// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class WorkspaceStateTests: XCTestCase {
  func testReconcileKeepsOrderAndAppendsNewSessions() {
    var saved = WorkspaceState()
    saved.namespaces = [
      .init(id: "b", tabs: [.init(id: "b2", selectedPaneID: "pane2"), .init(id: "gone", selectedPaneID: nil)], selectedTabID: "b2"),
      .init(id: "gone", tabs: [], selectedTabID: nil),
      .init(id: "a", tabs: [.init(id: "a1", selectedPaneID: "pane2")], selectedTabID: "missing"),
    ]
    saved.selectedNamespaceID = "b"
    let live: [WorkspaceState.Namespace] = [
      .init(id: "a", tabs: [.init(id: "a1", selectedPaneID: "pane1")], selectedTabID: "a1"),
      .init(id: "b", tabs: [.init(id: "b1", selectedPaneID: "pane3"), .init(id: "b2", selectedPaneID: "pane4")], selectedTabID: "b1"),
      .init(id: "new", tabs: [], selectedTabID: nil),
    ]
    let restored = saved.reconciled(with: live, panesByTab: ["a1": ["pane1"], "b2": ["pane2", "pane4"]])
    XCTAssertEqual(restored.namespaces.map(\.id), ["b", "a", "new"])
    XCTAssertEqual(restored.namespaces[0].tabs.map(\.id), ["b2", "b1"])
    XCTAssertEqual(restored.namespaces[0].selectedTabID, "b2")
    XCTAssertEqual(restored.namespaces[0].tabs[0].selectedPaneID, "pane2")
    XCTAssertEqual(restored.namespaces[1].tabs[0].selectedPaneID, "pane1")
    XCTAssertEqual(restored.namespaces[1].selectedTabID, "a1")
  }

  func testWindowUpdatesPreserveDetachedNamespaces() {
    var state = WorkspaceState()
    state.namespaces = ["a", "b", "c"].map { .init(id: $0, tabs: [], selectedTabID: nil) }
    state.update([state.namespaces[2], state.namespaces[0]], replacing: ["a", "c"])
    XCTAssertEqual(state.namespaces.map(\.id), ["c", "b", "a"])
    state.update([], replacing: ["b"])
    XCTAssertEqual(state.namespaces.map(\.id), ["c", "a"])
  }

  func testLegacyStateAndWindowOwnership() throws {
    let legacy = try JSONDecoder().decode(WorkspaceState.self, from: Data("{\"version\":1,\"namespaces\":[]}".utf8))
    XCTAssertNil(legacy.windows)
    XCTAssertEqual(legacy.reconciled(with: [], panesByTab: [:]).version, 2)
    var state = WorkspaceState()
    state.namespaces = ["a", "b"].map { .init(id: $0, tabs: [], selectedTabID: nil) }
    state.windows = [
      .init(id: "one", namespaceIDs: ["a", "gone"], selectedNamespaceID: "gone", frame: .init(x: 10, y: 20, width: 800, height: 600), sidebar: nil),
      .init(id: "two", namespaceIDs: ["a", "b"], selectedNamespaceID: "b", frame: nil, sidebar: nil),
    ]
    let restored = state.reconciled(with: state.namespaces, panesByTab: [:])
    XCTAssertEqual(restored.windows?.map(\.namespaceIDs), [["a"], ["b"]])
    XCTAssertEqual(restored.windows?.first?.selectedNamespaceID, "a")
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(restored)), restored)
  }

  func testStoreRoundTripAndFutureVersionProtection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
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
    XCTAssertThrowsError(try store.load())
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
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
    var old = WorkspaceState(); old.version = 2
    try store.save(old)
    var updated = try store.load(); updated.version = 3
    try store.save(updated)
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: store.url.appendingPathExtension("v2.backup"))), old)
  }
}
