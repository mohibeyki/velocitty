// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class WorkspaceStateTests: XCTestCase {
  func testWindowUpdatesPreserveDetachedNamespaces() {
    var state = WorkspaceState()
    state.namespaces = ["a", "b", "c"].map { .init(id: $0, tabs: [], selectedTabID: nil) }
    state.update([state.namespaces[2], state.namespaces[0]], replacing: ["a", "c"])
    XCTAssertEqual(state.namespaces.map(\.id), ["c", "b", "a"])
    state.update([], replacing: ["b"])
    XCTAssertEqual(state.namespaces.map(\.id), ["c", "a"])
  }

  func testWindowGroupsFilterSavedWindowsAndPlaceUnknownNamespacesInActiveWindow() {
    var state = WorkspaceState()
    state.windows = [.init(id: "w1", namespaceIDs: ["a", "gone"], selectedNamespaceID: "a", frame: nil, sidebar: nil),
      .init(id: "w2", namespaceIDs: ["b"], selectedNamespaceID: "b", frame: nil, sidebar: nil),
      .init(id: "w3", namespaceIDs: ["attached"], selectedNamespaceID: nil, frame: nil, sidebar: nil)]
    state.activeWindowID = "w2"
    XCTAssertEqual(state.windowGroups(available: ["a", "b", "new"]).map(\.namespaceIDs), [["a"], ["b", "new"]])
    state.windows = nil
    state.selectedNamespaceID = "new"
    let groups = state.windowGroups(available: ["c", "new"])
    XCTAssertEqual(groups.map(\.namespaceIDs), [["c", "new"]])
    XCTAssertEqual(groups.first?.selectedNamespaceID, "new")
  }

  func testAssignedWindowOwnsItsNamespaces() {
    var state = WorkspaceState()
    state.windows = [.init(id: "w1", namespaceIDs: ["a", "b"], selectedNamespaceID: "a", frame: nil, sidebar: nil),
      .init(id: "w2", namespaceIDs: ["c"], selectedNamespaceID: "c", frame: nil, sidebar: nil)]
    state.assign(window: .init(id: "w2", namespaceIDs: ["c", "b"], selectedNamespaceID: "b", frame: nil, sidebar: nil))
    XCTAssertEqual(state.windows?.map(\.namespaceIDs), [["a"], ["c", "b"]])
    state.assign(window: .init(id: "w3", namespaceIDs: ["a"], selectedNamespaceID: "a", frame: nil, sidebar: nil))
    XCTAssertEqual(state.windows?.map(\.id), ["w2", "w3"])
    state.assign(window: .init(id: "w4", namespaceIDs: [], selectedNamespaceID: nil, frame: nil, sidebar: nil))
    XCTAssertEqual(state.windows?.map(\.id), ["w2", "w3"])
  }

  func testLegacyStateDecodes() throws {
    let legacy = try JSONDecoder().decode(WorkspaceState.self, from: Data("{\"version\":1,\"namespaces\":[]}".utf8))
    XCTAssertNil(legacy.windows)
    XCTAssertEqual(legacy.version, 1)
  }

  func testStoreRoundTripAndFutureVersionProtection() throws {
    let directory = try makeTemporaryDirectory()
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    XCTAssertEqual(try store.load(), WorkspaceState())
    var state = WorkspaceState()
    state.sidebar = .init(width: 276, compact: true)
    state.namespaces = [.init(id: "a", tabs: [.init(id: "tab", selectedPaneID: "pane")], selectedTabID: "tab")]
    state.selectedNamespaceID = "a"
    try store.save(state)
    XCTAssertEqual(try store.load(), state)
    let future = Data("{\"version\":99,\"namespaces\":[]}".utf8)
    try future.write(to: store.url)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? WorkspaceStateError, .unsupportedFutureVersion(99))
    }
    XCTAssertThrowsError(try store.save(WorkspaceState())) { error in
      XCTAssertEqual(error as? WorkspaceStateError, .unsupportedFutureVersion(99))
    }
    XCTAssertEqual(try Data(contentsOf: store.url), future)
  }

  func testFutureVersionWithIncompatibleSchemaIsNotTreatedAsDamaged() throws {
    let directory = try makeTemporaryDirectory()
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    let future = Data("{\"version\":7,\"namespaces\":{\"changed\":true}}".utf8)
    try future.write(to: store.url)
    XCTAssertThrowsError(try store.loadWithRevision()) { error in
      XCTAssertEqual(error as? WorkspaceStateError, .unsupportedFutureVersion(7))
    }
    XCTAssertEqual(try Data(contentsOf: store.url), future)
  }
}

extension WorkspaceStateTests {
  func testMixedSpaceReconciliationKeepsOfflineTabsAndLocalNames() {
    var saved = WorkspaceState()
    var space = WorkspaceState.Namespace(id: "project", tabs: [.init(id: "tab", selectedPaneID: nil), .init(id: "ssh:gpu::tab", selectedPaneID: nil)], selectedTabID: "ssh:gpu::tab")
    space.name = "My Project"; saved.namespaces = [space]
    let live = WorkspaceState.Namespace(id: "backend", tabs: [.init(id: "tab", selectedPaneID: nil)], selectedTabID: nil)
    let restored = saved.reconciled(endpoint: "local", live: [live])
    XCTAssertEqual(restored.namespaces.count, 1)
    XCTAssertEqual(restored.namespaces[0].id, "project")
    XCTAssertEqual(restored.namespaces[0].name, "My Project")
    XCTAssertEqual(restored.namespaces[0].tabs.map(\.id), ["tab", "ssh:gpu::tab"])
    let gone = restored.reconciled(endpoint: "local", live: [])
    XCTAssertEqual(gone.namespaces[0].tabs.map(\.id), ["ssh:gpu::tab"])
  }

