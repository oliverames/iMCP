# Worklog

## 2026-11-20 - Helped on Mattt's TopoText edit engine and the iMCP CI cache

**What changed**:

- **mattt/TopoText#5** (`oliverames:fix/notes-edit-tests-typecheck` → `mattt/notes-edit-engine`): the Test step on Mattt's Notes edit engine PR (#4) fails on Swift 6.1 and 6.2 with "the compiler is unable to type-check this expression in reasonable time" at `NoteEditorTests.swift:606`. The line builds the expected field list as one long array concatenation. The PR builds it in a few statements instead. Verified locally on Swift 6.4: `swift test` 234 tests in 24 suites, 0 failures; `swift format lint --strict` clean. No CI checks have appeared on the PR yet (first-time contributor, so the workflow may need Mattt's approval).
- **mattt/iMCP#393** (`oliverames:ci-drop-all-module-caches` → `main`): the macOS 26 CI job is red on the recent PRs, and it is not a test failure. It fails in different steps on different runs (Test once, Build on the latest run) with a stale module cache: the runner image now has Xcode 26.0.1 while the cached `.pcm` was built by 26.0. The cache key already includes the Xcode build number, but the cleanup step only removed `DerivedData/ModuleCache.noindex`; the `iMCP Helper` target keeps a second module cache under `DerivedData/.../HelperDerivedData/ModuleCache.noindex`, which stayed in the saved archive. The PR removes every `ModuleCache.noindex` under `DerivedData` before saving.
- Corrected the #390 PR body: the macOS 26 failure is this cache issue, not a test, and the final cleaned run failed on Build while the earlier diagnostic run had passed on both jobs.

**Decisions made**: The CI cache fix is a separate PR rather than a change to #390, so the AppleScript PR stays scoped. TopoText help goes through Oliver's fork and a PR to `mattt/notes-edit-engine`, per the fork rules.

**Left off at**: Waiting on Mattt for TopoText#5 and iMCP#393, and on his re-review of #373/#377/#378/#384/#390. Still open: #385 and #391 findings, and the #385 signed sandboxed files pass.

---

## 2026-11-20 - Finished #390 and #373, and ran the real-calendar pass

**What changed**:

- **#390** (`pr/apple-events-helper`): `beforeSending` is `@Sendable` and the `nonisolated(unsafe)` binding is gone; the task's cancellation is checked again after the hook returns, with a test that cancels while the hook is blocked and checks the script never runs. The earlier macOS 26 failure did not reproduce: a run with the test step un-quieted passed both the macOS 26 and macOS 27 jobs, so the failing test could not be named; the diagnostic was removed before the final push. The PR body says this.
- **#373** (`pr/calendar-selection`): `CalendarSelectionStore` now fails closed when the stored value is not `Data` or decodes with none of the known keys (`{"calendars":42}`); only a missing key gets the first-run default. Update and delete now require the calendar of the occurrence that is actually changed, not only the first resolved event. Tests cover unknown-key, wrong-type, missing-key and corrupt-value cases.
- **Real-calendar pass** on the #373 branch, on this Mac with real data: deselected **Oliver** in Settings → Calendar, then `calendars_list` (Oliver absent), `events_fetch` (no Oliver events in a day that had two), `events_create` / `events_update` / `events_delete` against Oliver (all refused with `notShared("Oliver")`), and `events_create` in a still-selected calendar (succeeded; the throwaway event was deleted and confirmed gone). The installed app was quit for the pass and relaunched after.

**Decisions made**: The pass ran against a Debug build of the fork main with the #373 fixes cherry-picked (`f33ca6b`), signed with the fork's team, because the upstream-based PR branch cannot sign the Helper on this Mac.

**Left off at**: #377, #378, #384, #390 and #373 are waiting on Mattt. #385 and #391 still have his findings, and the #385 signed sandboxed files pass is still to schedule.

---

## 2026-11-20 - Sent #378 and #384 review fixes upstream

**What changed**: Finished Mattt's pre-merge findings on #378 and #384, and rebased #384 onto the trimmed #377.

- **#378** (`pr/reminders`): The branch was already EventKit-only, so no private commit needed dropping; the body now says so. Fixed all seven findings: stored relative alarms clamp instead of trapping; all-day and timed dues carry the reminder's calendar and time zone and timed dues keep seconds; views read a due date in its stored zone; a location alarm's house number is part of the street match and a bare locality is rejected; `reminders_complete` is gated by `reminders_update` and a list rename by `reminders_lists_rename`, both before EventKit is touched; a complete with no reminder on readback is uncertain and stops the batch; `reminders_update` accepts `completion_date`; the batch-delete test drives the tool itself. The test target now compiles `Reminders.swift` plus the two extension files it needs, so the tool-level tests exercise the real handlers. 215 tests, 1 skipped, 0 failures.
- **#384** (`pr/notes-v2`, force-pushed to `pr/notes`): Rebased onto the trimmed #377 and fixed the four findings. The scan budget counts `scannedNoteCount` and the page request is capped by the remaining budget; unreadable notes are reported whether or not they matched; tag filters read the same database tag records as `keywords`, inside `notes_fetch`'s snapshot; `keywords` is no longer overwritten by tags parsed from note text; the Markdown table converter no longer pads short rows; `TagTally` and its test are gone. The PR is read filters plus create only; the private NotesShared and edit tools stay on the fork. 251 tests, 1 skipped, 0 failures.
- **Standing rule**: `AGENTS.md` now records that NotesShared and ReminderKit private APIs are for the fork only and never go upstream.

