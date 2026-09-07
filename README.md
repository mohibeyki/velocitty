# Velocitty

Velocitty is a native macOS terminal built with Swift and AppKit, powered by
[libghostty](https://github.com/ghostty-org/ghostty) through VeloKit, its private
terminal engine.

The goal is to manage terminal and agent sessions in a single window. Today,
Velocitty provides independent terminal windows with shell integration, search,
copy/paste, clickable links, and file-based configuration. Tabs, panes, and
persistent multiplexing are still ahead.

## Build and run

Requires an Apple Silicon Mac, macOS 13+, full Xcode with the Metal toolchain,
and Nix with flakes and direnv. Install Metal if needed:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Build VeloKit with the pinned Zig toolchain, then the app:

```sh
cd VeloKit
direnv allow
zig build -Doptimize=ReleaseFast
ditto build/VeloKit.xcframework ../macos/VeloKit.xcframework
cd ../macos
xcodebuild -project Velocitty.xcodeproj -scheme Velocitty \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build
open build/Build/Products/Debug/Velocitty.app
```

Rebuild and copy VeloKit whenever its source changes. The generated framework
is ignored by Git. `macos/` contains the app; `VeloKit/` contains the engine.

## Tests

After building VeloKit, run configuration and native bridge tests from the repo root:

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
process settings apply to the next terminal.

The default theme follows macOS appearance using Rosé Pine and Rosé Pine Dawn.
Eleven iTerm2 themes are bundled across Rosé Pine, Tokyo Night, and Catppuccin.
The shell starts in `~/workspace`, falling back to `~` if it does not exist.

## License

Velocitty and VeloKit use GPLv3. See [LICENSE](LICENSE). Third-party licenses and
provenance are collected in [VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
