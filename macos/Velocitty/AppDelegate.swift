// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon
import Foundation
import UserNotifications
import VeloKit
import VelocittyConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  let discoverHerdr: () -> URL?
  init(discoverHerdr: @escaping () -> URL? = HerdrClient.discover) {
    self.discoverHerdr = discoverHerdr
    super.init()
  }

  let secureInputOwner = SecureInputOwner()
  let fullscreenPresentation = FullscreenPresentation()
  var windows: [TerminalWindowController] = []
  // Test sessions do not read or overwrite the user's workspace file.
  var workspaceStateURL: URL?
  private var workspaceStore: WorkspaceStateStore?
  private var workspaceState: WorkspaceState?
  private var workspaceLoadAttempted = false
  private var restoringWorkspace = false
  private var synchronizingWorkspace = false
  private var eventRefresh: Timer?
  private var eventRefreshRunning = false
  private var workspaceNeedsSave = false
  private var workspaceSaveTimer: Timer?

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
  var terminating = false
  var herdr: HerdrClient?
  var muxOpening = false
  var muxError: String?


  var activeWindow: TerminalWindowController? {
    windows.first { $0.window === NSApp.keyWindow }
      ?? windows.first { $0.window === NSApp.mainWindow }
      ?? focusedWindow ?? windows.last
  }
  var native: NativeSettings { NativeSettings(config: runtime?.config) }

  func applicationWillFinishLaunching(_ notification: Notification) {
    herdr = discoverHerdr().map { HerdrClient(executable: $0) }
    do {
      runtime = try TerminalRuntime(settings: AppConfiguration.load())
      updateRestorationPolicy()
    } catch { NSLog("Could not prepare window restoration: %@", error.localizedDescription) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
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
    if native.initialWindow && windows.isEmpty { newWindow() }
    if herdr == nil { showMuxWarning() }
    if !pendingFiles.isEmpty && !muxOpening {
      if !insertFiles(pendingFiles) { NSLog("Could not insert queued files.") }
      pendingFiles.removeAll()
    }
    scheduleQuitIfNeeded()
    if native.hiddenPolicy == "always" { NSApp.hide(nil) }
    showConfigurationDiagnostics()
  }

  @objc func newWindow() {
    let customCommand = runtime?.settings.options.contains {
      ["command", "initial-command"].contains($0.key) && !$0.value.isEmpty
    } == true
    if let herdr, !customCommand { openHerdrWindow(using: herdr); return }
    newLocalWindow()
  }

  func newLocalWindow() {
    quitTimer?.invalidate()
    quitTimer = nil
    do {
      if runtime == nil { runtime = try TerminalRuntime(settings: AppConfiguration.load()) }
      guard let runtime else { return }
      let session = runtime.makeSession()
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

  // Reopening from the Dock presents an existing terminal when possible.
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
    // Confirm every terminal before closing any, so cancelling Quit preserves all windows.
    let closingWindows = windows
    for controller in closingWindows where !controller.confirmClose() { return .terminateCancel }
    terminating = true
    pendingFiles.removeAll()
    quitTimer?.invalidate()
    // Leave windows registered while AppKit captures their restorable state.
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    secureInputOwner.update(wanted: false)
    fullscreenPresentation.update(nil)
    flushWorkspaceSave()
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
    if runtime == nil || muxOpening || (windows.isEmpty && herdr != nil) {
      pendingFiles.append(contentsOf: filenames)
      if runtime != nil && !muxOpening { newWindow() }
      sender.reply(toOpenOrPrint: .success)
      return // Accepted; insertion happens once a destination exists.
    }
    sender.reply(toOpenOrPrint: insertFiles(filenames) ? .success : .failure)
  }

  func insertFiles(_ filenames: [String]) -> Bool {
    guard !terminating else { return false }
    openWindow()
    guard let surface = activeWindow?.session?.view?.surface else { return false }
    let text = ShellInput.paths(filenames)
    return text.withCString { velokit_surface_paste(surface, $0, UInt(text.utf8.count)) }
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
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: scroll.contentView.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.string = diagnostics.joined(separator: "\n\n")
    text.textContainerInset = NSSize(width: 6, height: 6)
    text.isVerticallyResizable = true
    text.maxSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    scroll.documentView = text
    alert.accessoryView = scroll
    alert.addButton(withTitle: "OK")
    if let window = activeWindow?.window, window.attachedSheet == nil {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

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

  func installMainMenu() {
    let mainMenu = NSMenu()

    let appMenu = NSMenu(title: "Velocitty")
    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let aboutItem = appMenu.addItem(
      withTitle: "About Velocitty",
      action: #selector(showAboutPanel(_:)),
      keyEquivalent: "")
    aboutItem.target = self
    appMenu.addItem(.separator())
    let reloadItem = appMenu.addItem(
      withTitle: "Reload Configuration",
      action: #selector(reloadConfiguration(_:)),
      keyEquivalent: "r")
    reloadItem.keyEquivalentModifierMask = [.command, .shift]
    reloadItem.target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide Velocitty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
      withTitle: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Velocitty", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    ).target = NSApp

    let terminalMenu = NSMenu(title: "Terminal")
    let terminalMenuItem = NSMenuItem()
    terminalMenuItem.submenu = terminalMenu
    mainMenu.addItem(terminalMenuItem)
    terminalMenu.addItem(
      withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n"
    ).target = self
    terminalMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t").target = self
    terminalMenu.addItem(withTitle: "Close Pane", action: #selector(closePane), keyEquivalent: "w").target = self
    terminalMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Previous Tab", action: #selector(previousTab), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Move Tab to Namespace…", action: #selector(moveTabToNamespace), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Move Pane to Tab…", action: #selector(movePaneToTab), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Move Pane to New Tab", action: #selector(detachPaneToTab), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Move Tab Left", action: #selector(moveTabLeft), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Move Tab Right", action: #selector(moveTabRight), keyEquivalent: "").target = self
    terminalMenu.addItem(.separator())
    terminalMenu.addItem(
      withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w"
    ).target = self

    terminalMenu.addItem(.separator())
    terminalMenu.addItem(withTitle: "Split Vertically", action: #selector(splitVertical), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Split Horizontally", action: #selector(splitHorizontal), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Equalize Panes", action: #selector(equalizePanes), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Zoom Pane", action: #selector(zoomPane), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Next Pane", action: #selector(nextPane), keyEquivalent: "").target = self
    terminalMenu.addItem(withTitle: "Previous Pane", action: #selector(previousPane), keyEquivalent: "").target = self
    for (index, direction) in ["Left", "Right", "Up", "Down"].enumerated() {
      let item = terminalMenu.addItem(withTitle: "Resize Pane \(direction)", action: #selector(resizePane(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
    }

    let namespaceMenu = NSMenu(title: "Namespace")
    let namespaceMenuItem = NSMenuItem()
    namespaceMenuItem.submenu = namespaceMenu
    mainMenu.addItem(namespaceMenuItem)
    namespaceMenu.addItem(withTitle: "New Namespace", action: #selector(newNamespace), keyEquivalent: "").target = self
    namespaceMenu.addItem(withTitle: "Rename Namespace…", action: #selector(editNamespace), keyEquivalent: "").target = self
    namespaceMenu.addItem(withTitle: "Close Namespace", action: #selector(closeNamespace), keyEquivalent: "").target = self

    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem()
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)
    editMenu.addItem(
      withTitle: "Copy", action: #selector(TerminalView.copyMenuItem(_:)), keyEquivalent: "c")
    editMenu.addItem(
      withTitle: "Paste", action: #selector(TerminalView.pasteMenuItem(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All",
      action: #selector(TerminalView.selectAllMenuItem(_:)),
      keyEquivalent: "a")

    editMenu.addItem(.separator())
    let find = editMenu.addItem(
      withTitle: "Find…", action: #selector(findTerminal), keyEquivalent: "f")
    find.target = self
    let next = editMenu.addItem(
      withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
    next.target = self
    let previous = editMenu.addItem(
      withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "g")
    previous.keyEquivalentModifierMask = [.command, .shift]
    previous.target = self

    let commands = editMenu.addItem(
      withTitle: "Command Palette…", action: #selector(showCommands), keyEquivalent: "p")
    commands.keyEquivalentModifierMask = [.command, .shift]
    commands.target = self
    let windowMenu = NSMenu(title: "Window")
    let windowMenuItem = NSMenuItem()
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)
    windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

    NSApp.mainMenu = mainMenu
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
        var trigger = ghostty_input_trigger_s()
        guard action.withCString({ velokit_config_trigger(config, $0, &trigger) }) else { continue }
        if trigger.tag == GHOSTTY_TRIGGER_UNICODE, let scalar = UnicodeScalar(trigger.key.unicode) {
          item.keyEquivalent = String(scalar)
        } else if trigger.tag == GHOSTTY_TRIGGER_PHYSICAL {
          let code = velokit_keycode_for_key(trigger.key.physical)
          // Menu equivalents use the active keyboard layout, not US-only key labels.
          item.keyEquivalent = GlobalShortcuts.character(for: code) ?? ""
        }
        var flags: NSEvent.ModifierFlags = []
        let raw = trigger.mods.rawValue
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
  var layout: HerdrClient.Layout?
  var zoomed = false
  var layoutTree: HerdrClient.LayoutNode?
  var treeLayout: HerdrClient.Layout?
  var loadingTree = false
  var displayTitle: String { title ?? selected.terminalTitle }
  var hasBell: Bool { panes.contains { $0.hasBell } }
  let herdrID: String?

  init(_ pane: TerminalSession) {
    herdrID = pane.herdrTerminal?.pane.tab_id
    panes = [pane]
    selected = pane
    title = pane.tabTitle
  }
}

final class TerminalNamespace: NSObject {
  var name: String
  var herdrID: String?
  var subtitle = ""
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

final class TerminalWindowController: NSObject, NSWindowDelegate {
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
  private(set) var namespaces: [TerminalNamespace]
  private(set) var activeNamespace: TerminalNamespace
  private(set) var tabs: [TerminalTab] {
    get { activeNamespace.tabs }
    set { activeNamespace.tabs = newValue }
  }
  var activeTab: TerminalTab { activeNamespace.selected }
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
    // Until workspace restoration lands, do not silently restore only one tab.
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
    if normalFrame != nil || native.windowDecoration == "none" || titlebar == "hidden" {
      window.styleMask.remove(.titled)
    } else {
      window.styleMask.insert(.titled)
    }
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
    let background: NSColor? = nil
    if window.styleMask.contains(.titled) && !family.isEmpty {
      let accessory = NSTitlebarAccessoryViewController()
      let label = NSTextField(labelWithString: window.title)
      label.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
      label.alignment = .center
      label.font = NSFont(name: family, size: 13) ?? .systemFont(ofSize: 13)
      if let foreground { label.textColor = foreground }
      if let background {
        label.drawsBackground = true
        label.backgroundColor = background
      }
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

  func windowShouldClose(_ sender: NSWindow) -> Bool { closing || confirmClose() }

  func windowWillClose(_ notification: Notification) {
    owner?.scheduleWorkspaceSave(self)
    owner?.flushWorkspaceSave()
    persistenceReady = false
    pendingMuxActions.removeAll()
    passwordInput = false
    manualSecureInput = false
    readonly = false
    updateSecureInput(forceOff: true)
    clearProgress()
    for tab in allPanes { tab.close() }
    for namespace in namespaces { namespace.tabs.removeAll() }
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
    let displayed = (hasBell && native.bellFeatures & 8 != 0 ? "● " : "") + (windowTitleOverride ?? activeTab.displayTitle)
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
    for pane in activeTab.panes {
      if let surface = pane.surface { velokit_surface_set_occlusion(surface, window.occlusionState.contains(.visible)) }
    }
  }
  func windowDidEndLiveResize(_ notification: Notification) {
    window?.invalidateRestorableState()
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
    if features & 1 != 0 { NSSound.beep() }
    if features & 2 != 0 {
      let path = native.bellAudioPath
      bellSound =
        path.isEmpty ? NSSound(named: "Glass") : NSSound(contentsOfFile: path, byReference: true)
      bellSound?.volume = Float(native.bellAudioVolume)
      bellSound?.play()
    }
    if (!NSApp.isActive || window?.isKeyWindow != true || session !== tab) && features & 4 != 0 {
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
    chrome?.layer?.borderWidth = hasBell && native.bellFeatures & 16 != 0 ? 3 : 0
  }

  func notify(title: String, body: String) {
    // OSC notifications are filtered by the engine. Command-finish notifications
    // have their own policy and must not be disabled by that OSC setting.
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      let deliver = {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
    if actions & 1 != 0 { ringBell(from: tab) }
    if actions & 2 != 0 {
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
  func newTab(inNewNamespace: Bool = false) {
    guard let session, let client = session.herdrTerminal?.client else { owner?.showMuxWarning(); return }
    guard let window, window.attachedSheet == nil, !closing else { return }
    if deferMuxAction({ [weak self] in self?.newTab(inNewNamespace: inNewNamespace) }) { return }
    let workspace = inNewNamespace ? nil : activeNamespace.herdrID
    let name = "Namespace \(namespaces.count + 1)"
    let directory = native.tabInheritsDirectory ? currentDirectory ?? session.settings.workingDirectory.path
      : session.settings.workingDirectory.path
    let existing = Set((owner?.windows.flatMap(\.allPanes) ?? allPanes).compactMap { $0.herdrTerminal?.pane.terminal_id })
    let shellEnvironment = client.shellEnvironment(settings: session.settings)
    muxBusy = true
    client.perform({ try $0.create(workspace: workspace, name: name, directory: directory, environment: shellEnvironment) }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, self.window != nil, self.owner?.terminating != true else { return }
      do {
        let snapshot = try result.get()
        try self.addHerdrTerminals(snapshot, excluding: existing)
      } catch { self.owner?.showMuxError(error) }
    }
  }

  func selectTab(_ tab: TerminalTab) { selectTab(tab.selected) }

  // Selecting a pane also selects its containing tab and namespace.
  func selectTab(_ pane: TerminalSession) {
    guard let namespace = namespace(for: pane), let tab = tab(for: pane), pane.surface != nil,
      let window, window.attachedSheet == nil, !closing else { return }
    if session !== pane {
      palette?.close()
      updateSecureInput(forceOff: true)
      session?.view?.updateFocus(forceOff: true)
      activeNamespace = namespace
      namespace.selected = tab
      if tab.selected !== pane { tab.zoomed = false }
      tab.selected = pane
      session = pane
      workspaceView.present()
      applyWindowSettings()
      setTitle(pane.terminalTitle)
      applySizeLimit(for: pane)
    }
    for terminal in allPanes {
      if let surface = terminal.surface {
        velokit_surface_set_occlusion(surface,
          tab.panes.contains { $0 === terminal } && (!tab.zoomed || terminal === tab.selected) && window.occlusionState.contains(.visible))
      }
    }
    if native.windowStepResize, tab.panes.count == 1, let surface = pane.surface {
      let size = velokit_surface_size(surface)
      window.contentResizeIncrements = NSSize(width: max(1, CGFloat(size.cell_width_px) / window.backingScaleFactor),
        height: max(1, CGFloat(size.cell_height_px) / window.backingScaleFactor))
    } else { window.contentResizeIncrements = NSSize(width: 1, height: 1) }
    refreshTabBars()
    if window.firstResponder !== pane.view { window.makeFirstResponder(pane.view) }
    pane.view?.updateFocus()
    updateSecureInput()
    owner?.updateMenuShortcuts()
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
      guard let terminal = tab.herdrTerminal else { return }
      terminal.client.perform({ _ = try $0.request(["tab", "rename", terminal.pane.tab_id, value]) }) { [weak self, weak tab] result in
        guard let self, let tab, !self.closing, self.owner?.terminating != true else { return }
        switch result {
        case .success:
          self.tab(for: tab)?.title = value.isEmpty ? nil : value
          for pane in self.tab(for: tab)?.panes ?? [] { pane.tabTitle = value.isEmpty ? nil : value }
          self.tabMetadataChanged(tab)
        case .failure(let error): self.owner?.showMuxError(error)
        }
      }
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
  }

  func refreshTabBars() {
    workspaceView.refreshTabs()
  }

  func applySizeLimit(for tab: TerminalSession) {
    guard session === tab, let window, let limit = tab.sizeLimit else { return }
    if activeTab.panes.count > 1 {
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
      guard let client = self.session?.herdrTerminal?.client, let id = namespace.herdrID else { return }
      let name = value.isEmpty ? namespace.name : value
      let subtitle = namespace.subtitle
      client.perform({ try $0.rename(workspace: id, name: name, subtitle: subtitle) }) { [weak self] result in
        guard let self, !self.closing, self.owner?.terminating != true else { return }
        switch result {
        case .success: namespace.name = name; namespace.subtitle = subtitle; self.refreshTabBars()
        case .failure(let error): self.owner?.showMuxError(error)
        }
      }
    }
    window.attachedSheet?.makeFirstResponder(name)
  }
}

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

  func openHerdrWindow(using client: HerdrClient) {
    guard !muxOpening, !terminating, let runtime else { return }
    muxOpening = true
    quitTimer?.invalidate()
    let attached = Set(windows.flatMap(\.allPanes).compactMap { $0.herdrTerminal?.pane.terminal_id })
    let directory = runtime.settings.workingDirectory
    let shellEnvironment = client.shellEnvironment(settings: runtime.settings)
    client.perform({ client -> HerdrClient.Snapshot in
      let snapshot = try client.connect(directory: directory)
      if snapshot.panes.contains(where: { !attached.contains($0.terminal_id) }) { return snapshot }
      return try client.create(workspace: nil, name: "Default", directory: directory.path, environment: shellEnvironment)
    }) { [weak self] result in
      guard let self else { return }
      self.muxOpening = false
      guard !self.terminating else { return }
      defer {
        if !self.pendingFiles.isEmpty {
          if !self.insertFiles(self.pendingFiles) { NSLog("Could not insert queued files.") }
          self.pendingFiles.removeAll()
        }
      }
      do {
        let snapshot = try result.get()
        self.loadWorkspaceState(for: client)
        let live = snapshot.workspaces.map { workspace in
          WorkspaceState.Namespace(id: workspace.workspace_id,
            tabs: snapshot.tabs.filter { $0.workspace_id == workspace.workspace_id }.map { tab in
              WorkspaceState.Tab(id: tab.tab_id, selectedPaneID: snapshot.panes.first { $0.tab_id == tab.tab_id }?.pane_id)
            }, selectedTabID: snapshot.tabs.first { $0.workspace_id == workspace.workspace_id }?.tab_id)
        }
        let saved = self.workspaceState ?? WorkspaceState()
        let restored = saved.reconciled(with: live,
          panesByTab: Dictionary(grouping: snapshot.panes, by: \.tab_id).mapValues { Set($0.map(\.pane_id)) })
        let attachedNamespaces = Set(self.windows.flatMap(\.namespaces).compactMap(\.herdrID))
        let available = snapshot.workspaces.map(\.workspace_id).filter { !attachedNamespaces.contains($0) }
        var groups = (restored.windows ?? []).compactMap { saved -> WorkspaceState.Window? in
          var window = saved
          window.namespaceIDs = window.namespaceIDs.filter { available.contains($0) }
          return window.namespaceIDs.isEmpty ? nil : window
        }
        let assigned = Set(groups.flatMap(\.namespaceIDs))
        let unknown = available.filter { !assigned.contains($0) }
        if !unknown.isEmpty {
          if let index = groups.firstIndex(where: { $0.id == restored.activeWindowID }) ?? groups.indices.first {
            groups[index].namespaceIDs += unknown
          } else {
            groups.append(.init(id: UUID().uuidString, namespaceIDs: unknown,
              selectedNamespaceID: restored.selectedNamespaceID ?? unknown.first, frame: nil, sidebar: restored.sidebar))
          }
        }
        self.restoringWorkspace = true
        var opened: [TerminalWindowController] = []
        do {
          for group in groups { opened.append(try self.attachHerdrWindow(snapshot, client: client, presentation: group, state: restored)) }
        } catch {
          for controller in opened { controller.closing = true; controller.window?.close() }
          self.restoringWorkspace = false
          throw error
        }
        self.workspaceState = self.workspaceStore == nil ? nil : restored
        self.restoringWorkspace = false
        for controller in opened {
          controller.persistenceReady = self.workspaceStore != nil
          controller.persistedNamespaceIDs = Set(controller.namespaces.compactMap(\.herdrID))
          self.scheduleWorkspaceSave(controller)
        }
        if let selected = opened.first(where: { $0.workspaceWindowID == restored.activeWindowID }) {
          selected.window?.makeKeyAndOrderFront(nil)
        }
        self.observeHerdr(client, snapshot: snapshot)
        self.muxError = nil
      } catch {
        self.muxError = error.localizedDescription
        if self.windows.isEmpty { self.newLocalWindow() }
        self.showMuxError(error)
      }
    }
  }
  func observeHerdr(_ client: HerdrClient, snapshot: HerdrClient.Snapshot) {
    client.onWorkspaceEvent = { [weak self, weak client] in
      guard let self, let client, !self.terminating else { return }
      self.eventRefresh?.invalidate()
      self.eventRefresh = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self, weak client] _ in
        guard let self, let client, !self.eventRefreshRunning, !self.terminating else { return }
        self.eventRefreshRunning = true
        client.perform({ try $0.snapshot(timeout: 1) }) { [weak self, weak client] result in
          guard let self, let client else { return }
          self.eventRefreshRunning = false
          if case .success(let snapshot) = result { self.synchronizeHerdr(snapshot, client: client) }
        }
      }
    }
    client.observeEvents(panes: snapshot.panes)
  }

  func synchronizeHerdr(_ serverSnapshot: HerdrClient.Snapshot, client: HerdrClient) {
    let targets = windows.filter { $0.session?.herdrTerminal?.client === client && !$0.closing }
    guard !terminating, !muxOpening, !restoringWorkspace, !synchronizingWorkspace, !targets.isEmpty,
      targets.allSatisfy({ !$0.muxBusy && !$0.hasPendingMuxActions && $0.window?.attachedSheet == nil }) else { return }
    observeHerdr(client, snapshot: serverSnapshot)
    let visibleNamespaces = Set(targets.flatMap(\.namespaces).compactMap(\.herdrID))
    let detached = Set((workspaceState?.windows ?? []).flatMap(\.namespaceIDs)).subtracting(visibleNamespaces)
    let snapshot = serverSnapshot.filtered(namespaceIDs: Set(serverSnapshot.workspaces.map(\.workspace_id)).subtracting(detached))
    let currentRecords = targets.flatMap(\.allPanes).compactMap { $0.herdrTerminal?.pane }
    let structureMatches = Set(currentRecords.map(\.terminal_id)) == Set(snapshot.panes.map(\.terminal_id))
      && currentRecords.allSatisfy { old in snapshot.panes.contains { $0.terminal_id == old.terminal_id && $0.tab_id == old.tab_id && $0.workspace_id == old.workspace_id } }
    if var saved = workspaceState {
      let live = serverSnapshot.workspaces.map { workspace in
        WorkspaceState.Namespace(id: workspace.workspace_id,
          tabs: serverSnapshot.tabs.filter { $0.workspace_id == workspace.workspace_id }.map { .init(id: $0.tab_id, selectedPaneID: nil) }, selectedTabID: nil)
      }
      saved = saved.reconciled(with: live, panesByTab: Dictionary(grouping: serverSnapshot.panes, by: \.tab_id).mapValues { Set($0.map(\.pane_id)) })
      workspaceNeedsSave = workspaceNeedsSave || saved != workspaceState
      workspaceState = saved
    }
    if structureMatches {
      for controller in targets { controller.updateHerdrLabels(snapshot) }
      if workspaceNeedsSave { flushWorkspaceSave() }
      return
    }
    synchronizingWorkspace = true
    restoringWorkspace = true
    defer { restoringWorkspace = false; synchronizingWorkspace = false }
    let oldPanes = targets.flatMap(\.allPanes)
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
    var owners: [String: TerminalWindowController] = [:]
    for controller in targets {
      for namespace in controller.namespaces { if let id = namespace.herdrID { owners[id] = controller } }
    }
    for workspace in snapshot.workspaces where owners[workspace.workspace_id] == nil { owners[workspace.workspace_id] = destination }
    for controller in targets {
      let ids = snapshot.workspaces.map(\.workspace_id).filter { owners[$0] === controller }
      controller.reconcileHerdr(snapshot, namespaceIDs: ids, sessions: sessions)
    }
    let liveIDs = Set(snapshot.panes.map(\.terminal_id))
    for pane in oldPanes where !liveIDs.contains(pane.herdrTerminal?.pane.terminal_id ?? "") { pane.close() }
    restoringWorkspace = false
    for controller in targets where !controller.closing { scheduleWorkspaceSave(controller) }
  }

  private func attachHerdrWindow(_ snapshot: HerdrClient.Snapshot, client: HerdrClient,
    presentation: WorkspaceState.Window, state: WorkspaceState) throws -> TerminalWindowController {
    guard let runtime, let first = snapshot.panes.first(where: { presentation.namespaceIDs.contains($0.workspace_id) }) else {
      throw ConfigurationError("herdr returned no terminals to attach.")
    }
    let session = runtime.makeSession()
    session.herdrTerminal = .init(client: client, pane: first)
    let controller = TerminalWindowController(session: session, owner: self)
    controller.workspaceWindowID = presentation.id
    controller.activeNamespace.herdrID = first.workspace_id
    windows.append(controller)
    controller.openWindow(cascadingFrom: focusedWindow?.window)
    do {
      guard let window = controller.window else { throw ConfigurationError("Could not create terminal window.") }
      let excluded = Set(snapshot.panes.filter { !presentation.namespaceIDs.contains($0.workspace_id) }.map(\.terminal_id))
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

extension TerminalWindowController {
  func addHerdrTerminals(_ snapshot: HerdrClient.Snapshot, excluding excluded: Set<String>, restoring: Bool = false) throws {
    guard let client = session?.herdrTerminal?.client, let runtime = session?.runtime else { return }
    let attached = Set((owner?.windows.flatMap(\.allPanes) ?? allPanes).compactMap { $0.herdrTerminal?.pane.terminal_id })
    let excluded = excluded.union(attached)
    var prepared: [String: TerminalSession] = [:]
    do {
      for pane in snapshot.panes where !excluded.contains(pane.terminal_id) {
        guard prepared[pane.terminal_id] == nil else { throw ConfigurationError("herdr returned duplicate terminal IDs.") }
        let terminal = runtime.makeSession()
        terminal.herdrTerminal = HerdrClient.Terminal(client: client, pane: pane)
        terminal.surfaceContext = GHOSTTY_SURFACE_CONTEXT_SPLIT
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
          if let namespace = namespaces.first(where: { $0.herdrID == workspace.workspace_id }) {
            if let tab = namespace.tabs.first(where: { $0.herdrID == record.tab_id }) {
              tab.panes.append(terminal)
            } else {
              let tab = TerminalTab(terminal)
              if !restoring, native.newTabPosition == "current", let index = namespace.tabs.firstIndex(where: { $0 === activeTab }) {
                namespace.tabs.insert(tab, at: index + 1)
              } else { namespace.tabs.append(tab) }
            }
          } else {
            let namespace = TerminalNamespace(name: workspace.label, session: terminal)
            namespace.herdrID = workspace.workspace_id
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

  func reconcileHerdr(_ snapshot: HerdrClient.Snapshot, namespaceIDs: [String], sessions: [String: TerminalSession]) {
    let previousPane = session
    let previousNamespace = activeNamespace.herdrID
    let responder = window?.firstResponder
    let oldNamespaces = namespaces
    var rebuilt: [TerminalNamespace] = []
    let ordered = oldNamespaces.compactMap(\.herdrID).filter(namespaceIDs.contains)
      + namespaceIDs.filter { id in !oldNamespaces.contains { $0.herdrID == id } }
    for id in ordered {
      guard let workspace = snapshot.workspaces.first(where: { $0.workspace_id == id }) else { continue }
      let records = snapshot.tabs.filter { $0.workspace_id == id }
      let oldNamespace = oldNamespaces.first { $0.herdrID == id }
      let oldTabs = oldNamespace?.tabs ?? []
      let order = oldTabs.compactMap(\.herdrID).filter { id in records.contains { $0.tab_id == id } }
        + records.map(\.tab_id).filter { id in !oldTabs.contains { $0.herdrID == id } }
      var tabs: [TerminalTab] = []
      for tabID in order {
        let panes = snapshot.panes.filter { $0.tab_id == tabID }.compactMap { record -> TerminalSession? in
          guard let pane = sessions[record.terminal_id] else { return nil }
          pane.herdrTerminal = .init(client: pane.herdrTerminal!.client, pane: record)
          pane.windowController = self
          return pane
        }
        guard let first = panes.first else { continue }
        let tab = oldTabs.first { $0.herdrID == tabID } ?? TerminalTab(first)
        tab.panes = panes
        if !panes.contains(where: { $0 === tab.selected }) { tab.selected = first }
        tabs.append(tab)
      }
      guard let first = tabs.first else { continue }
      let namespace = oldNamespace ?? TerminalNamespace(name: workspace.label, session: first.selected)
      namespace.herdrID = id
      namespace.tabs = tabs
      if !tabs.contains(where: { $0 === namespace.selected }) { namespace.selected = first }
      rebuilt.append(namespace)
    }
    namespaces = rebuilt
    guard let first = rebuilt.first else {
      persistenceReady = false
      closing = true
      window?.close()
      return
    }
    activeNamespace = rebuilt.first { $0.herdrID == previousNamespace } ?? first
    let selected = previousPane.flatMap { pane in allPanes.contains { $0 === pane } ? pane : nil } ?? activeNamespace.selected.selected
    session = nil
    updateHerdrLabels(snapshot)
    selectTab(selected)
    if previousPane === selected, let responder { window?.makeFirstResponder(responder) }
  }

  func updateHerdrLabels(_ snapshot: HerdrClient.Snapshot) {
    for pane in allPanes {
      if let terminal = pane.herdrTerminal, let record = snapshot.panes.first(where: { $0.terminal_id == terminal.pane.terminal_id }) {
        pane.herdrTerminal = .init(client: terminal.client, pane: record)
      }
    }
    workspaceView.updateAgents(snapshot)
    var changed = false
    for namespace in namespaces {
      if let record = snapshot.workspaces.first(where: { $0.workspace_id == namespace.herdrID }) {
        changed = changed || namespace.name != record.label || namespace.subtitle != (record.tokens?["subtitle"] ?? "")
        namespace.name = record.label
        namespace.subtitle = record.tokens?["subtitle"] ?? ""
      }
      for tab in namespace.tabs {
        let layout = snapshot.layouts.first { $0.tab_id == tab.herdrID }
        changed = changed || tab.layout != layout
        tab.layout = layout
        refreshLayoutTree(tab)
        if let record = snapshot.tabs.first(where: { $0.tab_id == tab.herdrID }) {
          let position = snapshot.tabs.filter { $0.workspace_id == record.workspace_id }.firstIndex { $0.tab_id == record.tab_id }.map { $0 + 1 }
          let defaultLabel = String(position ?? record.number ?? 1)
          let title = record.label == defaultLabel ? nil : record.label
          changed = changed || tab.title != title
          tab.title = title
          for pane in tab.panes { pane.tabTitle = tab.title }
        }
      }
    }
    if changed { workspaceView.present() }
  }

  func refreshLayoutTree(_ tab: TerminalTab) {
    guard !tab.loadingTree, tab.treeLayout != tab.layout, let terminal = tab.selected.herdrTerminal,
      let layout = tab.layout, tab.panes.count > 1 else { return }
    tab.loadingTree = true
    terminal.client.perform({ try $0.layoutTree(tabID: terminal.pane.tab_id) }) { [weak self, weak tab] result in
      guard let self, let tab else { return }
      tab.loadingTree = false
      guard !self.closing else { return }
      if tab.layout == layout, case .success(let tree) = result {
        tab.layoutTree = tree
        tab.treeLayout = layout
        self.workspaceView.needsLayout = true
      }
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

  func chooseTabNamespace() {
    guard let client = session?.herdrTerminal?.client else { return }
    let tab = activeTab
    let destinations = (owner?.windows.flatMap(\.namespaces) ?? namespaces).filter { $0 !== activeNamespace && $0.selected.selected.herdrTerminal?.client === client }
    chooseDestination(title: "Move Tab to Namespace", labels: destinations.map(\.name)) { [weak self, weak tab] index in
      guard let self, let tab, destinations.indices.contains(index), let id = destinations[index].herdrID else { return }
      self.moveTab(tab, toNamespace: id)
    }
  }

  func moveTab(_ tab: TerminalTab, toNamespace id: String) {
    guard let tabID = tab.herdrID else { return }
    moveTerminals { try $0.moveTab(tabID: tabID, workspaceID: id, label: tab.title) }
  }

  func choosePaneTab() {
    guard let client = session?.herdrTerminal?.client, let pane = session else { return }
    let tabs = (owner?.windows.flatMap(\.namespaces) ?? namespaces).flatMap { namespace in
      namespace.tabs.filter { $0 !== activeTab && $0.selected.herdrTerminal?.client === client }.map { (namespace.name + " / " + $0.displayTitle, $0) }
    }
    chooseDestination(title: "Move Pane to Tab", labels: tabs.map { $0.0 }) { [weak self, weak pane] index in
      guard let self, let pane, tabs.indices.contains(index), let target = tabs[index].1.selected.herdrTerminal else { return }
      self.movePane(pane, toTab: target.pane.tab_id, targetPane: target.pane.pane_id)
    }
  }

  func movePane(_ pane: TerminalSession, toTab tabID: String, targetPane: String) {
    guard let id = pane.herdrTerminal?.pane.pane_id else { return }
    moveTerminals { _ = try $0.api("pane.move", ["pane_id": id, "destination": ["type": "tab", "tab_id": tabID, "target_pane_id": targetPane, "split": "right"], "focus": false]) }
  }

  func movePaneToNewTab() {
    guard activeTab.panes.count > 1, let terminal = session?.herdrTerminal else { return }
    moveTerminals { _ = try $0.api("pane.move", ["pane_id": terminal.pane.pane_id, "destination": ["type": "new_tab", "workspace_id": terminal.pane.workspace_id], "focus": false]) }
  }

  private func moveTerminals(_ change: @escaping (HerdrClient) throws -> Void) {
    guard !closing, let client = session?.herdrTerminal?.client else { return }
    if deferMuxAction({ [weak self] in self?.moveTerminals(change) }) { return }
    let selected = session
    let app = owner
    muxBusy = true
    client.perform({ client -> (HerdrClient.Snapshot?, Error?) in
      do { try change(client); return (try client.snapshot(), nil) }
      catch { return (try? client.snapshot(), error) }
    }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, self.owner?.terminating != true else { return }
      if case .success(let (snapshot, error)) = result {
        if let snapshot {
          app?.synchronizeHerdr(snapshot, client: client)
          if let selected, let destination = app?.windows.first(where: { $0.allPanes.contains { $0 === selected } }) {
            destination.selectTab(selected)
            destination.window?.makeKeyAndOrderFront(nil)
          }
        }
        if let error { self.owner?.showMuxError(error) }
      }
    }
  }

  func equalizePanes() {
    guard let terminal = session?.herdrTerminal, activeTab.panes.count > 1 else { return }
    changePaneLayout { try $0.equalize(tabID: terminal.pane.tab_id) }
  }

  func setSplitRatio(tabID: String, path: [Bool], ratio: Double) {
    guard ratio.isFinite else { return }
    changePaneLayout { _ = try $0.api("layout.set_split_ratio", ["tab_id": tabID, "path": path, "ratio": max(0.1, min(0.9, ratio))]) }
  }

  private func changePaneLayout(_ change: @escaping (HerdrClient) throws -> Void) {
    guard !closing, let client = session?.herdrTerminal?.client else { return }
    if deferMuxAction({ [weak self] in self?.changePaneLayout(change) }) { return }
    muxBusy = true
    client.perform({ client in try change(client); return try client.snapshot() }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing else { return }
      switch result {
      case .success(let snapshot): self.updateHerdrLabels(snapshot)
      case .failure(let error): self.owner?.showMuxError(error)
      }
    }
  }

  func endHerdrTabs(_ targets: [TerminalTab]) {
    guard !closing, owner?.terminating != true else { return }
    if deferMuxAction({ [weak self] in self?.endHerdrTabs(targets) }) { return }
    let targets = targets.filter { tab in namespaces.contains { $0.tabs.contains { $0 === tab } } }
    guard let client = targets.first?.selected.herdrTerminal?.client else { return }
    muxBusy = true
    let ids = targets.compactMap(\.herdrID)
    client.perform({ client -> ([String], Error?) in
      var closed: [String] = []
      for id in ids {
        do { _ = try client.request(["tab", "close", id]); closed.append(id) }
        catch { return (closed, error) }
      }
      return (closed, nil)
    }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, self.owner?.terminating != true else { return }
      switch result {
      case .success(let (closed, error)):
        for tab in targets where closed.contains(tab.herdrID ?? "") {
          self.closeTab(tab.selected, confirm: false, endSession: false)
        }
        if let error { self.owner?.showMuxError(error) }
      case .failure(let error): self.owner?.showMuxError(error)
      }
    }
  }
}

extension TerminalWindowController {
  func splitPane(_ direction: String, from source: TerminalSession? = nil) {
    guard let pane = source ?? session, let terminal = pane.herdrTerminal else { owner?.showMuxWarning(); return }
    guard !closing, window?.attachedSheet == nil else { return }
    if deferMuxAction({ [weak self, weak pane] in if let pane { self?.splitPane(direction, from: pane) } }) { return }
    let existing = Set((owner?.windows.flatMap(\.allPanes) ?? allPanes).compactMap { $0.herdrTerminal?.pane.terminal_id })
    let shellEnvironment = terminal.client.shellEnvironment(settings: pane.settings)
    muxBusy = true
    terminal.client.perform({ client in
      let backendDirection = direction == "left" ? "right" : direction == "up" ? "down" : direction
      let response = try client.request(["pane", "split", terminal.pane.pane_id, "--direction", backendDirection, "--no-focus"] + HerdrClient.environmentArguments(shellEnvironment))
      if direction == "left" || direction == "up", let newPane = response["pane"] as? [String: Any], let id = newPane["pane_id"] as? String {
        // Herdr creates right/down only. Swapping preserves both processes;
        // its incidental backend selection is never imported into Velocitty.
        _ = try client.request(["pane", "swap", "--source-pane", id, "--target-pane", terminal.pane.pane_id])
      }
      return try client.snapshot()
    }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, self.window != nil, self.owner?.terminating != true else { return }
      do { try self.addHerdrTerminals(result.get(), excluding: existing) }
      catch { self.owner?.showMuxError(error) }
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
    let candidates = tab.panes.filter { candidate in
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
    guard let pane = source ?? session, let terminal = pane.herdrTerminal,
      tab(for: pane)?.panes.count ?? 0 > 1, !closing, window?.attachedSheet == nil else { return }
    if deferMuxAction({ [weak self, weak pane] in if let pane { self?.resizePane(direction, amount: amount, from: pane) } }) { return }
    muxBusy = true
    terminal.client.perform({ client in
      _ = try client.request(["pane", "resize", "--pane", terminal.pane.pane_id,
        "--direction", direction, "--amount", String(max(0.01, min(0.4, amount)))])
      return try client.snapshot()
    }) { [weak self] result in
      guard let self else { return }
      self.muxBusy = false
      guard !self.closing, self.owner?.terminating != true else { return }
      switch result {
      case .success(let snapshot): self.updateHerdrLabels(snapshot)
      case .failure(let error): self.owner?.showMuxError(error)
      }
    }
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
    if tab.selected === pane { tab.selected = tab.panes[min(index, tab.panes.count - 1)] }
    if session === pane { selectTab(tab.selected) }
    pane.close()
    workspaceView.present()
    if let client = tab.selected.herdrTerminal?.client {
      client.perform({ try $0.snapshot() }) { [weak self] result in
        guard let self, !self.closing else { return }
        if case .success(let snapshot) = result { self.updateHerdrLabels(snapshot) }
      }
    }
  }
}

extension AppDelegate {
  private func loadWorkspaceState(for client: HerdrClient) {
    guard !workspaceLoadAttempted, client.sessionName == "velocitty" || workspaceStateURL != nil else { return }
    workspaceLoadAttempted = true
    let store = workspaceStateURL.map { WorkspaceStateStore(url: $0) } ?? WorkspaceStateStore()
    do {
      workspaceState = try store.load()
      workspaceStore = store
    } catch {
      // Preserve unreadable, malformed, or future-version state for recovery.
      NSLog("Workspace persistence disabled for this run: %@", error.localizedDescription)
    }
  }

  func scheduleWorkspaceSave(_ controller: TerminalWindowController) {
    guard !restoringWorkspace, controller.persistenceReady, workspaceStore != nil, var state = workspaceState else { return }
    let current = controller.namespaces.compactMap { namespace -> WorkspaceState.Namespace? in
      guard let id = namespace.herdrID else { return nil }
      return WorkspaceState.Namespace(id: id, tabs: namespace.tabs.compactMap { tab in
        guard let id = tab.herdrID else { return nil }
        return WorkspaceState.Tab(id: id, selectedPaneID: tab.selected.herdrTerminal?.pane.pane_id, zoomed: tab.zoomed)
      }, selectedTabID: namespace.selected.herdrID)
    }
    state.update(current, replacing: controller.persistedNamespaceIDs)
    controller.persistedNamespaceIDs = Set(current.map(\.id))
    let frame = controller.normalFrame ?? controller.window?.frame
    let presentation = WorkspaceState.Window(id: controller.workspaceWindowID,
      namespaceIDs: current.map(\.id), selectedNamespaceID: controller.activeNamespace.herdrID,
      frame: frame.map { .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
      sidebar: controller.workspaceView.savedSidebarState)
    var savedWindows = state.windows ?? []
    // A namespace has one presentation owner, even after a cross-window move.
    for index in savedWindows.indices where savedWindows[index].id != presentation.id {
      savedWindows[index].namespaceIDs.removeAll { presentation.namespaceIDs.contains($0) }
    }
    if let index = savedWindows.firstIndex(where: { $0.id == presentation.id }) { savedWindows[index] = presentation }
    else if !presentation.namespaceIDs.isEmpty { savedWindows.append(presentation) }
    savedWindows.removeAll { $0.namespaceIDs.isEmpty }
    state.windows = savedWindows
    state.version = 2
    if focusedWindow == nil || focusedWindow === controller {
      state.activeWindowID = controller.workspaceWindowID
      state.selectedNamespaceID = controller.activeNamespace.herdrID
      state.sidebar = controller.workspaceView.savedSidebarState
    }
    guard state != workspaceState || workspaceNeedsSave else { return }
    workspaceNeedsSave = true
    workspaceState = state
    workspaceSaveTimer?.invalidate()
    workspaceSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
      self?.flushWorkspaceSave()
    }
  }

  func flushWorkspaceSave() {
    workspaceSaveTimer?.invalidate()
    workspaceSaveTimer = nil
    guard workspaceNeedsSave, let state = workspaceState, let store = workspaceStore else { return }
    do { try store.save(state); workspaceNeedsSave = false }
    catch { NSLog("Could not save workspace: %@", error.localizedDescription) }
  }
}

extension TerminalWindowController {
  func restoreWorkspaceState(_ state: WorkspaceState) {
    let namespaceOrder = state.namespaces.map(\.id)
    namespaces.sort { (namespaceOrder.firstIndex(of: $0.herdrID ?? "") ?? Int.max) < (namespaceOrder.firstIndex(of: $1.herdrID ?? "") ?? Int.max) }
    for namespace in namespaces {
      guard let saved = state.namespaces.first(where: { $0.id == namespace.herdrID }) else { continue }
      let tabOrder = saved.tabs.map(\.id)
      namespace.tabs.sort { (tabOrder.firstIndex(of: $0.herdrID ?? "") ?? Int.max) < (tabOrder.firstIndex(of: $1.herdrID ?? "") ?? Int.max) }
      for tab in namespace.tabs {
        tab.zoomed = saved.tabs.first(where: { $0.id == tab.herdrID })?.zoomed == true
        if let paneID = saved.tabs.first(where: { $0.id == tab.herdrID })?.selectedPaneID,
          let pane = tab.panes.first(where: { $0.herdrTerminal?.pane.pane_id == paneID }) { tab.selected = pane }
      }
      if let tab = namespace.tabs.first(where: { $0.herdrID == saved.selectedTabID }) { namespace.selected = tab }
    }
    if let sidebar = state.sidebar { workspaceView.restoreSidebarState(sidebar) }
    let selected = namespaces.first { $0.herdrID == state.selectedNamespaceID } ?? namespaces.first
    if let selected { selectTab(selected.selected) }
    workspaceView.present()
  }
}
