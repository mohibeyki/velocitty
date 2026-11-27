// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

extension AppDelegate {
  func showMuxWarning() {
    let reason = herdr == nil
      ? "herdr 0.8.2 or newer is required for tabs and namespaces. Install herdr and relaunch Velocitty. This window remains a standalone terminal."
      : "This is a standalone terminal. Windows using command or initial_command cannot enable mux. Remove that override and open a new window to use herdr."
    showMuxError(ConfigurationError(muxError ?? reason))
  }

  func showMuxError(_ error: Error) {
    guard !terminating else { return }
    let alert = NSAlert()
    alert.messageText = "Multiplexing unavailable"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    if let window = activeWindow?.window, window.attachedSheet == nil {
      alert.beginSheetModal(for: window)
    } else { alert.runModal() }
  }

  fileprivate func savedTab(containing terminalID: String) -> WorkspaceState.Tab? {
    workspaceState?.namespaces.flatMap(\.tabs).first { $0.panes?.contains { $0.terminalID == terminalID } == true }
  }

  func localTabID(_ pane: HerdrClient.Pane) -> String { savedTab(containing: pane.terminal_id)?.id ?? pane.tab_id }

  private func savedNamespaces(_ snapshot: HerdrClient.Snapshot) -> [WorkspaceState.Namespace] {
    snapshot.workspaces.map { workspace in
      var space = WorkspaceState.Namespace(id: workspace.workspace_id, tabs: snapshot.tabs.filter { $0.workspace_id == workspace.workspace_id }.map { record in
        var tab = WorkspaceState.Tab(id: record.tab_id, selectedPaneID: snapshot.panes.first { $0.tab_id == record.tab_id }?.pane_id)
        tab.title = record.label == String(record.number ?? 1) ? nil : record.label
        tab.panes = snapshot.panes.filter { $0.tab_id == record.tab_id }.map { $0.saved() }
        return tab
      }, selectedTabID: nil)
      space.name = workspace.label
      return space
    }
  }

  func spaceForTab(_ id: String) -> WorkspaceState.Namespace? {
    if let spaceID = tabSpaceOverrides[id] ?? windows.flatMap(\.namespaces).first(where: { $0.tabs.contains { $0.herdrID == id } })?.id,
      let space = windows.flatMap(\.namespaces).first(where: { $0.id == spaceID }) {
      var saved = WorkspaceState.Namespace(id: spaceID, tabs: [], selectedTabID: nil); saved.name = space.name; return saved
    }
    return workspaceState?.namespaces.first { $0.tabs.contains { $0.id == id } }
  }

