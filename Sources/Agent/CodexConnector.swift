import Foundation

enum CodexConnectorError: Error, Equatable {
    case paginationDidNotProgress
}

struct CodexConnector: AgentConnector {
    let source: AgentSource = .codex

    private let transport: any CodexRPCTransport
    private let now: @Sendable () -> Date

    init(
        transport: any CodexRPCTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(transport: CodexProcessTransport(), now: now)
    }

    func scan(cursor: String?) async throws -> AgentSnapshot {
        let client = CodexAppServerClient(transport: transport)
        try await client.start()
        do {
            let snapshot = try await readSnapshot(client: client)
            await client.stop()
            return snapshot
        } catch {
            await client.stop()
            throw error
        }
    }

    private func readSnapshot(client: CodexAppServerClient) async throws -> AgentSnapshot {
        var threads: [CodexThread] = []
        var pageCursor: String?
        var seenCursors: Set<String> = []
        var seenThreadIDs: Set<String> = []
        var pageCount = 0

        repeat {
            guard pageCount < 500 else {
                throw CodexConnectorError.paginationDidNotProgress
            }
            if let pageCursor, !seenCursors.insert(pageCursor).inserted {
                throw CodexConnectorError.paginationDidNotProgress
            }
            let page = try await client.listThreads(cursor: pageCursor)
            pageCount += 1
            let remaining = 500 - threads.count
            let newThreads = page.data.filter { seenThreadIDs.insert($0.id).inserted }
            threads.append(contentsOf: newThreads.prefix(remaining))
            if page.nextCursor != nil, newThreads.isEmpty {
                throw CodexConnectorError.paginationDidNotProgress
            }
            pageCursor = threads.count < 500 ? page.nextCursor : nil
        } while pageCursor != nil

        var goalsByThreadID: [String: CodexGoal] = [:]
        for thread in threads {
            if let goal = try await client.goal(threadID: thread.id) {
                goalsByThreadID[thread.id] = goal
            }
        }
        let capturedPlans = try await client.freezeCapturedPlans()

        var sessionsByProject: [CodexProjectIdentity: [AgentSessionSnapshot]] = [:]
        for thread in threads {
            var items: [AgentItemSnapshot] = []
            if let goal = goalsByThreadID[thread.id],
               goal.threadId == thread.id,
               let status = AgentItemStatus(codexGoalStatus: goal.status),
               status != .done {
                items.append(AgentItemSnapshot(
                    key: AgentItemKey(source: .codex, sessionID: thread.id, itemID: "goal"),
                    kind: .goal,
                    title: goal.objective,
                    description: "",
                    status: status,
                    sortOrder: 0,
                    sourceUpdatedAt: Date(timeIntervalSince1970: TimeInterval(goal.updatedAt) / 1_000),
                    blocks: [],
                    blockedBy: []
                ))
            }

            var duplicateCounts: [String: Int] = [:]
            let capturedPlan = capturedPlans[thread.id]
            items.append(contentsOf: (capturedPlan?.steps ?? []).enumerated().compactMap { index, step in
                guard let status = Self.planStatus(step.status) else { return nil }
                let duplicateIndex = duplicateCounts[step.step, default: 0]
                duplicateCounts[step.step] = duplicateIndex + 1
                return AgentItemSnapshot(
                    key: AgentItemKey(
                        source: .codex,
                        sessionID: thread.id,
                        itemID: Self.planItemID(
                            turnID: capturedPlan?.turnID ?? "",
                            step: step.step,
                            duplicateIndex: duplicateIndex
                        )
                    ),
                    kind: .planStep,
                    title: step.step,
                    description: "",
                    status: status,
                    sortOrder: items.count + index,
                    sourceUpdatedAt: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)),
                    blocks: [],
                    blockedBy: []
                )
            })
            guard !items.isEmpty else { continue }

            let cwd = URL(fileURLWithPath: thread.cwd).standardizedFileURL.path
            let project = CodexProjectIdentity(cwd: cwd)
            let session = AgentSessionSnapshot(
                source: .codex,
                sessionID: thread.id,
                title: Self.title(for: thread),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)),
                items: items
            )
            sessionsByProject[project, default: []].append(session)
        }

        let projects = sessionsByProject.keys.sorted { $0.cwd < $1.cwd }.map { project in
            AgentProjectSnapshot(
                source: .codex,
                projectKey: project.cwd,
                displayName: project.displayName,
                cwd: project.cwd,
                sessions: sessionsByProject[project, default: []].sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.sessionID < $1.sessionID }
                    return $0.updatedAt > $1.updatedAt
                }
            )
        }

        return AgentSnapshot(
            source: .codex,
            scannedAt: now(),
            projects: projects,
            cursorData: nil
        )
    }

    private static func title(for thread: CodexThread) -> String {
        if let name = nonEmpty(thread.name) { return name }
        if let preview = nonEmpty(thread.preview) { return preview }
        return String(thread.id.prefix(8))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func planStatus(_ value: String) -> AgentItemStatus? {
        switch value {
        case "pending": return .pending
        case "inProgress": return .inProgress
        case "completed": return .done
        default: return nil
        }
    }

    private static func planItemID(
        turnID: String,
        step: String,
        duplicateIndex: Int
    ) -> String {
        "plan-step-\(stableHash(turnID))-\(stableHash(step))-\(duplicateIndex)"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private struct CodexProjectIdentity: Hashable {
    let cwd: String

    var displayName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}
