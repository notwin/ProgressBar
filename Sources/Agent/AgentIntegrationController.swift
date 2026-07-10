import AppKit
import Combine
import Foundation

@MainActor
protocol AgentPollCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol AgentPollScheduling: AnyObject {
    func schedule(
        every interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any AgentPollCancellation
}

@MainActor
private final class FoundationAgentPollCancellation: AgentPollCancellation {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
private final class FoundationAgentPollScheduler: AgentPollScheduling {
    func schedule(
        every interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any AgentPollCancellation {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        return FoundationAgentPollCancellation(timer: timer)
    }
}

private actor AgentRefreshWorker {
    private let connectorLoader: @Sendable () -> [any AgentConnector]
    private let configuredSources: [AgentSource]
    private let storeLoader: @Sendable () async throws -> AgentStore
    private let now: @Sendable () -> Date
    private var connectors: [any AgentConnector]?
    private var store: AgentStore?
    private var storeInitializationError: String?

    init(
        store: AgentStore,
        connectors: [any AgentConnector],
        now: @escaping @Sendable () -> Date
    ) {
        self.store = store
        self.connectors = connectors
        self.connectorLoader = { connectors }
        self.configuredSources = Array(Set(connectors.map(\.source)))
        self.now = now
        self.storeLoader = { store }
    }

    init(
        databaseURL: URL,
        sources: [AgentSource],
        connectorLoader: @escaping @Sendable () -> [any AgentConnector],
        now: @escaping @Sendable () -> Date
    ) {
        self.connectorLoader = connectorLoader
        self.configuredSources = Array(Set(sources))
        self.now = now
        self.storeLoader = {
            try await AgentStore(databaseURL: databaseURL)
        }
    }

    func performPass(includeHistory: Bool) async -> AgentDashboard {
        let connectors = loadConnectors()
        let store: AgentStore
        do {
            store = try await loadStore()
        } catch {
            return disabledDashboard(message: error.localizedDescription)
        }

        for connector in connectors {
            do {
                let cursor = try await store.cursor(for: connector.source)
                let snapshot = try await connector.scan(cursor: cursor)
                try await store.apply(snapshot: snapshot)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    break
                }
                try? await store.recordFailure(
                    source: connector.source,
                    message: error.localizedDescription,
                    at: now()
                )
            }
        }

        do {
            try await store.pruneHistory(before: now().addingTimeInterval(-30 * 24 * 60 * 60))
            return try await store.dashboard(includeHistory: includeHistory)
        } catch {
            return disabledDashboard(message: error.localizedDescription)
        }
    }

    func adoption(for key: AgentItemKey) async throws -> AgentAdoptionRecord? {
        let store = try await loadStore()
        return try await store.adoption(for: key)
    }

    func reserveAdoption(
        key: AgentItemKey,
        taskID: String,
        sectionID: String,
        at: Date
    ) async throws -> AgentAdoptionRecord {
        let store = try await loadStore()
        return try await store.reserveAdoption(
            key: key,
            taskID: taskID,
            sectionID: sectionID,
            at: at
        )
    }

    func completeAdoption(key: AgentItemKey) async throws {
        let store = try await loadStore()
        try await store.completeAdoption(key: key)
    }

    func failAdoption(key: AgentItemKey) async throws {
        let store = try await loadStore()
        try await store.failAdoption(key: key)
    }

    func dashboard(includeHistory: Bool) async throws -> AgentDashboard {
        let store = try await loadStore()
        return try await store.dashboard(includeHistory: includeHistory)
    }

    private func loadStore() async throws -> AgentStore {
        if let store { return store }
        if let storeInitializationError {
            throw AgentIntegrationError.storeUnavailable(storeInitializationError)
        }
        do {
            let loadedStore = try await storeLoader()
            store = loadedStore
            return loadedStore
        } catch {
            storeInitializationError = error.localizedDescription
            throw error
        }
    }

    private func loadConnectors() -> [any AgentConnector] {
        if let connectors { return connectors }
        let loadedConnectors = connectorLoader()
        connectors = loadedConnectors
        return loadedConnectors
    }

    private func disabledDashboard(message: String) -> AgentDashboard {
        let sources = configuredSources.sorted { $0.rawValue < $1.rawValue }
        return AgentDashboard(
            projects: [],
            sourceStates: sources.map {
                AgentSourceState(source: $0, lastScanAt: now(), lastSuccessAt: nil, error: message)
            },
            adoptedKeys: []
        )
    }
}

private enum AgentIntegrationError: Error, LocalizedError {
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .storeUnavailable(message): return message
        }
    }
}

enum AgentAdoptionError: Error, Equatable {
    case userTaskWriteFailed
}

private final class AgentLifecycleToken: @unchecked Sendable {}

