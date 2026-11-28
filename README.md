# Velocitty

Velocitty is a native macOS terminal for managing terminal and agent sessions in
one window. It is built with Swift and AppKit, uses
[libghostty](https://github.com/ghostty-org/ghostty) through its private VeloKit
engine, and uses [herdr](https://github.com/herdrdev/herdr) for persistent sessions.

Namespaces group projects, tabs group work, and panes show individual terminals.
Velocitty owns spaces, presentation, and focus; herdr owns running processes.
A space can mix tabs from local and remote connections. Each tab’s panes can span
connections. Tabs can move between spaces or appear side by side without moving
or restarting their processes.

## Roadmap

- [x] **Terminal foundation:** interactive shells, shell integration, copy/paste,
  search, links, file drops, and native window controls.
- [x] **Configuration:** TOML, default-config export, categorized native settings
  editor with effective values and source diagnostics, per-file reset, reload, and
  independent interface colors and automatic light/dark terminal themes.
- [x] **Namespaces and tabs:** naming, ordering, keyboard navigation, compact
  sidebar, drag-and-drop ordering, and Git branch/cwd subtitles.
- [x] **Panes:** nested splits, directional focus, resizing by keyboard or divider,
  zoom, equalization, moves between tabs, and mixed-server layouts.
- [x] **Workspace presentation:** live search across namespaces, tabs, and agents;
  side-by-side tabs, tab-to-window moves, and local focus across servers.
- [x] **Persistence and recovery:** restore windows, ordering, selections, sidebar,
  and side-by-side presentation; preserve damaged state and reconnect to the same IDs.
- [x] **Session restore:** after a reboot or lost herdr session, rebind or recreate
  each saved terminal at its working directory with its tab, split ratios, and
  selection, and show its recent output above the new prompt. Standalone windows
  restore their directory and output too. Turn off with `restore_session`.
- [x] **Close undo:** briefly retain closed terminals, restore their original
  surfaces, and retry unfinished explicit closes after connection failures.
- [x] **Remote sessions:** TOML connections, SSH transport, multiple servers
  in one space or tab, independent local sessions, connection enable/disable,
  remote Git metadata, and restoration of unavailable tabs.
- [x] **Agents:** clickable monochrome icons, accessible status badges, an overview,
  waiting-agent navigation, and configurable notifications enabled by default.
- [ ] **Distribution:** release builds, signing, notarization, and updates.
- [ ] **Linux frontend:** a separate native frontend sharing the terminal engine.

## Build and run

Requires an Apple Silicon Mac, macOS 13+, full Xcode with the Metal toolchain,
and Nix with flakes and direnv. Install Metal if needed:

```sh
xcodebuild -downloadComponent MetalToolchain
```

From the repository root:

```sh
direnv allow
just build
just run
```

The root direnv environment provides pinned Zig and Just through Nix. Enable
[direnv’s shell hook](https://direnv.net/docs/hook.html) so they are available when
you enter the repository. Without the hook, use `direnv exec . just build`.

`zig build` and `zig build run` are the underlying commands. The app is written to
`zig-out/Velocitty.app`; opening that bundle directly does not build anything.
The engine is optimized by default; `just release` also enables Swift release
optimizations. Use `zig build -Doptimize=Debug` to debug the engine.

You can still run the scheme in Xcode. Its build phase uses the same root build
entry point for VeloKit. `macos/` contains the app; `VeloKit/` contains the private
engine, pinned toolchain definition, and bundled third-party notices.

## Sessions and navigation

Install **herdr 0.8.2+** for local multiplexing, or **herdr 0.9+ on both ends** for
remote sessions. Without herdr, Velocitty provides standalone terminal windows.
Set `VELOCITTY_DISABLE_HERDR=1` to launch as if herdr were not installed (no session, workspace or
scrollback state is read or written). Useful for debugging and benchmarks.
The local herdr session is named `velocitty`. Window close and quit detach;
explicit pane, tab, and namespace closes end their terminals after the undo
window. Rebooting does not preserve running processes; it does not lose the layout
either. When a local herdr session starts anew, Velocitty restores each saved tab,
split, and selection into terminals at their last directory, and prints the
terminal's last 2000 lines (dimmed, above a "restored session" line) before the
new prompt. Standalone windows come back the same way through macOS window
restoration (`window_save_state`). The text is kept in owner-only files in
`scrollback/` next to `workspace.json`, and is removed when the terminal is closed
for good. An unreachable or disabled remote still shows its tabs as unavailable
until it returns. Set `restore_session = false` under `[interface]` to turn this off
and delete the saved text.

| Work | Default shortcuts |
| --- | --- |
| Tabs | ⌘T create, ⌘W close, ⌘1–9 select, ⌘[ / ⌘] switch |
| Namespaces | Ctrl-T create, Ctrl-W close, Ctrl-1–9 select, Ctrl-[ / Ctrl-] switch, Ctrl-R rename |
| Panes | Ctrl-\ side by side, Ctrl-minus stacked, Ctrl-H/J/K/L focus, Ctrl-Shift-arrows resize, Ctrl-Shift-W close |
| Find work | ⌘P workspace search, ⌘Shift-P command palette |
| Close undo | ⌘Z undo, ⌘Shift-Z redo; duration comes from `undo_timeout` |

Use the command palette for **Show Tab Alongside**, pane moves, zoom, equalization,
connection-specific tabs/splits, **Show Agents**, and **Next Agent Waiting for Input**.
Drag tabs to reorder them or move them onto another space; drag spaces to reorder.
Agent icons focus their exact terminals. Status comes from herdr and becomes unknown
when disconnected. Notifications are enabled by default for waiting/completion
transitions; disable them with `agent_notifications = false` under `[interface]`.

Use **Velocitty → Connections** to add, edit, enable/disable, and remove local
or SSH instances, retry a connection, or create a tab on it. Changes are saved to
TOML, including the appropriate included file. Removing a connection keeps its
processes running; reuse its connection ID to restore saved panes. SSH uses existing keys and known hosts;
start the selected herdr session on the destination first.

```toml
[[connections]]
id = "local"
name = "Laptop"
session = "velocitty"

[[connections]]
id = "gpu"
name = "GPU cluster"
host = "user@cluster"
session = "work"
enabled = true
```

Connection IDs are stable references in saved workspaces: keep the ID when renaming
an entry, and use a new ID when changing its host or session. Reload configuration
to apply changes. Disabling or removing an entry preserves its running processes
and offline tabs; restoring the same entry reconnects them. Without a connection
list, the default local session is used. An explicit `connections = []` at the
root disables all connections. Included files replace the entire list when they
specify one. Old `connections.json` files are no longer read; copy desired entries
to TOML using the same IDs.

New tabs inherit the active connection unless another is selected in Connections.
Local file drops always use the default local server. Workspace state lives in
`~/Library/Application Support/Velocitty/workspace.json`. Upgrades keep a versioned
backup; damaged state is preserved before rebuilding the workspace. Shell
configuration belongs to herdr. New local shells receive bundled integration
hooks; existing shells and remote shell configuration are left intact.

## Configuration

Choose **Velocitty → Settings** or edit `~/.config/velocitty/config.toml`
(`$XDG_CONFIG_HOME/velocitty/config.toml` when that variable is an absolute path).
Settings provides categories, search, numeric/color/list controls, effective values,
source information, diagnostics, and an advanced TOML editor. **Reset Override** removes the selected file’s override; included files may
still supply a value. The editor preserves comments and unknown settings, and checks
for external edits before saving. Reload with ⌘Shift-comma; process settings apply
to newly created terminals.

Generate a commented reference containing available settings and their defaults:

```sh
zig-out/Velocitty.app/Contents/MacOS/Velocitty \
  --dump-config > defaults.toml
```

Use **Velocitty → Terminal Theme** (also in the command palette and Settings)
to search themes and preview their colors before applying. Choose one theme or
separate light/dark themes that follow macOS appearance.
The default terminal theme follows macOS appearance using Rosé Pine/Dawn.
Eleven iTerm2 variants from Rosé Pine, Tokyo Night, and Catppuccin are bundled.
Interface colors and agent indicator appearance are independently configurable.
Invalid settings are reported and skipped, retaining defaults or earlier valid
values. The initial local directory is `~/workspace`, falling back to `~`.

## Tests

```sh
just test
```

This runs configuration and Core checks. `just test-gui` also runs window and
isolated herdr integration checks; it requires an unlocked desktop and briefly
changes focus. The equivalent Zig steps are `zig build test` and `zig build test-gui`.
The opt-in `WindowChecks
--remote-check` additionally requires `VELO_TEST_HERDR`, `VELO_TEST_SSH_HOST`, and
`VELO_TEST_KNOWN_HOSTS`; point the SSH host at this Mac’s IP. It creates isolated
local servers and reaches one through SSH; no production cluster is needed. GitHub Actions runs the configuration and Core
checks on pushes and pull requests. `WindowChecks --scale` measures 50 terminals
across three isolated local servers. These checks require the built app’s resources
via `VELOKIT_RESOURCES_DIR`.

## License

Velocitty and VeloKit use GPLv3. See [LICENSE](LICENSE). Third-party licenses and
provenance, including agent icons from [Lobe Icons](https://github.com/lobehub/lobe-icons),
are collected in [VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