**Decisions made**: The app scheme cannot be built from these upstream-based branches on this Mac because the `iMCP Helper` target uses Mattt's team for signing and there is no profile for it. The test target compiles the changed service files, so the code is type-checked, and the app build is left to CI; both PR bodies say so under "Not verified".

**Left off at**: #377, #378 and #384 are mergeable and waiting on Mattt's re-review. #373, #385, #390 and #391 still have his findings; the two manual passes (#373 real calendars, #385 signed sandboxed files) still need Oliver's Mac.

---

## 2026-11-20 - Synced fork main with upstream and reworked #377 for Mattt's review

**What changed**: Merged `upstream/main` into fork main (`612e935`): #351 Notes smart folders/tags/links, #358 search limits, #382 alert wording. Resolved the structural conflicts by keeping upstream's snapshot-based Notes base with the fork's filters layered on, keeping the fork's `NotesSmartFolders.swift` and dropping upstream's duplicate `NotesInlineTests.swift`, and keeping both sides of the project file. Then cut #377 down to the two commits Mattt asked for (`pr/allow-writes-and-approvals`, force-pushed): Allow writes with its tests, README and test-target entries in the first commit, and the shared confirmation window in the second. Added `Task.checkCancellation()` before `perform` in `approve` with a test that cancels the caller while the confirmation is still being decided (`65f1a62`, also on fork main). #377 is `MERGEABLE` again.

**Decisions made**: Upstream's `NotesInlineTests.swift` was dropped from the fork because it tested the smart-folder behaviour the fork replaced; the fork's `NotesSmartFolderTests.swift` covers the current code. Fork main keeps the cancellation fix so the fork and the PR stay in step. Standing rule added in `AGENTS.md`: NotesShared and ReminderKit private APIs are for the fork only and never go upstream.

**Left off at**: #377 is rebased, trimmed and mergeable, waiting on Mattt's re-review. #378 and #384 are next: drop the private ReminderKit commit from #378 and fix the seven EventKit findings, and fix the four #384 findings on top of #351's snapshot code.

---

## 2026-11-20 - Finished the Antigravity session's iMCP upstream/fork work; reworked approvals to the accepted design

**What changed**: Reviewed Antigravity session `7e0f9e8b` (died on Gemini quota mid-Phase-3) and finished its work. Finished and pushed fork main: upstream fixes cherry-picked/applied (`21a52b6`..`857877b`), TopoText repinned to `mattt/TopoText` 0.3.0 (`c459ed1`), and the approval system reworked to the design Oliver accepted in Antigravity's pop-up (`85a41fd`): four global modes deleted, per-service Allow writes is the only permission model, and a single Unattended switch (default on, legacy-mode migration) auto-approves iMCP's own confirmation windows. Removed the promise sentences from the #373/#385 comments at Oliver's instruction. Deleted 11 merged/closed-PR branches (local + origin). Updated `oliverames/iMCP#12` with the resolved libtailscale/ReminderKit/NotesShared decisions, Mattt's 2026-11-20 per-PR findings, and the new fork↔upstream sync task.

**Decisions made**: Approvals follow Mattt's upstream design plus the Unattended switch (NOT the four kept modes an earlier commit `c626376` assumed) — Oliver corrected this from the pop-up record. TopoText follows Mattt's upstream release. Mattt's four #351 Notes fixes do not apply to the fork's divergent Notes service; fork keeps its implementation plus NotesPrivate/NotesShared/editing. Home helper stays on the fork in full (Oliver's choice in this session, overriding the Antigravity pop-up's "drop" answer). Manual passes for #373/#385 are Mattt's merge conditions but are not promised in comments (Oliver: "don't promise this").

**Left off at**: Mattt merged #351/#358/#382 into upstream main (17:56–18:55 UTC) and left per-PR findings on #373/#377/#378/#384/#385/#390/#391, all "before I merge." #390 also has a real macOS 26 CI test failure he asked Oliver to identify. Fork↔upstream sync is planned but not started (structural conflicts: fork's Notes service vs upstream's #351 version).

**Open questions**: Which PR to work first (proposed: #390 → #377/#385 → #384 → #373/#378/#391); when to run the two manual passes (#373 real calendars, #385 signed sandboxed files pass) — both need Oliver's Mac and real data; timing of the fork↔upstream sync.

---
