# Worklog

## 2026-11-20 - Second review of the upstream PRs, fork ports, and outreach to Mattt

**What changed**: Re-reviewed every open upstream PR and fixed what turned up, then updated each PR body and posted a comment tagging Mattt: #393 versions the CI cache key (Xcode 26.0 and 26.0.1 share build 17A400, so the bad archives kept restoring); #377 reports a cancelled confirmation as cancelled; #378 clamps stored alarms without trapping and resets the batch-delete store after a failed delete; #384 caps `scanLimit` by the budget, dedups unreadable IDs, returns a database `identifier` from create (`scriptIdentifier` for the scripting id), balances link parentheses; #385 refuses a long-s Photos library spelling and keeps tags, mode and name on replace with a new modification date; #391 re-checks pairing in `accept` and quarantines an unreadable old outbox; #392 sets `ASSETCATALOG_COMPILER_APPICON_NAME`. #384 and #385 are rebased onto the current #377. CI passes on #377, #378, #384, #385 and #393. Posted a review of Mattt's #308 (pre-auth connection and buffer exhaustion, global session cap, Host only checked when present, uncached whois failures), a #364 update with split offers for #378 and #384 and a TopoText testing offer, and a #305 note on how #390's helper fits his branch. Ported the Reminders, Files, Notes and confirmation fixes to fork main (`0bc19ea`, `3629176`, `f69e757`, `56cea32`). Tests no longer leave plists in `~/Library/Preferences` (`dfb55c2`, `0aa4ce3`; 6,231 old ones moved to the Trash). Fork CI green on `0aa4ce3`.

**Decisions made**: The #308 review, #364 update and #305 note were posted with Oliver's approval. Mattt took only #382's alert wording; the custom menu panel waits for his #316 wizard. The menu's accessibility changes (real buttons, system background, semantic fonts, standard About panel) can be offered separately; not yet offered.

**Left off at**: Waiting on Mattt. The small menu accessibility PR was offered on #364; the panel gets reworked around #316 once it merges. Done since: every Notes tool accepts the database id or the `x-coredata://` id and returns both, through `NotesIDMapper` (an exact read-only database lookup, with the NotesShared bridge as fallback); `notes_create`'s title and timestamp matching is gone (`5dc4506`, 862 tests passed). Live checks are in `oliverames/iMCP#13`. 2026-11-21: every Mattt review point on #373, #377, #378, #384, #385, #390 and #391 is fixed and answered (the #390 reply naming `ce80938` was missing and is now posted); merged agent worktrees and branches removed. Still waiting on Mattt; #390's macOS 26 job stays red until #393 merges.

---

## 2026-11-20 - Review of upstream PRs, fork-only features and fork bugs

**What changed**: Reviewed every upstream PR, Mattt's comments, CI, the worklogs and the fork-only code, asked Oliver about each fork-only feature (plan recorded in `AGENTS.md`, `1b70789`), and fixed what the review found. All on `main`, CI green (run 44849951879), `imcp-serverTests` 826 passed, iMCP app builds.
- CI: generates the empty bootstrap secrets file; fork CI had never passed (`47a656c`).
- Notes Markdown export kept text after `<head>` (`c2527bf`); Unattended defaults to off for new installs (`87f1d89`).
- Trust by signature only when imcp-server's direct parent is the app or a same-team bundled helper (`051d5f3`), Mattt's #374 point.
- #391's outbox migration and liveness fixes ported, pairing checked when a link is installed, 8 KiB pre-auth WebSocket frames (`81ed856`, `4bf9b81`).
- Cloudflare ingress: a failed read aborts, `path`/`originRequest`/unknown fields survive (`11d770b`), Mattt's #376 point.
- Private Reminders tools honour the per-tool switches, on the normalized action, failing closed (`e4ecc2e`, `e6965ab`); NotesShared rolls back failed writes and tag batches validate first; group delete only after its lists move (`b09f035`).
- `notes_update`/`notes_append` refuse notes with checklists, tags, links, tables, U+FFFC or sharing, read from the database through NoteTraits; attachments confined to one folder (`403ffd1`, `771f5f7`).
- Public endpoint: per-sender OAuth limits, denial cooldown, one prompt per app and sender, DNS under the deadline, missing Authorization not counted, unauthenticated connections close (`a11e7b0`); `CF-Connecting-IP` ignored while Funnel is on, and no cooldown or replacement for unknown senders (`2c39ad7`).

**Decisions made**: The dev bootstrap stays in all builds (Oliver). The Notes rewrite guard maps the scripting id to the TopoText id through the NotesShared bridge, so with Private Notes features off, `notes_update`/`notes_append` refuse (fail closed). Funnel traffic has no sender address, so its OAuth limits stay shared.

**Not verified**: Only unit tests and builds. Live checks are listed in `oliverames/iMCP#13`.

**Left off at**: Mattt's re-review of #373/#377/#378/#384/#385/#390/#391/#393 is unchanged; #392 parked.

---

## 2026-11-20 - Wrapped up the upstream/fork session

