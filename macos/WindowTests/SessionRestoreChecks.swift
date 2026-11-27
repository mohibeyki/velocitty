// SPDX-License-Identifier: GPL-3.0
// The --session-restore check: standalone windows and herdr sessions that come back after a relaunch
// or a lost server.
import AppKit
import VeloKit
import VelocittyConfiguration

func runSessionRestoreCheck() throws {
  try withTemporaryDirectory("velocitty-restore") { directory in try checkStandaloneRestore(directory: directory) }
  try withIsolatedHerdr("velocitty-test") { directory, clients in
    try checkLostServerRecreation(directory: directory, client: clients[0])
  }
  print("Session restoration tests passed.")
}

/// Closes an owner's windows and waits until they are gone and its workspace writes have finished, so
/// a later launch does not see a late write from this one as an outside change.
private func closeAndWait(_ owner: AppDelegate) {
  for controller in Array(owner.windows) { controller.closing = true; controller.window?.close() }
  waitUntil("The windows did not close") { owner.windows.isEmpty }
  owner.flushWorkspaceSaveSynchronously()
}

/// Closes windows the way quitting does: their saved state is kept.
private func closeWindows(of owner: AppDelegate) {
  owner.terminating = true
  closeAndWait(owner)
}

private func posixPermissions(_ url: URL) -> Int {
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

/// A window's text as the engine holds it, for waiting on shell output.
private func output(of pane: TerminalSession) -> String { pane.recentOutput() ?? "" }

// MARK: Standalone windows

/// Launches of a standalone terminal that share one workspace file and one saved working directory.
private struct StandaloneRun {
  let stateURL: URL
  let work: URL

  func launch(restore: Bool = true) throws -> AppDelegate {
    let owner = AppDelegate(discoverHerdr: { nil })
    owner.workspaceStateURL = stateURL
    owner.runtime = try TerminalRuntime(settings: testSettings(restore ? "" : "[interface]\nrestore_session=false", saveState: "always"))
    app.delegate = owner
    return owner
  }
}

/// Standalone windows come back through AppKit's restoration state with their directory, and show
/// their previous output, dimmed and followed by a separator, above the new shell's prompt.
private func checkStandaloneRestore(directory: URL) throws {
  let work = directory.appendingPathComponent("work", isDirectory: true).resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
  let run = StandaloneRun(stateURL: directory.appendingPathComponent("workspace.json"), work: work)
  let store = ScrollbackStore(besideStateAt: run.stateURL)
  let (pane, encoded) = try saveStandaloneOutput(run, store: store)
  try verifyStandaloneRestored(run, previous: pane, encoded: encoded)
  try verifyClosingDiscardsOutput(run, store: store)
  try verifySettingOffRemovesOutput(run, store: store)
}

/// Prints enough output to overflow the saved lines, saves it and encodes the window's restoration
/// state, then quits the way the application does, which keeps the saved text.
private func saveStandaloneOutput(_ run: StandaloneRun, store: ScrollbackStore) throws -> (TerminalSession, Data) {
  let first = try run.launch()
  first.newLocalWindow(directory: run.work)
  let controller = first.windows[0], pane = controller.session!
  enterCommand("echo before-quit-marker; seq 1 3000", in: pane)
  waitUntil("The first terminal did not print", timeout: 8) { output(of: pane).contains("\n3000") }
  let encoder = NSKeyedArchiver(requiringSecureCoding: true)
  controller.window(controller.window!, willEncodeRestorableState: encoder)
  encoder.finishEncoding()
  first.saveScrollback(of: [pane], blocking: true)
  let saved = store.load(pane.standaloneScrollbackKey)?.text ?? ""
  precondition(saved.hasSuffix("3000") || saved.contains("\n3000\n"), "The last output must be saved")
  precondition(saved.split(separator: "\n").count <= SessionScrollback.maxLines, "Saved scrollback must be bounded")
  precondition(!saved.contains("before-quit-marker"), "Only the most recent lines are saved")
  precondition(posixPermissions(store.url(for: pane.standaloneScrollbackKey)) == 0o600, "Scrollback must be owner-only")
  precondition(posixPermissions(store.directory) == 0o700)
  closeWindows(of: first)
  return (pane, encoder.encodedData)
}

/// The restored window has its directory and its old output above a separator, before the new shell's output.
private func verifyStandaloneRestored(_ run: StandaloneRun, previous pane: TerminalSession, encoded: Data) throws {
  let second = try run.launch()
  var restored: NSWindow?
  let decoder = try NSKeyedUnarchiver(forReadingFrom: encoded)
  decoder.requiresSecureCoding = true
  TerminalWindowRestoration.restoreWindow(withIdentifier: TerminalWindowRestoration.identifier, state: decoder) { window, _ in restored = window }
  precondition(restored != nil && second.windows.count == 1, "A standalone window must be restored")
  let revived = second.windows[0].session!
  precondition(revived.standaloneScrollbackKey == pane.standaloneScrollbackKey)
  precondition(second.windows[0].currentDirectory == run.work.path || revived.initialDirectory?.path == run.work.path, "The working directory must be restored")
  waitUntil("Saved output must be shown", timeout: 8) { output(of: revived).contains("restored session") }
  enterCommand("echo after-restore-marker", in: revived)
  waitUntil("The new shell must run", timeout: 8) { output(of: revived).contains("\nafter-restore-marker") }
  let text = output(of: revived)
  let shown = text.range(of: "\n2999\n"), separator = text.range(of: "restored session"), fresh = text.range(of: "\nafter-restore-marker")
  precondition(shown != nil && separator != nil && fresh != nil && shown!.upperBound <= separator!.lowerBound && separator!.upperBound <= fresh!.lowerBound,
    "Restored output must precede the separator and the new shell's output")
  closeWindows(of: second)
}

/// A user closing a window discards its output.
private func verifyClosingDiscardsOutput(_ run: StandaloneRun, store: ScrollbackStore) throws {
  let third = try run.launch()
  third.newLocalWindow(directory: run.work)
  let closed = third.windows[0].session!
  third.saveScrollback(of: [closed], blocking: true)
  third.windows[0].closing = true; third.windows[0].window?.close()
  precondition(store.load(closed.standaloneScrollbackKey) == nil, "Closing a standalone window removes its scrollback")
}

/// Turning the restore setting off removes the saved output of every window, including ones quit with it kept.
private func verifySettingOffRemovesOutput(_ run: StandaloneRun, store: ScrollbackStore) throws {
  let fourth = try run.launch()
  fourth.newLocalWindow(directory: run.work)
  let kept = fourth.windows[0].session!
  enterCommand("echo kept-marker", in: kept)
  waitUntil("The terminal did not print", timeout: 8) { output(of: kept).contains("\nkept-marker") }
  fourth.saveScrollback(of: [kept], blocking: true)
  precondition(store.load(kept.standaloneScrollbackKey) != nil, "Quitting keeps the output")
  closeWindows(of: fourth)
  let disabled = try run.launch(restore: false)
  disabled.pruneScrollback()
  precondition((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path))?.isEmpty != false,
    "No scrollback remains when the setting is off")
}

