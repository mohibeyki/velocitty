// SPDX-License-Identifier: GPL-3.0
import Foundation

/// Number formatting for TOML values written by the settings stepper.
public enum SettingsNumber {
  /// Largest magnitude the stepper offers; whole numbers up to it are exact in a Double.
  public static let limit = 1e15

  /// Whole numbers become plain integers (TOML would read `1e+06` as a float); other
  /// values are rounded to 12 significant digits.
  public static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) <= limit { return String(Int64(value)) }
    // 12 significant digits absorb stepper accumulation error (0.1 + 0.1 + 0.1). Magnitudes below
    // 1e-4 would print as an exponent, so fall back to fixed notation there.
    let text = String(format: "%.12g", value)
    guard text.contains("e") else { return text }
    return String(format: "%.12f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
  }
}
