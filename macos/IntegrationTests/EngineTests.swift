// SPDX-License-Identifier: GPL-3.0
import XCTest

final class EngineTests: XCTestCase {
  func testHerdrControl() throws {
    try runCheck("WindowChecks", arguments: ["--herdr-control-only"], success: "Herdr control tests passed.")
  }
  func testConfigurationAndABI() throws {
    try runCheck("EngineChecks", success: "Engine configuration tests passed.")
  }
}
