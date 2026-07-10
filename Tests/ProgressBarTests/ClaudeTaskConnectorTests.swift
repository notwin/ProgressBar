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

    func testUnknownStatusFailsClosedWithoutInventingTask() async throws {
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

        let snapshot = try await connector.scan(cursor: nil)

        XCTAssertTrue(snapshot.projects.flatMap(\.sessions).flatMap(\.items).isEmpty)
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

    func testOversizedTaskIsRejectedBeforeCursorReuse() async throws {
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

        XCTAssertTrue(snapshot.projects.flatMap(\.sessions).flatMap(\.items).isEmpty)
    }

    func testTaskGrowthAfterFingerprintIsRejectedByActualReadSize() async throws {
        let root = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Claude"))
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects"),
            taskDataReader: { url, _ in
                var data = try Data(contentsOf: url)
                data.append(Data(repeating: 0x20, count: 1_048_577))
                return data
            }
        )

        let snapshot = try await connector.scan(cursor: nil)

        XCTAssertTrue(snapshot.projects.flatMap(\.sessions).flatMap(\.items).isEmpty)
    }
}
