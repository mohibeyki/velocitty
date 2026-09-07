// SPDX-License-Identifier: GPL-3.0
import XCTest

final class WindowTests: XCTestCase {
  func testConfigurationReload() throws {
    try runCheck("WindowChecks", arguments: ["--configuration-only"], success: "Configuration reload tests passed.")
  }

  func testWindowLifecycle() throws {
    try runCheck("WindowChecks", success: "Window lifecycle tests passed.")
  }

  func testQuitWhenLastWindowCloses() throws {
    try runCheck("WindowChecks", arguments: ["--quit-on-close"], success: "Last-window quit test passed.")
  }
}
