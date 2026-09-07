// SPDX-License-Identifier: GPL-3.0
import Foundation

public enum ConfigurationTemplate {
  /// A commented reference keeps context-dependent defaults (especially theme
  /// colors) automatic when the output is saved directly as config.toml.
  public static func render(engineEntry: (String) throws -> String) throws -> String {
    var lines = [
      "# Velocitty defaults. Uncomment only the settings you want to override.",
      "# Values are strings in the engine's syntax; repeatable settings use arrays.",
      "# Empty values mean unset/automatic. Colors below are engine fallbacks;",
      "# the selected theme supplies colors unless you explicitly override them.",
      "# working_directory uses ~/workspace when it exists, otherwise ~.",
      "", "[terminal]", "",
    ]
    for key in TerminalSettings.supported.sorted() {
      let values: [String]
      switch key {
      case "theme": values = [TerminalTheme.defaultSelection]
      case "working-directory": values = [""]
      case "config-file": values = []
      default:
        let entry = try engineEntry(key)
        let prefix = key + " = "
        values = try entry.split(separator: "\n", omittingEmptySubsequences: true).map { line in
          guard line.hasPrefix(prefix) else {
            throw ConfigurationError("Could not format default for \(key).")
          }
          return String(line.dropFirst(prefix.count))
        }
      }
      let value: String
      if TerminalSettings.repeatable.contains(key) {
        let entries = values.filter { !$0.isEmpty }.map(quote)
        value = entries.isEmpty ? "[]" : "[\n#   " + entries.joined(separator: ",\n#   ") + ",\n# ]"
      } else {
        guard values.count <= 1 else {
          throw ConfigurationError("Unexpected repeated default for \(key).")
        }
        value = quote(values.first ?? "")
      }
      lines.append("# \(key.replacingOccurrences(of: "-", with: "_")) = \(value)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func quote(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5c: result += "\\\\"
      case 0...0x1f, 0x7f: result += String(format: "\\u%04X", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
}
