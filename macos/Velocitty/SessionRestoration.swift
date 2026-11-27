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

/// Runs scrollback reads and writes off the main thread, one round at a time. Used from the main thread.
final class ScrollbackCapture {
  static let interval: TimeInterval = 60
  private let queue = DispatchQueue(label: "velocitty.scrollback", qos: .utility)
  /// Rounds queued or running; a periodic round is skipped while any is.
  private var pending = 0
  private var timer: Timer?

  func start(_ tick: @escaping () -> Void) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in tick() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func enqueue(_ jobs: [() -> Void], periodic: Bool) {
    guard !jobs.isEmpty, !(periodic && pending > 0) else { return }
    pending += 1
    queue.async { [weak self] in
      jobs.forEach { $0() }
      DispatchQueue.main.async { self?.pending -= 1 }
    }
  }

  /// Quit waits briefly for slow herdr reads rather than losing the text.
  func runBlocking(_ jobs: [() -> Void], timeout: TimeInterval) {
    guard !jobs.isEmpty else { return }
    let group = DispatchGroup()
    for job in jobs { DispatchQueue.global(qos: .userInitiated).async(group: group, execute: job) }
    _ = group.wait(timeout: .now() + timeout)
  }

  /// Removes files now and again after any write already queued, which would otherwise bring them back.
  func discard(_ keys: [String], from store: ScrollbackStore) {
    store.remove(keys)
    queue.async { store.remove(keys) }
  }
}

/// What the settings allow for scrollback, read once per round rather than per pane.
struct ScrollbackPolicy {
  let store: ScrollbackStore
  let restoreSession: Bool
  let persistsWorkspace: Bool
  let savesWindows: Bool

  /// Where a terminal's scrollback is kept, or nil when it is not saved. Standalone terminals follow
  /// window restoration; herdr terminals follow workspace persistence. Remote servers keep their own
  /// terminals and cannot be recreated from here.
  func store(for pane: TerminalSession) -> ScrollbackStore? {
    guard restoreSession else { return nil }
    if let terminal = pane.herdrTerminal { return persistsWorkspace && terminal.client.machine == nil ? store : nil }
    return savesWindows ? store : nil
  }
}

extension AppDelegate {
  var restoreSessionEnabled: Bool { runtime?.settings.interface["restore_session"] != "false" }

  var scrollbackPolicy: ScrollbackPolicy {
    ScrollbackPolicy(store: ScrollbackStore(besideStateAt: workspaceStateURL ?? WorkspaceStateStore().url),
      restoreSession: restoreSessionEnabled, persistsWorkspace: workspacePersistenceEnabled, savesWindows: native.windowSaveState != "never")
  }

  /// Whether terminals a restarted server lost are brought back.
  func restoresTerminals(of client: HerdrClient) -> Bool { restoreSessionEnabled && client.machine == nil }

  /// Where a terminal's scrollback is kept, or nil when it is not saved.
  func scrollbackStore(for pane: TerminalSession) -> ScrollbackStore? { scrollbackPolicy.store(for: pane) }

  func startScrollbackCapture() {
    pruneScrollback()
    scrollbackCapture.start { [weak self] in
      guard let self else { return }
      let policy = self.scrollbackPolicy
      self.scrollbackCapture.enqueue(self.windows.flatMap(\.allPanes).compactMap { self.scrollbackJob(for: $0, policy: policy) }, periodic: true)
    }
  }

  /// Everything is removed when the setting is off; otherwise only files of terminals no longer saved.
  func pruneScrollback() {
    let policy = scrollbackPolicy
    guard policy.restoreSession else { policy.store.prune(keeping: [], olderThan: 0); return }
    guard let state = workspaceState else { return }
    let saved = state.namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }.map(\.terminalID)
    policy.store.prune(keeping: Set(saved).subtracting(state.pendingTerminalClosures ?? []))
  }

  /// Reads each pane's text now, on the main thread where its surface lives, and writes it elsewhere.
  func saveScrollback(of panes: [TerminalSession], blocking: Bool = false) {
    let policy = scrollbackPolicy
    let jobs = panes.compactMap { scrollbackJob(for: $0, policy: policy) }
    if blocking { scrollbackCapture.runBlocking(jobs, timeout: 2.5) } else { scrollbackCapture.enqueue(jobs, periodic: false) }
  }

  private func scrollbackJob(for pane: TerminalSession, policy: ScrollbackPolicy) -> (() -> Void)? {
    guard let store = policy.store(for: pane) else { return nil }
    let key = pane.scrollbackKey
    if let terminal = pane.herdrTerminal {
      let client = terminal.client, paneID = terminal.pane.pane_id
      return { if let text = try? client.recentText(paneID: paneID, lines: SessionScrollback.maxLines) { _ = try? store.save(text, key: key) } }
    }
    guard let text = pane.recentOutput() else { return nil }
    return { _ = try? store.save(text, key: key) }
  }

  func discardScrollback(keys: [String]) { scrollbackCapture.discard(keys, from: scrollbackPolicy.store) }

  /// A closing window detaches herdr terminals, whose text is kept for a later restart, and ends
  /// standalone terminals, whose text goes with them unless the application is quitting.
  func windowPanesClosing(_ panes: [TerminalSession]) {
    guard !terminating else { return }
    saveScrollback(of: panes.filter { $0.herdrTerminal != nil })
    discardScrollback(keys: panes.filter { $0.herdrTerminal == nil }.map(\.scrollbackKey))
  }
}

