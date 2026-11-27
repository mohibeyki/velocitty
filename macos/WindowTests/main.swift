// SPDX-License-Identifier: GPL-3.0
// AppKit regression executable, built by WindowChecks and launched by the test plans.
import AppKit
import VeloKit
import VelocittyConfiguration

precondition(velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
if ProcessInfo.processInfo.environment["VELOKIT_TEST_RESTORATION"] != nil {
  runRestorationCheck()
}
// Runs without NSApplication or a real herdr server, including in Core CI.
if CommandLine.arguments.contains("--headless") {
  try runHerdrControlCheck()
  try runLogicChecks()
  try runPersistenceCoordinationCheck()
  print("Headless checks passed.")
  exit(0)
}
let previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
pumpEvents(until: Date(timeIntervalSinceNow: 0.2))
let standaloneChecks: [(flag: String, run: () throws -> Void)] = [
  ("--remote-check", runRemoteCheck), ("--management-ui", runManagementUICheck), ("--scale", runScaleCheck),
  ("--mixed-connections", runMixedConnectionsCheck), ("--workspace-persistence", runWorkspacePersistenceCheck),
  ("--session-restore", runSessionRestoreCheck),
]
if let check = standaloneChecks.first(where: { CommandLine.arguments.contains($0.flag) }) {
  try check.run()
  exit(0)
}

// The remaining modes share one app delegate with two terminal windows.
let delegate = AppDelegate()
app.delegate = delegate
let testAutomaticQuit = CommandLine.arguments.contains("--quit-on-close")
let settings = try testSettings("undo_timeout = \"0s\"" + (testAutomaticQuit ? "\nquit_after_last_window_closed = true" : ""))
delegate.runtime = try TerminalRuntime(settings: settings)
delegate.installMainMenu()
delegate.updateMenuShortcuts()
let new = menuItem("New Window")
precondition(new.keyEquivalent == "n")
let closeMenuItem = menuItem("Close Window")
precondition(closeMenuItem.menu === new.menu)
precondition(!delegate.validateMenuItem(closeMenuItem))
for title in ["Find…", "Command Palette…"] {
  precondition(!delegate.validateMenuItem(menuItem(title)))
}
precondition(app.sendAction(new.action!, to: new.target, from: new))
waitUntil("The first window did not open") { delegate.windows.count == 1 }
let first = delegate.windows[0]
let terminal = first.session!.view!
let originalEngine = delegate.runtime!.app
precondition(app.sendAction(new.action!, to: new.target, from: new))
waitUntil("The second window did not open") { delegate.windows.count == 2 }
precondition(delegate.validateMenuItem(closeMenuItem))
let second = delegate.windows[1]
precondition(first.session?.view?.surface != second.session?.view?.surface)
precondition(first.session?.windowController === first)
precondition(second.session?.windowController === second)
precondition(second.window!.frame.minX > first.window!.frame.minX)
precondition(second.window!.frame.maxY < first.window!.frame.maxY)

if testAutomaticQuit { checkQuitAfterLastWindowCloses() }
if CommandLine.arguments.contains("--configuration-only") {
  try checkNativeSettings()
  try checkTitlebarStyles()
  try checkSharedEngine()
  try checkConfigurationReload()
  try checkVisualPolicies()
  closeAllWindows()
  print("Configuration reload tests passed.")
  exit(0)
}
checkCommittedText()
try checkQueuedWakeup()
try checkRestorationMetadata()
try checkAccessibility()
checkQuitPreservesWindows()
checkMissingHerdr()
checkWindowNavigation()
checkIndependentSheets()
try checkRetainedSession()
try checkFocusReporting()
checkLinkRouting()
checkClipboardQueue()
checkClipboardCancellation()
try checkUnattachedClipboard()
try checkClipboardAtPTY()
checkCloseAndQuit()
print("Window lifecycle tests passed.")

// MARK: - Shared helpers

/// Delivers AppKit events when an application is running, and main-queue work in any case.
func pumpEvents(until deadline: Date) {
  repeat {
    if let app = NSApp, let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
      inMode: .default, dequeue: true) {
      app.sendEvent(event)
    }
    NSApp?.updateWindows()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
  } while Date() < deadline
}
func drain() { pumpEvents(until: Date(timeIntervalSinceNow: 0.15)) }

/// Pumps events until the condition holds or the timeout passes, and returns the condition.
func pollUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
  let deadline = Date(timeIntervalSinceNow: timeout)
  while !condition() && Date() < deadline { pumpEvents(until: Date(timeIntervalSinceNow: 0.02)) }
  return condition()
}

/// Pumps events until the condition holds, failing with the message after the timeout.
func waitUntil(_ message: @autoclosure () -> String, timeout: TimeInterval = 3, _ condition: () -> Bool) {
  let satisfied = pollUntil(timeout: timeout, condition)
  precondition(satisfied, message())
}

/// Waits until no connection is opening and the window has no mux action running or queued.
/// The first pump lets work scheduled by the caller start before the flags are read.
func waitForMux(_ owner: AppDelegate, _ controller: TerminalWindowController? = nil, timeout: TimeInterval = 10) {
  pumpEvents(until: Date(timeIntervalSinceNow: 0.02))
  waitUntil("Mux work did not finish: opening=\(owner.muxOpening), busy=\(controller?.muxBusy == true), "
    + "queued=\(controller?.hasPendingMuxActions == true)", timeout: timeout) {
    !owner.muxOpening && controller?.muxBusy != true && controller?.hasPendingMuxActions != true
  }
}

func withTemporaryDirectory<T>(_ prefix: String, _ body: (URL) throws -> T) throws -> T {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try body(directory)
}

/// Settings for a plain, fast-starting test terminal, followed by extra TOML lines.
func testSettings(_ extra: String = "", command: String = "/bin/sh", saveState: String = "never") throws -> AppConfiguration {
  try AppConfiguration.parse(Data("""
  [terminal]
  command = \(ConfigurationDocument.quote(command))
  shell_integration = "none"
  theme = ""
  confirm_close_surface = false
  window_save_state = "\(saveState)"
  \(extra)
  """.utf8))
}

func menuItem(_ title: String, in menu: NSMenu = NSApp.mainMenu!) -> NSMenuItem {
  for item in menu.items {
    if item.title == title { return item }
    if let submenu = item.submenu,
      let found = submenu.items.first(where: { $0.title == title }) { return found }
  }
  fatalError("Missing menu: \(title)")
}

func closeAllWindows() {
  delegate.terminating = true
  for controller in delegate.windows {
    controller.closing = true
    controller.window?.close()
  }
}

func enterCommand(_ command: String, in pane: TerminalSession) {
  command.withCString { velokit_surface_text(pane.surface!, $0, UInt(command.utf8.count)) }
  var enter = ghostty_input_key_s()
  enter.action = GHOSTTY_ACTION_PRESS
  enter.keycode = 36
  _ = velokit_surface_key(pane.surface!, enter)
}

/// A window whose terminal runs a shell script that records its raw input, as seen at the PTY.
struct RecordingTerminal {
  let controller: TerminalWindowController
  let session: TerminalSession
  let view: TerminalView
  let input: URL
  func received() -> Data { (try? Data(contentsOf: input)) ?? Data() }
}

