// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon
import Foundation
import UserNotifications
import VeloKit
import VelocittyConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var windows: [TerminalWindowController] = []
  weak var focusedWindow: TerminalWindowController?
  var idleRuntime: TerminalRuntime?
  var appearanceObservation: NSKeyValueObservation?
  var keyboardObservation: NSObjectProtocol?
  var shortcuts: GlobalShortcuts?
  var quitTimer: Timer?
  var pendingFiles: [String] = []
  var terminating = false

  var activeWindow: TerminalWindowController? {
    windows.first { $0.window === NSApp.keyWindow }
      ?? windows.first { $0.window === NSApp.mainWindow }
      ?? focusedWindow ?? windows.last
  }
  var runtime: TerminalRuntime? { activeWindow?.runtime ?? idleRuntime }
  var native: NativeSettings { NativeSettings(config: runtime?.config) }

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
      for controller in self?.windows ?? [] {
        if let app = controller.runtime?.app { velokit_app_keyboard_changed(app) }
      }
      self?.shortcuts?.reload()
      self?.updateMenuShortcuts()
    }
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.refreshAppearance() }
    }

    let runtime: TerminalRuntime
    do {
      runtime = try TerminalRuntime(settings: AppConfiguration.load())
    } catch {
      let alert = configurationAlert(error)
      alert.informativeText += "\n\nUse the defaults for this launch, or quit to fix the file."
      alert.addButton(withTitle: "Use Defaults")
      alert.addButton(withTitle: "Quit")
      guard alert.runModal() == .alertFirstButtonReturn else {
        NSApp.terminate(nil)
        return
      }
      do {
        runtime = try TerminalRuntime(settings: .defaults())
      } catch {
        configurationAlert(error).runModal()
        NSApp.terminate(nil)
        return
      }
    }

    self.idleRuntime = runtime
    shortcuts = GlobalShortcuts(owner: self)
    shortcuts?.reload()
    updateMenuShortcuts()
    if native.value("initial-window", true) { newWindow() }
    if !pendingFiles.isEmpty {
      insertFiles(pendingFiles)
      pendingFiles.removeAll()
    }
    scheduleQuitIfNeeded()
    if native.string("macos-hidden") == "always" { NSApp.hide(nil) }
  }

  @objc func newWindow() {
    quitTimer?.invalidate()
    quitTimer = nil
    do {
      let runtime: TerminalRuntime
      if let idleRuntime {
        runtime = idleRuntime
        self.idleRuntime = nil
      } else {
        runtime = try TerminalRuntime(settings: self.runtime?.settings ?? AppConfiguration.load())
      }
      let previousWindow = activeWindow?.window
      let controller = TerminalWindowController(runtime: runtime, owner: self)
      windows.append(controller)
      controller.openWindow(cascadingFrom: previousWindow)
      if controller.window == nil {
        windows.removeAll { $0 === controller }
        idleRuntime = runtime
        configurationAlert(ConfigurationError("Could not create a terminal window.")).runModal()
      }
    } catch { configurationAlert(error).runModal() }
  }

  // Reopening from the Dock presents an existing terminal when possible.
  func openWindow() {
    if let activeWindow { activeWindow.openWindow() } else { newWindow() }
  }

  func windowFocused(_ controller: TerminalWindowController) {
    for other in windows where other !== controller { other.updateSecureInput(forceOff: true) }
    focusedWindow = controller
    if controller.hasBell {
      controller.hasBell = false
      controller.setTitle(controller.terminalTitle)
    }
    updateMenuShortcuts()
  }

  func windowClosed(_ controller: TerminalWindowController) {
    windows.removeAll { $0 === controller }
    if focusedWindow === controller { focusedWindow = nil }
    if windows.isEmpty {
      idleRuntime = controller.runtime
      idleRuntime?.context.owner = nil
    }
    if !terminating { scheduleQuitIfNeeded() }
  }

  func scheduleQuitIfNeeded() {
    guard windows.isEmpty, !terminating, native.value("quit-after-last-window-closed", false) else { return }
    quitTimer?.invalidate()
    quitTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.01, native.seconds("quit-after-last-window-closed-delay", 0)),
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
    quitTimer?.invalidate()
    for controller in closingWindows {
      controller.closing = true
      controller.window?.close()
    }
    return .terminateNow
  }

  @objc func closeWindow() { activeWindow?.window?.performClose(nil) }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    menuItem.action != #selector(closeWindow) || activeWindow != nil
  }

  func closeAllWindows() {
    for controller in windows { controller.window?.performClose(nil) }
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if runtime == nil { pendingFiles.append(contentsOf: filenames) } else { insertFiles(filenames) }
    sender.reply(toOpenOrPrint: .success)
  }

  func insertFiles(_ filenames: [String]) {
    openWindow()
    let text = ShellInput.paths(filenames)
    if let surface = activeWindow?.runtime?.view?.surface {
      text.withCString { velokit_surface_text(surface, $0, UInt(text.utf8.count)) }
    }
  }

  func refreshAppearance() {
    for controller in windows { controller.refreshAppearance() }
    if let idleRuntime { try? idleRuntime.updateConfiguration(idleRuntime.settings) }
  }

  @objc func reloadConfiguration(_ sender: Any?) {
    do {
      let settings = try AppConfiguration.load()
      // Validate before changing any window.
      let candidate = try TerminalRuntime.makeConfig(settings)
      velokit_config_free(candidate)
      for controller in windows {
        try controller.runtime?.updateConfiguration(settings)
        controller.applyWindowSettings()
        controller.updateSecureInput()
      }
      try idleRuntime?.updateConfiguration(settings)
      shortcuts?.reload()
      updateMenuShortcuts()
    } catch { configurationAlert(error).runModal() }
  }

  @objc func showCommands() { activeWindow?.showCommands() }
  @objc func findTerminal() { activeWindow?.findTerminal() }
  @objc func findNext() { activeWindow?.findNext() }
  @objc func findPrevious() { activeWindow?.findPrevious() }

  func applicationDidBecomeActive(_ notification: Notification) {
    for controller in windows {
      controller.updateSecureInput()
      if let app = controller.runtime?.app { velokit_app_set_focus(app, true) }
    }
  }

  func applicationDidResignActive(_ notification: Notification) {
    for controller in windows {
      controller.updateSecureInput(forceOff: true)
      if let app = controller.runtime?.app { velokit_app_set_focus(app, false) }
    }
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
    terminalMenu.addItem(.separator())
    terminalMenu.addItem(
      withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w"
    ).target = self

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
      "Close Window": "close_surface", "Quit Velocitty": "quit",
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
      .applicationVersion: "0.1.0",
      .credits: NSAttributedString(string: "A macOS terminal powered by libghostty."),
    ])
  }
}

