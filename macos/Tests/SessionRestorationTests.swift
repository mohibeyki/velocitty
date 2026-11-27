// SPDX-License-Identifier: GPL-3.0
import Darwin
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class SessionRestorationTests: XCTestCase {
  // MARK: Saved text

  func testBoundedKeepsRecentLinesWithoutControlSequences() {
    let text = "\n\nold\n\u{1B}[31mred\u{1B}[0m\r\nnew\u{7}\t end\n\n  \n"
    XCTAssertEqual(SessionScrollback.bounded(text), "old\n[31mred[0m\nnew\t end")
    XCTAssertEqual(SessionScrollback.bounded("a\nb\nc\nd", maxLines: 2), "c\nd")
    XCTAssertEqual(SessionScrollback.bounded("aaaa\nbbbb\ncccc", maxBytes: 10), "bbbb\ncccc")
    XCTAssertEqual(SessionScrollback.bounded(" \n\u{1B}\n"), "")
  }

  func testDisplayDimsTextAndEndsWithSeparator() {
    let shown = SessionScrollback.display("one\ntwo")
    XCTAssertTrue(shown.hasPrefix("\u{1B}[2mone\ntwo\u{1B}[0m\n"))
    XCTAssertTrue(shown.contains("restored session"))
    XCTAssertTrue(shown.hasSuffix("\u{1B}[0m\n"))
    XCTAssertFalse(SessionScrollback.terminalOutput("one\ntwo").contains("\r\r"))
    XCTAssertTrue(SessionScrollback.terminalOutput("one\ntwo").contains("one\r\ntwo\u{1B}[0m\r\n"))
  }

  // MARK: Files

  func testStoreFilesAreOwnerOnlyAndReplacedAtomically() throws {
    let directory = try makeTemporaryDirectory()
    let store = ScrollbackStore(besideStateAt: directory.appendingPathComponent("workspace.json"))
    XCTAssertTrue(try store.save("first", key: "ssh:host::term_1"))
    XCTAssertFalse(try store.save("first", key: "ssh:host::term_1"), "Unchanged text is not rewritten")
    XCTAssertTrue(try store.save("second", key: "ssh:host::term_1"))
    XCTAssertEqual(store.load("ssh:host::term_1")?.text, "second")
    XCTAssertNotNil(store.load("ssh:host::term_1")?.savedAt)
    let file = store.url(for: "ssh:host::term_1")
    XCTAssertEqual(file.deletingLastPathComponent(), store.directory)
    XCTAssertFalse(file.lastPathComponent.contains(":"))
    XCTAssertEqual(try permissions(file), 0o600)
    XCTAssertEqual(try permissions(store.directory), 0o700)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [file.lastPathComponent],
      "No temporary files may remain")
    let escaping = store.url(for: "../../etc/passwd")
    XCTAssertEqual(escaping.deletingLastPathComponent(), store.directory)
    XCTAssertFalse(try store.save("  \n", key: "blank"))
    XCTAssertNil(store.load("blank"))
    store.remove(["ssh:host::term_1", "missing"])
    XCTAssertNil(store.load("ssh:host::term_1"))
  }

  func testPruneKeepsSavedTerminalsAndRecentFiles() throws {
    let directory = try makeTemporaryDirectory()
    let store = ScrollbackStore(besideStateAt: directory.appendingPathComponent("workspace.json"))
    for key in ["kept", "old", "fresh"] { try store.save(key, key: key) }
    let past = Date(timeIntervalSinceNow: -30 * 24 * 3600)
    for key in ["kept", "old"] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: store.url(for: key).path) }
    store.prune(keeping: ["kept"])
    XCTAssertNotNil(store.load("kept"))
    XCTAssertNil(store.load("old"))
    XCTAssertNotNil(store.load("fresh"))
    store.prune(keeping: [], olderThan: 0)
    XCTAssertNil(store.load("fresh"))
  }

  private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  // MARK: Recreating lost terminals

  private func pane(_ id: Int, tab: Int, space: String = "w1", prefix: String = "") -> WorkspaceState.Pane {
    var pane = WorkspaceState.Pane(id: "\(prefix)\(space):p\(id)", terminalID: "\(prefix)term_\(id)", workspaceID: prefix + space, cwd: "/work/\(id)")
    pane.tabID = "\(prefix)\(space):t\(tab)"
    return pane
  }

  private var saved: WorkspaceState {
    var state = WorkspaceState()
    var split = WorkspaceState.Tab(id: "w1:t1", selectedPaneID: "w1:p2", zoomed: true)
    split.panes = [pane(1, tab: 1), pane(2, tab: 2)]
    split.layout = .split(direction: "right", ratio: 0.3, first: .terminal("term_1"), second: .terminal("term_2"))
    split.title = "build"
    var single = WorkspaceState.Tab(id: "w1:t3", selectedPaneID: "w1:p3")
    single.panes = [pane(3, tab: 3)]
    single.layout = .terminal("term_3")
    var remote = WorkspaceState.Tab(id: "ssh:gpu::w1:t1", selectedPaneID: "ssh:gpu::w1:p1")
    remote.panes = [pane(9, tab: 1, prefix: "ssh:gpu::")]
    var space = WorkspaceState.Namespace(id: "w1", tabs: [split, single], selectedTabID: "w1:t3")
    space.name = "Work"
    var other = WorkspaceState.Namespace(id: "ssh:gpu::w1", tabs: [remote], selectedTabID: remote.id)
    other.name = "GPU"
    state.namespaces = [space, other]
    state.selectedNamespaceID = "w1"
    var window = WorkspaceState.Window(id: "window", namespaceIDs: ["w1", "ssh:gpu::w1"], selectedNamespaceID: "w1", frame: nil, sidebar: nil)
    window.primaryTabID = "w1:t1"; window.companionTabID = "w1:t3"; window.focusedTerminalID = "term_3"
    state.windows = [window]
    return state
  }

  func testLostTerminalsAreOnlyThoseOfTheEndpointMissingFromTheServer() {
    let lost = saved.lostTerminals(endpoint: "local", live: ["term_3"], excluding: ["term_2"])
    XCTAssertEqual(lost.map(\.namespaceID), ["w1"])
    XCTAssertEqual(lost.first?.panes.map(\.terminalID), ["term_1"])
    XCTAssertEqual(lost.first?.name, "Work")
    XCTAssertEqual(saved.lostTerminals(endpoint: "local", live: []).first?.panes.map(\.terminalID), ["term_1", "term_2", "term_3"])
    XCTAssertEqual(saved.lostTerminals(endpoint: "ssh:gpu", live: []).first?.panes.map(\.terminalID), ["ssh:gpu::term_9"])
    XCTAssertTrue(saved.lostTerminals(endpoint: "local", live: ["term_1", "term_2", "term_3"]).isEmpty)
  }

  func testRecreatedStateFollowsNewTerminalsAndKeepsLayoutAndSelection() throws {
    // The new server numbers its IDs from the start again, so old and new IDs overlap.
    func created(_ old: Int, as new: Int, tab: Int) -> (String, WorkspaceState.Pane) {
      var pane = WorkspaceState.Pane(id: "w1:p\(new)", terminalID: "fresh_\(new)", workspaceID: "w1", cwd: nil)
      pane.tabID = "w1:t\(tab)"
      return ("term_\(old)", pane)
    }
    let replacements = Dictionary(uniqueKeysWithValues: [created(1, as: 2, tab: 2), created(2, as: 3, tab: 3), created(3, as: 1, tab: 1)])
    let state = saved.recreated(replacements: replacements)
    let space = state.namespaces[0]
    XCTAssertEqual(space.id, "w1")
    XCTAssertEqual(space.tabs.map(\.id), ["w1:t2", "w1:t1"])
    XCTAssertEqual(space.selectedTabID, "w1:t1")
    XCTAssertEqual(space.tabs[0].panes?.map(\.terminalID), ["fresh_2", "fresh_3"])
    XCTAssertEqual(space.tabs[0].panes?.map(\.cwd), ["/work/1", "/work/2"], "Saved directories are kept")
    XCTAssertEqual(space.tabs[0].selectedPaneID, "w1:p3")
    XCTAssertEqual(space.tabs[0].layout, .split(direction: "right", ratio: 0.3, first: .terminal("fresh_2"), second: .terminal("fresh_3")))
    XCTAssertEqual(space.tabs[0].title, "build")
    XCTAssertEqual(space.tabs[0].zoomed, true)
    XCTAssertEqual(state.windows?.first?.primaryTabID, "w1:t2")
    XCTAssertEqual(state.windows?.first?.companionTabID, "w1:t1")
    XCTAssertEqual(state.windows?.first?.focusedTerminalID, "fresh_1")
    XCTAssertEqual(state.namespaces[1], saved.namespaces[1], "Other endpoints are untouched")
    // The saved file stays loadable.
    let directory = try makeTemporaryDirectory()
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    try store.save(state)
    XCTAssertEqual(try store.load(), state)
  }

  func testRecreatedStateMovesNamespacesToTheirNewWorkspaces() {
    var replacement = WorkspaceState.Pane(id: "w5:p1", terminalID: "fresh", workspaceID: "w5", cwd: nil)
    replacement.tabID = "w5:t1"
    let state = saved.recreated(replacements: ["term_1": replacement])
    XCTAssertEqual(state.namespaces[0].id, "w5")
    XCTAssertEqual(state.selectedNamespaceID, "w5")
    XCTAssertEqual(state.windows?.first?.namespaceIDs, ["w5", "ssh:gpu::w1"])
    XCTAssertEqual(state.windows?.first?.selectedNamespaceID, "w5")
    XCTAssertEqual(saved.recreated(replacements: [:]), saved)
  }

  func testPaneLayoutMappingKeepsShapeAndRatios() {
    let layout = PaneLayout.split(direction: "down", ratio: 0.7, first: .terminal("a"),
      second: .split(direction: "right", ratio: 0.2, first: .terminal("b"), second: .terminal("c")))
    XCTAssertEqual(layout.mapping { $0.uppercased() }, .split(direction: "down", ratio: 0.7, first: .terminal("A"),
      second: .split(direction: "right", ratio: 0.2, first: .terminal("B"), second: .terminal("C"))))
  }

  func testRestoreSessionSettingDefaultsOnAndValidates() throws {
    XCTAssertEqual(NamespaceAppearance.defaults["restore_session"], "true")
    XCTAssertTrue(NamespaceAppearance.validate("false", for: "restore_session"))
    XCTAssertFalse(NamespaceAppearance.validate("maybe", for: "restore_session"))
    let config = try AppConfiguration.parse(Data("[interface]\nrestore_session = false\n".utf8))
    XCTAssertEqual(config.interface["restore_session"], "false")
  }
}