  func openHerdrWindow(using client: HerdrClient) {
    guard !muxOpening, !terminating, let runtime else { return }
    loadWorkspaceState(for: client)
    muxOpening = true
    quitTimer?.invalidate()
    let attached = attachedTerminalIDs.union(retainedTerminalIDs)
    let inheritedDirectory = activeWindow.flatMap { $0.native.windowInheritsDirectory && $0.session?.herdrTerminal?.client === client ? $0.currentDirectory : nil }
    let directory = inheritedDirectory.map { URL(fileURLWithPath: $0) } ?? runtime.settings.workingDirectory
    let shellEnvironment = client.shellEnvironment(settings: runtime.settings)
    let connect = connectionWork(for: client, directory: directory)
    client.perform({ client -> ConnectionResult in
      var connected = try connect(client)
      if connected.snapshot.panes.contains(where: { !attached.contains($0.terminal_id) }) { return connected }
      connected.snapshot = try client.create(workspace: nil, name: "Default", directory: client.machine == nil ? directory.path : inheritedDirectory, environment: shellEnvironment)
      return connected
    }) { [weak self] result in
      guard let self else { return }
      self.muxOpening = false
      guard !self.terminating else { return }
      defer {
        if !self.pendingFiles.isEmpty {
          self.drainDockFiles()
        }
      }
      do {
        let connected = try result.get()
        let snapshot = self.applyConnection(connected, client: client)
        if snapshot.panes.isEmpty {
          self.createDefaultWorkspace(client, directory: directory, environment: shellEnvironment)
          return
        }
        let restored = self.reconcileWorkspace(snapshot, client: client)
        let attachedNamespaces = Set(self.windows.flatMap(\.namespaces).compactMap(\.id))
        let displaySnapshot = snapshot.excluding(terminals: self.retainedTerminalIDs)
        let available = restored.namespaces.filter { space in space.tabs.contains { tab in displaySnapshot.panes.contains { pane in tab.matches(pane) } } }.map(\.id).filter { !attachedNamespaces.contains($0) }
        let opened = try self.attachHerdrWindows(restored.windowGroups(available: available), snapshot: displaySnapshot, client: client, state: restored)
        self.connectionStatus[client.endpointID] = .connected
        self.restoreUnavailableTabs()
        for controller in opened {
          controller.persistenceReady = self.workspacePersistenceEnabled
          controller.persistedNamespaceIDs = Set(controller.namespaces.compactMap(\.id))
          self.scheduleWorkspaceSave(controller)
        }
        if let selected = opened.first(where: { $0.workspaceWindowID == restored.activeWindowID }) {
          selected.window?.makeKeyAndOrderFront(nil)
        }
        self.observeHerdr(client, snapshot: snapshot)
        self.muxError = nil
        // Run again once the windows are ordered front: becoming key can change the selection,
        // and this re-applies each window's saved selection (restoreWorkspaceState) after it.
        self.restoreUnavailableTabs()
        self.restoreConnections()
      } catch {
        self.muxError = error.localizedDescription
        self.connectionStatus[client.endpointID] = .failed(error.localizedDescription)
        self.restoreUnavailableTabs()
        self.restoreConnections()
        if self.windows.isEmpty { self.newLocalWindow() }
        self.showMuxError(error)
      }
    }
  }
  /// Attach one window per saved group with saves suppressed; on failure, close the windows already opened.
  private func attachHerdrWindows(_ groups: [WorkspaceState.Window], snapshot: HerdrClient.Snapshot, client: HerdrClient,
    state: WorkspaceState) throws -> [TerminalWindowController] {
    restoringWorkspace = true
    defer { restoringWorkspace = false }
    var opened: [TerminalWindowController] = []
    do {
      for group in groups { opened.append(try attachHerdrWindow(snapshot, client: client, presentation: group, state: state)) }
    } catch {
      for controller in opened { controller.closing = true; controller.window?.close() }
      throw error
    }
    return opened
  }
  /// The handling every connection result needs first: adopts terminals the server recreated and
  /// retries closes that were left pending. Returns the live snapshot without hidden terminals.
  func applyConnection(_ connected: ConnectionResult, client: HerdrClient) -> HerdrClient.Snapshot {
    adoptRecreation(connected, client: client)
    retryPendingClosures(client, snapshot: connected.snapshot)
    return connected.snapshot.excluding(terminals: hiddenTerminalIDs)
  }

  /// Reconciles the saved workspace with what this endpoint is running and keeps the result.
  func reconcileWorkspace(_ snapshot: HerdrClient.Snapshot, client: HerdrClient) -> WorkspaceState {
    let reconciled = (workspaceState ?? WorkspaceState()).reconciled(endpoint: client.endpointID, live: savedNamespaces(snapshot))
    workspaceState = reconciled
    return reconciled
  }

  /// A server with nothing to show gets a "Default" workspace, then the window opens again.
  private func createDefaultWorkspace(_ client: HerdrClient, directory: URL, environment: [String: String]) {
    muxOpening = true
    client.perform({ try $0.create(workspace: nil, name: "Default", directory: client.machine == nil ? directory.path : nil, environment: environment) }) { [weak self] result in
      guard let self else { return }; self.muxOpening = false
      switch result {
      case .success: self.openHerdrWindow(using: client)
      case .failure(let error): self.showMuxError(error); if self.windows.isEmpty { self.newLocalWindow() }
      }
    }
  }

