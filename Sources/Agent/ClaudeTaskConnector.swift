import Foundation

struct ClaudeTaskConnector: AgentConnector {
    let source: AgentSource = .claude

    private let tasksRoot: URL
    private let projectsRoot: URL
    private let now: @Sendable () -> Date
    private let taskDataReader: @Sendable (URL, Int) throws -> Data
    private var fileManager: FileManager { .default }

    init(
        tasksRoot: URL,
        projectsRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tasksRoot = tasksRoot
        self.projectsRoot = projectsRoot
        self.now = now
        self.taskDataReader = { url, count in
            try Self.readTaskData(at: url, upToCount: count)
        }
    }

    init(
        tasksRoot: URL,
        projectsRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        taskDataReader: @escaping @Sendable (URL, Int) throws -> Data
    ) {
        self.tasksRoot = tasksRoot
        self.projectsRoot = projectsRoot
        self.now = now
        self.taskDataReader = taskDataReader
    }

    func scan(cursor: String?) async throws -> AgentSnapshot {
        let priorFiles = decodeCursor(cursor)
        let taskFiles = try discoverTaskFiles()
        let transcriptIndex = makeTranscriptIndex()
        var nextCursorFiles: [ClaudeCursorFile] = []
        var itemsBySession: [String: [AgentItemSnapshot]] = [:]

        for taskFile in taskFiles {
            let fingerprint = try fingerprint(for: taskFile.url)
            let prior = priorFiles[taskFile.url.standardizedFileURL.path]
            let item: AgentItemSnapshot?

            if fingerprint.byteSize <= ClaudeLimits.maximumTaskBytes,
               prior?.byteSize == fingerprint.byteSize,
               prior?.modificationTimestamp == fingerprint.modificationTimestamp,
               let cached = prior?.item?.snapshot,
               cached.key.source == .claude,
               cached.key.sessionID == taskFile.sessionID {
                item = cached
            } else {
                item = decodeTask(
                    at: taskFile.url,
                    sessionID: taskFile.sessionID,
                    byteSize: fingerprint.byteSize,
                    modifiedAt: fingerprint.modifiedAt
                )
            }

            nextCursorFiles.append(ClaudeCursorFile(
                path: taskFile.url.standardizedFileURL.path,
                byteSize: fingerprint.byteSize,
                modificationTimestamp: fingerprint.modificationTimestamp,
                item: item.map(ClaudeCursorItem.init)
            ))
            if let item {
                itemsBySession[taskFile.sessionID, default: []].append(item)
            }
        }

        let projects = buildProjects(
            from: itemsBySession,
            transcriptIndex: transcriptIndex
        )
        let nextCursor = ClaudeCursor(files: nextCursorFiles)
        let cursorData = try String(
            decoding: JSONEncoder.claudeCursor.encode(nextCursor),
            as: UTF8.self
        )

        return AgentSnapshot(
            source: .claude,
            scannedAt: now(),
            projects: projects,
            cursorData: cursorData
        )
    }

    private func discoverTaskFiles() throws -> [ClaudeTaskFileLocation] {
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: tasksRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try sessionDirectories
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { sessionDirectory -> [ClaudeTaskFileLocation] in
                let sessionID = sessionDirectory.lastPathComponent
                return try fileManager.contentsOfDirectory(
                    at: sessionDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                .filter { url in
                    url.pathExtension == "json"
                        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { ClaudeTaskFileLocation(sessionID: sessionID, url: $0) }
            }
    }

    private func fingerprint(for url: URL) throws -> ClaudeTaskFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let byteSize = values.fileSize,
              let modifiedAt = values.contentModificationDate
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return ClaudeTaskFingerprint(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            modificationTimestamp: modifiedAt.timeIntervalSince1970
        )
    }

    private func decodeTask(
        at url: URL,
        sessionID: String,
        byteSize: Int,
        modifiedAt: Date
    ) -> AgentItemSnapshot? {
        guard byteSize <= ClaudeLimits.maximumTaskBytes,
              let data = try? taskDataReader(url, ClaudeLimits.maximumTaskBytes + 1),
              data.count <= ClaudeLimits.maximumTaskBytes,
              let task = try? JSONDecoder().decode(ClaudeTaskFile.self, from: data),
              let status = AgentItemStatus(claudeStatus: task.status)
        else {
            return nil
        }

        return AgentItemSnapshot(
            key: AgentItemKey(source: .claude, sessionID: sessionID, itemID: task.id),
            kind: .todo,
            title: task.subject,
            description: task.description,
            status: status,
            sortOrder: 0,
            sourceUpdatedAt: modifiedAt,
            blocks: task.blocks,
            blockedBy: task.blockedBy
        )
    }

    private static func readTaskData(at url: URL, upToCount count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private func makeTranscriptIndex() -> [String: URL] {
        guard let enumerator = fileManager.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        let transcripts = enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  url.pathExtension == "jsonl",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }

        return transcripts
            .sorted { $0.path < $1.path }
            .reduce(into: [:]) { index, url in
                let sessionID = url.deletingPathExtension().lastPathComponent
                if index[sessionID] == nil {
                    index[sessionID] = url
                }
            }
    }

    private func buildProjects(
        from itemsBySession: [String: [AgentItemSnapshot]],
        transcriptIndex: [String: URL]
    ) -> [AgentProjectSnapshot] {
        var sessionsByProject: [ClaudeProjectIdentity: [AgentSessionSnapshot]] = [:]

        for sessionID in itemsBySession.keys.sorted() {
            guard let unsortedItems = itemsBySession[sessionID] else { continue }
            let items = unsortedItems.enumerated().map { index, item in
                AgentItemSnapshot(
                    key: item.key,
                    kind: item.kind,
                    title: item.title,
                    description: item.description,
                    status: item.status,
                    sortOrder: index,
                    sourceUpdatedAt: item.sourceUpdatedAt,
                    blocks: item.blocks,
                    blockedBy: item.blockedBy
                )
            }
            let transcriptURL = transcriptIndex[sessionID]
            let transcript = transcriptURL.flatMap(readTranscriptContext)
            let project = projectIdentity(transcript: transcript, transcriptURL: transcriptURL, sessionID: sessionID)
            let updatedAt = items.compactMap(\.sourceUpdatedAt).max() ?? now()
            let session = AgentSessionSnapshot(
                source: .claude,
                sessionID: sessionID,
                title: transcript?.title ?? String(sessionID.prefix(8)),
                updatedAt: updatedAt,
                items: items
            )
            sessionsByProject[project, default: []].append(session)
        }

        return sessionsByProject.keys.sorted { $0.projectKey < $1.projectKey }.map { project in
            AgentProjectSnapshot(
                source: .claude,
                projectKey: project.projectKey,
                displayName: project.displayName,
                cwd: project.cwd,
                sessions: sessionsByProject[project, default: []].sorted { $0.sessionID < $1.sessionID }
            )
        }
    }

    private func readTranscriptContext(at url: URL) -> ClaudeTranscriptContext? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ClaudeLimits.maximumTranscriptBytes) else {
            return nil
        }

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "user",
                  let cwd = object["cwd"] as? String,
                  !cwd.isEmpty,
                  let message = object["message"] as? [String: Any],
                  let title = textualContent(message["content"]),
                  !title.isEmpty
            else {
                continue
            }

