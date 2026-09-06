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
- file-based TOML configuration;
- no tabs or multiplexing yet.

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
`~/workspace` by default (falling back to `~` if that directory does not exist),
regardless of where the app was launched. The generated framework is intentionally ignored, so rebuild VeloKit and copy it
again whenever the library changes.

Xcode resolves the pinned [TOMLDecoder](https://github.com/dduan/TOMLDecoder)
Swift package automatically. VeloKit diagnostics use the `app.velocitty.velokit`
macOS logging subsystem.

## Configuration

Create `~/.config/velocitty/config.toml` to override the defaults. If
`XDG_CONFIG_HOME` is an absolute path in the app's environment, the file is
`$XDG_CONFIG_HOME/velocitty/config.toml` instead. Velocitty never creates or
rewrites this file. A missing or empty file uses defaults.

```toml
[terminal]
working_directory = "~/workspace"
font_family = ["Menlo", "Monaco"]
font_size = 14
font_feature = ["-calt"]
background = "#171923"
foreground = "#e2e8f0"
palette = ["0=#171923", "1=#f56565", "2=#68d391"]
cursor_style = "bar"
cursor_style_blink = false
window_padding_x = 10
window_padding_y = 8
scrollback_limit_lines = 10000
keybind = ["ctrl+shift+j=text:hello"]
env = ["EDITOR=nvim", "LANG=en_US.UTF-8"]
```

Settings live under `[terminal]`. Underscore names are canonical; Ghostty's
hyphenated spelling is also accepted. Using both spellings of the same key is
an error. Values use the vendored engine's syntax and defaults: TOML strings,
booleans, and numbers are passed to its existing parsers. Compound values such as
`"8,12"` padding, `"10%"` metric adjustments, and `"-calt"` font features remain
strings. Strings containing `#` must be quoted as shown above.

Repeatable settings accept either one value or a TOML array; array order is
preserved. Use arrays for fallback fonts, palette entries, font features,
keybindings, environment assignments (`"NAME=value"`), and input segments.
Other settings reject arrays. Empty strings, and empty arrays for repeatable
settings, reset to engine defaults. Omitted keys also use defaults. Nested TOML
tables and date/time values are not setting values.

The default working directory remains `~/workspace`, falling back to `~` if
that directory does not exist. `working_directory` accepts an existing accessible
absolute directory, `~`, `~/…`, `home`, or `inherit` (the launching process's
directory). An empty value restores Velocitty's default. Environment variables
in paths are not expanded. Background-image and shader paths follow the engine's
path rules: relative to the TOML file, with `~/` expansion and an optional `?`
prefix for optional assets.

The default font size is 13 points. The earlier app-specific 6–96 restriction
has been removed; finite sizes use the engine's native sizing rules. On reload,
the engine clamps font sizes to 1–255 points. Non-finite values are rejected.

Choose **Velocitty → Reload Configuration** (**⌘⇧R**) after editing. Validation
builds a new engine configuration before applying it; syntax errors, unknown
keys, invalid native values, and unavailable settings leave the active
configuration unchanged. Errors identify the configuration file and setting.
At startup, an invalid configuration offers **Use Defaults** or **Quit**.

Appearance and terminal behavior reload according to the engine's existing
rules. Process settings (`command`, `initial_command`, `env`, `input`, `term`,
and `working_directory`) apply on the next launch and never restart the current
shell. Font codepoint mappings and horizontal/vertical padding also require a new
terminal. Reload does not promise that every setting takes effect immediately.

Use `config_file = ["appearance.toml", "keys.toml"]` under `[terminal]` to include
other TOML files. Includes load in array order, then the containing file overrides
them by setting name (including whole arrays). Paths are relative to the containing
file; `~/` is supported. Prefix an include with `?` to make a missing file optional.
Cycles are errors. Asset paths stay relative to the file that declares them.

### Available terminal settings

The following list covers the configuration declarations in the vendored engine,
not settings from a different Ghostty release. These **87 settings** are connected
to the native parsers. Existing renderer/input behavior is retained.

| Setting | Repeated values |
| --- | --- |
| `abnormal_command_exit_runtime` | Scalar |
| `adjust_box_thickness` | Scalar |
| `adjust_cell_height` | Scalar |
| `adjust_cell_width` | Scalar |
| `adjust_cursor_height` | Scalar |
| `adjust_cursor_thickness` | Scalar |
| `adjust_font_baseline` | Scalar |
| `adjust_icon_height` | Scalar |
| `adjust_overline_position` | Scalar |
| `adjust_overline_thickness` | Scalar |
| `adjust_strikethrough_position` | Scalar |
| `adjust_strikethrough_thickness` | Scalar |
| `adjust_underline_position` | Scalar |
| `adjust_underline_thickness` | Scalar |
| `alpha_blending` | Scalar |
| `background` | Scalar |
| `background_image` | Scalar |
| `background_image_fit` | Scalar |
| `background_image_opacity` | Scalar |
| `background_image_position` | Scalar |
| `background_image_repeat` | Scalar |
| `bold_color` | Scalar |
| `clipboard_codepoint_map` | Array or scalar |
| `clipboard_trim_trailing_spaces` | Scalar |
| `clipboard_write` | Scalar |
| `clipboard_write_limit_bytes` | Scalar |
| `command` | Scalar |
| `config_file` | Array or scalar |
| `cursor_color` | Scalar |
| `cursor_opacity` | Scalar |
| `cursor_style` | Scalar |
| `cursor_style_blink` | Scalar |
| `cursor_text` | Scalar |
| `custom_shader` | Array or scalar |
| `custom_shader_animation` | Scalar |
| `enquiry_response` | Scalar |
| `env` | Array or scalar |
| `faint_opacity` | Scalar |
| `font_codepoint_map` | Array or scalar |
| `font_family` | Array or scalar |
| `font_family_bold` | Array or scalar |
| `font_family_bold_italic` | Array or scalar |
| `font_family_italic` | Array or scalar |
| `font_feature` | Array or scalar |
| `font_shaping_break` | Scalar |
| `font_size` | Scalar |
| `font_style` | Scalar |
| `font_style_bold` | Scalar |
| `font_style_bold_italic` | Scalar |
| `font_style_italic` | Scalar |
| `font_synthetic_style` | Scalar |
| `font_thicken` | Scalar |
| `font_thicken_strength` | Scalar |
| `font_variation` | Array or scalar |
| `font_variation_bold` | Array or scalar |
| `font_variation_bold_italic` | Array or scalar |
| `font_variation_italic` | Array or scalar |
| `foreground` | Scalar |
| `grapheme_width_method` | Scalar |
| `image_storage_limit` | Scalar |
| `initial_command` | Scalar |
| `input` | Array or scalar |
| `key_remap` | Array or scalar |
| `keybind` | Array or scalar |
| `minimum_contrast` | Scalar |
| `osc_color_report_format` | Scalar |
| `palette` | Array or scalar |
| `palette_generate` | Scalar |
| `palette_harmonious` | Scalar |
| `scroll_to_bottom` | Scalar |
| `scrollback_compression` | Scalar |
| `scrollback_limit_bytes` | Scalar |
| `scrollback_limit_lines` | Scalar |
| `selection_background` | Scalar |
| `selection_clear_on_copy` | Scalar |
| `selection_clear_on_typing` | Scalar |
| `selection_foreground` | Scalar |
| `term` | Scalar |
| `title` | Scalar |
| `title_report` | Scalar |
| `vt_kam_allowed` | Scalar |
| `wait_after_command` | Scalar |
| `window_padding_balance` | Scalar |
| `window_padding_color` | Scalar |
| `window_padding_x` | Scalar |
| `window_padding_y` | Scalar |
| `window_vsync` | Scalar |
| `working_directory` | Scalar |

### Limitations within available settings

| Setting | Current limit |
| --- | --- |
| `keybind` | Terminal-engine actions work. Actions requiring unimplemented app features (such as search, new tabs/panes, inspectors, and command palettes) do not. Global shortcuts need a macOS event registration path. AppKit menu shortcuts currently take precedence. |
| `clipboard_write` | `allow` and `deny` work; `ask` is rejected because confirmation UI is missing. Clipboard callbacks currently support plain text only. |
| `clipboard_codepoint_map` | Applies to supported text-copy operations; broader clipboard MIME support is not implemented. |
| `selection_background` | Colors keyboard-created selections; mouse selection needs event forwarding. |
| `selection_foreground` | Colors keyboard-created selections; mouse selection needs event forwarding. |
| `selection_clear_on_copy` | Works with existing copy/selection actions; mouse selection is not implemented. |
| `selection_clear_on_typing` | Works with existing selections; mouse selection is not implemented. |
| `background_image` | Image loading happens in the renderer; decoding/resource failures are logged rather than shown as configuration alerts. |
| `custom_shader` | Shader loading and GPU compilation happen in the renderer; failures are logged rather than shown as configuration alerts. |
| `title` | Setting a fixed title works; clearing it follows engine title reporting and may wait for the next shell title update. |

Clipboard operations that require confirmation are denied until that UI exists;
ordinary text pastes still work.

### Settings needing application integration

Each setting below is recognized but rejected with the explanation shown here,
so an inert setting cannot be mistaken for enabled functionality. These are
pending decisions, not newly implemented app features. Closely related settings
are still listed individually for review.

| Setting | What is missing |
| --- | --- |
| `app_notifications` | Needs AppKit/UserNotifications notification callbacks. |
| `async_backend` | Selects the process-wide I/O backend before TOML is loaded; needs startup restructuring. |
| `auto_update` | Needs an application updater. |
| `auto_update_channel` | Needs an application updater. |
| `background_blur` | Needs AppKit window/layer transparency and blur integration. |
| `background_opacity` | Needs AppKit window/layer transparency and blur integration. |
| `background_opacity_cells` | Needs AppKit window/layer transparency and blur integration. |
| `bell_audio_path` | Needs bell callbacks, audio playback, and app attention handling. |
| `bell_audio_volume` | Needs bell callbacks, audio playback, and app attention handling. |
| `bell_features` | Needs bell callbacks, audio playback, and app attention handling. |
| `class` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `click_repeat_interval` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `clipboard_paste_bracketed_safe` | Needs paste-confirmation UI; the current confirmation callback denies requests requiring confirmation. |
| `clipboard_paste_protection` | Needs paste-confirmation UI; the current confirmation callback denies requests requiring confirmation. |
| `clipboard_read` | Needs clipboard authorization prompts; the current confirmation callback denies requests requiring confirmation. |
| `command_palette_entry` | Needs a command palette UI. |
| `config_default_files` | Uses the upstream configuration-file format and search policy; Velocitty loads its own TOML file. |

| `confirm_close_surface` | Needs process-aware close confirmation; closing currently terminates the terminal directly. |
| `copy_on_select` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `cursor_click_to_move` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `desktop_notifications` | Needs AppKit/UserNotifications notification callbacks. |
| `drag_handle` | Needs configurable AppKit window creation, appearance, or state handling. |
| `focus_follows_mouse` | Needs pane layout, focus, and split rendering in the app. |
| `freetype_load_flags` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `fullscreen` | Needs configurable AppKit window creation, appearance, or state handling. |
| `gtk_custom_css` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_horizontal_tab_scroll` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_opengl_debug` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_quick_terminal_layer` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_quick_terminal_namespace` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_single_instance` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_tabs_location` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_titlebar` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_titlebar_hide_when_maximized` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_titlebar_style` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_toolbar_style` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `gtk_wide_tabs` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `initial_window` | Needs configurable application lifecycle behavior. |
| `language` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `link` | Needs pointer interaction and the open-URL callback. |
| `link_osc8` | Needs pointer interaction and the open-URL callback. |
| `link_previews` | Needs link hover handling and a preview UI. |
| `link_url` | Needs pointer interaction and the open-URL callback. |
| `linux_cgroup` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `linux_cgroup_hard_fail` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `linux_cgroup_memory_limit` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `linux_cgroup_processes_limit` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `macos_applescript` | Needs an AppleScript command interface. |
| `macos_auto_secure_input` | Needs macOS secure-input lifecycle handling and its indicator. |
| `macos_custom_icon` | Needs configurable application icon generation/loading; the app has fixed artwork. |
| `macos_dock_drop_behavior` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `macos_hidden` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `macos_icon` | Needs configurable application icon generation/loading; the app has fixed artwork. |
| `macos_icon_frame` | Needs configurable application icon generation/loading; the app has fixed artwork. |
| `macos_icon_ghost_color` | Needs configurable application icon generation/loading; the app has fixed artwork. |
| `macos_icon_screen_color` | Needs configurable application icon generation/loading; the app has fixed artwork. |
| `macos_non_native_fullscreen` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `macos_option_as_alt` | Needs Option-aware key text translation, consumed modifiers, and left/right modifier tracking. |
| `macos_secure_input_indication` | Needs macOS secure-input lifecycle handling and its indicator. |
| `macos_shortcuts` | Needs Shortcuts integration and authorization handling. |
| `macos_titlebar_proxy_icon` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `macos_titlebar_style` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `macos_window_buttons` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `macos_window_shadow` | Needs the corresponding AppKit window, Dock, or launch behavior. |
| `maximize` | Needs configurable AppKit window creation, appearance, or state handling. |
| `middle_click_action` | Needs middle-click event handling and primary-selection clipboard support. |
| `mouse_hide_while_typing` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `mouse_reporting` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `mouse_scroll_multiplier` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `mouse_shift_capture` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `notify_on_command_finish` | Needs command-completion callbacks and notification/attention handling. |
| `notify_on_command_finish_action` | Needs command-completion callbacks and notification/attention handling. |
| `notify_on_command_finish_after` | Needs command-completion callbacks and notification/attention handling. |
| `progress_style` | Needs progress-report callbacks and a progress indicator. |
| `quick_terminal_animation_duration` | Needs a quick-terminal window and activation/focus handling. |
| `quick_terminal_autohide` | Needs a quick-terminal window and activation/focus handling. |
| `quick_terminal_keyboard_interactivity` | Needs a quick-terminal window and activation/focus handling. |
| `quick_terminal_position` | Needs a quick-terminal window and activation/focus handling. |
| `quick_terminal_screen` | Needs a quick-terminal window and activation/focus handling. |
| `quick_terminal_size` | Needs a quick-terminal window and activation/focus handling. |
| `quick_terminal_space_behavior` | Needs a quick-terminal window and activation/focus handling. |
| `quit_after_last_window_closed` | Needs configurable application lifecycle behavior. |
| `quit_after_last_window_closed_delay` | Needs configurable application lifecycle behavior. |
| `resize_overlay` | Needs a resize overlay view. |
| `resize_overlay_duration` | Needs a resize overlay view. |
| `resize_overlay_position` | Needs a resize overlay view. |
| `right_click_action` | Needs secondary-click handling and, for context-menu mode, an AppKit menu. |
| `scrollbar` | Needs a scrollbar view and scroll-position callbacks. |
| `search_background` | Needs a search UI and search callbacks. |
| `search_foreground` | Needs a search UI and search callbacks. |
| `search_selected_background` | Needs a search UI and search callbacks. |
| `search_selected_foreground` | Needs a search UI and search callbacks. |
| `selection_word_chars` | Needs mouse event forwarding and cursor/selection integration in TerminalView. |
| `shell_integration` | Needs shell-integration resources bundled and located by the app. |
| `shell_integration_features` | Needs shell-integration resources bundled and located by the app. |
| `split_divider_color` | Needs pane layout, focus, and split rendering in the app. |
| `split_inherit_working_directory` | Needs window/tab/pane creation and inheritance policies. |
| `split_preserve_zoom` | Needs pane layout, focus, and split rendering in the app. |
| `tab_inherit_working_directory` | Needs window/tab/pane creation and inheritance policies. |
| `theme` | Needs theme resource lookup and light/dark appearance integration. Direct colors and palettes are available. |
| `undo_timeout` | Needs an undo/restore model for closed terminals. |
| `unfocused_split_fill` | Needs pane layout, focus, and split rendering in the app. |
| `unfocused_split_opacity` | Needs pane layout, focus, and split rendering in the app. |
| `window_colorspace` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_decoration` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_height` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_inherit_font_size` | Needs window/tab/pane creation and inheritance policies. |
| `window_inherit_working_directory` | Needs window/tab/pane creation and inheritance policies. |
| `window_new_tab_position` | Needs window/tab/pane creation and inheritance policies. |
| `window_position_x` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_position_y` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_save_state` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_show_tab_bar` | Needs window/tab/pane creation and inheritance policies. |
| `window_step_resize` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_subtitle` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_theme` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_title_font_family` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_titlebar_background` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_titlebar_foreground` | Needs configurable AppKit window creation, appearance, or state handling. |
| `window_width` | Needs configurable AppKit window creation, appearance, or state handling. |
| `x11_instance_name` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |

### Configuration tests

TOML structure, repeated values, aliases, and availability errors:

```sh
swift test --package-path macos
```

Native parser/ABI tests (after building and copying VeloKit):

```sh
xcrun clang macos/EngineTests/Configuration.c -I VeloKit/include \
  macos/VeloKit.xcframework/macos-arm64/libvelokit.a \
  -framework AppKit -framework Metal -framework QuartzCore \
  -framework CoreText -framework IOSurface -framework Carbon -lc++ \
  -o /tmp/velocitty-engine-config-tests
/tmp/velocitty-engine-config-tests
```

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