  /// Gives each saved window group the terminals of its namespaces that no window shows yet, either
  /// by adding them to the group's open window or by opening one. Returns every terminal now attached.
  func attachSavedWindows(_ saved: WorkspaceState, snapshot: HerdrClient.Snapshot, client: HerdrClient) throws -> Set<String> {
    var attached = attachedTerminalIDs
    for group in saved.windows ?? [] {
      let tabs = Set(saved.namespaces.filter { group.namespaceIDs.contains($0.id) }.flatMap(\.tabs).map(\.id))
      let scoped = snapshot.excluding(terminals: attached.union(snapshot.panes.filter { !tabs.contains(localTabID($0)) }.map(\.terminal_id)))
      guard !scoped.panes.isEmpty else { continue }
      if let existing = windows.first(where: { $0.workspaceWindowID == group.id }) {
        try existing.addHerdrTerminals(scoped, excluding: [], restoring: true, client: client)
        var selection = saved; selection.selectedNamespaceID = group.selectedNamespaceID; selection.sidebar = group.sidebar
        existing.restoreWorkspaceState(selection)
        scheduleWorkspaceSave(existing)
      } else {
        let opened = try attachHerdrWindow(scoped, client: client, presentation: group, state: saved)
        opened.persistenceReady = workspacePersistenceEnabled
        scheduleWorkspaceSave(opened)
      }
      attached.formUnion(scoped.panes.map(\.terminal_id))
    }
    return attached
  }

  /// Terminals no saved window group claims go to the active herdr window, or to a new one.
  func attachRemaining(_ remaining: HerdrClient.Snapshot, saved: WorkspaceState, client: HerdrClient) throws {
    guard !remaining.panes.isEmpty else { return }
    if let destination = activeWindow, destination.session?.herdrTerminal != nil {
      try destination.addHerdrTerminals(remaining, excluding: [], client: client)
      scheduleWorkspaceSave(destination)
    } else {
      let spaces = saved.namespaces.filter { $0.tabs.contains { tab in remaining.panes.contains { pane in tab.matches(pane) } } }.map(\.id)
      let group = WorkspaceState.Window(id: UUID().uuidString, namespaceIDs: spaces, selectedNamespaceID: spaces.first, frame: nil, sidebar: nil)
      let opened = try attachHerdrWindow(remaining, client: client, presentation: group, state: saved)
      opened.persistenceReady = workspacePersistenceEnabled; scheduleWorkspaceSave(opened)
    }
  }

  func observeHerdr(_ client: HerdrClient, snapshot: HerdrClient.Snapshot) {
    connectionCoordinator.observe(client, snapshot: snapshot) { [weak self, weak client] result in
      guard let self, let client, !self.terminating else { return }
      switch result {
      case .success(let snapshot): self.synchronizeHerdr(snapshot, client: client)
      case .failure(let error): self.connectionFailed(client, error: error)
      }
    }
  }

  private func herdrTargets(_ client: HerdrClient) -> [TerminalWindowController] {
    windows.filter { $0.allPanes.contains { $0.herdrTerminal?.client === client } && !$0.closing }
  }

  func synchronizeHerdr(_ incoming: HerdrClient.Snapshot, client: HerdrClient) {
    guard client.isEnabled else { return }
    guard client.isCurrent(incoming) else { client.onWorkspaceEvent?(); return }
    let regainedConnection = connectionStatus[client.endpointID] != .connected
    connectionStatus[client.endpointID] = .connected
    retryPendingClosures(client, snapshot: incoming)
    let serverSnapshot = incoming.excluding(terminals: hiddenTerminalIDs)
    // Subscriptions must follow external pane changes even while presentation is busy.
    observeHerdr(client, snapshot: serverSnapshot)
    let targets = herdrTargets(client)
    // Agent status and notifications must not wait for sheets or busy windows.
    let agents = serverSnapshot.excluding(terminals: retainedTerminalIDs)
    for controller in targets { controller.workspaceView.updateAgents(agents) }
    if regainedConnection {
      for controller in targets { controller.workspaceView.refreshTabs() }
      connectionsWindow?.refresh()
    }
    applyHerdrSnapshot(incoming, client: client)
  }