final class TerminalWindowController: NSObject, NSWindowDelegate {
  weak var owner: AppDelegate?

  init(runtime: TerminalRuntime, owner: AppDelegate) {
    self.runtime = runtime
    self.owner = owner
    super.init()
    runtime.context.owner = self
  }

  var window: NSWindow?
  var runtime: TerminalRuntime?
  var closing = false
  var resizeTimer: Timer?
  var hasResized = false
  var normalFrame: NSRect?
  var normalStyle: NSWindow.StyleMask?
  var titleAccessory: NSTitlebarAccessoryViewController?
  var titleLabel: NSTextField?
  var currentDirectory: String?
  var opacityOverride: Double?
  var palette: CommandPalette?
  var passwordInput = false
  var manualSecureInput = false
  var secureInputEnabled = false
  var bellSound: NSSound?
  var terminalTitle = "Velocitty"
  var windowTitleOverride: String?
  var hasBell = false
  var readonly = false
  var progressTimer: Timer?
  var progressAnimationTimer: Timer?
  var chrome: TerminalChrome?
  var native: NativeSettings { NativeSettings(config: runtime?.config) }

  func openWindow(cascadingFrom previousWindow: NSWindow? = nil) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard let runtime, let terminalView = runtime.createView() else { return }
    let window = TerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    currentDirectory = runtime.settings.workingDirectory.path
    terminalTitle = "Velocitty"
    windowTitleOverride = nil
    hasBell = false
    window.title = "Velocitty"
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    let chrome = TerminalChrome(terminalView)
    self.chrome = chrome
    window.contentView = chrome
    self.window = window
    applyWindowSettings()
    if let surface = terminalView.surface {
      let size = velokit_surface_size(surface)
      let scale = window.backingScaleFactor
      if terminalView.initialSize != nil { resetWindowSize() }
      if native.value("window-step-resize", false) {
        window.contentResizeIncrements = NSSize(
          width: max(1, CGFloat(size.cell_width_px) / scale),
          height: max(1, CGFloat(size.cell_height_px) / scale))
      }
    }
    window.center()
    if shouldSaveState { _ = window.setFrameUsingName("TerminalWindow") }
    let x = native.value("window-position-x", Int16.min)
    let y = native.value("window-position-y", Int16.min)
    if x != Int16.min || y != Int16.min, let screen = window.screen {
      let frame = screen.visibleFrame
      window.setFrameOrigin(
        NSPoint(
          x: x == Int16.min ? window.frame.minX : frame.minX + CGFloat(x),
          y: y == Int16.min ? window.frame.minY : frame.maxY - window.frame.height - CGFloat(y)))
    }
    if let previousWindow {
      // AppKit keeps the cascade on screen when it reaches a display edge.
      _ = window.cascadeTopLeft(from: NSPoint(
        x: previousWindow.frame.minX + 24, y: previousWindow.frame.maxY - 24))
    }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminalView)
    if native.value("maximize", false) { window.zoom(nil) }
    if native.string("fullscreen", "false") != "false"
      || (shouldSaveState && UserDefaults.standard.bool(forKey: "TerminalFullscreen"))
    {
      toggleFullscreen()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  var shouldSaveState: Bool {
    let policy = native.string("window-save-state", "default")
    return policy == "always"
      || (policy == "default"
        && (UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool ?? true))
  }

  func applyWindowSettings() {
    guard let window else { return }
    let titlebar = native.string("macos-titlebar-style", "transparent")
    if native.string("window-decoration") == "none" || titlebar == "hidden" {
      window.styleMask.remove(.titled)
    } else {
      window.styleMask.insert(.titled)
    }
    window.titlebarAppearsTransparent = titlebar != "native"
    window.hasShadow = native.value("macos-window-shadow", true)
    window.titleVisibility = titlebar == "hidden" ? .hidden : .visible
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(button)?.isHidden =
        native.string("macos-window-buttons") == "hidden"
    }
    window.colorSpace = native.string("window-colorspace") == "display-p3" ? .displayP3 : .sRGB
    if let titleAccessory {
      window.removeTitlebarAccessoryViewController(
        at: window.titlebarAccessoryViewControllers.firstIndex(of: titleAccessory) ?? 0)
      self.titleAccessory = nil
      titleLabel = nil
    }
    let family = native.string("window-title-font-family")
    let foreground =
      runtime?.settings.options.contains {
        $0.key == "window-titlebar-foreground" && !$0.value.isEmpty
      } == true
    let background =
      runtime?.settings.options.contains {
        $0.key == "window-titlebar-background" && !$0.value.isEmpty
      } == true
    if !family.isEmpty || foreground || background {
      let accessory = NSTitlebarAccessoryViewController()
      let label = NSTextField(labelWithString: window.title)
      label.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
      label.alignment = .center
      label.font = NSFont(name: family, size: 13) ?? .systemFont(ofSize: 13)
      if foreground { label.textColor = native.color("window-titlebar-foreground", .labelColor) }
      if background {
        label.drawsBackground = true
        label.backgroundColor = native.color("window-titlebar-background")
      }
      accessory.view = label
      accessory.layoutAttribute = .bottom
      window.addTitlebarAccessoryViewController(accessory)
      titleAccessory = accessory
      titleLabel = label
      window.titleVisibility = .hidden
    }
    let directory = currentDirectory ?? runtime?.settings.workingDirectory.path ?? ""
    window.subtitle = native.string("window-subtitle") == "working-directory" ? directory : ""
    window.representedURL =
      native.string("macos-titlebar-proxy-icon") == "visible"
      ? URL(fileURLWithPath: directory) : nil
    let theme = native.string("window-theme")
    let color = native.color("background").usingColorSpace(.sRGB) ?? .black
    let dark =
      0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
      < 0.5
    let inferred = theme == "ghostty" || (theme == "auto" && titlebar != "native")
    window.appearance =
      theme == "dark" || (inferred && dark)
      ? NSAppearance(named: .darkAqua)
      : theme == "light" || (inferred && !dark) ? NSAppearance(named: .aqua) : nil
    let opacity = opacityOverride ?? native.value("background-opacity", 1.0)
    window.isOpaque = opacity >= 1
    window.backgroundColor = native.color("background").withAlphaComponent(opacity)
    let blur = native.value("background-blur", Int16(0))
    if blur != 0 && opacity < 1, let terminal = chrome, window.contentView === terminal {
      let visual = NSVisualEffectView(frame: terminal.frame)
      visual.material = .underWindowBackground
      visual.blendingMode = .behindWindow
      visual.state = .active
      window.contentView = visual
      terminal.frame = visual.bounds
      terminal.autoresizingMask = [.width, .height]
      visual.addSubview(terminal)
    } else if blur == 0 || opacity >= 1, let terminal = chrome,
      window.contentView is NSVisualEffectView
    {
      terminal.removeFromSuperview()
      window.contentView = terminal
    }
  }

  func confirmClose() -> Bool {
    guard let surface = runtime?.view?.surface, velokit_surface_needs_confirm_quit(surface) else {
      return true
    }
    let alert = NSAlert()
    alert.messageText = "Close this terminal?"
    alert.informativeText = "A process is still running. Closing the terminal will end it."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Close Terminal")
    return alert.runModal() == .alertSecondButtonReturn
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { closing || confirmClose() }

  func windowWillClose(_ notification: Notification) {
    if shouldSaveState {
      if window?.styleMask.contains(.fullScreen) != true && normalFrame == nil {
        window?.saveFrame(usingName: "TerminalWindow")
      }
      UserDefaults.standard.set(
        (window?.styleMask.contains(.fullScreen) == true || normalFrame != nil),
        forKey: "TerminalFullscreen")
    }
    passwordInput = false
    manualSecureInput = false
    readonly = false
    updateSecureInput(forceOff: true)
    clearProgress()
    runtime?.closeView()
    window = nil
    chrome = nil
    palette?.close()
    palette = nil
    normalFrame = nil
    normalStyle = nil
    if NSApp.keyWindow == nil { NSApp.presentationOptions = [] }
    resizeTimer?.invalidate()
    owner?.windowClosed(self)
  }

  func setTitle(_ title: String) {
    terminalTitle = title
    let displayed = (hasBell ? "● " : "") + (windowTitleOverride ?? title)
    window?.title = displayed
    titleLabel?.stringValue = displayed
  }

  func promptTitle(_ mode: ghostty_action_prompt_title_e) {
    guard let window, let terminal = runtime?.view else { return }
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
    if native.string("window-subtitle") == "working-directory" { window?.subtitle = path }
    window?.representedURL =
      native.string("macos-titlebar-proxy-icon") == "visible" ? URL(fileURLWithPath: path) : nil
  }
  func resetWindowSize() {
    guard let window else { return }
    var size = runtime?.view?.initialSize ?? NSSize(width: 960, height: 640)
    let drag = native.string("drag-handle", "auto")
    if drag == "always" || (drag == "auto" && !window.styleMask.contains(.titled)) {
      size.height += 12
    }
    if chrome?.searching == true { size.height += 38 }
    window.setContentSize(size)
  }

  func toggleFullscreen() {
    guard let window else { return }
    let mode = native.string("macos-non-native-fullscreen", "false")
    if let frame = normalFrame {
      window.styleMask = normalStyle ?? [.titled, .closable, .miniaturizable, .resizable]
      window.setFrame(frame, display: true)
      normalFrame = nil
      normalStyle = nil
      NSApp.presentationOptions = []
      return
    }
    guard mode != "false" || native.string("fullscreen") == "non-native" else {
      window.toggleFullScreen(nil)
      return
    }
    if shouldSaveState { window.saveFrame(usingName: "TerminalWindow") }
    normalFrame = window.frame
    normalStyle = window.styleMask
    window.styleMask = [.borderless, .resizable]
    if let screen = window.screen {
      var frame = mode == "visible-menu" ? screen.visibleFrame : screen.frame
      if mode == "padded-notch" { frame.size.height -= screen.safeAreaInsets.top }
      window.setFrame(frame, display: true)
    }
    NSApp.presentationOptions =
      mode == "visible-menu" ? [.autoHideDock] : [.autoHideDock, .autoHideMenuBar]
  }
  func windowDidResize(_ notification: Notification) {
    defer { hasResized = true }
    let policy = native.string("resize-overlay", "after-first")
    guard policy != "never", policy == "always" || hasResized, window?.inLiveResize == true,
      let chrome, let surface = runtime?.view?.surface
    else { return }
    let size = velokit_surface_size(surface)
    chrome.resizeLabel.stringValue = "\(size.columns) × \(size.rows)"
    chrome.resizeLabel.isHidden = false
    chrome.needsLayout = true
    resizeTimer?.invalidate()
    resizeTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.01, native.seconds("resize-overlay-duration", 0.75)), repeats: false
    ) { [weak chrome] _ in chrome?.resizeLabel.isHidden = true }
  }
  func windowWillEnterFullScreen(_ notification: Notification) {
    if shouldSaveState { window?.saveFrame(usingName: "TerminalWindow") }
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    if let window, let surface = runtime?.view?.surface {
      velokit_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }
  }
  func windowDidEndLiveResize(_ notification: Notification) {
    if shouldSaveState { window?.saveFrame(usingName: "TerminalWindow") }
  }

  @objc func showCommands() {
    if palette?.isVisible == true {
      palette?.close()
      return
    }
    guard let terminal = runtime?.view else { return }
    let palette = CommandPalette(terminal: terminal)
    self.palette = palette
    palette.center()
    palette.makeKeyAndOrderFront(nil)
    palette.makeFirstResponder(palette.query)
  }

  @objc func findTerminal() { runtime?.view?.performSurfaceAction("start_search") }
  @objc func findNext() { runtime?.view?.performSurfaceAction("navigate_search:next") }
  @objc func findPrevious() { runtime?.view?.performSurfaceAction("navigate_search:previous") }

  func refreshAppearance() {
    guard let runtime else { return }
    do {
      try runtime.updateConfiguration(runtime.settings)
      applyWindowSettings()
    } catch { NSLog("Appearance update failed: %@", error.localizedDescription) }
  }

}

