// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VelocittyConfiguration

// A close keeps the original surfaces alive for the configured undo window.
// Only explicit terminal closes become durable backend-destruction intentions.
final class ClosedTerminals {
  struct Slot {
    let pane: TerminalSession
    let namespace: TerminalNamespace
    let namespaceIndex: Int
    let tab: TerminalTab
    let tabIndex: Int
    let paneIndex: Int
    let layout: PaneLayout?
  }
  weak var controller: TerminalWindowController?
  var slots: [Slot]
  let destroy: Bool
  let frame: NSRect?
  let windowID: String
  var applied = true
  var checking = false
  var timer: Timer?
  var expiry: Date?
  var panes: [TerminalSession] { slots.map(\.pane) }
  var terminalIDs: [String] { panes.compactMap { $0.herdrTerminal?.pane.terminal_id } }
  init(_ panes: [TerminalSession], controller: TerminalWindowController, destroy: Bool) {
    self.controller = controller; self.destroy = destroy
    frame = controller.window?.frame; windowID = controller.workspaceWindowID
    slots = controller.namespaces.enumerated().flatMap { ni, namespace in
      namespace.tabs.enumerated().flatMap { ti, tab in
        tab.panes.enumerated().compactMap { pi, pane in
          panes.contains(where: { $0 === pane }) ? Slot(pane: pane, namespace: namespace, namespaceIndex: ni, tab: tab, tabIndex: ti, paneIndex: pi, layout: tab.localLayout) : nil
        }
      }
    }
  }
}

final class WorkspacePersistence {
  var store: WorkspaceStateStore?
  var state: WorkspaceState?
  var revision: Data?
  var dirty = false
  var timer: Timer?
  private let queue = DispatchQueue(label: "velocitty.workspace-persistence", qos: .utility)
  private var writing = false
  private var completedRevision: Data?
  private var completedError: Error?
  deinit { timer?.invalidate() }

  func flush(completion: @escaping (Result<Void, Error>) -> Void) {
    timer?.invalidate(); timer = nil
    guard dirty, !writing, let state, let store else { return }
    writing = true
    dirty = false
    let expectedRevision = revision
    queue.async {
      do {
        let saved = try store.save(state, expectedRevision: expectedRevision)
        self.completedRevision = saved
      } catch {
        self.completedError = error
      }
      DispatchQueue.main.async {
        self.writing = false
        // Whichever path takes the error first reports it, so it is never reported twice.
        if let error = self.takeCompletion() {
          self.dirty = true
          completion(.failure(error))
          return
        }
        completion(.success(()))
        if self.dirty { self.flush(completion: completion) }
      }
    }
  }

  func flushSynchronously() throws {
    timer?.invalidate(); timer = nil
    try queue.sync {
      if let completedRevision { revision = completedRevision }
      if let completedError {
        self.completedError = nil
        dirty = true
        throw completedError
      }
      guard dirty, let state, let store else { return }
      revision = try store.save(state, expectedRevision: revision)
      completedRevision = revision
      dirty = false
    }
  }

  // Adopts the newest saved revision and takes any unreported write error.
  private func takeCompletion() -> Error? {
    queue.sync {
      if let completedRevision { revision = completedRevision }
      defer { completedError = nil }
      return completedError
    }
  }
}

final class ConnectionCoordinator {
  var clients: [String: HerdrClient] = [:]
  var restored = false
  var loaded = false
  var timers: [String: Timer] = [:]
  var refreshing: Set<String> = []
  private var pending: Set<String> = []
  deinit { timers.values.forEach { $0.invalidate() } }

  func observe(_ client: HerdrClient, snapshot: HerdrClient.Snapshot, receive: @escaping (Result<HerdrClient.Snapshot, Error>) -> Void) {
    client.onWorkspaceEvent = { [weak self, weak client] in
      guard let self, let client, client.isEnabled else { return }
      self.timers[client.endpointID]?.invalidate()
      self.timers[client.endpointID] = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self, weak client] _ in
        guard let client else { return }
        self?.refresh(client, receive: receive)
      }
    }
    client.observeEvents(panes: snapshot.panes)
  }

  private func refresh(_ client: HerdrClient, receive: @escaping (Result<HerdrClient.Snapshot, Error>) -> Void) {
    guard client.isEnabled else { return }
    guard refreshing.insert(client.endpointID).inserted else { pending.insert(client.endpointID); return }
    client.perform({ try $0.snapshot(timeout: 1) }) { [weak self, weak client] result in
      guard let self, let client else { return }
      self.refreshing.remove(client.endpointID)
      receive(result)
      if self.pending.remove(client.endpointID) != nil { self.refresh(client, receive: receive) }
    }
  }
}

final class CloseHistory {
  var closed: [ClosedTerminals] = []
  var redo: [ClosedTerminals] = []
  var pending: Set<String> = []
  var ending: Set<String> = []
  deinit { (closed + redo).forEach { $0.timer?.invalidate() } }
}
