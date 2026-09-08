# Velocitty

Velocitty is a native macOS terminal for managing terminal and agent sessions in
one window. It is built with Swift and AppKit, uses
[libghostty](https://github.com/ghostty-org/ghostty) through its private VeloKit
engine, and uses [herdr](https://github.com/herdrdev/herdr) for persistent sessions.

Namespaces group projects, tabs group work, and panes show individual terminals.
Velocitty owns presentation and focus; herdr owns running processes. Local and
remote namespaces can share a window, and tabs from different namespaces can be
shown side by side without moving their terminals.

## Roadmap

- [x] **Terminal foundation:** interactive shells, shell integration, copy/paste,
  search, links, file drops, and native window controls.
- [x] **Configuration:** TOML, default-config export, native settings editor,
  reload, independent interface colors, and automatic light/dark terminal themes.
- [x] **Namespaces and tabs:** naming, ordering, keyboard navigation, compact
  sidebar, Git branch/cwd subtitles, and monochrome agent status indicators.
- [x] **Panes:** nested splits, directional focus, resizing by keyboard or divider,
  zoom, equalization, and moves between tabs and namespaces.
- [x] **Workspace presentation:** live search across namespaces, tabs, and agents;
  side-by-side tabs, tab-to-window moves, and local focus across servers.
- [x] **Persistence and recovery:** restore windows, ordering, selections, sidebar,
  and side-by-side presentation; reconnect interrupted streams to the same IDs.
- [x] **Close undo:** briefly retain closed terminals, restore their original
  surfaces, and retry unfinished explicit closes after connection failures.
- [x] **Remote sessions:** herdr machine profiles, SSH transport, multiple servers
  in one window, remote Git metadata, and restoration of saved connections.
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
direnv allow VeloKit
xcodebuild -project macos/Velocitty.xcodeproj -scheme Velocitty \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/build build
open macos/build/Build/Products/Debug/Velocitty.app
```

You can also run the scheme in Xcode. Builds check VeloKit through direnv and Zig;
unchanged work uses Zig’s cache. `macos/` contains the app; `VeloKit/` contains the
private engine and bundled third-party notices.

## Sessions and navigation

Install **herdr 0.8.2+** for local multiplexing, or **herdr 0.9+ on both ends** for
remote sessions. Without herdr, Velocitty provides standalone terminal windows.
The local herdr session is named `velocitty`. Window close and quit detach;
explicit pane, tab, and namespace closes end their terminals after the undo
window. Rebooting does not preserve running processes.

| Work | Default shortcuts |
| --- | --- |
| Tabs | ⌘T create, ⌘W close, ⌘1–9 select, ⌘[ / ⌘] switch |
| Namespaces | Ctrl-T create, Ctrl-W close, Ctrl-1–9 select, Ctrl-[ / Ctrl-] switch, Ctrl-R rename |
| Panes | Ctrl-\ side by side, Ctrl-minus stacked, Ctrl-H/J/K/L focus, Ctrl-Shift-arrows resize, Ctrl-Shift-W close |
| Find work | ⌘P workspace search, ⌘Shift-P command palette |
| Close undo | ⌘Z undo, ⌘Shift-Z redo; duration comes from `undo_timeout` |

Use the command palette for **Show Tab Alongside**, pane moves, zoom, equalization,
and the remaining window actions. Agent icons reflect herdr’s reported state;
unknown status is shown when a server cannot be reached.

For remote work, configure SSH access and add a herdr machine profile:

```sh
herdr machine add user@host --label Host --remote-session velocitty
```

Start the selected session on that host, then choose **Velocitty → Connections**.
Connections use existing SSH keys and known hosts. Enabled profiles previously
used by the saved workspace reconnect on launch; an unavailable server’s saved
layout is retained. Local file drops always use the local server.

Workspace state is stored separately from preferences in
`~/Library/Application Support/Velocitty/workspace.json`. Shell configuration
belongs to herdr. New local shells receive bundled integration hooks; existing
shells and remote shell configuration are left intact.

## Configuration

Choose **Velocitty → Settings** or edit `~/.config/velocitty/config.toml`
(`$XDG_CONFIG_HOME/velocitty/config.toml` when that variable is an absolute path).
The editor preserves comments, unknown settings, and included files, and checks
for external edits before saving. Reload with ⌘Shift-comma; process settings apply
to newly created terminals.

Generate a commented reference containing available settings and their defaults:

```sh
macos/build/Build/Products/Debug/Velocitty.app/Contents/MacOS/Velocitty \
  --dump-config > defaults.toml
```

The default terminal theme follows macOS appearance using Rosé Pine/Dawn.
Eleven iTerm2 variants from Rosé Pine, Tokyo Night, and Catppuccin are bundled.
Interface colors and agent indicator appearance are independently configurable.
Invalid settings are reported and skipped, retaining defaults or earlier valid
values. The initial local directory is `~/workspace`, falling back to `~`.

## Tests

```sh
swift test --package-path macos
xcodebuild -project macos/Velocitty.xcodeproj -scheme Velocitty \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath macos/build \
  -testPlan Core test
```

Use `-testPlan GUI` for window and isolated herdr integration checks. It requires
an unlocked desktop and briefly changes focus. The opt-in `WindowChecks
--remote-check` additionally requires `VELO_TEST_HERDR`, `VELO_TEST_SSH_HOST`, and
`VELO_TEST_KNOWN_HOSTS`; point the SSH host at this Mac’s IP. It creates isolated
local servers and reaches one through SSH; no production cluster is needed. GitHub Actions runs the configuration and Core
checks on pushes and pull requests.

## License

Velocitty and VeloKit use GPLv3. See [LICENSE](LICENSE). Third-party licenses and
provenance, including agent icons from [Lobe Icons](https://github.com/lobehub/lobe-icons),
are collected in [VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
