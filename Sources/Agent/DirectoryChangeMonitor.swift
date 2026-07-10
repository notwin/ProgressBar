import Darwin
import Foundation

final class DirectoryChangeMonitor: @unchecked Sendable {
    static let defaultDebounceInterval: TimeInterval = 1

    private let tasksRoot: URL
    private let debounceInterval: TimeInterval
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(label: "progressbar.agent-directory-monitor")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingCallback: DispatchWorkItem?
    private var isStarted = false

    init(
        tasksRoot: URL,
        debounceInterval: TimeInterval = DirectoryChangeMonitor.defaultDebounceInterval,
        callback: @escaping @Sendable () -> Void
    ) {
        self.tasksRoot = tasksRoot.standardizedFileURL
        self.debounceInterval = debounceInterval
        self.callback = callback
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() {
        synchronized {
            guard !isStarted else { return }
            isStarted = true
            refreshWatchedDirectories()
        }
    }

    func stop() {
        synchronized {
            guard isStarted || !sources.isEmpty || pendingCallback != nil else { return }
            isStarted = false
            pendingCallback?.cancel()
            pendingCallback = nil
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
        var urls = [tasksRoot.deletingLastPathComponent(), tasksRoot]
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
            self.callback()
        }
        pendingCallback = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
