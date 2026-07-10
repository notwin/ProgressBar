import Foundation
import XCTest
@testable import ProgressBar

final class CodexConnectorTests: XCTestCase {
    func testScanRequestsStableThreadPageAndBuildsGoalItem() async throws {
        let transport = FakeCodexTransport(
            responses: [
                "initialize": [Data(#"{"userAgent":"codex_cli_rs/0.144.1"}"#.utf8)],
                "initialized": [Data(#"{}"#.utf8)],
                "thread/list": [Self.firstThreadPage],
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
            "initialize", "initialized", "thread/list", "thread/goal/get"
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
                "thread/list": [Self.firstThreadPage],
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
        let page = Data(
            #"{"data":[{"id":"thread-1","sessionId":"session-1","name":"First","preview":"","cwd":"/tmp/ProgressBar","updatedAt":200},{"id":"thread-2","sessionId":"session-2","name":"Second","preview":"","cwd":"/tmp/ProgressBar","updatedAt":300}],"nextCursor":null}"#.utf8
        )
        let unrelatedNotification = Data(
            #"{"method":"turn/plan/updated","params":{"threadId":"other-thread","turnId":"turn-0","plan":[{"step":"Ignore","status":"pending"}]}}"#.utf8
        )
        let lateNotification = Data(
            #"{"method":"turn/plan/updated","params":{"threadId":"thread-1","turnId":"turn-1","plan":[{"step":"Arrived late","status":"inProgress"}]}}"#.utf8
        )
        let transport = FakeCodexTransport(
            responses: Self.responses(
                pages: [page],
                goals: [Data(#"{"goal":null}"#.utf8), Data(#"{"goal":null}"#.utf8)]
            ),
            notifications: [
                "thread/goal/get": [unrelatedNotification, lateNotification]
            ]
        )

        let snapshot = try await CodexConnector(transport: transport).scan(cursor: nil)

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
        XCTAssertEqual(listRequests.count, 2)
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

    private static let firstThreadPage = Data(
        #"{"data":[{"id":"thread-1","sessionId":"session-1","name":"Agent integration","preview":"Integrate local agent tasks","cwd":"/tmp/ProgressBar","createdAt":100,"updatedAt":200,"cliVersion":"0.144.1","modelProvider":"openai","ephemeral":false,"source":"cli","status":{"type":"idle"},"turns":[]}],"nextCursor":null}"#.utf8
    )

    private static let activeGoal = Data(
        #"{"goal":{"threadId":"thread-1","objective":"Ship the Agent view","status":"active","tokenBudget":null,"tokensUsed":10,"timeUsedSeconds":30,"createdAt":100000,"updatedAt":200000}}"#.utf8
    )

    private static func responses(pages: [Data], goals: [Data]) -> [String: [Data]] {
        [
            "initialize": [Data(#"{}"#.utf8)],
            "initialized": [Data(#"{}"#.utf8)],
            "thread/list": pages,
            "thread/goal/get": goals
        ]
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

    init(responses: [String: [Data]], notifications: [String: [Data]] = [:]) {
        queuedResponses = responses
        queuedNotifications = notifications
    }

    func start() async throws {
        starts += 1
    }

    func request(method: String, params: Data) async throws -> Data {
        recordedRequests.append(RecordedRequest(method: method, params: params))
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
}