  func testAdditionalLocalEndpointCannotRemoveDefaultLocalTabs() {
    var saved = WorkspaceState()
    saved.namespaces = [.init(id: "project", tabs: [.init(id: "tab", selectedPaneID: nil), .init(id: "local:other::tab", selectedPaneID: nil)], selectedTabID: "tab")]
    let restored = saved.reconciled(endpoint: "local:other", live: [])
    XCTAssertEqual(restored.namespaces[0].tabs.map(\.id), ["tab"])
  }

  func testMigrationKeepsBackup() throws {
    let directory = try makeTemporaryDirectory()
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    var old = WorkspaceState(); old.version = 2
    try store.save(old)
    var updated = try store.load(); updated.version = 3
    try store.save(updated)
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: store.url.appendingPathExtension("v2.backup"))), old)
  }
}

extension WorkspaceStateTests {
  func testDamagedStateIsPreservedBeforeFreshSave() throws {
    let directory = try makeTemporaryDirectory()
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    let original = Data("broken json".utf8)
    try original.write(to: store.url)
    XCTAssertThrowsError(try store.load())
    try store.preserveDamagedState()
    try store.save(WorkspaceState())
    let backup = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("damaged-") }!
    XCTAssertEqual(try Data(contentsOf: backup), original)
    XCTAssertEqual(try store.load(), WorkspaceState())
  }
}

extension WorkspaceStateTests {
  func testStaleWriterCannotOverwriteNewerWorkspaceOrPendingCloses() throws {
    let directory = try makeTemporaryDirectory()
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    try store.save(WorkspaceState())
    let first = try store.loadWithRevision()
    let second = try store.loadWithRevision()

    var firstState = first.state
    firstState.pendingTerminalClosures = ["terminal-to-close"]
    let savedRevision = try store.save(firstState, expectedRevision: first.revision)

    var staleState = second.state
    staleState.sidebar = .init(width: 300, compact: false)
    XCTAssertThrowsError(try store.save(staleState, expectedRevision: second.revision)) { error in
      XCTAssertEqual(error as? WorkspaceStateError, .conflictingUpdate)
    }
    XCTAssertEqual(try store.load(), firstState)

    var merged = try store.load()
    merged.sidebar = staleState.sidebar
    merged.pendingTerminalClosures = Set((merged.pendingTerminalClosures ?? []) + ["another-terminal"]).sorted()
    try store.save(merged, expectedRevision: savedRevision)
    XCTAssertEqual(try store.load().pendingTerminalClosures, ["another-terminal", "terminal-to-close"])
  }
}

extension WorkspaceStateTests {
  func testReconciliationPreservesNewerHostDirectoryAndStaysClean() {
    let savedPane = WorkspaceState.Pane(id: "pane", terminalID: "terminal", workspaceID: "backend", cwd: "/current")
    let livePane = WorkspaceState.Pane(id: "pane", terminalID: "terminal", workspaceID: "backend", cwd: "/creation")
    var savedTab = WorkspaceState.Tab(id: "tab", selectedPaneID: "pane")
    savedTab.panes = [savedPane]
    var liveTab = WorkspaceState.Tab(id: "tab", selectedPaneID: "pane")
    liveTab.panes = [livePane]
    var state = WorkspaceState()
    state.namespaces = [.init(id: "project", tabs: [savedTab], selectedTabID: "tab")]
    let live = [WorkspaceState.Namespace(id: "backend", tabs: [liveTab], selectedTabID: "tab")]
    let reconciled = state.reconciled(endpoint: "local", live: live)
    XCTAssertEqual(reconciled.namespaces[0].tabs[0].panes?[0].cwd, "/current")
    XCTAssertEqual(reconciled.reconciled(endpoint: "local", live: live), reconciled)
  }
}

extension WorkspaceStateTests {
  func testMixedPaneReconciliationAndLocalGeometry() {
    let a = WorkspaceState.Pane(id: "a", terminalID: "ta", workspaceID: "wa", cwd: nil)
    let b = WorkspaceState.Pane(id: "b", terminalID: "gpu::tb", workspaceID: "gpu::wb", cwd: nil)
    var tab = WorkspaceState.Tab(id: "local-tab", selectedPaneID: "b")
    tab.panes = [a, b]
    tab.layout = .terminal(a.terminalID).inserting(b.terminalID, beside: a.terminalID, direction: "down").settingRatio(path: [], ratio: 0.3)
    var state = WorkspaceState(); state.namespaces = [.init(id: "project", tabs: [tab], selectedTabID: tab.id)]
    var live = WorkspaceState.Tab(id: "backend-tab", selectedPaneID: "a"); live.panes = [a]
    let updated = state.reconciled(endpoint: "local", live: [.init(id: "backend-space", tabs: [live], selectedTabID: nil)])
    XCTAssertEqual(updated.namespaces, state.namespaces)
    let deleted = updated.reconciled(endpoint: "local", live: [])
    XCTAssertEqual(deleted.namespaces[0].tabs[0].panes, [b])
    XCTAssertEqual(deleted.namespaces[0].tabs[0].layout, .terminal(b.terminalID))
    XCTAssertTrue(tab.layout!.validated())
    XCTAssertFalse(PaneLayout.split(direction: "right", ratio: 0.5, first: .terminal("a"), second: .terminal("a")).validated())
  }
}
