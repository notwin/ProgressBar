# Task 6 Report: Recoverable, Idempotent Task Adoption

## Implementation

- Added the `@MainActor UserTaskAdopting` boundary and made `AppState` conform.
- `AppState.containsTask(id:)` searches active and archived tasks in every section.
- `insertAdoptedTask` is fixed-ID and idempotent, validates the target section and trimmed title,
  inserts at index zero, creates exactly one `today()` log, and preserves the normalized Agent
  status. A duplicate ID returns success without another write.
- Ordinary `addTask(title:to:)` and adoption share one private insertion helper. Ordinary adds keep
  their generated lowercase ID, pending status, empty logs, existing spring animation, save call,
  and existing in-memory behavior if saving fails.
- Added the controller's two-phase adoption path: reuse an existing reservation or reserve a new
  lowercase UUID, recover an already-written user task, map status and pre-localization source log
  text, mark failed after a rejected write, and mark completed plus reload the dashboard after a
  successful or recovered write.
- No `TaskItem`, `AppData`, or `data.json` schema changed. Agent SQLite remains at the existing local
  Application Support path and no iCloud path changed.

## Persistence Scope Expansion

The planned `insertAdoptedTask(...) -> Bool` could not represent a real user-data write failure:
`PersistenceManager.save(appData:)` caught the atomic-write error, reported it through `onError`,
and returned `Void`. That would let the controller mark an adoption completed even when `data.json`
was not written.

Task 6 therefore includes the explicitly authorized minimal persistence change:

- `PersistenceManager.save(appData:)` and `AppState.save()` are now `@discardableResult -> Bool`.
- Success means the primary atomic `dataURL` write succeeded. The existing optional local backup,
  error callback, generation tracking, path choice, and schema are unchanged.
- If adoption saving fails, AppState removes only the just-inserted fixed-ID task from memory and
  returns false. This prevents a later `containsTask` check from mistaking an unpersisted task for a
  completed adoption.
- Ordinary task creation intentionally does not roll back, preserving its prior in-memory behavior.
- AppState has a production-equivalent `convenience init()` and an internal injected initializer.
  Tests disable calendar initialization, timers, and appearance observers and never touch user
  persistence. The normal `AppState()` path still constructs the real persistence manager and runs
  the same service initialization sequence.

## TDD Evidence

- Baseline before edits: full `swift test` — 58 tests, 0 failures.
- Initial RED: focused compilation failed because `UserTaskAdopting`, controller `adopt`, the AppState
  adoption surface, injectable persistence, and Boolean save result did not exist.
- The first RED also exposed async expressions inside XCTest autoclosures; those test-only errors
  were removed and RED was rerun before production implementation.
- Real persistence RED used a fake `PersistenceManager` and required save failure to return false,
  remove the inserted task, leave the reservation failed, and let retry reuse the reservation ID.
- First GREEN compile exposed a MainActor default-argument isolation error. Root-cause correction
  replaced the actor-isolated default argument with a production `convenience init()` delegating to
  the injected designated initializer.
- Final focused `AgentAdoptionTests`: 9 tests, 0 failures.
- Coverage includes first success, repeated click, mapped status, exact Claude/Codex log text,
  lowercase reservation IDs, fake sink failure, failed-reservation retry, real AppState save failure
  and rollback, active/archived cross-section lookup, validation, exactly one dated log, duplicate
  insertion, and ordinary-add save-failure semantics.

## Verification

- Full suite: `swift test` — 67 tests, 0 failures.
- Agent plus adoption surface Swift 6 typecheck with
  `-strict-concurrency=complete -warnings-as-errors` — exit 0. The command used a temporary no-op
  CalendarManager interface so the Task 6 surface could be checked independently of the repository's
  known pre-existing CalendarManager Swift 6 diagnostics; the real CalendarManager was used in the
  complete app build.
- Real app `swiftc` source set and flags matching `Scripts/build.sh`, redirected to
  `/private/tmp/progressbar-task6-app` — exit 0. `Scripts/build.sh` itself was not executed, so no
  process was killed, no application was replaced, and nothing was launched or deployed.
- `git diff --check` exited 0. No Agent SQLite, generated cache, temporary fixture, or companion file
  is tracked.

## Recovery and Concurrency Review

- Concurrent adopts for one key may both observe no mapping across an actor suspension, but
  `reserveAdoption` serializes the transaction and `INSERT OR IGNORE` returns the same persisted ID.
  The sink API is synchronous and MainActor-isolated, so the contains/insert step cannot create two
  user tasks.
- If the user task is written and completing the mapping fails, retry finds the fixed-ID task and
  only retries `completeAdoption`.
- If the reservation is already failed while the sink contains the task, the same recovery branch
  marks it completed and reloads the dashboard.
- Dashboard reload happens after task persistence and mapping completion. If that read fails, the
  controller propagates the store error even though the core adoption is already durable. A retry
  remains idempotent and retries completion/reload; this follows the plan's ordered
  `complete + reload + return` algorithm but can produce one conservative error presentation.

## Remaining Concerns

- The save result proves the primary atomic write returned successfully; the existing best-effort
  local backup still does not affect success, matching prior persistence semantics.
- Task 7 owns the UI treatment of completed mappings whose user task was later deleted. Task 8 owns
  localization; the required Chinese pre-localization log semantics remain hardcoded in Task 6.
