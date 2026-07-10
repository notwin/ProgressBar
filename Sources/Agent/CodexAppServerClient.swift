import Foundation
import CoreFoundation
import Darwin

protocol CodexRPCTransport: Sendable {
    func start() async throws
    func request(method: String, params: Data) async throws -> Data
    func stop() async
}

protocol CodexNotificationTransport: Sendable {
    func setNotificationHandler(_ handler: (@Sendable (Data) async -> Void)?) async
    func requestAndFreezeNotifications(method: String, params: Data) async throws -> Data
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
    case frameTooLarge
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
        let freezesNotifications: Bool
    }

    private let executablePath: String?
    private let requestTimeout: TimeInterval
    private let maximumFrameBytes: Int
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var standardOutputTask: Task<Void, Never>?
    private var standardErrorTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var diagnosticBuffer = Data()
    private var notificationHandler: (@Sendable (Data) async -> Void)?

    init(
        executablePath: String? = CodexExecutableResolver().resolve(),
        requestTimeout: TimeInterval = 5,
        maximumFrameBytes: Int = 1_048_576
    ) {
        self.executablePath = executablePath
        self.requestTimeout = requestTimeout
        self.maximumFrameBytes = maximumFrameBytes
    }

    func start() async throws {
        guard process == nil else { return }
        guard let executablePath,
              FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw CodexTransportError.executableNotFound
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration
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
            Task { await self?.processDidTerminate(terminatedProcess, generation: generation) }
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
        standardOutput = outputHandle
        standardError = errorHandle

        standardOutputTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let data = Self.readPipeChunk(outputHandle, maximumBytes: 4_096),
                      !data.isEmpty else {
                    break
                }
                await self?.consumeStandardOutput(data, generation: generation)
            }
        }
        standardErrorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let data = Self.readPipeChunk(errorHandle, maximumBytes: 4_096),
                      !data.isEmpty else {
                    break
                }
                await self?.consumeStandardError(data, generation: generation)
            }
        }
    }

    func request(method: String, params: Data) async throws -> Data {
        try await performRequest(method: method, params: params, freezesNotifications: false)
    }

    private static func readPipeChunk(_ handle: FileHandle, maximumBytes: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                return Data(buffer.prefix(byteCount))
            }
            if byteCount == 0 {
                return nil
            }
            if errno != EINTR {
                return nil
            }
        }
    }

    func requestAndFreezeNotifications(method: String, params: Data) async throws -> Data {
        try await performRequest(method: method, params: params, freezesNotifications: true)
    }

    private func performRequest(
        method: String,
        params: Data,
        freezesNotifications: Bool
    ) async throws -> Data {
        try Task.checkCancellation()
        guard process != nil, let standardInput else {
            throw CodexTransportError.notStarted
        }
        let generation = connectionGeneration

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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutNanoseconds = UInt64(max(0, requestTimeout) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.expireRequest(id: requestID, generation: generation)
                }
                pendingRequests[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    freezesNotifications: freezesNotifications
                )
                do {
                    try writeLine(object: object, to: standardInput)
                } catch {
                    resumeRequest(
                        id: requestID,
                        result: .failure(CodexTransportError.writeFailed)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: requestID, generation: generation) }
        }
    }

    func setNotificationHandler(_ handler: (@Sendable (Data) async -> Void)?) async {
        notificationHandler = handler
    }

    func stop() async {
        connectionGeneration &+= 1
        let processToStop = process
        let inputToClose = standardInput
        let outputToClose = standardOutput
        let errorToClose = standardError
        let outputTask = standardOutputTask
        let errorTask = standardErrorTask

        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
        standardOutputTask = nil
        standardErrorTask = nil
        notificationHandler = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
        resumeAllPending(with: CodexTransportError.stopped)

        processToStop?.terminationHandler = nil
        try? inputToClose?.close()
        try? outputToClose?.close()
        try? errorToClose?.close()
        if let processToStop, processToStop.isRunning {
            processToStop.terminate()
        }
        outputTask?.cancel()
        errorTask?.cancel()
        await outputTask?.value
        await errorTask?.value
    }

    private func resumeRequest(id: Int, result: Result<Data, Error>) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }

    private func resumeAllPending(with error: Error) {
        let requestIDs = Array(pendingRequests.keys)
        for requestID in requestIDs {
            resumeRequest(id: requestID, result: .failure(error))
        }
    }

    private func cancelRequest(id: Int, generation: UInt64) {
        guard connectionGeneration == generation else { return }
        resumeRequest(id: id, result: .failure(CancellationError()))
    }

    private func expireRequest(id: Int, generation: UInt64) {
        guard connectionGeneration == generation else { return }
        resumeRequest(id: id, result: .failure(CodexTransportError.timeout))
    }

    private func failConnection(
        _ error: CodexTransportError,
        generation: UInt64
    ) {
        guard connectionGeneration == generation else { return }
        connectionGeneration &+= 1
        let processToStop = process
        let inputToClose = standardInput
        let outputToClose = standardOutput
        let errorToClose = standardError
        let outputTask = standardOutputTask
        let errorTask = standardErrorTask

        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
        standardOutputTask = nil
        standardErrorTask = nil
        notificationHandler = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        diagnosticBuffer.removeAll(keepingCapacity: false)
        resumeAllPending(with: error)

        processToStop?.terminationHandler = nil
        try? inputToClose?.close()
        try? outputToClose?.close()
        try? errorToClose?.close()
        if let processToStop, processToStop.isRunning {
            processToStop.terminate()
        }
        outputTask?.cancel()
        errorTask?.cancel()
    }

    private func writeLine(object: Any, to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }


    private func processDidTerminate(
        _ terminatedProcess: Process,
        generation: UInt64
    ) {
        guard connectionGeneration == generation,
              process === terminatedProcess else { return }
        failConnection(.stopped, generation: generation)
    }

    private func consumeStandardOutput(_ data: Data, generation: UInt64) async {
        guard connectionGeneration == generation else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            guard stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: newline)
                    <= maximumFrameBytes else {
                failConnection(.frameTooLarge, generation: generation)
                return
            }
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            await consumeLine(line, generation: generation)
            guard connectionGeneration == generation else { return }
        }
        if stdoutBuffer.count > maximumFrameBytes {
            failConnection(.frameTooLarge, generation: generation)
        }
    }

    private func consumeLine(_ line: Data, generation: UInt64) async {
        guard connectionGeneration == generation else { return }
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            return
        }

        if let requestID = strictRequestID(object["id"]) {
            guard let pending = pendingRequests[requestID] else { return }
            if pending.freezesNotifications {
                notificationHandler = nil
            }
            if let result = object["result"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                resumeRequest(id: requestID, result: .success(data))
            } else if let error = object["error"] as? [String: Any] {
                resumeRequest(
                    id: requestID,
                    result: .failure(CodexTransportError.serverError(code: error["code"] as? Int))
                )
            } else {
                resumeRequest(id: requestID, result: .failure(CodexTransportError.invalidResponse))
            }
            return
        }

        guard object["method"] is String, let notificationHandler else { return }
        await notificationHandler(line)
    }

    private func strictRequestID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.compare(NSNumber(value: Int.min)) != .orderedAscending,
              number.compare(NSNumber(value: Int.max)) != .orderedDescending,
              let requestID = Int(exactly: number.int64Value),
              number.compare(NSNumber(value: requestID)) == .orderedSame
        else {
            return nil
        }
        return requestID
    }

    private func consumeStandardError(_ data: Data, generation: UInt64) {
        guard connectionGeneration == generation else { return }
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

struct CapturedTurnPlan: Equatable, Sendable {
    let turnID: String
    let steps: [TurnPlanStep]
}

private struct CodexTurnPlanUpdatedNotification: Decodable {
    struct Params: Decodable {
        let threadId: String
        let turnId: String
        let plan: [TurnPlanStep]
    }

    let method: String
    let params: Params
}

actor CodexAppServerClient {
    private let transport: any CodexRPCTransport
    private var isStarted = false
    private var plansByThreadID: [String: CapturedTurnPlan] = [:]
    private var isPlanCaptureFrozen = false

    init(transport: any CodexRPCTransport) {
        self.transport = transport
    }

    func start() async throws {
        guard !isStarted else { return }
        plansByThreadID.removeAll()
        isPlanCaptureFrozen = false
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
        plansByThreadID[threadID]?.steps ?? []
    }

    func freezeCapturedPlans() async throws -> [String: CapturedTurnPlan] {
        let params = try JSONSerialization.data(withJSONObject: [
            "archived": false,
            "limit": 1,
            "sortKey": "updated_at",
            "sortDirection": "desc"
        ])
        let response: Data
        if let notificationTransport = transport as? any CodexNotificationTransport {
            response = try await notificationTransport.requestAndFreezeNotifications(
                method: "thread/list",
                params: params
            )
        } else {
            response = try await transport.request(method: "thread/list", params: params)
        }
        _ = try JSONDecoder().decode(CodexThreadListResponse.self, from: response)
        isPlanCaptureFrozen = true
        return plansByThreadID
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
        guard !isPlanCaptureFrozen else { return }
        guard let notification = try? JSONDecoder().decode(
            CodexTurnPlanUpdatedNotification.self,
            from: data
        ), notification.method == "turn/plan/updated" else {
            return
        }
        plansByThreadID[notification.params.threadId] = CapturedTurnPlan(
            turnID: notification.params.turnId,
            steps: notification.params.plan
        )
    }
}
