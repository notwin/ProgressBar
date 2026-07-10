# Local Agent Task Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local-only Agent section that mirrors reliable Claude Code and Codex project/session/task state and lets the user idempotently adopt an Agent item into the existing iCloud-synced ProgressBar task store.

**Architecture:** Keep `data.json` and its iCloud behavior unchanged. Two read-only connectors normalize Claude Code task files and Codex app-server data into `agent-index.sqlite`; an `AgentIntegrationController` exposes a hierarchical dashboard to SwiftUI. Adoption is the only bridge into `AppState`, using a recoverable two-phase mapping so repeated clicks cannot create duplicate user tasks.

**Tech Stack:** Swift 5.9+, macOS 14+, SwiftUI/AppKit, Foundation `Process`, SQLite3 C API, newline-delimited JSON-RPC, XCTest, existing `swiftc`/SwiftPM build paths.

## Global Constraints

- Existing `TaskItem`, `TaskSection`, `AppData`, `data.json`, iCloud Drive, EventKit, Quick Input, and MCP semantics remain unchanged except for a new fixed-ID insertion API used by adoption.
- `agent-index.sqlite` lives only at `~/Library/Application Support/ProgressBar/agent-index.sqlite`; it must never be placed in iCloud.
- Reads from `~/.claude` and Codex are strictly read-only; never write source task state or execute transcript content.
- Never persist authentication tokens, full transcripts, terminal output, tool calls, or reasoning content.
- Do not infer tasks from ordinary assistant prose. Missing structured Codex Plan data means the session shows only its reliable session/Goal data.
- Agent history retention is exactly 30 days; adoption mappings are retained.
- Agent-visible polling interval is exactly 10 seconds; Claude filesystem events are debounced for 1 second.
- Source errors preserve the last successful cache and do not clear another source.
- All new UI strings must have identical keys in all 12 existing `.lproj` files.
- Every task follows red-green-refactor, ends with targeted verification, and receives its own commit.

---

## File Map

### New production files

- `Sources/Agent/AgentModels.swift` — normalized source, project, session, item, dashboard, error, and adoption types plus `AgentConnector`.
- `Sources/Agent/AgentStore.swift` — SQLite schema, migrations, transactional snapshot replacement, dashboard queries, scan state, retention, and adoption reservations.
- `Sources/Agent/ClaudeTaskConnector.swift` — Claude task JSON decoding, project/session lookup, fingerprinting, and snapshot normalization.
- `Sources/Agent/CodexAppServerClient.swift` — executable resolution, stdio JSON-RPC transport, initialization, request correlation, timeout, and shutdown.
- `Sources/Agent/CodexConnector.swift` — paginated thread/Goal reads and reliable Codex normalization.
- `Sources/Agent/DirectoryChangeMonitor.swift` — watched-directory dispatch sources and 1-second debounce.
- `Sources/Agent/AgentIntegrationController.swift` — source orchestration, cache publication, polling, foreground/visibility lifecycle, errors, and adoption service.
- `Sources/Views/AgentSectionView.swift` — approved hierarchical project/session/item UI and local history toggle.
- `Sources/Views/AgentAdoptionSheet.swift` — editable title, target section picker, adopt/re-adopt confirmation.
- `Sources/Views/AgentSettingsView.swift` — Codex executable path and connector health.

### New test files and fixtures

- `Tests/ProgressBarTests/AgentModelsTests.swift`
- `Tests/ProgressBarTests/AgentStoreTests.swift`
- `Tests/ProgressBarTests/ClaudeTaskConnectorTests.swift`
- `Tests/ProgressBarTests/CodexConnectorTests.swift`
- `Tests/ProgressBarTests/AgentIntegrationControllerTests.swift`
- `Tests/ProgressBarTests/AgentAdoptionTests.swift`
- `Tests/ProgressBarTests/Fixtures/Claude/tasks/session-1/1.json`
- `Tests/ProgressBarTests/Fixtures/Claude/projects/-tmp-example/session-1.jsonl`

### Existing files modified

- `Package.swift` — link SQLite3, add XCTest target and fixture resources.
- `Scripts/build.sh`, `Scripts/release.sh`, `.github/workflows/release.yml` — compile `Sources/Agent/*.swift`, Agent views, and link `sqlite3`.
- `Sources/App/ProgressBarApp.swift` — own and inject `AgentIntegrationController`, start lifecycle.
- `Sources/Services/AppState.swift` — fixed-ID adopted-task insertion only; virtual Agent navigation remains transient `ContentView` state.
- `Sources/Views/SectionTabBar.swift` — fixed Agent tab after ordinary sections.
- `Sources/Views/ContentView.swift` — switch between ordinary content and `AgentSectionView` without persisting Agent as a section.
- `Sources/Views/SettingsView.swift` — add Agent settings tab.
- `Sources/Localization/*/Localizable.strings` — Agent UI and error copy.
- `README.md`, `README_en.md`, `CHANGELOG.md` — document local Agent index and unchanged iCloud boundary.

---

### Task 1: Test Scaffold and Normalized Agent Domain

**Files:**
- Create: `Sources/Agent/AgentModels.swift`
- Create: `Tests/ProgressBarTests/AgentModelsTests.swift`
- Modify: `Package.swift:6-16`
- Modify: `Scripts/build.sh:15-35`
- Modify: `Scripts/release.sh:68-84`
- Modify: `.github/workflows/release.yml:31-54`

**Interfaces:**
- Consumes: existing `TaskStatus` from `Sources/Models/Models.swift`.
- Produces: `AgentSource`, `AgentItemKind`, `AgentItemStatus`, `AgentItemKey`, `AgentItemSnapshot`, `AgentSessionSnapshot`, `AgentProjectSnapshot`, `AgentSnapshot`, `AgentDashboard`, `AgentSourceState`, `AgentAdoptionRecord`, and `AgentConnector.scan(cursor:) async throws -> AgentSnapshot`.

- [ ] **Step 1: Add the XCTest target and write the failing normalization tests**

Update `Package.swift` so the target declaration is exactly:

