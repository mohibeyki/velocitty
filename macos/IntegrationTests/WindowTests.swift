// SPDX-License-Identifier: GPL-3.0
import XCTest

final class WindowTests: XCTestCase {
  func testWindowLifecycle() throws {
    try runCheck("WindowChecks", success: "Window lifecycle tests passed.")
  }

  func testQuitWhenLastWindowCloses() throws {
    try runCheck("WindowChecks", arguments: ["--quit-on-close"], success: "Last-window quit test passed.")
  }
}