/// Opens a recording terminal with the given settings applied to the shared runtime;
/// the caller restores `settings`. `prelude` runs in raw mode before recording starts.
func openRecordingTerminal(in directory: URL, prelude: String = "", extra: String = "") throws -> RecordingTerminal {
  let script = directory.appendingPathComponent("record.sh")
  let input = directory.appendingPathComponent("input")
  let ready = directory.appendingPathComponent("ready")
  try Data("stty raw -echo\n\(prelude): > \"$2\"\nexec cat > \"$1\"\n".utf8).write(to: script)
  let command = "/bin/sh " + ShellInput.paths([script.path, input.path, ready.path])
  try delegate.runtime!.updateConfiguration(testSettings(extra, command: command))
  let session = delegate.runtime!.makeSession()
  let controller = TerminalWindowController(session: session, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  waitUntil("Recording terminal did not start") { FileManager.default.fileExists(atPath: ready.path) }
  return RecordingTerminal(controller: controller, session: session, view: session.view!, input: input)
}

/// Runs body with isolated herdr sessions whose servers use zsh and a private configuration.
/// The sessions are stopped and deleted afterwards, or by a watchdog if this process dies first.
func withIsolatedHerdr<T>(_ prefix: String, sessions count: Int = 1, executable: URL? = nil, root: URL? = nil,
  _ body: (URL, [HerdrClient]) throws -> T) throws -> T {
  guard let executable = executable ?? HerdrClient.discover() else { fatalError("herdr is required for this check") }
  let directory = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(prefix + "-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let config = directory.appendingPathComponent("herdr.toml")
  try Data("[terminal]\ndefault_shell='/bin/zsh'\n".utf8).write(to: config)
  let previousConfig = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
  defer {
    if let previousConfig { setenv("HERDR_CONFIG_PATH", previousConfig, 1) } else { unsetenv("HERDR_CONFIG_PATH") }
  }
  setenv("HERDR_CONFIG_PATH", config.path, 1)
  let clients = (0..<count).map { _ in HerdrClient(executable: executable, sessionName: prefix + "-" + UUID().uuidString.lowercased()) }
  let watchdog = startHerdrWatchdog(executable, sessions: clients.map(\.sessionName), directory: directory)
  defer {
    kill(watchdog, SIGKILL)
    waitpid(watchdog, nil, 0)
    for client in clients {
      _ = try? client.run(["server", "stop"])
      _ = try? client.run(["session", "delete", client.sessionName])
    }
  }
  return try body(directory, clients)
}

/// A detached shell that stops and deletes the sessions, and removes the directory, once this process
/// has exited, so a failed precondition or a timeout does not leave servers holding PTYs. Its own
/// session survives a signal sent to this process group.
private func startHerdrWatchdog(_ executable: URL, sessions: [String], directory: URL) -> pid_t {
  let herdr = "/usr/bin/env -u HERDR_SESSION -u HERDR_SOCKET_PATH " + ShellInput.quote(executable.path)
  let cleanup = sessions.map { name in
    "\(herdr) --session \(ShellInput.quote(name)) server stop; \(herdr) session delete \(ShellInput.quote(name))"
  }
  let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.5; done; " + cleanup.joined(separator: "; ")
    + "; rm -rf " + ShellInput.quote(directory.path)
  var attributes: posix_spawnattr_t?
  var actions: posix_spawn_file_actions_t?
  posix_spawnattr_init(&attributes)
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
  for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
    posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
  }
  let argv = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
  defer { argv.forEach { free($0) } }
  var pid: pid_t = 0
  let code = argv.withUnsafeBufferPointer { posix_spawn(&pid, "/bin/sh", &actions, &attributes, UnsafeMutablePointer(mutating: $0.baseAddress!), environ) }
  precondition(code == 0, "Could not start the herdr cleanup watchdog")
  return pid
}

// MARK: - Configuration reload (--configuration-only)

// AppKit may already have removed our tracked accessory during a style change.
func checkTitlebarStyles() throws {
  let unrelatedAccessory = NSTitlebarAccessoryViewController()
  unrelatedAccessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
  first.window!.addTitlebarAccessoryViewController(unrelatedAccessory)
  first.titleAccessory = NSTitlebarAccessoryViewController()
  first.applyWindowSettings()
  precondition(first.window!.titlebarAccessoryViewControllers.contains(unrelatedAccessory))
  first.window!.removeTitlebarAccessoryViewController(at: 0)
  for (index, style) in ["hidden", "native", "transparent", "hidden", "native"].enumerated() {
    let scrollbar = index.isMultiple(of: 2) ? "never" : "system"
    try first.session!.runtime.updateConfiguration(testSettings("""
    window_title_font_family = "Menlo"
    macos_titlebar_style = "\(style)"
    scrollbar = "\(scrollbar)"
    """))
    first.chrome!.scrollState = ghostty_action_scrollbar_s(total: 100, offset: 0, len: 10)
    first.applyWindowSettings()
    precondition(first.chrome!.showScroll == (scrollbar == "system"))
    precondition((first.titleAccessory == nil) == (style == "hidden"))
  }
  try first.session!.runtime.updateConfiguration(settings)
  first.applyWindowSettings()
}

// Native settings, read through the Swift accessors, and native diagnostics. These need
// NSApplication for the appearance used when preparing a configuration.
func checkNativeSettings() throws {
  // Verify the Swift accessors against finalized native values, including C conversions.
  let typedSettings = try AppConfiguration.parse(Data("""
  [terminal]
  theme = ""
  initial_window = false
  window_position_x = -24
  background_blur = "macos-glass-regular"
  background_opacity = 0.625
  background = "#123456"
  bell_features = "audio"
  bell_audio_path = "/tmp"
  window_title_font_family = "Menlo"
  resize_overlay_duration = "1250ms"
  command_palette_entry = ['title:Typed read,action:copy_to_clipboard']
  """.utf8))
  let config = try TerminalRuntime.makeConfig(typedSettings)
  let native = NativeSettings(config: config)
  precondition(!native.initialWindow)
  precondition(native.windowPositionX == -24)
  precondition(native.backgroundBlur == -1)
  precondition(native.backgroundOpacity == 0.625)
  precondition(native.bellFeatures == [.audio, .attention, .title]) // audio plus default attention/title
  precondition(native.titleFontFamily == "Menlo")
  precondition(native.resizeOverlayDuration == 1.25)
  let color = native.background.usingColorSpace(.sRGB)!
  precondition(abs(color.redComponent - 18.0 / 255) < 0.0001)
  let commands = native.commands
  let path = native.bellAudioPath
  velokit_config_free(config)
  precondition(path == "/tmp")
  precondition(commands.contains { $0.title == "Typed read" && $0.actionKey == "copy_to_clipboard" })
  let missing = NativeSettings(config: nil)
  precondition(missing.initialWindow && missing.backgroundOpacity == 1)
  precondition(missing.windowPositionX == Int16.min && missing.commands.isEmpty)
  try withTemporaryDirectory("velocitty-diagnostics") { directory in
    // Native diagnostics identify the included file that produced them.
    let root = directory.appendingPathComponent("config.toml")
    let included = directory.appendingPathComponent("included.toml")
    try Data("[terminal]\nconfig_file = [\"included.toml\"]\ntheme = \"\"".utf8).write(to: root)
    try Data("[terminal]\nfont_size = \"not-a-number\"".utf8).write(to: included)
    var diagnostics: [String] = []
    velokit_config_free(try TerminalRuntime.makeConfig(AppConfiguration.load(from: root)) { diagnostics.append($0) })
    precondition(diagnostics.count == 1 && diagnostics[0].hasPrefix(included.path + ":"))
  }
}

// One engine serves every session, including native all/global surface actions.
func checkSharedEngine() throws {
  let runtime = delegate.runtime!
  precondition(first.session!.runtime === runtime && second.session!.runtime === runtime)
  precondition(runtime.context.owner === delegate)
  let firstSurface = first.session!.surface!
  let secondSurface = second.session!.surface!
  let originalCell = velokit_surface_size(firstSurface).cell_height_px
  func configured(_ opacity: Double) throws -> AppConfiguration {
    try testSettings("""
    font_size = 24
    background_opacity = \(opacity)
    keybind = ["all:ctrl+shift+a=set_surface_title:Broadcast", "global:ctrl+shift+b=set_surface_title:Global"]
    """)
  }
  try runtime.updateConfiguration(configured(0.4))
  waitUntil("The cell size did not follow the font") { velokit_surface_size(firstSurface).cell_height_px > originalCell }
  precondition(velokit_surface_size(firstSurface).cell_height_px == velokit_surface_size(secondSurface).cell_height_px)
  let scoped = try TerminalRuntime.makeConfig(AppConfiguration.parse(Data("""
  [terminal]
  theme = ""
  font_size = 36
  """.utf8)))
  precondition(velokit_surface_update_config(firstSurface, scoped))
  velokit_config_free(scoped)
  let scopedFontSize = String(cString: velokit_config_format(first.session!.config!, "font-size")!)
  precondition(scopedFontSize == "font-size = 36\n", "The host must copy the borrowed applied configuration")
  waitUntil("The scoped font change did not apply") { velokit_surface_size(firstSurface).cell_height_px > velokit_surface_size(secondSurface).cell_height_px }
  precondition(velokit_surface_size(firstSurface).cell_height_px > velokit_surface_size(secondSurface).cell_height_px,
    "A surface-only update must leave sibling terminals unchanged")
  try runtime.updateConfiguration(configured(0.4))
  drain()
  first.session!.view!.performSurfaceAction("toggle_background_opacity")
  waitUntil("The opacity toggle did not apply") { first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.4 }
  precondition(delegate.native.backgroundOpacity == 0.4)
  delegate.newWindow()
  waitUntil("The third window did not open") { delegate.windows.count == 3 }
  let third = delegate.windows.last!
  precondition(third.session!.runtime === runtime && third.native.backgroundOpacity == 0.4)
  third.closing = true
  third.window!.close()
  waitUntil("The third window did not close") { delegate.windows.count == 2 }
  precondition(delegate.runtime === runtime && first.session!.surface == firstSurface)
  try runtime.updateConfiguration(configured(0.6))
  waitUntil("The reloaded opacity did not apply") { first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.6 }
  first.session!.view!.performSurfaceAction("toggle_background_opacity")
  waitUntil("The opacity toggle did not revert") { first.native.backgroundOpacity == 0.6 && second.native.backgroundOpacity == 0.6 }
  let broadcast = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.window!.windowNumber,
    context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
  first.session!.view!.sendKey(broadcast, action: GHOSTTY_ACTION_PRESS)
  waitUntil("The broadcast binding did not apply") { first.window!.title == "Broadcast" && second.window!.title == "Broadcast" }
  var global = ghostty_input_key_s()
  global.action = GHOSTTY_ACTION_PRESS
  global.keycode = 11 // physical B
  global.mods = ghostty_input_mods_e(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
  global.unshifted_codepoint = 98
  precondition(velokit_app_key(runtime.app!, global))
  waitUntil("The global binding did not apply") { first.window!.title == "Global" && second.window!.title == "Global" }
  precondition(first.session!.surface == firstSurface && second.session!.surface == secondSurface)
  try runtime.updateConfiguration(settings)
  drain()
}

// Reload bad values alongside valid settings without replacing terminals or losing overrides.
func checkConfigurationReload() throws {
  let runtime = delegate.runtime!
  let firstSurface = first.session!.surface!
  let secondSurface = second.session!.surface!
  try withTemporaryDirectory("velocitty-reload") { directory in
    let file = directory.appendingPathComponent("config.toml")
    try Data("""
    [terminal]
    command = "/bin/sh"
    shell_integration = "none"
    confirm_close_surface = false
    window_save_state = "never"
    theme = "missing-theme"
    font_size = "nan"
    cursor_style = "not-a-style"
    background_opacity = 0.45
    scrollbar = "system"
    title = "Reloaded"
    window_titlebar_foreground = "not-a-color"
    window_titlebar_background = "not-a-color"
    palette = ["0=#112233", "invalid", "1=#445566"]
    keybind = ["super+f=unbind", "invalid-key=invalid-action", "super+shift+c=copy_to_clipboard"]
    working_directory = "relative"
    """.utf8).write(to: file)
    try first.session!.toggleOpacity()
    try runtime.updateConfiguration(AppConfiguration.load(from: file))
    waitUntil("The reloaded configuration did not apply") {
      runtime.diagnostics.count == 8 && first.window!.title == "Reloaded" && second.window!.title == "Reloaded"
        && first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.45
    }
    precondition(runtime.diagnostics.count == 8, runtime.diagnostics.joined(separator: "\n"))
    precondition(first.session!.surface == firstSurface && second.session!.surface == secondSurface)
    precondition(first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.45)
    precondition(second.window!.backgroundColor == .windowBackgroundColor,
      "Native window chrome stays independent of terminal opacity")
    precondition(first.window!.title == "Reloaded" && second.window!.title == "Reloaded")
    precondition(first.titleAccessory == nil && second.titleAccessory == nil,
      "Rejected titlebar colors must not enable custom titlebars")
    precondition(menuItem("Find…").keyEquivalent.isEmpty, "super+f=unbind must clear the Find menu shortcut")
    let defaults = try TerminalRuntime.makeConfig(.defaults())
    defer { velokit_config_free(defaults) }
    let defaultFontSize = String(cString: velokit_config_format(defaults, "font-size")!)
    precondition(String(cString: velokit_config_format(runtime.config!, "font-size")!) == defaultFontSize)
    let palette = String(cString: velokit_config_format(runtime.config!, "palette")!)
    precondition(palette.contains("0=#112233") && palette.contains("1=#445566"), palette)
    precondition(runtime.settings.workingDirectory == AppConfiguration.defaults().workingDirectory)

    delegate.showConfigurationDiagnostics()
    waitUntil("The diagnostics sheet did not appear") { delegate.activeWindow?.window?.attachedSheet != nil }
    let diagnosticWindow = delegate.activeWindow!.window!
    precondition(diagnosticWindow.attachedSheet != nil, "Reload diagnostics must be visible")
    diagnosticWindow.endSheet(diagnosticWindow.attachedSheet!)
    waitUntil("The diagnostics sheet did not close") { diagnosticWindow.attachedSheet == nil }

    // Overrides use already prepared theme colors, even if the theme disappears.
    let themeFile = directory.appendingPathComponent("custom.itermcolors")
    let color: [String: Any] = ["Red Component": 0.25, "Green Component": 0.5,
      "Blue Component": 0.75, "Color Space": "sRGB"]
    try PropertyListSerialization.data(fromPropertyList:
      ["Background Color": color, "Foreground Color": color], format: .xml, options: 0)
      .write(to: themeFile)
    let custom = try AppConfiguration.parse(Data("[terminal]\ntheme = '\(themeFile.path)'".utf8))
    let prepared = try TerminalRuntime.makeConfig(custom)
    defer { velokit_config_free(prepared) }
    try FileManager.default.removeItem(at: themeFile)
    let override = try first.session!.prepareOverride(from: prepared)!
    precondition(first.session!.applyPreparedConfiguration(override))
    velokit_config_free(override)
    precondition(first.native.backgroundOpacity == 1)
    precondition(first.native.background == NativeSettings(config: prepared).background)
  }
  // A subsequent clean reload clears diagnostics and the opacity toggle still works.
  try runtime.updateConfiguration(settings)
  try first.session!.toggleOpacity()
  waitUntil("The clean reload did not clear diagnostics") { runtime.diagnostics.isEmpty && first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 1 }
  precondition(runtime.diagnostics.isEmpty)
  precondition(first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 1)
}

// Native visual policies retain their distinct meanings.
func checkVisualPolicies() throws {
  let runtime = delegate.runtime!
  for blur in ["12", "macos-glass-regular", "macos-glass-clear", "false"] {
    try runtime.updateConfiguration(testSettings("""
    background_opacity = 0.5
    bell_features = "no-attention,no-title,border"
    background_blur = "\(blur)"
    """))
    drain()
    if #available(macOS 26, *), blur.hasPrefix("macos-glass") {
      let effect = first.window!.contentView as! NSGlassEffectView
      precondition(effect.style == (blur.hasSuffix("clear") ? .clear : .regular))
      precondition(effect.contentView === first.workspaceView)
    } else {
      precondition(first.window!.contentView === first.workspaceView)
    }
    precondition(first.session!.surface != nil && !first.window!.isOpaque)
  }
  first.ringBell()
  waitUntil("The bell did not register") { first.hasBell }
  precondition(first.hasBell && first.chrome!.layer!.borderWidth == 3)
  first.clearBell()
  precondition(!first.hasBell && first.chrome!.layer!.borderWidth == 0)
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_SURFACE
  target.target.surface = first.session!.surface
  var action = ghostty_action_s()
  action.tag = GHOSTTY_ACTION_SIZE_LIMIT
  action.action.size_limit.min_width = 200
  action.action.size_limit.min_height = 100
  action.action.size_limit.max_width = 1600
  action.action.size_limit.max_height = 1200
  precondition(runtime.context.handleAction(target: target, action: action))
  waitUntil("The size limit did not apply") { first.window!.contentMaxSize.width == 1600 / first.window!.backingScaleFactor }
  let scale = first.window!.backingScaleFactor
  precondition(first.window!.contentMaxSize.width == 1600 / scale)
  precondition(first.window!.contentMinSize.height == 100 / scale)
  action.action.size_limit.max_width = 0
  action.action.size_limit.max_height = 0
  precondition(runtime.context.handleAction(target: target, action: action))
  waitUntil("The size limit did not clear") { first.window!.contentMaxSize.width > 100_000 }
  try runtime.updateConfiguration(settings)
  drain()
}

// MARK: - Last-window quit (--quit-on-close)

func checkQuitAfterLastWindowCloses() -> Never {
  precondition(delegate.native.quitAfterLastWindowClosed)
  first.window?.performClose(nil)
  waitUntil("The window did not close") { delegate.windows.count == 1 }
  precondition(delegate.quitTimer == nil || delegate.quitTimer?.isValid == false)
  let observer = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: app, queue: .main
  ) { _ in
    precondition(delegate.windows.isEmpty)
    try! FileHandle.standardOutput.write(contentsOf: Data("Last-window quit test passed.\n".utf8))
  }
  second.window?.performClose(nil)
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
  withExtendedLifetime(observer) { fatalError("Closing the last window did not quit") }
}

