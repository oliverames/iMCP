# Worklog

## 2026-11-20 - Finished the Antigravity session's iMCP upstream/fork work; reworked approvals to the accepted design

**What changed**: Reviewed Antigravity session `7e0f9e8b` (died on Gemini quota mid-Phase-3) and finished its work. Finished and pushed fork main: upstream fixes cherry-picked/applied (`21a52b6`..`857877b`), TopoText repinned to `mattt/TopoText` 0.3.0 (`c459ed1`), and the approval system reworked to the design Oliver accepted in Antigravity's pop-up (`85a41fd`): four global modes deleted, per-service Allow writes is the only permission model, and a single Unattended switch (default on, legacy-mode migration) auto-approves iMCP's own confirmation windows. Removed the promise sentences from the #373/#385 comments at Oliver's instruction. Deleted 11 merged/closed-PR branches (local + origin). Updated `oliverames/iMCP#12` with the resolved libtailscale/ReminderKit/NotesShared decisions, Mattt's 2026-11-20 per-PR findings, and the new fork↔upstream sync task.

**Decisions made**: Approvals follow Mattt's upstream design plus the Unattended switch (NOT the four kept modes an earlier commit `c626376` assumed) — Oliver corrected this from the pop-up record. TopoText follows Mattt's upstream release. Mattt's four #351 Notes fixes do not apply to the fork's divergent Notes service; fork keeps its implementation plus NotesPrivate/NotesShared/editing. Home helper stays on the fork in full (Oliver's choice in this session, overriding the Antigravity pop-up's "drop" answer). Manual passes for #373/#385 are Mattt's merge conditions but are not promised in comments (Oliver: "don't promise this").

**Left off at**: Mattt merged #351/#358/#382 into upstream main (17:56–18:55 UTC) and left per-PR findings on #373/#377/#378/#384/#385/#390/#391, all "before I merge." #390 also has a real macOS 26 CI test failure he asked Oliver to identify. Fork↔upstream sync is planned but not started (structural conflicts: fork's Notes service vs upstream's #351 version).

**Open questions**: Which PR to work first (proposed: #390 → #377/#385 → #384 → #373/#378/#391); when to run the two manual passes (#373 real calendars, #385 signed sandboxed files pass) — both need Oliver's Mac and real data; timing of the fork↔upstream sync.

---
