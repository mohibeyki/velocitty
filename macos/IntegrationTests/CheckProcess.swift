// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest

extension XCTestCase {
  // These checks need their own process: native assertions can abort, and the GUI
  // quit regression intentionally terminates NSApplication. Neither should exit XCTest.
  func runCheck(_ name: String, arguments: [String] = [], success: String) throws {
    let products = Bundle(for: EngineTests.self).bundleURL.deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("velocitty-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logURL = directory.appendingPathComponent("output.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    let process = Process()
    process.executableURL = products.appendingPathComponent(name)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["VELOKIT_RESOURCES_DIR"] = products
      .appendingPathComponent("Velocitty.app/Contents/Resources").path
    process.environment = environment
    process.standardOutput = log
    process.standardError = log
    let finished = expectation(description: "\(name) exits")
    process.terminationHandler = { _ in finished.fulfill() }
    try process.run()
    let result = XCTWaiter.wait(for: [finished], timeout: 90)
    if result != .completed { process.terminate() }
    let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    let attachment = XCTAttachment(string: output)
    attachment.name = "\(name) \(arguments.joined(separator: " ")) output"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard result == .completed else {
      XCTFail("\(name) timed out.\n\(output)")
      return
    }
    XCTAssertEqual(process.terminationReason, .exit, output)
    XCTAssertEqual(process.terminationStatus, 0, output)
    XCTAssertTrue(output.contains(success), "Missing completion marker.\n\(output)")
  }
}
