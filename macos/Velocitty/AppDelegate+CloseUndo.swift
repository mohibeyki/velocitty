// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

extension AppDelegate {
  func endTerminal(_ terminal: HerdrClient.Terminal) {
    closeHistory.pending.insert(terminal.pane.terminal_id)
    discardScrollback(keys: [terminal.pane.terminal_id])
    guard persistCloseIntent(), terminal.client.isEnabled else { return }
    terminal.client.perform({ try $0.snapshot() }) { [weak self] result in
      if case .success(let snapshot) = result { self?.retryPendingClosures(terminal.client, snapshot: snapshot) }
    }
  }

  func deferClose(_ panes: [TerminalSession], in controller: TerminalWindowController, destroy: Bool) -> Bool {
    let timeout = controller.native.undoTimeout
    guard timeout > 0, !panes.isEmpty, !terminating, !controller.muxBusy else { return false }
    let operation = ClosedTerminals(panes, controller: controller, destroy: destroy)
    guard !operation.slots.isEmpty else { return false }
    closeHistory.redo.forEach { $0.timer?.invalidate() }; closeHistory.redo = []
    closeHistory.closed.append(operation)
    operation.expiry = Date(timeIntervalSinceNow: timeout)
    scheduleExpiry(operation, after: timeout)
    persistCloseIntent()
    controller.hideClosed(operation)
    refreshCloseUndoBanner()
    return true
  }

  private func refreshCloseUndoBanner() {
    windows.forEach { $0.workspaceView.hideCloseUndo() }
    guard let operation = closeHistory.closed.last, operation.applied, !operation.checking,
      let controller = operation.controller, !controller.closing, controller.window != nil,
      let expiry = operation.expiry else { return }
    controller.workspaceView.showCloseUndo(count: operation.panes.count, expires: expiry,
      onUndo: { [weak self] in self?.undoClose() },
      onEnd: { [weak self] in self?.endLatestClose() })
  }

  private func endLatestClose() {
    guard let operation = closeHistory.closed.last, operation.applied, !operation.checking else { return }
    expireClose(operation)
  }

  // Writes the close intent before any backend terminal is destroyed, so a crash cannot leave
  // a destroyed terminal in the saved workspace. Returns false when the write failed.
  @discardableResult
  func persistCloseIntent() -> Bool {
    // With persistence disabled (never enabled, or turned off after a conflict) there is no saved
    // workspace to protect, and waiting would leak backend terminals, so report success consistently.
    guard workspacePersistenceEnabled, var state = workspaceState else { return true }
    state.pendingTerminalClosures = hiddenTerminalIDs.sorted()
    if state != workspaceState { workspaceState = state; workspacePersistence.dirty = true }
    // Always synchronize: an asynchronous write may already hold this change (dirty is then false),
    // and the synchronous flush waits for it and surfaces its error.
    do { try workspacePersistence.flushSynchronously() } catch { workspaceSaveFailed(error) }
    return !workspacePersistenceEnabled || !workspacePersistence.dirty
  }

  func flushClosesBeforeQuit() -> Bool {
    let clients = uniqueByEndpoint([herdr].compactMap { $0 } + Array(connectionCoordinator.clients.values) + closeHistory.closed.flatMap(\.panes).compactMap { $0.herdrTerminal?.client })
    closeHistory.pending.formUnion(hiddenTerminalIDs)
    for operation in closeHistory.closed { operation.timer?.invalidate(); operation.applied = false }
    // Leave terminals pending when the intent could not be saved; they are ended on a later run.
    guard persistCloseIntent(), !closeHistory.pending.isEmpty else { return false }
    // Pending terminals no known client can reach stay recorded for a later run; waiting would only time out.
    guard !clients.isEmpty else { return false }
    var remaining = clients.count
    var replied = false
    let finish = { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: finish)
    for client in clients.values {
      let ids = closeHistory.pending.filter(client.owns)
      client.perform({ client -> Set<String> in
        let deadline = Date(timeIntervalSinceNow: 4)
        let snapshot = try client.snapshot(timeout: 1)
        var completed: Set<String> = []
        for id in ids where Date() < deadline {
          guard let pane = snapshot.panes.first(where: { $0.terminal_id == id }) else { completed.insert(id); continue }
          if (try? client.request(["pane", "close", pane.pane_id], timeout: 1)) != nil { completed.insert(id) }
        }
        return completed
      }) { [weak self] result in
        guard let self, !replied else { return }
        if case .success(let completed) = result { self.closeHistory.pending.subtract(completed); self.persistCloseIntent() }
        remaining -= 1
        if remaining == 0 { finish() }
      }
    }
    return true
  }

  func expireClose(_ operation: ClosedTerminals) {
    operation.timer?.invalidate()
    closeHistory.closed.removeAll { $0 === operation }
    closeHistory.redo.removeAll { $0 === operation }
    operation.expiry = nil
    refreshCloseUndoBanner()
    guard operation.applied else { return }
    if operation.destroy { closeHistory.pending.formUnion(operation.terminalIDs) }
    discardScrollback(keys: operation.panes.filter { operation.destroy || $0.herdrTerminal == nil }.map(\.scrollbackKey))
    operation.panes.forEach { $0.close() }
    guard persistCloseIntent() else { return }
    let clients = uniqueByEndpoint(operation.panes.compactMap { $0.herdrTerminal?.client })
    for client in clients.values {
      client.perform({ try $0.snapshot() }) { [weak self] result in
        if case .success(let snapshot) = result { self?.retryPendingClosures(client, snapshot: snapshot) }
      }
    }
  }

