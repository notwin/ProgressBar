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
        let second = Task { @MainActor in await controller.refresh() }
        await Task.yield()
        await connector.releaseFirstScan()
        await first.value
        await second.value

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
    func testRestartResamplesApplicationActivityBeforePolling() async throws {
        let activity = MutableApplicationActivity(isActive: true)
        let scheduler = TestPollScheduler()
        let controller = try await makeController(
            connectors: [CountingConnector()],
            pollScheduler: scheduler,
            applicationIsActiveProvider: { activity.isActive }
        )
        controller.setVisible(true)
        controller.start()
        XCTAssertEqual(scheduler.scheduledIntervals, [10])
        controller.stop()

        activity.isActive = false
        controller.start()

        XCTAssertEqual(scheduler.scheduledIntervals, [10])
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

    @MainActor
    func testQueuedPollAndFileTriggersAfterStopDoNotRefresh() async throws {
        let connector = CountingConnector()
        let scheduler = TestPollScheduler()
        let directoryMonitor = TestDirectoryMonitor()
        let controller = try await makeController(
            connectors: [connector],
            pollScheduler: scheduler,
            directoryMonitor: directoryMonitor
        )
        controller.start()
        controller.setVisible(true)
        await waitUntil { await connector.scanCount == 1 }
        let queuedPoll = try XCTUnwrap(scheduler.captureQueuedAction())
        let queuedFile = try XCTUnwrap(directoryMonitor.captureQueuedChange())

        controller.stop()
        queuedPoll()
        await queuedFile()
        await Task.yield()

        let scanCount = await connector.scanCount
        XCTAssertEqual(scanCount, 1)
    }

    @MainActor
    func testStopRestartSuppressesStalePublishAndQueuesNewGeneration() async throws {
        let connector = GenerationGatedConnector()
        let controller = try await makeController(connectors: [connector])
        controller.start()
        await connector.waitForScanCount(1)
        let pendingCaller = Task { @MainActor in
            await controller.refresh()
        }
        await Task.yield()

        controller.stop()
        controller.start()
        await Task.yield()
        let scanCountBeforeRelease = await connector.currentScanCount()
        XCTAssertEqual(scanCountBeforeRelease, 1)

        await connector.releaseScan(1)
        await connector.waitForScanCount(2)
        XCTAssertTrue(controller.dashboard.projects.isEmpty)
        let recordedCancellation = await connector.wasCancelled(scan: 2)
        let secondScanCancelled = try XCTUnwrap(recordedCancellation)
        XCTAssertFalse(secondScanCancelled)
        let maximumConcurrency = await connector.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)

        await connector.releaseScan(2)
        await waitUntil {
            await MainActor.run {
                controller.dashboard.projects.first?.displayName == "generation-2"
            }
        }
        await pendingCaller.value
        let finalScanCount = await connector.currentScanCount()
        XCTAssertEqual(finalScanCount, 2)
    }

    @MainActor
    func testControllerDeinitCancelsTimerMonitorAndObservers() async throws {
        let connector = CountingConnector()
        let scheduler = TestPollScheduler()
        let directoryMonitor = TestDirectoryMonitor()
        let notificationCenter = NotificationCenter()
        var controller: AgentIntegrationController? = try await makeController(
            connectors: [connector],
            notificationCenter: notificationCenter,
            pollScheduler: scheduler,
            directoryMonitor: directoryMonitor
        )
        let weakController = WeakBox(controller)
        controller?.setVisible(true)
        controller?.start()
        await waitUntil { await connector.scanCount == 1 }
        await waitUntil {
            await MainActor.run { controller?.isRefreshing == false }
        }
        XCTAssertEqual(scheduler.scheduledIntervals, [10])

        controller = nil

        XCTAssertNil(weakController.value)
        XCTAssertEqual(directoryMonitor.currentStopCount(), 1)
        await waitUntil {
            await MainActor.run { scheduler.cancelCount == 1 }
        }
        XCTAssertEqual(scheduler.cancelCount, 1)
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(scheduler.scheduledIntervals, [10])
    }

    @MainActor
    func testControllerCanDeinitWhileConnectorIgnoresCancellation() async throws {
        let connector = GenerationGatedConnector()
        let scheduler = TestPollScheduler()
        let directoryMonitor = TestDirectoryMonitor()
        var controller: AgentIntegrationController? = try await makeController(
            connectors: [connector],
            pollScheduler: scheduler,
            directoryMonitor: directoryMonitor
        )
        let weakController = WeakBox(controller)
        controller?.start()
        await connector.waitForScanCount(1)

        controller = nil
        let deallocatedBeforeConnectorReturned = weakController.value == nil
        if !deallocatedBeforeConnectorReturned {
            await connector.releaseScan(1)
            await waitUntil {
                await MainActor.run { weakController.value == nil }
            }
        }

        XCTAssertTrue(deallocatedBeforeConnectorReturned)
        XCTAssertEqual(directoryMonitor.currentStopCount(), 1)
        await connector.releaseScan(1)
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

        await startMonitor(monitor)
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
        await startMonitor(monitor)

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
        await startMonitor(monitor)

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
    func testDirectoryMonitorStartReturnsBeforePrivateQueueSetupCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "progressbar.agent-directory-monitor.test-suspended")
        queue.suspend()
        let readyCount = AsyncCounter()
        let callbackCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05,
            queue: queue,
            callback: { Task { await callbackCount.increment() } }
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            queue.resume()
        }

        let startedAt = ContinuousClock.now
        monitor.start(onReady: {
            Task { await readyCount.increment() }
        })
        let returnDuration = startedAt.duration(to: .now)

        XCTAssertLessThan(returnDuration, .milliseconds(50))
        await waitUntil { await readyCount.value == 1 }
        try Data("ready".utf8).write(to: session.appendingPathComponent("1.json"))
        await waitUntil { await callbackCount.value == 1 }
        monitor.stop()
    }

    func testDirectoryMonitorUsesExistingAncestorWhenClaudeParentIsInitiallyMissing() async throws {
        let anchor = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let root = anchor.appendingPathComponent("missing/.claude/tasks")
        let callbackCount = AsyncCounter()
        let readyCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05,
            callback: { Task { await callbackCount.increment() } }
        )
        monitor.start(onReady: { Task { await readyCount.increment() } })
        await waitUntil { await readyCount.value == 1 }

        let session = root.appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        await waitUntil { await callbackCount.value == 1 }
        try Data("created".utf8).write(to: session.appendingPathComponent("1.json"))
        await waitUntil { await callbackCount.value == 2 }

        let count = await callbackCount.value
        XCTAssertEqual(count, 2)
        try FileManager.default.createDirectory(
            at: anchor.appendingPathComponent("unrelated"),
            withIntermediateDirectories: true
        )
        try await Task.sleep(for: .milliseconds(100))
        let countAfterUnrelatedAncestorChange = await callbackCount.value
        XCTAssertEqual(countAfterUnrelatedAncestorChange, 2)
        monitor.stop()
    }

    func testDirectoryMonitorImmediateStopDrainsQueuedStartAndSuppressesChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let readyCount = AsyncCounter()
        let callbackCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05,
            callback: { Task { await callbackCount.increment() } }
        )

        monitor.start(onReady: { Task { await readyCount.increment() } })
        monitor.stop()
        await waitUntil { await readyCount.value == 1 }
        try Data("stopped".utf8).write(to: session.appendingPathComponent("1.json"))
        try await Task.sleep(for: .milliseconds(100))

        let count = await callbackCount.value
        XCTAssertEqual(count, 0)
    }

    func testDirectoryMonitorRecoversAfterClaudeParentIsDeletedAndRecreated() async throws {
        let anchor = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let parent = anchor.appendingPathComponent(".claude")
        let root = parent.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("session-1"),
            withIntermediateDirectories: true
        )
        let callbackCount = AsyncCounter()
        let readyCount = AsyncCounter()
        let monitor = DirectoryChangeMonitor(
            tasksRoot: root,
            debounceInterval: 0.05,
            callback: { Task { await callbackCount.increment() } }
        )
        monitor.start(onReady: { Task { await readyCount.increment() } })
        await waitUntil { await readyCount.value == 1 }

        try FileManager.default.removeItem(at: parent)
        await waitUntil { await callbackCount.value == 1 }
        let replacementSession = root.appendingPathComponent("session-2")
        try FileManager.default.createDirectory(at: replacementSession, withIntermediateDirectories: true)
        await waitUntil { await callbackCount.value == 2 }
        try Data("replacement".utf8).write(to: replacementSession.appendingPathComponent("1.json"))
        await waitUntil { await callbackCount.value == 3 }

        let count = await callbackCount.value
        XCTAssertEqual(count, 3)
        monitor.stop()
    }

    @MainActor
    private func makeController(
        connectors: [any AgentConnector],
        notificationCenter: NotificationCenter = NotificationCenter(),
        pollScheduler: (any AgentPollScheduling)? = nil,
        directoryMonitor: (any AgentDirectoryMonitoring)? = nil,
        applicationIsActiveProvider: (@MainActor () -> Bool)? = nil
    ) async throws -> AgentIntegrationController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = try await AgentStore(databaseURL: directory.appendingPathComponent("agent.sqlite"))
        return AgentIntegrationController(
            store: store,
            connectors: connectors,
            notificationCenter: notificationCenter,
            pollScheduler: pollScheduler ?? TestPollScheduler(),
            directoryMonitor: directoryMonitor,
            applicationIsActiveProvider: applicationIsActiveProvider ?? { true },
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

    private func startMonitor(_ monitor: DirectoryChangeMonitor) async {
        let readyCount = AsyncCounter()
        monitor.start(onReady: {
            Task { await readyCount.increment() }
        })
        await waitUntil { await readyCount.value == 1 }
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

private actor GenerationGatedConnector: AgentConnector {
    nonisolated let source: AgentSource = .claude
    private var scanCount = 0
    private var concurrentScans = 0
    private var maximumConcurrentScans = 0
    private var cancelledByScan: [Int: Bool] = [:]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func scan(cursor: String?) async throws -> AgentSnapshot {
        scanCount += 1
        let scan = scanCount
        concurrentScans += 1
        maximumConcurrentScans = max(maximumConcurrentScans, concurrentScans)
        cancelledByScan[scan] = Task.isCancelled
        await withCheckedContinuation { continuation in
            continuations[scan] = continuation
        }
        concurrentScans -= 1
        return makeSnapshot(source: source, displayName: "generation-\(scan)")
    }

    func waitForScanCount(_ expectedCount: Int) async {
        while scanCount < expectedCount {
            await Task.yield()
        }
    }

    func releaseScan(_ scan: Int) {
        continuations.removeValue(forKey: scan)?.resume()
    }

    func currentScanCount() -> Int { scanCount }
    func maximumConcurrency() -> Int { maximumConcurrentScans }
    func wasCancelled(scan: Int) -> Bool? { cancelledByScan[scan] }
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

    func captureQueuedAction() -> (@MainActor () -> Void)? {
        slots.last?.action
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

@MainActor
private final class MutableApplicationActivity {
    var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class TestDirectoryMonitor: AgentDirectoryMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var changeHandler: (@Sendable () async -> Void)?
    private(set) var stopCount = 0

    func start(onChange: @escaping @Sendable () async -> Void) {
        lock.withLock {
            changeHandler = onChange
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            changeHandler = nil
        }
    }

    func captureQueuedChange() -> (@Sendable () async -> Void)? {
        lock.withLock { changeHandler }
    }

    func currentStopCount() -> Int {
        lock.withLock { stopCount }
    }
}

private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private enum TestFailure: Error {
    case failed
}

private func makeSnapshot(
    source: AgentSource,
    displayName: String? = nil
) -> AgentSnapshot {
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
        displayName: displayName ?? source.rawValue,
        cwd: "/tmp/\(source.rawValue)",
        sessions: [session]
    )
    return AgentSnapshot(source: source, scannedAt: now, projects: [project], cursorData: nil)
}
