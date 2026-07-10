import XCTest
@testable import ProgressBar

@MainActor
final class FakeUserTaskSink: UserTaskAdopting {
    var tasks: [String: TaskItem] = [:]
    var failNextInsert = false

    func containsTask(id: String) -> Bool {
        tasks[id] != nil
    }

    func insertAdoptedTask(
        id: String,
        title: String,
        status: TaskStatus,
        sectionID: String,
        logText: String
    ) -> Bool {
        if failNextInsert {
            failNextInsert = false
            return false
        }
        if tasks[id] != nil { return true }
        tasks[id] = TaskItem(
            id: id,
            title: title,
            status: status,
            deadline: "",
            logs: [LogEntry(id: "log", date: "26.07.10", text: logText)],
            completedAt: nil
        )
        return true
    }
}

@MainActor
final class TestPersistenceManager: PersistenceManager {
    var saveSucceeds: Bool
    private(set) var savedData: [AppData] = []
    private let initialData: AppData

    init(initialData: AppData, saveSucceeds: Bool) {
        self.initialData = initialData
        self.saveSucceeds = saveSucceeds
        super.init()
    }

    override var iCloudAvailable: Bool { false }

    override func load() -> LoadResult {
        .loaded(initialData)
    }

    @discardableResult
    override func save(appData: AppData) -> Bool {
        savedData.append(appData)
        return saveSucceeds
    }
}

