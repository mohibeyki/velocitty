// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

extension AppDelegate {
  func loadWorkspaceState(for client: HerdrClient) {
    guard !workspaceLoadAttempted, client.sessionName == "velocitty" || workspaceStateURL != nil else { return }
    workspaceLoadAttempted = true
    let store = workspaceStateURL.map { WorkspaceStateStore(url: $0) } ?? WorkspaceStateStore()
    do {
      let loaded = try store.loadWithRevision()
      workspaceState = loaded.state
      workspacePersistence.revision = loaded.revision
      closeHistory.pending = Set(workspaceState?.pendingTerminalClosures ?? [])
      workspacePersistence.store = store
    } catch WorkspaceStateError.unsupportedFutureVersion(let version) {
      workspaceState = nil
      workspacePersistence.store = nil
      workspaceCompatibilityWarning = "This workspace was saved by a newer Velocitty (workspace version \(version)). It will be left unchanged and workspace saving is disabled. Upgrade Velocitty to restore and edit this workspace."
      NSLog("Workspace persistence disabled for unsupported future version: %d", version)
    } catch {
      do {
        try store.preserveDamagedState()
        workspaceState = WorkspaceState()
        workspacePersistence.revision = try? Data(contentsOf: store.url)
        workspacePersistence.store = store
        NSLog("Started a fresh workspace after preserving damaged state: %@", error.localizedDescription)
      } catch { NSLog("Could not preserve damaged workspace; persistence disabled: %@", error.localizedDescription) }
    }
    registerMissingConnections()
  }