extension TerminalWindowController {
  func ringBell() {
    let features = native.value("bell-features", UInt32(12))
    if features & 1 != 0 { NSSound.beep() }
    if features & 2 != 0 {
      let pathValue = native.value(
        "bell-audio-path", ghostty_config_path_s(path: nil, optional: false))
      let path = pathValue.path.map { String(cString: $0) } ?? ""
      bellSound =
        path.isEmpty ? NSSound(named: "Glass") : NSSound(contentsOfFile: path, byReference: true)
      bellSound?.volume = Float(native.value("bell-audio-volume", 0.5))
      bellSound?.play()
    }
    if !NSApp.isActive || window?.isKeyWindow != true {
      if features & 4 != 0 { NSApp.requestUserAttention(.informationalRequest) }
      if features & 8 != 0, !hasBell {
        hasBell = true
        setTitle(terminalTitle)
      }
    }
    if features & 16 != 0, let chrome {
      chrome.wantsLayer = true
      chrome.layer?.borderColor = NSColor.controlAccentColor.cgColor
      chrome.layer?.borderWidth = 2
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak chrome] in
        chrome?.layer?.borderWidth = 0
      }
    }
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

  func commandFinished(_ value: ghostty_action_command_finished_s) {
    let policy = native.string("notify-on-command-finish", "never")
    let focused =
      NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === runtime?.view
    guard policy != "never", policy == "always" || !focused,
      Double(value.duration) / 1_000_000_000 >= native.seconds("notify-on-command-finish-after", 5)
    else { return }
    let actions = native.value("notify-on-command-finish-action", UInt32(1))
    if actions & 1 != 0 { ringBell() }
    if actions & 2 != 0 {
      notify(
        title: "Command finished",
        body: value.exit_code < 0
          ? "The command has finished." : "The command exited with status \(value.exit_code).")
    }
  }

  func clearProgress() {
    progressTimer?.invalidate()
    progressTimer = nil
    progressAnimationTimer?.invalidate()
    progressAnimationTimer = nil
    NSApp.dockTile.contentView = nil
    NSApp.dockTile.badgeLabel = nil
    NSApp.dockTile.display()
  }

  func showProgress(_ report: ghostty_action_progress_report_s) {
    guard native.value("progress-style", true), report.state != GHOSTTY_PROGRESS_STATE_REMOVE else {
      clearProgress()
      return
    }
    let tile = NSApp.dockTile
    let container = NSView(frame: NSRect(origin: .zero, size: tile.size))
    let icon = NSImageView(frame: container.bounds)
    icon.image = NSApp.applicationIconImage
    container.addSubview(icon)
    let progress = NSProgressIndicator(
      frame: NSRect(x: 10, y: 7, width: max(20, tile.size.width - 20), height: 12))
    progress.style = .bar
    progress.isIndeterminate = report.state == GHOSTTY_PROGRESS_STATE_INDETERMINATE
    progress.minValue = 0
    progress.maxValue = 100
    progress.doubleValue = Double(max(0, report.progress))
    container.addSubview(progress)
    if progress.isIndeterminate { progress.startAnimation(nil) }
    progressAnimationTimer?.invalidate()
    progressAnimationTimer =
      progress.isIndeterminate
      ? Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in NSApp.dockTile.display()
      } : nil
    tile.contentView = container
    tile.badgeLabel =
      report.state == GHOSTTY_PROGRESS_STATE_ERROR
      ? "!" : report.state == GHOSTTY_PROGRESS_STATE_PAUSE ? "Ⅱ" : nil
    tile.display()
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
      self?.clearProgress()
    }
  }
}

