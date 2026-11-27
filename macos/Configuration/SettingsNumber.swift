// SPDX-License-Identifier: GPL-3.0
import Foundation

/// Number formatting for TOML values written by the settings stepper.
public enum SettingsNumber {
  /// Largest magnitude the stepper offers; whole numbers up to it are exact in a Double.
  public static let limit = 1e15

  /// Whole numbers become plain integers (TOML would read `1e+06` as a float); other
  /// values use Swift's shortest representation that round-trips exactly.
  public static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) <= limit { return String(Int64(value)) }
    return "\(value)"
  }
}
