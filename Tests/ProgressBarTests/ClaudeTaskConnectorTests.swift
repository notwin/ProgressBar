import Foundation
import XCTest
@testable import ProgressBar

final class ClaudeTaskConnectorTests: XCTestCase {
    func testScanBuildsProjectSessionAndTodo() async throws {
        let root = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects"),
            now: { Date(timeIntervalSince1970: 100) }
        )

        let snapshot = try await connector.scan(cursor: nil)

        XCTAssertEqual(snapshot.source, .claude)
        XCTAssertEqual(snapshot.projects[0].displayName, "example")
        XCTAssertEqual(snapshot.projects[0].sessions[0].title, "Integrate local agent tasks")
        XCTAssertEqual(snapshot.projects[0].sessions[0].items[0].status, .inProgress)
        XCTAssertEqual(snapshot.projects[0].sessions[0].items[0].blocks, ["2"])
    }

    func testUnknownStatusFailsSourceScanAsIncompatibleSchema() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let taskURL = root.appendingPathComponent("tasks/session-1/1.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: taskURL)) as? [String: Any]
        )
        object["status"] = "waiting"
        try JSONSerialization.data(withJSONObject: object).write(to: taskURL, options: .atomic)
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects")
        )

        do {
            _ = try await connector.scan(cursor: nil)
            XCTFail("Expected an incompatible-schema error")
        } catch let error as ClaudeTaskConnectorError {
            guard case .incompatibleTaskSchema = error else {
                return XCTFail("Unexpected connector error: \(error)")
            }
        }
    }

    func testKnownJSONWithWrongFieldTypeFailsSourceScanAsIncompatibleSchema() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let taskURL = root.appendingPathComponent("tasks/session-1/1.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: taskURL)) as? [String: Any]
        )
        object["blocks"] = "2"
        try JSONSerialization.data(withJSONObject: object).write(to: taskURL, options: .atomic)
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects")
        )

        do {
            _ = try await connector.scan(cursor: nil)
            XCTFail("Expected an incompatible-schema error")
        } catch let error as ClaudeTaskConnectorError {
            guard case .incompatibleTaskSchema = error else {
                return XCTFail("Unexpected connector error: \(error)")
            }
        }
    }

    func testMalformedSiblingDoesNotHideValidTask() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        try Data("{not valid json".utf8).write(
            to: root.appendingPathComponent("tasks/session-1/bad.json")
        )
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects")
        )

        let snapshot = try await connector.scan(cursor: nil)
        let items = snapshot.projects.flatMap(\.sessions).flatMap(\.items)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].key.itemID, "1")
    }

    func testOversizedTaskRetainsCachedItemEvenWhenCursorFingerprintMatchesFile() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects")
        )
        let first = try await connector.scan(cursor: nil)
        let taskURL = root.appendingPathComponent("tasks/session-1/1.json")
        var oversized = try Data(contentsOf: taskURL)
        oversized.append(Data(repeating: 0x20, count: 1_048_577))
        try oversized.write(to: taskURL, options: .atomic)

        var cursorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(first.cursorData).utf8))
                as? [String: Any]
        )
        var files = try XCTUnwrap(cursorObject["files"] as? [[String: Any]])
        let attributes = try FileManager.default.attributesOfItem(atPath: taskURL.path)
        files[0]["byteSize"] = try XCTUnwrap(attributes[.size] as? NSNumber)
        files[0]["modificationTimestamp"] = try XCTUnwrap(
            attributes[.modificationDate] as? Date
        ).timeIntervalSince1970
        cursorObject["files"] = files
        let forgedCursor = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: cursorObject),
            encoding: .utf8
        ))

        let snapshot = try await connector.scan(cursor: forgedCursor)

        XCTAssertEqual(
            snapshot.projects.flatMap(\.sessions).flatMap(\.items).map(\.key.itemID),
            ["1"]
        )
    }

    func testTaskGrowthAfterFingerprintIsRejectedByActualReadSize() async throws {
        let root = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects"),
            taskDataReader: { url, count in
                XCTAssertEqual(count, 1_048_577)
                var data = try Data(contentsOf: url)
                data.append(Data(repeating: 0x20, count: 1_048_577))
                return data
            }
        )

        let snapshot = try await connector.scan(cursor: nil)

        XCTAssertTrue(snapshot.projects.flatMap(\.sessions).flatMap(\.items).isEmpty)
    }

    func testCachedTaskSurvivesTransientMalformedFileButRealDeletionCompletesIt() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let taskURL = root.appendingPathComponent("tasks/session-1/1.json")
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects")
        )
        let first = try await connector.scan(cursor: nil)

        try Data("{temporarily incomplete".utf8).write(to: taskURL, options: .atomic)
        let transient = try await connector.scan(cursor: first.cursorData)

        XCTAssertEqual(
            transient.projects.flatMap(\.sessions).flatMap(\.items).map(\.key.itemID),
            ["1"]
        )

        try FileManager.default.removeItem(at: taskURL)
        let deleted = try await connector.scan(cursor: transient.cursorData)

        XCTAssertTrue(deleted.projects.flatMap(\.sessions).flatMap(\.items).isEmpty)
    }

    func testUnchangedScanReusesTranscriptContextAndChangedFingerprintRefreshesIt() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let transcriptURL = root.appendingPathComponent("projects/-tmp-example/session-1.jsonl")
        let locatorCount = ClaudeLockedCounter()
        let readCount = ClaudeLockedCounter()
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects"),
            transcriptLocator: { sessionIDs in
                locatorCount.increment()
                return sessionIDs.contains("session-1") ? ["session-1": transcriptURL] : [:]
            },
            transcriptDataReader: { url, count in
                readCount.increment()
                XCTAssertEqual(count, 262_144)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: count) ?? Data()
            }
        )

        let first = try await connector.scan(cursor: nil)
        let unchanged = try await connector.scan(cursor: first.cursorData)

        XCTAssertEqual(locatorCount.value(), 1)
        XCTAssertEqual(readCount.value(), 1)
        XCTAssertEqual(unchanged.projects[0].sessions[0].title, "Integrate local agent tasks")

        try Data(
            #"{"type":"user","cwd":"/tmp/updated","message":{"content":"Updated context"}}"#.utf8
        ).write(to: transcriptURL, options: .atomic)
        let changed = try await connector.scan(cursor: unchanged.cursorData)

        XCTAssertEqual(locatorCount.value(), 1)
        XCTAssertEqual(readCount.value(), 2)
        XCTAssertEqual(changed.projects[0].displayName, "updated")
        XCTAssertEqual(changed.projects[0].sessions[0].title, "Updated context")
    }

    func testNewSessionLocatesAndReadsOnlyItsTranscript() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let firstTranscript = root.appendingPathComponent("projects/-tmp-example/session-1.jsonl")
        let secondTranscript = root.appendingPathComponent("projects/-tmp-next/session-2.jsonl")
        let locatorCount = ClaudeLockedCounter()
        let readCount = ClaudeLockedCounter()
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects"),
            transcriptLocator: { sessionIDs in
                locatorCount.increment()
                var result: [String: URL] = [:]
                if sessionIDs.contains("session-1") { result["session-1"] = firstTranscript }
                if sessionIDs.contains("session-2"), FileManager.default.fileExists(atPath: secondTranscript.path) {
                    result["session-2"] = secondTranscript
                }
                return result
            },
            transcriptDataReader: { url, count in
                readCount.increment()
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: count) ?? Data()
            }
        )
        let first = try await connector.scan(cursor: nil)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tasks/session-2"),
            withIntermediateDirectories: true
        )
        var task = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("tasks/session-1/1.json"))
            ) as? [String: Any]
        )
        task["id"] = "2"
        try JSONSerialization.data(withJSONObject: task).write(
            to: root.appendingPathComponent("tasks/session-2/2.json"),
            options: .atomic
        )
        try FileManager.default.createDirectory(
            at: secondTranscript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"type":"user","cwd":"/tmp/next","message":{"content":"Second session"}}"#.utf8
        ).write(to: secondTranscript)

        let second = try await connector.scan(cursor: first.cursorData)

        XCTAssertEqual(locatorCount.value(), 2)
        XCTAssertEqual(readCount.value(), 2)
        XCTAssertEqual(
            second.projects.flatMap(\.sessions).first { $0.sessionID == "session-2" }?.title,
            "Second session"
        )
    }

    func testUnchangedSessionWithoutTranscriptCachesNegativeLookup() async throws {
        let source = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        let transcriptURL = root.appendingPathComponent("projects/new/session-1.jsonl")
        let locatorCount = ClaudeLockedCounter()
        let readCount = ClaudeLockedCounter()
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects"),
            transcriptLocator: { sessionIDs in
                locatorCount.increment()
                if sessionIDs.contains("session-1"),
                   FileManager.default.fileExists(atPath: transcriptURL.path) {
                    return ["session-1": transcriptURL]
                }
                return [:]
            },
            transcriptDataReader: { url, count in
                readCount.increment()
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: count) ?? Data()
            }
        )

        let first = try await connector.scan(cursor: nil)
        let second = try await connector.scan(cursor: first.cursorData)

        XCTAssertEqual(locatorCount.value(), 1)
        XCTAssertEqual(readCount.value(), 0)
        XCTAssertEqual(second.projects[0].sessions[0].title, "session-")

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"type":"user","cwd":"/tmp/recovered","message":{"content":"Recovered transcript"}}"#.utf8
        ).write(to: transcriptURL)
        let taskURL = root.appendingPathComponent("tasks/session-1/1.json")
        var task = try Data(contentsOf: taskURL)
        task.append(0x20)
        try task.write(to: taskURL, options: .atomic)

        let recovered = try await connector.scan(cursor: second.cursorData)

        XCTAssertEqual(locatorCount.value(), 2)
        XCTAssertEqual(readCount.value(), 1)
        XCTAssertEqual(recovered.projects[0].displayName, "recovered")
        XCTAssertEqual(recovered.projects[0].sessions[0].title, "Recovered transcript")
    }
}

private final class ClaudeLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}
