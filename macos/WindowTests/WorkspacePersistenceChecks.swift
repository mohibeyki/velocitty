// SPDX-License-Identifier: GPL-3.0
// The --workspace-persistence check: a real herdr session driven through successive app launches.
import AppKit
import VeloKit
import VelocittyConfiguration

func runWorkspacePersistenceCheck() throws {
  try withIsolatedHerdr("velocitty-test") { directory, clients in
    try checkWorkspacePersistence(directory: directory, client: clients[0])
  }
  print("Workspace persistence tests passed.")
}

/// One herdr session and workspace file, opened by successive app launches. Each launch has its own
/// client, as a real one would: a client has a single event callback, which an earlier owner's late
/// refresh would otherwise take back from the later one.
private final class PersistenceRun {
  let directory: URL
  let file: URL
  let settings: AppConfiguration
  private let initialClient: HerdrClient
  private(set) var client: HerdrClient
  private var launches = 0

  init(directory: URL, client: HerdrClient) throws {
    self.directory = directory
    file = directory.appendingPathComponent("workspace.json")
    settings = try AppConfiguration.parse(Data("[terminal]\nconfirm_close_surface=false\ntheme=''\n".utf8))
    initialClient = client
    self.client = client
  }

  func launch() throws -> AppDelegate {
    if launches > 0 { client = HerdrClient(executable: initialClient.executable, sessionName: initialClient.sessionName) }
    launches += 1
    let owner = AppDelegate()
    owner.workspaceStateURL = file
    owner.runtime = try TerminalRuntime(settings: settings)
    owner.herdr = client
    return owner
  }

  func markerExists(_ marker: URL) -> Bool { FileManager.default.fileExists(atPath: marker.path) }
}

/// What the first launch arranged and saved, for the launches after it to find again.
private struct ArrangedWorkspace {
  let splitTabID: String
  let selectedPane: String
  let tabOrder: [String]
  let localName: String
  let selectedNamespace: String
}

private func checkWorkspacePersistence(directory: URL, client initialClient: HerdrClient) throws {
  let run = try PersistenceRun(directory: directory, client: initialClient)
  let first = try run.launch()
  first.newWindow(); waitForMux(first)
  let window = first.windows.last!
  try verifyShellIntegration(window, run: run)
  try verifyAttachmentRecovery(window, run: run)
  try verifyQueuedTabsKeepHerdrFocus(first, window, run: run)
  let arranged = try arrangeWorkspace(first, window, run: run)
  // A fresh owner loads the file, rather than reusing the in-memory state.
  let second = try run.launch()
  second.newWindow(); waitForMux(second)
  let restored = second.windows.last!
  verifyRestoredArrangement(restored, arranged)
  try verifyExternalChanges(second, restored, arranged, run: run)
  let (extraID, extraNamespace) = try detachSecondWindow(second, restored, run: run)
  let third = try run.launch()
  third.newWindow(); waitForMux(third)
  let (sourceWindow, extraRestored, detachedID) = try verifyMoves(third, extraID: extraID, extraNamespace: extraNamespace)
  try verifySearchAndDrop(third, sourceWindow: sourceWindow, extraRestored: extraRestored, directory: directory)
  try verifyShellExitClosesTab(third, extraRestored: extraRestored, detachedID: detachedID, run: run)
}

/// Waits until the shell in a herdr pane has drawn a prompt, which is after it loaded its integration.
private func waitForShellPrompt(_ pane: TerminalSession, timeout: TimeInterval = 10) {
  let client = pane.herdrTerminal!.client, paneID = pane.herdrTerminal!.pane.pane_id
  waitUntil("The shell did not draw a prompt", timeout: timeout) {
    ((try? client.recentText(paneID: paneID, lines: 50)) ?? "").contains { !$0.isWhitespace }
  }
}