@MainActor
final class AgentIntegrationController: ObservableObject {
    @Published private(set) var dashboard = AgentDashboard(
        projects: [],
        sourceStates: [],
        adoptedKeys: []
    )
    @Published private(set) var isRefreshing = false
    @Published var showingHistory = false

    private static let pollingInterval: TimeInterval = 10

    private let worker: AgentRefreshWorker
    private let notificationCenter: NotificationCenter
    private let pollScheduler: any AgentPollScheduling
    private let directoryMonitor: (any AgentDirectoryMonitoring)?
    private let applicationIsActiveProvider: @MainActor () -> Bool
    private var notificationObservers: [NSObjectProtocol] = []
    private var pollCancellation: (any AgentPollCancellation)?
    private var refreshTask: Task<Void, Never>?
    private var refreshExecutionTail: Task<Void, Never>?
    private var activeRefreshRunID: UInt64?
    private var nextRefreshRunID: UInt64 = 0
    private var lifecycleToken = AgentLifecycleToken()
    private var isStarted = false
    private var isVisible = false
    private var applicationIsActive: Bool
    private var refreshPending = false

    init(
        store: AgentStore,
        connectors: [any AgentConnector],
        notificationCenter: NotificationCenter = .default,
        pollScheduler: (any AgentPollScheduling)? = nil,
        directoryMonitor: (any AgentDirectoryMonitoring)? = nil,
        applicationIsActive: Bool? = nil,
        applicationIsActiveProvider: (@MainActor () -> Bool)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        worker = AgentRefreshWorker(store: store, connectors: connectors, now: now)
        self.notificationCenter = notificationCenter
        self.pollScheduler = pollScheduler ?? FoundationAgentPollScheduler()
        self.directoryMonitor = directoryMonitor
        let initialApplicationIsActive = applicationIsActive
        let provider = applicationIsActiveProvider ?? {
            initialApplicationIsActive ?? NSApplication.shared.isActive
        }
        self.applicationIsActiveProvider = provider
        self.applicationIsActive = provider()
    }

    private init(
        databaseURL: URL,
        sources: [AgentSource],
        connectorLoader: @escaping @Sendable () -> [any AgentConnector],
        notificationCenter: NotificationCenter = .default,
        pollScheduler: (any AgentPollScheduling)? = nil,
        directoryMonitor: (any AgentDirectoryMonitoring)? = nil,
        applicationIsActive: Bool? = nil,
        applicationIsActiveProvider: (@MainActor () -> Bool)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        worker = AgentRefreshWorker(
            databaseURL: databaseURL,
            sources: sources,
            connectorLoader: connectorLoader,
            now: now
        )
        self.notificationCenter = notificationCenter
        self.pollScheduler = pollScheduler ?? FoundationAgentPollScheduler()
        self.directoryMonitor = directoryMonitor
        let initialApplicationIsActive = applicationIsActive
        let provider = applicationIsActiveProvider ?? {
            initialApplicationIsActive ?? NSApplication.shared.isActive
        }
        self.applicationIsActiveProvider = provider
        self.applicationIsActive = provider()
    }

    deinit {
        let pollCancellation = pollCancellation
        let notificationObservers = notificationObservers
        let notificationCenter = notificationCenter
        refreshTask?.cancel()
        directoryMonitor?.stop()
        Task { @MainActor in
            pollCancellation?.cancel()
            notificationObservers.forEach(notificationCenter.removeObserver)
        }
    }

    static func live() -> AgentIntegrationController {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let tasksRoot = home.appendingPathComponent(".claude/tasks")
        let directoryMonitor = DirectoryChangeMonitor(tasksRoot: tasksRoot)
        let controller = AgentIntegrationController(
            databaseURL: PersistenceManager.localDir.appendingPathComponent("agent-index.sqlite"),
            sources: [.claude, .codex],
            connectorLoader: {
                [
                    ClaudeTaskConnector(
                        tasksRoot: tasksRoot,
                        projectsRoot: home.appendingPathComponent(".claude/projects")
                    ),
                    CodexConnector(
                        transport: CodexProcessTransport(
                            executablePath: CodexExecutableResolver().resolve()
                        )
                    )
                ]
            },
            directoryMonitor: directoryMonitor
        )
        return controller
    }

    func start() {
        guard !isStarted else { return }
        lifecycleToken = AgentLifecycleToken()
        let token = lifecycleToken
        isStarted = true
        applicationIsActive = applicationIsActiveProvider()
        registerApplicationNotifications(token: token)
        directoryMonitor?.start { [weak self, token] in
            Task { @MainActor in
                guard let self, self.isStarted, token === self.lifecycleToken else { return }
                _ = self.requestRefresh(token: token)
            }
        }
        updatePolling(token: token)
        _ = requestRefresh(token: token)
    }

    func stop() {
        guard isStarted else { return }
        let task = refreshTask
        lifecycleToken = AgentLifecycleToken()
        isStarted = false
        refreshPending = false
        refreshTask = nil
        activeRefreshRunID = nil
        isRefreshing = false
        task?.cancel()
        stopPolling()
        directoryMonitor?.stop()
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updatePolling(token: lifecycleToken)
    }

