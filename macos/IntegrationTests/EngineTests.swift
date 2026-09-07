// SPDX-License-Identifier: GPL-3.0
import XCTest

final class EngineTests: XCTestCase {
  func testConfigurationAndABI() throws {
    try runCheck("EngineChecks", success: "Engine configuration tests passed.")
  }
}