// MARK: - Bringing back terminals a restarted herdr server lost

struct ConnectionResult {
  var snapshot: HerdrClient.Snapshot
  /// New terminals keyed by the saved terminal each replaces.
  var replacements: [String: WorkspaceState.Pane] = [:]
  /// New shells to show their old output, once their terminals are attached.
  var shells: [HerdrClient.ShellRestore] = []
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
    let saved = restoresTerminals(of: client) ? workspaceState : nil
    let hidden = hiddenTerminalIDs
    let store = scrollbackPolicy.store
    let environment = runtime.map { client.shellEnvironment(settings: $0.settings) } ?? [:]
    return { client in
      let (snapshot, started) = try client.connectReportingStart(directory: directory)
      guard started, let saved else { return ConnectionResult(snapshot: snapshot) }
      return try client.restoreAfterServerStart(snapshot, saved: saved, hidden: hidden, environment: environment, scrollback: store)
    }
  }

  /// Saves the workspace under the new terminal IDs before anything else refers to them, and starts
  /// restoring the new shells.
  func adoptRecreation(_ connected: ConnectionResult, client: HerdrClient) {
    client.restoreShells(connected.shells)
    guard !connected.replacements.isEmpty, let state = workspaceState else { return }
    workspaceState = state.recreated(replacements: connected.replacements)
    workspacePersistence.dirty = true
    flushWorkspaceSaveSynchronously()
    // The saved workspace now names the new terminals, so the old text is no longer needed.
    discardScrollback(keys: connected.shells.compactMap(\.replacedID))
  }

  /// For a result that will not be adopted: the old text stays with the saved workspace, which still
  /// names the old terminals, and what was prepared for the new ones is removed.
  func abandonRecreation(_ connected: ConnectionResult) {
    HerdrClient.abandon(connected.shells) { discardScrollback(keys: $0) }
  }
}

extension HerdrClient {
  /// A new shell that should show the output of the one it replaces.
  struct ShellRestore {
    let pane: Pane
    /// Where the old shell was, when the new one starts elsewhere.
    let directory: String?
    /// The saved output as a shell prints it, removed by whoever prints it.
    let file: URL?
    /// The terminal's size when it was prepared; it changes once a window attaches and sizes it.
    let rows: Int?
    /// The terminal whose saved text was copied for this one; removed once the workspace refers to the new one.
    let replacedID: String?
  }

  /// Gives the terminals a new server lost or renumbered their shells back. The snapshot is taken
  /// again only when terminals were created, since rebinding changes nothing structurally.
  func restoreAfterServerStart(_ snapshot: Snapshot, saved: WorkspaceState, hidden: Set<String>, environment: [String: String], scrollback: ScrollbackStore) throws -> ConnectionResult {
    // herdr restores its own workspaces under their old IDs; only what it did not restore is created.
    let live = snapshot.panes.map { $0.saved() }
    let rebound = saved.reboundTerminals(endpoint: endpointID, live: live, excluding: hidden)
    let lost = saved.lostTerminals(endpoint: endpointID, live: Set(live.map(\.terminalID)), excluding: hidden.union(rebound.keys))
    guard !rebound.isEmpty || !lost.isEmpty else { return ConnectionResult(snapshot: snapshot) }
    let directories = saved.savedDirectories()
    var shells: [ShellRestore] = []
    for (oldID, new) in rebound {
      guard let pane = snapshot.panes.first(where: { $0.terminal_id == new.terminalID }) else { continue }
      shells.append(prepareShell(of: oldID, in: pane, directory: directories[oldID], scrollback: scrollback))
    }
    let created = recreate(lost, environment: environment, scrollback: scrollback)
    shells += created.shells
    do {
      return ConnectionResult(snapshot: created.panes.isEmpty ? snapshot : try self.snapshot(),
        replacements: rebound.merging(created.panes) { first, _ in first }, shells: shells)
    } catch {
      Self.abandon(shells) { scrollback.remove($0) }
      throw error
    }
  }

  /// Creates a terminal for each lost one, at its working directory, with its namespace's panes in
  /// one new workspace. A failure skips that terminal.
  func recreate(_ lost: [LostNamespace], environment: [String: String], scrollback: ScrollbackStore) -> (panes: [String: WorkspaceState.Pane], shells: [ShellRestore]) {
    var created: [String: WorkspaceState.Pane] = [:], shells: [ShellRestore] = []
    for space in lost {
      var workspace: String?
      for saved in space.panes {
        do {
          let pane = try createPane(workspace: workspace, name: space.name ?? "Default", directory: Self.existingDirectory(saved.cwd), environment: environment)
          workspace = pane.workspace_id
          created[saved.terminalID] = pane.saved(cwd: saved.cwd)
          shells.append(prepareShell(of: saved.terminalID, in: pane, directory: nil, scrollback: scrollback))
        } catch { NSLog("Could not recreate terminal %@: %@", saved.terminalID, error.localizedDescription) }
      }
    }
    return (created, shells)
  }