  // Structural synchronization, deferred while presentation is busy. A deferred snapshot is
  // applied without the connection, agent and close-retry steps, which only suit a fresh snapshot.
  private func applyHerdrSnapshot(_ incoming: HerdrClient.Snapshot, client: HerdrClient) {
    // A deferred snapshot can predate a mutation whose result is already shown; a fresh one follows.
    guard client.isCurrent(incoming) else {
      deferredSnapshots.removeValue(forKey: client.endpointID)
      client.onWorkspaceEvent?()
      return
    }
    let serverSnapshot = incoming.excluding(terminals: hiddenTerminalIDs)
    let targets = herdrTargets(client)
    // Without a window showing this client there is nothing to synchronize or defer.
    guard !targets.isEmpty else { deferredSnapshots.removeValue(forKey: client.endpointID); return }
    guard !terminating, !muxOpening, !restoringWorkspace, !synchronizingWorkspace,
      targets.allSatisfy({ !$0.muxBusy && !$0.hasPendingMuxActions && $0.window?.attachedSheet == nil }) else {
      deferredSnapshots[client.endpointID] = incoming
      scheduleDeferredSnapshotDrain()
      return
    }
    deferredSnapshots.removeValue(forKey: client.endpointID)
    let visibleNamespaces = Set(windows.flatMap(\.namespaces).compactMap(\.id))
    let detached = Set((workspaceState?.namespaces ?? []).filter { !visibleNamespaces.contains($0.id) }.flatMap(\.tabs).map(\.id))
    let snapshot = serverSnapshot.excluding(terminals: retainedTerminalIDs.union(serverSnapshot.panes.filter { detached.contains(localTabID($0)) }.map(\.terminal_id)))
    let currentRecords = targets.flatMap(\.allPanes).filter { $0.herdrTerminal?.client === client }.compactMap { $0.herdrTerminal?.pane }
    let recordsByTerminal = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.terminal_id, $0) })
    let structureMatches = Set(currentRecords.map(\.terminal_id)) == Set(snapshot.panes.map(\.terminal_id))
      && currentRecords.allSatisfy { old in
        guard let new = recordsByTerminal[old.terminal_id] else { return false }
        return new.tab_id == old.tab_id && new.workspace_id == old.workspace_id
      }
    if var saved = workspaceState {
      saved = saved.reconciled(endpoint: client.endpointID, live: savedNamespaces(serverSnapshot))
      workspacePersistence.dirty = workspacePersistence.dirty || saved != workspaceState
      workspaceState = saved
    }
    if structureMatches {
      for controller in targets { controller.updateHerdrLabels(snapshot) }
      if workspacePersistence.dirty, let controller = targets.first { scheduleWorkspaceSave(controller) }
      return
    }
    synchronizingWorkspace = true
    restoringWorkspace = true
    defer { restoringWorkspace = false; synchronizingWorkspace = false }
    let oldPanes = targets.flatMap(\.allPanes).filter { $0.herdrTerminal?.client === client }
    var sessions = Dictionary(uniqueKeysWithValues: oldPanes.compactMap { pane in
      pane.herdrTerminal.map { ($0.pane.terminal_id, pane) }
    })
    var created: [TerminalSession] = []
    do {
      // Prepare before touching any existing window, so failures are atomic.
      for record in snapshot.panes where sessions[record.terminal_id] == nil {
        guard let runtime else { return }
        let pane = runtime.makeSession()
        pane.herdrTerminal = .init(client: client, pane: record)
        pane.currentDirectory = record.cwd
        pane.surfaceContext = GHOSTTY_SURFACE_CONTEXT_SPLIT
        created.append(pane)
        guard let view = pane.createView() else { throw ConfigurationError("Could not attach an external terminal.") }
        pane.chrome = TerminalChrome(view)
        sessions[record.terminal_id] = pane
      }
    } catch {
      created.forEach { $0.close() }
      NSLog("Workspace synchronization: %@", error.localizedDescription)
      return
    }
    let destination = targets.first { $0 === focusedWindow } ?? targets[0]
    let assigned = Set(windows.flatMap(\.namespaces).compactMap(\.id))
    let state = workspaceState ?? WorkspaceState()
    for controller in targets {
      let owned = Set(controller.namespaces.compactMap(\.id))
      let spaces = state.namespaces.filter { owned.contains($0.id) || (controller === destination && !assigned.contains($0.id)) }
      controller.reconcileHerdr(snapshot, spaces: spaces, sessions: sessions, client: client)
    }
    let liveIDs = Set(snapshot.panes.map(\.terminal_id))
    for pane in oldPanes where !liveIDs.contains(pane.herdrTerminal?.pane.terminal_id ?? "") { pane.close() }
    restoringWorkspace = false
    for controller in targets where !controller.closing { scheduleWorkspaceSave(controller) }
  }

  private func scheduleDeferredSnapshotDrain() {
    guard deferredSnapshotTimer == nil else { return }
    deferredSnapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.drainDeferredSnapshots()
    }
  }

  private func drainDeferredSnapshots() {
    // Each value is the newest snapshot for its endpoint; older work is obsolete.
    for (endpoint, snapshot) in deferredSnapshots {
      guard let client = client(for: endpoint), client.isEnabled else {
        deferredSnapshots.removeValue(forKey: endpoint)
        continue
      }
      // A newer failure supersedes the stale snapshot.
      guard connectionStatus[endpoint] == .connected else {
        deferredSnapshots.removeValue(forKey: endpoint)
        continue
      }
      applyHerdrSnapshot(snapshot, client: client)
    }
    if deferredSnapshots.isEmpty {
      deferredSnapshotTimer?.invalidate()
      deferredSnapshotTimer = nil
    }
  }

  func attachHerdrWindow(_ snapshot: HerdrClient.Snapshot, client: HerdrClient,
    presentation: WorkspaceState.Window, state: WorkspaceState) throws -> TerminalWindowController {
    guard let runtime, let first = snapshot.panes.first(where: { pane in state.namespaces.contains { presentation.namespaceIDs.contains($0.id) && $0.tabs.contains { $0.id == localTabID(pane) } } }) else {
      throw ConfigurationError("herdr returned no terminals to attach.")
    }
    let session = runtime.makeSession()
    if presentation.frame == nil, let source = activeWindow?.session, NativeSettings(config: source.config).windowInheritsFontSize, let surface = source.surface { session.initialFontSize = velokit_surface_font_size(surface) }
    session.herdrTerminal = .init(client: client, pane: first)
    let controller = TerminalWindowController(session: session, owner: self)
    controller.workspaceWindowID = presentation.id
    controller.activeNamespace.id = state.namespaces.first { $0.tabs.contains { $0.id == localTabID(first) } }?.id ?? first.workspace_id
    controller.activeNamespace.name = state.namespaces.first { $0.id == controller.activeNamespace.id }?.name ?? "Default"
    windows.append(controller)
    controller.activeTab.herdrID = localTabID(first)
    controller.openWindow(cascadingFrom: focusedWindow?.window)
    do {
      guard let window = controller.window else { throw ConfigurationError("Could not create terminal window.") }
      let includedTabs = Set(state.namespaces.filter { presentation.namespaceIDs.contains($0.id) }.flatMap(\.tabs).map(\.id))
      let excluded = Set(snapshot.panes.filter { !includedTabs.contains(localTabID($0)) }.map(\.terminal_id))
      try controller.addHerdrTerminals(snapshot, excluding: excluded, restoring: true)
      var selection = state
      selection.selectedNamespaceID = presentation.selectedNamespaceID
      selection.sidebar = presentation.sidebar
      controller.restoreWorkspaceState(selection)
      if let saved = presentation.frame {
        var frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
          frame.size.width = min(max(window.minSize.width, frame.width), bounds.width)
          frame.size.height = min(max(window.minSize.height, frame.height), bounds.height)
          frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
          frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
      }
      return controller
    } catch {
      controller.closing = true
      controller.window?.close()
      windows.removeAll { $0 === controller }
      session.close()
      throw error
    }
  }

}