    func refresh() async {
        let task = requestRefresh(token: lifecycleToken)
        await task.value
    }

    func adopt(
        item: AgentItemSnapshot,
        sessionTitle: String,
        editedTitle: String,
        targetSectionID: String,
        taskSink: UserTaskAdopting
    ) async throws -> String {
        let adoption: AgentAdoptionRecord
        if let existing = try await worker.adoption(for: item.key) {
            adoption = existing
        } else {
            adoption = try await worker.reserveAdoption(
                key: item.key,
                taskID: UUID().uuidString.lowercased(),
                sectionID: targetSectionID,
                at: Date()
            )
        }

        if taskSink.containsTask(id: adoption.progressBarTaskID) {
            try await worker.completeAdoption(key: item.key)
            dashboard = try await worker.dashboard(includeHistory: showingHistory)
            return adoption.progressBarTaskID
        }

        let sourceName: String
        switch item.key.source {
        case .claude: sourceName = "Claude Code"
        case .codex: sourceName = "Codex"
        }
        let inserted = taskSink.insertAdoptedTask(
            id: adoption.progressBarTaskID,
            title: editedTitle,
            status: item.status.taskStatus,
            sectionID: adoption.targetSectionID,
            logText: "从 \(sourceName) 会话「\(sessionTitle)」接管"
        )
        guard inserted else {
            try await worker.failAdoption(key: item.key)
            throw AgentAdoptionError.userTaskWriteFailed
        }

        try await worker.completeAdoption(key: item.key)
        dashboard = try await worker.dashboard(includeHistory: showingHistory)
        return adoption.progressBarTaskID
    }

    private func requestRefresh(token: AgentLifecycleToken) -> Task<Void, Never> {
        guard token === lifecycleToken else { return Task {} }
        if let refreshTask {
            refreshPending = true
            return refreshTask
        }

        nextRefreshRunID &+= 1
        let runID = nextRefreshRunID
        let predecessor = refreshExecutionTail
        activeRefreshRunID = runID
        isRefreshing = true
        let task = Task { @MainActor [weak self, token] in
            defer { self?.finishRefresh(token: token, runID: runID) }
            await predecessor?.value
            while !Task.isCancelled {
                guard let pass = self?.prepareRefreshPass(token: token, runID: runID) else {
                    return
                }
                let refreshedDashboard = await pass.worker.performPass(
                    includeHistory: pass.includeHistory
                )
                guard !Task.isCancelled,
                      let shouldContinue = self?.publish(
                        refreshedDashboard,
                        token: token,
                        runID: runID
                      )
                else {
                    return
                }
                if !shouldContinue { return }
            }
        }
        refreshTask = task
        refreshExecutionTail = task
        return task
    }

    private func prepareRefreshPass(
        token: AgentLifecycleToken,
        runID: UInt64
    ) -> (worker: AgentRefreshWorker, includeHistory: Bool)? {
        guard isCurrent(token: token, runID: runID) else { return nil }
        refreshPending = false
        return (worker, showingHistory)
    }

    private func publish(
        _ refreshedDashboard: AgentDashboard,
        token: AgentLifecycleToken,
        runID: UInt64
    ) -> Bool? {
        guard isCurrent(token: token, runID: runID) else { return nil }
        dashboard = refreshedDashboard
        return refreshPending
    }

    private func finishRefresh(token: AgentLifecycleToken, runID: UInt64) {
        guard isCurrent(token: token, runID: runID) else { return }
        refreshTask = nil
        activeRefreshRunID = nil
        isRefreshing = false
    }

    private func isCurrent(token: AgentLifecycleToken, runID: UInt64) -> Bool {
        token === lifecycleToken && activeRefreshRunID == runID
    }

    private func registerApplicationNotifications(token: AgentLifecycleToken) {
        notificationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, token] _ in
            Task { @MainActor in
                guard let self, self.isStarted, token === self.lifecycleToken else { return }
                self.applicationIsActive = false
                self.updatePolling(token: token)
            }
        })
        notificationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, token] _ in
            Task { @MainActor in
                guard let self, self.isStarted, token === self.lifecycleToken else { return }
                self.applicationIsActive = true
                self.updatePolling(token: token)
            }
        })
    }

    private func updatePolling(token: AgentLifecycleToken) {
        stopPolling()
        guard isStarted, token === lifecycleToken, isVisible, applicationIsActive else { return }
        pollCancellation = pollScheduler.schedule(every: Self.pollingInterval) { [weak self, token] in
            guard let self, self.isStarted, token === self.lifecycleToken else { return }
            _ = self.requestRefresh(token: token)
        }
    }

    private func stopPolling() {
        pollCancellation?.cancel()
        pollCancellation = nil
    }
}
