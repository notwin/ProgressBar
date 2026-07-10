import Foundation
import SQLite3
import XCTest
@testable import ProgressBar

final class AgentStoreTests: XCTestCase {
    private func makeStore() async throws -> AgentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await AgentStore(databaseURL: dir.appendingPathComponent("agent.sqlite"))
    }

    private func makeStoreWithURL() async throws -> (store: AgentStore, url: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent.sqlite")
        return (try await AgentStore(databaseURL: url), url)
    }

    func testApplyingSameSnapshotTwiceIsIdempotent() async throws {
        let store = try await makeStore()
        let snapshot = AgentFixtures.snapshot(status: .inProgress)
        try await store.apply(snapshot: snapshot)
        try await store.apply(snapshot: snapshot)
        let dashboard = try await store.dashboard(includeHistory: false)
        XCTAssertEqual(dashboard.projects.count, 1)
        XCTAssertEqual(dashboard.projects[0].sessions[0].items.count, 1)
    }

    func testFailureKeepsLastSuccessfulRows() async throws {
        let store = try await makeStore()
        try await store.apply(snapshot: AgentFixtures.snapshot(status: .pending))
        try await store.recordFailure(source: .claude, message: "decode failed", at: Date())
        let dashboard = try await store.dashboard(includeHistory: false)
        XCTAssertEqual(dashboard.projects[0].sessions[0].items[0].status, .pending)
        XCTAssertEqual(dashboard.sourceStates.first?.error, "decode failed")
    }

    func testCompletedRowsAreHiddenFromActiveDashboard() async throws {
        let store = try await makeStore()
        try await store.apply(snapshot: AgentFixtures.snapshot(status: .done))
        let active = try await store.dashboard(includeHistory: false)
        let history = try await store.dashboard(includeHistory: true)
        XCTAssertTrue(active.projects.isEmpty)
        XCTAssertEqual(history.projects.count, 1)
    }

    func testCorruptDatabaseIsBackedUpAndRebuilt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent.sqlite")
        try Data("not a sqlite database".utf8).write(to: url)
        let store = try await AgentStore(databaseURL: url)
        let dashboard = try await store.dashboard(includeHistory: false)
        XCTAssertTrue(dashboard.projects.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("agent.sqlite.corrupt.") }.count, 1)
    }

    func testApplyingChangedSnapshotReplacesStaleLinks() async throws {
        let store = try await makeStore()
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .inProgress,
            blocks: ["old-block"],
            blockedBy: ["old-parent"]
        ))
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .inProgress,
            blocks: ["new-block"],
            blockedBy: ["new-parent"]
        ))

        let dashboard = try await store.dashboard(includeHistory: false)
        let item = try XCTUnwrap(dashboard.projects.first?.sessions.first?.items.first)
        XCTAssertEqual(item.blocks, ["new-block"])
        XCTAssertEqual(item.blockedBy, ["new-parent"])
    }

    func testMissingItemCompletionIsIsolatedToSuccessfulSource() async throws {
        let store = try await makeStore()
        let base = AgentFixtures.baseDate
        try await store.apply(snapshot: AgentFixtures.snapshot(
            source: .claude,
            status: .pending,
            scannedAt: base
        ))
        try await store.apply(snapshot: AgentFixtures.snapshot(
            source: .codex,
            status: .pending,
            scannedAt: base.addingTimeInterval(1)
        ))
        try await store.apply(snapshot: AgentFixtures.snapshot(
            source: .claude,
            status: .pending,
            scannedAt: base.addingTimeInterval(2),
            includeItem: false
        ))

        let historyItems = try await store.dashboard(includeHistory: true).projects
            .flatMap(\.sessions)
            .flatMap(\.items)
        XCTAssertEqual(historyItems.first { $0.key.source == .claude }?.status, .done)
        XCTAssertEqual(historyItems.first { $0.key.source == .codex }?.status, .pending)

        let active = try await store.dashboard(includeHistory: false)
        let activeSources = Set(active.projects.map(\.source))
        XCTAssertEqual(activeSources, [.codex])
    }

    func testReopeningMissingItemClearsCompletionForPruning() async throws {
        let store = try await makeStore()
        let base = AgentFixtures.baseDate
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .pending,
            scannedAt: base
        ))
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .pending,
            scannedAt: base.addingTimeInterval(10),
            includeItem: false
        ))
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .pending,
            scannedAt: base.addingTimeInterval(20)
        ))

        try await store.pruneHistory(before: base.addingTimeInterval(30))

        let dashboard = try await store.dashboard(includeHistory: false)
        let item = try XCTUnwrap(dashboard.projects.first?.sessions.first?.items.first)
        XCTAssertEqual(item.status, .pending)
    }

    func testFailurePreservesLastSuccessfulCursor() async throws {
        let store = try await makeStore()
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .pending,
            cursorData: "successful-cursor"
        ))
        let successfulCursor = try await store.cursor(for: .claude)
        XCTAssertEqual(successfulCursor, "successful-cursor")

        try await store.recordFailure(
            source: .claude,
            message: "scan failed",
            at: AgentFixtures.baseDate.addingTimeInterval(10)
        )

        let cursorAfterFailure = try await store.cursor(for: .claude)
        XCTAssertEqual(cursorAfterFailure, "successful-cursor")
    }

    func testAdoptionReservationConflictAndStateTransitionsPersist() async throws {
        let store = try await makeStore()
        let key = AgentFixtures.key()
        let first = try await store.reserveAdoption(
            key: key,
            taskID: "task-original",
            sectionID: "section-original",
            at: AgentFixtures.baseDate
        )
        let conflict = try await store.reserveAdoption(
            key: key,
            taskID: "task-replacement",
            sectionID: "section-replacement",
            at: AgentFixtures.baseDate.addingTimeInterval(1)
        )
        XCTAssertEqual(first, conflict)
        XCTAssertEqual(conflict.progressBarTaskID, "task-original")
        XCTAssertEqual(conflict.targetSectionID, "section-original")

        try await store.completeAdoption(key: key)
        let completed = try await store.adoption(for: key)
        XCTAssertEqual(completed?.state, .completed)
        try await store.failAdoption(key: key)
        let failed = try await store.adoption(for: key)
        XCTAssertEqual(failed?.state, .failed)
    }

    func testPreparingAdoptionRetryRetargetsEveryStateWithoutChangingTaskID() async throws {
        let store = try await makeStore()
        let key = AgentFixtures.key()
        _ = try await store.reserveAdoption(
            key: key,
            taskID: "task-original",
            sectionID: "section-original",
            at: AgentFixtures.baseDate
        )

        let pendingRetry = try await store.prepareAdoptionRetry(
            key: key,
            sectionID: "section-pending"
        )
        XCTAssertEqual(pendingRetry.progressBarTaskID, "task-original")
        XCTAssertEqual(pendingRetry.targetSectionID, "section-pending")
        XCTAssertEqual(pendingRetry.state, .pending)

        try await store.failAdoption(key: key)

        let failedRetry = try await store.prepareAdoptionRetry(
            key: key,
            sectionID: "section-retry"
        )
        XCTAssertEqual(failedRetry.progressBarTaskID, "task-original")
        XCTAssertEqual(failedRetry.targetSectionID, "section-retry")
        XCTAssertEqual(failedRetry.state, .pending)

        try await store.completeAdoption(key: key)
        let completedRetry = try await store.prepareAdoptionRetry(
            key: key,
            sectionID: "section-readopt"
        )
        XCTAssertEqual(completedRetry.progressBarTaskID, "task-original")
        XCTAssertEqual(completedRetry.targetSectionID, "section-readopt")
        XCTAssertEqual(completedRetry.state, .pending)
    }

    func testPruneHistoryRemovesEmptyHierarchyButRetainsAdoption() async throws {
        let (store, databaseURL) = try await makeStoreWithURL()
        let key = AgentFixtures.key()
        try await store.apply(snapshot: AgentFixtures.snapshot(
            status: .done,
            scannedAt: AgentFixtures.baseDate
        ))
        let adoption = try await store.reserveAdoption(
            key: key,
            taskID: "task-1",
            sectionID: "section-1",
            at: AgentFixtures.baseDate
        )

        try await store.pruneHistory(before: AgentFixtures.baseDate.addingTimeInterval(1))

        let history = try await store.dashboard(includeHistory: true)
        let retainedAdoption = try await store.adoption(for: key)
        let active = try await store.dashboard(includeHistory: false)
        XCTAssertTrue(history.projects.isEmpty)
        XCTAssertEqual(retainedAdoption, adoption)
        XCTAssertTrue(active.adoptedKeys.contains(key))
        XCTAssertEqual(try rowCount(in: "agent_items", databaseURL: databaseURL), 0)
        XCTAssertEqual(try rowCount(in: "agent_sessions", databaseURL: databaseURL), 0)
        XCTAssertEqual(try rowCount(in: "agent_projects", databaseURL: databaseURL), 0)
        XCTAssertEqual(try rowCount(in: "agent_adoptions", databaseURL: databaseURL), 1)
    }

    func testDashboardIncludesFullAdoptionRecordMapping() async throws {
        let store = try await makeStore()
        let key = AgentFixtures.key()
        let adoption = try await store.reserveAdoption(
            key: key,
            taskID: "task-1",
            sectionID: "section-1",
            at: AgentFixtures.baseDate
        )
        try await store.completeAdoption(key: key)

        let dashboard = try await store.dashboard(includeHistory: false)

        XCTAssertEqual(dashboard.adoptions[key]?.progressBarTaskID, adoption.progressBarTaskID)
        XCTAssertEqual(dashboard.adoptions[key]?.targetSectionID, adoption.targetSectionID)
        XCTAssertEqual(dashboard.adoptions[key]?.state, .completed)
    }

    private func rowCount(in table: String, databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            throw NSError(domain: "AgentStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw NSError(domain: "AgentStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "AgentStoreTests", code: 3)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private enum AgentFixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func key(source: AgentSource = .claude) -> AgentItemKey {
        AgentItemKey(source: source, sessionID: "session-1", itemID: "item-1")
    }

    static func snapshot(
        source: AgentSource = .claude,
        status: AgentItemStatus,
        scannedAt: Date = baseDate,
        cursorData: String? = "cursor-1",
        blocks: [String] = [],
        blockedBy: [String] = [],
        includeItem: Bool = true
    ) -> AgentSnapshot {
        let key = key(source: source)
        let item = AgentItemSnapshot(
            key: key,
            kind: .todo,
            title: "Ship store",
            description: "Persist the normalized snapshot",
            status: status,
            sortOrder: 0,
            sourceUpdatedAt: scannedAt,
            blocks: blocks,
            blockedBy: blockedBy
        )
        let session = AgentSessionSnapshot(
            source: source,
            sessionID: "session-1",
            title: "Agent store",
            updatedAt: scannedAt,
            items: includeItem ? [item] : []
        )
        let project = AgentProjectSnapshot(
            source: source,
            projectKey: "project-\(source.rawValue)",
            displayName: "ProgressBar",
            cwd: "/tmp/ProgressBar",
            sessions: [session]
        )
        return AgentSnapshot(
            source: source,
            scannedAt: scannedAt,
            projects: [project],
            cursorData: cursorData
        )
    }
}
