# Cleanup review

Updated 2026-09-06. This is the working list for the cleanup session. Original issue
IDs are retained; resolved findings and rejected claims are removed from the queue.

Discuss one issue at a time: choose an approach, implement it, validate it, update
this file, and commit the change as a self-contained chunk. A recommendation below
is not an approved decision. **Current issue: C09 — awaiting a choice.**

Scope: our macOS host, private VeloKit bridge, configuration, and build/test integration.
Untouched libghostty internals and new mux functionality are outside this cleanup.

## Remaining issues

### C09. Test workflow

**Before mux; confirmed gap.** SwiftPM runs configuration tests only. Native bridge
and AppKit regressions require manual compilation, and there is no CI workflow.

**Choose:** normal test targets and CI coverage using existing build tools. Cover
our bridge and host, including ABI, teardown, input, focus, and clipboard cancellation.

Code: [Package.swift](macos/Package.swift), [EngineTests](macos/EngineTests/Configuration.c),
[WindowTests](macos/WindowTests/main.swift).

### C10. Engine artifact freshness

**Before mux; confirmed gap.** Xcode consumes a manually copied, ignored XCFramework
without checking whether it matches engine source. Terminfo is generated separately.

**Choose:** an engine build dependency or a freshness/resource check using Zig/Xcode.
Avoid adding a bespoke development-tool wrapper. A successful stale build is not
validation of current engine source.

Code: [Xcode project](macos/Velocitty.xcodeproj/project.pbxproj),
[build.zig](VeloKit/build.zig).

### C11. Consistent configuration reload

**Medium; confirmed gap.** The shared engine update applies settings to existing
surfaces, followed by per-session overrides. A failure during application can leave
a partial update; the host has no rollback. Native control refresh is already fixed.

**Choose:** preparation/application/rollback semantics for the shared runtime.
The original claim of a config-pointer race during the synchronous update was not
established and is not an additional open defect.

Code: [TerminalRuntime.swift](macos/Velocitty/TerminalRuntime.swift),
[AppDelegate.swift](macos/Velocitty/AppDelegate.swift), `reloadConfiguration`.

### C12. Supported features and actions

**Medium; confirmed mismatches.** Decide each subitem separately:

- **C12a:** `goto_window` ignores direction.
- **C12b:** `open_config:new_window` opens externally.
- **C12c:** blur variants and radii produce one native visual treatment.
- **C12d:** decoration toggles are lost during later appearance/config updates.
- **C12e:** size-limit handling ignores maximums.
- **C12f:** unsupported keybinding actions can parse; the palette has a separate denylist.
- **C12g:** bell borders flash briefly rather than providing persistent feedback.

**Choose for each:** implement, reject, or explicitly define Velocitty's behavior.
Consider a shared capability registry when addressing C12f.

Code: [RuntimeContext.swift](macos/Velocitty/RuntimeContext.swift),
[CommandPalette.swift](macos/Velocitty/CommandPalette.swift),
[AppDelegate.swift](macos/Velocitty/AppDelegate.swift).

### C13. Process-wide UI ownership

**Medium; Dock/fullscreen conflicts confirmed.** One window's timers can clear
another window's Dock progress. Borderless fullscreen windows independently modify
application-wide presentation options.

**Choose separately:** Dock aggregation/selection and timeout policy; fullscreen
ownership; centralized Secure Input ownership. Balance only successful acquisitions.
A process crash leaving Secure Input locked until logout was not substantiated.

Code: [AppDelegate.swift](macos/Velocitty/AppDelegate.swift).

### C14. Configuration include semantics

**Medium; intentional compatibility difference.** Our loader applies includes first,
then lets the parent override; repeatable arrays replace earlier arrays. The engine's
native loader applies includes afterward and uses per-setting repeat/reset semantics.

**Choose:** retain and document our policy or align it with the native loader.
Changing array behavior needs per-setting reset rules, not blanket concatenation.

Code: [AppConfiguration.swift](macos/Configuration/AppConfiguration.swift).

### C15. Direct file drops

**Optional feature.** File-open failure reporting is fixed. Dropping files directly
onto the terminal view is not implemented.

**Choose:** implement direct drops or defer as feature work.

