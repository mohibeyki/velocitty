// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class AppearanceAndGitTests: XCTestCase {
  func testHexColorsNeedExactlySixDigits() {
    XCTAssertEqual(NamespaceAppearance.rgb("#1A2b3C"), 0x1A2B3C)
    XCTAssertEqual(NamespaceAppearance.rgb("112233"), 0x112233)
    for bad in ["#+12345", "#-12345", "#12345", "#1234567", "#12 456", "", "#", "#GGGGGG", " 112233"] {
      XCTAssertNil(NamespaceAppearance.rgb(bad), bad)
    }
    XCTAssertTrue(NamespaceAppearance.validate("#112233", for: "running_color"))
    XCTAssertFalse(NamespaceAppearance.validate("#+12345", for: "running_color"))
    XCTAssertFalse(NamespaceAppearance.validate("112233", for: "running_color"))
  }

  func testSettingsCatalogGroupsAndDescribes() {
    XCTAssertEqual(SettingsCatalog.category(table: "interface", key: "theme"), "Workspace")
    XCTAssertEqual(SettingsCatalog.category(table: "terminal", key: "font_size"), "Font")
    XCTAssertEqual(SettingsCatalog.category(table: "terminal", key: "cursor_style"), "Colors & Appearance")
    XCTAssertEqual(SettingsCatalog.category(table: "terminal", key: "unknown_setting"), "Advanced")
    XCTAssertTrue(SettingsCatalog.categories.contains(SettingsCatalog.category(table: "terminal", key: "keybind")))
    XCTAssertEqual(SettingsCatalog.summary(table: "terminal", key: "font_size"), "Terminal font size in points.")
  }

  func testGitBranchReader() throws {
    let root = try makeTemporaryDirectory().resolvingSymlinksInPath().path
    XCTAssertNil(GitBranchReader.branch(at: root))
    guard GitBranchReader.run(["init", "-q", "-b", "trunk"], in: root) == nil else { return XCTFail("git init prints nothing") }
    let gitDirectory = try XCTUnwrap(GitBranchReader.gitDirectory(at: root))
    XCTAssertEqual(URL(fileURLWithPath: gitDirectory).resolvingSymlinksInPath().path, root + "/.git")
    // An unborn branch has a name but no commit.
    XCTAssertEqual(GitBranchReader.branch(at: root), "trunk")
    let commit = ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "x"]
    _ = GitBranchReader.run(commit, in: root)
    XCTAssertEqual(GitBranchReader.branch(at: root), "trunk")
    _ = GitBranchReader.run(["checkout", "-q", "--detach"], in: root)
    XCTAssertTrue(GitBranchReader.branch(at: root)?.hasPrefix("Detached · ") == true)
  }
}
