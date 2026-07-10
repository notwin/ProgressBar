import Darwin
import Foundation

protocol AgentDirectoryMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable () async -> Void)
    func stop()
}

final class DirectoryChangeMonitor: AgentDirectoryMonitoring, @unchecked Sendable {
    static let defaultDebounceInterval: TimeInterval = 1

    private let tasksRoot: URL
    private let debounceInterval: TimeInterval
    private let initialCallback: (@Sendable () -> Void)?
    private var changeHandler: (@Sendable () async -> Void)?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingCallback: DispatchWorkItem?
    private var isStarted = false

    init(
        tasksRoot: URL,
        debounceInterval: TimeInterval = DirectoryChangeMonitor.defaultDebounceInterval,
        queue: DispatchQueue? = nil,
        callback: (@Sendable () -> Void)? = nil
    ) {
        self.tasksRoot = tasksRoot.standardizedFileURL
        self.debounceInterval = debounceInterval
        self.initialCallback = callback
        self.queue = queue ?? DispatchQueue(label: "progressbar.agent-directory-monitor")
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

    func start(onChange: @escaping @Sendable () async -> Void) {
        enqueueStart(onChange: onChange, onReady: {})
    }

    private func enqueueStart(
        onChange: (@Sendable () async -> Void)?,
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

    private func refreshWatchedDirectories() {
        guard isStarted else { return }
        let desiredURLs = watchedDirectoryURLs()
        let desiredPaths = Set(desiredURLs.map(\.path))

        for path in Array(sources.keys) where !desiredPaths.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for url in desiredURLs where sources[url.path] == nil {
            addSource(for: url)
        }
    }

    private func watchedDirectoryURLs() -> [URL] {
        let tasksParent = tasksRoot.deletingLastPathComponent()
        guard isDirectory(tasksParent) else {
            return [nearestExistingAncestor(startingAt: tasksParent)]
        }

        var urls = [tasksParent]
        guard isDirectory(tasksRoot) else { return urls }
        urls.append(tasksRoot)
        let sessionDirectories = (try? FileManager.default.contentsOfDirectory(
            at: tasksRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        urls.append(contentsOf: sessionDirectories.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        })
        return urls.sorted { $0.path < $1.path }
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
                self.sources.removeValue(forKey: url.path)?.cancel()
            }
            self.scheduleCallback()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources[url.path] = source
        source.resume()
    }

    private func scheduleCallback() {
        guard isStarted else { return }
        pendingCallback?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.pendingCallback = nil
            self.refreshWatchedDirectories()
            if let changeHandler = self.changeHandler {
                Task { await changeHandler() }
            } else {
                self.initialCallback?()
            }
        }
        pendingCallback = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