// MARK: Lost herdr server

/// Launches of a herdr session whose server is stopped between them, as a reboot would. herdr restores
/// its own workspaces under their old IDs, so Velocitty must rebind to those; when the session is gone
/// altogether it must create the terminals itself.
private final class LostServerRun {
  let directory: URL
  let file: URL
  let store: ScrollbackStore
  let initial: HerdrClient
  let alpha: String
  let beta: String

  init(directory: URL, client: HerdrClient) throws {
    self.directory = directory
    initial = client
    file = directory.appendingPathComponent("workspace.json")
    store = ScrollbackStore(besideStateAt: file)
    for name in ["alpha", "beta"] { try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true) }
    func realPath(_ name: String) -> String { realpath(directory.appendingPathComponent(name).path, nil).map { String(cString: $0) } ?? name }
    alpha = realPath("alpha")
    beta = realPath("beta")
  }

  func launch(restore: Bool = true) throws -> AppDelegate {
    let owner = AppDelegate()
    owner.workspaceStateURL = file
    owner.runtime = try TerminalRuntime(settings: AppConfiguration.parse(Data(
      "[terminal]\nconfirm_close_surface=false\ntheme=''\nundo_timeout='1s'\n[interface]\nrestore_session=\(restore)\n".utf8)))
    owner.herdr = HerdrClient(executable: initial.executable, sessionName: initial.sessionName)
    app.delegate = owner
    return owner
  }

  func stopServer(deleteSession: Bool) throws {
    _ = try? initial.run(["server", "stop"])
    waitUntil("The herdr server did not stop", timeout: 8) { (try? initial.snapshot(timeout: 1)) == nil }
    if deleteSession { _ = try initial.run(["session", "delete", initial.sessionName]) }
  }

  /// Saves the owner's workspace and closes its windows, leaving the server as it is.
  func detach(_ owner: AppDelegate) {
    owner.scheduleWorkspaceSave(owner.windows[0]); owner.flushWorkspaceSaveSynchronously()
    closeAndWait(owner)
  }

  /// Waits for herdr to see the shell's directory, then lets the owner's pane records catch up.
  func waitForCwd(_ owner: AppDelegate, _ pane: TerminalSession, _ path: String) throws {
    let client = owner.herdr!, id = pane.herdrTerminal!.pane.terminal_id
    waitUntil("herdr did not report \(path)", timeout: 10) { (try? client.snapshot())?.panes.first { $0.terminal_id == id }?.cwd == path }
    owner.synchronizeHerdr(try client.snapshot(), client: client)
    precondition(pane.herdrTerminal?.pane.cwd == path)
  }

  /// The saved arrangement, checked against what a relaunch shows: same layout, selection, directories
  /// and previous output, in new terminals, with nothing added.
  func verifyRestored(_ owner: AppDelegate, previous: Set<String>, previousKey: String, via: String) throws -> TerminalWindowController {
    precondition(owner.windows.count == 1, "\(via): the saved window must be restored")
    let restored = owner.windows[0]
    let panes = restored.allPanes
    precondition(panes.count == 3, "\(via): every saved terminal must come back once, found \(panes.count)")
    let terminals = Set(panes.compactMap { $0.herdrTerminal?.pane.terminal_id })
    precondition(terminals.isDisjoint(with: previous), "\(via): terminals are new")
    precondition(restored.namespaces.count == 1 && restored.namespaces[0].tabs.map(\.panes.count) == [2, 1], "\(via): tabs must keep their panes")
    guard case .split(let direction, let ratio, _, _) = restored.namespaces[0].tabs[0].localLayout else { fatalError("\(via): the split layout was lost") }
    precondition(direction == "right" && abs(ratio - 0.3) < 0.01, "\(via): split ratio must survive: \(ratio)")
    precondition(restored.activeTab === restored.namespaces[0].tabs[0] && restored.session === restored.activeTab.panes[0], "\(via): the selection must survive")
    let client = owner.herdr!
    waitUntil("\(via): working directories must be restored", timeout: 15) {
      let cwds = Set(((try? client.snapshot())?.panes ?? []).compactMap(\.cwd))
      return cwds.isSuperset(of: [alpha, beta])
    }
    let live = try client.snapshot()
    precondition(live.panes.count == 3 && live.workspaces.count == 1, "\(via): nothing may be added: \(live.panes.map(\.pane_id))")
    let record = restored.session!.herdrTerminal!.pane
    waitUntil("\(via): the previous output must be printed in the new shell", timeout: 15) {
      guard let text = try? client.recentText(paneID: record.pane_id, lines: 200) else { return false }
      return text.contains("history-alpha") && text.contains("restored session")
    }
    precondition(store.load(previousKey) == nil && store.load(record.terminal_id)?.text.contains("history-alpha") == true,
      "\(via): scrollback must move to the new terminal")
    owner.scheduleWorkspaceSave(restored); owner.flushWorkspaceSaveSynchronously()
    let saved = try WorkspaceStateStore(url: file).load()
    precondition(Set(saved.namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }.map(\.terminalID)) == terminals, "\(via): the saved workspace must name the new terminals")
    return restored
  }
}

