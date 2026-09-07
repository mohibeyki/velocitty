# Velocitty

Velocitty is a native macOS terminal built with Swift and AppKit, powered by
[libghostty](https://github.com/ghostty-org/ghostty) through VeloKit, its private
terminal engine.

The goal is to manage terminal and agent sessions in a single window. Today,
Velocitty provides tabbed terminal windows with shell integration, search,
copy/paste, clickable links, and file-based configuration. Panes, namespaces,
and persistent multiplexing are still ahead.

## Roadmap

Planned in the order below. Velocitty owns namespaces, tabs, pane layouts, and
rendering; herdr integration comes after those interfaces are established.

- [x] **Terminal foundation:** native AppKit windows, interactive user shells,
  shell integration, search, copy/paste, clickable links, and file drops.
- [x] **Configuration and appearance:** TOML settings, default-config export,
  reload support, bundled themes, and automatic light/dark appearance.
- [x] **Basic window controls:** create and close windows, quit confirmation,
  window restoration with fresh shells, and a searchable command palette.
- [x] **Tabs:** create, close, rename, reorder, and switch tabs within a window;
  retain each terminal's state when switching and add menu/keyboard navigation.
- [ ] **Panes:** split tabs horizontally or vertically, resize dividers, move
  focus, and close individual panes. Route input, terminal resizing, and commands
  to the correct pane.
- [ ] **Namespaces:** create, rename, and switch named groups of tabs and sessions.
  Keep session identity separate from where it is displayed, so terminals from
  different namespaces can appear side by side in the same window.
- [ ] **Workspace restoration:** save namespace organization, tab order, pane
  layouts, and the active selection. Initially reopen fresh shells in saved
  directories; preserving running processes belongs to the next milestone.
- [ ] **Local herdr integration:** connect individual sessions to VeloKit for
  input, output, and resizing while retaining Velocitty's own navigation and UI.
  Start with one session, then support independent streams across tabs and panes.
- [ ] **Persistent running sessions:** detach when Velocitty quits and reconnect
  to the same processes on relaunch. Handle connection loss, recover terminal
  contents, and distinguish closing a view from terminating its session.
- [ ] **Agent status:** surface working, waiting, and completed states on the
  corresponding sessions and make it easy to jump to agents needing attention.
- [ ] **Remote sessions:** bring sessions on other machines into the same
  namespace/tab/pane interface, with reconnect behavior and clear host identity.

## Build and run

Requires an Apple Silicon Mac, macOS 13+, full Xcode with the Metal toolchain,
and Nix with flakes and direnv. Install Metal if needed:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Allow the pinned build environment once, then build from the repo root:

```sh
direnv allow VeloKit
xcodebuild -project macos/Velocitty.xcodeproj -scheme Velocitty \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/build build
open macos/build/Build/Products/Debug/Velocitty.app
```

You can also open the project in Xcode and run the Velocitty scheme. Every build
checks VeloKit through direnv and Zig; unchanged work uses Zig's cache. The private
library, headers, and terminfo are generated in DerivedData. No manual engine build
or copying is needed. `macos/` contains the app; `VeloKit/` contains the engine.

## Tabs

Use **Terminal → New Tab** (⌘T), **Close Tab** (⌘W), and the tab strip to manage
terminals in a window. Control-Tab / Control-Shift-Tab switch tabs; ⌘1–⌘8 select
by position and ⌘9 selects the last tab. Rename and reorder tabs from the Terminal
menu or command palette. Shortcuts follow the configured keybindings.

Each tab keeps its own running shell, terminal output, and search state while
hidden. New tabs inherit the current directory by default. Closing a tab ends
its shell; closing the last tab closes the window. Closing a window or quitting
checks every tab for processes that need confirmation.

Tab layouts and names are not saved across launches yet. Window restoration
currently applies to single-tab windows; multi-tab workspace restoration is a
later milestone.

## Tests

Run configuration and native bridge tests from the repo root:

```sh
swift test --package-path macos
xcodebuild -project macos/Velocitty.xcodeproj -scheme Velocitty \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath macos/build \
  -testPlan Core test
```

Use `-testPlan GUI` for the window, input, clipboard, and quit checks. Run these on
an unlocked desktop with another application open; the tests briefly switch focus.
Both plans are available in Xcode's Velocitty scheme. Failures include captured logs
in the test results. GitHub Actions builds the engine and app and runs the Core and
configuration tests on pushes and pull requests.

## Configuration

Edit `~/.config/velocitty/config.toml` (or
`$XDG_CONFIG_HOME/velocitty/config.toml` when that variable is an absolute path).
Settings belong under `[terminal]`:

```toml
[terminal]
font_size = 14
```

To generate a commented TOML reference containing every available setting and
its default, run the app executable directly. From the repository root:

```sh
macos/build/Build/Products/Debug/Velocitty.app/Contents/MacOS/Velocitty \
  --dump-config > defaults.toml
```

You can use that file as your configuration and uncomment the settings you want
to change. Choose **Velocitty → Reload Configuration** (**⌘⇧,**) after editing;
process settings apply to the next terminal. Invalid values are reported and skipped,
leaving defaults or earlier valid values. Unreadable or malformed files are reported
and contribute defaults; valid settings from other included files still load. Includes
load after the main file, in queue order. Repeatable settings follow the engine’s
append/reset rules; an empty array resets that setting.

The default theme follows macOS appearance using Rosé Pine and Rosé Pine Dawn.
Eleven iTerm2 themes are bundled across Rosé Pine, Tokyo Night, and Catppuccin.
The shell starts in `~/workspace`, falling back to `~` if it does not exist.
Window restoration follows macOS preferences and starts fresh shells in saved
directories; it does not keep processes running after the app quits.

## License

Velocitty and VeloKit use GPLv3. See [LICENSE](LICENSE). Third-party licenses and
provenance are collected in [VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
