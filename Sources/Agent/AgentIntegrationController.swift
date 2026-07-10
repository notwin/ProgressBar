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
    private var directoryMonitor: DirectoryChangeMonitor?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pollCancellation: (any AgentPollCancellation)?
    private var initialRefreshTask: Task<Void, Never>?
    private var isStarted = false
    private var isVisible = false
    private var applicationIsActive: Bool
    private var refreshPending = false
    private var refreshRunning = false

    init(
        store: AgentStore,
        connectors: [any AgentConnector],
        notificationCenter: NotificationCenter = .default,
        pollScheduler: (any AgentPollScheduling)? = nil,
        applicationIsActive: Bool? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        worker = AgentRefreshWorker(store: store, connectors: connectors, now: now)
        self.notificationCenter = notificationCenter
        self.pollScheduler = pollScheduler ?? FoundationAgentPollScheduler()
        self.applicationIsActive = applicationIsActive ?? NSApplication.shared.isActive
    }

    private init(
        databaseURL: URL,
        sources: [AgentSource],
        connectorLoader: @escaping @Sendable () -> [any AgentConnector],
        notificationCenter: NotificationCenter = .default,
        pollScheduler: (any AgentPollScheduling)? = nil,
        applicationIsActive: Bool? = nil,
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
        self.applicationIsActive = applicationIsActive ?? NSApplication.shared.isActive
    }

    static func live() -> AgentIntegrationController {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let tasksRoot = home.appendingPathComponent(".claude/tasks")
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
            }
        )
        controller.directoryMonitor = DirectoryChangeMonitor(tasksRoot: tasksRoot) { [weak controller] in
            Task { @MainActor in
                await controller?.refresh()
            }
        }
        return controller
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        registerApplicationNotifications()
        directoryMonitor?.start()
        updatePolling()
        initialRefreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        stopPolling()
        directoryMonitor?.stop()
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updatePolling()
    }

    func refresh() async {
        if refreshRunning {
            refreshPending = true
            return
        }

        refreshRunning = true
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshRunning = false
        }
        repeat {
            refreshPending = false
            dashboard = await worker.performPass(includeHistory: showingHistory)
        } while refreshPending
    }

    private func registerApplicationNotifications() {
        notificationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applicationIsActive = false
                self?.updatePolling()
            }
        })
        notificationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applicationIsActive = true
                self?.updatePolling()
            }
        })
    }

    private func updatePolling() {
        stopPolling()
        guard isStarted, isVisible, applicationIsActive else { return }
        pollCancellation = pollScheduler.schedule(every: Self.pollingInterval) { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollCancellation?.cancel()
        pollCancellation = nil
    }
}