private func checkLostServerRecreation(directory: URL, client initial: HerdrClient) throws {
  let run = try LostServerRun(directory: directory, client: initial)
  let (first, window, alphaKey) = try arrangeSavedSession(run)
  var terminals = Set(window.allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })
  precondition(terminals.count == 3, "Expected three live terminals, found \(terminals.count)")
  let running = try initial.connectReportingStart(directory: directory)
  precondition(!running.started, "A running server is not a new one")

  // Reboot 1: herdr restores its workspaces with new terminals, and Velocitty rebinds to them.
  run.detach(first)
  try run.stopServer(deleteSession: false)
  let second = try run.launch()
  second.newWindow(); waitForMux(second, timeout: 30)
  let afterRestore = try run.verifyRestored(second, previous: terminals, previousKey: alphaKey, via: "restored session")
  terminals = Set(afterRestore.allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })
  let secondKey = afterRestore.activeTab.panes[0].herdrTerminal!.pane.terminal_id
  second.saveScrollback(of: afterRestore.allPanes, blocking: true)

  // Reboot 2: the session itself is gone, so Velocitty creates the terminals.
  run.detach(second)
  try run.stopServer(deleteSession: true)
  let third = try run.launch()
  third.newWindow(); waitForMux(third, timeout: 30)
  let afterLoss = try run.verifyRestored(third, previous: terminals, previousKey: secondKey, via: "lost session")
  let thirdKey = afterLoss.activeTab.panes[0].herdrTerminal!.pane.terminal_id
  third.saveScrollback(of: afterLoss.allPanes, blocking: true)
  let survivors = Set(afterLoss.allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })

  run.detach(third)
  let fourth = try run.launch()
  fourth.newWindow(); waitForMux(fourth)
  verifyRunningServerIsNotLost(fourth, survivors: survivors)
  verifyClosedScrollbackIsRemoved(run, fourth, keeping: thirdKey)

  run.detach(fourth)
  try run.stopServer(deleteSession: false)
  try verifySettingOffRemovesEverything(run)
}

