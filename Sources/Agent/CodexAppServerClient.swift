import Foundation

protocol CodexRPCTransport: Sendable {
    func start() async throws
    func request(method: String, params: Data) async throws -> Data
    func stop() async
}

protocol CodexNotificationTransport: Sendable {
    func setNotificationHandler(_ handler: (@Sendable (Data) async -> Void)?) async
}

enum CodexTransportError: Error, Equatable {
    case executableNotFound
    case notStarted
    case timeout
    case stopped
    case invalidResponse
    case serverError(code: Int?)
    case launchFailed
    case writeFailed
}

struct CodexExecutableResolver: Sendable {
    private let configuredPath: @Sendable () -> String?
    private let candidatePaths: [String]
    private let isExecutable: @Sendable (String) -> Bool

    init(
        configuredPath: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: "agent.codexExecutablePath")
        },
        candidatePaths: [String] = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "~/.local/bin/codex"
        ],
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.configuredPath = configuredPath
        self.candidatePaths = candidatePaths
        self.isExecutable = isExecutable
    }

    func resolve() -> String? {
        let paths = [configuredPath()].compactMap { $0 } + candidatePaths
        return paths
            .map { NSString(string: $0).expandingTildeInPath }
            .first(where: isExecutable)
    }
}

actor CodexProcessTransport: CodexRPCTransport, CodexNotificationTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executablePath: String?
    private let requestTimeout: TimeInterval
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutputTask: Task<Void, Never>?
    private var standardErrorTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var diagnosticBuffer = Data()
    private var notificationHandler: (@Sendable (Data) async -> Void)?

    init(
        executablePath: String? = CodexExecutableResolver().resolve(),
        requestTimeout: TimeInterval = 5
    ) {
        self.executablePath = executablePath
        self.requestTimeout = requestTimeout
    }

    func start() async throws {
        guard process == nil else { return }
        guard let executablePath,
              FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw CodexTransportError.executableNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { await self?.processDidTerminate(terminatedProcess) }
        }

        do {
            try process.run()
        } catch {
            throw CodexTransportError.launchFailed
        }

        self.process = process
        nextRequestID = 1
        stdoutBuffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
        standardInput = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        standardOutputTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let data = try? outputHandle.read(upToCount: 4_096),
                      !data.isEmpty else {
                    break
                }
                await self?.consumeStandardOutput(data)
            }
        }
        standardErrorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let data = try? errorHandle.read(upToCount: 4_096),
                      !data.isEmpty else {
                    break
                }
                await self?.consumeStandardError(data)
            }
        }
    }

    func request(method: String, params: Data) async throws -> Data {
        guard process != nil, let standardInput else {
            throw CodexTransportError.notStarted
        }

        let paramsObject = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])
        if method == "initialized" {
            try writeLine(
                object: ["method": method, "params": paramsObject],
                to: standardInput
            )
            return Data(#"{}"#.utf8)
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let object: [String: Any] = [
            "method": method,
            "id": requestID,
            "params": paramsObject
        ]

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutNanoseconds = UInt64(max(0, requestTimeout) * 1_000_000_000)
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.expireRequest(id: requestID)
            }
            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            do {
                try writeLine(object: object, to: standardInput)
            } catch {
                let pending = pendingRequests.removeValue(forKey: requestID)
                pending?.timeoutTask.cancel()
                pending?.continuation.resume(throwing: CodexTransportError.writeFailed)
            }
        }
    }

    func setNotificationHandler(_ handler: (@Sendable (Data) async -> Void)?) async {
        notificationHandler = handler
    }

    func stop() async {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CodexTransportError.stopped)
        }

        try? standardInput?.close()
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        standardOutputTask?.cancel()
        standardErrorTask?.cancel()
        standardOutputTask = nil
        standardErrorTask = nil
        standardInput = nil
        process = nil
        notificationHandler = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
    }

    private func writeLine(object: Any, to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func expireRequest(id: Int) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CodexTransportError.timeout)
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CodexTransportError.stopped)
        }
        standardOutputTask?.cancel()
        standardErrorTask?.cancel()
        standardOutputTask = nil
        standardErrorTask = nil
        standardInput = nil
        process = nil
    }

    private func consumeStandardOutput(_ data: Data) async {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            await consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) async {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            return
        }

        if let number = object["id"] as? NSNumber {
            let requestID = number.intValue
            guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
            pending.timeoutTask.cancel()
            if let result = object["result"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                pending.continuation.resume(returning: data)
            } else if let error = object["error"] as? [String: Any] {
                pending.continuation.resume(
                    throwing: CodexTransportError.serverError(code: error["code"] as? Int)
                )
            } else {
                pending.continuation.resume(throwing: CodexTransportError.invalidResponse)
            }
            return
        }

        guard object["method"] is String, let notificationHandler else { return }
        await notificationHandler(line)
    }

    private func consumeStandardError(_ data: Data) {
        diagnosticBuffer.append(data)
        let maximumBytes = 32 * 1_024
        if diagnosticBuffer.count > maximumBytes {
            diagnosticBuffer.removeFirst(diagnosticBuffer.count - maximumBytes)
        }
    }
}