// MARK: - Window lifecycle (default)

// Exercise the keyboard-event/committed-text bridge, not the paste path.
func checkCommittedText() {
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: first.window!.windowNumber, context: nil,
    characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
  for text in ["a", "Ａ！", "🙂", "𠮷", "e\u{301}"] {
    precondition(terminal.withKey(event, action: GHOSTTY_ACTION_PRESS, overrideText: text) {
      $0.text.map { String(cString: $0) } == text
    })
  }
  for text in ["\u{1b}", "\u{F700}", "\u{F8FF}"] {
    precondition(terminal.withKey(event, action: GHOSTTY_ACTION_PRESS, overrideText: text) {
      $0.text == nil
    })
  }
}

// A queued wakeup can outlive its runtime, but must not retain a native handle.
func checkQueuedWakeup() throws {
  var runtime: TerminalRuntime? = try TerminalRuntime(settings: settings)
  let context = runtime!.context
  RuntimeContext.wakeup(Unmanaged.passUnretained(context).toOpaque())
  runtime = nil
  precondition(context.app == nil)
  context.tick()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
}

// AppKit restores each window's own metadata; ordinary new windows still cascade.
func checkRestorationMetadata() throws {
  let runtime = delegate.runtime!
  try runtime.updateConfiguration(testSettings("window_position_x = 80\nwindow_position_y = 70", saveState: "always"))
  delegate.newWindow()
  let placed = delegate.windows.last!
  waitUntil("The window was not placed") { abs(placed.window!.frame.minX - placed.window!.screen!.visibleFrame.minX - 80) < 1 }
  let visible = placed.window!.screen!.visibleFrame
  precondition(abs(placed.window!.frame.minX - visible.minX - 80) < 1)
  precondition(abs(placed.window!.frame.maxY - visible.maxY + 70) < 1)
  precondition(!placed.window!.isRestorable, "Custom commands must not be replayed by restoration")
  let savedTitle = first.windowTitleOverride
  first.windowTitleOverride = "First restored terminal"
  second.windowTitleOverride = "Second restored terminal"
  for original in [first, second] {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    original.window(original.window!, willEncodeRestorableState: coder)
    coder.finishEncoding()
    let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
    decoder.requiresSecureCoding = true
    decoder.decodingFailurePolicy = .setErrorAndReturn
    var restored: NSWindow?
    TerminalWindowRestoration.restoreWindow(withIdentifier: TerminalWindowRestoration.identifier,
      state: decoder) { window, error in
        precondition(error == nil)
        restored = window
      }
    guard let restored, let controller = delegate.windows.first(where: { $0.window === restored }) else {
      fatalError("Window metadata did not restore")
    }
    precondition(restored.title == original.windowTitleOverride)
    precondition(controller.currentDirectory == original.currentDirectory)
    controller.closing = true
    restored.close()
  }
  first.windowTitleOverride = savedTitle
  second.windowTitleOverride = nil
  first.setTitle(first.terminalTitle)
  second.setTitle(second.terminalTitle)
  placed.closing = true
  placed.window?.close()
  try runtime.updateConfiguration(settings)
  drain()
}