**What changed**: Rewrote the session's pull request replies in Oliver's voice and tagged `@mattt` on every comment of his across `mattt/iMCP` (#364, #373, #377, #378, #380, #384, #385, #387, #390, #391, #392), #317 and `mattt/TopoText#4`, including seven older comments that had drifted in without the tag. The Home paragraph in the README now describes the bundled XPC helper and no longer suggests showing the helper's window (`76eb6f8`). `AGENTS.md` gained a "What stays on the fork" inventory: the private APIs, Notes editing, Safari, Music playlist writes, Cloudflare Tunnel, Funnel, OAuth, Tailscale remote access, the iOS app and mobile approvals, the custom menu bar panel, the bundled XPC Home helper, trust by code signature, the Unattended switch, and the dev bootstrap and local config.

**Decisions made**: The fork's `main` is the buildable trunk and is in step with the upstream fixes; the upstream PRs stay split by concern. `oliverames/iMCP#13` is now the repository's single testing issue: #10 is closed and its remaining item moved there, and #12's live-checks list moved there too. #12 records the resolved sync and review fixes, the remaining upstream re-reviews, and the parked PRs.

**Left off at**: Waiting on Mattt's re-review and merges of #373, #377, #378, #384, #385, #390, #391, #393 and `mattt/TopoText#5`, and on a maintainer approving TopoText#5's CI run. Once #393 merges, rebase #377/#378/#384/#385/#390 onto `main` so their macOS 26 jobs go green. #387/#388/#389 and #392 stay parked.

**Open questions**: Whether to offer Mattt help with the TopoText notes-edit database-write side once his encoder holds up, and whether to retake the pr-assets screenshots now or after #387/#388 settle.

---

## 2026-11-20 - Ported the #378, #384 and #390 review fixes to fork main

**What changed**: The fork's integration build still had the pre-review Reminders, Notes and AppleScript helper code, so the fixes Mattt is reviewing upstream were not in it. Ported all three:

- **Reminders**: clamp stored relative alarms instead of trapping; all-day and timed dues carry the reminder's calendar and time zone and keep seconds; views read the stored time zone; the house number is part of the street match and a bare locality is rejected; `reminders_complete` is gated by `reminders_update` and rename by `reminders_lists_rename`; a complete with no readback is uncertain and stops the batch; `reminders_update` accepts `completion_date`; `notes_tags` reads the database tag records (the fork's scan-based `tagsResult` and duplicate tool were removed).
- **Notes**: the scan budget counts `scannedNoteCount` and caps the page request; unreadable notes are kept whether or not they matched; tag filters read the database tag records; `keywords` is no longer overwritten from note text; short table rows are not padded; `TagTally` is gone.
- **AppleScript**: `beforeSending` is `@Sendable`, the `nonisolated(unsafe)` binding is gone, and cancellation is checked after the hook returns.

**Verification**: `imcp-serverTests` 781 tests, 0 failures; `swift format lint --strict` clean; the `iMCP` scheme builds (signed with the fork's team).

**Left off at**: All of Mattt's findings are addressed upstream and replied to; the fork is in step. Remaining: his re-review and merges, the TopoText #5 CI approval (first-time contributor), and rebasing the PRs whose macOS 26 job is red once #393 lands.

---

## 2026-11-20 - Ran the TopoText validation and the signed sandboxed Files pass

**What changed**:

- **TopoText #4 validation** against my real Notes database, read-only, from Terminal with Full Disk Access: 433 notes across 30 folders, 430 decoded (3 locked), 189 in Recently Deleted. Every decoded note encodes back to exactly the bytes Notes stored (`lossless: encoding equals the stored bytes: 430`), every invariant the editor relies on holds (`invariants: notes with every invariant: 430`), and the trial edits are sound where they apply: append a checklist item 430, insert text in the first paragraph 430, change a checklist item's state 9, delete a character of the last paragraph 268 sound with 122 refused for an attachment range and 1 refused for splitting a character. The tool printed aggregate counts only. Posted to `mattt/TopoText#4`.
- **#385 signed sandboxed pass** on a Debug build signed with the fork's team: added `~/Documents/imcp-files-pass` in Settings → Files → Add Folder; quit and relaunched the app (both shared folders stayed available, so the bookmarks persist); `files_list`, `files_read` (content matched byte for byte), `files_write` (created a file), and `files_trash` (the file went to the Trash and was still there, not deleted). Originals untouched. Test files and the test folder were removed afterwards, and the installed app was relaunched.

**Decisions made**: The pass ran against fork main with the #385 fix cherry-picked (`8b76101`), signed with the fork's team, because the upstream-based PR branch cannot sign the Helper on this Mac. The code under test is the same as the PR head.

**Left off at**: All seven PRs and TopoText #5 are waiting on Mattt. The two deferred passes are done.

---

## 2026-11-20 - Finished the #385 and #391 code fixes

**What changed**:

- **#385** (`pr/files-v2`, force-pushed to `pr/files-service`): rebased onto the trimmed #377 and fixed Mattt's three findings. `files_stat` no longer unwraps `canonicalComponents.last!` for a link that resolves to the shared root (an empty canonical path is the root), with a test. `files_trash` reports `trashUnverified` when `F_GETPATH` fails instead of success, and reports `trashRestoreFailed` when putting a swapped item back fails instead of dropping the error. `write` closes its output descriptor when `writeAll` throws, on both the replace and create paths. 243 tests, 1 skipped, 0 failures.
- **#391** (`pr/ios-outbox-liveness`): the outbox migration now copies each file and removes the old ones only when every copy matches its source; a failed checkpoint or copy leaves the old outbox in place, and `shared()` opens the old outbox until the migration is complete, so a partial migration can't strand records or anchors. `answers(within:)` no longer waits for the status call after the timer wins — the first of the call or the timer returns, and a silent socket can't hold the result open. `attach` remembers whether the device was paired before the liveness check and refuses a link for a device unpaired during the wait. 252 tests, 1 skipped, 0 failures.

**Decisions made**: The unpair guard only refuses when the device was paired before the check, so the existing tests that attach unpaired fake links keep working and the production transition is what is caught. The signed sandboxed Files pass and the TopoText validation run are deferred to the end, per Oliver.

**Left off at**: All code fixes Mattt asked for are in: #373, #377, #378, #384, #385, #390, #391. Waiting on his re-review. Deferred to the end: the #385 signed sandboxed files pass and the TopoText #4 validation run. #387/#388/#389 stay parked, #392 parked.

---

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
