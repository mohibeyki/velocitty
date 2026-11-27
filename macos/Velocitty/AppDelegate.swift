// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon
import Foundation
import UserNotifications
import VeloKit
import VelocittyConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
  let discoverHerdr: () -> URL?
  init(discoverHerdr: @escaping () -> URL? = HerdrClient.discover) {
    self.discoverHerdr = discoverHerdr
    super.init()
  }

  private var agentNotificationStates: [String: String] = [:]
  let secureInputOwner = SecureInputOwner()
  let fullscreenPresentation = FullscreenPresentation()
  var windows: [TerminalWindowController] = []
  private var settingsWindow: SettingsWindow?
  private var themePicker: ThemePickerWindow?
  // Test sessions do not read or overwrite the user's workspace file.
  var workspaceStateURL: URL?
  let workspacePersistence = WorkspacePersistence()
  var workspaceState: WorkspaceState? {
    get { workspacePersistence.state }
    set { workspacePersistence.state = newValue }
  }
  var workspaceLoadAttempted = false
  var workspaceCompatibilityWarning: String?
  var restoringWorkspace = false
  var synchronizingWorkspace = false
  let deferredSnapshots = DeferredSnapshots()

  weak var focusedWindow: TerminalWindowController?
  var runtime: TerminalRuntime? {
    didSet {
      oldValue?.context.owner = nil
      runtime?.context.owner = self
    }
  }
  var appearanceObservation: NSKeyValueObservation?
  var keyboardObservation: NSObjectProtocol?
  var shortcuts: GlobalShortcuts?
  var quitTimer: Timer?
  var pendingFiles: [String] = []
  private var openingDroppedFile = false
  var terminating = false
  var herdr: HerdrClient?
  let connectionCoordinator = ConnectionCoordinator()
  var connectionsWindow: ConnectionsWindow?
  private var agentPollTimer: Timer?
  let scrollbackCapture = ScrollbackCapture()
  private var pollingAgentEndpoints: Set<String> = []
  private var lastAgentPoll: [String: TimeInterval] = [:]
  var connections: [HerdrConnection] = []
  var connectionStatus: [String: ConnectionStatus] = [:]
  var tabSpaceOverrides: [String: String] = [:]
  var muxOpening = false
  var muxError: String?
  let closeHistory = CloseHistory()
  var retainedTerminalIDs: Set<String> { Set(closeHistory.closed.filter(\.applied).flatMap(\.terminalIDs)) }
  var hiddenTerminalIDs: Set<String> {
    closeHistory.pending.union(closeHistory.closed.filter { $0.applied && $0.destroy }.flatMap(\.terminalIDs))
  }

  func pollAgentSnapshots() {
    guard !terminating else { return }
    let clients = uniqueByEndpoint(windows.filter { !$0.closing }.flatMap(\.allPanes)
      .compactMap { $0.herdrTerminal?.client }.filter(\.isEnabled)).values
    let now = ProcessInfo.processInfo.systemUptime
    for client in clients {
      let endpoint = client.endpointID
      let interval: TimeInterval = NSApp.isActive ? (client.eventsConnected ? 10 : 2) : 30
      guard !pollingAgentEndpoints.contains(endpoint), now - (lastAgentPoll[endpoint] ?? -.infinity) >= interval else { continue }
      lastAgentPoll[endpoint] = now
      pollingAgentEndpoints.insert(endpoint)
      client.perform({ try $0.statusSnapshot() }) { [weak self, weak client] result in
        self?.pollingAgentEndpoints.remove(endpoint)
        guard let self, let client, !self.terminating else { return }
        switch result {
        case .success(let snapshot):
          self.synchronizeHerdr(snapshot, client: client)
        case .failure(let error):
          self.connectionFailed(client, error: error)
        }
      }
    }
  }

  func observeAgentStates(_ snapshot: HerdrClient.Snapshot) {
    let live = Set(snapshot.panes.map(\.terminal_id))
    agentNotificationStates = agentNotificationStates.filter { id, _ in
      !HerdrClient.owns(id, endpoint: snapshot.endpointID) || live.contains(id)
    }
    for record in snapshot.panes {
      let status = record.agent_status ?? "unknown"
      let previous = agentNotificationStates.updateValue(status, forKey: record.terminal_id)
      guard let previous, previous != status, ["blocked", "done"].contains(status),
        runtime?.settings.interface["agent_notifications"] != "false",
        let pane = pane(forTerminal: record.terminal_id),
        let controller = pane.windowController, !pane.connectionSuspended,
        !(NSApp.isActive && controller.window?.isKeyWindow == true && controller.session === pane) else { continue }
      let agent = record.display_agent ?? record.agent ?? "Agent"
      controller.notify(title: agent + (status == "blocked" ? " needs input" : " finished"),
        body: (controller.namespace(for: pane)?.name ?? "Workspace") + " · " + (controller.tab(for: pane)?.displayTitle ?? pane.displayTitle), terminalID: record.terminal_id)
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler complete: @escaping () -> Void) {
    let id = response.notification.request.content.userInfo["terminalID"] as? String
    DispatchQueue.main.async { [weak self] in
      defer { complete() }
      guard let self, let id, let pane = self.pane(forTerminal: id), let window = pane.windowController else { return }
      window.selectTab(pane); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler complete: @escaping (UNNotificationPresentationOptions) -> Void) {
    guard let id = notification.request.content.userInfo["terminalID"] as? String else { complete([]); return }
    let focused = activeWindow?.session?.herdrTerminal?.pane.terminal_id == id && activeWindow?.window?.isKeyWindow == true
    complete(focused ? [] : [.banner, .sound])
  }

  var activeWindow: TerminalWindowController? {
    windows.first { $0.window === NSApp.keyWindow }
      ?? windows.first { $0.window === NSApp.mainWindow }
      ?? focusedWindow ?? windows.last
  }
  var native: NativeSettings { NativeSettings(config: runtime?.config) }

  func applicationWillFinishLaunching(_ notification: Notification) {
    herdr = discoverHerdr().map { HerdrClient(executable: $0) }
    if let herdr { loadWorkspaceState(for: herdr) }
    do {
      runtime = try TerminalRuntime(settings: AppConfiguration.load())
      loadConnections()
      updateRestorationPolicy()
    } catch { NSLog("Could not prepare window restoration: %@", error.localizedDescription) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    // Load the bundled artwork directly so the running Dock tile doesn't
    // depend on Launch Services resolving an icon for a development build.
    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let icon = NSImage(contentsOf: iconURL)
    {
      NSApp.applicationIconImage = icon
    }

    installMainMenu()
    keyboardObservation = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil, queue: .main
    ) { [weak self] _ in
      if let app = self?.runtime?.app { velokit_app_keyboard_changed(app) }
      self?.shortcuts?.reload()
      self?.updateMenuShortcuts()
    }
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.refreshAppearance() }
    }

    let runtime: TerminalRuntime
    do {
      runtime = try self.runtime ?? TerminalRuntime(settings: AppConfiguration.load())
    } catch {
      configurationAlert(error).runModal()
      pendingFiles.removeAll()
      NSApp.terminate(nil)
      return
    }

    self.runtime = runtime
    shortcuts = GlobalShortcuts(owner: self)
    shortcuts?.reload()
    updateMenuShortcuts()
    updateRestorationPolicy()
    startInitialWorkspace()
    pollAgentSnapshots()
    agentPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.pollAgentSnapshots()
    }
    startScrollbackCapture()
    if herdr == nil { showMuxWarning() }
    if !pendingFiles.isEmpty && !muxOpening {
      drainDockFiles()
    }
    scheduleQuitIfNeeded()
    if native.hiddenPolicy == "always" { NSApp.hide(nil) }
    showConfigurationDiagnostics()
    if let workspaceCompatibilityWarning {
      configurationAlert(ConfigurationError(workspaceCompatibilityWarning)).runModal()
      self.workspaceCompatibilityWarning = nil
    }
  }

  func startInitialWorkspace() {
    if native.initialWindow && windows.isEmpty {
      newWindow()
    } else {
      restoreConnections(includingPrimary: true)
    }
  }

  @objc func newWindow() {
    if let herdr { loadWorkspaceState(for: herdr) }
    let customCommand = runtime?.settings.hasCustomCommand == true
    if !customCommand, let client = ([herdr].compactMap { $0 } + connectionCoordinator.clients.values.sorted { $0.endpointID < $1.endpointID }).first(where: { $0.isEnabled }) {
      openHerdrWindow(using: client); return
    }
    if !customCommand, herdr != nil { restoreUnavailableTabs(); showConnections(); return }
    newLocalWindow()
  }

  func newLocalWindow(directory: URL? = nil, initialInput: String? = nil) {
    quitTimer?.invalidate()
    quitTimer = nil
    do {
      if runtime == nil { runtime = try TerminalRuntime(settings: AppConfiguration.load()) }
      guard let runtime else { return }
      let session = runtime.makeSession()
      if let source = activeWindow?.session {
        let native = NativeSettings(config: source.config)
        if native.windowInheritsDirectory, let path = source.currentDirectory ?? activeWindow?.currentDirectory { session.initialDirectory = URL(fileURLWithPath: path) }
        if native.windowInheritsFontSize, let surface = source.surface { session.initialFontSize = velokit_surface_font_size(surface) }
      }
      if let directory { session.initialDirectory = directory }
      session.initialInput = initialInput
      let previousWindow = activeWindow?.window
      let controller = TerminalWindowController(session: session, owner: self)
      windows.append(controller)
      controller.openWindow(cascadingFrom: previousWindow)
      if controller.window == nil {
        windows.removeAll { $0 === controller }
        session.close()
        configurationAlert(ConfigurationError("Could not create a terminal window.")).runModal()
      }
    } catch { configurationAlert(error).runModal() }
  }

  func openWindow() {
    if let activeWindow { activeWindow.openWindow() } else { newWindow() }
  }

  func gotoWindow(_ direction: ghostty_action_goto_window_e, from source: TerminalWindowController?) {
    guard !terminating else { return }
    let step: Int
    switch direction {
    case GHOSTTY_GOTO_WINDOW_NEXT: step = 1
    case GHOSTTY_GOTO_WINDOW_PREVIOUS: step = -1
    default: return
    }
    // The registry keeps creation order, independent of focus and window stacking.
    let candidates = windows.filter { !$0.closing && $0.window != nil && $0.session?.surface != nil }
    guard !candidates.isEmpty else { return }
    let index: Int
    if let current = source ?? activeWindow,
      let currentIndex = candidates.firstIndex(where: { $0 === current })
    {
      index = (currentIndex + step + candidates.count) % candidates.count
    } else {
      index = step > 0 ? 0 : candidates.count - 1
    }
    guard let window = candidates[index].window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    if NSApp.isHidden { NSApp.unhide(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowFocused(_ controller: TerminalWindowController) {
    for other in windows where other !== controller { other.updateSecureInput(forceOff: true) }
    focusedWindow = controller
    scheduleWorkspaceSave(controller)
    if controller.hasBell {
      controller.clearBell()
    }
    updateMenuShortcuts()
  }

  func windowClosed(_ controller: TerminalWindowController) {
    windows.removeAll { $0 === controller }
    if focusedWindow === controller { focusedWindow = nil }
    if !terminating { scheduleQuitIfNeeded() }
  }

  func scheduleQuitIfNeeded() {
    guard windows.isEmpty, !muxOpening, !terminating, native.quitAfterLastWindowClosed else { return }
    quitTimer?.invalidate()
    quitTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.01, native.quitDelay),
      repeats: false
    ) { [weak self] _ in
      if self?.windows.isEmpty == true { NSApp.terminate(nil) }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openWindow()
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard settingsWindow?.confirmQuit() != false else { return .terminateCancel }
    // Confirm every terminal before closing any, so cancelling Quit preserves all windows.
    let closingWindows = windows
    for controller in closingWindows where !controller.confirmClose() { return .terminateCancel }
    terminating = true
    pendingFiles.removeAll()
    quitTimer?.invalidate()
    // Leave windows registered while AppKit captures their restorable state.
    if flushClosesBeforeQuit() { return .terminateLater }
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    deferredSnapshots.cancel()
    agentPollTimer?.invalidate()
    agentPollTimer = nil
    scrollbackCapture.stop()
    // Before any surface closes, while its text can still be read.
    saveScrollback(of: windows.flatMap(\.allPanes), blocking: true)
    secureInputOwner.update(wanted: false)
    fullscreenPresentation.update(nil)
    persistCloseIntent()
    flushWorkspaceSave()
    for operation in closeHistory.closed { operation.panes.forEach { $0.close() } }
    for controller in windows {
      controller.clearProgress()
      for tab in controller.allPanes { tab.close() }
    }
  }

  @objc func newNamespace() { activeWindow?.newNamespace() }
  @objc func editNamespace() { activeWindow?.editNamespace() }
  @objc func closeNamespace() { activeWindow?.closeNamespace() }


  @objc func newTab() { if let activeWindow { activeWindow.newTab() } else { newWindow() } }
  @objc func splitVertical() { activeWindow?.splitPane("right") }
  @objc func splitHorizontal() { activeWindow?.splitPane("down") }
  @objc func moveTabToNamespace() { activeWindow?.chooseTabNamespace() }
  @objc func movePaneToTab() { activeWindow?.choosePaneTab() }
  @objc func detachPaneToTab() { activeWindow?.movePaneToNewTab() }
  @objc func equalizePanes() { activeWindow?.equalizePanes() }
  @objc func zoomPane() { activeWindow?.togglePaneZoom() }
  @objc func closePane() { activeWindow?.closePane() }
  @objc func nextPane() { activeWindow?.focusPane("next") }
  @objc func previousPane() { activeWindow?.focusPane("previous") }
  @objc func resizePane(_ sender: NSMenuItem) { activeWindow?.resizePane(["left", "right", "up", "down"][sender.tag]) }
  @objc func closeTab() { activeWindow?.closeTab() }
  @objc func nextTab() { activeWindow?.cycleTab(1) }
  @objc func previousTab() { activeWindow?.cycleTab(-1) }
  @objc func renameTab() { activeWindow?.renameTab() }
  @objc func moveTabLeft() { activeWindow?.moveTab(-1) }
  @objc func moveTabRight() { activeWindow?.moveTab(1) }

  @objc func closeWindow() { activeWindow?.window?.performClose(nil) }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let muxActions: [Selector] = [#selector(splitVertical), #selector(splitHorizontal), #selector(nextPane), #selector(previousPane), #selector(resizePane(_:)), #selector(editNamespace), #selector(closeNamespace),
      #selector(nextTab), #selector(previousTab), #selector(renameTab), #selector(moveTabLeft), #selector(moveTabRight)]
    if let action = menuItem.action, muxActions.contains(action) {
      return activeWindow?.session?.herdrTerminal != nil && activeWindow?.muxBusy == false
    }
    if [#selector(closePane), #selector(closeTab)].contains(menuItem.action), activeWindow?.muxBusy == true { return false }
    switch menuItem.action {
    case #selector(undoClose): return NSApp.keyWindow?.firstResponder?.undoManager?.canUndo == true || closeHistory.closed.contains { $0.applied }
    case #selector(redoClose): return NSApp.keyWindow?.firstResponder?.undoManager?.canRedo == true || !closeHistory.redo.isEmpty
    case #selector(zoomPane), #selector(equalizePanes): return (activeWindow?.activeTab.panes.count ?? 0) > 1 && activeWindow?.muxBusy != true
    case #selector(closePane), #selector(newNamespace), #selector(editNamespace), #selector(closeNamespace),  #selector(closeTab), #selector(nextTab), #selector(previousTab), #selector(renameTab),
      #selector(moveTabLeft), #selector(moveTabRight), #selector(closeWindow), #selector(showCommands), #selector(findTerminal),
      #selector(findNext), #selector(findPrevious):
      return activeWindow?.session?.view?.surface != nil
    default:
      return true
    }
  }

  func closeAllWindows() {
    for controller in windows { controller.window?.performClose(nil) }
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard !terminating else { sender.reply(toOpenOrPrint: .failure); return }
    guard !filenames.isEmpty else {
      sender.reply(toOpenOrPrint: .success)
      return
    }
    pendingFiles.append(contentsOf: filenames)
    drainDockFiles()
    sender.reply(toOpenOrPrint: .success)
  }

  func drainDockFiles() {
    guard runtime != nil, !terminating, !muxOpening, !openingDroppedFile, !pendingFiles.isEmpty else { return }
    let path = pendingFiles.removeFirst()
    var directoryFlag: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directoryFlag) else {
      showMuxError(ConfigurationError("The dropped path no longer exists: " + path))
      drainDockFiles(); return
    }
    let url = URL(fileURLWithPath: path)
    let directory = directoryFlag.boolValue ? url : url.deletingLastPathComponent()
    let input: String?
    if directoryFlag.boolValue { input = nil }
    else {
      let alert = NSAlert()
      alert.messageText = "Allow Velocitty to execute “" + url.lastPathComponent + "”?"
      alert.informativeText = path
      alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { drainDockFiles(); return }
      // Leave the interactive shell open so short scripts don't lose their output.
      input = ShellInput.quote(path)
    }
    guard let client = herdr else {
      newLocalWindow(directory: directory, initialInput: input.map { $0 + "\n" })
      drainDockFiles(); return
    }
    let destination = native.dockDropBehavior == "new-tab" ? activeWindow.flatMap { $0.session?.herdrTerminal?.client === client ? $0 : nil } : nil
    let workspace = destination?.session?.herdrTerminal?.pane.workspace_id
    let environment = client.shellEnvironment(settings: runtime!.settings)
    openingDroppedFile = true
    client.perform({ client -> (HerdrClient.Snapshot, Set<String>) in
      _ = try client.connect(directory: directory)
      let pane = try client.createPane(workspace: workspace, name: directory.lastPathComponent, directory: directory.path, environment: environment)
      let after = try client.snapshot()
      let old = Set(after.panes.map(\.terminal_id)).subtracting([pane.terminal_id])
      if let input {
        _ = try client.api("pane.send_input", ["pane_id": pane.pane_id, "text": input, "keys": ["Enter"]])
      }
      return (after, old)
    }) { [weak self, weak destination] result in
      guard let self else { return }
      self.openingDroppedFile = false
      defer { self.drainDockFiles() }
      guard !self.terminating else { return }
      do {
        let (snapshot, old) = try result.get()
        let controller: TerminalWindowController
        if let destination, !destination.closing {
          controller = destination
          try destination.addHerdrTerminals(snapshot, excluding: old, client: client)
        } else {
          let ids = Set(snapshot.panes.filter { !old.contains($0.terminal_id) }.map(\.workspace_id))
          self.loadWorkspaceState(for: client)
          controller = try self.attachHerdrWindow(snapshot.excluding(terminals: old).filtered(namespaceIDs: ids), client: client,
            presentation: .init(id: UUID().uuidString, namespaceIDs: Array(ids), selectedNamespaceID: ids.first, frame: nil, sidebar: nil), state: self.workspaceState ?? WorkspaceState())
          controller.persistenceReady = self.workspacePersistenceEnabled
        }
        self.observeHerdr(client, snapshot: snapshot)
        self.scheduleWorkspaceSave(controller)
      } catch { self.showMuxError(error) }
    }
  }

  func refreshAppearance() {
    guard let runtime else { return }
    do {
      try runtime.updateConfiguration(runtime.settings)
      for diagnostic in runtime.diagnostics { NSLog("Configuration: %@", diagnostic) }
    } catch { NSLog("Appearance update failed: %@", error.localizedDescription) }
  }

  func updateRestorationPolicy() {
    switch native.windowSaveState {
    case "always": UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
    case "never": UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    default: UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func configurationDidChange() {
    updateRestorationPolicy()
    pruneScrollback()
    for controller in windows {
      for tab in controller.allPanes { tab.chrome?.refreshVisibility() }
      controller.workspaceView.refreshTabs()
      controller.applyWindowSettings()
      controller.updateSecureInput()
    }
    shortcuts?.reload()
    updateMenuShortcuts()
  }

  @objc func reloadConfiguration(_ sender: Any?) {
    do {
      try runtime?.updateConfiguration(AppConfiguration.load())
      loadConnections(reload: true)
      showConfigurationDiagnostics()
    } catch { configurationAlert(error).runModal() }
  }

  func showConfigurationDiagnostics() {
    guard let diagnostics = runtime?.diagnostics, !diagnostics.isEmpty else { return }
    for diagnostic in diagnostics { NSLog("Configuration: %@", diagnostic) }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Configuration has errors"
    alert.informativeText =
      "Valid settings were applied. Invalid values were skipped, leaving defaults or earlier valid values."
    alert.accessoryView = NSScrollView.readOnlyText(diagnostics.joined(separator: "\n\n"), size: NSSize(width: 560, height: 180))
    alert.addButton(withTitle: "OK")
    if let window = activeWindow?.window, window.attachedSheet == nil {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  @objc func showThemePicker() {
    do {
      if themePicker?.window?.isVisible != true { themePicker = try ThemePickerWindow(owner: self) }
      themePicker?.showWindow(nil); themePicker?.window?.makeKeyAndOrderFront(nil)
    } catch { configurationAlert(error).runModal() }
  }

  @objc func showSettings() {
    do {
      if settingsWindow == nil { settingsWindow = try SettingsWindow(appOwner: self) }
      settingsWindow?.showWindow(nil)
      settingsWindow?.window?.makeKeyAndOrderFront(nil)
    } catch { showMuxError(error) }
  }
  @objc func searchWorkspace() { activeWindow?.showWorkspaceSearch() }
  @objc func showCommands() { activeWindow?.showCommands() }
  @objc func findTerminal() { activeWindow?.findTerminal() }
  @objc func findNext() { activeWindow?.findNext() }
  @objc func findPrevious() { activeWindow?.findPrevious() }

  func updateFullscreenPresentation() {
    let controller = NSApp.isActive ? windows.first { $0.window?.isKeyWindow == true && !$0.closing } : nil
    let mode = controller?.fullscreenMode
    fullscreenPresentation.update(controller?.normalFrame != nil
      ? (mode == "visible-menu"
        ? [.autoHideDock] : [.autoHideDock, .autoHideMenuBar]) : nil)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    updateFullscreenPresentation()
    for controller in windows {
      controller.updateSecureInput()
    }
    runtime?.updateFocus()
  }

  func applicationDidResignActive(_ notification: Notification) {
    fullscreenPresentation.update(nil)
    for controller in windows {
      controller.updateSecureInput(forceOff: true)
    }
    runtime?.updateFocus()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// One main menu entry; a nil `action` with no title is a separator.
  private struct MenuEntry {
    enum Target { case delegate, application, responder }
    var title = ""
    var action: Selector?
    var key = ""
    var modifiers: NSEvent.ModifierFlags?
    var target = Target.delegate
    var tag: Int?
    static let separator = MenuEntry()
  }

  func installMainMenu() {
    let shift: NSEvent.ModifierFlags = [.command, .shift]
    let tables: [(title: String, entries: [MenuEntry])] = [
      ("Velocitty", [
        MenuEntry(title: "About Velocitty", action: #selector(showAboutPanel(_:))),
        .separator,
        MenuEntry(title: "Connections…", action: #selector(showConnections)),
        MenuEntry(title: "Terminal Theme…", action: #selector(showThemePicker)),
        MenuEntry(title: "Settings…", action: #selector(showSettings), key: ","),
        MenuEntry(title: "Reload Configuration", action: #selector(reloadConfiguration(_:)), key: "r", modifiers: shift),
        .separator,
        MenuEntry(title: "Hide Velocitty", action: #selector(NSApplication.hide(_:)), key: "h", target: .responder),
        MenuEntry(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: .responder),
        MenuEntry(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: .responder),
        .separator,
        MenuEntry(title: "Quit Velocitty", action: #selector(NSApplication.terminate(_:)), key: "q", target: .application),
      ]),
      ("Terminal", [
        MenuEntry(title: "New Window", action: #selector(newWindow), key: "n"),
        MenuEntry(title: "Search Workspace…", action: #selector(searchWorkspace), key: "p"),
        MenuEntry(title: "New Tab", action: #selector(newTab), key: "t"),
        MenuEntry(title: "Close Pane", action: #selector(closePane), key: "w"),
        MenuEntry(title: "Close Tab", action: #selector(closeTab)),
        MenuEntry(title: "Rename Tab…", action: #selector(renameTab)),
        MenuEntry(title: "Next Tab", action: #selector(nextTab)),
        MenuEntry(title: "Previous Tab", action: #selector(previousTab)),
        MenuEntry(title: "Move Tab to Namespace…", action: #selector(moveTabToNamespace)),
        MenuEntry(title: "Move Pane to Tab…", action: #selector(movePaneToTab)),
        MenuEntry(title: "Move Pane to New Tab", action: #selector(detachPaneToTab)),
        MenuEntry(title: "Move Tab Left", action: #selector(moveTabLeft)),
        MenuEntry(title: "Move Tab Right", action: #selector(moveTabRight)),
        .separator,
        MenuEntry(title: "Close Window", action: #selector(closeWindow), key: "w"),
        .separator,
        MenuEntry(title: "Split Vertically", action: #selector(splitVertical)),
        MenuEntry(title: "Split Horizontally", action: #selector(splitHorizontal)),
        MenuEntry(title: "Equalize Panes", action: #selector(equalizePanes)),
        MenuEntry(title: "Zoom Pane", action: #selector(zoomPane)),
        MenuEntry(title: "Next Pane", action: #selector(nextPane)),
        MenuEntry(title: "Previous Pane", action: #selector(previousPane)),
      ] + ["Left", "Right", "Up", "Down"].enumerated().map {
        MenuEntry(title: "Resize Pane \($0.element)", action: #selector(resizePane(_:)), tag: $0.offset)
      }),
      ("Namespace", [
        MenuEntry(title: "New Namespace", action: #selector(newNamespace)),
        MenuEntry(title: "Rename Namespace…", action: #selector(editNamespace)),
        MenuEntry(title: "Close Namespace", action: #selector(closeNamespace)),
      ]),
      ("Edit", [
        MenuEntry(title: "Undo Close", action: #selector(undoClose), key: "z"),
        MenuEntry(title: "Redo Close", action: #selector(redoClose), key: "z", modifiers: shift),
        .separator,
        MenuEntry(title: "Copy", action: #selector(TerminalView.copyMenuItem(_:)), key: "c", target: .responder),
        MenuEntry(title: "Paste", action: #selector(TerminalView.pasteMenuItem(_:)), key: "v", target: .responder),
        MenuEntry(title: "Select All", action: #selector(TerminalView.selectAllMenuItem(_:)), key: "a", target: .responder),
        .separator,
        MenuEntry(title: "Find…", action: #selector(findTerminal), key: "f"),
        MenuEntry(title: "Find Next", action: #selector(findNext), key: "g"),
        MenuEntry(title: "Find Previous", action: #selector(findPrevious), key: "g", modifiers: shift),
        MenuEntry(title: "Command Palette…", action: #selector(showCommands), key: "p", modifiers: shift),
      ]),
      ("Window", [
        MenuEntry(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", target: .responder),
        MenuEntry(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), target: .responder),
      ]),
    ]
    let mainMenu = NSMenu()
    for table in tables {
      let menu = NSMenu(title: table.title)
      for entry in table.entries { menu.addItem(menuItem(for: entry)) }
      let item = NSMenuItem()
      item.submenu = menu
      mainMenu.addItem(item)
    }
    NSApp.mainMenu = mainMenu
  }

  private func menuItem(for entry: MenuEntry) -> NSMenuItem {
    guard let action = entry.action else { return .separator() }
    let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: entry.key)
    if let modifiers = entry.modifiers { item.keyEquivalentModifierMask = modifiers }
    if let tag = entry.tag { item.tag = tag }
    switch entry.target {
    case .delegate: item.target = self
    case .application: item.target = NSApp
    case .responder: break
    }
    return item
  }

  func updateMenuShortcuts() {
    guard let config = runtime?.config else { return }
    let actions = [
      "New Window": "new_window", "Copy": "copy_to_clipboard", "Paste": "paste_from_clipboard",
      "Select All": "select_all",
      "Find…": "start_search", "Find Next": "navigate_search:next",
      "Find Previous": "navigate_search:previous",
      "Command Palette…": "toggle_command_palette", "Reload Configuration": "reload_config",
      "Close Window": "close_window", "Quit Velocitty": "quit",
      "Rename Namespace…": "rename_namespace",
      "New Namespace": "new_namespace", "Close Namespace": "close_namespace",
      "Resize Pane Left": "resize_split:left,5", "Resize Pane Right": "resize_split:right,5",
      "Resize Pane Up": "resize_split:up,5", "Resize Pane Down": "resize_split:down,5",
      "Split Vertically": "new_split:right", "Split Horizontally": "new_split:down",
      "Zoom Pane": "toggle_split_zoom", "Equalize Panes": "equalize_splits",
      "Next Pane": "goto_split:next", "Previous Pane": "goto_split:previous",
      "New Tab": "new_tab", "Close Pane": "close_surface", "Close Tab": "close_tab", "Rename Tab…": "prompt_tab_title",
      "Next Tab": "next_tab", "Previous Tab": "previous_tab",
      "Move Tab Left": "move_tab:-1", "Move Tab Right": "move_tab:1",
    ]
    func update(_ menu: NSMenu) {
      for item in menu.items {
        if let submenu = item.submenu { update(submenu) }
        guard let action = actions[item.title] else { continue }
        item.keyEquivalent = ""
        guard let shortcut = GlobalShortcuts.resolvedShortcut(action: action, config: config) else { continue }
        item.keyEquivalent = shortcut.key
        var flags: NSEvent.ModifierFlags = []
        let raw = shortcut.mods.rawValue
        if raw & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if raw & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if raw & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if raw & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        item.keyEquivalentModifierMask = flags
      }
    }
    if let menu = NSApp.mainMenu { update(menu) }
  }

  func configurationAlert(_ error: Error) -> NSAlert {
    NSLog("Configuration error: %@", error.localizedDescription)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Could not load configuration"
    alert.informativeText = error.localizedDescription
    return alert
  }

  @objc private func showAboutPanel(_ sender: Any?) {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Velocitty",
      .credits: NSAttributedString(string: "A macOS terminal powered by libghostty.\nLicensed under GNU GPL version 3."),
    ])
  }
}

final class TerminalTab {
  var panes: [TerminalSession]
  var selected: TerminalSession
  var title: String?
  var zoomed = false
  var localLayout: PaneLayout?
  var loadingTree = false
  var displayTitle: String { title ?? selected.terminalTitle }
  var hasBell: Bool { panes.contains { $0.hasBell } }
  var herdrID: String?

  init(_ pane: TerminalSession) {
    herdrID = pane.herdrTerminal?.pane.tab_id
    panes = [pane]
    selected = pane
    title = pane.tabTitle
  }
  func ensureLayout() {
    let ids = panes.compactMap { $0.herdrTerminal?.pane.terminal_id }
    var tree = localLayout?.retaining(Set(ids))
    for id in ids where tree?.terminals.contains(id) != true {
      if let current = tree, let target = current.terminals.last { tree = current.inserting(id, beside: target, direction: "right") }
      else { tree = .terminal(id) }
    }
    localLayout = tree
  }

}

final class TerminalNamespace: NSObject {
  var name: String
  var id: String?
  var tabs: [TerminalTab]
  var selected: TerminalTab

  init(name: String, session: TerminalSession) {
    self.name = name
    let tab = TerminalTab(session)
    self.tabs = [tab]
    self.selected = tab
    super.init()
  }
}

final class TerminalWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
  weak var owner: AppDelegate?

  init(session: TerminalSession, owner: AppDelegate) {
    self.session = session
    let namespace = TerminalNamespace(name: "Default", session: session)
    self.namespaces = [namespace]
    self.activeNamespace = namespace
    self.owner = owner
    super.init()
    session.windowController = self
  }

  var window: NSWindow?
  private(set) var session: TerminalSession?
  fileprivate(set) var namespaces: [TerminalNamespace]
  private(set) var activeNamespace: TerminalNamespace
  private(set) var tabs: [TerminalTab] {
    get { activeNamespace.tabs }
    set { activeNamespace.tabs = newValue }
  }
  var activeTab: TerminalTab { activeNamespace.selected }
  var primaryTab: TerminalTab?
  var companionTab: TerminalTab?
  var companionRatio: Double = 0.5
  var comparisonDismissed = false
  var presentedTabs: [TerminalTab] {
    let all = namespaces.flatMap(\.tabs)
    guard let primaryTab, let companionTab, primaryTab !== companionTab,
      all.contains(where: { $0 === primaryTab }), all.contains(where: { $0 === companionTab }) else { return [activeTab] }
    return [primaryTab, companionTab]
  }
  var visiblePanes: [TerminalSession] { presentedTabs.flatMap { $0.zoomed ? [$0.selected] : $0.panes } }

  func showAlongside(_ tab: TerminalTab) {
    guard tab !== activeTab, namespaces.flatMap(\.tabs).contains(where: { $0 === tab }) else { return }
    comparisonDismissed = false
    primaryTab = activeTab
    companionTab = tab
    workspaceView.present()
    selectTab(activeTab.selected)
    owner?.scheduleWorkspaceSave(self)
  }

  func chooseCompanion() {
    let candidates = namespaces.flatMap(\.tabs).filter { $0 !== activeTab }
    guard let window, window.attachedSheet == nil, !candidates.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Show a Tab Alongside"
    let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
    choices.addItems(withTitles: candidates.map { (namespace(for: $0.selected)?.name ?? "") + " / " + $0.displayTitle + " — " + ($0.selected.herdrTerminal?.client.endpointLabel ?? "Local") })
    alert.accessoryView = choices
    alert.addButton(withTitle: "Show")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn { self?.showAlongside(candidates[choices.indexOfSelectedItem]) }
    }
  }

  func stopAlongside() {
    comparisonDismissed = true
    primaryTab = nil; companionTab = nil
    workspaceView.present()
    selectTab(activeTab.selected)
    owner?.scheduleWorkspaceSave(self)
  }
  var allPanes: [TerminalSession] { namespaces.flatMap(\.tabs).flatMap(\.panes) }
  lazy var workspaceView = TerminalWorkspaceView(controller: self)
  func tab(for pane: TerminalSession) -> TerminalTab? {
    namespaces.flatMap(\.tabs).first { $0.panes.contains { $0 === pane } }
  }
  func namespace(for tab: TerminalSession) -> TerminalNamespace? {
    namespaces.first { $0.tabs.contains { $0.panes.contains { $0 === tab } } }
  }
  private var pendingTabClosures: [TerminalSession] = []
  var workspaceWindowID = UUID().uuidString
  var persistenceReady = false
  var persistedNamespaceIDs: Set<String> = []
  private var pendingMuxActions: [() -> Void] = []
  var hasPendingMuxActions: Bool { !pendingMuxActions.isEmpty }
  var muxBusy = false { didSet { if !muxBusy { drainMuxActions() } } }
  private func drainMuxActions() {
    guard !pendingMuxActions.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.muxBusy, !self.closing, self.owner?.terminating != true,
        !self.pendingMuxActions.isEmpty else { return }
      self.pendingMuxActions.removeFirst()()
      if !self.muxBusy { self.drainMuxActions() }
    }
  }
  private func deferMuxAction(_ action: @escaping () -> Void) -> Bool {
    guard muxBusy else { return false }
    pendingMuxActions.append(action)
    return true
  }
  var closing = false
  var resizeTimer: Timer?
  var hasResized = false
  var normalFrame: NSRect?
  var normalStyle: NSWindow.StyleMask?
  var fullscreenMode: String?
  private var decorationsOverride: Bool?
  var titleAccessory: NSTitlebarAccessoryViewController?
  var titleLabel: NSTextField?
  var currentDirectory: String? {
    get { session?.currentDirectory }
    set { session?.currentDirectory = newValue }
  }
  var palette: CommandPalette?
  var passwordInput: Bool {
    get { session?.passwordInput ?? false }
    set { session?.passwordInput = newValue }
  }
  var manualSecureInput: Bool {
    get { session?.manualSecureInput ?? false }
    set { session?.manualSecureInput = newValue }
  }
  var secureInputWanted = false
  var secureInputEnabled: Bool { secureInputWanted && owner?.secureInputOwner.enabled == true }
  var bellSound: NSSound?
  var terminalTitle: String {
    get { session?.terminalTitle ?? "Velocitty" }
    set { session?.terminalTitle = newValue }
  }
  var windowTitleOverride: String?
  var hasBell: Bool {
    get { session?.hasBell ?? false }
    set { session?.hasBell = newValue }
  }
  var readonly: Bool {
    get { session?.readonly ?? false }
    set { session?.readonly = newValue }
  }
  var chrome: TerminalChrome? {
    get { session?.chrome }
    set { session?.chrome = newValue }
  }
  var native: NativeSettings { NativeSettings(config: session?.config) }

  func openWindow(cascadingFrom previousWindow: NSWindow? = nil, restoring: Bool = false) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard let session, let terminalView = session.createView() else { return }
    let window = TerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    currentDirectory = (session.initialDirectory ?? session.settings.workingDirectory).path
    terminalTitle = "Velocitty"
    windowTitleOverride = nil
    hasBell = false
    window.title = "Velocitty"
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.identifier = TerminalWindowRestoration.identifier
    window.restorationClass = TerminalWindowRestoration.self
    let chrome = TerminalChrome(terminalView)
    self.chrome = chrome
    refreshTabBars()
    workspaceView.present()
    window.contentView = workspaceView
    self.window = window
    applyWindowSettings()
    if let surface = terminalView.surface {
      let size = velokit_surface_size(surface)
      let scale = window.backingScaleFactor
      if terminalView.initialSize != nil { resetWindowSize() }
      if native.windowStepResize {
        window.contentResizeIncrements = NSSize(
          width: max(1, CGFloat(size.cell_width_px) / scale),
          height: max(1, CGFloat(size.cell_height_px) / scale))
      }
    }
    window.center()
    let x = native.windowPositionX
    let y = native.windowPositionY
    let fixedPosition = x != Int16.min && y != Int16.min
    if !restoring, fixedPosition, let screen = window.screen {
      let frame = screen.visibleFrame
      window.setFrameOrigin(
        NSPoint(
          x: x == Int16.min ? window.frame.minX : frame.minX + CGFloat(x),
          y: y == Int16.min ? window.frame.minY : frame.maxY - window.frame.height - CGFloat(y)))
    }
    if !restoring, !fixedPosition, let previousWindow {
      // AppKit keeps the cascade on screen when it reaches a display edge.
      _ = window.cascadeTopLeft(from: NSPoint(
        x: previousWindow.frame.minX + 24, y: previousWindow.frame.maxY - 24))
    }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminalView)
    if !restoring && native.maximize { window.zoom(nil) }
    if !restoring && native.fullscreen != "false" {
      toggleFullscreen()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  var shouldSaveState: Bool {
    let policy = native.windowSaveState
    return policy == "always"
      || (policy == "default"
        && (UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool ?? true))
  }

  func applyWindowSettings() {
    guard let window else { return }
    // AppKit restores standalone windows; workspace persistence restores mux windows.
    window.isRestorable = shouldSaveState && session?.herdrTerminal == nil && namespaces.count == 1 && allPanes.count == 1 && session?.hasCustomCommand != true
    window.invalidateRestorableState()
    chrome?.refreshVisibility()
    if !native.progressStyle { clearProgress() }
    // Detach before changing styles; borderless windows have no titlebar controller.
    if let titleAccessory {
      if let index = window.titlebarAccessoryViewControllers.firstIndex(of: titleAccessory) {
        window.removeTitlebarAccessoryViewController(at: index)
      }
      self.titleAccessory = nil
      titleLabel = nil
    }
    let titlebar = native.titlebarStyle
    if normalFrame != nil || (decorationsOverride.map { !$0 } ?? (native.windowDecoration == "none" || titlebar == "hidden")) {
      window.styleMask.remove(.titled)
    } else {
      window.styleMask.insert(.titled)
    }
    if window.styleMask.contains(.titled), session?.herdrTerminal != nil {
      if window.toolbar == nil {
        let toolbar = NSToolbar(identifier: "workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifier = .init("workspaceSearch")
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
      }
    } else { window.toolbar = nil }
    window.titlebarAppearsTransparent = false
    window.hasShadow = native.windowShadow
    window.titleVisibility = titlebar == "hidden" ? .hidden : .visible
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(button)?.isHidden =
        native.windowButtons == "hidden"
    }
    window.colorSpace = native.windowColorspace == "display-p3" ? .displayP3 : .sRGB
    let family = native.titleFontFamily
    let foreground: NSColor? = workspaceView.chromeColor("chrome_foreground_color")
    if window.styleMask.contains(.titled) && !family.isEmpty {
      let accessory = NSTitlebarAccessoryViewController()
      let label = NSTextField(labelWithString: window.title)
      label.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
      label.alignment = .center
      label.font = NSFont(name: family, size: 13) ?? .systemFont(ofSize: 13)
      if let foreground { label.textColor = foreground }
      accessory.view = label
      accessory.layoutAttribute = .bottom
      window.addTitlebarAccessoryViewController(accessory)
      titleAccessory = accessory
      titleLabel = label
      window.titleVisibility = .hidden
    }
    let directory = currentDirectory ?? session?.settings.workingDirectory.path ?? ""
    window.subtitle = native.windowSubtitle == "working-directory" ? directory : ""
    window.representedURL =
      native.titlebarProxyIcon == "visible"
      ? URL(fileURLWithPath: directory) : nil
    window.appearance = NSAppearance(named: workspaceView.chromeIsDark ? .darkAqua : .aqua)
    applyBackground()
    refreshBell()
  }

  func applyBackground() {
    guard let window, chrome != nil else { return }
    WindowAppearance.apply(to: window, terminal: workspaceView, native: native,
      forceOpaque: session?.opacityOverride != nil)
    // Match the native chrome material rather than the terminal or a flat custom tint.
    window.backgroundColor = .windowBackgroundColor
  }


  private func confirmEnding(_ panes: [TerminalSession], checked: Bool = false, action: @escaping () -> Void) {
    guard !panes.isEmpty, !closing, owner?.terminating != true, let window, window.attachedSheet == nil else { return }
    if !checked, let client = panes.first(where: { $0.herdrTerminal != nil })?.herdrTerminal?.client {
      if deferMuxAction({ [weak self] in self?.confirmEnding(panes, action: action) }) { return }
      let candidates = panes.filter { NativeSettings(config: $0.config).confirmClose != "false" }
      guard !candidates.isEmpty else { action(); return }
      if candidates.contains(where: { NativeSettings(config: $0.config).confirmClose == "always" }) {
        confirmEnding(panes, checked: true, action: action)
        return
      }
      muxBusy = true
      client.perform({ client in
        candidates.contains { pane in
          guard let id = pane.herdrTerminal?.pane.pane_id else { return true }
          return (try? client.hasRunningTask(paneID: id)) != false
        }
      }) { [weak self] result in
        guard let self else { return }
        self.muxBusy = false
        guard !self.closing, self.owner?.terminating != true, self.window?.attachedSheet == nil else { return }
        if (try? result.get()) == false { action() }
        else { self.confirmEnding(panes, checked: true, action: action) }
      }
      return
    }
    let requiresConfirmation = panes.contains { pane in
      if pane.herdrTerminal != nil { return NativeSettings(config: pane.config).confirmClose != "false" }
      return pane.surface.map { velokit_surface_needs_confirm_quit($0) } ?? false
    }
    guard requiresConfirmation else { action(); return }
    let alert = NSAlert()
    alert.messageText = panes.count == 1 ? "End terminal?" : "End \(panes.count) terminals?"
    alert.informativeText = "This ends these terminals and their running processes.\n\n"
      + panes.prefix(8).map(\.displayTitle).joined(separator: "\n")
      + (panes.count > 8 ? "\n…and \(panes.count - 8) more" : "")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "End")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.closing, self.owner?.terminating != true else { return }
      if response == .alertSecondButtonReturn { action() }
    }
  }

  func confirmClose(of target: TerminalSession? = nil) -> Bool {
    guard let target else {
      // Closing a window or quitting only detaches herdr clients.
      return allPanes.filter { $0.herdrTerminal == nil }.allSatisfy { confirmClose(of: $0) }
    }
    if target.herdrTerminal != nil {
      guard NativeSettings(config: target.config).confirmClose != "false" else { return true }
      let alert = NSAlert()
      alert.messageText = "End \(target.displayTitle)?"
      alert.informativeText = "This ends the terminal and its running processes in herdr. Close the window instead to keep them running."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "End Terminal")
      return alert.runModal() == .alertSecondButtonReturn
    }
    guard let surface = target.surface, velokit_surface_needs_confirm_quit(surface) else {
      return true
    }
    let alert = NSAlert()
    alert.messageText = "Close \(target.displayTitle)?"
    alert.informativeText = "A process is still running. Closing the terminal will end it."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Close Terminal")
    return alert.runModal() == .alertSecondButtonReturn
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closing { return true }
    guard confirmClose() else { return false }
    if owner?.deferClose(allPanes, in: self, destroy: false) == true { return false }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    owner?.scheduleWorkspaceSave(self)
    owner?.flushWorkspaceSave()
    owner?.windowPanesClosing(allPanes)
    persistenceReady = false
    pendingMuxActions.removeAll()
    passwordInput = false
    manualSecureInput = false
    readonly = false
    updateSecureInput(forceOff: true)
    clearProgress()
    for tab in allPanes { tab.close() }
    namespaces.removeAll()
    pendingTabClosures.removeAll()
    window = nil
    chrome = nil
    palette?.close()
    palette = nil
    normalFrame = nil
    normalStyle = nil
    fullscreenMode = nil
    owner?.updateFullscreenPresentation()
    resizeTimer?.invalidate()
    owner?.windowClosed(self)
  }

  func setTitle(_ title: String) {
    terminalTitle = title
    refreshTabBars()
    let displayed = (hasBell && native.bellFeatures.contains(.title) ? "● " : "") + (windowTitleOverride ?? activeTab.displayTitle)
    window?.title = displayed
    titleLabel?.stringValue = displayed
    window?.invalidateRestorableState()
  }

  func promptTitle(_ mode: ghostty_action_prompt_title_e) {
    guard let window, let terminal = session?.view else { return }
    let alert = NSAlert()
    alert.messageText = "Terminal Title"
    alert.informativeText = "Enter a title. Leave it empty to clear the override."
    let field = NSTextField(string: windowTitleOverride ?? terminalTitle)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Set Title")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak terminal] response in
      guard response == .alertFirstButtonReturn, terminal?.surface != nil else { return }
      terminal?.performSurfaceAction(
        (mode == GHOSTTY_PROMPT_TITLE_WINDOW ? "set_window_title:" : "set_surface_title:")
          + field.stringValue)
    }
  }
  func setDirectory(_ path: String) {
    currentDirectory = path
    window?.invalidateRestorableState()
    if native.windowSubtitle == "working-directory" { window?.subtitle = path }
    window?.representedURL =
      native.titlebarProxyIcon == "visible" ? URL(fileURLWithPath: path) : nil
  }
  func resetWindowSize() {
    guard let window else { return }
    var size = session?.view?.initialSize ?? NSSize(width: 960, height: 640)
    size.width += workspaceView.sidebarInset
    size.height += workspaceView.tabHeight
    let drag = native.dragHandle
    if drag == "always" || (drag == "auto" && !window.styleMask.contains(.titled)) {
      size.height += 12
    }
    if chrome?.searching == true { size.height += 38 }
    window.setContentSize(size)
  }

  func toggleFullscreen(modeOverride: String? = nil) {
    guard let window else { return }
    let mode = modeOverride ?? (native.fullscreen == "non-native-visible-menu" ? "visible-menu"
      : native.fullscreen == "non-native-padded-notch" ? "padded-notch" : native.nonNativeFullscreen)
    if let frame = normalFrame {
      window.styleMask = normalStyle ?? [.titled, .closable, .miniaturizable, .resizable]
      window.setFrame(frame, display: true)
      normalFrame = nil
      normalStyle = nil
      fullscreenMode = nil
      window.invalidateRestorableState()
      owner?.updateFullscreenPresentation()
      applyWindowSettings()
      window.makeFirstResponder(session?.view)
      return
    }
    guard !window.styleMask.contains(.fullScreen),
      mode != "false" || native.fullscreen.hasPrefix("non-native") else {
      window.toggleFullScreen(nil)
      return
    }
    fullscreenMode = mode == "false" ? "true" : mode
    window.invalidateRestorableState()
    normalFrame = window.frame
    normalStyle = window.styleMask
    window.styleMask = [.borderless]
    if let screen = window.screen {
      var frame = mode == "visible-menu" ? screen.visibleFrame : screen.frame
      if mode == "padded-notch" { frame.size.height -= screen.safeAreaInsets.top }
      window.setFrame(frame, display: true)
    }
    owner?.updateFullscreenPresentation()
    window.makeFirstResponder(session?.view)
    applyBackground()
  }
  func windowDidMove(_ notification: Notification) { owner?.scheduleWorkspaceSave(self) }
  func windowDidResize(_ notification: Notification) {
    owner?.scheduleWorkspaceSave(self)
    defer { hasResized = true }
    let policy = native.resizeOverlay
    guard policy != "never", policy == "always" || hasResized, window?.inLiveResize == true,
      let chrome, let surface = session?.view?.surface
    else { return }
    let size = velokit_surface_size(surface)
    chrome.resizeLabel.stringValue = "\(size.columns) × \(size.rows)"
    chrome.resizeLabel.isHidden = false
    chrome.needsLayout = true
    resizeTimer?.invalidate()
    resizeTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.01, native.resizeOverlayDuration), repeats: false
    ) { [weak chrome] _ in chrome?.resizeLabel.isHidden = true }
  }
  func windowDidEnterFullScreen(_ notification: Notification) { applyBackground() }
  func windowDidExitFullScreen(_ notification: Notification) { applyBackground() }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let window else { return }
    for pane in visiblePanes {
      if let surface = pane.surface { velokit_surface_set_occlusion(surface, window.occlusionState.contains(.visible)) }
    }
  }
  func windowDidEndLiveResize(_ notification: Notification) {
    window?.invalidateRestorableState()
  }

  func workspaceSearchEntries() -> [CommandPalette.Entry] {
    (owner?.windows ?? [self]).flatMap { controller in
      controller.namespaces.flatMap { namespace in
        namespace.tabs.enumerated().flatMap { index, tab in
          tab.panes.map { pane in
            let agent = controller.workspaceView.agent(for: pane)
            let status = agent.map { " · " + $0.name + " · " + ($0.status == "blocked" ? "waiting for input" : $0.status) } ?? ""
            return CommandPalette.Entry(title: namespace.name + " / " + String(index + 1) + " · " + tab.displayTitle + status,
              detail: [pane.herdrTerminal?.client.endpointLabel, pane.currentDirectory, pane.herdrTerminal?.pane.cwd, agent?.name, agent?.status].compactMap { $0 }.joined(separator: " "),
              action: "workspace:" + (pane.herdrTerminal?.pane.terminal_id ?? String(ObjectIdentifier(pane).hashValue)),
              run: { [weak controller, weak pane] in
                guard let controller, let pane, controller.allPanes.contains(where: { $0 === pane }) else { return }
                controller.selectTab(pane)
                controller.window?.makeKeyAndOrderFront(nil)
              })
          }
        }
      }
    }
  }

  func showWorkspaceSearch(query: String = "") {
    guard let terminal = session?.view, window?.attachedSheet == nil else { return }
    palette?.close()
    let panel = CommandPalette(terminal: terminal, entries: { [weak self] in self?.workspaceSearchEntries() ?? [] })
    palette = panel
    panel.query.stringValue = query
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    panel.present()
  }

  func showAgents() {
    guard let terminal = session?.view, window?.attachedSheet == nil else { return }
    palette?.close()
    let panel = CommandPalette(terminal: terminal, entries: { [weak self] in
      guard let self else { return [] }
      let ids = Set((self.owner?.windows ?? [self]).flatMap { controller in controller.allPanes.filter { controller.workspaceView.agent(for: $0) != nil }.compactMap { $0.herdrTerminal?.pane.terminal_id }.map { "workspace:" + $0 } })
      return self.workspaceSearchEntries().filter { ids.contains($0.action) }
    })
    panel.title = "Agents"; palette = panel; panel.present()
  }

  func selectNextWaitingAgent() {
    let panes = (owner?.windows ?? [self]).flatMap { controller in controller.allPanes.filter { controller.workspaceView.agent(for: $0)?.status == "blocked" } }
    guard !panes.isEmpty else { NSSound.beep(); return }
    let index = panes.firstIndex { $0 === session }.map { ($0 + 1) % panes.count } ?? 0
    let pane = panes[index]; pane.windowController?.selectTab(pane); pane.windowController?.window?.makeKeyAndOrderFront(nil)
  }

  @objc private func workspaceSearchTyped(_ sender: NSSearchField) {
    let text = sender.stringValue
    sender.stringValue = ""
    showWorkspaceSearch(query: text)
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("workspaceSearch"), .init("namespaceSidebar")] }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("namespaceSidebar"), .flexibleSpace, .init("workspaceSearch"), .flexibleSpace] }
  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    if identifier.rawValue == "namespaceSidebar" {
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Compact Namespaces"
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle compact namespaces")
      item.target = workspaceView
      item.action = #selector(TerminalWorkspaceView.toggleNamespaceSidebar)
      return item
    }
    guard identifier.rawValue == "workspaceSearch" else { return nil }
    let item = NSSearchToolbarItem(itemIdentifier: identifier)
    item.searchField.placeholderString = "Search namespaces, tabs, agents…"
    item.searchField.sendsSearchStringImmediately = true
    item.searchField.target = self
    item.searchField.action = #selector(workspaceSearchTyped(_:))
    item.preferredWidthForSearchField = 400
    return item
  }

  @objc func showCommands() {
    if palette?.isVisible == true {
      palette?.close()
      return
    }
    guard let terminal = session?.view else { return }
    let palette = CommandPalette(terminal: terminal)
    self.palette = palette
    palette.present()
  }

  @objc func findTerminal() { session?.view?.performSurfaceAction("start_search") }
  @objc func findNext() { session?.view?.performSurfaceAction("navigate_search:next") }
  @objc func findPrevious() { session?.view?.performSurfaceAction("navigate_search:previous") }


}

extension TerminalWindowController {
  func ringBell(from source: TerminalSession? = nil) {
    guard let tab = source ?? session else { return }
    let native = NativeSettings(config: tab.config)
    let features = native.bellFeatures
    if features.contains(.system) { NSSound.beep() }
    if features.contains(.audio) {
      let path = native.bellAudioPath
      bellSound =
        path.isEmpty ? NSSound(named: "Glass") : NSSound(contentsOfFile: path, byReference: true)
      bellSound?.volume = Float(native.bellAudioVolume)
      bellSound?.play()
    }
    if (!NSApp.isActive || window?.isKeyWindow != true || session !== tab) && features.contains(.attention) {
      NSApp.requestUserAttention(.informationalRequest)
    }
    tab.hasBell = true
    tabMetadataChanged(tab)
  }

  func clearBell() {
    guard hasBell else { return }
    hasBell = false
    setTitle(terminalTitle)
    refreshBell()
  }

  func refreshBell() {
    chrome?.wantsLayer = true
    chrome?.layer?.borderColor = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.5).cgColor
    chrome?.layer?.borderWidth = hasBell && native.bellFeatures.contains(.border) ? 3 : 0
  }

  func notify(title: String, body: String, terminalID: String? = nil) {
    // OSC notifications are filtered by the engine. Command-finish notifications
    // have their own policy and must not be disabled by that OSC setting.
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      let deliver = {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let terminalID { content.userInfo["terminalID"] = terminalID; content.sound = .default }
        center.add(
          UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
          if let error { NSLog("Notification failed: %@", error.localizedDescription) }
        }
      }
      switch settings.authorizationStatus {
      case .authorized, .provisional: deliver()
      case .notDetermined:
        center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
          if allowed { deliver() }
        }
      default: break
      }
    }
  }

  func commandFinished(_ value: ghostty_action_command_finished_s, from source: TerminalSession? = nil) {
    guard let tab = source ?? session else { return }
    let native = NativeSettings(config: tab.config)
    let policy = native.notifyOnCommandFinish
    let focused =
      NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === tab.view
    guard policy != "never", policy == "always" || !focused,
      Double(value.duration) / 1_000_000_000 >= native.commandFinishDelay
    else { return }
    let actions = native.commandFinishActions
    if actions.contains(.bell) { ringBell(from: tab) }
    if actions.contains(.notify) {
      notify(
        title: "Command finished",
        body: value.exit_code < 0
          ? "The command has finished." : "The command exited with status \(value.exit_code).")
    }
  }

  func clearProgress() { chrome?.progress.clear() }

  func showProgress(_ report: ghostty_action_progress_report_s) {
    if native.progressStyle { chrome?.progress.update(report) }
    else { clearProgress() }
  }

}

extension TerminalWindowController {
  func secureInput(_ mode: ghostty_action_secure_input_e, from source: TerminalSession? = nil) {
    guard let tab = source ?? session else { return }
    if mode == GHOSTTY_SECURE_INPUT_TOGGLE {
      tab.manualSecureInput.toggle()
    } else {
      tab.passwordInput = mode == GHOSTTY_SECURE_INPUT_ON
    }
    if session === tab { updateSecureInput() }
  }
  func updateSecureInput(forceOff: Bool = false) {
    secureInputWanted = !forceOff && NSApp.isActive && window?.isKeyWindow == true
      && (manualSecureInput || (passwordInput && native.autoSecureInput
        && session?.view?.terminalFocused == true))
    owner?.secureInputOwner.update(wanted: owner?.windows.contains { $0.secureInputWanted } == true)
    var indicators: [String] = []
    if readonly { indicators.append("Read Only") }
    if secureInputEnabled && native.secureInputIndication {
      indicators.append("🔒 Secure Input")
    }
    chrome?.secure.stringValue = indicators.joined(separator: " · ")
  }
  func windowDidBecomeKey(_ notification: Notification) {
    owner?.updateFullscreenPresentation()
    applyBackground()
    owner?.windowFocused(self)
    updateSecureInput()
    session?.view?.updateFocus()
  }
  func windowDidResignKey(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in self?.owner?.updateFullscreenPresentation() }
    updateSecureInput(forceOff: true)
    session?.view?.updateFocus()
  }
  func windowWillBeginSheet(_ notification: Notification) {
    // The sheet may not yet be attached when AppKit sends this notification.
    session?.view?.updateFocus(forceOff: true)
  }
  func windowDidEndSheet(_ notification: Notification) {
    // AppKit can send this before clearing attachedSheet and restoring the key window.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.session?.view?.updateFocus()
      let pending = self.pendingTabClosures
      self.pendingTabClosures.removeAll()
      for tab in pending { self.closePane(tab, confirm: false, endSession: false) }
    }
  }
}

final class TerminalWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

extension TerminalWindowController {
  func newTab(inNewNamespace: Bool = false, using chosenClient: HerdrClient? = nil) {
    guard let session, let client = chosenClient ?? session.herdrTerminal?.client else { owner?.showMuxWarning(); return }
    guard let window, window.attachedSheet == nil, !closing else { return }
    if deferMuxAction({ [weak self] in self?.newTab(inNewNamespace: inNewNamespace, using: chosenClient) }) { return }
    guard client.isEnabled else { owner?.showConnections(); return }
    let targetSpace = activeNamespace
    let workspace = inNewNamespace ? nil : targetSpace.tabs.flatMap(\.panes).first { $0.herdrTerminal?.client === client }?.herdrTerminal?.pane.workspace_id
    let name = "Namespace \(namespaces.count + 1)"
    let fallback = client.machine == nil ? session.settings.workingDirectory.path : nil
    let directory = native.tabInheritsDirectory && session.herdrTerminal?.client === client ? currentDirectory ?? fallback : fallback
    let existing = owner?.attachedTerminalIDs ?? Set(allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })
    let shellEnvironment = client.shellEnvironment(settings: session.settings)
    muxBusy = true
    client.perform({ client -> (HerdrClient.Snapshot, String) in
      _ = try client.connect(directory: session.settings.workingDirectory)
      let pane = try client.createPane(workspace: workspace, name: name, directory: directory, environment: shellEnvironment)
      return (try client.snapshot(), pane.tab_id)
    }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, self.window != nil, self.owner?.terminating != true else { return }
      do {
        let (snapshot, tabID) = try result.get()
        if !inNewNamespace, self.namespaces.contains(where: { $0 === targetSpace }) { self.owner?.tabSpaceOverrides[tabID] = targetSpace.id }
        try self.addHerdrTerminals(snapshot, excluding: existing, client: client)
        self.owner?.scheduleWorkspaceSave(self)
      } catch { self.owner?.showMuxError(error) }
    }
  }

  func selectTab(_ tab: TerminalTab) { selectTab(tab.selected) }

  func selectTab(_ pane: TerminalSession) {
    guard let namespace = namespace(for: pane), let tab = tab(for: pane), (pane.surface != nil || pane.connectionSuspended),
      let window, window.attachedSheet == nil, !closing else { return }
    if presentedTabs.count == 2, !presentedTabs.contains(where: { $0 === tab }) { primaryTab = tab }
    if session !== pane || activeTab !== tab || activeNamespace !== namespace {
      palette?.close()
      updateSecureInput(forceOff: true)
      session?.view?.updateFocus(forceOff: true)
      activeNamespace = namespace
      namespace.selected = tab
      if tab.selected !== pane && !NativeSettings(config: pane.config).preserveZoomNavigation { tab.zoomed = false }
      tab.selected = pane
      session = pane
      workspaceView.present()
      applyWindowSettings()
      setTitle(pane.terminalTitle)
      applySizeLimit(for: pane)
    }
    for terminal in allPanes {
      terminal.chrome?.needsLayout = true
      if let surface = terminal.surface {
        velokit_surface_set_occlusion(surface,
          visiblePanes.contains { $0 === terminal } && window.occlusionState.contains(.visible))
      }
    }
    if native.windowStepResize, visiblePanes.count == 1, let surface = pane.surface {
      let size = velokit_surface_size(surface)
      window.contentResizeIncrements = NSSize(width: max(1, CGFloat(size.cell_width_px) / window.backingScaleFactor),
        height: max(1, CGFloat(size.cell_height_px) / window.backingScaleFactor))
    } else { window.contentResizeIncrements = NSSize(width: 1, height: 1) }
    refreshTabBars()
    if window.firstResponder !== pane.view { window.makeFirstResponder(pane.view) }
    pane.view?.updateFocus()
    updateSecureInput()
    owner?.updateMenuShortcuts()
    owner?.scheduleWorkspaceSave(self)
  }

  func cycleTab(_ step: Int, from source: TerminalSession? = nil) {
    guard let selected = source ?? session, let namespace = namespace(for: selected),
      let tab = tab(for: selected), let index = namespace.tabs.firstIndex(where: { $0 === tab }) else { return }
    let tabs = namespace.tabs
    selectTab(tabs[(index + step % tabs.count + tabs.count) % tabs.count])
  }

  func moveTab(_ amount: Int, from source: TerminalSession? = nil) {
    guard let pane = source ?? session, let namespace = namespace(for: pane), let tab = tab(for: pane),
      let index = namespace.tabs.firstIndex(where: { $0 === tab }),
      window?.attachedSheet == nil, !closing else { return }
    let destination = max(0, min(namespace.tabs.count - 1, index + max(-namespace.tabs.count, min(namespace.tabs.count, amount))))
    namespace.tabs.remove(at: index)
    namespace.tabs.insert(tab, at: destination)
    refreshTabBars()
    owner?.scheduleWorkspaceSave(self)
  }

  func requestTabClose(_ pane: TerminalSession) {
    guard namespace(for: pane) != nil, !closing else { return }
    if window?.attachedSheet != nil {
      if !pendingTabClosures.contains(where: { $0 === pane }) { pendingTabClosures.append(pane) }
    } else { closePane(pane, confirm: false, endSession: false) }
  }

  func closeTab(_ source: TerminalSession? = nil, confirm: Bool = true, endSession: Bool = true) {
    guard let pane = source ?? session, let namespace = namespace(for: pane), let tab = tab(for: pane),
      let index = namespace.tabs.firstIndex(where: { $0 === tab }),
      window?.attachedSheet == nil, !closing else { return }
    if confirm {
      confirmEnding(tab.panes) { [weak self, weak pane] in
        if let pane { self?.closeTab(pane, confirm: false, endSession: endSession) }
      }
      return
    }
    if endSession, pane.herdrTerminal != nil { endHerdrTabs([tab]); return }
    if endSession, owner?.deferClose(tab.panes, in: self, destroy: true) == true { return }
    if namespaces.flatMap(\.tabs).count == 1 {
      closing = true
      window?.close()
      return
    }
    if activeTab === tab {
      let next = namespace.tabs.count > 1
        ? namespace.tabs[index == namespace.tabs.count - 1 ? index - 1 : index + 1]
        : namespaces.first { $0 !== namespace }!.selected
      selectTab(next)
    }
    namespace.tabs.removeAll { $0 === tab }
    if namespace.tabs.isEmpty { namespaces.removeAll { $0 === namespace } }
    else if namespace.selected === tab { namespace.selected = namespace.tabs[min(index, namespace.tabs.count - 1)] }
    for pane in tab.panes { pane.close() }
    workspaceView.present()
    applyWindowSettings()
    owner?.scheduleWorkspaceSave(self)
  }

  func closeTabs(_ mode: ghostty_action_close_tab_mode_e, from source: TerminalSession? = nil) {
    guard let pane = source ?? session, let namespace = namespace(for: pane), let tab = tab(for: pane),
      let index = namespace.tabs.firstIndex(where: { $0 === tab }),
      window?.attachedSheet == nil, !closing else { return }
    let targets: [TerminalTab]
    switch mode {
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: targets = namespace.tabs.filter { $0 !== tab }
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: targets = Array(namespace.tabs.dropFirst(index + 1))
    default: targets = [tab]
    }
    confirmEnding(targets.flatMap(\.panes)) { [weak self, weak pane] in
      guard let self, let pane else { return }
      if pane.herdrTerminal == nil { self.closeTab(pane, confirm: false); return }
      self.endHerdrTabs(targets)
    }
  }

  func renameTab(_ source: TerminalSession? = nil) {
    guard let tab = source ?? session, namespace(for: tab) != nil,
      let window, window.attachedSheet == nil else { return }
    let alert = NSAlert()
    alert.messageText = "Rename Tab"
    alert.informativeText = "Leave the name empty to follow the terminal title."
    let field = NSTextField(string: tab.tabTitle ?? tab.terminalTitle)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self, weak tab] response in
      guard response == .alertFirstButtonReturn, let self, let tab, tab.surface != nil else { return }
      let value = field.stringValue
      self.tab(for: tab)?.title = value.isEmpty ? nil : value
      for pane in self.tab(for: tab)?.panes ?? [] { pane.tabTitle = value.isEmpty ? nil : value }
      self.tabMetadataChanged(tab)
      self.owner?.scheduleWorkspaceSave(self)
    }
    window.attachedSheet?.makeFirstResponder(field)
  }

  func tabMetadataChanged(_ tab: TerminalSession) {
    if session === tab {
      setTitle(tab.terminalTitle)
      if let directory = tab.currentDirectory { setDirectory(directory) }
      refreshBell()
      updateSecureInput()
    } else { refreshTabBars() }
    owner?.scheduleWorkspaceSave(self)
  }

  func refreshTabBars() {
    workspaceView.refreshTabs()
  }

  func applySizeLimit(for tab: TerminalSession) {
    guard session === tab, let window, let limit = tab.sizeLimit else { return }
    if visiblePanes.count > 1 {
      window.contentMinSize = NSSize(width: workspaceView.sidebarInset + 320, height: 240)
      window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      return
    }
    let scale = window.backingScaleFactor
    window.contentMinSize = NSSize(width: CGFloat(limit.min_width) / scale + (workspaceView.sidebarInset),
      height: CGFloat(limit.min_height) / scale + (workspaceView.tabHeight))
    window.contentMaxSize = NSSize(
      width: limit.max_width == 0 ? CGFloat.greatestFiniteMagnitude
        : max(window.contentMinSize.width, CGFloat(limit.max_width) / scale + (workspaceView.sidebarInset)),
      height: limit.max_height == 0 ? CGFloat.greatestFiniteMagnitude
        : max(window.contentMinSize.height, CGFloat(limit.max_height) / scale + (workspaceView.tabHeight)))
  }
}


extension TerminalWindowController {
  func newNamespace() { newTab(inNewNamespace: true) }

  func selectNamespace(at index: Int) {
    guard namespaces.indices.contains(index) else { return }
    selectTab(namespaces[index].selected)
  }

  func closeNamespace() {
    guard window?.attachedSheet == nil, !closing else { return }
    let targets = activeNamespace.tabs
    confirmEnding(targets.flatMap(\.panes)) { [weak self] in self?.endHerdrTabs(targets) }
  }

  func editNamespace() {
    guard let window, window.attachedSheet == nil, !closing else { return }
    let namespace = activeNamespace
    let alert = NSAlert()
    alert.messageText = "Rename Namespace"
    let name = NSTextField(string: namespace.name)
    name.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    name.setAccessibilityLabel("Namespace name")
    alert.accessoryView = name
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self,
        self.namespaces.contains(where: { $0 === namespace }) else { return }
      let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      namespace.name = value.isEmpty ? namespace.name : value
      self.refreshTabBars()
      self.owner?.scheduleWorkspaceSave(self)
    }
    window.attachedSheet?.makeFirstResponder(name)
  }
}


extension TerminalWindowController {
  func addHerdrTerminals(_ snapshot: HerdrClient.Snapshot, excluding excluded: Set<String>, restoring: Bool = false, client explicitClient: HerdrClient? = nil) throws {
    guard let client = explicitClient ?? session?.herdrTerminal?.client, let runtime = session?.runtime else { return }
    let attached = (owner?.attachedTerminalIDs ?? Set(allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })).union(owner?.retainedTerminalIDs ?? [])
    let excluded = excluded.union(attached)
    var prepared: [String: TerminalSession] = [:]
    do {
      for pane in snapshot.panes where !excluded.contains(pane.terminal_id) {
        guard prepared[pane.terminal_id] == nil else { throw ConfigurationError("herdr returned duplicate terminal IDs.") }
        let terminal = runtime.makeSession()
        terminal.herdrTerminal = HerdrClient.Terminal(client: client, pane: pane)
        terminal.surfaceContext = GHOSTTY_SURFACE_CONTEXT_SPLIT
        if !restoring, native.windowInheritsFontSize, let surface = session?.surface { terminal.initialFontSize = velokit_surface_font_size(surface) }
        terminal.windowController = self
        prepared[pane.terminal_id] = terminal
        guard let view = terminal.createView() else { throw ConfigurationError("Could not attach the terminal view. Its herdr session is still running.") }
        terminal.chrome = TerminalChrome(view)
        terminal.currentDirectory = pane.cwd
      }
    } catch {
      prepared.values.forEach { $0.close() }
      throw error
    }
    var newest: TerminalSession?
    for workspace in snapshot.workspaces {
      for record in snapshot.tabs where record.workspace_id == workspace.workspace_id {
        for pane in snapshot.panes where pane.tab_id == record.tab_id && !excluded.contains(pane.terminal_id) {
          guard let terminal = prepared.removeValue(forKey: pane.terminal_id) else { continue }
          let localID = owner?.localTabID(pane) ?? record.tab_id
          let space = owner?.spaceForTab(localID)
          let spaceID = space?.id ?? workspace.workspace_id
          if let namespace = namespaces.first(where: { $0.id == spaceID }) {
            if let tab = namespace.tabs.first(where: { $0.herdrID == localID }) {
              tab.panes.append(terminal)
            } else {
              let tab = TerminalTab(terminal); tab.herdrID = localID
              if !restoring, native.newTabPosition == "current", let index = namespace.tabs.firstIndex(where: { $0 === activeTab }) {
                namespace.tabs.insert(tab, at: index + 1)
              } else { namespace.tabs.append(tab) }
            }
          } else {
            let namespace = TerminalNamespace(name: space?.name ?? workspace.label, session: terminal)
            namespace.id = spaceID; namespace.selected.herdrID = localID
            namespaces.append(namespace)
          }
          newest = terminal
        }
      }
    }
    prepared.values.forEach { $0.close() }
    updateHerdrLabels(snapshot)
    if !restoring, let newest { selectTab(newest) }
    workspaceView.present()
  }

  func reconcileHerdr(_ snapshot: HerdrClient.Snapshot, spaces: [WorkspaceState.Namespace], sessions: [String: TerminalSession], client: HerdrClient) {
    let previousPane = session, responder = window?.firstResponder
    let oldTabs = namespaces.flatMap(\.tabs)
    var available = Dictionary(uniqueKeysWithValues: allPanes.compactMap { pane in pane.herdrTerminal.map { ($0.pane.terminal_id, pane) } })
    available.merge(sessions) { _, new in new }
    var rebuilt: [TerminalNamespace] = []
    for space in spaces {
      var tabs: [TerminalTab] = []
      for saved in space.tabs {
        let panes = (saved.panes ?? []).compactMap { record -> TerminalSession? in
          guard let pane = available[record.terminalID] else { return nil }
          if let live = snapshot.panes.first(where: { $0.terminal_id == record.terminalID }) {
            pane.herdrTerminal = .init(client: client, pane: live)
            if pane.connectionSuspended { pane.retryAttachment() }
          }
          pane.windowController = self
          return pane
        }
        guard let first = panes.first else { continue }
        let tab = oldTabs.first { $0.herdrID == saved.id } ?? TerminalTab(first)
        tab.herdrID = saved.id; tab.panes = panes; tab.title = saved.title
        tab.localLayout = saved.layout ?? tab.localLayout
        tab.ensureLayout()
        if !panes.contains(where: { $0 === tab.selected }) { tab.selected = first }
        tabs.append(tab)
      }
      guard let first = tabs.first else { continue }
      let namespace = namespaces.first { $0.id == space.id } ?? TerminalNamespace(name: space.name ?? "Namespace", session: first.selected)
      namespace.id = space.id; namespace.tabs = tabs
      if !tabs.contains(where: { $0 === namespace.selected }) { namespace.selected = first }
      rebuilt.append(namespace)
    }
    namespaces = rebuilt
    guard let first = namespaces.first else { persistenceReady = false; closing = true; window?.close(); return }
    if !namespaces.contains(where: { $0 === activeNamespace }) { activeNamespace = first }
    let selected = previousPane.flatMap { pane in allPanes.contains { $0 === pane } ? pane : nil } ?? activeNamespace.selected.selected
    session = nil; updateHerdrLabels(snapshot); selectTab(selected)
    if previousPane === selected, let responder { window?.makeFirstResponder(responder) }
  }

  func updateHerdrLabels(_ snapshot: HerdrClient.Snapshot) {
    var presentationChanged = false
    let records = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.terminal_id, $0) })
    for pane in allPanes {
      if let terminal = pane.herdrTerminal, let record = records[terminal.pane.terminal_id], terminal.pane != record {
        pane.herdrTerminal = .init(client: terminal.client, pane: record)
        presentationChanged = true
      }
    }
    workspaceView.updateAgents(snapshot)
    let savedTabs = owner?.workspaceState?.namespaces.flatMap(\.tabs)
      .reduce(into: [String: WorkspaceState.Tab]()) { $0[$1.id] = $1 } ?? [:]
    for tab in namespaces.flatMap(\.tabs) {
      if tab.localLayout == nil, let saved = savedTabs[tab.herdrID ?? ""] {
        presentationChanged = presentationChanged || tab.title != saved.title
        tab.localLayout = saved.layout; tab.title = saved.title
      }
      if tab.localLayout == nil, tab.panes.count > 1 { refreshLayoutTree(tab) }
      else { tab.ensureLayout() }
    }
    if presentationChanged { workspaceView.present() }
  }

  func refreshLayoutTree(_ tab: TerminalTab) {
    guard !tab.loadingTree, tab.localLayout == nil, let terminal = tab.selected.herdrTerminal else { return }
    tab.loadingTree = true
    tab.ensureLayout()
    let fallback = tab.localLayout
    terminal.client.perform({ try $0.layoutTree(tabID: terminal.pane.tab_id) }) { [weak self, weak tab] result in
      guard let self, let tab else { return }
      tab.loadingTree = false
      guard !self.closing, tab.localLayout == fallback else { return }
      if case .success(let tree) = result {
        func convert(_ node: HerdrClient.LayoutNode) -> PaneLayout? {
          if let id = node.pane_id, let pane = tab.panes.first(where: { $0.herdrTerminal?.pane.pane_id == id }), let terminal = pane.herdrTerminal { return .terminal(terminal.pane.terminal_id) }
          if let a = node.first.flatMap(convert), let b = node.second.flatMap(convert) { return .split(direction: node.direction ?? "right", ratio: max(0.1, min(0.9, node.ratio ?? 0.5)), first: a, second: b) }
          return nil
        }
        tab.localLayout = convert(tree)
      }
      tab.ensureLayout(); self.workspaceView.needsLayout = true
      self.owner?.scheduleWorkspaceSave(self)
    }
  }

  private func chooseDestination(title: String, labels: [String], complete: @escaping (Int) -> Void) {
    guard !closing, let window, window.attachedSheet == nil, !labels.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "The running terminals will be preserved."
    let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    choices.addItems(withTitles: labels)
    alert.accessoryView = choices
    alert.addButton(withTitle: "Move")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn { complete(choices.indexOfSelectedItem) }
    }
  }

  func chooseConnection(split direction: String? = nil) {
    guard let owner, let window, window.attachedSheet == nil else { return }
    let clients = owner.connections.filter(\.enabled).compactMap { owner.client(for: $0.id) }.filter(\.isEnabled)
    guard !clients.isEmpty else { owner.showConnections(); return }
    let alert = NSAlert()
    alert.messageText = direction == nil ? "New Tab on Connection" : "Split with Connection"
    let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    choices.addItems(withTitles: clients.map(\.endpointLabel))
    if let index = clients.firstIndex(where: { $0 === session?.herdrTerminal?.client }) { choices.selectItem(at: index) }
    alert.accessoryView = choices; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self, clients.indices.contains(choices.indexOfSelectedItem) else { return }
      let client = clients[choices.indexOfSelectedItem]
      if let direction { self.splitPane(direction, using: client) } else { self.newTab(using: client) }
    }
  }

  func chooseTabNamespace() {
    let tab = activeTab
    let destinations = (owner?.windows.flatMap(\.namespaces) ?? namespaces).filter { $0 !== activeNamespace }
    chooseDestination(title: "Move Tab to Namespace", labels: destinations.map(\.name)) { [weak self, weak tab] index in
      guard let self, let tab, destinations.indices.contains(index), let id = destinations[index].id else { return }
      self.moveTab(tab, toNamespace: id)
    }
  }

  func reorderNamespace(_ id: String, to index: Int) {
    guard let old = namespaces.firstIndex(where: { $0.id == id }) else { return }
    let space = namespaces.remove(at: old)
    namespaces.insert(space, at: max(0, min(namespaces.count, index > old ? index - 1 : index)))
    workspaceView.refreshTabs(); owner?.scheduleWorkspaceSave(self)
  }

  func placeTab(id: String, before target: TerminalTab) -> Bool {
    guard let owner, let destination = namespace(for: target.selected),
      let source = owner.windows.first(where: { $0.namespaces.flatMap(\.tabs).contains { $0.herdrID == id } }),
      let tab = source.namespaces.flatMap(\.tabs).first(where: { $0.herdrID == id }), tab !== target else { return false }
    if source.namespace(for: tab.selected) !== destination, let id = destination.id { source.moveTab(tab, toNamespace: id) }
    destination.tabs.removeAll { $0 === tab }
    let index = destination.tabs.firstIndex { $0 === target } ?? destination.tabs.count
    destination.tabs.insert(tab, at: index)
    selectTab(tab); workspaceView.refreshTabs(); owner.scheduleWorkspaceSave(self); return true
  }

  func moveTab(_ tab: TerminalTab, toNamespace id: String) {
    guard let source = namespace(for: tab.selected), let owner,
      let destination = owner.windows.first(where: { $0.namespaces.contains { $0.id == id } }),
      let space = destination.namespaces.first(where: { $0.id == id }), source !== space else { return }
    removeTab(tab, from: source)
    space.tabs.append(tab)
    tab.panes.forEach { $0.windowController = destination }
    reselectAfterRemoval()
    destination.selectTab(tab)
    // Save the destination first so ownership is transferred before pruning the source.
    owner.scheduleWorkspaceSave(destination)
    owner.scheduleWorkspaceSave(self)
    closeIfEmpty()
    refreshTabBars(); destination.refreshTabBars()
  }

  func choosePaneTab() {
    guard let pane = session else { return }
    let tabs = (owner?.windows.flatMap(\.namespaces) ?? namespaces).flatMap { namespace in
      namespace.tabs.filter { $0 !== activeTab }.map { (namespace.name + " / " + $0.displayTitle, $0) }
    }
    chooseDestination(title: "Move Pane to Tab", labels: tabs.map { $0.0 }) { [weak self, weak pane] index in
      guard let self, let pane, tabs.indices.contains(index), let target = tabs[index].1.herdrID else { return }
      self.movePane(pane, toTab: target, targetPane: tabs[index].1.selected.herdrTerminal?.pane.pane_id ?? "")
    }
  }

  func movePane(_ pane: TerminalSession, toTab tabID: String, targetPane: String) {
    guard let source = tab(for: pane), let owner,
      let destination = owner.windows.first(where: { $0.namespaces.flatMap(\.tabs).contains { $0.herdrID == tabID } }),
      let target = destination.namespaces.flatMap(\.tabs).first(where: { $0.herdrID == tabID }), source !== target,
      let id = pane.herdrTerminal?.pane.terminal_id else { return }
    target.ensureLayout()
    let neighbor = target.panes.first { $0.herdrTerminal?.pane.pane_id == targetPane } ?? target.selected
    if let targetID = neighbor.herdrTerminal?.pane.terminal_id { target.localLayout = target.localLayout?.inserting(id, beside: targetID, direction: "right") }
    source.panes.removeAll { $0 === pane }; source.ensureLayout()
    target.panes.append(pane); pane.windowController = destination
    if source.panes.isEmpty {
      if let space = namespaces.first(where: { $0.tabs.contains { $0 === source } }) { removeTab(source, from: space) }
    } else if source.selected === pane { source.selected = source.panes[0] }
    reselectAfterRemoval()
    destination.selectTab(pane)
    owner.scheduleWorkspaceSave(destination); owner.scheduleWorkspaceSave(self)
    closeIfEmpty()
    workspaceView.present(); destination.workspaceView.present()
  }

  func movePaneToNewTab() {
    guard let pane = session, activeTab.panes.count > 1 else { return }
    let source = activeTab
    source.panes.removeAll { $0 === pane }; source.selected = source.panes[0]; source.ensureLayout()
    let tab = TerminalTab(pane); tab.herdrID = "tab-" + UUID().uuidString
    activeNamespace.tabs.append(tab); selectTab(tab); workspaceView.present()
    owner?.scheduleWorkspaceSave(self)
  }

  func equalizePanes() {
    activeTab.ensureLayout(); activeTab.localLayout = activeTab.localLayout?.equalized()
    workspaceView.needsLayout = true; owner?.scheduleWorkspaceSave(self)
  }

  func setSplitRatio(tabID: String, path: [Bool], ratio: Double) {
    guard ratio.isFinite, let tab = namespaces.flatMap(\.tabs).first(where: { $0.herdrID == tabID }) else { return }
    tab.ensureLayout(); tab.localLayout = tab.localLayout?.settingRatio(path: path, ratio: ratio)
    workspaceView.needsLayout = true; owner?.scheduleWorkspaceSave(self)
  }

  func endHerdrTabs(_ targets: [TerminalTab]) {
    guard !closing, owner?.terminating != true else { return }
    if deferMuxAction({ [weak self] in self?.endHerdrTabs(targets) }) { return }
    let targets = targets.filter { tab in namespaces.contains { $0.tabs.contains { $0 === tab } } }
    if owner?.deferClose(targets.flatMap(\.panes), in: self, destroy: true) == true { return }
    for pane in targets.flatMap(\.panes) {
      guard let terminal = pane.herdrTerminal else { continue }
      owner?.endTerminal(terminal)
      closePane(pane, confirm: false, endSession: false)
    }
  }
}

extension TerminalWindowController {
  func splitPane(_ direction: String, from source: TerminalSession? = nil, using chosenClient: HerdrClient? = nil) {
    guard let pane = source ?? session, let terminal = pane.herdrTerminal, let tab = tab(for: pane) else { owner?.showMuxWarning(); return }
    let client = chosenClient ?? terminal.client
    guard client.isEnabled, !closing, window?.attachedSheet == nil else { return }
    if deferMuxAction({ [weak self, weak pane] in if let pane { self?.splitPane(direction, from: pane, using: chosenClient) } }) { return }
    let same = client === terminal.client
    let fallback = client.machine == nil ? pane.settings.workingDirectory.path : nil
    let directory = same && native.splitInheritsDirectory ? pane.currentDirectory ?? terminal.pane.foreground_cwd ?? terminal.pane.cwd ?? fallback : fallback
    let environment = client.shellEnvironment(settings: pane.settings)
    muxBusy = true
    client.perform({ try $0.createPane(workspace: same ? terminal.pane.workspace_id : nil, name: "Terminal", directory: directory, environment: environment) }) { [weak self, weak tab] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, let tab, self.tab(for: pane) === tab else { return }
      do {
        let record = try result.get()
        let added = pane.runtime.makeSession(); added.herdrTerminal = .init(client: client, pane: record)
        if self.native.windowInheritsFontSize, let surface = pane.surface { added.initialFontSize = velokit_surface_font_size(surface) }
        added.currentDirectory = record.cwd; added.windowController = self; added.surfaceContext = GHOSTTY_SURFACE_CONTEXT_SPLIT
        guard let view = added.createView() else { throw ConfigurationError("Could not attach the new terminal; its process remains in herdr.") }
        added.chrome = TerminalChrome(view)
        tab.ensureLayout()
        tab.localLayout = tab.localLayout?.inserting(record.terminal_id, beside: terminal.pane.terminal_id, direction: direction)
        tab.panes.append(added); self.selectTab(added); self.workspaceView.present()
        self.owner?.scheduleWorkspaceSave(self)
      } catch { self.owner?.showMuxError(error) }
    }
  }

  func togglePaneZoom(from source: TerminalSession? = nil) {
    guard let pane = source ?? session, let tab = tab(for: pane), tab.panes.count > 1,
      !closing, window?.attachedSheet == nil else { return }
    tab.zoomed.toggle()
    selectTab(pane)
    workspaceView.present()
    owner?.scheduleWorkspaceSave(self)
  }

  func focusPane(_ direction: String, from source: TerminalSession? = nil) {
    guard let pane = source ?? session, let tab = tab(for: pane),
      let index = tab.panes.firstIndex(where: { $0 === pane }) else { return }
    if direction == "next" || direction == "previous" {
      let step = direction == "next" ? 1 : -1
      selectTab(tab.panes[(index + step + tab.panes.count) % tab.panes.count])
      return
    }
    guard let origin = pane.chrome?.frame else { return }
    let candidates = visiblePanes.filter { candidate in
      guard candidate !== pane, let frame = candidate.chrome?.frame else { return false }
      switch direction {
      case "left": return frame.midX < origin.minX
      case "right": return frame.midX > origin.maxX
      case "up": return frame.midY > origin.maxY
      default: return frame.midY < origin.minY
      }
    }
    if let next = candidates.min(by: {
      let a = $0.chrome!.frame, b = $1.chrome!.frame
      return hypot(a.midX - origin.midX, a.midY - origin.midY) < hypot(b.midX - origin.midX, b.midY - origin.midY)
    }) { selectTab(next) }
  }

  func resizePane(_ direction: String, amount: Double = 0.05, from source: TerminalSession? = nil) {
    guard let pane = source ?? session, let tab = tab(for: pane), let id = pane.herdrTerminal?.pane.terminal_id else { return }
    tab.ensureLayout(); tab.localLayout = tab.localLayout?.resized(terminal: id, direction: direction, amount: amount)
    workspaceView.needsLayout = true; owner?.scheduleWorkspaceSave(self)
  }

  func closePane(_ source: TerminalSession? = nil, confirm: Bool = true, endSession: Bool = true) {
    guard let pane = source ?? session, let tab = tab(for: pane),
      !closing, window?.attachedSheet == nil else { return }
    if tab.panes.count == 1 { closeTab(pane, confirm: confirm, endSession: endSession); return }
    if confirm {
      confirmEnding([pane]) { [weak self, weak pane] in
        if let pane { self?.closePane(pane, confirm: false, endSession: endSession) }
      }
      return
    }
    if endSession, owner?.deferClose([pane], in: self, destroy: true) == true { return }
    if endSession, let terminal = pane.herdrTerminal {
      if deferMuxAction({ [weak self, weak pane] in if let pane { self?.closePane(pane, confirm: false) } }) { return }
      muxBusy = true
      terminal.client.perform({ client in
        _ = try client.request(["pane", "close", terminal.pane.pane_id])
        return try client.snapshot()
      }) { [weak self, weak pane] result in
        guard let self else { return }
        self.muxBusy = false
        guard !self.closing, self.owner?.terminating != true else { return }
        switch result {
        case .success(let snapshot):
          if let pane { self.closePane(pane, confirm: false, endSession: false) }
          self.updateHerdrLabels(snapshot)
        case .failure(let error): self.owner?.showMuxError(error)
        }
      }
      return
    }
    let index = tab.panes.firstIndex { $0 === pane }!
    tab.panes.remove(at: index)
    tab.ensureLayout()
    if tab.selected === pane { tab.selected = tab.panes[min(index, tab.panes.count - 1)] }
    if session === pane { selectTab(tab.selected) }
    pane.close()
    workspaceView.present()
    owner?.scheduleWorkspaceSave(self)
    if let client = tab.selected.herdrTerminal?.client {
      client.perform({ try $0.snapshot() }) { [weak self] result in
        guard let self, !self.closing else { return }
        if case .success(let snapshot) = result { self.updateHerdrLabels(snapshot) }
      }
    }
  }
}


extension TerminalWindowController {
  func restoreWorkspaceState(_ state: WorkspaceState) {
    let namespaceOrder = state.namespaces.map(\.id)
    namespaces.sort { (namespaceOrder.firstIndex(of: $0.id ?? "") ?? Int.max) < (namespaceOrder.firstIndex(of: $1.id ?? "") ?? Int.max) }
    for namespace in namespaces {
      guard let saved = state.namespaces.first(where: { $0.id == namespace.id }) else { continue }
      if let name = saved.name { namespace.name = name }
      let tabOrder = saved.tabs.map(\.id)
      namespace.tabs.sort { (tabOrder.firstIndex(of: $0.herdrID ?? "") ?? Int.max) < (tabOrder.firstIndex(of: $1.herdrID ?? "") ?? Int.max) }
      for tab in namespace.tabs {
        let savedTab = saved.tabs.first { $0.id == tab.herdrID }
        tab.zoomed = savedTab?.zoomed == true
        tab.localLayout = savedTab?.layout ?? tab.localLayout
        tab.title = savedTab?.title ?? tab.title
        if let paneID = savedTab?.selectedPaneID,
          let pane = tab.panes.first(where: { $0.herdrTerminal?.pane.pane_id == paneID }) { tab.selected = pane }
      }
      if let tab = namespace.tabs.first(where: { $0.herdrID == saved.selectedTabID }) { namespace.selected = tab }
    }
    if let sidebar = state.sidebar { workspaceView.restoreSidebarState(sidebar) }
    let selected = namespaces.first { $0.id == state.selectedNamespaceID } ?? namespaces.first
    if let selected { selectTab(selected.selected) }
    if let saved = state.windows?.first(where: { $0.id == workspaceWindowID }),
      let first = namespaces.flatMap(\.tabs).first(where: { $0.herdrID == saved.primaryTabID }),
      let second = namespaces.flatMap(\.tabs).first(where: { $0.herdrID == saved.companionTabID }), first !== second {
      comparisonDismissed = false
      primaryTab = first; companionTab = second
      companionRatio = max(0.1, min(0.9, saved.companionRatio ?? 0.5))
      if let focused = allPanes.first(where: { $0.herdrTerminal?.pane.terminal_id == saved.focusedTerminalID }) { selectTab(focused) }
    }
    workspaceView.present()
  }
}


extension AppDelegate {
  func connectionFailed(_ client: HerdrClient, error: Error) {
    guard client.isEnabled else { return }
    let status = ConnectionStatus.failed(error.localizedDescription)
    guard connectionStatus[client.endpointID] != status else { return }
    connectionStatus[client.endpointID] = status
    connectionsWindow?.refresh()
    for controller in windows where !controller.closing && controller.allPanes.contains(where: { $0.herdrTerminal?.client === client }) {
      controller.workspaceView.refreshTabs()
    }
  }

  func client(for id: String) -> HerdrClient? {
    if herdr?.endpointID == id { return herdr }
    return connectionCoordinator.clients.values.first { $0.endpointID == id }
  }

  func clientIsAvailable(_ id: String) -> Bool {
    client(for: id)?.isEnabled == true && connectionStatus[id] == .connected
  }

  func loadConnections(reload: Bool = false) {
    guard (!connectionCoordinator.loaded || reload), let executable = herdr?.executable else { return }
    connectionCoordinator.loaded = true
    let next = runtime?.settings.connections ?? [.local]
    let previous = connections
    connections = next
    for client in [herdr].compactMap({ $0 }) + Array(connectionCoordinator.clients.values) where !next.contains(where: { $0.id == client.endpointID && $0.enabled }) {
      suspendConnection(client)
    }
    for profile in next {
      if let old = client(for: profile.id), !old.isPlaceholder,
        old.machine?.target != profile.target || old.sessionName != profile.session {
        // Saved terminal references belong to their original server, even when offline.
        suspendConnection(old)
        connectionStatus[profile.id] = .failed("Host/session changed. Use a new connection id to retain the original terminals.")
        continue
      }
      let existing = client(for: profile.id)
      let client = existing?.isPlaceholder == true ? makeClient(profile, executable: executable) : existing ?? makeClient(profile, executable: executable)
      client.updateLabel(profile.label)
      if let existing, existing !== client {
        for pane in windows.flatMap(\.allPanes) + closeHistory.closed.flatMap(\.panes) where pane.herdrTerminal?.client === existing {
          if let record = pane.herdrTerminal?.pane { pane.herdrTerminal = .init(client: client, pane: record) }
        }
      }
      if client !== herdr { connectionCoordinator.clients[profile.id] = client }
      let changed = client.isEnabled != profile.enabled
      if changed { client.setEnabled(profile.enabled) }
      if !profile.enabled { suspendConnection(client) }
      else if connectionStatus[profile.id] == nil || changed { connectionStatus[profile.id] = .notConnected }
      if reload, profile.enabled, changed || !previous.contains(where: { $0.id == profile.id }) { connectEndpoint(client) }
    }
    registerMissingConnections()
    restoreUnavailableTabs()
    connectionsWindow?.refresh()
  }

  func registerMissingConnections() {
    guard let executable = herdr?.executable else { return }
    for id in Set(workspaceState?.namespaces.flatMap(\.tabs).flatMap { tab in tab.panes?.map(\.connectionID) ?? [tab.connectionID] } ?? []) where client(for: id) == nil {
      let missing = HerdrClient(executable: executable, sessionName: "missing", identity: id, label: "Missing: " + id)
      missing.isPlaceholder = true
      missing.setEnabled(false); connectionCoordinator.clients[id] = missing
      connectionStatus[id] = .failed("Connection is missing from config.toml")
    }
  }

  private func suspendConnection(_ client: HerdrClient) {
    client.setEnabled(false)
    connectionCoordinator.timers.removeValue(forKey: client.endpointID)?.invalidate()
    connectionStatus[client.endpointID] = .disabled
    for pane in windows.flatMap(\.allPanes) + closeHistory.closed.flatMap(\.panes) where pane.herdrTerminal?.client === client {
      pane.suspendConnection(client.endpointLabel + " · Disabled")
    }
    windows.forEach { $0.workspaceView.present(); scheduleWorkspaceSave($0) }
  }

  private func makeClient(_ profile: HerdrConnection, executable: URL) -> HerdrClient {
    let machine = profile.target.map { HerdrClient.Machine(id: profile.id.hasPrefix("ssh:") ? String(profile.id.dropFirst(4)) : profile.id,
      label: profile.label, target: $0, session: profile.session) }
    return HerdrClient(executable: executable, sessionName: profile.session, machine: machine, identity: profile.id, label: profile.label)
  }

  @objc func showConnections() {
    loadConnections()
    if connectionsWindow == nil { connectionsWindow = ConnectionsWindow(owner: self) }
    connectionsWindow?.showWindow(nil); connectionsWindow?.window?.makeKeyAndOrderFront(nil)
  }

  func restoreConnections(includingPrimary: Bool = false) {
    guard !connectionCoordinator.restored else { return }
    connectionCoordinator.restored = true
    let clients = Array(connectionCoordinator.clients.values) + (includingPrimary ? [herdr].compactMap { $0 } : [])
    connectRemaining(clients.filter(\.isEnabled).sorted { $0.endpointID < $1.endpointID })
  }

  private func connectRemaining(_ clients: [HerdrClient]) {
    guard let client = clients.first, !terminating else { return }
    connectEndpoint(client) { [weak self] in self?.connectRemaining(Array(clients.dropFirst())) }
  }

  func restoreUnavailableTabs() {
    guard let state = workspaceState, let runtime else { return }
    let wasRestoring = restoringWorkspace
    restoringWorkspace = true
    defer { restoringWorkspace = wasRestoring }
    // Terminals already shown, hidden or retained must not be recreated. Grows as panes are added.
    var unavailable = attachedTerminalIDs.union(hiddenTerminalIDs).union(retainedTerminalIDs)
    for group in state.windows ?? [] {
      var controller = windows.first { $0.workspaceWindowID == group.id }
      for saved in state.namespaces where group.namespaceIDs.contains(saved.id) {
        for tab in saved.tabs {
          let panes = suspendedPanes(for: tab, excluding: unavailable, runtime: runtime)
          guard let first = panes.first else { continue }
          if controller == nil {
            let created = TerminalWindowController(session: first, owner: self)
            created.workspaceWindowID = group.id; created.activeNamespace.id = saved.id; created.activeNamespace.name = saved.name ?? "Namespace"; created.activeTab.herdrID = tab.id
            windows.append(created); created.openWindow(restoring: true)
            if let frame = group.frame { created.window?.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: true) }
            created.persistenceReady = workspacePersistenceEnabled; controller = created
          }
          guard let controller else { continue }
          merge(panes: panes, of: tab, in: saved, into: controller, first: first)
          unavailable.formUnion(panes.compactMap { $0.herdrTerminal?.pane.terminal_id })
        }
      }
      if let controller {
        var selection = state; selection.selectedNamespaceID = group.selectedNamespaceID; selection.sidebar = group.sidebar
        controller.restoreWorkspaceState(selection)
        controller.persistedNamespaceIDs = Set(controller.namespaces.compactMap(\.id))
      }
    }
  }

  /// Suspended placeholder panes for the saved records whose connection is unavailable.
  private func suspendedPanes(for tab: WorkspaceState.Tab, excluding unavailable: Set<String>, runtime: TerminalRuntime) -> [TerminalSession] {
    var panes: [TerminalSession] = []
    for record in tab.panes ?? [] where !unavailable.contains(record.terminalID) {
      guard let client = client(for: record.connectionID), !clientIsAvailable(record.connectionID) else { continue }
      let pane = runtime.makeSession()
      pane.herdrTerminal = .init(client: client, pane: .init(pane_id: record.id, terminal_id: record.terminalID, workspace_id: record.workspaceID, tab_id: record.tabID ?? tab.id, cwd: record.cwd))
      pane.currentDirectory = record.cwd; pane.tabTitle = tab.title
      pane.suspendConnection(client.endpointLabel + (client.isEnabled ? " · Disconnected" : " · Disabled"))
      panes.append(pane)
    }
    return panes
  }

  private func merge(panes: [TerminalSession], of tab: WorkspaceState.Tab, in saved: WorkspaceState.Namespace, into controller: TerminalWindowController, first: TerminalSession) {
    let space = controller.namespaces.first { $0.id == saved.id } ?? TerminalNamespace(name: saved.name ?? "Namespace", session: first)
    space.id = saved.id
    if !controller.namespaces.contains(where: { $0 === space }) { controller.namespaces.append(space) }
    let restored = space.tabs.first { $0.herdrID == tab.id } ?? TerminalTab(first)
    restored.herdrID = tab.id
    restored.panes += panes.filter { pane in !restored.panes.contains { $0 === pane } }; restored.title = tab.title
    restored.localLayout = tab.layout
    if !space.tabs.contains(where: { $0 === restored }) { space.tabs.append(restored) }
    panes.forEach { $0.windowController = controller }
  }
}


extension TerminalWindowController {
  func hideClosed(_ operation: ClosedTerminals) {
    if !operation.destroy { owner?.scheduleWorkspaceSave(self); owner?.flushWorkspaceSave(); persistenceReady = false }
    for slot in operation.slots {
      slot.tab.panes.removeAll { $0 === slot.pane }
      slot.pane.chrome?.removeFromSuperview()
      if let surface = slot.pane.surface { velokit_surface_set_occlusion(surface, false) }
      slot.pane.windowController = nil
      if slot.tab.selected === slot.pane, let first = slot.tab.panes.first { slot.tab.selected = first }
    }
    for namespace in namespaces {
      namespace.tabs.removeAll { $0.panes.isEmpty }
      if !namespace.tabs.contains(where: { $0 === namespace.selected }), let first = namespace.tabs.first { namespace.selected = first }
    }
    namespaces.removeAll { $0.tabs.isEmpty }
    if let next = allPanes.first {
      if !allPanes.contains(where: { $0 === session }) { selectTab(next) }
      workspaceView.present()
      owner?.scheduleWorkspaceSave(self)
    } else { closing = true; window?.close() }
  }

  func restoreClosed(_ operation: ClosedTerminals) {
    if window == nil { namespaces = [] }
    for slot in operation.slots {
      let namespace = namespaces.first { $0 === slot.namespace || ($0.id != nil && $0.id == slot.namespace.id) } ?? slot.namespace
      if !namespaces.contains(where: { $0 === namespace }) { namespaces.insert(namespace, at: min(slot.namespaceIndex, namespaces.count)) }
      let tab = namespace.tabs.first { $0 === slot.tab || ($0.herdrID != nil && $0.herdrID == slot.tab.herdrID) } ?? slot.tab
      if !namespace.tabs.contains(where: { $0 === tab }) { namespace.tabs.insert(tab, at: min(slot.tabIndex, namespace.tabs.count)) }
      if !tab.panes.contains(where: { $0 === slot.pane }) { tab.panes.insert(slot.pane, at: min(slot.paneIndex, tab.panes.count)) }
      if let layout = slot.layout { tab.localLayout = layout }; tab.ensureLayout()
      slot.pane.windowController = self
    }
    closing = false
  }
}


extension TerminalWindowController {
  func moveTabToNewWindow() {
    guard !closing, let owner else { return }
    let tab = activeTab, source = activeNamespace
    removeTab(tab, from: source)
    let destination = TerminalWindowController(session: tab.selected, owner: owner)
    destination.activeNamespace.id = "space:" + UUID().uuidString
    destination.activeNamespace.name = source.name
    destination.activeNamespace.tabs = [tab]; destination.activeNamespace.selected = tab
    tab.panes.forEach { $0.windowController = destination }
    owner.windows.append(destination); destination.openWindow(cascadingFrom: window)
    destination.persistenceReady = persistenceReady || owner.workspacePersistenceEnabled
    destination.selectTab(tab)
    reselectAfterRemoval()
    owner.scheduleWorkspaceSave(destination); owner.scheduleWorkspaceSave(self)
    closeIfEmpty()
  }

  /// Remove a tab that moved elsewhere, keeping its namespace's selection valid and dropping the namespace once empty.
  private func removeTab(_ tab: TerminalTab, from space: TerminalNamespace) {
    space.tabs.removeAll { $0 === tab }
    if let first = space.tabs.first { if space.selected === tab { space.selected = first } }
    else { namespaces.removeAll { $0 === space } }
  }

  /// After a removal, fall back to the first namespace if the active one was dropped, and reselect its tab.
  private func reselectAfterRemoval() {
    guard let first = namespaces.first else { return }
    if !namespaces.contains(where: { $0 === activeNamespace }) { activeNamespace = first }
    selectTab(activeNamespace.selected)
  }

  /// Close the window once its last namespace has moved elsewhere, without saving it as closed.
  private func closeIfEmpty() {
    guard namespaces.isEmpty else { return }
    persistenceReady = false; closing = true; window?.close()
  }

  func toggleDecorations() {
    guard let window, !window.styleMask.contains(.fullScreen), normalFrame == nil else { return }
    decorationsOverride = !window.styleMask.contains(.titled)
    applyWindowSettings()
  }

  func toggleTabOverview() {
    if palette?.isVisible == true { palette?.close() }
    else { showWorkspaceSearch() }
  }
}

extension AppDelegate {
  var workspacePersistenceEnabled: Bool { workspacePersistence.store != nil }
  var attachedTerminalIDs: Set<String> { Set(windows.flatMap(\.allPanes).compactMap { $0.herdrTerminal?.pane.terminal_id }) }
  fileprivate func pane(forTerminal id: String) -> TerminalSession? { windows.flatMap(\.allPanes).first { $0.herdrTerminal?.pane.terminal_id == id } }
  func uniqueByEndpoint<S: Sequence>(_ clients: S) -> [String: HerdrClient] where S.Element == HerdrClient {
    clients.reduce(into: [String: HerdrClient]()) { $0[$1.endpointID] = $1 }
  }
  func scheduleExpiry(_ operation: ClosedTerminals, after interval: TimeInterval) {
    operation.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self, weak operation] _ in
      guard let self, let operation else { return }
      self.expireClose(operation)
    }
  }
}

extension WorkspaceState.Tab {
  /// Whether this saved tab holds a live herdr pane, by tab ID or by one of its terminals.
  func matches(_ pane: HerdrClient.Pane) -> Bool {
    id == pane.tab_id || panes?.contains { $0.terminalID == pane.terminal_id } == true
  }
}
