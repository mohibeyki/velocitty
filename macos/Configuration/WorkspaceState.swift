// SPDX-License-Identifier: GPL-3.0
import Darwin
import Foundation

public struct WorkspaceState: Codable, Equatable, Sendable {
  public struct Pane: Codable, Equatable, Sendable {
    public var id: String
    public var terminalID: String
    public var workspaceID: String
    public var cwd: String?
    public var tabID: String? = nil
    public var connectionID: String { WorkspaceState.connectionID(of: terminalID) }
    public init(id: String, terminalID: String, workspaceID: String, cwd: String?) {
      self.id = id; self.terminalID = terminalID; self.workspaceID = workspaceID; self.cwd = cwd
    }
  }
  public struct Tab: Codable, Equatable, Sendable {
    public var id: String
    public var selectedPaneID: String?
    public var zoomed: Bool?
    public var panes: [Pane]?
    public var title: String?
    public var layout: PaneLayout? = nil
    public var connectionID: String { WorkspaceState.connectionID(of: id) }
    public init(id: String, selectedPaneID: String?, zoomed: Bool? = nil) {
      self.id = id; self.selectedPaneID = selectedPaneID; self.zoomed = zoomed
    }
  }
  public struct Namespace: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
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
  public struct Frame: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x; self.y = y; self.width = width; self.height = height
    }
  }
  public struct Window: Codable, Equatable, Sendable {
    public var id: String
    public var namespaceIDs: [String]
    public var selectedNamespaceID: String?
    public var companionTabID: String?
    public var primaryTabID: String?
    public var companionRatio: Double?
    public var focusedTerminalID: String?
    public var frame: Frame?
    public var sidebar: Sidebar?
    public init(id: String, namespaceIDs: [String], selectedNamespaceID: String?, frame: Frame?, sidebar: Sidebar?) {
      self.id = id; self.namespaceIDs = namespaceIDs; self.selectedNamespaceID = selectedNamespaceID
      self.frame = frame; self.sidebar = sidebar
    }
  }
  public var pendingTerminalClosures: [String]?
  public var windows: [Window]?
  public var activeWindowID: String?
  public static let currentVersion = 4
  public var version = currentVersion
  public var namespaces: [Namespace] = []
  public var selectedNamespaceID: String?
  public var sidebar: Sidebar?
  public init() {}

  /// The endpoint that owns a qualified ID ("<endpoint>::<raw>"); unqualified IDs are local.
  static func connectionID(of id: String) -> String { id.range(of: "::").map { String(id[..<$0.lowerBound]) } ?? "local" }

  /// Reconcile one successful endpoint snapshot without changing local space membership.
  /// Unavailable endpoints are deliberately absent from this operation.
  public func reconciled(endpoint: String, live: [Namespace]) -> Self {
    var result = self
    let liveTabs = Dictionary(uniqueKeysWithValues: live.flatMap(\.tabs).map { ($0.id, $0) })
    let livePanes = Dictionary(uniqueKeysWithValues: live.flatMap(\.tabs).flatMap { $0.panes ?? [] }.map { ($0.terminalID, $0) })
    var assigned = Set<String>()
    var assignedTabs = Set<String>()
    for index in result.namespaces.indices {
      result.namespaces[index].tabs = result.namespaces[index].tabs.compactMap { saved in
        var current = saved
        if let panes = saved.panes {
          current.panes = panes.compactMap { pane in
            guard pane.connectionID == endpoint else { return pane }
            guard var live = livePanes[pane.terminalID] else { return nil }
            // The host's OSC/PWD value is presentation state and may be newer than
            // the server's creation cwd. Do not reintroduce a difference every poll.
            live.cwd = pane.cwd ?? live.cwd
            return live
          }
          guard let surviving = current.panes, !surviving.isEmpty else { return nil }
          assigned.formUnion(surviving.map(\.terminalID))
          current.layout = saved.layout?.retaining(Set(surviving.map(\.terminalID)))
          if !surviving.contains(where: { $0.id == current.selectedPaneID }) { current.selectedPaneID = surviving.first?.id }
        } else if saved.connectionID == endpoint {
          guard let replacement = liveTabs[saved.id] else { return nil }
          current.panes = replacement.panes
          assigned.formUnion(replacement.panes?.map(\.terminalID) ?? [])
        }
        assignedTabs.insert(current.id)
        return current
      }
    }
    for workspace in live {
      let added = workspace.tabs.compactMap { tab -> Tab? in
        var tab = tab
        if let panes = tab.panes {
          tab.panes = panes.filter { !assigned.contains($0.terminalID) }
          guard tab.panes?.isEmpty == false else { return nil }
        } else if assignedTabs.contains(tab.id) { return nil }
        return tab
      }
      guard !added.isEmpty else { continue }
      let index = result.namespaces.firstIndex { space in
        space.id == workspace.id || space.tabs.contains { tab in tab.panes?.contains { $0.workspaceID == workspace.id } == true }
      }
      if let index {
        for tab in added {
          if let ti = result.namespaces[index].tabs.firstIndex(where: { $0.id == tab.id }) { result.namespaces[index].tabs[ti].panes = (result.namespaces[index].tabs[ti].panes ?? []) + (tab.panes ?? []) }
          else { result.namespaces[index].tabs.append(tab) }
        }
      } else { var space = workspace; space.tabs = added; result.namespaces.append(space) }
    }
    result.namespaces.removeAll { $0.tabs.isEmpty }
    for index in result.namespaces.indices {
      if !result.namespaces[index].tabs.contains(where: { $0.id == result.namespaces[index].selectedTabID }) {
        result.namespaces[index].selectedTabID = result.namespaces[index].tabs.first?.id
      }
    }
    let ids = Set(result.namespaces.map(\.id))
    if !ids.contains(result.selectedNamespaceID ?? "") { result.selectedNamespaceID = result.namespaces.first?.id }
    if var windows = result.windows {
      for index in windows.indices {
        windows[index].namespaceIDs.removeAll { !ids.contains($0) }
        if !windows[index].namespaceIDs.contains(windows[index].selectedNamespaceID ?? "") { windows[index].selectedNamespaceID = windows[index].namespaceIDs.first }
      }
      result.windows = windows.filter { !$0.namespaceIDs.isEmpty }
    }
    result.version = Self.currentVersion
    return result
  }

  /// Window groups to open for the available namespaces, in saved order. Namespaces with no
  /// saved window join the active window, or a new one when no saved window survives.
  public func windowGroups(available: [String]) -> [Window] {
    var groups = (windows ?? []).compactMap { saved -> Window? in
      var window = saved
      window.namespaceIDs = window.namespaceIDs.filter { available.contains($0) }
      return window.namespaceIDs.isEmpty ? nil : window
    }
    let assigned = Set(groups.flatMap(\.namespaceIDs))
    let unknown = available.filter { !assigned.contains($0) }
    guard !unknown.isEmpty else { return groups }
    if let index = groups.firstIndex(where: { $0.id == activeWindowID }) ?? groups.indices.first {
      groups[index].namespaceIDs += unknown
    } else {
      groups.append(.init(id: UUID().uuidString, namespaceIDs: unknown,
        selectedNamespaceID: selectedNamespaceID ?? unknown.first, frame: nil, sidebar: sidebar))
    }
    return groups
  }

  /// Save one window's presentation. A namespace has one presentation owner, even after a
  /// cross-window move, so other windows lose the namespaces it now presents.
  public mutating func assign(window presentation: Window) {
    var saved = windows ?? []
    for index in saved.indices where saved[index].id != presentation.id {
      saved[index].namespaceIDs.removeAll { presentation.namespaceIDs.contains($0) }
    }
    if let index = saved.firstIndex(where: { $0.id == presentation.id }) { saved[index] = presentation }
    else if !presentation.namespaceIDs.isEmpty { saved.append(presentation) }
    saved.removeAll { $0.namespaceIDs.isEmpty }
    windows = saved
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

public enum WorkspaceStateError: Error, Equatable {
  case unsupportedFutureVersion(Int)
  case conflictingUpdate
}

public struct WorkspaceStateStore {
  public let url: URL
  public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Velocitty/workspace.json")) { self.url = url }

  public func load() throws -> WorkspaceState { try loadWithRevision().state }

  public func loadWithRevision() throws -> (state: WorkspaceState, revision: Data?) {
    guard let data = try readIfPresent() else { return (WorkspaceState(), nil) }
    // A newer schema may not decode at all, so check the version before decoding.
    if let version = Self.storedVersion(in: data), version > WorkspaceState.currentVersion {
      throw WorkspaceStateError.unsupportedFutureVersion(version)
    }
    let state = try JSONDecoder().decode(WorkspaceState.self, from: data)
    guard (1...WorkspaceState.currentVersion).contains(state.version) else { throw ConfigurationError("Unsupported workspace state version: \(state.version)") }
    // Reject malformed state rather than overwriting it during this run.
    let namespaces = state.namespaces.map(\.id)
    let tabs = state.namespaces.flatMap(\.tabs).map(\.id)
    guard Set(namespaces).count == namespaces.count, Set(tabs).count == tabs.count,
      namespaces.allSatisfy({ !$0.isEmpty }), tabs.allSatisfy({ !$0.isEmpty }),
      state.sidebar.map({ $0.width.isFinite && (160...400).contains($0.width) }) ?? true
    else { throw ConfigurationError("Invalid workspace state.") }
    let terminals = state.namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }.map(\.terminalID)
    guard Set(terminals).count == terminals.count,
      state.namespaces.flatMap(\.tabs).flatMap({ $0.panes ?? [] }).allSatisfy({ !$0.id.isEmpty && !$0.terminalID.isEmpty && !$0.workspaceID.isEmpty }),
      state.namespaces.flatMap(\.tabs).allSatisfy({ tab in
        tab.layout.map { $0.validated() && Set($0.terminals) == Set(tab.panes?.map(\.terminalID) ?? []) } ?? true
      }) else { throw ConfigurationError("Invalid pane layout in workspace state.") }
    if let windows = state.windows {
      guard Set(windows.map(\.id)).count == windows.count,
        Set(windows.flatMap(\.namespaceIDs)).count == windows.flatMap(\.namespaceIDs).count,
        windows.allSatisfy({ window in
          !window.id.isEmpty && window.namespaceIDs.allSatisfy { namespaces.contains($0) }
            && (window.sidebar.map { $0.width.isFinite && (160...400).contains($0.width) } ?? true)
            && (window.frame.map { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 } ?? true)
        }) else { throw ConfigurationError("Invalid workspace window state.") }
    }
    return (state, data)
  }

  public func preserveDamagedState() throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let backup = url.appendingPathExtension("damaged-" + UUID().uuidString)
    try FileManager.default.copyItem(at: url, to: backup)
  }

  @discardableResult
  public func save(_ state: WorkspaceState) throws -> Data {
    try withExclusiveLock { try saveLocked(state) }
  }

  @discardableResult
  public func save(_ state: WorkspaceState, expectedRevision: Data?) throws -> Data {
    try withExclusiveLock {
      let current = try readIfPresent()
      guard current == expectedRevision else { throw WorkspaceStateError.conflictingUpdate }
      return try saveLocked(state)
    }
  }

  private func saveLocked(_ state: WorkspaceState) throws -> Data {
    let previous = try readIfPresent()
    if let previous, let version = Self.storedVersion(in: previous), version > WorkspaceState.currentVersion {
      throw WorkspaceStateError.unsupportedFutureVersion(version)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    if let previous,
      let old = try? JSONDecoder().decode(WorkspaceState.self, from: previous), old.version < WorkspaceState.currentVersion {
      let backup = url.appendingPathExtension("v\(old.version).backup")
      if !FileManager.default.fileExists(atPath: backup.path) { try previous.write(to: backup, options: .withoutOverwriting) }
    }
    try data.write(to: url, options: .atomic)
    return data
  }

  /// A missing file is "no state"; any other read failure must not be mistaken for one.
  private func readIfPresent() throws -> Data? {
    do { return try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
  }

  /// The raw schema version, read without decoding the rest of a possibly newer schema.
  private static func storedVersion(in data: Data) -> Int? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return (object["version"] as? NSNumber)?.intValue
  }

  private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockURL = url.appendingPathExtension("lock")
    let descriptor: Int32 = lockURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return -1 }
      return open(path, O_RDWR | O_CREAT, 0o600)
    }
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
    return try body()
  }
}
