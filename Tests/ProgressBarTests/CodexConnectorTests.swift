import Foundation
import XCTest
@testable import ProgressBar

final class CodexConnectorTests: XCTestCase {
    func testScanRequestsStableThreadPageAndBuildsGoalItem() async throws {
        let transport = FakeCodexTransport(
            responses: [
                "initialize": [Data(#"{"userAgent":"codex_cli_rs/0.144.1"}"#.utf8)],
                "initialized": [Data(#"{}"#.utf8)],
                "thread/list": [Self.firstThreadPage, Self.barrierPage],
                "thread/goal/get": [Self.activeGoal]
            ]
        )
        let connector = CodexConnector(
            transport: transport,
            now: { Date(timeIntervalSince1970: 300) }
        )

        let snapshot = try await connector.scan(cursor: nil)

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.method), [
            "initialize", "initialized", "thread/list", "thread/goal/get", "thread/list"
        ])
        let request = try XCTUnwrap(requests.first { $0.method == "thread/list" })
        let params = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        XCTAssertEqual(request.method, "thread/list")
        XCTAssertEqual(params["archived"] as? Bool, false)
        XCTAssertEqual(params["limit"] as? Int, 100)
        XCTAssertEqual(params["sortKey"] as? String, "updated_at")
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        let barrierParams = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requests.last?.params ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(barrierParams["limit"] as? Int, 1)

        XCTAssertEqual(snapshot.source, .codex)
        XCTAssertEqual(snapshot.scannedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertEqual(snapshot.projects[0].cwd, "/tmp/ProgressBar")
        XCTAssertEqual(snapshot.projects[0].sessions.count, 1)
        XCTAssertEqual(snapshot.projects[0].sessions[0].title, "Agent integration")
        XCTAssertEqual(snapshot.projects[0].sessions[0].updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(snapshot.projects[0].sessions[0].items.count, 1)

        let goal = snapshot.projects[0].sessions[0].items[0]
        XCTAssertEqual(goal.kind, .goal)
        XCTAssertEqual(goal.title, "Ship the Agent view")
        XCTAssertEqual(goal.status, .inProgress)
        XCTAssertEqual(goal.sourceUpdatedAt, Date(timeIntervalSince1970: 200))
        let startCount = await transport.startCount()
        let stopCount = await transport.stopCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testCapturedPlanNotificationBuildsPlanItemsWithoutGoal() async throws {
        let notification = Data(
            #"{"method":"turn/plan/updated","params":{"threadId":"thread-1","turnId":"turn-1","explanation":null,"plan":[{"step":"Inspect schema","status":"completed"},{"step":"Implement connector","status":"inProgress"}]}}"#.utf8
        )
        let transport = FakeCodexTransport(
            responses: [
                "initialize": [Data(#"{}"#.utf8)],
                "initialized": [Data(#"{}"#.utf8)],
                "thread/list": [Self.firstThreadPage, Self.barrierPage],
                "thread/goal/get": [Data(#"{"goal":null}"#.utf8)]
            ],
            notifications: ["thread/list": [notification]]
        )
        let connector = CodexConnector(transport: transport)

        let snapshot = try await connector.scan(cursor: nil)

        let items = try XCTUnwrap(snapshot.projects.first?.sessions.first?.items)
        XCTAssertEqual(items.map(\.kind), [.planStep, .planStep])
        XCTAssertEqual(items.map(\.title), ["Inspect schema", "Implement connector"])
        XCTAssertEqual(items.map(\.status), [.done, .inProgress])
        XCTAssertEqual(items.map(\.sortOrder), [0, 1])
    }

    func testLatePlanNotificationForEarlierThreadIsCapturedBeforeNormalization() async throws {
        let lateNotification = Data(
            #"{"method":"turn/plan/updated","params":{"threadId":"thread-1","turnId":"turn-1","plan":[{"step":"Arrived late","status":"inProgress"}]}}"#.utf8
        )
        let barrierEntered = TestLatch()
        let releaseBarrier = TestLatch()
        let transport = FakeCodexTransport(
            responses: Self.responses(
                pages: [Self.firstThreadPage],
                goals: [Data(#"{"goal":null}"#.utf8)]
            ),
            blockedRequest: FakeRequestBlock(
                method: "thread/list",
                occurrence: 2,
                entered: barrierEntered,
                release: releaseBarrier
            )
        )

        let scan = Task { try await CodexConnector(transport: transport).scan(cursor: nil) }
        await barrierEntered.wait()
        await Task { await transport.deliverNotification(lateNotification) }.value
        await releaseBarrier.open()

        let snapshot = try await scan.value

        let sessions = try XCTUnwrap(snapshot.projects.first?.sessions)
        XCTAssertEqual(sessions.map(\.sessionID), ["thread-1"])
        XCTAssertEqual(sessions[0].items.map(\.title), ["Arrived late"])
    }

    func testGoalNullWithoutCapturedPlanOmitsThread() async throws {
        let transport = FakeCodexTransport(responses: Self.responses(
            pages: [Self.firstThreadPage],
            goals: [Data(#"{"goal":null}"#.utf8)]
        ))
        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testUnknownGoalStatusFailsClosed() async throws {
        let unknownGoal = Data(
            #"{"goal":{"threadId":"thread-1","objective":"Do not guess","status":"waiting","updatedAt":200000}}"#.utf8
        )
        let transport = FakeCodexTransport(responses: Self.responses(
            pages: [Self.firstThreadPage],
            goals: [unknownGoal]
        ))

        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testGoalWithMismatchedThreadIDFailsClosed() async throws {
        let mismatchedGoal = Data(
            #"{"goal":{"threadId":"other-thread","objective":"Wrong owner","status":"active","updatedAt":200000}}"#.utf8
        )
        let transport = FakeCodexTransport(responses: Self.responses(
            pages: [Self.firstThreadPage],
            goals: [mismatchedGoal]
        ))

        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testRepeatedEmptyPaginationCursorFailsClosed() async throws {
        let repeatedPage = Data(#"{"data":[],"nextCursor":"same-cursor"}"#.utf8)
        let finalPage = Data(#"{"data":[],"nextCursor":null}"#.utf8)
        let transport = FakeCodexTransport(responses: Self.responses(
            pages: [repeatedPage, repeatedPage, finalPage],
            goals: []
        ))

        do {
            _ = try await CodexConnector(transport: transport).scan(cursor: nil)
            XCTFail("Expected pagination to fail closed")
        } catch CodexConnectorError.paginationDidNotProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    func testPaginationStopsAtFiveHundredThreads() async throws {
        var pages: [Data] = []
        var goals: [Data] = []
        for pageIndex in 0..<5 {
            let threads = (0..<100).map { offset -> [String: Any] in
                let index = pageIndex * 100 + offset
                return [
                    "id": "thread-\(index)",
                    "sessionId": "session-\(index)",
                    "name": "Thread \(index)",
                    "preview": "",
                    "cwd": "/tmp/ProgressBar",
                    "updatedAt": index
                ]
            }
            pages.append(try JSONSerialization.data(withJSONObject: [
                "data": threads,
                "nextCursor": "cursor-\(pageIndex + 1)"
            ]))
            for offset in 0..<100 {
                let index = pageIndex * 100 + offset
                goals.append(try JSONSerialization.data(withJSONObject: [
                    "goal": [
                        "threadId": "thread-\(index)",
                        "objective": "Goal \(index)",
                        "status": "active",
                        "updatedAt": index * 1_000
                    ]
                ]))
            }
        }
        let transport = FakeCodexTransport(responses: Self.responses(pages: pages, goals: goals))

        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)

        XCTAssertEqual(snapshot.projects[0].sessions.count, 500)
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.method == "thread/list" }.count, 6)
        XCTAssertEqual(requests.filter { $0.method == "thread/goal/get" }.count, 500)
    }

    func testPlanItemIDsAreIsolatedAcrossTurns() async throws {
        let first = try await Self.planItems(
            turnID: "turn-1",
            steps: [("Implement connector", "inProgress")]
        )
        let second = try await Self.planItems(
            turnID: "turn-2",
            steps: [("Implement connector", "inProgress")]
        )

        XCTAssertNotEqual(first[0].key.itemID, second[0].key.itemID)
    }

    func testPlanItemIDsRemainStableWhenStepIsInsertedAtFront() async throws {
        let original = try await Self.planItems(
            turnID: "turn-1",
            steps: [("Inspect", "completed"), ("Implement", "inProgress")]
        )
        let inserted = try await Self.planItems(
            turnID: "turn-1",
            steps: [
                ("Prepare", "pending"),
                ("Inspect", "completed"),
                ("Implement", "inProgress")
            ]
        )
        let originalIDs = Dictionary(uniqueKeysWithValues: original.map { ($0.title, $0.key.itemID) })
        let insertedIDs = Dictionary(uniqueKeysWithValues: inserted.map { ($0.title, $0.key.itemID) })

        XCTAssertEqual(originalIDs["Inspect"], insertedIDs["Inspect"])
        XCTAssertEqual(originalIDs["Implement"], insertedIDs["Implement"])
        XCTAssertEqual(Set(inserted.map(\.key.itemID)).count, inserted.count)
    }

    func testDuplicatePlanStepTitlesUseDistinctDeterministicOrdinals() async throws {
        let items = try await Self.planItems(
            turnID: "turn-1",
            steps: [("Verify", "pending"), ("Verify", "inProgress")]
        )

        XCTAssertEqual(Set(items.map(\.key.itemID)).count, 2)
        XCTAssertTrue(items[0].key.itemID.hasSuffix("-0"))
        XCTAssertTrue(items[1].key.itemID.hasSuffix("-1"))
    }

    func testScanRequestsSecondPageAndIncludesItsGoal() async throws {
        let firstPage = Data(
            #"{"data":[{"id":"thread-1","sessionId":"session-1","name":"First","preview":"First preview","cwd":"/tmp/ProgressBar","updatedAt":200}],"nextCursor":"cursor-2"}"#.utf8
        )
        let secondPage = Data(
            #"{"data":[{"id":"thread-2","sessionId":"session-2","name":"Second","preview":"Second preview","cwd":"/tmp/ProgressBar/../ProgressBar","updatedAt":300}],"nextCursor":null}"#.utf8
        )
        let secondGoal = Data(
            #"{"goal":{"threadId":"thread-2","objective":"Ship page two","status":"paused","updatedAt":300000}}"#.utf8
        )
        let transport = FakeCodexTransport(responses: Self.responses(
            pages: [firstPage, secondPage],
            goals: [Self.activeGoal, secondGoal]
        ))

        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)

        let listRequests = await transport.requests().filter { $0.method == "thread/list" }
        XCTAssertEqual(listRequests.count, 3)
        let secondParams = try XCTUnwrap(
            JSONSerialization.jsonObject(with: listRequests[1].params) as? [String: Any]
        )
        XCTAssertEqual(secondParams["cursor"] as? String, "cursor-2")
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertEqual(snapshot.projects[0].sessions.map(\.sessionID), ["thread-2", "thread-1"])
        XCTAssertEqual(snapshot.projects[0].sessions[0].items[0].title, "Ship page two")
        XCTAssertEqual(snapshot.projects[0].sessions[0].items[0].status, .blocked)
    }

    func testProcessTransportRejectsMissingExecutable() async {
        let transport = CodexProcessTransport(
            executablePath: "/definitely/missing/progressbar-codex"
        )

        do {
            try await transport.start()
            XCTFail("Expected missing executable")
        } catch CodexTransportError.executableNotFound {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    func testProcessTransportTimesOutUnansweredRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex-stub")
        try Data("#!/bin/sh\nwhile IFS= read -r line; do :; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 0.05
        )
        try await transport.start()

        do {
            _ = try await transport.request(method: "thread/list", params: Data(#"{}"#.utf8))
            XCTFail("Expected request timeout")
        } catch CodexTransportError.timeout {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        await transport.stop()
    }

    func testProcessTransportCorrelatesNumericResponseID() async throws {
        let executable = try Self.makeExecutable(
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{\"id\":1,\"result\":{\"value\":\"ok\"}}'\n"
        )
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 1
        )
        try await transport.start()

        let response = try await transport.request(
            method: "thread/list",
            params: Data(#"{}"#.utf8)
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: String]
        )
        XCTAssertEqual(object["value"], "ok")
        await transport.stop()
    }

    func testBooleanResponseIDDoesNotResumeNumericPendingRequest() async throws {
        try await Self.assertMalformedResponseIDIsIgnored("true")
    }

    func testFractionalResponseIDDoesNotResumeNumericPendingRequest() async throws {
        try await Self.assertMalformedResponseIDIsIgnored("1.9")
    }

    func testOverflowResponseIDDoesNotResumeNumericPendingRequest() async throws {
        try await Self.assertMalformedResponseIDIsIgnored("9223372036854775808")
    }

    func testProcessRequestCancellationResumesWithCancellationError() async throws {
        let executable = try Self.makeExecutable(
            "#!/bin/sh\nwhile IFS= read -r line; do :; done\n"
        )
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 0.1
        )
        try await transport.start()
        let request = Task {
            try await transport.request(method: "thread/list", params: Data(#"{}"#.utf8))
        }
        await Task.yield()

        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        await transport.stop()
    }

    func testOversizedStdoutFrameFailsAndStopsConnection() async throws {
        let executable = try Self.makeExecutable(
            "#!/bin/sh\nIFS= read -r line\ndd if=/dev/zero bs=1024 count=12 2>/dev/null\nsleep 1\n"
        )
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 1,
            maximumFrameBytes: 8_192
        )
        try await transport.start()

        do {
            _ = try await transport.request(method: "thread/list", params: Data(#"{}"#.utf8))
            XCTFail("Expected oversized frame failure")
        } catch CodexTransportError.frameTooLarge {
            // Expected.
        } catch {
            XCTAssertEqual(error as? CodexTransportError, .frameTooLarge)
        }
        await transport.stop()
    }

    func testStopThenRestartIgnoresLateResponseFromOldConnection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counter = directory.appendingPathComponent("counter")
        let firstReady = directory.appendingPathComponent("first-ready")
        let secondReady = directory.appendingPathComponent("second-ready")
        let script = """
        #!/bin/sh
        if [ -f '\(counter.path)' ]; then run=$(cat '\(counter.path)'); else run=0; fi
        run=$((run + 1))
        printf '%s' "$run" > '\(counter.path)'
        IFS= read -r line
        if [ "$run" -eq 1 ]; then
          : > '\(firstReady.path)'
          (sleep 0.05; printf '%s\n' '{"id":1,"result":{"source":"old"}}') &
        else
          : > '\(secondReady.path)'
          (sleep 0.20; printf '%s\n' '{"id":1,"result":{"source":"new"}}') &
        fi
        wait
        """
        let executable = try Self.makeExecutable(script, in: directory)
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 1
        )
        try await transport.start()
        let firstRequest = Task {
            try await transport.request(method: "thread/list", params: Data(#"{}"#.utf8))
        }
        try await Self.waitForFile(firstReady)
        await transport.stop()
        do {
            _ = try await firstRequest.value
            XCTFail("Expected first connection to stop")
        } catch CodexTransportError.stopped {
            // Expected.
        }

        try await transport.start()
        let secondRequest = Task {
            try await transport.request(method: "thread/list", params: Data(#"{}"#.utf8))
        }
        try await Self.waitForFile(secondReady)
        let response = try await secondRequest.value
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: String]
        )
        XCTAssertEqual(object["source"], "new")
        await transport.stop()
    }

    func testProcessTerminationResumesPendingRequestOnce() async throws {
        let executable = try Self.makeExecutable("#!/bin/sh\nIFS= read -r line\nexit 0\n")
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 1
        )
        try await transport.start()

        do {
            _ = try await transport.request(method: "thread/list", params: Data(#"{}"#.utf8))
            XCTFail("Expected stopped transport")
        } catch CodexTransportError.stopped {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        await transport.stop()
    }

    private static let firstThreadPage = Data(
        #"{"data":[{"id":"thread-1","sessionId":"session-1","name":"Agent integration","preview":"Integrate local agent tasks","cwd":"/tmp/ProgressBar","createdAt":100,"updatedAt":200,"cliVersion":"0.144.1","modelProvider":"openai","ephemeral":false,"source":"cli","status":{"type":"idle"},"turns":[]}],"nextCursor":null}"#.utf8
    )

    private static let activeGoal = Data(
        #"{"goal":{"threadId":"thread-1","objective":"Ship the Agent view","status":"active","tokenBudget":null,"tokensUsed":10,"timeUsedSeconds":30,"createdAt":100000,"updatedAt":200000}}"#.utf8
    )

    private static let barrierPage = Data(#"{"data":[],"nextCursor":null}"#.utf8)

    private static func responses(pages: [Data], goals: [Data]) -> [String: [Data]] {
        [
            "initialize": [Data(#"{}"#.utf8)],
            "initialized": [Data(#"{}"#.utf8)],
            "thread/list": pages + [barrierPage],
            "thread/goal/get": goals
        ]
    }

    private static func planItems(
        turnID: String,
        steps: [(String, String)]
    ) async throws -> [AgentItemSnapshot] {
        let plan = steps.map { ["step": $0.0, "status": $0.1] }
        let notification = try JSONSerialization.data(withJSONObject: [
            "method": "turn/plan/updated",
            "params": [
                "threadId": "thread-1",
                "turnId": turnID,
                "plan": plan
            ]
        ])
        let transport = FakeCodexTransport(
            responses: responses(
                pages: [firstThreadPage],
                goals: [Data(#"{"goal":null}"#.utf8)]
            ),
            notifications: ["thread/list": [notification]]
        )
        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)
        return try XCTUnwrap(snapshot.projects.first?.sessions.first?.items)
    }

    private static func makeExecutable(
        _ script: String,
        in directory: URL? = nil
    ) throws -> URL {
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex-stub")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private static func waitForFile(_ url: URL) async throws {
        for _ in 0..<2_000 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FakeCodexTransportError.fileDidNotAppear(url.path)
    }

    private static func assertMalformedResponseIDIsIgnored(_ malformedID: String) async throws {
        let script = """
        #!/bin/sh
        IFS= read -r line
        printf '%s\n' '{"id":\(malformedID),"result":{"value":"malformed"}}'
        printf '%s\n' '{"id":1,"result":{"value":"valid"}}'
        """
        let executable = try makeExecutable(script)
        let transport = CodexProcessTransport(
            executablePath: executable.path,
            requestTimeout: 1
        )
        try await transport.start()

        let response = try await transport.request(
            method: "thread/list",
            params: Data(#"{}"#.utf8)
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: String]
        )
        XCTAssertEqual(object["value"], "valid")
        await transport.stop()
    }
}

private struct FakeRequestBlock: Sendable {
    let method: String
    let occurrence: Int
    let entered: TestLatch
    let release: TestLatch
}

private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FakeCodexTransport: CodexRPCTransport, CodexNotificationTransport {
    struct RecordedRequest: Sendable {
        let method: String
        let params: Data
    }

    private var queuedResponses: [String: [Data]]
    private var recordedRequests: [RecordedRequest] = []
    private var queuedNotifications: [String: [Data]]
    private var notificationHandler: (@Sendable (Data) async -> Void)?
    private var starts = 0
    private var stops = 0
    private var requestCounts: [String: Int] = [:]
    private let blockedRequest: FakeRequestBlock?

    init(
        responses: [String: [Data]],
        notifications: [String: [Data]] = [:],
        blockedRequest: FakeRequestBlock? = nil
    ) {
        queuedResponses = responses
        queuedNotifications = notifications
        self.blockedRequest = blockedRequest
    }

    func start() async throws {
        starts += 1
    }

    func request(method: String, params: Data) async throws -> Data {
        recordedRequests.append(RecordedRequest(method: method, params: params))
        requestCounts[method, default: 0] += 1
        if let blockedRequest,
           blockedRequest.method == method,
           blockedRequest.occurrence == requestCounts[method] {
            await blockedRequest.entered.open()
            await blockedRequest.release.wait()
        }
        if var notifications = queuedNotifications[method],
           !notifications.isEmpty,
           let notificationHandler {
            let notification = notifications.removeFirst()
            queuedNotifications[method] = notifications
            await notificationHandler(notification)
        }
        guard var responses = queuedResponses[method], !responses.isEmpty else {
            throw FakeCodexTransportError.missingResponse(method)
        }
        let response = responses.removeFirst()
        queuedResponses[method] = responses
        return response
    }

    func stop() async {
        stops += 1
    }

    func setNotificationHandler(_ handler: (@Sendable (Data) async -> Void)?) async {
        notificationHandler = handler
    }

    func requestAndFreezeNotifications(method: String, params: Data) async throws -> Data {
        let response = try await request(method: method, params: params)
        notificationHandler = nil
        return response
    }

    func deliverNotification(_ data: Data) async {
        guard let notificationHandler else { return }
        await notificationHandler(data)
    }

    func requests() -> [RecordedRequest] {
        recordedRequests
    }

    func startCount() -> Int {
        starts
    }

    func stopCount() -> Int {
        stops
    }
}

private enum FakeCodexTransportError: Error {
    case missingResponse(String)
    case fileDidNotAppear(String)
}
