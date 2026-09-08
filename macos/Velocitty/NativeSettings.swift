// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit

// The engine owns parsing and defaults. Callers can only request named, typed values.
struct NativeSettings {
  let config: ghostty_config_t?

  var focusFollowsMouse: Bool { bool("focus-follows-mouse", false) }
  var splitInheritsDirectory: Bool { bool("split-inherit-working-directory", true) }
  var windowInheritsDirectory: Bool { bool("window-inherit-working-directory", true) }
  var windowInheritsFontSize: Bool { bool("window-inherit-font-size", true) }
  var preserveZoomNavigation: Bool { uint32("split-preserve-zoom", 0) & 1 != 0 }
  var tabBarVisibility: String { string("window-show-tab-bar", "auto") }
  var unfocusedOpacity: Double { double("unfocused-split-opacity", 0.7) }
  var unfocusedFill: NSColor { color("unfocused-split-fill") ?? background }
  var dividerColor: NSColor { color("split-divider-color") ?? .separatorColor }
  var confirmClose: String { string("confirm-close-surface", "true") }
  var tabInheritsDirectory: Bool { bool("tab-inherit-working-directory", true) }
  var newTabPosition: String { string("window-new-tab-position", "current") }
  var initialWindow: Bool { bool("initial-window", true) }
  var quitAfterLastWindowClosed: Bool { bool("quit-after-last-window-closed", false) }
  var windowStepResize: Bool { bool("window-step-resize", false) }
  var maximize: Bool { bool("maximize", false) }
  var windowShadow: Bool { bool("macos-window-shadow", true) }
  var progressStyle: Bool { bool("progress-style", true) }
  var autoSecureInput: Bool { bool("macos-auto-secure-input", true) }
  var secureInputIndication: Bool { bool("macos-secure-input-indication", true) }
  var hiddenPolicy: String { string("macos-hidden", "") }
  var fullscreen: String { string("fullscreen", "false") }
  var windowSaveState: String { string("window-save-state", "default") }
  var titlebarStyle: String { string("macos-titlebar-style", "transparent") }
  var windowDecoration: String { string("window-decoration", "") }
  var windowButtons: String { string("macos-window-buttons", "") }
  var windowColorspace: String { string("window-colorspace", "") }
  var titleFontFamily: String { string("window-title-font-family", "") }
  var windowSubtitle: String { string("window-subtitle", "") }
  var titlebarProxyIcon: String { string("macos-titlebar-proxy-icon", "") }
  var windowTheme: String { string("window-theme", "") }
  var dragHandle: String { string("drag-handle", "auto") }
  var nonNativeFullscreen: String { string("macos-non-native-fullscreen", "false") }
  var resizeOverlay: String { string("resize-overlay", "after-first") }
  var resizeOverlayPosition: String { string("resize-overlay-position", "center") }
  var scrollbar: String { string("scrollbar", "system") }
  var notifyOnCommandFinish: String { string("notify-on-command-finish", "never") }
  var rightClickAction: String { string("right-click-action", "") }
  var windowPositionX: Int16 { int16("window-position-x", Int16.min) }
  var windowPositionY: Int16 { int16("window-position-y", Int16.min) }
  var backgroundBlur: Int16 { int16("background-blur", 0) }
  var backgroundOpacity: Double { double("background-opacity", 1.0) }
  var bellAudioVolume: Double { double("bell-audio-volume", 0.5) }
  var bellFeatures: UInt32 { uint32("bell-features", 12) }
  var commandFinishActions: UInt32 { uint32("notify-on-command-finish-action", 1) }
  var quitDelay: Double { seconds("quit-after-last-window-closed-delay", 0) }
  var resizeOverlayDuration: Double { seconds("resize-overlay-duration", 0.75) }
  var commandFinishDelay: Double { seconds("notify-on-command-finish-after", 5) }
  var background: NSColor { color("background") ?? .windowBackgroundColor }
  var titlebarForeground: NSColor? { color("window-titlebar-foreground") }
  var titlebarBackground: NSColor? { color("window-titlebar-background") }

  var bellAudioPath: String {
    guard let config else { return "" }
    var result = ghostty_config_path_s(path: nil, optional: false)
    guard velokit_config_get_path(config, "bell-audio-path", &result) else { return "" }
    return result.path.map { String(cString: $0) } ?? ""
  }

  struct Command {
    let actionKey: String
    let action: String
    let title: String
    let detail: String
  }

  var commands: [Command] {
    guard let config else { return [] }
    var result = ghostty_config_command_list_s(commands: nil, len: 0)
    guard velokit_config_get_commands(config, "command-palette-entry", &result),
      let commands = result.commands else { return [] }
    // Copy strings while the borrowed native list is valid.
    return (0..<result.len).compactMap { index in
      let command = commands[index]
      guard let key = command.action_key, let action = command.action, let title = command.title
      else { return nil }
      return Command(
        actionKey: String(cString: key), action: String(cString: action),
        title: String(cString: title),
        detail: command.description.map { String(cString: $0) } ?? "")
    }
  }

  private func bool(_ key: String, _ fallback: Bool) -> Bool {
    guard let config else { return fallback }
    var result = fallback
    return velokit_config_get_bool(config, key, &result) ? result : fallback
  }
  private func int16(_ key: String, _ fallback: Int16) -> Int16 {
    guard let config else { return fallback }
    var result = fallback
    return velokit_config_get_int16(config, key, &result) ? result : fallback
  }
  private func uint32(_ key: String, _ fallback: UInt32) -> UInt32 {
    guard let config else { return fallback }
    var result = fallback
    return velokit_config_get_uint32(config, key, &result) ? result : fallback
  }
  private func double(_ key: String, _ fallback: Double) -> Double {
    guard let config else { return fallback }
    var result = fallback
    return velokit_config_get_double(config, key, &result) ? result : fallback
  }
  private func string(_ key: String, _ fallback: String) -> String {
    guard let config else { return fallback }
    var result: UnsafePointer<CChar>?
    guard velokit_config_get_string(config, key, &result) else { return fallback }
    return result.map { String(cString: $0) } ?? fallback
  }
  private func seconds(_ key: String, _ fallback: Double) -> Double {
    guard let config else { return fallback }
    var milliseconds: UInt = 0
    guard velokit_config_get_milliseconds(config, key, &milliseconds) else { return fallback }
    return Double(milliseconds) / 1000
  }
  private func color(_ key: String) -> NSColor? {
    guard let config else { return nil }
    var result = ghostty_config_color_s(r: 0, g: 0, b: 0)
    guard velokit_config_get_color(config, key, &result) else { return nil }
    return NSColor(
      srgbRed: Double(result.r) / 255, green: Double(result.g) / 255,
      blue: Double(result.b) / 255, alpha: 1)
  }
}