struct CodexThreadListResponse: Decodable {
    let data: [CodexThread]
    let nextCursor: String?
}

struct CodexThread: Decodable {
    let id: String
    let sessionId: String
    let name: String?
    let preview: String
    let cwd: String
    let updatedAt: Int64
}

struct CodexGoalResponse: Decodable {
    let goal: CodexGoal?
}

struct CodexGoal: Decodable {
    let threadId: String
    let objective: String
    let status: String
    let updatedAt: Int64
}

struct TurnPlanStep: Decodable, Equatable, Sendable {
    let step: String
    let status: String
}

private struct CodexTurnPlanUpdatedNotification: Decodable {
    struct Params: Decodable {
        let threadId: String
        let plan: [TurnPlanStep]
    }

    let method: String
    let params: Params
}

actor CodexAppServerClient {
    private let transport: any CodexRPCTransport
    private var isStarted = false
    private var planStepsByThreadID: [String: [TurnPlanStep]] = [:]

    init(transport: any CodexRPCTransport) {
        self.transport = transport
    }

    func start() async throws {
        guard !isStarted else { return }
        planStepsByThreadID.removeAll()
        if let notificationTransport = transport as? any CodexNotificationTransport {
            await notificationTransport.setNotificationHandler { [weak self] data in
                await self?.receiveNotification(data)
            }
        }
        do {
            try await transport.start()
            let initialize = try JSONSerialization.data(withJSONObject: [
                "clientInfo": [
                    "name": "progressbar",
                    "title": "ProgressBar",
                    "version": "1.0"
                ]
            ])
            _ = try await transport.request(method: "initialize", params: initialize)
            let initialized = try JSONSerialization.data(withJSONObject: [:])
            _ = try await transport.request(method: "initialized", params: initialized)
            isStarted = true
        } catch {
            if let notificationTransport = transport as? any CodexNotificationTransport {
                await notificationTransport.setNotificationHandler(nil)
            }
            await transport.stop()
            throw error
        }
    }

    func listThreads(cursor: String?) async throws -> CodexThreadListResponse {
        var object: [String: Any] = [
            "archived": false,
            "limit": 100,
            "sortKey": "updated_at",
            "sortDirection": "desc"
        ]
        if let cursor {
            object["cursor"] = cursor
        }
        let params = try JSONSerialization.data(withJSONObject: object)
        let response = try await transport.request(method: "thread/list", params: params)
        return try JSONDecoder().decode(CodexThreadListResponse.self, from: response)
    }

    func goal(threadID: String) async throws -> CodexGoal? {
        let params = try JSONSerialization.data(withJSONObject: ["threadId": threadID])
        let response = try await transport.request(method: "thread/goal/get", params: params)
        return try JSONDecoder().decode(CodexGoalResponse.self, from: response).goal
    }

    func capturedPlanSteps(threadID: String) -> [TurnPlanStep] {
        planStepsByThreadID[threadID, default: []]
    }

    func stop() async {
        if let notificationTransport = transport as? any CodexNotificationTransport {
            await notificationTransport.setNotificationHandler(nil)
        }
        guard isStarted else { return }
        isStarted = false
        await transport.stop()
    }

    private func receiveNotification(_ data: Data) {
        guard let notification = try? JSONDecoder().decode(
            CodexTurnPlanUpdatedNotification.self,
            from: data
        ), notification.method == "turn/plan/updated" else {
            return
        }
        planStepsByThreadID[notification.params.threadId] = notification.params.plan
    }
}
