// SPDX-License-Identifier: GPL-3.0
import Foundation

public struct WorkspaceState: Codable, Equatable, Sendable {
  public struct Tab: Codable, Equatable, Sendable {
    public var id: String
    public var selectedPaneID: String?
    public init(id: String, selectedPaneID: String?) {
      self.id = id; self.selectedPaneID = selectedPaneID
    }
  }
  public struct Namespace: Codable, Equatable, Sendable {
    public var id: String
    public var tabs: [Tab]
    public var selectedTabID: String?
    public init(id: String, tabs: [Tab], selectedTabID: String?) {
      self.id = id; self.tabs = tabs; self.selectedTabID = selectedTabID
    }
  }
  public struct Sidebar: Codable, Equatable, Sendable {
    public var width: Double
    public var compact: Bool
    public init(width: Double, compact: Bool) { self.width = width; self.compact = compact }
  }
  public var version = 1
  public var namespaces: [Namespace] = []
  public var selectedNamespaceID: String?
  public var sidebar: Sidebar?
  public init() {}

  /// The successful server snapshot is authoritative for existence. Saved order
  /// and selection apply only to surviving objects; new objects append in server order.
  public func reconciled(with live: [Namespace], panesByTab: [String: Set<String>]) -> Self {
    var result = self
    var remaining = live
    result.namespaces = []
    for saved in namespaces {
      guard let index = remaining.firstIndex(where: { $0.id == saved.id }) else { continue }
      var current = remaining.remove(at: index)
      var tabs = current.tabs
      current.tabs = []
      for savedTab in saved.tabs {
        guard let index = tabs.firstIndex(where: { $0.id == savedTab.id }) else { continue }
        var tab = tabs.remove(at: index)
        if let selected = savedTab.selectedPaneID, panesByTab[tab.id]?.contains(selected) == true { tab.selectedPaneID = selected }
        current.tabs.append(tab)
      }
      current.tabs += tabs
      if let selected = saved.selectedTabID, current.tabs.contains(where: { $0.id == selected }) {
        current.selectedTabID = selected
      }
      result.namespaces.append(current)
    }
    result.namespaces += remaining
    if !result.namespaces.contains(where: { $0.id == selectedNamespaceID }) {
      result.selectedNamespaceID = result.namespaces.first?.id
    }
    return result
  }

  /// Update the namespaces owned by one window. Detached windows remain saved;
  /// namespaces explicitly removed by this window are removed from its saved scope.
  public mutating func update(_ current: [Namespace], replacing ownedIDs: Set<String>) {
    let currentIDs = Set(current.map(\.id))
    namespaces.removeAll { ownedIDs.contains($0.id) && !currentIDs.contains($0.id) }
    let existingIDs = Set(namespaces.map(\.id))
    // Keep other windows in place while allowing this window's ordering to change.
    var iterator = current.filter { existingIDs.contains($0.id) }.makeIterator()
    namespaces = namespaces.map { namespace in
      currentIDs.contains(namespace.id) ? iterator.next()! : namespace
    }
    namespaces += current.filter { !existingIDs.contains($0.id) }
  }
}

public struct WorkspaceStateStore {
  public let url: URL
  public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Velocitty/workspace.json")) { self.url = url }

  public func load() throws -> WorkspaceState {
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return WorkspaceState() }
    let state = try JSONDecoder().decode(WorkspaceState.self, from: data)
    guard state.version == 1 else { throw ConfigurationError("Unsupported workspace state version: \(state.version)") }
    // Reject malformed state rather than overwriting it during this run.
    let namespaces = state.namespaces.map(\.id)
    let tabs = state.namespaces.flatMap(\.tabs).map(\.id)
    guard Set(namespaces).count == namespaces.count, Set(tabs).count == tabs.count,
      namespaces.allSatisfy({ !$0.isEmpty }), tabs.allSatisfy({ !$0.isEmpty }),
      state.sidebar.map({ $0.width.isFinite && (160...400).contains($0.width) }) ?? true
    else { throw ConfigurationError("Invalid workspace state.") }
    return state
  }

  public func save(_ state: WorkspaceState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}
