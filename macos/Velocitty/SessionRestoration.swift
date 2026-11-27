// SPDX-License-Identifier: GPL-3.0
import Foundation
import VeloKit
import VelocittyConfiguration

// Scrollback is the part of a session that outlives a terminal's process. Standalone terminals
// read it from the engine and show it again through the engine; herdr terminals keep their
// own screen, so it is read with `herdr pane read` and printed by the new shell instead.

extension TerminalSession {
  var scrollbackKey: String { herdrTerminal?.pane.terminal_id ?? standaloneScrollbackKey }

  /// The terminal's recent primary-screen text, from the engine. A herdr attachment shows an
  /// alternate screen, so its text comes from herdr instead.
  func recentOutput(lines: Int = SessionScrollback.maxLines) -> String? {
    guard herdrTerminal == nil, let surface else { return nil }
    var history = velokit_history_s()
    guard velokit_surface_read_history(surface, lines, &history), let text = history.text else { return nil }
    defer { velokit_free_history(&history) }
    return String(decoding: UnsafeRawBufferPointer(start: text, count: history.text_len), as: UTF8.self)
  }

  /// Shows saved output as if the new shell had printed it, before the shell's own output.
  func showRestoredOutput() {
    guard let surface, let output = restoredOutput else { return }
    restoredOutput = nil
    output.withCString { velokit_surface_write_output(surface, $0, UInt(output.utf8.count)) }
  }
}

/// Runs scrollback reads and writes off the main thread, one round at a time.
final class ScrollbackCapture {
  static let interval: TimeInterval = 60
  var timer: Timer?
  private let queue = DispatchQueue(label: "velocitty.scrollback", qos: .utility)
  private var running = false

  /// A periodic round is skipped while the previous one is still reading.
  func run(_ jobs: [() -> Void], periodic: Bool, blocking: Bool) {
    guard !jobs.isEmpty, !(periodic && running) else { return }
    if blocking {
      // Quit waits briefly for slow herdr reads rather than losing the text.
      let group = DispatchGroup()
      for job in jobs { DispatchQueue.global(qos: .userInitiated).async(group: group, execute: job) }
      _ = group.wait(timeout: .now() + 2.5)
      return
    }
    running = true
    queue.async { [weak self] in
      jobs.forEach { $0() }
      DispatchQueue.main.async { self?.running = false }
    }
  }
}

extension AppDelegate {
  var restoreSessionEnabled: Bool { runtime?.settings.interface["restore_session"] != "false" }

  private var scrollbackLocation: ScrollbackStore { ScrollbackStore(besideStateAt: workspaceStateURL ?? WorkspaceStateStore().url) }

  /// Where a terminal's scrollback is kept, or nil when it is not saved. Standalone terminals follow
  /// window restoration; herdr terminals follow workspace persistence. Remote servers keep their own
  /// terminals and cannot be recreated from here.
  func scrollbackStore(for pane: TerminalSession) -> ScrollbackStore? {
    guard restoreSessionEnabled else { return nil }
    if let terminal = pane.herdrTerminal { return workspacePersistenceEnabled && terminal.client.machine == nil ? scrollbackLocation : nil }
    return native.windowSaveState == "never" ? nil : scrollbackLocation
  }

  func startScrollbackCapture() {
    pruneScrollback()
    scrollbackCapture.timer = Timer.scheduledTimer(withTimeInterval: ScrollbackCapture.interval, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.saveScrollback(of: self.windows.flatMap(\.allPanes), periodic: true)
    }
  }

  /// Everything is removed when the setting is off; otherwise only files of terminals no longer saved.
  func pruneScrollback() {
    guard restoreSessionEnabled else { scrollbackLocation.prune(keeping: [], olderThan: 0); return }
    guard let state = workspaceState else { return }
    let saved = state.namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }.map(\.terminalID)
    scrollbackLocation.prune(keeping: Set(saved).subtracting(state.pendingTerminalClosures ?? []))
  }

  /// Reads each pane's text now, on the main thread where its surface lives, and writes it elsewhere.
  func saveScrollback(of panes: [TerminalSession], periodic: Bool = false, blocking: Bool = false) {
    scrollbackCapture.run(panes.compactMap(scrollbackJob), periodic: periodic, blocking: blocking)
  }

  private func scrollbackJob(for pane: TerminalSession) -> (() -> Void)? {
    guard let store = scrollbackStore(for: pane) else { return nil }
    let key = pane.scrollbackKey
    if let terminal = pane.herdrTerminal {
      let client = terminal.client, paneID = terminal.pane.pane_id
      return { if let text = try? client.recentText(paneID: paneID, lines: SessionScrollback.maxLines) { _ = try? store.save(text, key: key) } }
    }
    guard let text = pane.recentOutput() else { return nil }
    return { _ = try? store.save(text, key: key) }
  }

  func discardScrollback(of panes: [TerminalSession]) { discardScrollback(keys: panes.map(\.scrollbackKey)) }
  func discardScrollback(keys: [String]) { scrollbackLocation.remove(keys) }

  /// A closing window detaches herdr terminals, whose text is kept for a later restart, and ends
  /// standalone terminals, whose text goes with them unless the application is quitting.
  func windowPanesClosing(_ panes: [TerminalSession]) {
    guard !terminating else { return }
    saveScrollback(of: panes.filter { $0.herdrTerminal != nil })
    discardScrollback(of: panes.filter { $0.herdrTerminal == nil })
  }
}

