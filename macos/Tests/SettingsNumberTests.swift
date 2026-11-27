// SPDX-License-Identifier: GPL-3.0
import XCTest
@testable import VelocittyConfiguration

final class SettingsNumberTests: XCTestCase {
  func testWholeNumbersStayIntegers() {
    XCTAssertEqual(SettingsNumber.format(1_000_000), "1000000")
    XCTAssertEqual(SettingsNumber.format(10_000_000), "10000000")
    XCTAssertEqual(SettingsNumber.format(1_234_567), "1234567")
    XCTAssertEqual(SettingsNumber.format(-42), "-42")
    XCTAssertEqual(SettingsNumber.format(0), "0")
    XCTAssertEqual(SettingsNumber.format(SettingsNumber.limit), "1000000000000000")
  }

  func testFractionsRoundTrip() {
    for value in [0.1, 12.5, -0.25, 1234567.125, 0.3] {
      XCTAssertEqual(Double(SettingsNumber.format(value)), value)
      XCTAssertFalse(SettingsNumber.format(value).contains("e"))
    }
  }

  func testAccumulatedStepperValuesAreClean() {
    XCTAssertEqual(SettingsNumber.format(0.1 + 0.1 + 0.1), "0.3")
    XCTAssertEqual(SettingsNumber.format(0.7 + 0.1), "0.8")
    XCTAssertEqual(SettingsNumber.format(0.00001), "0.00001")
    XCTAssertFalse(SettingsNumber.format(0.00001234).contains("e"))
  }
}
