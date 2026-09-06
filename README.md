# Velocitty

Velocitty is a small macOS terminal application built with AppKit and
[libghostty](https://github.com/ghostty-org/ghostty). The application owns the
window and macOS input layer; [VeloKit](VeloKit/) provides the terminal engine,
renderer, fonts, and process integration.

The app currently provides:

- one terminal window with the user's default shell and automatic shell integration;
- mouse selection, protected clipboard access, scrolling, and Cmd-click links;
- terminal search and a searchable command palette;
- file-based TOML configuration, includes, and adaptive bundled themes;
- configurable window appearance, close confirmation, and geometry restoration;
- bells, desktop notifications, Secure Input, and Dock progress.

Tabs, panes, and multiplexing are not implemented yet.

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
`VeloKit/build/VeloKit.xcframework` and `VeloKit/build/terminfo/`. Xcode copies
the generated terminfo database and the vendored shell-integration scripts into
the application resources. Copy the generated framework into the
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
theme = "light:Rose Pine Dawn,dark:Rose Pine"
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
strings. Color strings such as `"#171923"` must be quoted.

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

Choose **Velocitty → Reload Configuration** (**⌘⇧,**) after editing. Validation
builds a new engine configuration before applying it; syntax errors, unknown
keys, invalid native values, and unavailable settings leave the active
configuration unchanged. Errors identify the configuration file and setting.
At startup, an invalid configuration offers **Use Defaults** or **Quit**.

Appearance and terminal behavior reload according to the engine's existing
rules. Process settings (`command`, `initial_command`, `env`, `input`, `term`,
and `working_directory`) apply to the next terminal and never restart the current
shell. Font codepoint mappings and horizontal/vertical padding also require a new
terminal. Reload does not promise that every setting takes effect immediately.

Use `config_file = ["appearance.toml", "keys.toml"]` under `[terminal]` to include
other TOML files. Includes load in array order, then the containing file overrides
them by setting name (including whole arrays). Paths are relative to the containing
file; `~/` is supported. Prefix an include with `?` to make a missing file optional.
Cycles are errors. Asset paths stay relative to the file that declares them.

Themes are iTerm2 `.itermcolors` files; sRGB, calibrated RGB, and Display P3
colors are converted to the engine’s sRGB palette. The default pair is **Rosé Pine Dawn**
(light) and **Rosé Pine** (dark), following macOS appearance automatically.
Select a fixed theme with `theme = "Catppuccin Mocha"`, or a pair with
`theme = "light:Rose Pine Dawn,dark:Rose Pine"`. Explicit colors override the theme.
Put custom files in `~/.config/velocitty/themes/`, or use an absolute theme path.
Set `theme = ""` for the engine's unthemed colors.

Bundled: TokyoNight Night, Storm, Moon, Day; Rose Pine, Moon, Dawn;
Catppuccin Latte, Frappe, Macchiato, Mocha. These are the palettes from the
pinned collection used by Ghostty, converted to iTerm2 plist format.

### Terminal behavior

**Input and clipboard.** The engine owns selections, mouse reporting to terminal
programs, shift-click overrides, wheel scrolling, and Cmd-click URL/OSC 8 links.
Option-as-Alt uses its macOS keyboard-layout heuristic unless explicitly set to
`true`, `false`, `left`, or `right`. Read/write confirmation, unsafe-paste checks,
and bracketed paste use the engine's defaults. Clipboard representations include
plain text, HTML, and PNG. Middle-click primary paste uses an application selection
pasteboard, separate from the system clipboard. Read approvals that support a
session grant can be remembered for that terminal.

**Shell integration.** The bundled scripts enable prompt boundaries, command
tracking, working-directory/title updates, cursor changes, and idle-shell close
detection. `shell_integration = "detect"` is the default; use `"none"` to disable
it or select a supported shell explicitly. Detection and shell-version limitations
come from the vendored engine; the older system Bash does not gain automatic
integration. Feature flags retain the engine's defaults. Flags requiring the
upstream command-line helper are rejected with an explanatory error.

**Search and commands.** Cmd-F opens search; Return/Shift-Return or Cmd-G/Cmd-Shift-G
move between matches, and Escape closes it. Colors and highlights come from the
engine. Cmd-Shift-P opens the command palette; type to filter, use arrows to select,
and Return to run. Custom entries use the native syntax:

```toml
[terminal]
command_palette_entry = [
  "title:Reset Colors,action:csi:0m",
  "title:Print Greeting,description:Insert a greeting,action:text:hello"
]
keybind = [
  "super+shift+r=reload_config",
  "ctrl+a>r=reload_config",
  "global:super+shift+space=toggle_visibility"
]
```

Bindings, sequences, chains, remaps, and unbindings are parsed by the engine.
Menu equivalents reflect the final bindings. Global shortcuts use macOS hotkey
registration; conflicts or keys unavailable in the active keyboard layout are
reported in the app log. The palette filters actions requiring excluded or
unfinished UI. Terminal screen/selection/scrollback export actions use the engine's
temporary files. Keybindings cannot create tabs, splits, or other omitted features.

**Window and lifecycle.** Closing an active process asks for confirmation according
to `confirm_close_surface`; an integrated idle shell can close immediately.
Closing the window leaves the app running by default. The Dock or Terminal →
Open Terminal opens the single terminal again. `quit_after_last_window_closed`
and its optional delay control automatic quit. `initial_window = false` starts
without a terminal window.

`window_save_state` restores geometry and fullscreen state; it never restores a
shell or its processes. Set both initial dimensions to choose terminal columns/rows; positions
are measured from the screen's top-left. Window appearance, opacity, cell opacity,
blur, decorations, titlebar, color space, shadow, buttons, and fullscreen modes
are configurable. Exact blur radius is supplied by the macOS material. A custom
title font/color uses an AppKit title accessory. In the single-window app, the
`tabs` titlebar style behaves like the transparent style. The resize overlay shows
columns × rows, with configurable position and duration. The system scrollbar
can be disabled with `scrollbar = "never"`.

Dropping files or folders on the Dock inserts shell-escaped paths into the
terminal, opening it when necessary. It does not append Enter or run a command.
The native `macos_dock_drop_behavior` tab/window policies do not apply.

**Activity and privacy.** Bells can use the system alert, an audio file and volume,
Dock attention, a title marker, or a border flash. Command-finish notifications
honor the configured duration, focus policy, and actions. Desktop notification
permission is requested when a notification is first needed. Terminal progress
reports appear on the Dock icon and expire after 15 seconds without an update.
Secure Input follows password-entry reports and window/application focus; its
indicator can be disabled separately. Both automatic Secure Input and its
indicator are enabled by default.

### Available terminal settings

The following **156 settings** are connected to the vendored engine and
AppKit implementation. Values and defaults are defined in
[Config.zig](VeloKit/src/config/Config.zig); the behavior and exceptions above
apply. Process/initial window settings take effect when the next terminal opens.

| Setting | TOML shape |
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
| `background_blur` | Scalar |
| `background_image` | Scalar |
| `background_image_fit` | Scalar |
| `background_image_opacity` | Scalar |
| `background_image_position` | Scalar |
| `background_image_repeat` | Scalar |
| `background_opacity` | Scalar |
| `background_opacity_cells` | Scalar |
| `bell_audio_path` | Scalar |
| `bell_audio_volume` | Scalar |
| `bell_features` | Scalar |
| `bold_color` | Scalar |
| `click_repeat_interval` | Scalar |
| `clipboard_codepoint_map` | Array or scalar |
| `clipboard_paste_bracketed_safe` | Scalar |
| `clipboard_paste_protection` | Scalar |
| `clipboard_read` | Scalar |
| `clipboard_trim_trailing_spaces` | Scalar |
| `clipboard_write` | Scalar |
| `clipboard_write_limit_bytes` | Scalar |
| `command` | Scalar |
| `command_palette_entry` | Array or scalar |
| `config_file` | Array or scalar |
| `confirm_close_surface` | Scalar |
| `copy_on_select` | Scalar |
| `cursor_click_to_move` | Scalar |
| `cursor_color` | Scalar |
| `cursor_opacity` | Scalar |
| `cursor_style` | Scalar |
| `cursor_style_blink` | Scalar |
| `cursor_text` | Scalar |
| `custom_shader` | Array or scalar |
| `custom_shader_animation` | Scalar |
| `desktop_notifications` | Scalar |
| `drag_handle` | Scalar |
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
| `fullscreen` | Scalar |
| `grapheme_width_method` | Scalar |
| `image_storage_limit` | Scalar |
| `initial_command` | Scalar |
| `initial_window` | Scalar |
| `input` | Array or scalar |
| `key_remap` | Array or scalar |
| `keybind` | Array or scalar |
| `link_osc8` | Scalar |
| `link_previews` | Scalar |
| `link_url` | Scalar |
| `macos_auto_secure_input` | Scalar |
| `macos_hidden` | Scalar |
| `macos_non_native_fullscreen` | Scalar |
| `macos_option_as_alt` | Scalar |
| `macos_secure_input_indication` | Scalar |
| `macos_titlebar_proxy_icon` | Scalar |
| `macos_titlebar_style` | Scalar |
| `macos_window_buttons` | Scalar |
| `macos_window_shadow` | Scalar |
| `maximize` | Scalar |
| `middle_click_action` | Scalar |
| `minimum_contrast` | Scalar |
| `mouse_hide_while_typing` | Scalar |
| `mouse_reporting` | Scalar |
| `mouse_scroll_multiplier` | Scalar |
| `mouse_shift_capture` | Scalar |
| `notify_on_command_finish` | Scalar |
| `notify_on_command_finish_action` | Scalar |
| `notify_on_command_finish_after` | Scalar |
| `osc_color_report_format` | Scalar |
| `palette` | Array or scalar |
| `palette_generate` | Scalar |
| `palette_harmonious` | Scalar |
| `progress_style` | Scalar |
| `quit_after_last_window_closed` | Scalar |
| `quit_after_last_window_closed_delay` | Scalar |
| `resize_overlay` | Scalar |
| `resize_overlay_duration` | Scalar |
| `resize_overlay_position` | Scalar |
| `right_click_action` | Scalar |
| `scroll_to_bottom` | Scalar |
| `scrollback_compression` | Scalar |
| `scrollback_limit_bytes` | Scalar |
| `scrollback_limit_lines` | Scalar |
| `scrollbar` | Scalar |
| `search_background` | Scalar |
| `search_foreground` | Scalar |
| `search_selected_background` | Scalar |
| `search_selected_foreground` | Scalar |
| `selection_background` | Scalar |
| `selection_clear_on_copy` | Scalar |
| `selection_clear_on_typing` | Scalar |
| `selection_foreground` | Scalar |
| `selection_word_chars` | Scalar |
| `shell_integration` | Scalar |
| `shell_integration_features` | Scalar |
| `term` | Scalar |
| `theme` | Scalar |
| `title` | Scalar |
| `title_report` | Scalar |
| `vt_kam_allowed` | Scalar |
| `wait_after_command` | Scalar |
| `window_colorspace` | Scalar |
| `window_decoration` | Scalar |
| `window_height` | Scalar |
| `window_padding_balance` | Scalar |
| `window_padding_color` | Scalar |
| `window_padding_x` | Scalar |
| `window_padding_y` | Scalar |
| `window_position_x` | Scalar |
| `window_position_y` | Scalar |
| `window_save_state` | Scalar |
| `window_step_resize` | Scalar |
| `window_subtitle` | Scalar |
| `window_theme` | Scalar |
| `window_title_font_family` | Scalar |
| `window_titlebar_background` | Scalar |
| `window_titlebar_foreground` | Scalar |
| `window_vsync` | Scalar |
| `window_width` | Scalar |
| `working_directory` | Scalar |

### Excluded and deferred settings

These names produce an explicit configuration error. They remain listed so
unavailable features are distinguishable from spelling mistakes.

| Setting | Status |
| --- | --- |
| `app_notifications` | This engine option applies only to GTK. |
| `async_backend` | Excluded; the app uses its built-in I/O backend. |
| `auto_update` | Deferred until application distribution is implemented. |
| `auto_update_channel` | Deferred until application distribution is implemented. |
| `class` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `config_default_files` | Uses the upstream configuration-file format and search policy; Velocitty loads its own TOML file. |
| `focus_follows_mouse` | Deferred until tabs and panes are implemented. |
| `freetype_load_flags` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
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
| `language` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `link` | Custom link patterns are not implemented by the vendored engine; URL and OSC 8 links are supported. |
| `linux_cgroup` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `linux_cgroup_hard_fail` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `linux_cgroup_memory_limit` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `linux_cgroup_processes_limit` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |
| `macos_applescript` | Excluded from the application. |
| `macos_custom_icon` | Excluded; the app uses fixed artwork. |
| `macos_dock_drop_behavior` | Velocitty inserts dropped paths into its single terminal; new-tab/new-window policies do not apply. |
| `macos_icon` | Excluded; the app uses fixed artwork. |
| `macos_icon_frame` | Excluded; the app uses fixed artwork. |
| `macos_icon_ghost_color` | Excluded; the app uses fixed artwork. |
| `macos_icon_screen_color` | Excluded; the app uses fixed artwork. |
| `macos_shortcuts` | Excluded from the application. |
| `quick_terminal_animation_duration` | Excluded; there is no quick-terminal window. |
| `quick_terminal_autohide` | Excluded; there is no quick-terminal window. |
| `quick_terminal_keyboard_interactivity` | Excluded; there is no quick-terminal window. |
| `quick_terminal_position` | Excluded; there is no quick-terminal window. |
| `quick_terminal_screen` | Excluded; there is no quick-terminal window. |
| `quick_terminal_size` | Excluded; there is no quick-terminal window. |
| `quick_terminal_space_behavior` | Excluded; there is no quick-terminal window. |
| `split_divider_color` | Deferred until tabs and panes are implemented. |
| `split_inherit_working_directory` | Deferred until tabs and panes are implemented. |
| `split_preserve_zoom` | Deferred until tabs and panes are implemented. |
| `tab_inherit_working_directory` | Deferred until tabs and panes are implemented. |
| `undo_timeout` | Deferred until terminal session restoration is implemented. |
| `unfocused_split_fill` | Deferred until tabs and panes are implemented. |
| `unfocused_split_opacity` | Deferred until tabs and panes are implemented. |
| `window_inherit_font_size` | Deferred until tabs and panes are implemented. |
| `window_inherit_working_directory` | Deferred until tabs and panes are implemented. |
| `window_new_tab_position` | Deferred until tabs and panes are implemented. |
| `window_show_tab_bar` | Deferred until tabs and panes are implemented. |
| `x11_instance_name` | Requires a different platform frontend or font backend; this app uses AppKit and CoreText. |

### Configuration tests

TOML includes, themes, aliases, availability errors, and shell path escaping:

```sh
swift test --package-path macos
```

Native parser/ABI and shortcut lookup tests (after building and copying VeloKit):

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