extension TerminalWindowController {
  func secureInput(_ mode: ghostty_action_secure_input_e) {
    if mode == GHOSTTY_SECURE_INPUT_TOGGLE {
      manualSecureInput.toggle()
    } else {
      passwordInput = mode == GHOSTTY_SECURE_INPUT_ON
    }
    updateSecureInput()
  }
  func updateSecureInput(forceOff: Bool = false) {
    let wanted =
      !forceOff && NSApp.isActive && window?.isKeyWindow == true
      && (manualSecureInput || (passwordInput && native.value("macos-auto-secure-input", true)))
    if wanted != secureInputEnabled {
      if wanted {
        secureInputEnabled = EnableSecureEventInput() == noErr
      } else if DisableSecureEventInput() == noErr {
        secureInputEnabled = false
      }
    }
    var indicators: [String] = []
    if readonly { indicators.append("Read Only") }
    if secureInputEnabled && native.value("macos-secure-input-indication", true) {
      indicators.append("🔒 Secure Input")
    }
    chrome?.secure.stringValue = indicators.joined(separator: " · ")
  }
  func windowDidBecomeKey(_ notification: Notification) {
    owner?.windowFocused(self)
    updateSecureInput()
  }
  func windowDidResignKey(_ notification: Notification) { updateSecureInput(forceOff: true) }
}

final class TerminalWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
