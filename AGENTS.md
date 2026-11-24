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

## What stays on the fork

The fork carries work that is not going upstream. Do not move these into a PR
to `mattt/iMCP`:

- **Private APIs**: NotesShared (`NotesPrivate`, `NotesPrivateTools`,
  `NotesSharedBridge.m`, the home-relative-path read-write entitlement) and
  ReminderKit (`RemindersPrivate`, `RemindersPrivateTools`,
  `ReminderKitBridge.m`).
- **Notes editing through scripting**: `NotesWriting`, `NotesWriteTools`,
  `NotesOrganize`, `NotesOrganizeTools`, `NotesExport`, `NotesWrite`. Mattt
  declined the edit layer and is building a TopoText edit engine instead.
- **Safari**: `Safari`, `SafariBookmarksFile`, `SafariScripting`. Mattt has his
  own Safari service in progress.
- **Music playlist writes**: `MusicPlaylistWrites`. Mattt gave another
  contributor the first shot at the write side.
- **Connectivity**: Cloudflare Tunnel (`CloudflareTunnel`,
  `CloudflareTokenCheck`), Tailscale Funnel (`FunnelAccess`, with the
  `oliverames/libtailscale` pin), OAuth 2.1 (`OAuthAuthority`, `OAuthEndpoints`,
  `OAuthGrant`, `ClientMetadataFetcher`, `AccessToken`), and Tailscale remote
  access (`TailscalePolicyAccess`, the HTTP transport, `RemoteAccessChecklist`).
- **iOS**: the whole app (`iOS/`, `iOSWidgets/`), mobile sync and Approve on
  iPhone (`Mobile`, `MobileCache`, `MobileApprovals`, `RemoteApprovals`,
  `MobileActivity`), and the dev bootstrap (`DevBootstrap`,
  `GeneratedBootstrapSecrets`).
- **Menu bar**: the custom status item and panel (`MenuStructure`,
  `MenuBarPanel`, `MenuBarView`, `MenuBarController`). Mattt declined it in
  #382 because it collides with #316.
- **Home helper**: the bundled XPC helper (`HomeHelperXPC`,
  `HomeWindowPresence`). The helper app itself, `HomeBackend` and
  `HomeHelperLocator` are upstream.
- **Trust by code signature**: `ResponsibleApp` and the trusted-app tests.
  Mattt is doing trust by code signature himself.
- **Approvals**: the **Unattended** switch (`Unattended`) is the one approval
  pattern that is fork-only. Allow writes and the shared confirmation window
  are Mattt's design and are upstream (#377).
- **Setup/onboarding**: `OnboardingFlow` and `RemoteAccessChecklist` stay here only
  until Mattt merges his own Setup Assistant (he is building on #387); then the
  fork takes his.
- **Local config and dev tooling**: `Config/*.local.xcconfig`, the local plists,
  and the fork's `Scripts/` helpers (`generate-bootstrap-secrets.sh`,
  `install-ios.sh`, `check-home.py`).

Work that is in flight upstream is not on this list: #373, #384, #385, #391
and #392 (#387, #388 and #389 are parked; see below). #377, #378, #390 and
#393 merged and are in fork main.

## Long-term plan for each fork-only feature (Oliver, 2026-11-20)

Permanent on the fork:
- NotesShared and ReminderKit private API tools.
- The custom menu bar status item and panel. Resolve conflicts with #316 here, and once #316 merges, rework the panel around Mattt's wizard and offer it again. The menu accessibility change (real buttons, system background, semantic fonts, standard About panel) was offered separately on #364 on 2026-11-20.
- The iOS app's own design. Keep sending small fixes against `mattt/ios-app`
  (like #391) and rebase when #281 ships.
- The dev bootstrap stays in every build configuration (these builds only reach
  Oliver's own devices).

Waiting for upstream, then switch to Mattt's version:
- Trust by code signature: keep the fork's version (with the intermediary
  check) until Mattt ships his.
- Setup Assistant, Settings redesign and Activity row (#387, #388, #389).
- Bundled XPC Home helper: until upstream bundles the helper (#317).
- Safari: until Mattt's Safari service ships.
- Music playlist writes: until #327 merges.
- Tailnet HTTP: adopt #308 once it merges. Funnel, Cloudflare Tunnel and OAuth
  stay fork-only until Mattt decides how OAuth is hosted.
- Notes edits through scripting: `notes_append` and `notes_update` refuse
  notes with checklists, tags or tables; switch to TopoText's edit engine
  once it writes.

The Unattended switch stays fork-only and defaults to off for new installs.

## Working rules

- Verify before claiming done: build the app, run `imcp-serverTests`, and run
  `swift format lint --strict` on the changed files. Distinguish what was
  implemented, built, installed, and verified.
- Record session work in `WORKLOG.md`, newest entry first.
- Don't promise follow-ups in pull request comments under Oliver's name.
- Keep each PR's "Testing" and "Not verified" sections honest.