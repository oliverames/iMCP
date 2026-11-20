# Standing rules for this fork

This repository is Oliver Ames's fork of [mattt/iMCP](https://github.com/mattt/iMCP).
`origin` is `oliverames/iMCP`; `upstream` is `mattt/iMCP`.

## Private APIs stay on the fork

Apple's private frameworks and private API use belong to this fork only:

- **NotesShared** ("NotesKit"): `notes_structure`, `notes_native_tags`, `notes_pin`,
  `notes_checklist`, `notes_table`, `notes_link`, `notes_append_rich`,
  `notes_create_markdown`, and the home-relative-path entitlement that goes with them.
- **ReminderKit**: `reminders_tags`, `reminders_add_link`, `reminders_flag`,
  `reminders_get_private`, `reminders_sections`, `reminders_subtasks`,
  `reminders_list_appearance`, `reminders_groups`, `reminders_smart_lists`,
  `reminders_templates`, `reminders_restore`.

Never send private API work upstream. Pull requests to `mattt/iMCP` carry only
public frameworks (EventKit, Notes scripting, AppleScript, and the rest).
When a PR has a private commit, keep that commit on an `oliverames` branch and
send the public commits alone.

## Other invariants

- Push only to `origin`. Never push to `upstream`; upstream work goes through PRs
  from `oliverames` branches to `mattt/iMCP`.
- Coordination: `mattt/iMCP#364` (upstream review order and findings) and
  `oliverames/iMCP#12` (fork tracking). Read both before starting.
- `TopoText` is pinned to Mattt's 0.3.0 upstream release.
- Approvals are Mattt's per-service **Allow writes** plus the single
  **Unattended** switch. There are no global approval modes.
- `libtailscale` stays pinned to `oliverames/libtailscale` (Funnel).
- Keep on the fork: NotesPrivate, NotesShared, Notes editing, ReminderKit, the
  Home helper, the menu bar panel/status item, the iOS extras, and the
  Unattended switch.

## Working rules

- Verify before claiming done: build the app, run `imcp-serverTests`, and run
  `swift format lint --strict` on the changed files. Distinguish what was
  implemented, built, installed, and verified.
- Record session work in `WORKLOG.md`, newest entry first.
- Don't promise follow-ups in pull request comments under Oliver's name.
- Keep each PR's "Testing" and "Not verified" sections honest.