            return ClaudeTranscriptContext(
                cwd: URL(fileURLWithPath: cwd).standardizedFileURL.path,
                title: title
            )
        }
        return nil
    }

    private func textualContent(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = value as? [Any] else { return nil }
        for block in blocks {
            if let text = block as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let object = block as? [String: Any],
               object["type"] as? String == "text",
               let text = object["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func projectIdentity(
        transcript: ClaudeTranscriptContext?,
        transcriptURL: URL?,
        sessionID: String
    ) -> ClaudeProjectIdentity {
        if let transcript {
            return ClaudeProjectIdentity(
                projectKey: transcript.cwd,
                displayName: URL(fileURLWithPath: transcript.cwd).lastPathComponent,
                cwd: transcript.cwd
            )
        }

        if let parent = transcriptURL?.deletingLastPathComponent() {
            return ClaudeProjectIdentity(
                projectKey: parent.lastPathComponent,
                displayName: parent.lastPathComponent,
                cwd: parent.standardizedFileURL.path
            )
        }

        return ClaudeProjectIdentity(
            projectKey: sessionID,
            displayName: sessionID,
            cwd: tasksRoot.appendingPathComponent(sessionID).standardizedFileURL.path
        )
    }

    private func decodeCursor(_ cursor: String?) -> [String: ClaudeCursorFile] {
        guard let cursor,
              let data = cursor.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ClaudeCursor.self, from: data)
        else {
            return [:]
        }
        return Dictionary(decoded.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private enum ClaudeLimits {
    static let maximumTaskBytes = 1_048_576
    static let maximumTranscriptBytes = 262_144
}

private struct ClaudeTaskFile: Decodable {
    let id: String
    let subject: String
    let description: String
    let activeForm: String?
    let status: String
    let blocks: [String]
    let blockedBy: [String]
}

private struct ClaudeTaskFileLocation {
    let sessionID: String
    let url: URL
}

private struct ClaudeTaskFingerprint {
    let byteSize: Int
    let modifiedAt: Date
    let modificationTimestamp: TimeInterval
}

private struct ClaudeTranscriptContext {
    let cwd: String
    let title: String
}

private struct ClaudeProjectIdentity: Hashable {
    let projectKey: String
    let displayName: String
    let cwd: String
}

private struct ClaudeCursor: Codable {
    let files: [ClaudeCursorFile]
}

private struct ClaudeCursorFile: Codable {
    let path: String
    let byteSize: Int
    let modificationTimestamp: TimeInterval
    let item: ClaudeCursorItem?
}

private struct ClaudeCursorItem: Codable {
    let key: AgentItemKey
    let kind: AgentItemKind
    let title: String
    let description: String
    let status: AgentItemStatus
    let sortOrder: Int
    let sourceUpdatedAt: Date?
    let blocks: [String]
    let blockedBy: [String]

    init(_ item: AgentItemSnapshot) {
        self.key = item.key
        self.kind = item.kind
        self.title = item.title
        self.description = item.description
        self.status = item.status
        self.sortOrder = item.sortOrder
        self.sourceUpdatedAt = item.sourceUpdatedAt
        self.blocks = item.blocks
        self.blockedBy = item.blockedBy
    }

    var snapshot: AgentItemSnapshot {
        AgentItemSnapshot(
            key: key,
            kind: kind,
            title: title,
            description: description,
            status: status,
            sortOrder: sortOrder,
            sourceUpdatedAt: sourceUpdatedAt,
            blocks: blocks,
            blockedBy: blockedBy
        )
    }
}

private extension JSONEncoder {
    static var claudeCursor: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
