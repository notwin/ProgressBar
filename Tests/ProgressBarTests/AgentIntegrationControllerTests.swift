import Foundation
import AppKit
import XCTest
@testable import ProgressBar

final class AgentIntegrationControllerTests: XCTestCase {
    @MainActor
    func testOneSourceFailureDoesNotHideOtherSource() async throws {
        let controller = try await makeController(connectors: [
            SnapshotConnector(source: .claude),
            FailingConnector(source: .codex)
        ])

        await controller.refresh()

        XCTAssertEqual(controller.dashboard.projects.first?.source, .claude)
        XCTAssertNotNil(controller.dashboard.sourceStates.first { $0.source == .codex }?.error)
    }

    @MainActor
    func testRefreshCoalescesConcurrentRequestsIntoOnePendingPass() async throws {
        let connector = GatedCountingConnector()
        let controller = try await makeController(connectors: [connector])

        let first = Task { @MainActor in await controller.refresh() }
        await connector.waitForFirstScan()
        await controller.refresh()
        await connector.releaseFirstScan()
        await first.value

        let statistics = await connector.statistics()
        XCTAssertEqual(statistics.scanCount, 2)
        XCTAssertEqual(statistics.maximumConcurrentScans, 1)
    }

    @MainActor
    func testVisibilityAndApplicationActivityControlTenSecondPolling() async throws {
        let connector = CountingConnector()
        let scheduler = TestPollScheduler()
        let notificationCenter = NotificationCenter()
        let controller = try await makeController(
            connectors: [connector],
            notificationCenter: notificationCenter,
            pollScheduler: scheduler
        )
        controller.start()
        await waitUntil { await connector.scanCount == 1 }

        controller.setVisible(true)
        XCTAssertEqual(scheduler.scheduledIntervals, [10])
        scheduler.fire()
        await waitUntil { await connector.scanCount == 2 }

        notificationCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scheduler.cancelCount, 1)
        scheduler.fire()
        try await Task.sleep(for: .milliseconds(20))
        let inactiveScanCount = await connector.scanCount
        XCTAssertEqual(inactiveScanCount, 2)

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scheduler.scheduledIntervals, [10, 10])
        scheduler.fire()
        await waitUntil { await connector.scanCount == 3 }

        controller.setVisible(false)
        XCTAssertEqual(scheduler.cancelCount, 2)
        scheduler.fire()
        try await Task.sleep(for: .milliseconds(20))
        let hiddenScanCount = await connector.scanCount
        XCTAssertEqual(hiddenScanCount, 3)
        controller.stop()
    }

    @MainActor
    func testStoppingDuringInitialRefreshClearsPublishedRefreshState() async throws {
        let connector = CancellationAwareConnector()
        let controller = try await makeController(connectors: [connector])
        controller.start()
        await connector.waitForScan()
        XCTAssertTrue(controller.isRefreshing)

        controller.stop()

        await waitUntil {
            await MainActor.run { !controller.isRefreshing }
        }
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertNil(controller.dashboard.sourceStates.first { $0.source == .claude }?.error)
    }

    func testDirectoryMonitorDebouncesBurstsAndStopsCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let callbackCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05
        ) {
            Task { await callbackCount.increment() }
        }

        monitor.start()
        try Data("one".utf8).write(to: session.appendingPathComponent("1.json"))
        try Data("two".utf8).write(to: session.appendingPathComponent("2.json"))
        await waitUntil { await callbackCount.value == 1 }
        try await Task.sleep(for: .milliseconds(100))
        let debouncedCount = await callbackCount.value
        XCTAssertEqual(debouncedCount, 1)
        XCTAssertEqual(DirectoryChangeMonitor.defaultDebounceInterval, 1)

        monitor.stop()
        try Data("three".utf8).write(to: session.appendingPathComponent("3.json"))
        try await Task.sleep(for: .milliseconds(100))
        let stoppedCount = await callbackCount.value
        XCTAssertEqual(stoppedCount, 1)
    }

    func testDirectoryMonitorRefreshesSessionWatchersAfterRootChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let firstSession = root.appendingPathComponent("session-1")
        let secondSession = root.appendingPathComponent("session-2")
        try FileManager.default.createDirectory(at: firstSession, withIntermediateDirectories: true)
        let callbackCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05
        ) {
            Task { await callbackCount.increment() }
        }
        monitor.start()

        try FileManager.default.removeItem(at: firstSession)
        try FileManager.default.createDirectory(at: secondSession, withIntermediateDirectories: true)
        await waitUntil { await callbackCount.value == 1 }

        try Data("new session".utf8).write(to: secondSession.appendingPathComponent("1.json"))
        await waitUntil { await callbackCount.value == 2 }
        let refreshedCount = await callbackCount.value
        XCTAssertEqual(refreshedCount, 2)
        monitor.stop()
    }

    func testDirectoryMonitorRecoversAfterTasksRootIsDeletedAndRecreated() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("session-1"),
            withIntermediateDirectories: true
        )
        let callbackCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05
        ) {
            Task { await callbackCount.increment() }
        }
        monitor.start()

        try FileManager.default.removeItem(at: root)
        await waitUntil { await callbackCount.value == 1 }
        let replacementSession = root.appendingPathComponent("session-2")
        try FileManager.default.createDirectory(at: replacementSession, withIntermediateDirectories: true)
        await waitUntil { await callbackCount.value == 2 }

        try Data("replacement".utf8).write(to: replacementSession.appendingPathComponent("1.json"))
        await waitUntil { await callbackCount.value == 3 }
        let recoveredCount = await callbackCount.value
        XCTAssertEqual(recoveredCount, 3)
        monitor.stop()
    }

    @MainActor
    private func makeController(
        connectors: [any AgentConnector],
        notificationCenter: NotificationCenter = NotificationCenter(),
        pollScheduler: (any AgentPollScheduling)? = nil
    ) async throws -> AgentIntegrationController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = try await AgentStore(databaseURL: directory.appendingPathComponent("agent.sqlite"))
        return AgentIntegrationController(
            store: store,
            connectors: connectors,
            notificationCenter: notificationCenter,
            pollScheduler: pollScheduler ?? TestPollScheduler(),
            applicationIsActive: true,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before timeout")
    }
}

