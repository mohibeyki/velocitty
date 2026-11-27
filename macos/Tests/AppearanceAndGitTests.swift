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
    // Isolate from the developer's global/system git config (signing, hooks, templates), and allow for a slow first git launch.
    let isolated = ["HOME": root, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    let timeout: TimeInterval = 30
    func git(_ arguments: [String]) -> String? { GitBranchReader.run(arguments, in: root, timeout: timeout, extraEnvironment: isolated) }
    func branch() -> String? { GitBranchReader.branch(at: root, timeout: timeout, extraEnvironment: isolated) }
    XCTAssertNil(branch())
    guard git(["init", "-q", "-b", "trunk"]) == nil else { return XCTFail("git init prints nothing") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.git"), "git init must have succeeded")
    let gitDirectory = try XCTUnwrap(GitBranchReader.gitDirectory(at: root, timeout: timeout, extraEnvironment: isolated))
    XCTAssertEqual(URL(fileURLWithPath: gitDirectory).resolvingSymlinksInPath().path, root + "/.git")
    // An unborn branch has a name but no commit.
    XCTAssertEqual(branch(), "trunk")
    let commit = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "--allow-empty", "-m", "x"]
    XCTAssertNil(git(commit), "git commit prints nothing")
    let head = try XCTUnwrap(git(["rev-parse", "--short", "HEAD"]), "the commit must have succeeded")
    XCTAssertEqual(branch(), "trunk")
    XCTAssertNil(git(["checkout", "-q", "--detach"]))
    XCTAssertEqual(branch(), GitBranchReader.detachedLabel(head))
  }

  func testRemoteBranchCommandIsWrappedForPosixShell() throws {
    let root = try makeTemporaryDirectory().resolvingSymlinksInPath().appendingPathComponent("it's here").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let command = GitBranchReader.remoteCommand(directory: root)
    XCTAssertTrue(command.hasPrefix("/bin/sh -c '"), command)
    XCTAssertTrue(command.hasSuffix("'"), command)
    // A login shell such as fish would receive `command` verbatim; /bin/sh must parse the single quoted script.
    func output() throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let isolated = ["HOME": root, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    func git(_ arguments: [String]) -> String? { GitBranchReader.run(arguments, in: root, timeout: 30, extraEnvironment: isolated) }
    XCTAssertEqual(try output(), "", "outside a repository nothing is printed")
    XCTAssertNil(git(["init", "-q", "-b", "trunk"]))
    XCTAssertEqual(try output(), "trunk")
    XCTAssertNil(git(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "--allow-empty", "-m", "x"]))
    let head = try XCTUnwrap(git(["rev-parse", "--short", "HEAD"]))
    XCTAssertNil(git(["checkout", "-q", "--detach"]))
    XCTAssertEqual(try output(), "detached:" + head)
  }
}