Code: [TerminalView.swift](macos/Velocitty/TerminalView.swift).

### C16. Window placement and restoration

**Medium; precedence conflict confirmed.** Cascading overrides explicit coordinates
on subsequent windows. All windows also share saved frame/fullscreen keys.

**Choose separately:** explicit-position versus cascade precedence; last-closed versus
per-window restoration. Preserve diagonal placement for ordinary new windows.

Code: [AppDelegate.swift](macos/Velocitty/AppDelegate.swift).

### C17. Terminal accessibility

**Medium; missing host interface.** Rendered terminal output has no accessibility
text, selection, or cursor interface.

**Choose:** implementation scope and timing; preserve a suitable surface/view boundary.

Code: [TerminalView.swift](macos/Velocitty/TerminalView.swift).

### C18. Portable defaults and home expansion

**Lower; policy/testability.** Dumped working-directory defaults contain an absolute
machine-specific path. Theme expansion uses the process home even when configuration
loading receives an injected home. Error provenance is already fixed.

**Choose separately:** portable automatic-directory representation and consistent
home injection. Preserve the requested workspace/home default. Explicit `inherit`
currently means process cwd and is a separate compatibility decision.

Code: [ConfigurationTemplate.swift](macos/Configuration/ConfigurationTemplate.swift),
[TerminalTheme.swift](macos/Configuration/TerminalTheme.swift).

### C19. Commands while editing fields

**Lower; UX decision.** Find and Command Palette target the active terminal even when
another input field has focus. Their no-terminal availability is already fixed.

**Choose:** retain app-directed behavior or use responder-specific behavior.
Explicitly unbound shortcuts must stay unbound; C08 centralized shared config ownership.

Code: [AppDelegate.swift](macos/Velocitty/AppDelegate.swift).

### C20. Distribution housekeeping

**Before distribution; inventory and policy decisions.** Discuss separately:

- **C20a:** inventory shipped dependencies and complete their texts in VeloKit's
  consolidated third-party notice; its “Other dependencies” section is currently an index.
- **C20b:** keep broad `public.item` file handling or narrow the Open With registration.
- **C20c:** distribution signing is deferred; ad-hoc signing is intentional for development.

GPLv3-only is settled. Documentation, duplicate project licensing, and About metadata
have already been cleaned up.

Code: [THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md),
[Info.plist](macos/Velocitty/Info.plist).

## Completed fixes

| Issue | Completed work |
| --- | --- |
| C01 | Invalidate runtime callback handles and borrowed view handles before teardown. |
| C02 | Fix trigger ABI; replace untyped config reads with checked private getters and named Swift properties. Copy borrowed strings/lists into Swift-owned values. |
| C03 | Preserve Unicode above AppKit's special-key range. |
| C04 | Open HTTP(S)/mailto directly; confirm file/app links with the full destination and Cancel as default. Reject malformed, javascript, and data URLs. Cancel pending links on terminal close. |
| C05 | Derive terminal focus from app activity, key window, responder, and sheet state. Update on lifecycle transitions while retaining native composition callbacks. |
| C06 | Safely remove accessories and avoid adding them to hidden titlebars; reproduced crash fixed. |
| C07 | Own clipboard confirmations per terminal, queue sheets, and resolve pending requests exactly once before native surface teardown. |
| C08 | Share one engine and configuration across the app; sessions own surfaces and backing views, with callbacks routed to their current window. |
| C11, controls | Refresh scrollbar visibility/layout on reload; remove unreachable scrollbar policy branch. |
| C15, delivery | Report file-delivery outcomes, including startup failure/cancellation. |
| C18, diagnostics | Attribute native setting errors to their included source file. |
| C19, availability | Disable terminal commands without a live destination; preserve unbinding. |
| C20, docs | Update README, consolidate project license, use bundle About metadata, fix SPDX placement. |

Validation: rebuilt VeloKit; native configuration/ABI tests, 13 Swift configuration
tests, both AppKit lifecycle/automatic-quit suites, and Debug app build passed.
Tests include queued wakeups, Unicode conversion, titlebar reloads, scrollbar refresh,
menu availability, and included-file diagnostics. Real input-method UI and injected
file-open creation failures still need coverage. The C05 tests exercise composition
callbacks and real PTY input; C07 adds clipboard queue and cancellation coverage.

