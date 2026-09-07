# Cleanup review

Updated 2026-09-06. This is the working list for the cleanup session. Original issue
IDs are retained; resolved findings and rejected claims are removed from the queue.

Discuss one issue at a time: choose an approach, implement it, validate it, update
this file, and commit the change as a self-contained chunk. A recommendation below
is not an approved decision. **Current issue: C12a — awaiting a choice.**

Scope: our macOS host, private VeloKit bridge, configuration, and build/test integration.
Untouched libghostty internals and new mux functionality are outside this cleanup.

## Remaining issues

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
| C09 | Build regression executables as Xcode targets; run them through XCTest Core/GUI plans and add CI for configuration, native bridge, and app builds. |
| C10 | Build the private static engine, headers, and terminfo as an Xcode dependency through direnv and Zig; remove manual XCFramework packaging/copying. |
| C11 | Prepare base/override configurations before application; use best-effort reloads and engine notifications for applied snapshots. Report invalid values and use defaults or earlier valid values; refresh native controls. |
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
  updating siblings. Reload failure semantics are handled in C11; persistence is future work.
  Validation: rebuilt VeloKit and passed native bridge/configuration tests, 13 Swift
  configuration tests, both AppKit suites, and the Debug build. Tests cover native
  all/global broadcasts, shared reload without replacing surfaces, scoped native
  configuration, local opacity across reload/new windows, independent pending sheets,
  stale callbacks after close, session/engine/view teardown, and engine reuse after
  closing every window. Existing PTY focus, composition, clipboard, and quit checks pass.

- **C09 — standard test targets and CI.** Approved option 1.
  EngineChecks and WindowChecks build with Xcode. XCTest launches each check in its
  own process, captures output in test-result attachments, and reports crashes,
  nonzero exits, missing completion markers, and timeouts as failures. This isolates
  the intentional quit test from the test runner. Existing checks and assertions are
  preserved. The shared Velocitty scheme defaults to Core; GUI runs both interactive
  lifecycle/quit checks serially. SwiftPM retains the configuration test target.
  CI uses an Apple Silicon macOS runner, builds the engine through the pinned Nix
  flake, and runs configuration tests and the Core plan. GUI tests remain local.
  Actions are pinned to commits; results are uploaded for inspection. README contains
  all test commands and desktop requirements.
  Validation: Core and both GUI tests passed through xcodebuild test; the CI engine
  build command passed locally, and actionlint accepted the workflow. Configuration
  tests passed earlier in this cleanup. The GitHub workflow has not run remotely;
  its first run awaits a push. Automatic local engine builds are handled by C10.

- **C10 — automatic engine build dependency.** Approved option 1.
  Velocitty, EngineChecks, and WindowChecks depend on a shared VeloKitEngine target.
  It invokes direnv and the pinned Zig environment on each build, allowing Zig to
  check source/toolchain changes and reuse cached work. The private static archive,
  module headers, and terminfo install beneath DerivedData, separately by configuration.
  Xcode tracks their outputs before compiling, linking, and copying resources.
  XCFramework packaging and manual copying are removed; CI uses the same Xcode path.
  Standard rsync keeps generated terminfo exact, including removal of obsolete entries.
  README documents one-time direnv authorization and ordinary Xcode builds/tests.
  Validation: Core tests pass from fresh DerivedData with old framework copies absent;
  both GUI tests and a Release archive pass. A temporary native compile error rejected
  the build despite an existing library, and was then reverted. Restricted-PATH builds
  find direnv, repeated identical builds preserve artifact mtimes, stale terminfo entries
  disappear from generated output and the app bundle, and Clean removes generated outputs.
  Core tests pass again after Clean. Workflow syntax passes actionlint; remote CI still
  awaits a push.

- **C11 — best-effort reload and default fallback.** Approved Ghostty-like behavior;
  no rollback. TOML decoding collects per-setting/per-array-element diagnostics and
  preserves valid values. Unreadable, malformed, or cyclic includes are reported
  without discarding valid settings in other files. Invalid native values are omitted
  from a fresh configuration; valid repeatable entries survive. Invalid themes fall
  back to bundled Rose Pine/Dawn, preserving explicit overrides.
  The shared configuration and local opacity overrides are prepared before any live
  update, with overrides cloned from the prepared base rather than rereading themes.
  App and surface config-change callbacks synchronously copy borrowed configurations;
  host controls use those applied snapshots. Optional titlebar colors come from the
  native result so rejected values cannot enable custom titlebars. Application errors
  are reported without rollback or stopping subsequent local override updates.
  Startup/manual reload shows a scrollable diagnostic list after applying valid
  settings; appearance refresh logs diagnostics. Fatal preparation failures still
  stop the reload before application. Untouched engine updates remain best-effort,
  not an all-or-nothing transaction.
  Validation: 16 Swift configuration tests, native bridge/Core tests, and the focused
  AppKit configuration-reload test pass. Coverage includes mixed invalid values,
  includes, bad themes, non-finite numbers, repeated options, diagnostic ownership,
  native path diagnostics, two live terminals, local opacity, applied-config lifetime,
  updated controls, visible diagnostics, and theme removal after preparation.
  Full GUI lifecycle/quit retesting is pending an unlocked desktop: macOS reported
  `CGSSessionScreenIsLocked=Yes`, preventing the test app from acquiring focus.

## Review conclusions retained

The original reviews were consolidated and removed. These rejected claims should
not reappear as open issues: incorrect precise-scroll scaling, treating exported
text/HTML file paths as arbitrary URLs, missing engine child-exit/wait behavior,
Foundation nested-path handling, and retaining menu shortcuts after explicit unbind.
Speculative GTK ports, moving TOML to Zig, untouched vendor names, and cosmetic
Xcode identifiers are outside this cleanup.