// Read actual rendered Unicode, then map its selection to AppKit UTF-16 indices.
func checkAccessibility() throws {
  let runtime = delegate.runtime!
  try runtime.updateConfiguration(testSettings(command: #"/bin/sh -c 'printf "AX 😀 café\nsecond line\n"; exec cat'"#))
  delegate.newWindow()
  let controller = delegate.windows.last!
  let view = controller.session!.view!
  var snapshot = TerminalTextSnapshot()
  waitUntil("Rendered text did not appear", timeout: 5) {
    snapshot = TerminalTextSnapshot.read(view.surface!)
    return snapshot.text.contains("AX 😀 café")
  }
  var accessibilityNotifications: [NSAccessibility.Notification] = []
  view.postAccessibility = { _, notification in accessibilityNotifications.append(notification) }
  _ = view.accessibilityValue() // Start observing only after an AX client asks for text.
  view.performSurfaceAction("select_all")
  waitUntil("Selection did not notify") { accessibilityNotifications.contains(.selectedTextChanged) }
  let content = view.accessibilityValue() as! String
  precondition(view.accessibilityNumberOfCharacters() == content.utf16.count)
  let selected = view.accessibilitySelectedTextRange()
  precondition(selected.location != NSNotFound && NSMaxRange(selected) <= content.utf16.count)
  precondition(view.accessibilitySelectedText()?.contains("AX 😀 café") == true)
  let emoji = (content as NSString).range(of: "😀")
  precondition(emoji.length == 2 && view.accessibilityString(for: emoji) == "😀")
  let emojiFrame = view.accessibilityFrame(for: emoji)
  let letterFrame = view.accessibilityFrame(for: (content as NSString).range(of: "A"))
  precondition(emojiFrame.width > letterFrame.width * 1.5 && emojiFrame.height > 0)
  precondition(emojiFrame.width < view.bounds.width / 4)
  precondition(view.accessibilityFrame(for: NSRange(location: Int.max, length: 1)) == .zero)
  // New output must notify without another keypress or AX query.
  accessibilityNotifications.removeAll()
  let input = "AX changed output\n"
  input.withCString { velokit_surface_text(view.surface!, $0, UInt(input.utf8.count)) }
  waitUntil("New output did not notify") { accessibilityNotifications.contains(.valueChanged) }
  let dropped = NSPasteboard.withUniqueName()
  defer { dropped.releaseGlobally() }
  let droppedFile = URL(fileURLWithPath: "/tmp/AX-drop-'quoted'.txt")
  dropped.writeObjects([droppedFile as NSURL])
  controller.readonly = true
  precondition(!view.insertDrop(from: dropped))
  controller.readonly = false
  precondition(view.insertDrop(from: dropped))
  waitUntil("Dropped path did not reach the terminal") { TerminalTextSnapshot.read(view.surface!).text.contains("AX-drop-") }
  precondition(view.accessibilityLine(for: (content as NSString).range(of: "second").location)
    == view.accessibilityLine(for: (content as NSString).range(of: "AX 😀 café").location) + 1, "Unexpected AX lines: \(content.debugDescription)")
  precondition(view.accessibilityString(for: NSRange(location: Int.max, length: 1)) == nil)
  controller.closing = true
  controller.window?.close()
  precondition((view.accessibilityValue() as? String) == "")
  precondition(view.accessibilityTimer == nil && view.accessibilitySelectionWork == nil)
  precondition(!view.insertDrop(from: dropped))
  try runtime.updateConfiguration(settings)
  drain()
}

// Quit preserves windows for AppKit state capture, then closes native sessions.
func checkQuitPreservesWindows() {
  let runtime = delegate.runtime!
  let quitter = AppDelegate()
  quitter.runtime = runtime
  quitter.newWindow()
  let controller = quitter.windows.last!
  precondition(quitter.applicationShouldTerminate(app) == .terminateNow)
  precondition(controller.window != nil && controller.session?.surface != nil)
  let coder = NSKeyedArchiver(requiringSecureCoding: true)
  controller.window(controller.window!, willEncodeRestorableState: coder)
  coder.finishEncoding()
  quitter.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
  precondition(controller.window != nil && controller.session?.surface == nil)
  controller.closing = true
  controller.window?.close()
  quitter.runtime = nil
  runtime.context.owner = delegate
}

// Missing herdr leaves a plain terminal and rejects local multiplexing.
func checkMissingHerdr() {
  delegate.newLocalWindow()
  let controller = delegate.windows.last!
  precondition(controller.workspaceView.muxEnabled == false)
  controller.newTab()
  precondition(controller.tabs.count == 1 && controller.namespaces.count == 1)
  if let sheet = controller.window?.attachedSheet {
    controller.window?.endSheet(sheet)
    sheet.orderOut(nil)
  }
  controller.closing = true
  controller.window?.close()
}

// Native window navigation uses creation order, not the current stacking order.
func checkWindowNavigation() {
  let empty = AppDelegate()
  empty.gotoWindow(GHOSTTY_GOTO_WINDOW_NEXT, from: nil)
  empty.gotoWindow(GHOSTTY_GOTO_WINDOW_PREVIOUS, from: nil)
  precondition(empty.windows.isEmpty && empty.runtime == nil)

  delegate.newWindow()
  waitUntil("The third window did not open") { delegate.windows.count == 3 }
  let third = delegate.windows.last!
  func cycle(_ source: TerminalWindowController, _ direction: String,
    to destination: TerminalWindowController)
  {
    let action = "goto_window:" + direction
    precondition(action.withCString {
      velokit_surface_binding_action(source.session!.surface!, $0, UInt(action.utf8.count))
    })
    waitUntil("Window cycling did not focus the expected destination") {
      app.isActive && destination.window!.isKeyWindow && !destination.window!.isMiniaturized
    }
    precondition(delegate.windows.count == 3)
  }
  first.window!.makeKeyAndOrderFront(nil)
  cycle(first, "next", to: second)
  cycle(second, "next", to: third)
  cycle(third, "next", to: first)
  cycle(first, "previous", to: third)
  cycle(third, "previous", to: second)

  second.window!.miniaturize(nil)
  waitUntil("Destination did not minimize") { second.window!.isMiniaturized }
  first.window!.makeKeyAndOrderFront(nil)
  cycle(first, "next", to: second)

  // Closing entries cannot become destinations, even before deregistration.
  third.closing = true
  cycle(second, "next", to: first)
  third.window!.close()
  waitUntil("The window did not close") { delegate.windows.count == 2 }
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_APP
  var action = ghostty_action_s()
  action.tag = GHOSTTY_ACTION_GOTO_WINDOW
  action.action.goto_window = GHOSTTY_GOTO_WINDOW_PREVIOUS
  precondition(delegate.runtime!.context.handleAction(target: target, action: action))
  waitUntil("App navigation did not wrap past the closed window") { second.window!.isKeyWindow }
  precondition(delegate.windows[0] === first && delegate.windows[1] === second)
}

// Independent sessions retain independent sheets, and queued callbacks cannot reach replacements.
func checkIndependentSheets() {
  let runtime = delegate.runtime!
  delegate.newWindow()
  let closing = delegate.windows.last!
  let session = closing.session!
  let view = session.view!
  session.links = TerminalLinks { _ in fatalError("Unexpected external opening") }
  first.session!.links = TerminalLinks { _ in fatalError("Unexpected external opening") }
  session.links.open("custom:closing", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: view)
  first.session!.links.open("custom:surviving", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: first.session!.view)
  precondition(session.links.confirmation != nil && first.session!.links.confirmation != nil)
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_SURFACE
  target.target.surface = session.surface
  var title = ghostty_action_s()
  title.tag = GHOSTTY_ACTION_SET_TITLE
  "Stale title".withCString {
    title.action.set_title.title = $0
    precondition(runtime.context.handleAction(target: target, action: title))
  }
  RuntimeContext.closeSurface(Unmanaged.passUnretained(view).toOpaque(), false)
  closing.closing = true
  closing.window!.close()
  delegate.newWindow()
  let replacement = delegate.windows.last!
  drain() // Lets the stale title callback queued for the closed window run.
  precondition(replacement.window != nil && replacement.window!.title != "Stale title")
  precondition(first.session!.links.confirmation != nil && session.links.confirmation == nil)
  first.session!.links.cancel()
  replacement.closing = true
  replacement.window!.close()
  waitUntil("The replacement window did not close") { delegate.windows.count == 2 }
}

// A retained session keeps the engine alive; a retained view does not own either resource.
func checkRetainedSession() throws {
  var runtime: TerminalRuntime? = try TerminalRuntime(settings: settings)
  weak var weakRuntime: TerminalRuntime?
  weakRuntime = runtime
  var session: TerminalSession? = runtime!.makeSession()
  let view = session!.createView()!
  let surface = session!.surface
  let context = runtime!.context
  runtime = nil
  precondition(weakRuntime != nil && view.surface == surface)
  precondition(session!.createView() === view, "Repeated presentation must reuse the same terminal")
  RuntimeContext.wakeup(Unmanaged.passUnretained(context).toOpaque())
  session = nil
  precondition(weakRuntime == nil && context.app == nil)
  precondition(view.surface == nil && view.config == nil)
  drain()
}

// Observe focus reports and committed text at the PTY, not a mirrored Swift flag.
func checkFocusReporting() throws {
  try withTemporaryDirectory("velocitty-focus") { directory in
    let runtime = delegate.runtime!
    defer { try! runtime.updateConfiguration(settings) }
    let recorder = try openRecordingTerminal(in: directory, prelude: "printf '\\033[?1004h'\n")
    let controller = recorder.controller
    let window = controller.window!
    let terminal = recorder.view
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminal)
    waitUntil("Test application did not activate: active=\(app.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), keyWindow=\(String(describing: app.keyWindow)), target=\(window)") { app.isActive && window.isKeyWindow }
    drain()
    var expected = recorder.received()
    func expect(_ delta: String, _ message: String) {
      expected.append(Data(delta.utf8))
      waitUntil("\(message); expected \(Array(expected)), received \(Array(recorder.received())); "
        + "active=\(app.isActive) key=\(window.isKeyWindow) "
        + "responder=\(window.firstResponder === terminal) sheet=\(window.attachedSheet != nil)") {
        recorder.received() == expected
      }
    }
    first.window!.makeKeyAndOrderFront(nil)
    expect("\u{1b}[O", "Background terminal did not report focus loss")
    precondition(window.firstResponder === terminal)
    window.makeFirstResponder(terminal) // A background first responder is still unfocused.
    runtime.updateFocus()
    drain()
    precondition(recorder.received() == expected)
    window.makeKeyAndOrderFront(nil)
    expect("\u{1b}[I", "Returning to a terminal did not report focus gain")
    controller.chrome!.startSearch(nil)
    expect("\u{1b}[O", "Search retained terminal focus")
    controller.chrome!.hideSearch()
    expect("\u{1b}[I", "Leaving search did not restore focus")
    controller.showCommands()
    expect("\u{1b}[O", "Command palette retained terminal focus")
    controller.palette!.close()
    window.makeKeyAndOrderFront(nil)
    expect("\u{1b}[I", "Closing the palette did not restore focus")
    guard let previous = previouslyActiveApplication,
      previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
      fatalError("Focus tests require another foreground application")
    }
    precondition(previous.activate(options: []))
    waitUntil("Test application did not deactivate") { !app.isActive }
    expect("\u{1b}[O", "App deactivation retained terminal focus")
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    waitUntil("Test application did not reactivate") { app.isActive && window.isKeyWindow }
    expect("\u{1b}[I", "App reactivation did not restore terminal focus")
    recorder.session.links = TerminalLinks { _ in fatalError("Unexpected link opening") }
    recorder.session.links.open("custom:focus-test", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: terminal)
    expect("\u{1b}[O", "Confirmation sheet retained terminal focus")
    recorder.session.links.cancel()
    // AppKit may choose a different key window after programmatic cancellation.
    window.makeKeyAndOrderFront(nil)
    expect("\u{1b}[I", "Refocusing after the sheet did not restore terminal focus")
    // Simulate NSTextInputClient composition, leaving native commit/discard callbacks intact.
    terminal.setMarkedText("にほん" as NSString, selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    first.window!.makeKeyAndOrderFront(nil)
    expect("\u{1b}[O", "Composition focus loss was not forwarded")
    runtime.updateFocus()
    precondition(terminal.markedText.string == "にほん")
    window.makeKeyAndOrderFront(nil)
    expect("\u{1b}[I", "Composition focus gain was not forwarded")
    precondition(terminal.markedText.string == "にほん")
    terminal.keyInProgress = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
    terminal.insertText("日本" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    terminal.insertText("" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    terminal.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    terminal.keyInProgress = nil
    expect("日本", "Committed composition must not leak Return or duplicate input")
    precondition(!terminal.hasMarkedText())
    terminal.removeFromSuperview()
    expect("\u{1b}[O", "Detached view retained focus")
    controller.chrome!.addSubview(terminal)
    window.makeFirstResponder(terminal)
    expect("\u{1b}[I", "Reattached view did not restore focus")
    controller.closing = true
    window.close()
    waitUntil("The window did not close") { delegate.windows.count == 2 }
  }
}

// Exercise the actual native action routing with a fake OS opener.
func checkLinkRouting() {
  let openWindows = delegate.windows.count
  delegate.newWindow()
  waitUntil("The window did not open") { delegate.windows.count == openWindows + 1 }
  let controller = delegate.windows.last!
  let context = controller.session!.runtime.context
  var opened: [URL] = []
  controller.session!.links = TerminalLinks { opened.append($0) }
  let links = controller.session!.links
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_SURFACE
  target.target.surface = controller.session!.view!.surface
  func sendLink(_ value: String, kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_OSC8) {
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_OPEN_URL
    value.withCString {
      action.action.open_url = ghostty_action_open_url_s(kind: kind, url: $0, len: UInt(value.utf8.count))
      precondition(context.handleAction(target: target, action: action))
    }
    drain()
  }
  sendLink("https://example.com")
  precondition(opened.count == 1 && links.confirmation == nil)
  var invalidAction = ghostty_action_s()
  invalidAction.tag = GHOSTTY_ACTION_OPEN_URL
  let invalidUTF8: [CChar] = [-1]
  invalidUTF8.withUnsafeBufferPointer {
    invalidAction.action.open_url = ghostty_action_open_url_s(
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, url: $0.baseAddress, len: 1)
    precondition(context.handleAction(target: target, action: invalidAction))
  }
  drain()
  precondition(opened.count == 1 && links.confirmation == nil)
  sendLink("javascript:alert(1)")
  precondition(opened.count == 1 && links.confirmation == nil)
  sendLink("/tmp/terminal export.html", kind: GHOSTTY_ACTION_OPEN_URL_KIND_HTML)
  precondition(opened.count == 2 && opened.last!.isFileURL && links.confirmation == nil)
  let destination = "vscode://file/tmp/" + String(repeating: "long-path/", count: 100) + "test"
  sendLink(destination)
  let alert = links.confirmation!
  precondition(alert.window.sheetParent === controller.window)
  precondition(alert.buttons[0].title == "Cancel" && alert.buttons[0].keyEquivalent == "\r", String(describing: alert.buttons.map { ($0.title, $0.keyEquivalent) }))
  precondition(alert.buttons[1].keyEquivalent.isEmpty)
  let text = (alert.accessoryView as! NSScrollView).documentView as! NSTextView
  precondition(text.string == URL(string: destination)!.absoluteString && text.isSelectable)
  text.layoutManager?.ensureLayout(for: text.textContainer!)
  precondition(text.frame.height > (alert.accessoryView as! NSScrollView).contentSize.height)
  sendLink("file:///tmp/another") // A second request must not replace the pending destination.
  precondition(links.confirmation === alert && opened.count == 2)
  let cancelKey = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: alert.window.windowNumber, context: nil,
    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
  precondition(alert.buttons[0].performKeyEquivalent(with: cancelKey))
  waitUntil("The next queued link did not appear") { links.confirmation != nil && links.confirmation !== alert }
  precondition(links.confirmation != nil && links.confirmation !== alert,
    "The next queued link should appear after cancelling the first")
  let queuedText = (links.confirmation!.accessoryView as! NSScrollView).documentView as! NSTextView
  precondition(queuedText.string == "file:///tmp/another")
  links.confirmation!.buttons[0].performClick(nil)
  waitUntil("The link confirmation did not finish") { links.confirmation == nil && opened.count == 2 }
  precondition(links.confirmation == nil && opened.count == 2,
    "Return cancellation: active=\(app.isActive), key=\(alert.window.isKeyWindow), "
      + "modifiers=\(alert.buttons[0].keyEquivalentModifierMask.rawValue), "
      + "default=\(String(describing: alert.window.defaultButtonCell?.title)), opened=\(opened.count)")
  sendLink(destination)
  links.confirmation!.buttons[1].performClick(nil)
  waitUntil("The link was not opened") { opened.count == 3 }
  precondition(opened.count == 3 && opened.last!.absoluteString == destination)
  sendLink("file:///tmp/test")
  precondition(links.confirmation != nil)
  controller.closing = true
  controller.window!.close()
  waitUntil("The link confirmation did not close with its window") { links.confirmation == nil }
  precondition(links.confirmation == nil && opened.count == 3)
  precondition(delegate.windows.count == 2)
}

func openPlainWindow() -> (TerminalWindowController, TerminalSession, TerminalView) {
  let session = delegate.runtime!.makeSession()
  let controller = TerminalWindowController(session: session, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  return (controller, session, session.view!)
}

// Clipboard ownership: queue order, other sheets, and exactly-once teardown replies.
func checkClipboardQueue() {
  let (controller, session, view) = openPlainWindow()
  let queue = view.clipboard
  var replies: [(Int, Bool, Bool)] = []
  func enqueue(_ id: Int) {
    queue.enqueue(title: "Clipboard test \(id)", message: "Test", canRemember: true) { allow, remember in
      precondition(view.surface != nil, "Reply must precede native surface destruction")
      replies.append((id, allow, remember))
    }
  }
  enqueue(1)
  enqueue(2)
  waitUntil("The clipboard confirmation did not appear") { queue.confirmation != nil }
  let firstAlert = queue.confirmation!
  precondition(firstAlert.messageText == "Clipboard test 1" && replies.isEmpty)
  firstAlert.suppressionButton!.state = .on
  firstAlert.buttons[0].performClick(nil)
  waitUntil("The first clipboard reply was not sent") { replies.count == 1 }
  precondition(replies.count == 1 && replies[0].0 == 1 && replies[0].1 && replies[0].2)
  precondition(queue.confirmation!.messageText == "Clipboard test 2")
  queue.confirmation!.suppressionButton!.state = .on
  queue.confirmation!.buttons[1].performClick(nil)
  waitUntil("The second clipboard reply was not sent") { replies.count == 2 }
  precondition(replies.count == 2 && replies[1].0 == 2 && !replies[1].1 && !replies[1].2)
  precondition(queue.confirmation == nil)

  controller.window!.makeKeyAndOrderFront(nil)
  session.links.open("custom:clipboard-test", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: view)
  precondition(session.links.confirmation != nil)
  enqueue(3)
  drain()
  precondition(queue.confirmation == nil && replies.count == 2)
  session.links.cancel()
  waitUntil("The third clipboard request did not appear") { queue.confirmation?.messageText == "Clipboard test 3" }
  enqueue(4)
  let closingAlert = queue.confirmation!
  controller.closing = true
  controller.window!.close()
  precondition(view.surface == nil && replies.count == 4)
  precondition(replies[2].0 == 3 && !replies[2].1 && replies[3].0 == 4 && !replies[3].1)
  closingAlert.buttons[0].performClick(nil) // A late UI response cannot complete again.
  queue.cancel()
  waitUntil("The clipboard queue did not empty") { replies.count == 4 && queue.confirmation == nil }
}

// Cancellation before presentation, including the no-request-state write callback.
func checkClipboardCancellation() {
  let (controller, _, view) = openPlainWindow()
  var denied = 0
  view.clipboard.enqueue(title: "Pending", message: "Test") { allow, _ in
    precondition(!allow && view.surface != nil)
    denied += 1
  }
  let board = RuntimeContext.pasteboard(GHOSTTY_CLIPBOARD_SELECTION)
  board.clearContents()
  board.setString("unchanged", forType: .string)
  "text/plain".withCString { mime in
    "replacement".withCString { bytes in
      var item = ghostty_clipboard_content_s(mime: mime, data: bytes, len: 11)
      RuntimeContext.writeClipboard(Unmanaged.passUnretained(view).toOpaque(),
        GHOSTTY_CLIPBOARD_SELECTION, &item, 1, true)
    }
  }
  controller.closing = true
  controller.window!.close()
  precondition(denied == 1)
  waitUntil("The clipboard confirmation did not close with its window") { view.clipboard.confirmation == nil && denied == 1 }
  precondition(board.string(forType: .string) == "unchanged")
}

// A view that was never attached to a window denies requests instead of queueing them.
func checkUnattachedClipboard() throws {
  let runtime = try TerminalRuntime(settings: settings)
  let session = runtime.makeSession()
  let view = session.createView()!
  var denied = 0
  view.clipboard.enqueue(title: "Unattached", message: "Test") { allow, _ in
    precondition(!allow && view.surface != nil)
    denied += 1
  }
  waitUntil("The unattached clipboard request was not denied") { denied == 1 }
  precondition(denied == 1 && view.clipboard.confirmation == nil)
  session.close()
  precondition(denied == 1)
}

// Exercise native request allocation, copied clipboard bytes, completion and denial at a PTY.
func checkClipboardAtPTY() throws {
  try withTemporaryDirectory("velocitty-clipboard") { directory in
    defer { try! delegate.runtime!.updateConfiguration(settings) }
    let recorder = try openRecordingTerminal(in: directory,
      extra: "clipboard_paste_protection = true\nclipboard_paste_bracketed_safe = false")
    let view = recorder.view
    let board = RuntimeContext.pasteboard(GHOSTTY_CLIPBOARD_SELECTION)
    func paste(_ value: String) {
      board.clearContents()
      board.setString(value, forType: .string)
      view.performSurfaceAction("paste_from_selection")
    }
    paste("first\nsecond")
    paste("denied\ntext")
    board.clearContents()
    board.setString("changed after request", forType: .string)
    waitUntil("The first paste did not ask for confirmation") { view.clipboard.confirmation != nil }
    precondition(view.clipboard.confirmation!.informativeText.contains("first\nsecond"))
    view.clipboard.confirmation!.buttons[0].performClick(nil)
    waitUntil("The second paste did not ask for confirmation") {
      view.clipboard.confirmation?.informativeText.contains("denied\ntext") == true
    }
    view.clipboard.confirmation!.buttons[1].performClick(nil)
    let expected = Data("first\rsecond".utf8)
    waitUntil("The allowed paste did not reach the PTY") { recorder.received() == expected }
    drain()
    precondition(recorder.received() == expected)
    paste("pending\none")
    paste("pending\ntwo")
    waitUntil("The pending paste did not ask for confirmation") { view.clipboard.confirmation != nil }
    recorder.controller.closing = true
    recorder.controller.window!.close()
    waitUntil("The pending paste was not cancelled by closing") { view.surface == nil && view.clipboard.confirmation == nil }
    precondition(recorder.received() == expected)
    precondition(delegate.windows.count == 2)
  }
}

// Background titles, menu close, reopening on the same engine, and quit.
func checkCloseAndQuit() {
  // A background terminal's title callback must not change the foreground window.
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_SURFACE
  target.target.surface = first.session!.view!.surface
  var action = ghostty_action_s()
  action.tag = GHOSTTY_ACTION_SET_TITLE
  "Background terminal".withCString {
    action.action.set_title.title = $0
    precondition(first.session!.runtime.context.handleAction(target: target, action: action))
  }
  waitUntil("The background title did not apply") { first.window?.title == "Background terminal" }
  precondition(second.window?.title != "Background terminal")
  second.window?.makeKeyAndOrderFront(nil)
  drain()
  precondition(closeMenuItem.keyEquivalent == "w")
  precondition(app.sendAction(closeMenuItem.action!, to: closeMenuItem.target, from: closeMenuItem))
  waitUntil("The window did not close") { delegate.windows.count == 1 }
  precondition(first.session?.view?.surface != nil)
  precondition(second.session?.view == nil)
  first.window?.performClose(nil)
  waitUntil("The last window did not close") { delegate.windows.isEmpty }
  precondition(terminal.surface == nil && terminal.config == nil)
  precondition(!delegate.validateMenuItem(closeMenuItem))
  precondition(delegate.runtime?.app == originalEngine)
  precondition(app.sendAction(new.action!, to: new.target, from: new))
  precondition(app.sendAction(new.action!, to: new.target, from: new))
  waitUntil("The new windows did not open") { delegate.windows.count == 2 }
  precondition(delegate.windows.allSatisfy { $0.session?.runtime.app == originalEngine })
  let quit = menuItem("Quit Velocitty")
  precondition(quit.keyEquivalent == "q")
  precondition(quit.action == #selector(NSApplication.terminate(_:)))
  for controller in delegate.windows { controller.closing = true; controller.window?.close() }
  precondition(delegate.windows.isEmpty)
}

// MARK: - Standalone checks

// Runs inside an isolated app bundle so AppKit, rather than a hand-made coder,
// saves and restores windows across two processes.
func runRestorationCheck() -> Never {
  let application = NSApplication.shared
  application.setActivationPolicy(.regular)
  let owner = AppDelegate(discoverHerdr: { nil })
  application.delegate = owner
  let saving = ProcessInfo.processInfo.environment["VELOKIT_TEST_RESTORATION"] == "write"
  DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    for controller in owner.windows {
      if let sheet = controller.window?.attachedSheet {
        controller.window?.endSheet(sheet)
        sheet.orderOut(nil)
      }
    }
    if saving {
      owner.newWindow()
      precondition(owner.windows.count == 2)
      for (index, controller) in owner.windows.enumerated() {
        controller.windowTitleOverride = "Restoration \(index)"
        controller.setTitle(controller.terminalTitle)
        controller.window!.setFrame(NSRect(x: 80 + index * 50, y: 100 + index * 40,
          width: 700, height: 450), display: true)
        controller.window!.invalidateRestorableState()
      }
      owner.windows[1].toggleFullscreen(modeOverride: "true")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        print("AppKit restoration state written.")
        application.terminate(nil)
      }
    } else {
      precondition(owner.windows.count == 2, "AppKit did not restore both windows: \(owner.windows.count)")
      for index in 0..<2 {
        let controller = owner.windows.first { $0.windowTitleOverride == "Restoration \(index)" }!
        let expected = NSRect(x: 80 + index * 50, y: 100 + index * 40, width: 700, height: 450)
        if index == 1 {
          precondition(controller.normalFrame == expected && controller.fullscreenMode == "true",
            "Borderless fullscreen did not survive relaunch")
          controller.toggleFullscreen()
        }
        precondition(controller.window!.frame == expected, "Frame did not survive relaunch")
        precondition(controller.session?.surface != nil)
      }
      print("AppKit relaunch restoration passed.")
      application.terminate(nil)
    }
  }
  application.run()
  withExtendedLifetime(owner) {}
  exit(0)
}

// Opt-in integration check: an isolated herdr 0.9 server reached through SSH.
func runRemoteCheck() throws {
  let env = ProcessInfo.processInfo.environment
  guard let executablePath = env["VELO_TEST_HERDR"], let host = env["VELO_TEST_SSH_HOST"], let knownHosts = env["VELO_TEST_KNOWN_HOSTS"] else { fatalError("Remote check requires explicit executable, host, and known-hosts file") }
  let executable = URL(fileURLWithPath: executablePath)
  let root = URL(fileURLWithPath: "/tmp/velo-remote-" + String(UUID().uuidString.prefix(8)))
  try withIsolatedHerdr("vt", sessions: 2, executable: executable, root: root) { root, clients in
    let (server, local) = (clients[0], clients[1])
    let config = root.appendingPathComponent("herdr.toml")
    _ = try server.connect(directory: root)
    let raw = try server.create(workspace: nil, name: "SSH test", directory: root.path, environment: [:])
    let machine = HerdrClient.Machine(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), label: "Laptop test", target: host, session: server.sessionName)
    let remote = HerdrClient(executable: executable, machine: machine,
      sshOptions: ["-o", "UserKnownHostsFile=" + knownHosts, "-o", "StrictHostKeyChecking=yes"], remoteExecutable: executablePath,
      remoteEnvironment: ["HERDR_CONFIG_PATH": config.path])
    defer { remote.disconnectTransport() }
    let scoped = try remote.snapshot()
    precondition(Set(scoped.panes.map(\.terminal_id)) == Set(raw.panes.map { remote.qualify($0.terminal_id.components(separatedBy: "::").last!) }))
    let settings = try AppConfiguration.parse(Data("[terminal]\nconfirm_close_surface=false\nundo_timeout='2s'\ntheme=''\n".utf8))
    let owner = AppDelegate()
    owner.workspaceStateURL = root.appendingPathComponent("workspace.json")
    owner.runtime = try TerminalRuntime(settings: settings)
    owner.herdr = local
    owner.openHerdrWindow(using: local)
    waitForMux(owner, timeout: 15)
    let window = owner.windows[0]
    let localPane = window.session!
    owner.connectEndpoint(remote); waitForMux(owner, timeout: 15)
    let remotePane = window.allPanes.first { $0.herdrTerminal?.client === remote }!
    precondition(window.allPanes.contains { $0 === localPane })
    owner.synchronizeHerdr(try remote.snapshot(), client: remote)
    owner.synchronizeHerdr(try local.snapshot(), client: local)
    precondition(window.allPanes.contains { $0 === localPane } && window.allPanes.contains { $0 === remotePane })
    window.selectTab(localPane)
    window.showAlongside(window.tab(for: remotePane)!)
    window.selectTab(remotePane)
    window.workspaceView.layoutSubtreeIfNeeded()
    precondition(window.presentedTabs.count == 2 && window.visiblePanes.contains { $0 === localPane })
    precondition(!localPane.chrome!.frame.intersects(remotePane.chrome!.frame))
    owner.flushWorkspaceSaveSynchronously()
    let saved = try WorkspaceStateStore(url: owner.workspaceStateURL!).load()
    window.stopAlongside()
    window.restoreWorkspaceState(saved)
    precondition(window.presentedTabs.count == 2 && window.session === remotePane)
    // Kept as a fixed settle: this opt-in check needs an SSH host that is not available to run here, so a
    // prompt-based wait could not be verified. The marker below is waited for with a real timeout.
    pumpEvents(until: Date(timeIntervalSinceNow: 0.5))
    let marker = root.appendingPathComponent("ssh-input")
    enterCommand("printf remote-ok > " + ShellInput.quote(marker.path), in: remotePane)
    if !pollUntil(timeout: 5, { FileManager.default.fileExists(atPath: marker.path) }) {
      var capture = velokit_accessibility_s()
      if velokit_surface_read_accessibility(remotePane.surface!, &capture) {
        if let text = capture.text { FileHandle.standardError.write(Data(String(cString: text).utf8)) }
        velokit_free_accessibility(&capture)
      }
      throw ConfigurationError("SSH attachment did not deliver input. Command: " + remotePane.herdrTerminal!.command)
    }
    remote.disconnectTransport()
    let reconnected = try remote.snapshot()
    owner.synchronizeHerdr(reconnected, client: remote)
    precondition(window.allPanes.contains { $0 === remotePane }, "Reconnect must preserve the terminal view")
    let originalSurface = remotePane.surface
    let remoteID = remotePane.herdrTerminal!.pane.terminal_id
    window.closePane(remotePane, confirm: false)
    precondition(!window.allPanes.contains { $0 === remotePane })
    let pendingState = try WorkspaceStateStore(url: owner.workspaceStateURL!).load()
    precondition(pendingState.pendingTerminalClosures?.contains(remoteID) == true)
    let beforeUndo = try remote.snapshot()
    precondition(beforeUndo.panes.contains { $0.terminal_id == remoteID })
    owner.undoClose()
    waitUntil("Undo must restore the closed pane and its surface") {
      window.allPanes.contains { $0 === remotePane } && remotePane.surface == originalSurface
    }
    precondition(window.native.undoTimeout == 2)
    owner.redoClose()
    precondition(!window.allPanes.contains { $0 === remotePane }, "Redo must hide the restored pane")
    waitUntil("The expired close must destroy the remote terminal", timeout: 7) {
      (try? remote.snapshot())?.panes.contains { $0.terminal_id == remoteID } == false
    }
    let retainedSurface = localPane.surface
    let retainedWindowID = window.workspaceWindowID
    window.window?.performClose(nil)
    precondition(owner.windows.isEmpty && localPane.surface == retainedSurface)
    owner.undoClose()
    waitUntil("Undo must reopen the closed window with its terminal") {
      owner.windows.contains { $0.workspaceWindowID == retainedWindowID && $0.allPanes.contains { $0 === localPane } }
    }
    precondition(localPane.surface == retainedSurface)
    owner.redoClose()
    precondition(owner.windows.isEmpty)
    owner.undoClose()
    waitUntil("A second undo must reopen the window") { !owner.windows.isEmpty }
    precondition(localPane.surface == retainedSurface)
    for controller in Array(owner.windows) { controller.closing = true; controller.window?.close() }
  }
  print("Remote transport, comparison and close undo tests passed.")
}

func runMixedConnectionsCheck() throws {
  try withIsolatedHerdr("vt", sessions: 2) { directory, clients in
    try checkMixedConnections(directory: directory, first: clients[0], second: clients[1])
  }
  print("Mixed connection tests passed.")
}

private func checkMixedConnections(directory: URL, first: HerdrClient, second: HerdrClient) throws {
  var profiles = [first, second].map { HerdrConnection(id: $0.endpointID, label: $0.sessionName, session: $0.sessionName) }
  let file = directory.appendingPathComponent("workspace.json")
  let settings = try AppConfiguration.parse(Data("[terminal]\nconfirm_close_surface=false\nundo_timeout='2s'\ntheme=''\n".utf8))
  func owner() throws -> AppDelegate {
    var configuration = settings; configuration.connections = profiles
    let result = AppDelegate(); result.workspaceStateURL = file; result.runtime = try TerminalRuntime(settings: configuration)
    result.herdr = HerdrClient(executable: first.executable, sessionName: first.sessionName)
    result.loadWorkspaceState(for: result.herdr!)
    result.loadConnections(); return result
  }
  func enable(_ app: AppDelegate, _ id: String, _ enabled: Bool) {
    let index = profiles.firstIndex { $0.id == id }!
    profiles[index].enabled = enabled
    var updated = app.runtime!.settings; updated.connections = profiles
    try! app.runtime!.updateConfiguration(updated)
    app.loadConnections(reload: true)
  }
  func closeWindows(_ app: AppDelegate) {
    for controller in Array(app.windows) { controller.closing = true; controller.window?.close() }
  }
  let app = try owner(); app.startInitialWorkspace(); waitForMux(app, timeout: 15)
  let window = app.windows.first!
  // A fresh second server can be empty, so explicitly create its first tab.
  let client = app.client(for: second.endpointID)!
  window.newTab(using: client); waitForMux(app, window, timeout: 15)
  precondition(window.namespaces.count == 1 && window.tabs.count == 2)
  let remoteTab = window.activeTab, pane = remoteTab.selected
  let terminalID = pane.herdrTerminal!.pane.terminal_id
  let spaceID = window.activeNamespace.id!
  window.activeNamespace.name = "Mixed Project"
  app.scheduleWorkspaceSave(window); app.flushWorkspaceSaveSynchronously()
  app.synchronizeHerdr(try first.snapshot(), client: app.herdr!)
  app.synchronizeHerdr(try client.snapshot(), client: client)
  precondition(window.namespaces.count == 1 && window.tabs.count == 2 && window.activeNamespace.name == "Mixed Project")
  enable(app, client.endpointID, false)
  precondition(pane.surface == nil && pane.connectionSuspended && window.tabs.count == 2)
  let running = try second.snapshot()
  precondition(running.panes.contains { $0.terminal_id == terminalID })
  window.closePane(pane, confirm: false)
  precondition(!window.allPanes.contains { $0 === pane })
  app.undoClose()
  precondition(window.allPanes.contains { $0 === pane } && pane.connectionSuspended, "Undo must restore a disabled terminal without connecting")
  app.scheduleWorkspaceSave(window)
  app.flushWorkspaceSaveSynchronously()
  closeWindows(app)
  let restored = try owner(); restored.startInitialWorkspace(); waitForMux(restored, timeout: 15)
  let restoredWindow = restored.windows.first!
  precondition(restoredWindow.activeNamespace.id == spaceID && restoredWindow.tabs.count == 2)
  precondition(restoredWindow.activeNamespace.name == "Mixed Project")
  let placeholder = restoredWindow.tabs.first { $0.selected.herdrTerminal?.client.endpointID == second.endpointID }!.selected
  precondition(placeholder.connectionSuspended && placeholder.surface == nil)
  precondition(restoredWindow.session === placeholder, "Restore the selected disabled tab")
  enable(restored, second.endpointID, true); waitForMux(restored, timeout: 15)
  waitUntil("Enabling the connection must reconnect the placeholder", timeout: 8) { placeholder.surface != nil }
  precondition(placeholder.herdrTerminal!.pane.terminal_id == terminalID)
  restored.scheduleWorkspaceSave(restoredWindow); restored.flushWorkspaceSaveSynchronously()
  let saved = try WorkspaceStateStore(url: file).load()
  precondition(saved.namespaces[0].tabs.count == 2)
  enable(restored, second.endpointID, false)
  restoredWindow.closePane(placeholder, confirm: false)
  // Wait for the undo period to end, so the close becomes a pending destruction.
  waitUntil("The close did not expire", timeout: 5) { !restored.retainedTerminalIDs.contains(terminalID) }
  restored.connectEndpoint(restored.herdr!); waitForMux(restored, timeout: 15)
  precondition(restoredWindow.tabs.count == 1, "A pending close must not reappear as an offline placeholder")
  enable(restored, first.endpointID, false)
  restored.scheduleWorkspaceSave(restoredWindow); restored.flushWorkspaceSaveSynchronously()
  closeWindows(restored)
  let disabled = try owner(); disabled.startInitialWorkspace(); waitForMux(disabled, timeout: 15)
  precondition(disabled.windows.count == 1 && disabled.windows[0].tabs.count == 1, "All-disabled startup retains the saved workspace")
  precondition(disabled.windows[0].session!.connectionSuspended)
  closeWindows(disabled)
  profiles = profiles.map { var profile = $0; profile.enabled = true; return profile }
  let mixed = try owner(); mixed.startInitialWorkspace(); waitForMux(mixed, timeout: 15)
  let mixedWindow = mixed.windows[0]
  let originalID = mixedWindow.session!.herdrTerminal!.pane.terminal_id
  mixedWindow.splitPane("right", using: mixed.client(for: second.endpointID)!); waitForMux(mixed, mixedWindow, timeout: 15)
  let splitID = mixedWindow.session!.herdrTerminal!.pane.terminal_id
  precondition(mixedWindow.activeTab.panes.count == 2)
  precondition(Set(mixedWindow.activeTab.panes.compactMap { $0.herdrTerminal?.client.endpointID }).count == 2)
  let mixedTabID = mixedWindow.activeTab.herdrID!
  mixed.scheduleWorkspaceSave(mixedWindow); mixed.flushWorkspaceSaveSynchronously()
  closeWindows(mixed)
  let reopened = try owner(); reopened.startInitialWorkspace(); waitForMux(reopened, timeout: 15)
  let restoredMixed = reopened.windows.flatMap(\.namespaces).flatMap(\.tabs).first { $0.herdrID == mixedTabID }!
  precondition(Set(restoredMixed.panes.compactMap { $0.herdrTerminal?.pane.terminal_id }) == Set([originalID, splitID]), "Mixed panes must remain in one tab after relaunch")
  precondition(Set(restoredMixed.localLayout!.terminals) == Set([originalID, splitID]))
  let ownerWindow = restoredMixed.selected.windowController!
  enable(reopened, second.endpointID, false)
  precondition(restoredMixed.panes.count == 2 && restoredMixed.panes.contains { $0.connectionSuspended })
  reopened.scheduleWorkspaceSave(ownerWindow); reopened.flushWorkspaceSaveSynchronously()
  closeWindows(reopened)
  let offline = try owner(); offline.startInitialWorkspace(); waitForMux(offline, timeout: 15)
  let offlineTab = offline.windows.flatMap(\.namespaces).flatMap(\.tabs).first { $0.herdrID == mixedTabID }!
  precondition(offlineTab.panes.count == 2 && offlineTab.panes.contains { $0.connectionSuspended }, "Unavailable pane must retain its position in a mixed tab")
  closeWindows(offline)
  let removedProfile = profiles.removeLast()
  let missing = try owner(); missing.startInitialWorkspace(); waitForMux(missing, timeout: 15)
  let missingTab = missing.windows.flatMap(\.namespaces).flatMap(\.tabs).first { $0.herdrID == mixedTabID }!
  precondition(missingTab.panes.count == 2, "Removing a definition must preserve its saved pane")
  let missingPane = missingTab.panes.first { $0.herdrTerminal?.pane.terminal_id == splitID }!
  precondition(missingPane.connectionSuspended)
  var returned = removedProfile; returned.enabled = true; profiles.append(returned)
  var updated = missing.runtime!.settings; updated.connections = profiles
  try missing.runtime!.updateConfiguration(updated); missing.loadConnections(reload: true); waitForMux(missing, timeout: 15)
  waitUntil("Restoring the same definition must reconnect the existing pane", timeout: 8) { missingPane.surface != nil }
  precondition(missingPane.herdrTerminal?.pane.terminal_id == splitID)
  closeWindows(missing)
  for client in [first, second] { _ = try client.run(["server", "stop"]) }
  let restarted = try owner()
  precondition(!restarted.windows.isEmpty, "Saved tabs must be restored before connecting")
  restarted.startInitialWorkspace(); waitForMux(restarted, timeout: 15)
  for client in [first, second] { _ = try client.snapshot() }
  closeWindows(restarted)
}

func runScaleCheck() throws {
  try withIsolatedHerdr("velo-scale", sessions: 3) { directory, clients in
    let started = ProcessInfo.processInfo.systemUptime
    for (index, client) in clients.enumerated() {
      _ = try client.connect(directory: directory)
      let existing = try client.snapshot()
      let count = index == 2 ? 16 : 17
      for number in existing.panes.count..<count {
        _ = try client.createPane(workspace: existing.workspaces.first?.workspace_id, name: "Scale \(number)", directory: directory.path)
      }
    }
    let created = ProcessInfo.processInfo.systemUptime
    var settings = try AppConfiguration.parse(Data("[terminal]\ntheme=''\nconfirm_close_surface=false\n".utf8))
    settings.connections = clients.map { .init(id: $0.endpointID, label: $0.sessionName, session: $0.sessionName) }
    let owner = AppDelegate(); owner.workspaceStateURL = directory.appendingPathComponent("workspace.json")
    owner.runtime = try TerminalRuntime(settings: settings); owner.herdr = clients[0]; owner.loadConnections()
    owner.newWindow()
    waitUntil("All terminals must attach", timeout: 60) { !owner.muxOpening && owner.windows.flatMap(\.allPanes).count >= 50 }
    precondition(owner.windows.flatMap(\.allPanes).count == 50)
    let attached = ProcessInfo.processInfo.systemUptime
    let controller = owner.windows[0]
    for pane in controller.allPanes { controller.selectTab(pane) }
    let selected = ProcessInfo.processInfo.systemUptime
    for client in clients {
      let endpoint = owner.client(for: client.endpointID)!
      owner.synchronizeHerdr(try endpoint.snapshot(), client: endpoint)
    }
    let reconciled = ProcessInfo.processInfo.systemUptime
    owner.windows.forEach { owner.scheduleWorkspaceSave($0) }; owner.flushWorkspaceSaveSynchronously()
    let saved = try WorkspaceStateStore(url: owner.workspaceStateURL!).load()
    precondition(saved.namespaces.flatMap(\.tabs).flatMap { $0.panes ?? [] }.count == 50)
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    print(String(format: "Scale: 50 terminals / 3 local connections; create %.2fs, attach %.2fs, select 50 %.3fs, reconcile 3 %.3fs, peak RSS %.1f MiB", created-started, attached-created, selected-attached, reconciled-selected, Double(usage.ru_maxrss) / 1_048_576))
    for window in Array(owner.windows) { window.closing = true; window.window?.close() }
  }
  print("Scale check passed.")
}

func runManagementUICheck() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("velo-management-" + UUID().uuidString)
  let file = root.appendingPathComponent("velocitty/config.toml")
  try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
  defer {
    if let previous { setenv("XDG_CONFIG_HOME", previous, 1) } else { unsetenv("XDG_CONFIG_HOME") }
    try? FileManager.default.removeItem(at: root)
  }
  setenv("XDG_CONFIG_HOME", root.path, 1)
  try """
    [[connections]]
    id = 'local'
    name = 'Laptop'
    session = 'velocitty'
    enabled = false
    [[connections]]
    id = 'gpu'
    name = 'GPU Cluster'
    session = 'work'
    host = 'user@example.invalid'
    [terminal]
    theme = 'light:Rose Pine Dawn,dark:Rose Pine'
    initial_window = false
    """.write(to: file, atomically: true, encoding: .utf8)
  let owner = AppDelegate(); owner.runtime = try TerminalRuntime(settings: AppConfiguration.load())
  owner.herdr = HerdrClient.discover().map { HerdrClient(executable: $0) }; owner.loadConnections()
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  func show(_ controller: NSWindowController, snapshot: String) {
    controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    waitUntil("The window did not appear") { controller.window?.isVisible == true }
    let view = controller.window!.contentView!; view.layoutSubtreeIfNeeded()
    precondition(!view.hasAmbiguousLayout)
    if let path = ProcessInfo.processInfo.environment["VELO_TEST_UI_SNAPSHOTS"],
      let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: image)
      try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent(snapshot + ".png"))
    }
  }
  let connections = ConnectionsWindow(owner: owner); show(connections, snapshot: "connections")
  let connectionTable = descendants(connections.window!.contentView!).compactMap { $0 as? NSTableView }.first!
  precondition(connectionTable.numberOfRows == 2)
  let toggle = connectionTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as! NSButton
  toggle.performClick(nil)
  precondition(AppConfiguration.load().connections?.last?.enabled == false)
  connections.close()
  // A filter that leaves a different setting on the same selected row must refresh the detail pane.
  let settingsUI = try SettingsWindow(appOwner: owner); show(settingsUI, snapshot: "settings")
  let settingsControls = descendants(settingsUI.window!.contentView!)
  let settingsTable = settingsControls.compactMap { $0 as? NSTableView }.first!
  let settingsSearch = settingsControls.compactMap { $0 as? NSSearchField }.first!
  func settingsDetail() -> String { settingsControls.compactMap { ($0 as? NSTextField)?.stringValue }.first { $0.contains("\nEffective:") } ?? "" }
  func rowName(_ row: Int) -> String { (settingsTable.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTextField).stringValue }
  precondition(settingsTable.selectedRow == 0 && settingsTable.numberOfRows > 1)
  let initialName = rowName(0), nextName = rowName(1)
  precondition(settingsDetail().components(separatedBy: "\n")[0].hasSuffix("." + initialName.replacingOccurrences(of: " ", with: "_")))
  settingsSearch.stringValue = nextName.replacingOccurrences(of: " ", with: "_")
  NSApp.sendAction(settingsSearch.action!, to: settingsSearch.target, from: settingsSearch)
  precondition(settingsTable.selectedRow == 0 && rowName(0) != initialName)
  precondition(settingsDetail().components(separatedBy: "\n")[0].hasSuffix("." + rowName(0).replacingOccurrences(of: " ", with: "_")), "The detail pane must follow the highlighted setting after filtering")
  settingsUI.close()
  let picker = try ThemePickerWindow(owner: owner); show(picker, snapshot: "themes")
  let controls = descendants(picker.window!.contentView!)
  let mode = controls.compactMap { $0 as? NSPopUpButton }.first!
  mode.selectItem(at: 0); NSApp.sendAction(mode.action!, to: mode.target, from: mode)
  let themes = controls.compactMap { $0 as? NSTableView }.first!
  let row = (0..<themes.numberOfRows).first { (themes.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTextField)?.stringValue == "Catppuccin Mocha" }!
  themes.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  precondition(AppConfiguration.load().options.last { $0.key == "theme" }?.value == TerminalTheme.defaultSelection)
  controls.compactMap { $0 as? NSButton }.first { $0.title == "Apply Theme" }!.performClick(nil)
  precondition(AppConfiguration.load().options.last { $0.key == "theme" }?.value == "Catppuccin Mocha")
  precondition(AppConfiguration.load().connections?.count == 2)
  print("Management UI tests passed.")
}

