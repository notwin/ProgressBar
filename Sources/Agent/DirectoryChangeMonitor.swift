import Darwin
import Foundation

protocol AgentDirectoryMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

protocol DirectoryMonitorScheduledAction: AnyObject, Sendable {
    func cancel()
}

private final class DispatchDirectoryMonitorScheduledAction: DirectoryMonitorScheduledAction, @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

final class DirectoryChangeMonitor: AgentDirectoryMonitoring, @unchecked Sendable {
    static let defaultDebounceInterval: TimeInterval = 1

    private enum WatchTopology: Equatable {
        case fallback(anchorPath: String)
        case precise(paths: Set<String>)
    }

    private struct WatchPlan {
        let urls: [URL]
        let topology: WatchTopology
    }

    private let tasksRoot: URL
    private let debounceInterval: TimeInterval
    private let initialCallback: (@Sendable () -> Void)?
    private var changeHandler: (@Sendable () -> Void)?
    private let queue: DispatchQueue
    private let debounceScheduler: @Sendable (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> any DirectoryMonitorScheduledAction
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingCallback: (any DirectoryMonitorScheduledAction)?
    private var watchTopology: WatchTopology?
    private var isStarted = false

    init(
        tasksRoot: URL,
        debounceInterval: TimeInterval = DirectoryChangeMonitor.defaultDebounceInterval,
        queue: DispatchQueue? = nil,
        debounceScheduler: (@Sendable (
            TimeInterval,
            @escaping @Sendable () -> Void
        ) -> any DirectoryMonitorScheduledAction)? = nil,
        callback: (@Sendable () -> Void)? = nil
    ) {
        let monitorQueue = queue ?? DispatchQueue(label: "progressbar.agent-directory-monitor")
        self.tasksRoot = tasksRoot.resolvingSymlinksInPath().standardizedFileURL
        self.debounceInterval = debounceInterval
        self.initialCallback = callback
        self.queue = monitorQueue
        self.debounceScheduler = debounceScheduler ?? { interval, action in
            let workItem = DispatchWorkItem(block: action)
            monitorQueue.asyncAfter(deadline: .now() + interval, execute: workItem)
            return DispatchDirectoryMonitorScheduledAction(workItem: workItem)
        }
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() {
        enqueueStart(onChange: nil, onReady: {})
    }

    func start(onReady: @escaping @Sendable () -> Void) {
        enqueueStart(onChange: nil, onReady: onReady)
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        enqueueStart(onChange: onChange, onReady: {})
    }

    private func enqueueStart(
        onChange: (@Sendable () -> Void)?,
        onReady: @escaping @Sendable () -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if let onChange {
                self.changeHandler = onChange
            }
            guard !self.isStarted else {
                onReady()
                return
            }
            self.isStarted = true
            self.refreshWatchedDirectories()
            onReady()
        }
    }

    func stop() {
        synchronized {
            guard isStarted || !sources.isEmpty || pendingCallback != nil else { return }
            isStarted = false
            pendingCallback?.cancel()
            pendingCallback = nil
            changeHandler = nil
            watchTopology = nil
            let activeSources = Array(sources.values)
            sources.removeAll()
            activeSources.forEach { $0.cancel() }
        }
    }

    private func synchronized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    @discardableResult
    private func refreshWatchedDirectories() -> WatchTopology {
        let plan = makeWatchPlan()
        let desiredURLs = plan.urls
        let desiredPaths = Set(desiredURLs.map(canonicalPath))

        for path in Array(sources.keys) where !desiredPaths.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for url in desiredURLs where sources[canonicalPath(url)] == nil {
            addSource(for: url)
        }
        watchTopology = plan.topology
        return plan.topology
    }

    private func makeWatchPlan() -> WatchPlan {
        let tasksParent = tasksRoot.deletingLastPathComponent()
        guard isDirectory(tasksParent) else {
            let anchor = nearestExistingAncestor(startingAt: tasksParent)
            return WatchPlan(
                urls: [anchor],
                topology: .fallback(anchorPath: canonicalPath(anchor))
            )
        }

        var urls = [tasksParent]
        if isDirectory(tasksRoot) {
            urls.append(tasksRoot)
            let sessionDirectories = (try? FileManager.default.contentsOfDirectory(
                at: tasksRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            urls.append(contentsOf: sessionDirectories.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            })
        }
        let sortedURLs = urls.sorted { $0.path < $1.path }
        return WatchPlan(
            urls: sortedURLs,
            topology: .precise(paths: Set(sortedURLs.map(canonicalPath)))
        )
    }

    private func nearestExistingAncestor(startingAt url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !isDirectory(candidate) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return parent }
            candidate = parent
        }
        return candidate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func addSource(for url: URL) {
        let path = canonicalPath(url)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if !events.intersection([.rename, .delete]).isEmpty {
                self.sources.removeValue(forKey: path)?.cancel()
            }
            self.scheduleCallback()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources[path] = source
        source.resume()
    }

    private func scheduleCallback() {
        guard isStarted else { return }
        pendingCallback?.cancel()
        pendingCallback = debounceScheduler(debounceInterval) { [weak self] in
            self?.queue.async { [weak self] in
                self?.fireDebouncedCallback()
            }
        }
    }

    private func fireDebouncedCallback() {
        guard isStarted else { return }
        pendingCallback = nil
        let priorTopology = watchTopology
        let refreshedTopology = refreshWatchedDirectories()
        if case .fallback = priorTopology, priorTopology == refreshedTopology {
            return
        }
        if let changeHandler {
            changeHandler()
        } else {
            initialCallback?()
        }
    }

    func simulateFileSystemEvent(at url: URL) {
        queue.async { [weak self] in
            guard let self, self.sources[self.canonicalPath(url)] != nil else { return }
            self.scheduleCallback()
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    func watchedPaths() async -> Set<String> {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let paths = self.map { Set($0.sources.keys) } ?? []
                continuation.resume(returning: paths)
            }
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
