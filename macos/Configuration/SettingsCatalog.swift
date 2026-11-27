// SPDX-License-Identifier: GPL-3.0
import Foundation

/// How the settings window groups and describes each setting.
public enum SettingsCatalog {
  public static let categories = ["Font", "Colors & Appearance", "Input & Clipboard", "Windows & Tabs", "Shell & Terminal", "Workspace", "Advanced"]

  public static func category(table: String, key: String) -> String {
    if table == "interface" { return "Workspace" }
    if key.hasPrefix("font") || key.hasPrefix("adjust_") { return "Font" }
    if ["theme", "background", "foreground", "palette", "cursor", "selection", "unfocused"].contains(where: { key.hasPrefix($0) }) { return "Colors & Appearance" }
    if ["keybind", "mouse", "clipboard", "copy", "paste", "click", "link"].contains(where: { key.hasPrefix($0) }) { return "Input & Clipboard" }
    if ["window", "macos", "tab", "resize", "focus", "split", "quit", "confirm", "undo"].contains(where: { key.hasPrefix($0) }) { return "Windows & Tabs" }
    if ["shell", "command", "initial_command", "working_directory", "env", "term", "scrollback"].contains(where: { key.hasPrefix($0) }) { return "Shell & Terminal" }
    return "Advanced"
  }

  public static func summary(table: String, key: String) -> String {
    if key == "agent_notifications" { return "Notify when an agent needs input or finishes. Notifications focus its terminal when clicked." }
    if key == "restore_session" { return "Save each terminal's recent output and recreate lost herdr terminals after a reboot. Running processes are not restored." }
    if table == "interface" { return "Workspace appearance. Terminal colors are configured separately." }
    switch key {
    case "font_family": return "Typeface for terminal text. Font fallback remains available in Advanced."
    case "font_size": return "Terminal font size in points."
    case "theme": return "Use a bundled theme, a file path, or light:Name,dark:Name for automatic appearance."
    case "working_directory": return "Starting directory for new terminals when directory inheritance does not apply."
    case "command", "initial_command": return "An explicit command creates standalone terminals instead of herdr sessions."
    case "keybind": return "Keyboard bindings. This repeatable setting accepts an array of bindings."
    case "quit_after_last_window_closed": return "Quit after closing the last window. Herdr terminals keep running."
    case "undo_timeout": return "How long explicit terminal closes can be undone before ending the process."
    case "background_opacity": return "Terminal background opacity, from 0 (transparent) to 1 (opaque)."
    case "cursor_style": return "Shape of the terminal cursor. Applications can request a different shape."
    default: return "Edit the value below or use the source document for advanced syntax."
    }
  }
}
