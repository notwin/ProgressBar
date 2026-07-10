import Foundation

enum ClaudeTaskConnectorError: LocalizedError {
    case incompatibleTaskSchema(path: String)

    var errorDescription: String? {
        switch self {
        case .incompatibleTaskSchema(let path):
            return "Claude task schema is incompatible: \(path)"
        }
    }
}

struct ClaudeTaskConnector: AgentConnector {
    let source: AgentSource = .claude

    private let tasksRoot: URL
    private let now: @Sendable () -> Date
    private let taskDataReader: @Sendable (URL, Int) throws -> Data
    private let transcriptLocator: @Sendable (Set<String>) -> [String: URL]
    private let transcriptDataReader: @Sendable (URL, Int) throws -> Data
    private var fileManager: FileManager { .default }

    init(
        tasksRoot: URL,
        projectsRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tasksRoot = tasksRoot
        self.now = now
        self.taskDataReader = { url, count in
            try Self.readTaskData(at: url, upToCount: count)
        }
        self.transcriptLocator = { sessionIDs in
            Self.locateTranscripts(in: projectsRoot, sessionIDs: sessionIDs)
        }
        self.transcriptDataReader = { url, count in
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
        self.now = now
        self.taskDataReader = taskDataReader
        self.transcriptLocator = { sessionIDs in
            Self.locateTranscripts(in: projectsRoot, sessionIDs: sessionIDs)
        }
        self.transcriptDataReader = { url, count in
            try Self.readTaskData(at: url, upToCount: count)
        }
    }

    init(
        tasksRoot: URL,
        projectsRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        transcriptLocator: @escaping @Sendable (Set<String>) -> [String: URL],
        transcriptDataReader: @escaping @Sendable (URL, Int) throws -> Data
    ) {
        self.tasksRoot = tasksRoot
        self.now = now
        self.taskDataReader = { url, count in
            try Self.readTaskData(at: url, upToCount: count)
        }
        self.transcriptLocator = transcriptLocator
        self.transcriptDataReader = transcriptDataReader
    }

    func scan(cursor: String?) async throws -> AgentSnapshot {
        let priorCursor = decodeCursor(cursor)
        let priorFiles = Dictionary(
            priorCursor.files.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let taskFiles = try discoverTaskFiles()
        var nextCursorFiles: [ClaudeCursorFile] = []
        var taskFingerprintsBySession: [String: [ClaudeCursorTaskFingerprint]] = [:]
        var itemsBySession: [String: [AgentItemSnapshot]] = [:]

        for taskFile in taskFiles {
            let path = taskFile.url.standardizedFileURL.path
            let prior = priorFiles[path]
            let fileFingerprint: ClaudeTaskFingerprint
            do {
                fileFingerprint = try fingerprint(for: taskFile.url)
            } catch {
                if let prior {
                    nextCursorFiles.append(prior)
                    taskFingerprintsBySession[taskFile.sessionID, default: []].append(
                        ClaudeCursorTaskFingerprint(prior)
                    )
                    if let cached = prior.item?.snapshot,
                       cached.key.source == .claude,
                       cached.key.sessionID == taskFile.sessionID {
                        itemsBySession[taskFile.sessionID, default: []].append(cached)
                    }
                }
                continue
            }
            let item: AgentItemSnapshot?
            var cursorFile: ClaudeCursorFile

            if let prior,
               fileFingerprint.byteSize <= ClaudeLimits.maximumTaskBytes,
               prior.byteSize == fileFingerprint.byteSize,
               prior.modificationTimestamp == fileFingerprint.modificationTimestamp,
               let cached = prior.item?.snapshot,
               cached.key.source == .claude,
               cached.key.sessionID == taskFile.sessionID {
                item = cached
                cursorFile = prior
            } else {
                switch try decodeTask(
                    at: taskFile.url,
                    sessionID: taskFile.sessionID,
                    byteSize: fileFingerprint.byteSize,
                    modifiedAt: fileFingerprint.modifiedAt
                ) {
                case .valid(let decoded):
                    item = decoded
                    cursorFile = ClaudeCursorFile(
                        path: path,
                        byteSize: fileFingerprint.byteSize,
                        modificationTimestamp: fileFingerprint.modificationTimestamp,
                        item: ClaudeCursorItem(decoded)
                    )
                case .malformed:
                    if let prior,
                       let cached = prior.item?.snapshot,
                       cached.key.source == .claude,
                       cached.key.sessionID == taskFile.sessionID {
                        item = cached
                        cursorFile = prior
                    } else {
                        item = nil
                        cursorFile = ClaudeCursorFile(
                            path: path,
                            byteSize: fileFingerprint.byteSize,
                            modificationTimestamp: fileFingerprint.modificationTimestamp,
                            item: nil
                        )
                    }
                }
            }

            nextCursorFiles.append(cursorFile)
            taskFingerprintsBySession[taskFile.sessionID, default: []].append(
                ClaudeCursorTaskFingerprint(cursorFile)
            )
            if let item {
                itemsBySession[taskFile.sessionID, default: []].append(item)
            }
        }

        let transcriptState = resolveTranscripts(
            for: Set(itemsBySession.keys),
            taskFingerprints: taskFingerprintsBySession.mapValues {
                $0.sorted { $0.path < $1.path }
            },
            prior: Dictionary(
                priorCursor.transcripts.map { ($0.sessionID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        let projects = buildProjects(from: itemsBySession, transcripts: transcriptState.resolved)
        let nextCursor = ClaudeCursor(files: nextCursorFiles, transcripts: transcriptState.cursor)
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
    ) throws -> ClaudeTaskDecodeResult {
        guard byteSize <= ClaudeLimits.maximumTaskBytes else { return .malformed }
        let data: Data
        do {
            data = try taskDataReader(url, ClaudeLimits.maximumTaskBytes + 1)
        } catch {
            return .malformed
        }
        guard data.count <= ClaudeLimits.maximumTaskBytes else { return .malformed }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .malformed }

        let task: ClaudeTaskFile
        do {
            task = try JSONDecoder().decode(ClaudeTaskFile.self, from: data)
        } catch {
            throw ClaudeTaskConnectorError.incompatibleTaskSchema(path: url.path)
        }
        guard let status = AgentItemStatus(claudeStatus: task.status) else {
            throw ClaudeTaskConnectorError.incompatibleTaskSchema(path: url.path)
        }

        return .valid(AgentItemSnapshot(
            key: AgentItemKey(source: .claude, sessionID: sessionID, itemID: task.id),
            kind: .todo,
            title: task.subject,
            description: task.description,
            status: status,
            sortOrder: 0,
            sourceUpdatedAt: modifiedAt,
            blocks: task.blocks,
            blockedBy: task.blockedBy
        ))
    }

    private static func readTaskData(at url: URL, upToCount count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func locateTranscripts(
        in projectsRoot: URL,
        sessionIDs: Set<String>
    ) -> [String: URL] {
        guard !sessionIDs.isEmpty,
              let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        let transcripts = enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  url.pathExtension == "jsonl",
                  sessionIDs.contains(url.deletingPathExtension().lastPathComponent),
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
        transcripts: [String: ClaudeResolvedTranscript]
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
            let transcriptURL = transcripts[sessionID]?.url
            let transcript = transcripts[sessionID]?.context
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
        guard let data = try? transcriptDataReader(url, ClaudeLimits.maximumTranscriptBytes) else {
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

    private func resolveTranscripts(
        for sessionIDs: Set<String>,
        taskFingerprints: [String: [ClaudeCursorTaskFingerprint]],
        prior: [String: ClaudeCursorTranscript]
    ) -> (resolved: [String: ClaudeResolvedTranscript], cursor: [ClaudeCursorTranscript]) {
        var resolved: [String: ClaudeResolvedTranscript] = [:]
        var cursorBySession: [String: ClaudeCursorTranscript] = [:]
        var sessionsNeedingLocation = Set<String>()

        for sessionID in sessionIDs.sorted() {
            let currentTaskFingerprints = taskFingerprints[sessionID] ?? []
            guard let cached = prior[sessionID] else {
                sessionsNeedingLocation.insert(sessionID)
                continue
            }
            guard let cachedPath = cached.path else {
                if cached.taskFingerprints == currentTaskFingerprints {
                    cursorBySession[sessionID] = cached
                } else {
                    sessionsNeedingLocation.insert(sessionID)
                }
                continue
            }
            let url = URL(fileURLWithPath: cachedPath)
            guard let cachedByteSize = cached.byteSize,
                  let cachedModificationTimestamp = cached.modificationTimestamp,
                  let fileFingerprint = try? fingerprint(for: url)
            else {
                sessionsNeedingLocation.insert(sessionID)
                continue
            }

            if cachedByteSize == fileFingerprint.byteSize,
               cachedModificationTimestamp == fileFingerprint.modificationTimestamp {
                cursorBySession[sessionID] = cached.withTaskFingerprints(currentTaskFingerprints)
                resolved[sessionID] = ClaudeResolvedTranscript(
                    url: url,
                    context: cached.context
                )
            } else {
                let context = readTranscriptContext(at: url)
                let refreshed = ClaudeCursorTranscript(
                    sessionID: sessionID,
                    path: url.standardizedFileURL.path,
                    byteSize: fileFingerprint.byteSize,
                    modificationTimestamp: fileFingerprint.modificationTimestamp,
                    context: context,
                    taskFingerprints: currentTaskFingerprints
                )
                cursorBySession[sessionID] = refreshed
                resolved[sessionID] = ClaudeResolvedTranscript(url: url, context: context)
            }
        }

        let located = sessionsNeedingLocation.isEmpty
            ? [:]
            : transcriptLocator(sessionsNeedingLocation)
        for sessionID in sessionsNeedingLocation.sorted() {
            guard let url = located[sessionID],
                  let fileFingerprint = try? fingerprint(for: url)
            else { continue }
            let context = readTranscriptContext(at: url)
            let currentTaskFingerprints = taskFingerprints[sessionID] ?? []
            let discovered = ClaudeCursorTranscript(
                sessionID: sessionID,
                path: url.standardizedFileURL.path,
                byteSize: fileFingerprint.byteSize,
                modificationTimestamp: fileFingerprint.modificationTimestamp,
                context: context,
                taskFingerprints: currentTaskFingerprints
            )
            cursorBySession[sessionID] = discovered
            resolved[sessionID] = ClaudeResolvedTranscript(url: url, context: context)
        }
        for sessionID in sessionsNeedingLocation where cursorBySession[sessionID] == nil {
            cursorBySession[sessionID] = ClaudeCursorTranscript(
                sessionID: sessionID,
                path: nil,
                byteSize: nil,
                modificationTimestamp: nil,
                context: nil,
                taskFingerprints: taskFingerprints[sessionID] ?? []
            )
        }

        return (
            resolved,
            cursorBySession.keys.sorted().compactMap { cursorBySession[$0] }
        )
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

    private func decodeCursor(_ cursor: String?) -> ClaudeCursor {
        guard let cursor,
              let data = cursor.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ClaudeCursor.self, from: data)
        else {
            return ClaudeCursor(files: [], transcripts: [])
        }
        return decoded
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

private enum ClaudeTaskDecodeResult {
    case valid(AgentItemSnapshot)
    case malformed
}

private struct ClaudeTranscriptContext: Codable {
    let cwd: String
    let title: String
}

private struct ClaudeResolvedTranscript {
    let url: URL
    let context: ClaudeTranscriptContext?
}

private struct ClaudeProjectIdentity: Hashable {
    let projectKey: String
    let displayName: String
    let cwd: String
}

private struct ClaudeCursor: Codable {
    let files: [ClaudeCursorFile]
    let transcripts: [ClaudeCursorTranscript]

    init(files: [ClaudeCursorFile], transcripts: [ClaudeCursorTranscript]) {
        self.files = files
        self.transcripts = transcripts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([ClaudeCursorFile].self, forKey: .files)
        transcripts = try container.decodeIfPresent(
            [ClaudeCursorTranscript].self,
            forKey: .transcripts
        ) ?? []
    }
}

private struct ClaudeCursorTranscript: Codable {
    let sessionID: String
    let path: String?
    let byteSize: Int?
    let modificationTimestamp: TimeInterval?
    let context: ClaudeTranscriptContext?
    let taskFingerprints: [ClaudeCursorTaskFingerprint]

    private enum CodingKeys: String, CodingKey {
        case sessionID, path, byteSize, modificationTimestamp, context, taskFingerprints
    }

    init(
        sessionID: String,
        path: String?,
        byteSize: Int?,
        modificationTimestamp: TimeInterval?,
        context: ClaudeTranscriptContext?,
        taskFingerprints: [ClaudeCursorTaskFingerprint]
    ) {
        self.sessionID = sessionID
        self.path = path
        self.byteSize = byteSize
        self.modificationTimestamp = modificationTimestamp
        self.context = context
        self.taskFingerprints = taskFingerprints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize)
        modificationTimestamp = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .modificationTimestamp
        )
        context = try container.decodeIfPresent(ClaudeTranscriptContext.self, forKey: .context)
        taskFingerprints = try container.decodeIfPresent(
            [ClaudeCursorTaskFingerprint].self,
            forKey: .taskFingerprints
        ) ?? []
    }

    func withTaskFingerprints(
        _ taskFingerprints: [ClaudeCursorTaskFingerprint]
    ) -> ClaudeCursorTranscript {
        ClaudeCursorTranscript(
            sessionID: sessionID,
            path: path,
            byteSize: byteSize,
            modificationTimestamp: modificationTimestamp,
            context: context,
            taskFingerprints: taskFingerprints
        )
    }
}

private struct ClaudeCursorTaskFingerprint: Codable, Equatable {
    let path: String
    let byteSize: Int
    let modificationTimestamp: TimeInterval

    init(_ file: ClaudeCursorFile) {
        path = file.path
        byteSize = file.byteSize
        modificationTimestamp = file.modificationTimestamp
    }
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
