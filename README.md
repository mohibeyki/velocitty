# Velocitty

Velocitty is a native macOS terminal built with Swift and AppKit, powered by
[libghostty](https://github.com/ghostty-org/ghostty) through VeloKit, its private
terminal engine.

The goal is to manage terminal and agent sessions in a single window. Today,
Velocitty provides tabbed terminal windows with shell integration, search,
copy/paste, clickable links, split panes, and file-based configuration. Local
multiplexing uses herdr.

## Roadmap

Planned in the order below. Velocitty owns namespaces, tabs, pane layouts, and
rendering; herdr owns the running terminal sessions.

- [x] **Terminal foundation:** native AppKit windows, interactive user shells,
  shell integration, search, copy/paste, clickable links, and file drops.
- [x] **Configuration and appearance:** TOML settings, default-config export,
  reload support, bundled themes, and automatic light/dark appearance.
- [x] **Basic window controls:** create and close windows, quit confirmation,
  window restoration with fresh shells, and a searchable command palette.
- [x] **Tabs:** create, close, rename, reorder, and switch tabs within a window;
  retain each terminal's state when switching and add menu/keyboard navigation.
- [x] **Namespaces:** named groups in a compact left sidebar;
  each owns its tabs and remembers its selected tab. Showing terminals from
  different namespaces side by side remains a later workspace feature.
- [x] **Local herdr MVP:** attach individual terminals to VeloKit for input,
  output, and resizing. Reconnect to the dedicated local session on launch;
  require herdr for tabs and namespaces.
- [x] **Pane MVP:** split tabs horizontally or vertically, move focus, resize
  through menu/keyboard controls, and close individual panes. Restore herdr
  split layouts and route input to the focused pane.
- [ ] **Pane polish:** draggable dividers, zoom, equalization, and refined styling.
- [x] **Workspace state:** restore namespace/tab order, active selections, and
  sidebar width/compact mode against live herdr sessions and split layouts.
- [ ] **Window restoration:** restore window placement and assign namespaces to
  their previous windows; workspace sessions currently reopen together.
- [ ] **Connection recovery:** reconnect automatically after transport failures
  and synchronize changes made by other herdr clients.
- [x] **Agent status:** compact icons show herdr’s working, waiting, idle, and
  completed states; click an icon to focus its pane. Border appearance is reloadable.
- [ ] **Workspace search:** a centered title-bar search field for tabs and namespaces.
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
terminals in a window. ⌘[ / ⌘] switch tabs; ⌘1–⌘9 select
by position within the current namespace. Rename and reorder tabs from the Terminal
menu or command palette. Shortcuts follow the configured keybindings.

Each tab attaches directly to a herdr terminal and keeps its view state while
hidden. New tabs inherit the current directory by default. Closing a tab ends
all its panes; closing the last tab removes its namespace. The final namespace closes
the window. Closing a window or quitting detaches its views and leaves the herdr
terminals running. Exiting a shell closes its tab automatically.

Herdr retains namespaces, names, subtitles, terminals, and split layouts.
Velocitty saves namespace/tab order, active namespace/tab/pane, and sidebar state
in `~/Library/Application Support/Velocitty/workspace.json`, separate from TOML
preferences. Saves are automatic and atomic. Relaunching reconciles saved IDs
with live herdr sessions and attaches them in one window. Missing sessions are
removed from saved state only after a successful connection; new sessions append.
A connection failure preserves the saved workspace. Window placement and separate
window assignments are not restored yet; rebooting does not recreate processes.

## Panes

Use **Terminal → Split Vertically** (`Ctrl-\`) for side-by-side terminals or
**Split Horizontally** (`Ctrl-minus`) for stacked terminals. Splits can be nested.
Click a pane to focus it, or use Ctrl-H/J/K/L for left/down/up/right. These
keys pass through to the terminal when there is only one pane. The focused pane has an accent outline. Resize Pane menu commands
adjust the split, with Ctrl-Shift-arrow shortcuts; divider dragging is deferred.

Ctrl-Shift-W closes the focused pane. ⌘W closes every pane in the current tab.
Closing or exiting the last pane closes its tab. Herdr retains split layouts
and running terminals when the window closes or the app quits.

## Namespaces

Use the left sidebar or **Namespace** menu to create, select, rename, and close
namespaces. Expanded rows show the name above smaller, muted Git branch and cwd
subtitles, followed by agent icons. The branch and agent rows are omitted when absent.
Branch and cwd follow the selected pane; compact mode keeps the numbered column.
Ctrl-R renames the current namespace. Ctrl-1–Ctrl-9
select namespaces by position. Ctrl-T creates a namespace, Ctrl-W closes it,
and Ctrl-[ / Ctrl-] switch namespaces. Switching returns to that namespace's selected
tab, with its shells still running. Closing a namespace checks all its tabs
before ending them.

Monochrome agent marks are bundled for Codex, Claude, Grok, Gemini, Cursor,
GitHub Copilot, OpenCode, Kimi, Amp, Cline, Kilo Code, Qwen, Devin, Antigravity,
Kiro, and Qoder. Other agents use a terminal symbol. The icons come from
[Lobe Icons](https://github.com/lobehub/lobe-icons); provenance and license are in
[VeloKit’s third-party notices](VeloKit/THIRD_PARTY_NOTICES.md).

## Multiplexing

Install **herdr 0.8.2 or newer** to enable tabs and namespaces. Velocitty finds it
on `PATH` or in common Homebrew, Nix, Cargo, and user-local installation paths.
Without it, Velocitty warns and provides standalone terminal windows.

Velocitty starts or reconnects to a dedicated local herdr session named
`velocitty`. Each view runs `herdr terminal attach` for one terminal, so input,
output, and resizing use herdr's existing client. Closing a window or quitting
detaches; **Close Tab** and **Close Namespace** end the corresponding terminals.
Herdr owns shell configuration and process lifetime. Windows opened with
Velocitty's `command` or `initial_command` setting remain standalone.

Automatic reconnection and live synchronization of changes made outside
Velocitty are deferred.

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
Terminal settings belong under `[terminal]`:

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
Standalone window restoration follows macOS preferences and starts fresh shells
in saved directories. Herdr-backed windows reconnect to their running terminals.

Agent indicators use herdr’s reported identity and state. Appearance lives in the
`[interface]` table of `config.toml`; the default-config export includes every
option. Adjust icon size, border width, per-state colors/styles, and animation
duration, then use **Reload Configuration** (⌘⇧,). No rebuild is needed.
The interface `theme` (`dark`, `light`, or `auto`) is independent of the terminal
palette. Its `chrome_background_color`, `chrome_foreground_color`,
`chrome_selected_color`, and `chrome_border_color` control the shared window,
tab appearance. The namespace sidebar uses the native macOS material and
selection color; its divider can be dragged, and the sidebar toggle switches to a narrow numbered namespace column. Ctrl-R renames the namespace; namespace and tab
actions are also available in the command palette. Each tab has its own close button.

## License

Velocitty and VeloKit use GPLv3. See [LICENSE](LICENSE). Third-party licenses and
provenance are collected in [VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