// MARK: - Headless checks (--headless)

func runHerdrControlCheck() throws {
  try withTemporaryDirectory("velocitty-control") { root in
    let executable = root.appendingPathComponent("herdr")
    func script(_ body: String) throws {
      try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let client = HerdrClient(executable: executable, sessionName: "isolated-test")
    try script("echo 'diagnostic on stderr' >&2\nprintf '%s' '{\"result\":{\"value\":42}}'")
    let response = try client.request(["read"])
    precondition(response["value"] as? Int == 42)
    try script("printf '%s' '{\"error\":{\"code\":\"server_not_running\",\"message\":\"absent\"}}'\nexit 1")
    do { _ = try client.run(["read"]); preconditionFailure("Expected structured error") }
    catch let error as HerdrClient.RequestError { precondition(error.code == "server_not_running") }
    let descendant = root.appendingPathComponent("descendant")
    // The descendant would touch the file after a second; it records its pid so the check can wait for it to be gone.
    let descendantPID = root.appendingPathComponent("descendant.pid")
    try script("(sleep 1; touch " + ShellInput.quote(descendant.path) + ") &\necho $! > " + ShellInput.quote(descendantPID.path) + "\nwait")
    let started = ProcessInfo.processInfo.systemUptime
    do { _ = try client.run(["read"], timeout: 0.3); preconditionFailure("Expected timeout") }
    catch let error as HerdrClient.RequestError { precondition(error.code == "timeout") }
    precondition(ProcessInfo.processInfo.systemUptime - started < 1)
    // A malformed response must not start a server or be treated as an empty workspace.
    try script("if [ \"$3\" = '--version' ]; then echo 'herdr 0.8.2'; else echo invalid; fi")
    do { _ = try client.connect(directory: root); preconditionFailure("Expected invalid snapshot") }
    catch { precondition(!(error is HerdrClient.RequestError)) }
    try script("printf '%s' '{\"result\":{\"snapshot\":{\"workspaces\":[],\"tabs\":[],\"panes\":[]}}}'")
    let empty = try client.snapshot()
    precondition(empty.panes.isEmpty)
    // A snapshot requested before a mutation finished may lack it; one requested after may not.
    precondition(client.isCurrent(empty))
    _ = try? client.request(["tab", "create"])
    precondition(!client.isCurrent(empty), "A snapshot older than a mutation must be stale")
    let fresh = try client.snapshot()
    precondition(client.isCurrent(fresh))
    let pid = (try? String(contentsOf: descendantPID, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    precondition(pid != nil, "The descendant must have started before the timeout")
    waitUntil("The descendant is still running", timeout: 5) { kill(pid!, 0) != 0 }
    precondition(!FileManager.default.fileExists(atPath: descendant.path), "Timeout must also terminate request descendants")
  }
}

// Pure logic that needs neither windows nor a running application.
func runLogicChecks() throws {
  // URL classification must not rely on Foundation repairing malformed input.
  for kind in [GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN] {
    for value in ["https://example.com/a?x=1", "HTTP://example.com", "mailto:hello@example.com"] {
      guard case .direct = TerminalLinks.destination(value, kind: kind) else {
        fatalError("Expected a direct link: \(value)")
      }
    }
    for value in ["file:///tmp/a%20b", "vscode://file/tmp/test", "ssh://user@example.com", "custom:payload"] {
      guard case .confirm = TerminalLinks.destination(value, kind: kind) else {
        fatalError("Expected confirmation: \(value)")
      }
    }
    for value in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "DATA:text/html,test", "",
      "relative/path", "//example.com", "https://", "https:example.com", "https://example.com:99999", "https://a/%GG",
      "https://a/%", "https://a/%0", " https://example.com", "https://example.com/a b",
      "https://example.com/\n", "https://example.com/\0", "https:\\example.com"] {
      precondition(TerminalLinks.destination(value, kind: kind) == .reject, value)
    }
  }
  for kind in [GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, GHOSTTY_ACTION_OPEN_URL_KIND_HTML] {
    let path = "/tmp/terminal export.html"
    precondition(TerminalLinks.destination(path, kind: kind) == .direct(URL(fileURLWithPath: path)))
  }

  try withTemporaryDirectory("velocitty-logic") { directory in
    // Editor selection respects file associations, then the system text editor.
    let file = directory.appendingPathComponent("editor/config.toml")
    let associated = URL(fileURLWithPath: "/Applications/Associated.app")
    let fallback = URL(fileURLWithPath: "/Applications/TextEditor.app")
    var opened: [URL?] = []
    var editor = ConfigurationEditor()
    editor.applicationForType = { _ in associated }
    editor.openFile = { url, app, completion in
      precondition(url == file)
      opened.append(app)
      completion(nil)
    }
    editor.open(file) { precondition($0 == nil) }
    let original = try Data(contentsOf: file)
    precondition(AppConfiguration.load(from: file).diagnostics.isEmpty)
    editor.applicationForType = { $0 == "public.plain-text" ? fallback : nil }
    editor.open(file) { precondition($0 == nil) }
    editor.applicationForType = { _ in nil }
    editor.open(file) { precondition($0 == nil) }
    precondition(opened == [associated, fallback, nil])
    let unchanged = try Data(contentsOf: file)
    precondition(unchanged == original)
    editor.openFile = { _, _, completion in completion(ConfigurationError("Open failed")) }
    editor.open(file) { precondition($0?.localizedDescription == "Open failed") }
  }

  // Secure Input balances only successful calls, including failed release retries.
  let input = SecureInputOwner()
  var acquisitions = 0
  var releases = 0
  var failAcquire = true
  var failRelease = true
  input.acquire = { acquisitions += 1; return failAcquire ? -1 : 0 }
  input.release = { releases += 1; return failRelease ? -1 : 0 }
  input.update(wanted: true)
  precondition(!input.enabled)
  input.update(wanted: false)
  precondition(releases == 0)
  failAcquire = false
  input.update(wanted: true)
  input.update(wanted: true)
  precondition(input.enabled && acquisitions == 2)
  input.update(wanted: false)
  precondition(input.enabled)
  failRelease = false
  input.update(wanted: false)
  precondition(!input.enabled && releases == 2)

  // Progress reports belong to their own terminal.
  let firstProgress = TerminalProgress()
  let secondProgress = TerminalProgress()
  var report = ghostty_action_progress_report_s()
  report.state = GHOSTTY_PROGRESS_STATE_SET
  report.progress = 42
  firstProgress.update(report)
  report.state = GHOSTTY_PROGRESS_STATE_PAUSE
  report.progress = -1
  secondProgress.update(report)
  firstProgress.clear()
  precondition(firstProgress.isHidden && !secondProgress.isHidden)
  precondition(secondProgress.report?.state == GHOSTTY_PROGRESS_STATE_PAUSE)
  secondProgress.clear()

  // Dropped files become quoted shell arguments, followed by dropped text.
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  let droppedFile = NSPasteboardItem()
  droppedFile.setString(URL(fileURLWithPath: "/tmp/a'b $(echo x).txt").absoluteString, forType: .fileURL)
  droppedFile.setString("ignored file label", forType: .string)
  let text = NSPasteboardItem()
  text.setString("plain text", forType: .string)
  pasteboard.writeObjects([droppedFile, text])
  precondition(TerminalView.droppedText(from: pasteboard)
    == String(ShellInput.paths(["/tmp/a'b $(echo x).txt"]).dropLast()) + " plain text")
  pasteboard.clearContents()
  precondition(TerminalView.droppedText(from: pasteboard) == nil)
}

// The async flush path, its failure reporting and its interaction with synchronous flushes.
func runPersistenceCoordinationCheck() throws {
  try withTemporaryDirectory("velo-persistence") { directory in
    let file = directory.appendingPathComponent("workspace.json")
    let store = WorkspaceStateStore(url: file)
    let persistence = WorkspacePersistence()
    persistence.store = store
    persistence.state = WorkspaceState()
    persistence.revision = nil
    func mutate(_ name: String) {
      var state = persistence.state!
      state.selectedNamespaceID = name
      persistence.state = state
      persistence.dirty = true
    }
    // An asynchronous save completes, adopts the new revision and reports success once.
    var results: [Result<Void, Error>] = []
    mutate("a")
    persistence.flush { results.append($0) }
    waitUntil("The asynchronous save never completed", timeout: 5) { !results.isEmpty }
    precondition((try? results[0].get()) != nil && !persistence.dirty)
    precondition(persistence.revision == (try? Data(contentsOf: file)), "The revision must match the saved bytes")
    let firstSaved = try store.load().selectedNamespaceID
    precondition(firstSaved == "a")
    // Changes made while a write is in flight are written by the follow-up flush.
    results = []
    mutate("b")
    persistence.flush { results.append($0) }
    mutate("c")
    persistence.flush { results.append($0) }
    waitUntil("The follow-up save never completed", timeout: 5) { results.count >= 2 && !persistence.dirty }
    let secondSaved = try store.load().selectedNamespaceID
    precondition(secondSaved == "c" && persistence.revision == (try? Data(contentsOf: file)))
    // A synchronous flush right after an asynchronous one must not be overwritten by a stale revision.
    results = []
    mutate("d")
    persistence.flush { results.append($0) }
    mutate("e")
    try persistence.flushSynchronously()
    // The completion runs after the write finished, so nothing late remains once it has been reported.
    waitUntil("The asynchronous save never completed", timeout: 5) { !results.isEmpty }
    let thirdSaved = try store.load().selectedNamespaceID
    precondition(thirdSaved == "e")
    precondition(persistence.revision == (try? Data(contentsOf: file)), "A late completion must not restore an older revision")
    // An external change is a conflict and is reported exactly once.
    try Data("{\"version\":4,\"namespaces\":[]}".utf8).write(to: file)
    results = []
    mutate("f")
    persistence.flush { results.append($0) }
    waitUntil("The conflicting save never completed", timeout: 5) { !results.isEmpty }
    // Nothing is observable once the failure is reported (the write flag is private), so this brief pump only
    // gives a second, duplicate report a chance to arrive before asserting there is exactly one.
    pumpEvents(until: Date(timeIntervalSinceNow: 0.1))
    precondition(results.count == 1, "A failed save must be reported once")
    guard case .failure(let error) = results[0], error as? WorkspaceStateError == .conflictingUpdate else {
      fatalError("Expected a conflicting update")
    }
    precondition(persistence.dirty, "A failed save must stay dirty")
  }
}