final class AgentAdoptionTests: XCTestCase {
    private func makeStore() async throws -> AgentStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await AgentStore(databaseURL: directory.appendingPathComponent("agent.sqlite"))
    }

    @MainActor
    private func makeController(store: AgentStore) -> AgentIntegrationController {
        AgentIntegrationController(store: store, connectors: [], applicationIsActive: false)
    }

    private func makeItem(
        source: AgentSource = .claude,
        status: AgentItemStatus = .inProgress
    ) -> AgentItemSnapshot {
        AgentItemSnapshot(
            key: AgentItemKey(source: source, sessionID: "session-1", itemID: "item-1"),
            kind: .todo,
            title: "Original title",
            description: "",
            status: status,
            sortOrder: 0,
            sourceUpdatedAt: nil,
            blocks: [],
            blockedBy: []
        )
    }

    @MainActor
    private func makeAppState(
        saveSucceeds: Bool,
        sections: [TaskSection]? = nil
    ) -> (state: AppState, persistence: TestPersistenceManager) {
        let initialSections = sections ?? [
            TaskSection(id: "section-1", name: "Work", tasks: [], archived: [])
        ]
        let persistence = TestPersistenceManager(
            initialData: AppData(
                sections: initialSections,
                themeId: "obsidian",
                activeSectionId: initialSections[0].id
            ),
            saveSucceeds: saveSucceeds
        )
        return (
            AppState(persistence: persistence, initializeServices: false),
            persistence
        )
    }

    @MainActor
    func testFirstAdoptionCreatesMappedTaskAndCompletesReservation() async throws {
        let store = try await makeStore()
        let controller = makeController(store: store)
        let sink = FakeUserTaskSink()
        let item = makeItem(source: .codex, status: .blocked)

        let taskID = try await controller.adopt(
            item: item,
            sessionTitle: "Task 6",
            editedTitle: "Review recovery",
            targetSectionID: "section-1",
            taskSink: sink
        )

        XCTAssertEqual(taskID, taskID.lowercased())
        XCTAssertEqual(sink.tasks.count, 1)
        XCTAssertEqual(sink.tasks[taskID]?.title, "Review recovery")
        XCTAssertEqual(sink.tasks[taskID]?.status, .blocked)
        XCTAssertEqual(sink.tasks[taskID]?.logs.map(\.text), ["从 Codex 会话「Task 6」接管"])
        let adoption = try await store.adoption(for: item.key)
        XCTAssertEqual(adoption?.state, .completed)
    }

    @MainActor
    func testRepeatedAdoptionKeepsOneTaskAndReturnsSameID() async throws {
        let store = try await makeStore()
        let controller = makeController(store: store)
        let sink = FakeUserTaskSink()
        let item = makeItem()

        let firstTaskID = try await controller.adopt(
            item: item,
            sessionTitle: "Adoption",
            editedTitle: "First title",
            targetSectionID: "section-1",
            taskSink: sink
        )
        let repeatedTaskID = try await controller.adopt(
            item: item,
            sessionTitle: "Changed session",
            editedTitle: "Changed title",
            targetSectionID: "section-2",
            taskSink: sink
        )

        XCTAssertEqual(repeatedTaskID, firstTaskID)
        XCTAssertEqual(sink.tasks.count, 1)
        XCTAssertEqual(sink.tasks[firstTaskID]?.title, "First title")
        let adoption = try await store.adoption(for: item.key)
        XCTAssertEqual(adoption?.state, .completed)
    }

    @MainActor
    func testInsertFailureMarksReservationFailed() async throws {
        let store = try await makeStore()
        let controller = makeController(store: store)
        let sink = FakeUserTaskSink()
        let item = makeItem()
        sink.failNextInsert = true

        do {
            _ = try await controller.adopt(
                item: item,
                sessionTitle: "Adoption",
                editedTitle: "Will fail",
                targetSectionID: "section-1",
                taskSink: sink
            )
            XCTFail("Expected the user-task write to fail")
        } catch {
            XCTAssertEqual(error as? AgentAdoptionError, .userTaskWriteFailed)
        }

        XCTAssertTrue(sink.tasks.isEmpty)
        let adoption = try await store.adoption(for: item.key)
        XCTAssertEqual(adoption?.state, .failed)
    }

    @MainActor
    func testRetryReusesFailedReservationIDAndCompletesIt() async throws {
        let store = try await makeStore()
        let controller = makeController(store: store)
        let sink = FakeUserTaskSink()
        let item = makeItem(source: .claude, status: .pending)
        sink.failNextInsert = true

        do {
            _ = try await controller.adopt(
                item: item,
                sessionTitle: "Recovery",
                editedTitle: "Retry me",
                targetSectionID: "section-1",
                taskSink: sink
            )
            XCTFail("Expected the first insert to fail")
        } catch {
            XCTAssertEqual(error as? AgentAdoptionError, .userTaskWriteFailed)
        }
        let failedAdoption = try await store.adoption(for: item.key)
        let reservedTaskID = try XCTUnwrap(failedAdoption?.progressBarTaskID)

        let retriedTaskID = try await controller.adopt(
            item: item,
            sessionTitle: "Recovery",
            editedTitle: "Retry me",
            targetSectionID: "section-1",
            taskSink: sink
        )

        XCTAssertEqual(retriedTaskID, reservedTaskID)
        XCTAssertEqual(sink.tasks.count, 1)
        XCTAssertEqual(sink.tasks[retriedTaskID]?.status, .pending)
        XCTAssertEqual(sink.tasks[retriedTaskID]?.logs.map(\.text), ["从 Claude Code 会话「Recovery」接管"])
        let completedAdoption = try await store.adoption(for: item.key)
        XCTAssertEqual(completedAdoption?.state, .completed)
    }

    @MainActor
    func testAppStateAdoptedInsertionRollsBackWhenSaveFails() {
        let (state, persistence) = makeAppState(saveSucceeds: false)

        let inserted = state.insertAdoptedTask(
            id: "fixed-task-id",
            title: "Adopt me",
            status: .inProgress,
            sectionID: "section-1",
            logText: "Initial adoption log"
        )

        XCTAssertFalse(inserted)
        XCTAssertFalse(state.containsTask(id: "fixed-task-id"))
        XCTAssertTrue(state.sections[0].tasks.isEmpty)
        XCTAssertEqual(persistence.savedData.count, 1)
    }

    @MainActor
    func testControllerRetriesAppStateSaveFailureWithSameReservationID() async throws {
        let store = try await makeStore()
        let controller = makeController(store: store)
        let (state, persistence) = makeAppState(saveSucceeds: false)
        let item = makeItem(source: .claude, status: .inProgress)

        do {
            _ = try await controller.adopt(
                item: item,
                sessionTitle: "Persistent recovery",
                editedTitle: "Persist me",
                targetSectionID: "section-1",
                taskSink: state
            )
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? AgentAdoptionError, .userTaskWriteFailed)
        }
        let failedAdoption = try await store.adoption(for: item.key)
        let reservedTaskID = try XCTUnwrap(failedAdoption?.progressBarTaskID)
        XCTAssertEqual(failedAdoption?.state, .failed)
        XCTAssertFalse(state.containsTask(id: reservedTaskID))

        persistence.saveSucceeds = true
        let retriedTaskID = try await controller.adopt(
            item: item,
            sessionTitle: "Persistent recovery",
            editedTitle: "Persist me",
            targetSectionID: "section-1",
            taskSink: state
        )

        XCTAssertEqual(retriedTaskID, reservedTaskID)
        XCTAssertTrue(state.containsTask(id: retriedTaskID))
        XCTAssertEqual(state.sections[0].tasks.count, 1)
        let completedAdoption = try await store.adoption(for: item.key)
        XCTAssertEqual(completedAdoption?.state, .completed)
    }

    @MainActor
    func testAppStateContainsTaskSearchesActiveAndArchivedAcrossAllSections() {
        let active = TaskItem(
            id: "active-task",
            title: "Active",
            status: .pending,
            deadline: "",
            logs: [],
            completedAt: nil
        )
        let archived = TaskItem(
            id: "archived-task",
            title: "Archived",
            status: .done,
            deadline: "",
            logs: [],
            completedAt: "26.07.10"
        )
        let sections = [
            TaskSection(id: "section-1", name: "One", tasks: [], archived: []),
            TaskSection(id: "section-2", name: "Two", tasks: [active], archived: [archived])
        ]
        let (state, _) = makeAppState(saveSucceeds: true, sections: sections)

        XCTAssertTrue(state.containsTask(id: active.id))
        XCTAssertTrue(state.containsTask(id: archived.id))
        XCTAssertFalse(state.containsTask(id: "missing-task"))
    }

    @MainActor
    func testAppStateAdoptedInsertionValidatesAndCreatesOneDatedLog() {
        let (state, persistence) = makeAppState(saveSucceeds: true)

        XCTAssertFalse(state.insertAdoptedTask(
            id: "blank-title",
            title: "  \n ",
            status: .pending,
            sectionID: "section-1",
            logText: "log"
        ))
        XCTAssertFalse(state.insertAdoptedTask(
            id: "missing-section",
            title: "Valid",
            status: .pending,
            sectionID: "missing",
            logText: "log"
        ))
        XCTAssertTrue(state.insertAdoptedTask(
            id: "fixed-task-id",
            title: "  Trimmed title  ",
            status: .done,
            sectionID: "section-1",
            logText: "Initial adoption log"
        ))

        let task = state.sections[0].tasks[0]
        XCTAssertEqual(task.id, "fixed-task-id")
        XCTAssertEqual(task.title, "Trimmed title")
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.deadline, "")
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(task.logs.count, 1)
        XCTAssertEqual(task.logs[0].date, state.today())
        XCTAssertEqual(task.logs[0].text, "Initial adoption log")
        XCTAssertEqual(persistence.savedData.count, 1)

        XCTAssertTrue(state.insertAdoptedTask(
            id: "fixed-task-id",
            title: "Ignored duplicate",
            status: .pending,
            sectionID: "missing",
            logText: "Ignored"
        ))
        XCTAssertEqual(state.sections[0].tasks.count, 1)
        XCTAssertEqual(persistence.savedData.count, 1)
    }

    @MainActor
    func testOrdinaryAddTaskKeepsInMemoryTaskWhenSaveFails() {
        let (state, persistence) = makeAppState(saveSucceeds: false)

        state.addTask(title: "Ordinary", to: "section-1")

        let task = state.sections[0].tasks[0]
        XCTAssertEqual(task.id, task.id.lowercased())
        XCTAssertEqual(task.title, "Ordinary")
        XCTAssertEqual(task.status, .pending)
        XCTAssertEqual(task.deadline, "")
        XCTAssertTrue(task.logs.isEmpty)
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(persistence.savedData.count, 1)
    }
}
