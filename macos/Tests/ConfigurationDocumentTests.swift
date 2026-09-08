// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class ConfigurationDocumentTests: XCTestCase {
  func testLosslessEditsAndExternalChangeProtection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("config.toml")
    let original = """
      # Keep 日本 and comments
      [terminal]
      font-size = 12 # font comment
      font_family = [
        "Menlo", # primary
        "Monaco",
      ]
      title = '''multiple
      lines'''
      unknown_future_setting = true
      [interface]
      theme = "dark"
      """ + "\n"
    try Data(original.utf8).write(to: file)
    let document = try ConfigurationDocument(url: file)
    try document.setValue(table: "terminal", key: "font_size", toml: "15")
    XCTAssertEqual(document.text, original.replacingOccurrences(of: "= 12 #", with: "= 15 #"))
    XCTAssertTrue(document.value(table: "terminal", key: "font_family")?.contains("# primary") == true)
    XCTAssertEqual(document.value(table: "terminal", key: "title"), "'''multiple\nlines'''")
    try document.setValue(table: "terminal", key: "cursor_style", toml: "\"bar\"")
    XCTAssertTrue(document.text.contains("cursor_style = \"bar\"\n[interface]"))
    XCTAssertThrowsError(try document.setValue(table: "terminal", key: "font_size", toml: "15\nfont_family='bad'"))
    try document.save()
    XCTAssertFalse(document.hasChanges)
    try Data("# External edit\n".utf8).write(to: file)
    document.text += "# Draft\n"
    XCTAssertThrowsError(try document.save())
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# External edit\n")
    XCTAssertTrue(document.text.hasSuffix("# Draft\n"))
  }
}