private func verifyShellIntegration(_ window: TerminalWindowController, run: PersistenceRun) throws {
  let integrationMarker = run.directory.appendingPathComponent("integration")
  waitForShellPrompt(window.session!)
  let integrationCommand = "(( $+_ghostty_state )) && printf ok > " + ShellInput.quote(integrationMarker.path)
  enterCommand(integrationCommand, in: window.session!)
  if !pollUntil(timeout: 5, { run.markerExists(integrationMarker) }), let output = window.session?.view?.accessibilityValue() as? String {
    FileHandle.standardError.write(Data(output.utf8))
  }
  precondition(run.markerExists(integrationMarker), "New herdr shells must load integration")
  let running = try run.client.hasRunningTask(paneID: window.session!.herdrTerminal!.pane.pane_id)
  precondition(running == false, "An idle shell should not prompt to close")
}

/// A lost attachment reattaches to the same shell, with a usable view and clipboard.
private func verifyAttachmentRecovery(_ window: TerminalWindowController, run: PersistenceRun) throws {
  let recoveredPane = window.session!
  let terminalID = recoveredPane.herdrTerminal!.pane.terminal_id
  recoveredPane.attachmentExited()
  recoveredPane.attachmentExited()
  waitUntil("The attachment did not recover", timeout: 8) { !recoveredPane.recovering }
  precondition(window.session === recoveredPane && recoveredPane.herdrTerminal!.pane.terminal_id == terminalID)
  // The reconnect reuses the view, whose clipboard was cancelled with the old surface.
  var clipboardReply: Bool?
  recoveredPane.view!.clipboard.enqueue(title: "After reconnect", message: "Test") { allow, _ in clipboardReply = allow }
  precondition(clipboardReply == nil, "A reconnected terminal must not auto-deny clipboard requests")
  waitUntil("A reconnected terminal must present clipboard requests") { recoveredPane.view!.clipboard.confirmation != nil }
  recoveredPane.view!.clipboard.confirmation!.buttons[1].performClick(nil)
  waitUntil("The clipboard request was not answered") { clipboardReply != nil }
  precondition(clipboardReply == false && recoveredPane.view!.clipboard.confirmation == nil)
  let recoveryMarker = run.directory.appendingPathComponent("recovered")
  enterCommand("printf ok > " + ShellInput.quote(recoveryMarker.path), in: recoveredPane)
  waitUntil("Recovered attachment must accept input in the same shell", timeout: 5) { run.markerExists(recoveryMarker) }
}

/// Tab actions made while the mux is busy queue up, and selecting tabs is local to Velocitty.
private func verifyQueuedTabsKeepHerdrFocus(_ first: AppDelegate, _ window: TerminalWindowController, run: PersistenceRun) throws {
  window.newTab()
  window.newTab()
  waitForMux(first, window)
  precondition(window.tabs.count == 3, "Busy mux actions must queue instead of disappearing")
  let beforeSelection = try run.client.snapshot().workspaces.map(\.active_tab_id)
  window.selectTab(window.tabs[0])
  window.selectTab(window.tabs[2])
  waitForMux(first, window)
  let afterSelection = try run.client.snapshot().workspaces.map(\.active_tab_id)
  precondition(afterSelection == beforeSelection, "Velocitty navigation must not change herdr focus")
}