  func retryPendingClosures(_ client: HerdrClient, snapshot: HerdrClient.Snapshot) {
    let ids = closeHistory.pending.filter(client.owns)
    guard !ids.isEmpty, !closeHistory.ending.contains(client.endpointID), !terminating, persistCloseIntent() else { return }
    closeHistory.ending.insert(client.endpointID)
    client.perform({ client -> Set<String> in
      var completed: Set<String> = []
      for id in ids {
        guard let pane = snapshot.panes.first(where: { $0.terminal_id == id }) else { completed.insert(id); continue }
        // Resolve the current pane ID from the terminal identity, including after swaps.
        do { _ = try client.request(["pane", "close", pane.pane_id]); completed.insert(id) }
        catch { NSLog("Pending terminal close: %@", error.localizedDescription) }
      }
      return completed
    }) { [weak self] result in
      guard let self else { return }
      self.closeHistory.ending.remove(client.endpointID)
      if case .success(let completed) = result { self.closeHistory.pending.subtract(completed); self.persistCloseIntent() }
    }
  }

  @objc func undoClose() {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, let undo = editor.undoManager, undo.canUndo { undo.undo(); return }
    guard let operation = closeHistory.closed.last, operation.applied, !operation.checking, !terminating else { return }
    operation.checking = true
    operation.timer?.invalidate()
    operation.expiry = nil
    refreshCloseUndoBanner()
    let clients = Array(uniqueByEndpoint(operation.panes.compactMap { $0.herdrTerminal?.client }).values)
    validateUndo(operation, clients: clients)
  }

  private func validateUndo(_ operation: ClosedTerminals, clients: [HerdrClient]) {
    guard let client = clients.first else { restoreUndo(operation); return }
    if !client.isEnabled { validateUndo(operation, clients: Array(clients.dropFirst())); return }
    client.perform({ try $0.snapshot() }) { [weak self, weak operation] result in
      guard let self, let operation, !self.terminating else { return }
      switch result {
      case .success(let snapshot):
        let live = Set(snapshot.panes.map(\.terminal_id))
        operation.slots.removeAll { slot in
          guard let terminal = slot.pane.herdrTerminal, terminal.client === client, !live.contains(terminal.pane.terminal_id) else { return false }
          slot.pane.close(); return true
        }
        operation.slots = operation.slots.map { slot in
          guard let terminal = slot.pane.herdrTerminal, terminal.client === client,
            let record = snapshot.panes.first(where: { $0.terminal_id == terminal.pane.terminal_id }) else { return slot }
          slot.pane.herdrTerminal = .init(client: client, pane: record)
          return slot
        }
        self.validateUndo(operation, clients: Array(clients.dropFirst()))
      case .failure(let error):
        operation.checking = false
        self.showMuxError(error)
        operation.expiry = Date(timeIntervalSinceNow: max(0.01, self.native.undoTimeout))
        self.scheduleExpiry(operation, after: max(0.01, self.native.undoTimeout))
        self.refreshCloseUndoBanner()
      }
    }
  }

  private func restoreUndo(_ operation: ClosedTerminals) {
    operation.checking = false
    operation.applied = false
    closeHistory.closed.removeAll { $0 === operation }
    operation.expiry = nil
    refreshCloseUndoBanner()
    if operation.slots.isEmpty { persistCloseIntent(); return }
    closeHistory.redo.append(operation)
    persistCloseIntent()
    let controller: TerminalWindowController
    if let existing = operation.controller, !existing.closing, existing.window != nil { controller = existing }
    else {
      guard let first = operation.panes.first else { return }
      controller = TerminalWindowController(session: first, owner: self)
      controller.workspaceWindowID = operation.windowID
      windows.append(controller)
      operation.controller = controller
    }
    controller.restoreClosed(operation)
    if controller.window == nil {
      controller.openWindow()
      if let frame = operation.frame { controller.window?.setFrame(frame, display: true) }
    }
    controller.persistenceReady = workspacePersistenceEnabled
    if let first = operation.panes.first { controller.selectTab(first) }
    controller.workspaceView.present()
    controller.window?.makeKeyAndOrderFront(nil)
    scheduleWorkspaceSave(controller)
    scheduleExpiry(operation, after: max(0.01, controller.native.undoTimeout))
  }

  @objc func redoClose() {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, let undo = editor.undoManager, undo.canRedo { undo.redo(); return }
    guard let operation = closeHistory.redo.last, let controller = operation.controller, !controller.closing else { return }
    if !operation.destroy { controller.window?.performClose(nil); return }
    operation.timer?.invalidate()
    let panes = operation.panes.filter { pane in controller.allPanes.contains { $0 === pane } }
    if !deferClose(panes, in: controller, destroy: true) {
      closeHistory.redo.removeAll { $0 === operation }
      for pane in panes { controller.closePane(pane, confirm: false) }
    }
  }
}