```swift
targets: [
    .executableTarget(
        name: "ProgressBar",
        path: "Sources",
        exclude: ["Localization"],
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
        name: "ProgressBarTests",
        dependencies: ["ProgressBar"],
        path: "Tests/ProgressBarTests",
        resources: [.process("Fixtures")]
    )
]
```

Create `AgentModelsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests and verify the expected compile failure**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/progressbar-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/progressbar-swift-cache \
swift test --scratch-path /private/tmp/progressbar-swiftpm --filter AgentModelsTests
```

Expected: FAIL with `cannot find 'AgentItemStatus' in scope`.

- [ ] **Step 3: Implement the complete normalized domain**

Create `AgentModels.swift` with these exact declarations:

```swift
import Foundation

enum AgentSource: String, Codable, CaseIterable, Sendable { case claude, codex }
enum AgentItemKind: String, Codable, Sendable { case goal, planStep = "plan_step", todo }

enum AgentItemStatus: String, Codable, Sendable {
    case pending, inProgress = "in_progress", blocked, done

    init?(claudeStatus: String) {
        switch claudeStatus {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .done
        default: return nil
        }
    }

    init?(codexGoalStatus: String) {
        switch codexGoalStatus {
        case "active": self = .inProgress
        case "paused", "blocked", "usageLimited", "budgetLimited": self = .blocked
        case "complete": self = .done
        default: return nil
        }
    }

    var taskStatus: TaskStatus {
        switch self {
        case .pending: return .pending
        case .inProgress: return .inProgress
        case .blocked: return .blocked
        case .done: return .done
        }
    }
}

struct AgentItemKey: Hashable, Codable, Sendable {
    let source: AgentSource
    let sessionID: String
    let itemID: String
}

struct AgentItemSnapshot: Identifiable, Equatable, Sendable {
    let key: AgentItemKey
    let kind: AgentItemKind
    let title: String
    let description: String
    let status: AgentItemStatus
    let sortOrder: Int
    let sourceUpdatedAt: Date?
    let blocks: [String]
    let blockedBy: [String]
    var id: AgentItemKey { key }
}

struct AgentSessionSnapshot: Identifiable, Equatable, Sendable {
    let source: AgentSource
    let sessionID: String
    let title: String
    let updatedAt: Date
    let items: [AgentItemSnapshot]
    var id: String { "\(source.rawValue):\(sessionID)" }
}

struct AgentProjectSnapshot: Identifiable, Equatable, Sendable {
    let source: AgentSource
    let projectKey: String
    let displayName: String
    let cwd: String
    let sessions: [AgentSessionSnapshot]
    var id: String { "\(source.rawValue):\(projectKey)" }
}

struct AgentSnapshot: Equatable, Sendable {
    let source: AgentSource
    let scannedAt: Date
    let projects: [AgentProjectSnapshot]
    let cursorData: String?
}

struct AgentSourceState: Equatable, Sendable {
    let source: AgentSource
    let lastScanAt: Date?
    let lastSuccessAt: Date?
    let error: String?
}

struct AgentDashboard: Equatable, Sendable {
    let projects: [AgentProjectSnapshot]
    let sourceStates: [AgentSourceState]
    let adoptedKeys: Set<AgentItemKey>
}

enum AgentAdoptionState: String, Codable, Sendable { case pending, completed, failed }
struct AgentAdoptionRecord: Equatable, Sendable {
    let key: AgentItemKey
    let progressBarTaskID: String
    let targetSectionID: String
    let state: AgentAdoptionState
    let adoptedAt: Date
}

protocol AgentConnector: Sendable {
    var source: AgentSource { get }
    func scan(cursor: String?) async throws -> AgentSnapshot
}
```

- [ ] **Step 4: Update all three manual compiler paths**

Add `"$SRC"/Agent/*.swift` after model files, add future Agent view globs only when those files exist in Task 7, and add `-lsqlite3` before `-o` in `build.sh`, `release.sh`, and the workflow. This task must leave all current sources compiling.

- [ ] **Step 5: Run focused and baseline builds**

Run the focused test command from Step 2. Expected: `3 tests` PASS.

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/progressbar-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/progressbar-swift-cache \
swift build --scratch-path /private/tmp/progressbar-swiftpm
```

Expected: `Build complete!`.

- [ ] **Step 6: Commit the domain scaffold**

```bash
git add Package.swift Sources/Agent/AgentModels.swift Tests/ProgressBarTests/AgentModelsTests.swift Scripts/build.sh Scripts/release.sh .github/workflows/release.yml
git commit -m "feat: add normalized agent task domain"
```

---

### Task 2: Local SQLite Agent Store

**Files:**
- Create: `Sources/Agent/AgentStore.swift`
- Create: `Tests/ProgressBarTests/AgentStoreTests.swift`

**Interfaces:**
- Consumes: all Task 1 snapshots and keys.
- Produces: `AgentStore.init(databaseURL:now:)`, `apply(snapshot:)`, `cursor(for:)`, `recordFailure(source:message:at:)`, `dashboard(includeHistory:)`, `reserveAdoption(...)`, `completeAdoption(key:)`, `failAdoption(key:)`, and `pruneHistory(before:)`.

- [ ] **Step 1: Write failing store migration and idempotency tests**

Create `AgentStoreTests.swift` with a temporary database helper and these tests:

```swift
import XCTest
@testable import ProgressBar