/// Splits, zooms, reorders and renames, then saves the window and closes it.
private func arrangeWorkspace(_ first: AppDelegate, _ window: TerminalWindowController, run: PersistenceRun) throws -> ArrangedWorkspace {
  let client = run.client
  window.session?.view?.performSurfaceAction("increase_font_size:2")
  let inheritedFont = velokit_surface_font_size(window.session!.surface!)
  // Split through the terminal's own binding action, as a keybinding would.
  let splitPane = window.session!
  precondition("new_split:right".withCString { velokit_surface_binding_action(splitPane.surface!, $0, 15) })
  waitForMux(first, window)
  precondition(window.session !== splitPane && window.activeTab.panes.count == 2)
  precondition(abs(velokit_surface_font_size(window.session!.surface!) - inheritedFont) < 0.01, "Split must inherit the current font size")
  let splitTabID = window.activeTab.herdrID!
  window.setSplitRatio(tabID: splitTabID, path: [], ratio: 0.3); waitForMux(first, window)
  guard case .split(_, let resizedRatio, _, _) = window.activeTab.localLayout else { fatalError("Missing local tree") }
  precondition(abs(resizedRatio - 0.3) < 0.01)
  window.equalizePanes(); waitForMux(first, window)
  guard case .split(_, let equalRatio, _, _) = window.activeTab.localLayout else { fatalError("Missing local tree") }
  precondition(abs(equalRatio - 0.5) < 0.01)
  let originalPane = window.session!
  window.splitPane("left"); waitForMux(first, window)
  window.workspaceView.layoutSubtreeIfNeeded()
  precondition(window.session!.chrome!.frame.midX < originalPane.chrome!.frame.midX, "Left split must appear before the original pane")
  window.selectTab(originalPane)
  let selectedPane = originalPane.herdrTerminal!.pane.pane_id
  window.togglePaneZoom()
  precondition(window.activeTab.zoomed && window.session!.herdrTerminal!.pane.pane_id == selectedPane)
  window.newTab(); waitForMux(first, window)
  window.moveTab(-1)
  let order = window.tabs.map { $0.herdrID! }
  window.selectTab(window.tabs.first { $0.herdrID == splitTabID }!)
  // A backend rename must not replace the local space name.
  let localName = window.activeNamespace.name
  try client.rename(workspace: window.session!.herdrTerminal!.pane.workspace_id, name: "Agents", subtitle: "Local tasks")
  window.newNamespace(); waitForMux(first, window)
  let selectedNamespace = window.activeNamespace.id!
  precondition(window.namespaces.count == 2 && window.namespaces[0].tabs.map { $0.herdrID! } == order,
    "Window structure changed without a local action: \(window.namespaces.map { $0.tabs.map(\.herdrID) }), expected \(order)")
  window.workspaceView.restoreSidebarState(.init(width: 276, compact: true))
  window.workspaceView.layoutSubtreeIfNeeded()
  first.scheduleWorkspaceSave(window)
  first.flushWorkspaceSaveSynchronously()
  let saved = try WorkspaceStateStore(url: run.file).load()
  precondition(saved.selectedNamespaceID == selectedNamespace)
  precondition(saved.namespaces.first?.tabs.map(\.id) == order, "The saved tab order must match the window")
  window.window?.performClose(nil)
  waitUntil("The arranged window did not close") { first.windows.isEmpty }
  first.flushWorkspaceSaveSynchronously() // Finishes any write the close started before another launch loads the file.
  return ArrangedWorkspace(splitTabID: splitTabID, selectedPane: selectedPane, tabOrder: order, localName: localName, selectedNamespace: selectedNamespace)
}

/// The relaunched window shows what was saved: selection, tab order, local names, zoom and sidebar.
private func verifyRestoredArrangement(_ restored: TerminalWindowController, _ arranged: ArrangedWorkspace) {
  restored.workspaceView.layoutSubtreeIfNeeded()
  precondition(restored.activeNamespace.id == arranged.selectedNamespace)
  precondition(restored.namespaces[0].tabs.map { $0.herdrID! } == arranged.tabOrder)
  precondition(restored.namespaces[0].name == arranged.localName, "Backend names must not overwrite local space names")
  let split = restored.namespaces[0].tabs.first { $0.herdrID == arranged.splitTabID }!
  precondition(split.selected.herdrTerminal!.pane.pane_id == arranged.selectedPane)
  precondition(split.zoomed, "Local pane zoom must survive relaunch")
  precondition(restored.workspaceView.savedSidebarState == .init(width: 276, compact: true))
}