  func scheduleWorkspaceSave(_ controller: TerminalWindowController) {
    guard !restoringWorkspace, controller.persistenceReady, workspacePersistenceEnabled, var state = workspaceState else { return }
    let current = controller.namespaces.compactMap { namespace in
      savedNamespace(for: namespace, old: state.namespaces.first { $0.id == namespace.id })
    }
    state.update(current, replacing: controller.persistedNamespaceIDs)
    controller.persistedNamespaceIDs = Set(current.map(\.id))
    let presentation = windowPresentation(for: controller, namespaces: current, state: state)
    state.assign(window: presentation)
    state.version = WorkspaceState.currentVersion
    if focusedWindow == nil || focusedWindow === controller {
      state.activeWindowID = controller.workspaceWindowID
      state.selectedNamespaceID = controller.activeNamespace.id
      state.sidebar = controller.workspaceView.savedSidebarState
    }
    guard state != workspaceState || workspacePersistence.dirty else { return }
    workspacePersistence.dirty = true
    workspaceState = state
    workspacePersistence.timer?.invalidate()
    workspacePersistence.timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
      self?.flushWorkspaceSave()
    }
  }

  /// The saved form of one attached namespace. Individual unavailable tabs from its previous
  /// saved form are kept until their endpoint confirms deletion.
  private func savedNamespace(for namespace: TerminalNamespace, old: WorkspaceState.Namespace?) -> WorkspaceState.Namespace? {
    guard let id = namespace.id else { return nil }
    var space = WorkspaceState.Namespace(id: id, tabs: namespace.tabs.compactMap { tab in
      guard let id = tab.herdrID else { return nil }
      var saved = WorkspaceState.Tab(id: id, selectedPaneID: tab.selected.herdrTerminal?.pane.pane_id, zoomed: tab.zoomed)
      saved.title = tab.title
      tab.ensureLayout(); saved.layout = tab.localLayout
      // herdr tracks each shell's directory; the host sees none of its changes, so it only fills a gap.
      saved.panes = tab.panes.compactMap { pane in pane.herdrTerminal.map { $0.pane.saved(cwd: $0.pane.cwd == nil ? pane.currentDirectory : nil) } }
      return saved
    }, selectedTabID: namespace.selected.herdrID)
    space.name = namespace.name
    guard let old else { return space }
    let attached = Set(windows.flatMap(\.namespaces).flatMap(\.tabs).compactMap(\.herdrID))
    space.tabs += old.tabs.compactMap { tab in
      let unavailable = tab.panes?.contains { !clientIsAvailable($0.connectionID) } ?? !clientIsAvailable(tab.connectionID)
      guard !attached.contains(tab.id), unavailable else { return nil }
      var saved = tab
      if let panes = saved.panes {
        saved.panes = panes.filter { !hiddenTerminalIDs.contains($0.terminalID) }
        if saved.panes?.isEmpty == true { return nil }
        saved.layout = saved.layout?.retaining(Set(saved.panes?.map(\.terminalID) ?? []))
      }
      return saved
    }
    if let selected = old.selectedTabID, space.tabs.contains(where: { $0.id == selected }), !attached.contains(selected) { space.selectedTabID = selected }
    return space
  }

  /// The saved presentation of one window: its namespaces (plus offline ones it still owns),
  /// frame, sidebar and comparison, keeping a saved comparison whose companion is unavailable.
  private func windowPresentation(for controller: TerminalWindowController, namespaces current: [WorkspaceState.Namespace],
    state: WorkspaceState) -> WorkspaceState.Window {
    let frame = controller.normalFrame ?? controller.window?.frame
    let attachedIDs = Set(windows.flatMap(\.namespaces).compactMap(\.id))
    let offlineIDs = (state.windows?.first { $0.id == controller.workspaceWindowID }?.namespaceIDs ?? []).filter { id in state.namespaces.contains { $0.id == id } && !attachedIDs.contains(id) && !controller.persistedNamespaceIDs.contains(id) }
    var presentation = WorkspaceState.Window(id: controller.workspaceWindowID,
      namespaceIDs: current.map(\.id) + offlineIDs, selectedNamespaceID: controller.activeNamespace.id,
      frame: frame.map { .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
      sidebar: controller.workspaceView.savedSidebarState)
    if controller.presentedTabs.count == 2 {
      presentation.primaryTabID = controller.primaryTab?.herdrID
      presentation.companionTabID = controller.companionTab?.herdrID
      presentation.companionRatio = controller.companionRatio
      presentation.focusedTerminalID = controller.session?.herdrTerminal?.pane.terminal_id
    }
    if !controller.comparisonDismissed, presentation.companionTabID == nil,
      let old = state.windows?.first(where: { $0.id == presentation.id }),
      let companion = old.companionTabID,
      state.namespaces.flatMap(\.tabs).contains(where: { $0.id == companion }),
      !windows.flatMap(\.namespaces).flatMap(\.tabs).contains(where: { $0.herdrID == companion }) {
      presentation.primaryTabID = old.primaryTabID
      presentation.companionTabID = old.companionTabID
      presentation.companionRatio = old.companionRatio
      presentation.focusedTerminalID = old.focusedTerminalID
    }
    return presentation
  }

  func flushWorkspaceSave() {
    if terminating { flushWorkspaceSaveSynchronously(); return }
    workspacePersistence.flush { [weak self] result in
      if case .failure(let error) = result { self?.workspaceSaveFailed(error) }
    }
  }

  func flushWorkspaceSaveSynchronously() {
    do { try workspacePersistence.flushSynchronously() }
    catch { workspaceSaveFailed(error) }
  }

  func workspaceSaveFailed(_ error: Error) {
    switch error {
    case WorkspaceStateError.conflictingUpdate:
      workspacePersistenceFailed("Another Velocitty instance or process changed the workspace on disk. This instance did not overwrite it, and workspace saving has been disabled. Restart Velocitty to load the latest workspace.")
    case WorkspaceStateError.unsupportedFutureVersion(let version):
      workspacePersistenceFailed("The workspace was replaced by a newer Velocitty (workspace version \(version)). It will be left unchanged and workspace saving is disabled.")
    default: NSLog("Could not save workspace: %@", error.localizedDescription)
    }
  }

  private func workspacePersistenceFailed(_ message: String) {
    workspacePersistence.store = nil
    NSLog("Workspace persistence disabled: %@", message)
    guard !terminating else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.terminating else { return }
      configurationAlert(ConfigurationError(message)).runModal()
    }
  }
}