## Decisions implemented

- **C02 — checked bridge plus typed Swift accessors.** Approved option 2. Native
  getters verify the value's C representation before writing; unknown, unset, or
  incompatible values return false without changing the destination. The untyped
  private getter is removed. Parsing and defaults remain in the engine.
  Validation: 135 getter/type combinations plus successful value checks, Swift
  accessor and copied-value lifetime checks, both AppKit suites, and Debug build pass.

- **C04 — direct web/mail links, confirmation for file/app links.** Approved option 1.
  The host applies the policy to terminal URLs, while engine-generated text/HTML
  exports remain direct file opens. The confirmation shows the complete selectable,
  scrollable destination and does not remember approval. A second request cannot
  replace a pending destination; closing the terminal cancels it.
  Validation: URL policy cases, invalid UTF-8, native callback routing through a fake
  OS opener, long destination display, Return-to-cancel, explicit Open, duplicate
  requests, and close-with-confirmation pass in both AppKit suites. Debug build passes.

- **C05 — centralized focus, native composition behavior.** Approved option 1.
  One host rule updates engine focus on responder/window/app/sheet transitions and
  view attachment. Initial and idle runtime focus follows actual app activity.
  No forced composition commit or discard was added.
  Validation: the GUI harness dispatches AppKit events and observes real focus-report
  bytes at a PTY across windows, search, palette, app switches, sheets, and view
  detachment. Simulated NSTextInputClient composition survives window transitions
  and its explicit commit reaches the PTY exactly once. These GUI checks require
  an interactive desktop; actual input-method candidate UI was not exercised.
  Both AppKit suites and the Debug build pass.

- **C07 — per-terminal clipboard confirmation queue.** Approved option 1.
  Register copied request data synchronously before scheduling UI. Show one clipboard
  sheet at a time and wait behind other sheets. Cancel active and queued requests
  before freeing the native surface; late sheet callbacks cannot reply again.
  Clipboard writes without request state share the queue but do not call native denial.
  Validation: both AppKit suites cover ordered Allow/Cancel, remembered approval,
  waiting behind link sheets, missing windows, cancellation before presentation and
  with an active sheet, late responses, and exactly-once replies while the surface is
  alive. Real native paste requests preserve their original clipboard bytes, deliver
  approved input to a PTY, and discard denied input. Closing with native requests
  pending and cancelling a write leave no late UI or clipboard write. Debug build passes.

- **C08 — shared engine and separate terminal sessions.** Approved option 1.
  AppDelegate retains one TerminalRuntime even with no windows. TerminalSession owns
  its surface and backing view and retains the runtime until native teardown; the
  runtime tracks sessions weakly. Windows explicitly close their sessions, preserving
  existing close/quit behavior. The session controls process lifetime while its view
  can be detached.
  Callback dispatch resolves the source session's current window; app actions use
  application ownership. Focus, keyboard layout, global shortcuts, appearance, and
  configuration use the shared engine. Links and clipboard prompts remain per terminal.
  A private surface configuration call preserves local opacity overrides without
  updating siblings. Configuration failure rollback remains C11; persistence is future work.
  Validation: rebuilt VeloKit and passed native bridge/configuration tests, 13 Swift
  configuration tests, both AppKit suites, and the Debug build. Tests cover native
  all/global broadcasts, shared reload without replacing surfaces, scoped native
  configuration, local opacity across reload/new windows, independent pending sheets,
  stale callbacks after close, session/engine/view teardown, and engine reuse after
  closing every window. Existing PTY focus, composition, clipboard, and quit checks pass.

## Review conclusions retained

The original reviews were consolidated and removed. These rejected claims should
not reappear as open issues: incorrect precise-scroll scaling, treating exported
text/HTML file paths as arbitrary URLs, missing engine child-exit/wait behavior,
Foundation nested-path handling, and retaining menu shortcuts after explicit unbind.
Speculative GTK ports, moving TOML to Zig, untouched vendor names, and cosmetic
Xcode identifiers are outside this cleanup.
