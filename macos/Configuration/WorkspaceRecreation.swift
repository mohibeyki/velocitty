// SPDX-License-Identifier: GPL-3.0
import Foundation

/// The saved terminals of one namespace that a restarted server no longer has.
public struct LostNamespace: Equatable, Sendable {
  public var namespaceID: String
  public var name: String?
  /// In saved tab and pane order.
  public var panes: [WorkspaceState.Pane]
}

extension WorkspaceState {
  /// Saved terminals of one endpoint that its server does not have, grouped by namespace.
  public func lostTerminals(endpoint: String, live: Set<String>, excluding: Set<String> = []) -> [LostNamespace] {
    namespaces.compactMap { space in
      let lost = space.tabs.flatMap { $0.panes ?? [] }.filter {
        $0.connectionID == endpoint && !live.contains($0.terminalID) && !excluding.contains($0.terminalID)
      }
      return lost.isEmpty ? nil : LostNamespace(namespaceID: space.id, name: space.name, panes: lost)
    }
  }

  /// Saved terminals that a restarted server has already brought back under new terminal IDs. herdr
  /// restores each workspace, tab and pane with its old ID, so a missing terminal whose pane ID, tab and
  /// workspace are live again, under a terminal this workspace does not know, is its replacement.
  public func reboundTerminals(endpoint: String, live: [Pane], excluding: Set<String> = []) -> [String: Pane] {
    let saved = namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }
    let known = Set(saved.map(\.terminalID))
    let liveByPane = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var rebound: [String: Pane] = [:], claimed: Set<String> = []
    for pane in saved where pane.connectionID == endpoint && !excluding.contains(pane.terminalID) {
      guard let match = liveByPane[pane.id], match.terminalID != pane.terminalID, !known.contains(match.terminalID),
        match.workspaceID == pane.workspaceID, pane.tabID == nil || match.tabID == pane.tabID,
        claimed.insert(match.terminalID).inserted else { continue }
      rebound[pane.terminalID] = match
    }
    return rebound
  }

  /// This workspace with lost terminals replaced by newly created ones, keyed by the saved terminal ID
  /// each replaces. Tabs, namespaces, windows and layouts follow their terminals to the new IDs.
  public func recreated(replacements: [String: Pane]) -> Self {
    guard !replacements.isEmpty else { return self }
    var terminals: [String: String] = [:], panes: [String: String] = [:]
    var tabs: [String: String] = [:], spaces: [String: String] = [:]
    for space in namespaces {
      for tab in space.tabs {
        for pane in tab.panes ?? [] {
          guard let new = replacements[pane.terminalID] else { continue }
          terminals[pane.terminalID] = new.terminalID
          panes[pane.id] = new.id
          // A tab or namespace follows its first replaced terminal, when the same endpoint owns both IDs.
          if let tabID = new.tabID, tabs[tab.id] == nil, Self.connectionID(of: tab.id) == Self.connectionID(of: tabID) { tabs[tab.id] = tabID }
          if spaces[space.id] == nil, Self.connectionID(of: space.id) == Self.connectionID(of: new.workspaceID) { spaces[space.id] = new.workspaceID }
        }
      }
    }
    func follow(_ id: String, _ table: [String: String]) -> String { table[id] ?? id }
    var result = self
    result.namespaces = namespaces.map { space in
      var space = space
      space.id = follow(space.id, spaces)
      space.selectedTabID = space.selectedTabID.map { follow($0, tabs) }
      space.tabs = space.tabs.map { tab in
        var tab = tab
        tab.id = follow(tab.id, tabs)
        tab.selectedPaneID = tab.selectedPaneID.map { follow($0, panes) }
        tab.layout = tab.layout?.mapping { follow($0, terminals) }
        tab.panes = tab.panes?.map { old in
          guard var new = replacements[old.terminalID] else { return old }
          // The saved directory is where the new shell is put, so it is the one to keep.
          new.cwd = old.cwd ?? new.cwd
          return new
        }
        return tab
      }
      return space
    }
    result.selectedNamespaceID = selectedNamespaceID.map { follow($0, spaces) }
    result.windows = windows?.map { window in
      var window = window
      window.namespaceIDs = window.namespaceIDs.map { follow($0, spaces) }
      window.selectedNamespaceID = window.selectedNamespaceID.map { follow($0, spaces) }
      window.primaryTabID = window.primaryTabID.map { follow($0, tabs) }
      window.companionTabID = window.companionTabID.map { follow($0, tabs) }
      window.focusedTerminalID = window.focusedTerminalID.map { follow($0, terminals) }
      return window
    }
    return result
  }
}
