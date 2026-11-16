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


extension ConfigurationDocumentTests {
  func testResetPreservesOtherValuesAndComments() throws {
    let document = try ConfigurationDocument(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    document.text = "[terminal]\nfont-size = 13 # keep this comment\nfont_family = [\n  \"Menlo\",\n]\ncursor_style = 'bar'\n"
    try document.removeValue(table: "terminal", key: "font_size")
    try document.removeValue(table: "terminal", key: "font_family")
    XCTAssertNil(document.value(table: "terminal", key: "font_size"))
    XCTAssertNil(document.value(table: "terminal", key: "font_family"))
    XCTAssertTrue(document.text.contains("# keep this comment"))
    XCTAssertEqual(document.value(table: "terminal", key: "cursor_style"), "'bar'")
    _ = try AppConfiguration.parse(Data(document.text.utf8))
  }
}

extension ConfigurationDocumentTests {
  func testConnectionEditsPreserveCommentsAndOtherSettings() throws {
    let document = try ConfigurationDocument(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    document.text = """
    # My servers
    [[connections]]
    id = 'local'
    name = 'Laptop' # keep label comment
    session = 'velocitty'
    # keep connection comment
    [[connections]]
    id = 'gpu'
    name = 'GPU'
    session = 'work'
    host = 'user@cluster' # SSH alias
    [terminal]
    title = '''a title
    [[connections]]
    not a real section'''
    font_size = 14
    """ + "\n"
    var connections = try XCTUnwrap(AppConfiguration.parse(Data(document.text.utf8)).connections)
    connections[0].enabled = false
    connections[1].label = "GPU 日本"
    try document.setConnections(connections)
    XCTAssertTrue(document.text.contains("# keep label comment"))
    XCTAssertTrue(document.text.contains("# keep connection comment"))
    XCTAssertTrue(document.text.contains("# SSH alias"))
    XCTAssertTrue(document.text.contains("not a real section'''"))
    XCTAssertEqual(try AppConfiguration.parse(Data(document.text.utf8)).connections, connections)
    try document.setConnections([connections[1]])
    XCTAssertEqual(try AppConfiguration.parse(Data(document.text.utf8)).connections, [connections[1]])
    try document.setConnections([])
    XCTAssertEqual(try AppConfiguration.parse(Data(document.text.utf8)).connections, [])
    XCTAssertTrue(document.text.contains("font_size = 14"))
  }

  func testConnectionAddAndRemoveAtFileBoundaries() throws {
    for input in ["", "# Hello", "[terminal]\nfont_size=14", "connections = [] # explicit\n[terminal]\n"] {
      let document = try ConfigurationDocument(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
      document.text = input
      try document.setConnections([])
      XCTAssertEqual(try AppConfiguration.parse(Data(document.text.utf8)).connections, [])
      document.text = input
      let remote = HerdrConnection(id: "gpu", label: "GPU", session: "work", target: "user@host")
      try document.setConnections([.local, remote])
      XCTAssertEqual(try AppConfiguration.parse(Data(document.text.utf8)).connections, [.local, remote])
      try document.setConnections([remote])
      try document.setConnections([])
      XCTAssertEqual(try AppConfiguration.parse(Data(document.text.utf8)).connections, [])
    }
  }
}
