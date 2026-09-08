// SPDX-License-Identifier: GPL-3.0
import Foundation

/// App-owned settings, kept separate from the terminal engine's configuration.
public enum NamespaceAppearance {
  public static let defaults: [String: String] = [
    "theme": "dark",
    "chrome_background_color": "#131313", "chrome_foreground_color": "#DEDEDE",
    "chrome_selected_color": "#303030", "chrome_border_color": "#484848",
    "sidebar_width": "220", "agent_icon_size": "22", "agent_border_width": "1",
    "agent_animation_duration": "1.6",
    "running_color": "#69B578", "running_style": "animated",
    "waiting_color": "#BBA46A", "waiting_style": "solid",
    "idle_color": "#666666", "idle_style": "solid",
    "done_color": "#809B87", "done_style": "solid",
    "unknown_color": "#666666", "unknown_style": "dotted",
  ]

  public static func validate(_ value: String, for key: String) -> Bool {
    guard defaults[key] != nil else { return false }
    if key == "theme" { return ["dark", "light", "auto"].contains(value) }
    if key.hasSuffix("_color") {
      return value.count == 7 && value.first == "#" && UInt32(value.dropFirst(), radix: 16) != nil
    }
    if key.hasSuffix("_style") { return ["solid", "dotted", "animated", "none"].contains(value) }
    guard let number = Double(value), number.isFinite else { return false }
    switch key {
    case "sidebar_width": return (160...400).contains(number)
    case "agent_icon_size": return (16...36).contains(number)
    case "agent_border_width": return (0.5...3).contains(number)
    case "agent_animation_duration": return (0.4...10).contains(number)
    default: return false
    }
  }
}
