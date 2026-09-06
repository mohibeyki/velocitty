// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

// Read finalized engine values, including defaults, rather than re-parsing TOML.
struct NativeSettings {
  let config: ghostty_config_t?
  func value<T>(_ key: String, _ fallback: T) -> T {
    guard let config else { return fallback }
    var result = fallback
    let found = key.withCString { keyPointer in
      withUnsafeMutablePointer(to: &result) {
        velokit_config_get(config, $0, keyPointer, UInt(key.utf8.count))
      }
    }
    return found ? result : fallback
  }
  func string(_ key: String, _ fallback: String = "") -> String {
    let pointer: UnsafePointer<CChar>? = value(key, Optional<UnsafePointer<CChar>>.none)
    return pointer.map { String(cString: $0) } ?? fallback
  }
  func seconds(_ key: String, _ fallback: Double) -> Double {
    Double(value(key, UInt(fallback * 1000))) / 1000
  }
  func color(_ key: String, _ fallback: NSColor = .windowBackgroundColor) -> NSColor {
    guard let config else { return fallback }
    var value = ghostty_config_color_s(r: 0, g: 0, b: 0)
    guard key.withCString({ velokit_config_get(config, &value, $0, UInt(key.utf8.count)) }) else {
      return fallback
    }
    return NSColor(
      srgbRed: Double(value.r) / 255, green: Double(value.g) / 255, blue: Double(value.b) / 255,
      alpha: 1)
  }
}
