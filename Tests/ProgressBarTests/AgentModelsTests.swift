import XCTest
@testable import ProgressBar

final class AgentModelsTests: XCTestCase {
    func testCodexGoalStatusMapping() {
        XCTAssertEqual(AgentItemStatus(codexGoalStatus: "active"), .inProgress)
        XCTAssertEqual(AgentItemStatus(codexGoalStatus: "paused"), .blocked)
        XCTAssertEqual(AgentItemStatus(codexGoalStatus: "usageLimited"), .blocked)
        XCTAssertEqual(AgentItemStatus(codexGoalStatus: "complete"), .done)
        XCTAssertNil(AgentItemStatus(codexGoalStatus: "unknown"))
    }

    func testClaudeStatusMapping() {
        XCTAssertEqual(AgentItemStatus(claudeStatus: "pending"), .pending)
        XCTAssertEqual(AgentItemStatus(claudeStatus: "in_progress"), .inProgress)
        XCTAssertEqual(AgentItemStatus(claudeStatus: "completed"), .done)
        XCTAssertNil(AgentItemStatus(claudeStatus: "waiting"))
    }

    func testAdoptionStatusMapsToExistingTaskStatus() {
        XCTAssertEqual(AgentItemStatus.pending.taskStatus, .pending)
        XCTAssertEqual(AgentItemStatus.inProgress.taskStatus, .inProgress)
        XCTAssertEqual(AgentItemStatus.blocked.taskStatus, .blocked)
        XCTAssertEqual(AgentItemStatus.done.taskStatus, .done)
    }
}