/// External changes attach exactly once, through the event stream, without importing backend focus.
private func verifyExternalChanges(_ second: AppDelegate, _ restored: TerminalWindowController, _ arranged: ArrangedWorkspace,
  run: PersistenceRun) throws {
  let client = run.client
  let localSelection = restored.session!
  waitUntil("Event subscription must be acknowledged before changing the workspace") { client.eventsConnected }
  let eventsBefore = client.workspaceEventCount
  let external = try client.create(workspace: arranged.selectedNamespace, name: "External", directory: run.directory.path)
  let oldTerminalIDs = Set(restored.allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })
  let added = external.panes.first { !oldTerminalIDs.contains($0.terminal_id) }!
  let beforeRollback = restored.allPanes.count
  let invalid = HerdrClient.Snapshot(workspaces: external.workspaces, tabs: external.tabs, panes: [added, added])
  do { try restored.addHerdrTerminals(invalid, excluding: []); preconditionFailure("Expected duplicate rejection") }
  catch { precondition(restored.allPanes.count == beforeRollback, "A failed attachment must roll back prepared views") }
  waitUntil("Structural events must arrive over the read-only API and attach the new terminal", timeout: 5) {
    client.workspaceEventCount > eventsBefore && restored.allPanes.contains { $0.herdrTerminal?.pane.terminal_id == added.terminal_id }
  }
  // Attaching the pane changes the subscription set, so the stream is replaced; wait for the new one.
  waitUntil("The event subscription must be re-established after attaching") { client.eventsConnected }
  precondition(restored.session === localSelection)
  let count = restored.allPanes.count
  second.synchronizeHerdr(external, client: client)
  second.synchronizeHerdr(try client.snapshot(), client: client)
  precondition(restored.allPanes.count == count && restored.session === localSelection)
  let externalTab = external.tabs.first { $0.tab_id == added.tab_id }!
  _ = try client.request(["tab", "close", externalTab.tab_id])
  second.synchronizeHerdr(try client.snapshot(), client: client)
  precondition(restored.allPanes.count == count - 1 && restored.session === localSelection)
}

/// A second window has independent ownership and geometry; it is saved, detached and closed, with
/// the first window closed after it. Returns the second window's ID and namespace.
private func detachSecondWindow(_ second: AppDelegate, _ restored: TerminalWindowController, run: PersistenceRun) throws -> (String, String?) {
  second.newWindow(); waitForMux(second)
  let extra = second.windows.first { $0 !== restored }!
  let extraID = extra.workspaceWindowID
  let extraNamespace = extra.activeNamespace.id
  extra.window?.setFrame(NSRect(x: 100, y: 100, width: 850, height: 650), display: true)
  second.scheduleWorkspaceSave(extra); second.flushWorkspaceSaveSynchronously()
  extra.window?.performClose(nil)
  second.synchronizeHerdr(try run.client.snapshot(), client: run.client)
  precondition(!restored.namespaces.contains { $0.id == extraNamespace }, "Detached windows must stay detached")
  restored.window?.performClose(nil)
  return (extraID, extraNamespace)
}

/// After another relaunch the window assignments hold, and tabs and panes can move between windows.
/// Returns the window the tab came from, the second window and the detached pane's terminal.
private func verifyMoves(_ third: AppDelegate, extraID: String, extraNamespace: String?) throws
  -> (TerminalWindowController, TerminalWindowController, String) {
  precondition(third.windows.count == 2, "Window assignments must survive relaunch")
  let extraRestored = third.windows.first { $0.workspaceWindowID == extraID }!
  precondition(extraRestored.activeNamespace.id == extraNamespace)
  precondition(extraRestored.window!.frame.width == 850)
  let sourceWindow = third.windows.first { $0 !== extraRestored }!
  let movingTab = sourceWindow.namespaces.flatMap(\.tabs).first { $0.panes.count > 1 }!
  let movedIDs = Set(movingTab.panes.compactMap { $0.herdrTerminal?.pane.terminal_id })
  sourceWindow.selectTab(movingTab)
  sourceWindow.moveTab(movingTab, toNamespace: extraNamespace!); waitForMux(third, sourceWindow)
  let movedTab = extraRestored.tabs.first { Set($0.panes.compactMap { $0.herdrTerminal?.pane.terminal_id }) == movedIDs }
  precondition(movedTab != nil, "Moving a tab must preserve its existing terminals")
  extraRestored.selectTab(movedTab!)
  let detachedID = extraRestored.session!.herdrTerminal!.pane.terminal_id
  extraRestored.movePaneToNewTab(); waitForMux(third, extraRestored)
  precondition(extraRestored.activeTab.panes.count == 1 && extraRestored.session!.herdrTerminal!.pane.terminal_id == detachedID)
  return (sourceWindow, extraRestored, detachedID)
}

