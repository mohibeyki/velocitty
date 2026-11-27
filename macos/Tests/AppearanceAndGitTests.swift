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
    // Isolate from the developer's global/system git config (signing, hooks, templates).
    let isolated = ["HOME": root, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    func git(_ arguments: [String]) -> String? { GitBranchReader.run(arguments, in: root, extraEnvironment: isolated) }
    guard git(["init", "-q", "-b", "trunk"]) == nil else { return XCTFail("git init prints nothing") }
    let gitDirectory = try XCTUnwrap(GitBranchReader.gitDirectory(at: root))
    XCTAssertEqual(URL(fileURLWithPath: gitDirectory).resolvingSymlinksInPath().path, root + "/.git")
    // An unborn branch has a name but no commit.
    XCTAssertEqual(GitBranchReader.branch(at: root), "trunk")
    let commit = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "--allow-empty", "-m", "x"]
    XCTAssertNil(git(commit), "git commit prints nothing")
    let head = try XCTUnwrap(git(["rev-parse", "--short", "HEAD"]), "the commit must have succeeded")
    XCTAssertEqual(GitBranchReader.branch(at: root), "trunk")
    XCTAssertNil(git(["checkout", "-q", "--detach"]))
    XCTAssertEqual(GitBranchReader.branch(at: root), GitBranchReader.detachedLabel(head))
  }
}