private struct SnapshotConnector: AgentConnector {
    let source: AgentSource

    func scan(cursor: String?) async throws -> AgentSnapshot {
        makeSnapshot(source: source)
    }
}

private struct FailingConnector: AgentConnector {
    let source: AgentSource

    func scan(cursor: String?) async throws -> AgentSnapshot {
        throw TestFailure.failed
    }
}

private actor CountingConnector: AgentConnector {
    nonisolated let source: AgentSource = .claude
    private(set) var scanCount = 0

    func scan(cursor: String?) async throws -> AgentSnapshot {
        scanCount += 1
        return makeSnapshot(source: source)
    }
}

private actor GatedCountingConnector: AgentConnector {
    nonisolated let source: AgentSource = .claude
    private(set) var scanCount = 0
    private(set) var maximumConcurrentScans = 0
    private var concurrentScans = 0
    private var firstScanContinuation: CheckedContinuation<Void, Never>?
    private var firstScanStarted = false

    func scan(cursor: String?) async throws -> AgentSnapshot {
        scanCount += 1
        concurrentScans += 1
        maximumConcurrentScans = max(maximumConcurrentScans, concurrentScans)
        defer { concurrentScans -= 1 }
        if scanCount == 1 {
            firstScanStarted = true
            await withCheckedContinuation { continuation in
                firstScanContinuation = continuation
            }
        }
        return makeSnapshot(source: source)
    }

    func waitForFirstScan() async {
        while !firstScanStarted {
            await Task.yield()
        }
    }

    func releaseFirstScan() {
        firstScanContinuation?.resume()
        firstScanContinuation = nil
    }

    func statistics() -> (scanCount: Int, maximumConcurrentScans: Int) {
        (scanCount, maximumConcurrentScans)
    }
}

private actor CancellationAwareConnector: AgentConnector {
    nonisolated let source: AgentSource = .claude
    private var scanStarted = false

    func scan(cursor: String?) async throws -> AgentSnapshot {
        scanStarted = true
        try await Task.sleep(for: .seconds(30))
        return makeSnapshot(source: source)
    }

    func waitForScan() async {
        while !scanStarted {
            await Task.yield()
        }
    }
}

@MainActor
private final class TestPollScheduler: AgentPollScheduling {
    private var slots: [TestPollSlot] = []
    private(set) var scheduledIntervals: [TimeInterval] = []
    private(set) var cancelCount = 0

    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any AgentPollCancellation {
        scheduledIntervals.append(interval)
        let slot = TestPollSlot(action: action)
        slots.append(slot)
        return TestPollCancellation { [weak self] in
            guard let self, slot.isActive else { return }
            slot.isActive = false
            self.cancelCount += 1
        }
    }

    func fire() {
        guard let slot = slots.last, slot.isActive else { return }
        slot.action()
    }
}

@MainActor
private final class TestPollSlot {
    let action: @MainActor () -> Void
    var isActive = true

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }
}

@MainActor
private final class TestPollCancellation: AgentPollCancellation {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private enum TestFailure: Error {
    case failed
}

private func makeSnapshot(source: AgentSource) -> AgentSnapshot {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let item = AgentItemSnapshot(
        key: AgentItemKey(source: source, sessionID: "session", itemID: "item"),
        kind: .todo,
        title: "Task",
        description: "",
        status: .inProgress,
        sortOrder: 0,
        sourceUpdatedAt: now,
        blocks: [],
        blockedBy: []
    )
    let session = AgentSessionSnapshot(
        source: source,
        sessionID: "session",
        title: "Session",
        updatedAt: now,
        items: [item]
    )
    let project = AgentProjectSnapshot(
        source: source,
        projectKey: source.rawValue,
        displayName: source.rawValue,
        cwd: "/tmp/\(source.rawValue)",
        sessions: [session]
    )
    return AgentSnapshot(source: source, scannedAt: now, projects: [project], cursorData: nil)
}