  /// Removes what prepareShell wrote, when the shells will never be shown. `remove` deletes the
  /// copied text of the new terminals.
  static func abandon(_ shells: [ShellRestore], remove: ([String]) -> Void) {
    for shell in shells {
      if let file = shell.file { try? FileManager.default.removeItem(at: file) }
      if shell.replacedID != nil { remove([shell.pane.terminal_id]) }
    }
  }

  private static func existingDirectory(_ path: String?) -> String? {
    var isDirectory: ObjCBool = false
    return path.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
  }

  /// Copies the old terminal's saved output to the new terminal and writes what its shell will print.
  /// Nothing is typed yet: the shell is only worth talking to once a window has attached and sized it.
  private func prepareShell(of oldID: String, in pane: Pane, directory: String?, scrollback: ScrollbackStore) -> ShellRestore {
    var file: URL?, replaced: String?
    if pane.agent == nil, let saved = scrollback.load(oldID) {
      do {
        try scrollback.save(saved.text, key: pane.terminal_id)
        if oldID != pane.terminal_id { replaced = oldID }
        file = try scrollback.writeTemporary(SessionScrollback.display(saved.text, savedAt: saved.savedAt), name: pane.terminal_id)
      } catch { NSLog("Could not prepare the saved output of %@: %@", oldID, error.localizedDescription) }
    }
    let target = Self.existingDirectory(directory).flatMap { $0 == pane.cwd ? nil : $0 }
    return ShellRestore(pane: pane, directory: pane.agent == nil ? target : nil, file: file, rows: presentation(paneID: pane.pane_id)?.rows, replacedID: replaced)
  }

  /// A terminal's size and how much has been drawn in it, which change as it is attached and as its
  /// shell answers each resize.
  fileprivate struct Presentation: Equatable {
    let rows: Int?
    let revision: Int?
  }

  fileprivate func presentation(paneID: String) -> Presentation? {
    guard let pane = (try? request(["pane", "get", paneID], timeout: 2, mutating: false))?["pane"] as? [String: Any] else { return nil }
    return Presentation(rows: (pane["scroll"] as? [String: Any])?["viewport_rows"] as? Int, revision: pane["revision"] as? Int)
  }

  /// Each restoration can wait seconds for its terminal to settle, so only a few run at once; after a
  /// reboot there can be many.
  private static let shellRestoration: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "velocitty.shell-restoration"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 4
    return queue
  }()

  func restoreShells(_ shells: [ShellRestore]) {
    for shell in shells where shell.directory != nil || shell.file != nil {
      Self.shellRestoration.addOperation { self.restoreShell(shell) }
    }
  }

  /// Puts a new shell where the old one was: in its saved directory, and showing its saved output.
  /// A small `sh` prints the file above the first prompt like any earlier output and removes it; only
  /// that one portable command is typed into the shell, whatever the shell. A pane running an agent
  /// is left alone, since typing would reach the agent.
  private func restoreShell(_ shell: ShellRestore) {
    do {
      try waitUntilSized(shell)
      if let directory = shell.directory { try runCommandWhenReady(" cd " + ShellInput.quote(directory), paneID: shell.pane.pane_id) }
      if let file = shell.file {
        try runCommandWhenReady(" sh -c 'clear; cat \"$1\"; rm -f \"$1\"' sh " + ShellInput.quote(file.path), paneID: shell.pane.pane_id)
      }
    } catch {
      if let file = shell.file { try? FileManager.default.removeItem(at: file) }
      NSLog("Could not restore the shell of %@: %@", shell.pane.terminal_id, error.localizedDescription)
    }
  }

  /// A shell repaints its prompt when its terminal is resized, over the lines above it, so output
  /// printed while a window is still attaching and sizing the terminal can be erased. herdr offers no
  /// signal for that, so the terminal is taken to be settled once its size has changed from the one it
  /// started with and neither it nor what is drawn in it changes between two looks. A terminal whose
  /// size never changes, or that is never attached, is restored after a bounded wait.
  private func waitUntilSized(_ shell: ShellRestore, timeout: TimeInterval = 3) throws {
    guard let rows = shell.rows else { return }
    let deadline = Date(timeIntervalSinceNow: timeout)
    var previous: Presentation?
    while Date() < deadline {
      let current = presentation(paneID: shell.pane.pane_id)
      if let current, current.rows != rows, current == previous { return }
      previous = current
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  /// A pane of a server that has only just started may not accept input at once.
  private func runCommandWhenReady(_ command: String, paneID: String, attempts: Int = 3) throws {
    for attempt in 1...attempts {
      do { return try runCommand(command, paneID: paneID) } catch {
        if attempt == attempts { throw error }
        Thread.sleep(forTimeInterval: 0.2)
      }
    }
  }
}
