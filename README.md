# Velocitty

Velocitty is a small macOS terminal application built with AppKit and
[libghostty](https://github.com/ghostty-org/ghostty). The application owns the
window and macOS input layer; [VeloKit](VeloKit/) provides the terminal engine,
renderer, fonts, and process integration.

The current target is a useful terminal MVP:

- one resizable terminal window;
- the user's default shell, with interactive input and output;
- Copy, Paste, and Select All through the Edit menu and keyboard shortcuts;
- a basic menu bar with About, Edit, and Window commands;
- no tabs, multiplexing, settings, or other application-level features yet.

Development is focused on making the libghostty-backed terminal solid before
adding higher-level features or another platform frontend. There is no Linux
application in this tree yet.

## Repository layout

| Path | Purpose |
| --- | --- |
| `macos/` | Swift AppKit application and Xcode project |
| `VeloKit/` | Private terminal engine derived from libghostty |
| `macos/VeloKit.xcframework/` | Generated framework consumed by Xcode; ignored by Git |
| `LICENSE` | Velocitty project license |
| `VeloKit/THIRD_PARTY_NOTICES.md` | Third-party provenance and license notices |

This README is the canonical project guide. The remaining Markdown files under
VeloKit are source-local implementation notes or vendor documentation, not
additional user-facing project guides.

## Requirements

- Apple Silicon Mac running macOS 13 or newer;
- full Xcode with the macOS SDK and Metal toolchain;
- Nix with flakes enabled and `direnv`;
- an installed interactive user shell.

The VeloKit development environment supplies the pinned Zig 0.16.0 toolchain.
It does not install a shell or replace the system Xcode installation.

If the Metal toolchain is not installed, add it from Xcode's **Settings →
Components → Metal Toolchain**, or run:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Build VeloKit

Enter the VeloKit directory and allow direnv to load the development shell:

```sh
cd VeloKit
direnv allow
zig version
zig build -Doptimize=ReleaseFast
```

To use an existing Zig 0.16.0 installation instead of the Nix shell, set
`VELOKIT_ZIG_HOME` before entering the directory:

```sh
export VELOKIT_ZIG_HOME=/path/to/zig-0.16.0
```

The build supports only Apple Silicon macOS and writes
`VeloKit/build/VeloKit.xcframework`. Copy that generated framework into the
macOS project before building the app:

```sh
ditto build/VeloKit.xcframework ../macos/VeloKit.xcframework
```

If `xcode-select -p` points to the Command Line Tools instead of full Xcode,
set `DEVELOPER_DIR` to the installed Xcode before building. For example:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The repository's `VeloKit/.envrc` also selects a full Xcode installation when
one is available. Set `VELOKIT_DEVELOPER_DIR` when a different installation
should be used.

## Build and run the macOS app

From the macOS project directory:

```sh
cd macos
xcodebuild \
  -project Velocitty.xcodeproj \
  -scheme Velocitty \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  build
open build/Build/Products/Debug/Velocitty.app
```

The app starts one terminal surface and launches the default user shell in
`~/workspace`, the current development default, regardless of where the app was
launched. The generated framework is intentionally ignored, so rebuild VeloKit and copy it
again whenever the library changes.

The app uses VeloKit's default configuration; it does not load another terminal's
configuration files. VeloKit diagnostics use the `app.velocitty.velokit` macOS
logging subsystem.

## VeloKit boundary

VeloKit is an implementation detail of Velocitty, not a standalone library or
SDK. `include/velokit.h` is the private Swift/Zig bridge and declares only the
`velokit_*` functions the app uses. Shared engine structures retain their
upstream names and layouts; this is not a promise of external API compatibility.

The XCFramework is an internal Xcode build artifact containing `libvelokit.a`.
Only the Apple Silicon macOS static build is supported. There are no standalone
CLI, VT-library, WebAssembly, documentation-generator, or benchmark products.
Crash reporting and gettext translations are excluded from the app build.

VeloKit is a local fork maintained for this project. Its source revision,
provenance, and retained third-party notices are documented in
[VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).

## License

Velocitty and VeloKit are licensed under GPLv3; see [LICENSE](LICENSE)
and [VeloKit/LICENSE](VeloKit/LICENSE). Components derived from libghostty and
other dependencies retain their original license terms, which are collected in
[VeloKit/THIRD_PARTY_NOTICES.md](VeloKit/THIRD_PARTY_NOTICES.md).
