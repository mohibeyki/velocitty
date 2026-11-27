// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class ShellInputTests: XCTestCase {
  func testDroppedPathsAreLiteralShellArguments() throws {
    let paths = [
      "/tmp/a b", "/tmp/it's", "/tmp/$(printf WRONG)", "/tmp/a;printf WRONG", "/tmp/雪\nline",
    ]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf '%s\\0' " + ShellInput.paths(paths)]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(bytes, Data((paths.joined(separator: "\0") + "\0").utf8))
    XCTAssertEqual(ShellInput.paths([]), "")
    XCTAssertFalse(ShellInput.paths(paths).hasSuffix("\n"))
  }

  func testQuoteIsOneLiteralWord() {
    XCTAssertEqual(ShellInput.quote("it's"), "'it'\\''s'")
    XCTAssertEqual(ShellInput.paths(["/a"]), ShellInput.quote("/a") + " ")
  }
}