// MARK: - Bringing back terminals a restarted herdr server lost

struct ConnectionResult {
  var snapshot: HerdrClient.Snapshot
  /// New terminals keyed by the saved terminal each replaces.
  var replacements: [String: WorkspaceState.Pane] = [:]
}

extension HerdrClient.Pane {
  func saved(cwd override: String? = nil) -> WorkspaceState.Pane {
    var result = WorkspaceState.Pane(id: pane_id, terminalID: terminal_id, workspaceID: workspace_id, cwd: override ?? cwd)
    result.tabID = tab_id
    return result
  }
}

extension AppDelegate {
  /// Work for a client's queue: connect, and when that started a new server, bring back the saved
  /// terminals it lost. A server that is merely unreachable or disabled is never started, so its
  /// saved terminals stay as unavailable tabs.
  func connectionWork(for client: HerdrClient, directory: URL) -> (HerdrClient) throws -> ConnectionResult {
    let saved = restoreSessionEnabled && client.machine == nil ? workspaceState : nil
    let hidden = hiddenTerminalIDs
    let store = scrollbackLocation
    let environment = runtime.map { client.shellEnvironment(settings: $0.settings) } ?? [:]
    return { client in
      let (snapshot, started) = try client.connectReportingStart(directory: directory)
      guard started, let saved else { return ConnectionResult(snapshot: snapshot) }
      let endpoint = client.endpointID
      // herdr restores its own workspaces under their old IDs; only what it did not restore is created.
      let live = snapshot.panes.map { $0.saved() }
      let rebound = saved.reboundTerminals(endpoint: endpoint, live: live, excluding: hidden)
      let lost = saved.lostTerminals(endpoint: endpoint, live: Set(live.map(\.terminalID)), excluding: hidden.union(rebound.keys))
      guard !rebound.isEmpty || !lost.isEmpty else { return ConnectionResult(snapshot: snapshot) }
      let savedDirectories = Dictionary(uniqueKeysWithValues: saved.namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }.map { ($0.terminalID, $0.cwd) })
      for (oldID, new) in rebound {
        client.restoreShell(of: oldID, in: snapshot.panes.first { $0.terminal_id == new.terminalID }!, directory: savedDirectories[oldID] ?? nil, scrollback: store)
      }
      let replacements = rebound.merging(client.recreate(lost, environment: environment, scrollback: store)) { first, _ in first }
      return ConnectionResult(snapshot: try client.snapshot(), replacements: replacements)
    }
  }

  /// Saves the workspace under the new terminal IDs before anything else refers to them.
  func adoptRecreation(_ replacements: [String: WorkspaceState.Pane]) {
    guard !replacements.isEmpty, let state = workspaceState else { return }
    workspaceState = state.recreated(replacements: replacements)
    workspacePersistence.dirty = true
    flushWorkspaceSaveSynchronously()
  }
}

extension HerdrClient {
  /// Creates a terminal for each lost one, at its working directory, with its namespace's panes in
  /// one new workspace. A failure skips that terminal.
  func recreate(_ lost: [LostNamespace], environment: [String: String], scrollback: ScrollbackStore) -> [String: WorkspaceState.Pane] {
    var created: [String: WorkspaceState.Pane] = [:]
    for space in lost {
      var workspace: String?
      for saved in space.panes {
        do {
          let pane = try createPane(workspace: workspace, name: space.name ?? "Default", directory: Self.existingDirectory(saved.cwd), environment: environment)
          workspace = pane.workspace_id
          created[saved.terminalID] = pane.saved(cwd: saved.cwd)
          restoreShell(of: saved.terminalID, in: pane, directory: nil, scrollback: scrollback)
        } catch { NSLog("Could not recreate terminal %@: %@", saved.terminalID, error.localizedDescription) }
      }
    }
    return created
  }

  private static func existingDirectory(_ path: String?) -> String? {
    var isDirectory: ObjCBool = false
    return path.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
  }

  /// Puts a new shell where the old one was: in its saved `directory` when it started elsewhere, and
  /// showing its saved output. The new shell prints the file, so the text lands above the first prompt
  /// like any earlier output; the typed command is cleared away with the screen and the file removes
  /// itself. A pane running an agent is left alone, since typing would reach the agent.
  func restoreShell(of oldID: String, in pane: Pane, directory: String?, scrollback: ScrollbackStore) {
    guard pane.agent == nil else { return }
    var commands: [String] = []
    if let directory = Self.existingDirectory(directory), directory != pane.cwd { commands.append("cd " + ShellInput.quote(directory) + " 2>/dev/null") }
    do {
      if let saved = scrollback.load(oldID) {
        try scrollback.save(saved.text, key: pane.terminal_id)
        scrollback.remove([oldID])
        let file = ShellInput.quote(try scrollback.writeTemporary(SessionScrollback.display(saved.text, savedAt: saved.savedAt), name: pane.terminal_id).path)
        commands += ["clear", "cat " + file, "rm -f " + file]
      } else if !commands.isEmpty { commands.append("clear") }
      if !commands.isEmpty { try runCommand(" " + commands.joined(separator: "; "), paneID: pane.pane_id) }
    } catch { NSLog("Could not restore the shell of %@: %@", oldID, error.localizedDescription) }
  }
}