final class AgentStoreTests: XCTestCase {
    private func makeStore() async throws -> AgentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await AgentStore(databaseURL: dir.appendingPathComponent("agent.sqlite"))
    }

    func testApplyingSameSnapshotTwiceIsIdempotent() async throws {
        let store = try await makeStore()
        let snapshot = AgentFixtures.snapshot(status: .inProgress)
        try await store.apply(snapshot: snapshot)
        try await store.apply(snapshot: snapshot)
        let dashboard = try await store.dashboard(includeHistory: false)
        XCTAssertEqual(dashboard.projects.count, 1)
        XCTAssertEqual(dashboard.projects[0].sessions[0].items.count, 1)
    }

    func testFailureKeepsLastSuccessfulRows() async throws {
        let store = try await makeStore()
        try await store.apply(snapshot: AgentFixtures.snapshot(status: .pending))
        try await store.recordFailure(source: .claude, message: "decode failed", at: Date())
        let dashboard = try await store.dashboard(includeHistory: false)
        XCTAssertEqual(dashboard.projects[0].sessions[0].items[0].status, .pending)
        XCTAssertEqual(dashboard.sourceStates.first?.error, "decode failed")
    }

    func testCompletedRowsAreHiddenFromActiveDashboard() async throws {
        let store = try await makeStore()
        try await store.apply(snapshot: AgentFixtures.snapshot(status: .done))
        let active = try await store.dashboard(includeHistory: false)
        let history = try await store.dashboard(includeHistory: true)
        XCTAssertTrue(active.projects.isEmpty)
        XCTAssertEqual(history.projects.count, 1)
    }

    func testCorruptDatabaseIsBackedUpAndRebuilt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent.sqlite")
        try Data("not a sqlite database".utf8).write(to: url)
        let store = try await AgentStore(databaseURL: url)
        let dashboard = try await store.dashboard(includeHistory: false)
        XCTAssertTrue(dashboard.projects.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("agent.sqlite.corrupt.") }.count, 1)
    }
}
```

Add `AgentFixtures.snapshot(status:)` at the bottom of the test file, returning one Claude project/session/item with fixed IDs.

- [ ] **Step 2: Run the focused tests and verify failure**

Run the Task 1 `swift test` command with `--filter AgentStoreTests`.

Expected: FAIL because `AgentStore` does not exist.

- [ ] **Step 3: Implement schema migration and SQLite safety helpers**

Create `AgentStore.swift` as an `actor`. Open with `sqlite3_open_v2(..., SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)`, execute `PRAGMA foreign_keys = ON`, then run a version-1 migration inside `BEGIN IMMEDIATE`.

If opening, `PRAGMA integrity_check`, or migration returns `SQLITE_NOTADB`/`SQLITE_CORRUPT`, close the handle, move the original file to `agent.sqlite.corrupt.<unix-seconds>`, and create a fresh database once. Any second failure is returned to the controller; never touch `data.json`.

The migration must create the six tables from the design with these required constraints:

```sql
CREATE TABLE schema_version(version INTEGER NOT NULL);
CREATE TABLE agent_projects(
  id TEXT PRIMARY KEY, source TEXT NOT NULL, source_project_key TEXT NOT NULL,
  display_name TEXT NOT NULL, cwd TEXT NOT NULL, last_seen_at REAL NOT NULL,
  UNIQUE(source, source_project_key)
);
CREATE TABLE agent_sessions(
  id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES agent_projects(id) ON DELETE CASCADE,
  source TEXT NOT NULL, source_session_id TEXT NOT NULL, title TEXT NOT NULL,
  source_updated_at REAL NOT NULL, last_seen_at REAL NOT NULL,
  UNIQUE(source, source_session_id)
);
CREATE TABLE agent_items(
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
  source TEXT NOT NULL, source_session_id TEXT NOT NULL, source_item_id TEXT NOT NULL,
  kind TEXT NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL,
  status TEXT NOT NULL, sort_order INTEGER NOT NULL,
  source_updated_at REAL, last_seen_at REAL NOT NULL, completed_at REAL,
  UNIQUE(source, source_session_id, source_item_id)
);
CREATE TABLE agent_item_links(
  item_id TEXT NOT NULL REFERENCES agent_items(id) ON DELETE CASCADE,
  related_source_item_id TEXT NOT NULL, relation TEXT NOT NULL,
  UNIQUE(item_id, related_source_item_id, relation)
);
CREATE TABLE agent_adoptions(
  source TEXT NOT NULL, source_session_id TEXT NOT NULL, source_item_id TEXT NOT NULL,
  progressbar_task_id TEXT NOT NULL, target_section_id TEXT NOT NULL,
  state TEXT NOT NULL, adopted_at REAL NOT NULL,
  UNIQUE(source, source_session_id, source_item_id)
);
CREATE TABLE agent_scan_state(
  source TEXT PRIMARY KEY, connector_version TEXT NOT NULL,
  last_scan_at REAL, last_success_at REAL, last_error TEXT, cursor_data TEXT
);
```

Use prepared statements and `SQLITE_TRANSIENT`; no interpolated task text may enter SQL strings.

- [ ] **Step 4: Implement transactional snapshot replacement and dashboard reads**

`apply(snapshot:)` must:

1. `BEGIN IMMEDIATE`.
2. Upsert projects, sessions, items, and links using deterministic UUID strings derived from source keys.
3. Set `completed_at` only when status first becomes `done`; clear it if the same source item later reopens.
4. Delete/reinsert links only for items present in the successful snapshot.
5. Update `agent_scan_state.last_scan_at`, `last_success_at`, `cursor_data = snapshot.cursorData`, and clear `last_error`.
6. Mark source rows not seen in this successful snapshot as done/history without deleting adoption mappings.
7. Commit; rollback on any error.

`dashboard(includeHistory:)` must reconstruct nested snapshots, sort projects/sessions by newest update descending, sort items by `sort_order`, and return adopted keys plus both source states.

- [ ] **Step 5: Implement failure, retention, and adoption APIs**

Use these signatures:

```swift
func recordFailure(source: AgentSource, message: String, at: Date) throws
func cursor(for source: AgentSource) throws -> String?
func reserveAdoption(key: AgentItemKey, taskID: String, sectionID: String, at: Date) throws -> AgentAdoptionRecord
func completeAdoption(key: AgentItemKey) throws
func failAdoption(key: AgentItemKey) throws
func adoption(for key: AgentItemKey) throws -> AgentAdoptionRecord?
func pruneHistory(before cutoff: Date) throws
```

`reserveAdoption` returns the existing record on a uniqueness conflict instead of replacing its task ID. `pruneHistory` deletes completed items older than cutoff and cascading empty sessions/projects, but never deletes `agent_adoptions`.

- [ ] **Step 6: Run store tests and the complete test suite**

Run `swift test` with `--filter AgentStoreTests`; expected: 4 tests PASS. Then run the unfiltered Task 1 command; expected: all tests PASS.

- [ ] **Step 7: Commit the SQLite store**

```bash
git add Sources/Agent/AgentStore.swift Tests/ProgressBarTests/AgentStoreTests.swift
git commit -m "feat: add local agent sqlite store"
```

---

### Task 3: Claude Code Read-Only Connector

**Files:**
- Create: `Sources/Agent/ClaudeTaskConnector.swift`
- Create: `Tests/ProgressBarTests/ClaudeTaskConnectorTests.swift`
- Create: `Tests/ProgressBarTests/Fixtures/Claude/tasks/session-1/1.json`
- Create: `Tests/ProgressBarTests/Fixtures/Claude/projects/-tmp-example/session-1.jsonl`

**Interfaces:**
- Consumes: `AgentConnector`, normalized snapshots.
- Produces: `ClaudeTaskConnector.init(tasksRoot:projectsRoot:now:)` and a source `.claude` snapshot.

- [ ] **Step 1: Add realistic, non-sensitive fixtures**

`1.json`:

```json
{
  "id": "1",
  "subject": "Add local agent index",
  "description": "Persist normalized task state in a rebuildable SQLite cache.",
  "activeForm": "Adding local agent index",
  "status": "in_progress",
  "blocks": ["2"],
  "blockedBy": []
}
```

`session-1.jsonl`:

```jsonl
{"type":"user","sessionId":"session-1","cwd":"/tmp/example","message":{"role":"user","content":"Integrate local agent tasks"}}
```

- [ ] **Step 2: Write failing connector tests**

```swift
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
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: taskURL)) as? [String: Any])
        object["status"] = "waiting"
        try JSONSerialization.data(withJSONObject: object).write(to: taskURL, options: .atomic)
        let connector = ClaudeTaskConnector(
            tasksRoot: root.appendingPathComponent("tasks"),
            projectsRoot: root.appendingPathComponent("projects")
        )
        let snapshot = try await connector.scan(cursor: nil)
        XCTAssertTrue(snapshot.projects.flatMap(\.sessions).flatMap(\.items).isEmpty)
    }
}
```

For the second test, implement the fixture copy and JSON mutation explicitly with `JSONSerialization`; do not modify Bundle resources in place.

- [ ] **Step 3: Run tests and verify failure**

Run the standard test command with `--filter ClaudeTaskConnectorTests`.

Expected: FAIL because `ClaudeTaskConnector` is undefined.

- [ ] **Step 4: Implement strict decoding and project lookup**

Use a private Codable DTO:

```swift
private struct ClaudeTaskFile: Decodable {
    let id: String
    let subject: String
    let description: String
    let activeForm: String?
    let status: String
    let blocks: [String]
    let blockedBy: [String]
}
```

Implementation requirements:

- Enumerate only `<session-id>/*.json`; ignore `.lock` and `.highwatermark`.
- Reject files larger than 1 MiB.
- Decode each file independently; collect valid items even when a sibling is malformed.
- Locate `<session-id>.jsonl` with a cached `[sessionID: URL]` index of `projectsRoot`.
- Read at most the first 256 KiB of the transcript and stop at the first user record containing `cwd` and textual content.
- Fallback title is the first eight characters of session ID; fallback project key is the transcript parent directory.
- Normalize `cwd` with `URL.standardizedFileURL.path`; display name is its last path component.
- Use file modification date as `sourceUpdatedAt` and session max update.
- Encode a JSON cursor containing each task file's path, byte size, and modification timestamp. On the next `scan(cursor:)`, reuse the prior normalized item only when the fingerprint is unchanged; rescan changed/new files and omit deleted files. Return the new cursor in `AgentSnapshot.cursorData`.

- [ ] **Step 5: Add malformed sibling coverage**

Add a third test that places one valid and one invalid JSON in the same session. Expected: the valid item remains present and scan succeeds.

- [ ] **Step 6: Run connector and full tests**

Expected: Claude connector tests PASS; full suite PASS.

- [ ] **Step 7: Commit the Claude connector**

```bash
git add Sources/Agent/ClaudeTaskConnector.swift Tests/ProgressBarTests/ClaudeTaskConnectorTests.swift Tests/ProgressBarTests/Fixtures/Claude
git commit -m "feat: index claude code task files"
```

---

### Task 4: Codex App-Server Client and Connector

**Files:**
- Create: `Sources/Agent/CodexAppServerClient.swift`
- Create: `Sources/Agent/CodexConnector.swift`
- Create: `Tests/ProgressBarTests/CodexConnectorTests.swift`

**Interfaces:**
- Consumes: normalized Agent domain.
- Produces: `CodexRPCTransport`, `CodexProcessTransport`, `CodexAppServerClient`, `CodexExecutableResolver`, and `CodexConnector`.

- [ ] **Step 1: Write a fake transport and failing pagination/Goal tests**

Use a non-generic transport contract so it can be injected:

```swift
protocol CodexRPCTransport: Sendable {
    func start() async throws
    func request(method: String, params: Data) async throws -> Data
    func stop() async
}
```

The fake transport returns exact JSON for:

```json
{"data":[{"id":"thread-1","sessionId":"session-1","name":"Agent integration","preview":"Integrate local agent tasks","cwd":"/tmp/ProgressBar","createdAt":100,"updatedAt":200,"cliVersion":"0.144.1","modelProvider":"openai","ephemeral":false,"source":"cli","status":{"type":"idle"},"turns":[]}],"nextCursor":null}
```

and:

```json
{"goal":{"threadId":"thread-1","objective":"Ship the Agent view","status":"active","tokenBudget":null,"tokensUsed":10,"timeUsedSeconds":30,"createdAt":100000,"updatedAt":200000}}
```

Tests must assert pagination params include `archived:false`, `limit:100`, `sortKey:"updated_at"`, `sortDirection:"desc"`, and that the Goal becomes one `.goal/.inProgress` item.

- [ ] **Step 2: Run tests and verify failure**

Run with `--filter CodexConnectorTests`.

Expected: FAIL because Codex client types are missing.

- [ ] **Step 3: Implement exact Codable app-server DTOs**

Implement only fields required by this feature:

```swift
struct CodexThreadListResponse: Decodable { let data: [CodexThread]; let nextCursor: String? }
struct CodexThread: Decodable {
    let id: String; let sessionId: String; let name: String?; let preview: String
    let cwd: String; let updatedAt: Int64
}
struct CodexGoalResponse: Decodable { let goal: CodexGoal? }
struct CodexGoal: Decodable {
    let threadId: String; let objective: String; let status: String; let updatedAt: Int64
}
```

Keep unknown `source`, `status`, and turn item fields decodable by omitting them from these DTOs. Treat thread timestamps as seconds and Goal timestamps as milliseconds, matching the generated `0.144.1` schema.

- [ ] **Step 4: Implement the connector using paginated stable reads**

`CodexConnector.scan(cursor:)` must:

1. Start the client and initialize once.
2. Page `thread/list` until `nextCursor == nil` or 500 threads, whichever comes first.
3. Call `thread/goal/get` for each candidate.
4. Include sessions when a non-complete Goal exists. Also include structured Plan steps only when `CodexAppServerClient` actually received a `turn/plan/updated` notification for that thread during the connection; expose them through `capturedPlanSteps(threadID:) -> [TurnPlanStep]`.
5. Never call `turn/start`, `thread/resume`, or mutating endpoints.
6. Group by standardized `cwd`; title preference is non-empty `name`, then non-empty `preview`, then first eight thread-id characters.
7. Stop the client in `defer` on success or error.

Do not parse `PlanThreadItem.text`; it lacks structured step status. Decode `turn/plan/updated` into `TurnPlanStep { step, status }`, cache the latest notification by `threadId` for the lifetime of the connection, and normalize only those captured steps. A thread with neither a non-complete Goal nor captured structured steps is omitted.

- [ ] **Step 5: Implement the stdio process transport**

`CodexExecutableResolver` checks:

1. `UserDefaults.standard.string(forKey: "agent.codexExecutablePath")`.
2. `/opt/homebrew/bin/codex`.
3. `/usr/local/bin/codex`.
4. `~/.local/bin/codex`.

`CodexProcessTransport` launches `[codexPath, "app-server", "--listen", "stdio://"]`, writes one JSON object per line, reads stdout on a dedicated actor/task, correlates numeric `id`, enforces a 5-second request timeout, sends:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"progressbar","title":"ProgressBar","version":"1.0"}}}
{"method":"initialized","params":{}}
```

Stderr goes to a bounded 32 KiB diagnostic buffer. `stop()` closes stdin, terminates the process, resumes pending continuations with `CodexTransportError.stopped`, and never prints auth data.

- [ ] **Step 6: Add failure tests**

Cover: missing executable, timeout, `goal:null`, unknown Goal status, and second page. Unknown status must omit the Goal rather than guessing.

- [ ] **Step 7: Run tests and a read-only local smoke check**

Run focused/full tests. Then run:

```bash
codex app-server generate-json-schema --out /private/tmp/progressbar-codex-schema-smoke
```

Expected: exit 0 and generated schema files. Do not start a turn or modify a Codex thread.

- [ ] **Step 8: Commit the Codex connector**

```bash
git add Sources/Agent/CodexAppServerClient.swift Sources/Agent/CodexConnector.swift Tests/ProgressBarTests/CodexConnectorTests.swift
git commit -m "feat: read codex goals through app server"
```

---

### Task 5: Refresh Orchestration, File Monitoring, and Cache Publication

**Files:**
- Create: `Sources/Agent/DirectoryChangeMonitor.swift`
- Create: `Sources/Agent/AgentIntegrationController.swift`
- Create: `Tests/ProgressBarTests/AgentIntegrationControllerTests.swift`
- Modify: `Sources/App/ProgressBarApp.swift:122-134`

**Interfaces:**
- Consumes: connectors and `AgentStore`.
- Produces: `@MainActor AgentIntegrationController` with `dashboard`, `isRefreshing`, `showingHistory`, `refresh()`, `setVisible(_:)`, `start()`, and `stop()`.

- [ ] **Step 1: Write failing source-isolation and visibility tests**

Create fakes: one connector returns a snapshot, the other throws. Inject a temporary store and assert:

```swift
func testOneSourceFailureDoesNotHideOtherSource() async throws {
    let controller = try await makeController(
        connectors: [SuccessfulConnector(source: .claude), FailingConnector(source: .codex)]
    )
    await controller.refresh()
    XCTAssertEqual(controller.dashboard.projects.first?.source, .claude)
    XCTAssertNotNil(controller.dashboard.sourceStates.first { $0.source == .codex }?.error)
}

func testRefreshCoalescesConcurrentRequests() async throws {
    let connector = CountingConnector()
    let controller = try await makeController(connectors: [connector])
    async let first: Void = controller.refresh()
    async let second: Void = controller.refresh()
    _ = await (first, second)
    XCTAssertEqual(await connector.maximumConcurrentScans, 1)
}
```

- [ ] **Step 2: Run and verify failure**

Run with `--filter AgentIntegrationControllerTests`; expected: missing controller types.

- [ ] **Step 3: Implement directory monitoring with exact debounce**

`DirectoryChangeMonitor` owns dispatch sources for the tasks root and current session subdirectories. On `.write`, `.rename`, or `.delete`, it cancels the prior `DispatchWorkItem` and schedules one callback exactly 1 second later on a private serial queue. `stop()` cancels sources and closes descriptors. Refreshing the watched session list must not leak old descriptors.

- [ ] **Step 4: Implement controller refresh semantics**

Use this state surface:

```swift
@MainActor
final class AgentIntegrationController: ObservableObject {
    @Published private(set) var dashboard = AgentDashboard(projects: [], sourceStates: [], adoptedKeys: [])
    @Published private(set) var isRefreshing = false
    @Published var showingHistory = false

    func start()
    func stop()
    func setVisible(_ visible: Bool)
    func refresh() async
}
```

`AgentIntegrationController.live()` constructs the store at `PersistenceManager.localDir.appendingPathComponent("agent-index.sqlite")`, Claude roots under the current user's home directory, and a Codex connector using `CodexExecutableResolver`. It catches store initialization errors into a disabled controller state; it never falls back to an iCloud URL.

Requirements:

- `start()` triggers one asynchronous refresh and registers app active/inactive notifications.
- `setVisible(true)` starts a 10-second timer; false invalidates it.
- App inactive invalidates polling; active restarts only when Agent is visible.
- Each connector scans independently: read `let cursor = try await store.cursor(for: connector.source)`, call `connector.scan(cursor: cursor)`, apply successes, and call `store.recordFailure` for failures.
- A refresh requested during a running refresh sets `refreshPending`; exactly one additional pass runs afterward.
- After every pass, call `pruneHistory(before: now - 30 days)` and reload the dashboard using `showingHistory`.
- All store/file/process work stays off the main actor; only published assignments return to main actor.

- [ ] **Step 5: Inject the live controller without changing user data initialization**

In `ProgressBarApp`, add:

```swift
@StateObject private var agents = AgentIntegrationController.live()
```

Pass it to `ContentView(state:updater:agents:)`. Do not start scanning from `AppState.init()`; call `agents.start()` from the root view lifecycle so Agent failure cannot block `data.json` load.

- [ ] **Step 6: Run controller/full tests and compile**

Expected: focused tests PASS, full suite PASS, Swift build PASS.

- [ ] **Step 7: Commit orchestration**

```bash
git add Sources/Agent/DirectoryChangeMonitor.swift Sources/Agent/AgentIntegrationController.swift Tests/ProgressBarTests/AgentIntegrationControllerTests.swift Sources/App/ProgressBarApp.swift
git commit -m "feat: orchestrate local agent refresh"
```

---

### Task 6: Recoverable, Idempotent Task Adoption

**Files:**
- Modify: `Sources/Services/AppState.swift:214-226`
- Modify: `Sources/Agent/AgentIntegrationController.swift`
- Create: `Tests/ProgressBarTests/AgentAdoptionTests.swift`

**Interfaces:**
- Consumes: `AgentStore.reserveAdoption`, normalized status, existing `TaskItem` and sections.
- Produces: `UserTaskAdopting`, `AppState.containsTask(id:)`, `AppState.insertAdoptedTask(...)`, and `AgentIntegrationController.adopt(...)`.

- [ ] **Step 1: Write failing two-phase recovery tests with a fake user-task sink**

Define in the test:

```swift
@MainActor
final class FakeUserTaskSink: UserTaskAdopting {
    var tasks: [String: TaskItem] = [:]
    var failNextInsert = false
    func containsTask(id: String) -> Bool { tasks[id] != nil }
    func insertAdoptedTask(id: String, title: String, status: TaskStatus, sectionID: String, logText: String) -> Bool {
        if failNextInsert { failNextInsert = false; return false }
        if tasks[id] != nil { return true }
        tasks[id] = TaskItem(id: id, title: title, status: status, deadline: "", logs: [LogEntry(id: "log", date: "26.07.10", text: logText)], completedAt: nil)
        return true
    }
}
```

Test: first adoption succeeds and creates one task; repeated adoption keeps one task and the same ID; simulated insert failure leaves a pending/failed reservation; retry reuses the reservation ID and completes it.

- [ ] **Step 2: Run and verify failure**

Run with `--filter AgentAdoptionTests`; expected: missing protocol/methods.

- [ ] **Step 3: Add the narrow AppState adoption surface**

In production code:

```swift
@MainActor
protocol UserTaskAdopting: AnyObject {
    func containsTask(id: String) -> Bool
    @discardableResult
    func insertAdoptedTask(id: String, title: String, status: TaskStatus, sectionID: String, logText: String) -> Bool
}
```

Make `AppState` conform. `containsTask` searches active and archived tasks across all sections. `insertAdoptedTask` validates section ID and non-empty trimmed title, returns true without writing if the ID already exists, inserts at index 0, adds exactly one initial log using `today()`, calls existing `save()`, and returns false if validation fails.

Refactor ordinary `addTask(title:to:)` to call a shared private insertion helper while preserving its current generated ID, pending status, empty logs, animation, and save behavior.

- [ ] **Step 4: Implement two-phase adoption in the controller**

Use:

```swift
func adopt(
    item: AgentItemSnapshot,
    sessionTitle: String,
    editedTitle: String,
    targetSectionID: String,
    taskSink: UserTaskAdopting
) async throws -> String
```

Algorithm:

1. Ask store for existing adoption; otherwise reserve with a newly generated lowercase UUID.
2. If sink already contains that task ID, mark completed and return it.
3. Insert with mapped status and log `从 <Claude Code|Codex> 会话「<sessionTitle>」接管`.
4. On false, mark failed and throw `AgentAdoptionError.userTaskWriteFailed`.
5. On success, mark completed, reload dashboard, return task ID.

- [ ] **Step 5: Run adoption/full tests**

Expected: normal, duplicate, failure, and retry tests PASS; full suite PASS.

- [ ] **Step 6: Commit adoption**

```bash
git add Sources/Services/AppState.swift Sources/Agent/AgentIntegrationController.swift Tests/ProgressBarTests/AgentAdoptionTests.swift
git commit -m "feat: adopt agent items idempotently"
```

---

### Task 7: Approved Hierarchical Agent UI and Settings

**Files:**
- Create: `Sources/Views/AgentSectionView.swift`
- Create: `Sources/Views/AgentAdoptionSheet.swift`
- Create: `Sources/Views/AgentSettingsView.swift`
- Modify: `Sources/Views/SectionTabBar.swift:18-92`
- Modify: `Sources/Views/ContentView.swift:9-131`
- Modify: `Sources/Views/SettingsView.swift:8-10,130-146`
- Modify: `Sources/App/ProgressBarApp.swift:128-134`
- Modify: `Scripts/build.sh`, `Scripts/release.sh`, `.github/workflows/release.yml`

**Interfaces:**
- Consumes: controller dashboard/adoption, existing `ThemeColors` and `AppState.sections`.
- Produces: fixed Agent virtual tab, approved nested UI, history, refresh, errors, adoption sheet, and Codex path setting.

- [ ] **Step 1: Add controller-derived UI state tests before views**

Add these exact tests to `AgentIntegrationControllerTests`:

```swift
func testActiveItemCountExcludesCompletedItems() async throws {
    let controller = try await makeController(connectors: [
        SnapshotConnector(items: [
            AgentFixtures.item(id: "pending", status: .pending),
            AgentFixtures.item(id: "done", status: .done)
        ])
    ])
    await controller.refresh()
    XCTAssertEqual(controller.activeItemCount, 1)
}

func testHistoryToggleReloadsCompletedSessions() async throws {
    let controller = try await makeController(connectors: [
        SnapshotConnector(items: [AgentFixtures.item(id: "done", status: .done)])
    ])
    await controller.refresh()
    XCTAssertTrue(controller.dashboard.projects.isEmpty)
    await controller.setShowingHistory(true)
    XCTAssertEqual(controller.dashboard.projects.count, 1)
}

func testDashboardSortsNewestProjectFirst() async throws {
    let controller = try await makeController(connectors: [OrderedSnapshotConnector()])
    await controller.refresh()
    XCTAssertEqual(controller.dashboard.projects.map(\.displayName), ["newer", "older"])
}
```

Add `activeItemCount: Int` and `setShowingHistory(_:) async` only after these tests fail.

- [ ] **Step 2: Run and verify failure**

Run focused tests; expected: missing navigation/count APIs.

- [ ] **Step 3: Implement the fixed Agent tab**

Give `SectionTabBar` an `@ObservedObject var agents: AgentIntegrationController` and `@Binding var showingAgent: Bool`. Keep the existing ordinary `ForEach`, set `showingAgent = false` before ordinary section selection, then add this button before the plus button:

```swift
Button { showingAgent = true } label: {
    HStack(spacing: 4) {
        Image(systemName: "sparkles")
        Text(L("agent.tab"))
        if agents.activeItemCount > 0 { Text("\(agents.activeItemCount)") }
    }
    .padding(.horizontal, 12).padding(.vertical, 5)
    .background(showingAgent ? theme.accent : Color.clear)
    .foregroundColor(showingAgent ? .white : theme.t2)
    .cornerRadius(8)
}
.buttonStyle(.plain)
```

`ContentView` owns `@State private var showingAgent = false` and passes the binding. Add `.onChange(of: state.activeSectionId) { showingAgent = false }`, so `cycleSection` and ⌘1–⌘9 return to ordinary sections. Agent is never persisted as `activeSectionId`.

- [ ] **Step 4: Implement the approved nested Agent view**

`AgentSectionView` contains:

- Header `Agent`, counts, refresh button, and history toggle.
- One non-blocking banner per source state with `error != nil`.
- `DisclosureGroup` for project, nested `DisclosureGroup` for session, and item rows.
- Source badge, status icon, title, relative update time, dependencies in expanded detail.
- “接管” / “已接管” / “已接管任务已删除” state.
- Empty states for no unfinished items and no reliable structured items.
- `.task { agents.start(); agents.setVisible(true) }` and `.onDisappear { agents.setVisible(false) }`.

Use the existing theme tokens (`bg`, `surface`, `elevated`, `border`, `accent`, `t1/t2/t3`) and existing font sizing. Do not introduce a second visual system.

- [ ] **Step 5: Implement adoption and settings views**

`AgentAdoptionSheet` owns editable title and a Picker of `state.sections`; default is `state.activeSectionId`. Disable submit for blank title. Show errors inline and dismiss only after controller returns a task ID.

`AgentSettingsView` reads/writes `agent.codexExecutablePath`, displays resolved path and source health, offers “自动检测” by clearing the override, and never asks for tokens.

Add `.agents` to `SettingsTab` and a new TabView item with `cpu` system image.

- [ ] **Step 6: Switch ContentView without disturbing ordinary UI**

Keep `SectionTabBar` common. Immediately below the separator:

```swift
if showingAgent {
    AgentSectionView(state: state, agents: agents)
} else {
    ordinarySectionContent
}
```

Extract existing lines 35-85 into `ordinarySectionContent` without changing their behavior. Ordinary toolbar shortcuts, export, search, calendar, archive, and add-task controls do not render in Agent mode. Quick Input continues using the last ordinary section.

- [ ] **Step 7: Update manual compiler file lists**

Add these three exact paths before `ContentView.swift` in all compiler paths:

```text
Sources/Views/AgentSectionView.swift
Sources/Views/AgentAdoptionSheet.swift
Sources/Views/AgentSettingsView.swift
```

Keep `-lsqlite3` present.

- [ ] **Step 8: Run tests and compile without deploying**

Run full `swift test` and `swift build`. Then run the `swiftc` command from `Scripts/build.sh` with output changed to `/private/tmp/progressbar-agent-ui`; do not execute `Scripts/build.sh` because it kills and replaces the installed app.

Expected: arm64 Mach-O created; no app launched or replaced.

- [ ] **Step 9: Commit UI and settings**

```bash
git add Sources/Views/AgentSectionView.swift Sources/Views/AgentAdoptionSheet.swift Sources/Views/AgentSettingsView.swift Sources/Views/SectionTabBar.swift Sources/Views/ContentView.swift Sources/Views/SettingsView.swift Sources/App/ProgressBarApp.swift Scripts/build.sh Scripts/release.sh .github/workflows/release.yml Tests/ProgressBarTests/AgentIntegrationControllerTests.swift
git commit -m "feat: add hierarchical agent task view"
```

---

### Task 8: Localization, Documentation, and Full Regression Gate

**Files:**
- Modify: all `Sources/Localization/*/Localizable.strings`
- Modify: `README.md:120-170`
- Modify: `README_en.md:120-170`
- Modify: `CHANGELOG.md:1-6`

**Interfaces:**
- Consumes: all UI keys used by Task 7.
- Produces: 12-locale parity and release-facing documentation.

- [ ] **Step 1: Add the complete Agent key set to `en` and `zh-Hans` first**

Required keys:

```text
agent.tab
agent.title
agent.summary_%d_%d_%d
agent.refresh
agent.history
agent.active
agent.source_unavailable_%@
agent.last_updated_%@
agent.adopt
agent.adopted
agent.adopted_task_deleted
agent.re_adopt
agent.adoption_title
agent.adoption_target
agent.adoption_log_%@_%@
agent.empty
agent.empty_history
agent.no_structured_items
agent.settings
agent.codex_path
agent.codex_path_placeholder
agent.codex_detect
agent.codex_not_found
agent.save_failed
```

Use these complete authoritative Simplified Chinese/English blocks:

```text
"agent.tab" = "Agent";
"agent.title" = "Agent";
"agent.summary_%d_%d_%d" = "%d 个项目 · %d 个会话 · %d 个未完成";
"agent.refresh" = "刷新";
"agent.history" = "Agent 历史";
"agent.active" = "未完成";
"agent.source_unavailable_%@" = "%@ 暂不可用，正在显示上次成功的数据";
"agent.last_updated_%@" = "更新于 %@";
"agent.adopt" = "接管";
"agent.adopted" = "已接管";
"agent.adopted_task_deleted" = "已接管任务已删除";
"agent.re_adopt" = "重新接管";
"agent.adoption_title" = "接管任务";
"agent.adoption_target" = "目标分区";
"agent.adoption_log_%@_%@" = "从 %@ 会话「%@」接管";
"agent.empty" = "没有未完成的 Agent 任务";
"agent.empty_history" = "没有 Agent 历史";
"agent.no_structured_items" = "该会话没有可靠的结构化任务";
"agent.settings" = "Agent";
"agent.codex_path" = "Codex 可执行文件";
"agent.codex_path_placeholder" = "自动检测或输入 codex 的完整路径";
"agent.codex_detect" = "自动检测";
"agent.codex_not_found" = "未找到 Codex，请设置可执行文件路径";
"agent.save_failed" = "任务接管失败，请重试";
```

```text
"agent.tab" = "Agent";
"agent.title" = "Agent";
"agent.summary_%d_%d_%d" = "%d projects · %d sessions · %d unfinished";
"agent.refresh" = "Refresh";
"agent.history" = "Agent History";
"agent.active" = "Unfinished";
"agent.source_unavailable_%@" = "%@ is unavailable; showing the last successful data";
"agent.last_updated_%@" = "Updated %@";
"agent.adopt" = "Adopt";
"agent.adopted" = "Adopted";
"agent.adopted_task_deleted" = "Adopted task was deleted";
"agent.re_adopt" = "Adopt Again";
"agent.adoption_title" = "Adopt Task";
"agent.adoption_target" = "Target Section";
"agent.adoption_log_%@_%@" = "Adopted from %@ session “%@”";
"agent.empty" = "No unfinished Agent tasks";
"agent.empty_history" = "No Agent history";
"agent.no_structured_items" = "This session has no reliable structured tasks";
"agent.settings" = "Agent";
"agent.codex_path" = "Codex Executable";
"agent.codex_path_placeholder" = "Auto-detect or enter the full path to codex";
"agent.codex_detect" = "Auto-detect";
"agent.codex_not_found" = "Codex was not found. Set the executable path.";
"agent.save_failed" = "Task adoption failed. Try again.";
```

- [ ] **Step 2: Translate the same keys into the remaining 10 locales**

Update `zh-Hant`, `ja`, `ko`, `fr`, `it`, `es`, `es-419`, `pt-BR`, `hi`, and `id`. Preserve `%d`/`%@` argument count and order exactly. Keep product names `Agent`, `Claude Code`, and `Codex` untranslated.

- [ ] **Step 3: Run syntax and key-parity validation**

Run:

```bash
for f in Sources/Localization/*.lproj/*.strings; do plutil -lint "$f"; done
```

Expected: every file reports `OK`.

Run a key-set comparison using `plutil -convert json -o -` for each locale against `en.lproj`; expected: no missing or extra keys and exactly the same key count in all 12 locales.

- [ ] **Step 4: Update documentation without claiming cloud sync for Agent data**

README changes:

- Add “本地 Agent 任务视图：Claude Code + Codex，只读镜像，可接管为普通任务”.
- Change data stack to “用户数据：JSON + iCloud Drive；Agent 索引：本地 SQLite”.
- Add `Sources/Agent/` to the project tree.

English README gets the equivalent text. Add an `[Unreleased]` section to CHANGELOG describing the local Agent mirror and adoption boundary; do not bump the app version.

- [ ] **Step 5: Run the full verification gate**

Run in order:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/progressbar-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/progressbar-swift-cache \
swift test --scratch-path /private/tmp/progressbar-swiftpm
```

Expected: all Agent and existing tests PASS.

Run the exact `swiftc` source list from `Scripts/build.sh` with output `/private/tmp/progressbar-agent-final`. Expected: exit 0 and `file` identifies a Mach-O executable.

```bash
npm run build --prefix mcp-server
```

Expected: TypeScript compiler exits 0.

Run localization syntax/key parity from Step 3. Expected: all 12 PASS.

Finally run:

```bash
git diff --check
git status --short
```

Expected: only the files intentionally changed by Task 8 are present before commit; no `.sqlite`, `.corrupt`, `.superpowers`, generated schemas, app bundles, or `/private/tmp` artifacts are tracked.

- [ ] **Step 6: Perform a bounded manual runtime check**

Build a temporary `.app` under `/private/tmp`, ad-hoc sign it, and launch only after explicit runtime approval. Verify:

1. Existing `data.json` loads unchanged.
2. Agent tab shows current local Claude/Codex items.
3. Source failure banner preserves cached rows.
4. Adoption creates one ordinary task and retry does not duplicate it.
5. Agent SQLite path is local Application Support, not iCloud.

Do not replace `/Applications/Progress.app`, publish a release, or push commits in this step.

- [ ] **Step 7: Commit localization and docs**

```bash
git add Sources/Localization README.md README_en.md CHANGELOG.md
git commit -m "docs: document local agent task integration"
```

---

## Final Review Checklist

- [ ] Every spec requirement maps to Tasks 1–8.
- [ ] Claude and Codex source adapters fail independently and are independently testable.
- [ ] No source error clears successful cached rows.
- [ ] `data.json` schema and iCloud path remain unchanged.
- [ ] Agent SQLite is rebuildable and excluded from iCloud and Git.
- [ ] Adoption uses a persistent reservation ID and is idempotent across retries.
- [ ] UI matches approved hierarchical option A.
- [ ] Codex integration never calls mutating or model-usage endpoints.
- [ ] No unstructured transcript prose is interpreted as a task.
- [ ] Full Swift, MCP, localization, and manual runtime gates pass before completion is claimed.
