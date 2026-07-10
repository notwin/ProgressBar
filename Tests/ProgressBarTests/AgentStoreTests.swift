import Foundation
import XCTest
@testable import ProgressBar

final class AgentStoreTests: XCTestCase {
    private func makeStore() async throws -> AgentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await AgentStore(databaseURL: dir.appendingPathComponent("agent.sqlite"))
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
}

private enum AgentFixtures {
    static func snapshot(status: AgentItemStatus) -> AgentSnapshot {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let key = AgentItemKey(source: .claude, sessionID: "session-1", itemID: "item-1")
        let item = AgentItemSnapshot(
            key: key,
            kind: .todo,
            title: "Ship store",
            description: "Persist the normalized snapshot",
            status: status,
            sortOrder: 0,
            sourceUpdatedAt: updatedAt,
            blocks: [],
            blockedBy: []
        )
        let session = AgentSessionSnapshot(
            source: .claude,
            sessionID: "session-1",
            title: "Agent store",
            updatedAt: updatedAt,
            items: [item]
        )
        let project = AgentProjectSnapshot(
            source: .claude,
            projectKey: "project-1",
            displayName: "ProgressBar",
            cwd: "/tmp/ProgressBar",
            sessions: [session]
        )
        return AgentSnapshot(
            source: .claude,
            scannedAt: updatedAt,
            projects: [project],
            cursorData: "cursor-1"
        )
    }
}
