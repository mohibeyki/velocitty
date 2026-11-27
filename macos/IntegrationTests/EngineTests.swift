// SPDX-License-Identifier: GPL-3.0
import XCTest

final class EngineTests: XCTestCase {
  func testHeadlessChecks() throws {
    try runCheck("WindowChecks", arguments: ["--headless"], success: "Headless checks passed.")
  }
  func testConfigurationAndABI() throws {
    try runCheck("EngineChecks", success: "Engine configuration tests passed.")
  }
}