/// The settings window opens, workspace search finds a pane in another window, and a dropped
/// directory opens a terminal.
private func verifySearchAndDrop(_ third: AppDelegate, sourceWindow: TerminalWindowController,
  extraRestored: TerminalWindowController, directory: URL) throws {
  let settingsUI = try SettingsWindow(appOwner: third)
  settingsUI.showWindow(nil)
  settingsUI.window?.contentView?.layoutSubtreeIfNeeded()
  precondition(settingsUI.window?.isVisible == true)
  settingsUI.window?.close()
  extraRestored.showWorkspaceSearch()
  let searchPanel = extraRestored.palette!
  precondition(searchPanel.entries.count == third.windows.flatMap(\.allPanes).count)
  let searchTarget = sourceWindow.session!
  let searchID = "workspace:" + searchTarget.herdrTerminal!.pane.terminal_id
  let searchRow = searchPanel.filtered.firstIndex { $0.action == searchID }!
  searchPanel.table.selectRowIndexes(IndexSet(integer: searchRow), byExtendingSelection: false)
  searchPanel.runSelected()
  precondition(sourceWindow.session === searchTarget && !searchPanel.isVisible)
  let countBeforeDrop = third.windows.flatMap(\.allPanes).count
  third.application(app, openFiles: [directory.path])
  waitUntil("A directory drop creates a terminal", timeout: 8) { third.windows.flatMap(\.allPanes).count == countBeforeDrop + 1 }
}

/// A pane moves to its own window, and exiting its shell closes it without another keypress;
/// afterwards locally detached tabs do not leak into another window.
private func verifyShellExitClosesTab(_ third: AppDelegate, extraRestored: TerminalWindowController, detachedID: String,
  run: PersistenceRun) throws {
  let movingWindow = third.activeWindow!
  let movingPane = movingWindow.session!
  let surfaceBeforeMove = movingPane.surface
  movingWindow.moveTabToNewWindow(); waitForMux(third, movingWindow)
  let movedWindow = third.windows.first { $0.allPanes.contains { $0 === movingPane } }!
  precondition(movedWindow !== movingWindow && movingPane.surface == surfaceBeforeMove)
  let titled = movedWindow.window!.styleMask.contains(.titled)
  movedWindow.toggleDecorations()
  precondition(movedWindow.window!.styleMask.contains(.titled) != titled)
  movedWindow.toggleDecorations()
  // A shell exit closes its tab (here with its window) without another keypress.
  enterCommand("exit", in: movingPane)
  // The pane's recovery check abandons itself once its window is closing, so `recovering` is not a signal here.
  waitUntil("A herdr shell exit must close its tab without another keypress", timeout: 8) {
    movingPane.surface == nil && (movedWindow.closing || !movedWindow.allPanes.contains { $0 === movingPane })
  }
  extraRestored.window?.performClose(nil)
  third.synchronizeHerdr(try run.client.snapshot(), client: run.client)
  precondition(!third.windows.flatMap(\.allPanes).contains { $0.herdrTerminal?.pane.terminal_id == detachedID }, "Locally detached tabs must not leak into another window during reconciliation")
  for controller in Array(third.windows) { controller.closing = true; controller.window?.close() }
}
