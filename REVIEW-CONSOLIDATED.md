# Cleanup report

Completed 2026-09-06. The remaining review queue is resolved; distribution signing
remains deferred. Earlier fixes C01–C11 and C12a are retained in their existing
commits. Scope stayed within the macOS host, private bridge, configuration, and
build integration; untouched libghostty internals were not audited.

## Behavior decisions and changes

| Review item | Result |
| --- | --- |
| C12b — config editor | Both actions use the macOS file association, then the default text editor, then normal OS opening. Missing files are created without overwriting existing content. Opening errors are shown. |
| C12c — background blur | Numeric radii use the WindowServer API used upstream. Regular/clear glass use AppKit on macOS 26+. Native fullscreen and an opacity override disable transparency. |
| C12d/f — supported actions | One native capability registry filters bindings and the palette. Unsupported tab/pane, inspector, update, and decoration-toggle actions are rejected rather than silently accepted. macOS Ghostty also leaves decoration toggling unsupported. |
| C12e/g — limits and bells | Apply minimum and maximum window sizes. Bell borders persist until focus/input clears them. |
| C13 — shared UI state | Progress is a per-terminal bar with a 15-second expiry, matching Ghostty. One app owner balances Secure Input calls. Borderless fullscreen presentation follows the active window and restores previous app options. |
| C14 — includes | Main configuration loads first, then includes in queue order. Repeated values reach the engine in order for its per-setting append/reset rules. |
| C15 — drops | Accept file and text drops. File paths are shell-quoted; read-only and closed terminals reject delivery. |
| C16 — placement/restoration | A configured x/y pair takes precedence over cascading. AppKit owns per-window restoration, with separate directory, title, and borderless-fullscreen metadata. Custom-command windows are excluded. Quit preserves windows for AppKit state capture. |
| C17 — accessibility | Expose viewport text, selection, cursor, line navigation, and UTF-16 ranges through a cached, owned native snapshot. Closing a surface invalidates access safely. |
| C18 — portability | Dumped working-directory defaults use the portable automatic value. Theme paths use the home directory supplied to the config loader. The workspace/home default is preserved. |
| C19 — command focus | Retain app-directed Find and Command Palette behavior, including while another field is being edited. Explicitly unbound shortcuts stay unbound. |
| C20a/b — distribution metadata | Consolidate dependency/component license texts under VeloKit and copy the notice plus project license into the app. Narrow Finder registration to folders. |

Upstream behavior was checked against
[Ghostty revision 97f2ddb](https://github.com/ghostty-org/ghostty/tree/97f2ddb06e43ed73948385944cd1b0c19c282807).
Copied/adapted behavior retains attribution in
[VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
Changes are committed in logical chunks. Nothing was pushed.

## Validation and remaining checks

- Passed: 18 Swift configuration tests, native bridge/Core suite, targeted AppKit
  configuration/host checks, and Release app build.
- Added coverage for editor selection, unsupported actions, blur variants, size
  limits, persistent bells, Secure Input failure/retry accounting, independent
  progress, drop quoting, window placement/restoration metadata, quit state capture,
  and actual Unicode terminal output/selection.
- The desktop is locked. The full focus-switching/lifecycle and automatic-quit
  suites need an unlocked rerun after these changes. Their earlier passing results
  predate this final batch. CI has not run remotely.
- Manually check appearance on macOS 13–25/26+, actual VoiceOver navigation, and
  AppKit restoration across quit/relaunch. Numeric blur uses a private macOS API,
  as upstream does; missing symbols safely leave blur unavailable.
- Restoration starts new shells; it does not persist running processes. Rectangular
  selections expose their text without claiming one contiguous character range.
  Distribution signing/notarization remains deferred (C20c); development signing
  remains ad hoc.