/// Arranges one tab split in two (30/70) and a second tab, each shell in its own directory with some
/// history, saves the text and returns the owner, its window and the first terminal's key.
private func arrangeSavedSession(_ run: LostServerRun) throws -> (AppDelegate, TerminalWindowController, String) {
  let first = try run.launch()
  first.newWindow(); waitForMux(first)
  let window = first.windows.last!
  let alphaPane = window.session!
  enterCommand("cd \(ShellInput.quote(run.alpha)); echo history-alpha", in: alphaPane)
  try run.waitForCwd(first, alphaPane, run.alpha)
  window.splitPane("right"); waitForMux(first, window)
  let betaPane = window.session!
  precondition(betaPane !== alphaPane)
  enterCommand("cd \(ShellInput.quote(run.beta)); echo history-beta", in: betaPane)
  try run.waitForCwd(first, betaPane, run.beta)
  window.setSplitRatio(tabID: window.activeTab.herdrID!, path: [], ratio: 0.3)
  window.newTab(); waitForMux(first, window)
  window.selectTab(alphaPane)
  waitUntil("History must be readable from herdr", timeout: 10) {
    [alphaPane, betaPane].allSatisfy { pane in
      (try? run.initial.recentText(paneID: pane.herdrTerminal!.pane.pane_id, lines: 50))?.contains("history-") == true
    }
  }
  first.saveScrollback(of: window.allPanes, blocking: true)
  let alphaKey = alphaPane.herdrTerminal!.pane.terminal_id
  precondition(run.store.load(alphaKey)?.text.contains("history-alpha") == true, "herdr scrollback must be saved")
  precondition(posixPermissions(run.store.url(for: alphaKey)) == 0o600)
  return (first, window, alphaKey)
}

/// A server that is still running is not lost: nothing is rebound or created.
private func verifyRunningServerIsNotLost(_ owner: AppDelegate, survivors: Set<String>) {
  precondition(Set(owner.windows.flatMap(\.allPanes).compactMap { $0.herdrTerminal?.pane.terminal_id }) == survivors)
}

/// An explicit close keeps the text through the undo window, then removes it.
private func verifyClosedScrollbackIsRemoved(_ run: LostServerRun, _ owner: AppDelegate, keeping otherKey: String) {
  let store = run.store
  let closing = owner.windows[0]
  let singleTab = closing.namespaces[0].tabs[1]
  let singleKey = singleTab.panes[0].herdrTerminal!.pane.terminal_id
  owner.saveScrollback(of: closing.allPanes, blocking: true)
  precondition(store.load(singleKey) != nil, "The single pane's text was not saved")
  closing.closeTab(singleTab.panes[0], confirm: false); waitForMux(owner, closing)
  precondition(store.load(singleKey) != nil, "The undo window must keep the text")
  waitUntil("A closed terminal's scrollback must be removed after the undo window", timeout: 8) { store.load(singleKey) == nil }
  precondition(store.load(otherKey) != nil, "Other terminals keep their text")
}

/// With the setting off, nothing is rebound or created, and saved text is removed.
private func verifySettingOffRemovesEverything(_ run: LostServerRun) throws {
  let disabled = try run.launch(restore: false)
  disabled.newWindow(); waitForMux(disabled, timeout: 30)
  precondition(disabled.windows.flatMap(\.namespaces).flatMap(\.tabs).allSatisfy { $0.panes.count == 1 }, "The saved arrangement is not restored when the setting is off")
  disabled.pruneScrollback()
  disabled.saveScrollback(of: disabled.windows.flatMap(\.allPanes), blocking: true)
  precondition((try? FileManager.default.contentsOfDirectory(atPath: run.store.directory.path))?.isEmpty != false, "No scrollback remains when the setting is off")
  for controller in Array(disabled.windows) { controller.closing = true; controller.window?.close() }
}
