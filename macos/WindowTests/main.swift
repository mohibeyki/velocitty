// SPDX-License-Identifier: GPL-3.0
// AppKit regression executable, built by WindowChecks and launched by the GUI test plan.
import AppKit
import VeloKit
import VelocittyConfiguration

precondition(velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
if ProcessInfo.processInfo.environment["VELOKIT_TEST_RESTORATION"] != nil {
  runRestorationCheck()
}
if CommandLine.arguments.contains("--herdr-control-only") {
  try runHerdrControlCheck()
  exit(0)
}
let previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
pumpEvents(until: Date(timeIntervalSinceNow: 0.2))
if CommandLine.arguments.contains("--workspace-persistence") {
  try runWorkspacePersistenceCheck()
  exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
let testAutomaticQuit = CommandLine.arguments.contains("--quit-on-close")
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

// Verify the Swift accessors against finalized native values, including C conversions.
do {
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
  precondition(native.bellFeatures == 14) // audio plus default attention/title
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
}

// Editor selection respects file associations, then the system text editor.
do {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("config.toml")
  defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
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

let settings = try AppConfiguration.parse(Data(("""
[terminal]
command = "/bin/sh"
shell_integration = "none"
theme = ""
confirm_close_surface = false
window_save_state = "never"
""" + (testAutomaticQuit ? "\nquit_after_last_window_closed = true" : "")).utf8))
delegate.runtime = try TerminalRuntime(settings: settings)
delegate.installMainMenu()
delegate.updateMenuShortcuts()

do {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("velocitty-review-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let root = directory.appendingPathComponent("config.toml")
  let included = directory.appendingPathComponent("included.toml")
  try Data("[terminal]\nconfig_file = [\"included.toml\"]\ntheme = \"\"".utf8).write(to: root)
  try Data("[terminal]\nfont_size = \"not-a-number\"".utf8).write(to: included)
  let invalid = AppConfiguration.load(from: root)
  var diagnostics: [String] = []
  let config = try TerminalRuntime.makeConfig(invalid) { diagnostics.append($0) }
  velokit_config_free(config)
  precondition(diagnostics.count == 1 && diagnostics[0].hasPrefix(included.path + ":"))
}

// A queued wakeup can outlive its runtime, but must not retain a native handle.
do {
  var runtime: TerminalRuntime? = try TerminalRuntime(settings: settings)
  let context = runtime!.context
  RuntimeContext.wakeup(Unmanaged.passUnretained(context).toOpaque())
  runtime = nil
  precondition(context.app == nil)
  context.tick()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
}

func menuItem(_ title: String, in menu: NSMenu = NSApp.mainMenu!) -> NSMenuItem {
  for item in menu.items {
    if item.title == title { return item }
    if let submenu = item.submenu,
      let found = submenu.items.first(where: { $0.title == title }) { return found }
  }
  fatalError("Missing menu: \(title)")
}
func pumpEvents(until deadline: Date) {
  repeat {
    if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
      inMode: .default, dequeue: true) {
      app.sendEvent(event)
    }
    app.updateWindows()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
  } while Date() < deadline
}
func drain() { pumpEvents(until: Date(timeIntervalSinceNow: 0.15)) }
let new = menuItem("New Window")
precondition(new.keyEquivalent == "n")
let closeMenuItem = menuItem("Close Window")
precondition(closeMenuItem.menu === new.menu)
precondition(!delegate.validateMenuItem(closeMenuItem))
for title in ["Find…", "Command Palette…"] {
  precondition(!delegate.validateMenuItem(menuItem(title)))
}
precondition(app.sendAction(new.action!, to: new.target, from: new))
drain()
let first = delegate.windows[0]

// Exercise the keyboard-event/committed-text bridge, not the paste path.
let terminal = first.session!.view!
let originalEngine = delegate.runtime!.app
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

// AppKit may already have removed our tracked accessory during a style change.
let unrelatedAccessory = NSTitlebarAccessoryViewController()
unrelatedAccessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
first.window!.addTitlebarAccessoryViewController(unrelatedAccessory)
first.titleAccessory = NSTitlebarAccessoryViewController()
first.applyWindowSettings()
precondition(first.window!.titlebarAccessoryViewControllers.contains(unrelatedAccessory))
first.window!.removeTitlebarAccessoryViewController(at: 0)
for (index, style) in ["hidden", "native", "transparent", "hidden", "native"].enumerated() {
  let scrollbar = index.isMultiple(of: 2) ? "never" : "system"
  let updated = try AppConfiguration.parse(Data(("""
  [terminal]
  command = "/bin/sh"
  shell_integration = "none"
  theme = ""
  confirm_close_surface = false
  window_save_state = "never"
  window_title_font_family = "Menlo"
  macos_titlebar_style = "\(style)"
  scrollbar = "\(scrollbar)"
  """).utf8))
  try first.session!.runtime.updateConfiguration(updated)
  first.chrome!.scrollState = ghostty_action_scrollbar_s(total: 100, offset: 0, len: 10)
  first.applyWindowSettings()
  precondition(first.chrome!.showScroll == (scrollbar == "system"))
  precondition((first.titleAccessory == nil) == (style == "hidden"))
}
try first.session!.runtime.updateConfiguration(settings)
first.applyWindowSettings()

precondition(app.sendAction(new.action!, to: new.target, from: new))
drain()
precondition(delegate.windows.count == 2)
precondition(delegate.validateMenuItem(closeMenuItem))
let second = delegate.windows[1]
precondition(first.session?.view?.surface != second.session?.view?.surface)
precondition(first.session?.windowController === first)
precondition(second.session?.windowController === second)
precondition(second.window!.frame.minX > first.window!.frame.minX)
precondition(second.window!.frame.maxY < first.window!.frame.maxY)

// One engine serves every session, including native all/global surface actions.
do {
  let runtime = delegate.runtime!
  precondition(first.session!.runtime === runtime && second.session!.runtime === runtime)
  precondition(runtime.context.owner === delegate)
  let firstSurface = first.session!.surface!
  let secondSurface = second.session!.surface!
  let originalCell = velokit_surface_size(firstSurface).cell_height_px
  func configured(_ opacity: Double) throws -> AppConfiguration {
    try AppConfiguration.parse(Data("""
    [terminal]
    command = "/bin/sh"
    shell_integration = "none"
    theme = ""
    confirm_close_surface = false
    window_save_state = "never"
    font_size = 24
    background_opacity = \(opacity)
    keybind = ["all:ctrl+shift+a=set_surface_title:Broadcast", "global:ctrl+shift+b=set_surface_title:Global"]
    """.utf8))
  }
  try runtime.updateConfiguration(configured(0.4))
  drain()
  precondition(velokit_surface_size(firstSurface).cell_height_px > originalCell)
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
  drain()
  precondition(velokit_surface_size(firstSurface).cell_height_px > velokit_surface_size(secondSurface).cell_height_px,
    "A surface-only update must leave sibling terminals unchanged")
  try runtime.updateConfiguration(configured(0.4))
  drain()
  first.session!.view!.performSurfaceAction("toggle_background_opacity")
  drain()
  precondition(first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.4)
  precondition(delegate.native.backgroundOpacity == 0.4)
  delegate.newWindow()
  drain()
  let third = delegate.windows.last!
  precondition(third.session!.runtime === runtime && third.native.backgroundOpacity == 0.4)
  third.closing = true
  third.window!.close()
  drain()
  precondition(delegate.runtime === runtime && first.session!.surface == firstSurface)
  try runtime.updateConfiguration(configured(0.6))
  drain()
  precondition(first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.6)
  first.session!.view!.performSurfaceAction("toggle_background_opacity")
  drain()
  precondition(first.native.backgroundOpacity == 0.6 && second.native.backgroundOpacity == 0.6)
  let broadcast = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.window!.windowNumber,
    context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
  first.session!.view!.sendKey(broadcast, action: GHOSTTY_ACTION_PRESS)
  drain()
  precondition(first.window!.title == "Broadcast" && second.window!.title == "Broadcast")
  var global = ghostty_input_key_s()
  global.action = GHOSTTY_ACTION_PRESS
  global.keycode = 11 // physical B
  global.mods = ghostty_input_mods_e(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
  global.unshifted_codepoint = 98
  precondition(velokit_app_key(runtime.app!, global))
  drain()
  precondition(first.window!.title == "Global" && second.window!.title == "Global")
  precondition(first.session!.surface == firstSurface && second.session!.surface == secondSurface)
  try runtime.updateConfiguration(settings)
  drain()
}

// Reload bad values alongside valid settings without replacing terminals or losing overrides.
do {
  let runtime = delegate.runtime!
  let firstSurface = first.session!.surface!
  let secondSurface = second.session!.surface!
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
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
  drain()
  precondition(runtime.diagnostics.count == 8, runtime.diagnostics.joined(separator: "\n"))
  precondition(first.session!.surface == firstSurface && second.session!.surface == secondSurface)
  precondition(first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 0.45)
  precondition(second.window!.backgroundColor == .windowBackgroundColor,
    "Native window chrome stays independent of terminal opacity")
  precondition(first.window!.title == "Reloaded" && second.window!.title == "Reloaded")
  precondition(first.titleAccessory == nil && second.titleAccessory == nil,
    "Rejected titlebar colors must not enable custom titlebars")
  precondition(!menuItem("Find…").isEnabled || menuItem("Find…").keyEquivalent.isEmpty)
  let defaults = try TerminalRuntime.makeConfig(.defaults())
  defer { velokit_config_free(defaults) }
  let defaultFontSize = String(cString: velokit_config_format(defaults, "font-size")!)
  precondition(String(cString: velokit_config_format(runtime.config!, "font-size")!) == defaultFontSize)
  let palette = String(cString: velokit_config_format(runtime.config!, "palette")!)
  precondition(palette.contains("0=#112233") && palette.contains("1=#445566"), palette)
  precondition(runtime.settings.workingDirectory == AppConfiguration.defaults().workingDirectory)

  delegate.showConfigurationDiagnostics()
  drain()
  let diagnosticWindow = delegate.activeWindow!.window!
  precondition(diagnosticWindow.attachedSheet != nil, "Reload diagnostics must be visible")
  diagnosticWindow.endSheet(diagnosticWindow.attachedSheet!)
  drain()

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

  // A subsequent clean reload clears diagnostics and the opacity toggle still works.
  try runtime.updateConfiguration(settings)
  try first.session!.toggleOpacity()
  drain()
  precondition(runtime.diagnostics.isEmpty)
  precondition(first.native.backgroundOpacity == 1 && second.native.backgroundOpacity == 1)
}

// Native visual policies retain their distinct meanings.
do {
  let runtime = delegate.runtime!
  for blur in ["12", "macos-glass-regular", "macos-glass-clear", "false"] {
    let config = try AppConfiguration.parse(Data(("""
    [terminal]
    command = "/bin/sh"
    shell_integration = "none"
    theme = ""
    confirm_close_surface = false
    window_save_state = "never"
    background_opacity = 0.5
    bell_features = "no-attention,no-title,border"
    background_blur = "\(blur)"
    """).utf8))
    try runtime.updateConfiguration(config)
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
  drain()
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
  drain()
  let scale = first.window!.backingScaleFactor
  precondition(first.window!.contentMaxSize.width == 1600 / scale)
  precondition(first.window!.contentMinSize.height == 100 / scale)
  action.action.size_limit.max_width = 0
  action.action.size_limit.max_height = 0
  precondition(runtime.context.handleAction(target: target, action: action))
  drain()
  precondition(first.window!.contentMaxSize.width > 100_000)
  try runtime.updateConfiguration(settings)
  drain()
}

// Secure Input balances only successful calls, including failed release retries.
do {
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
}

do {
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  let file = NSPasteboardItem()
  file.setString(URL(fileURLWithPath: "/tmp/a'b $(echo x).txt").absoluteString, forType: .fileURL)
  file.setString("ignored file label", forType: .string)
  let text = NSPasteboardItem()
  text.setString("plain text", forType: .string)
  pasteboard.writeObjects([file, text])
  precondition(TerminalView.droppedText(from: pasteboard)
    == String(ShellInput.paths(["/tmp/a'b $(echo x).txt"]).dropLast()) + " plain text")
  pasteboard.clearContents()
  precondition(TerminalView.droppedText(from: pasteboard) == nil)
}

// AppKit restores each window's own metadata; ordinary new windows still cascade.
do {
  let runtime = delegate.runtime!
  let positioned = try AppConfiguration.parse(Data("""
  [terminal]
  theme = ""
  command = "/bin/sh"
  shell_integration = "none"
  confirm_close_surface = false
  window_save_state = "always"
  window_position_x = 80
  window_position_y = 70
  """.utf8))
  try runtime.updateConfiguration(positioned)
  delegate.newWindow()
  let placed = delegate.windows.last!
  drain()
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
do {
  let runtime = delegate.runtime!
  let textSettings = try AppConfiguration.parse(Data(#"""
  [terminal]
  command = "/bin/sh -c 'printf \"AX 😀 café\\nsecond line\\n\"; exec cat'"
  shell_integration = "none"
  theme = ""
  confirm_close_surface = false
  window_save_state = "never"
  """#.utf8))
  try runtime.updateConfiguration(textSettings)
  delegate.newWindow()
  let controller = delegate.windows.last!
  let view = controller.session!.view!
  let deadline = Date(timeIntervalSinceNow: 5)
  var snapshot = TerminalTextSnapshot()
  repeat {
    drain()
    snapshot = TerminalTextSnapshot.read(view.surface!)
  } while !snapshot.text.contains("AX 😀 café") && Date() < deadline
  precondition(snapshot.text.contains("AX 😀 café"))
  var accessibilityNotifications: [NSAccessibility.Notification] = []
  view.postAccessibility = { _, notification in accessibilityNotifications.append(notification) }
  _ = view.accessibilityValue() // Start observing only after an AX client asks for text.
  view.performSurfaceAction("select_all")
  pumpEvents(until: Date(timeIntervalSinceNow: 0.3))
  precondition(accessibilityNotifications.contains(.selectedTextChanged))
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
  let notificationDeadline = Date(timeIntervalSinceNow: 3)
  while !accessibilityNotifications.contains(.valueChanged) && Date() < notificationDeadline { drain() }
  precondition(accessibilityNotifications.contains(.valueChanged))
  let dropped = NSPasteboard.withUniqueName()
  defer { dropped.releaseGlobally() }
  let droppedFile = URL(fileURLWithPath: "/tmp/AX-drop-'quoted'.txt")
  dropped.writeObjects([droppedFile as NSURL])
  controller.readonly = true
  precondition(!view.insertDrop(from: dropped))
  controller.readonly = false
  precondition(view.insertDrop(from: dropped))
  let dropDeadline = Date(timeIntervalSinceNow: 3)
  while !TerminalTextSnapshot.read(view.surface!).text.contains("AX-drop-") && Date() < dropDeadline { drain() }
  precondition(TerminalTextSnapshot.read(view.surface!).text.contains("AX-drop-"))
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
do {
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
do {
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

// A real isolated server verifies streaming, namespace ownership, and detach/reattach.
if let executable = HerdrClient.discover() {
  let client = HerdrClient(executable: executable, sessionName: "velocitty-test-" + UUID().uuidString.lowercased())
  defer {
    _ = try? client.run(["server", "stop"])
    _ = try? client.run(["session", "delete", client.sessionName])
    delegate.herdr = nil
  }
  let muxSettings = try AppConfiguration.parse(Data("""
  [terminal]
  confirm_close_surface = false
  theme = ""
  """.utf8))
  try delegate.runtime!.updateConfiguration(muxSettings)
  defer { try? delegate.runtime?.updateConfiguration(settings) }
  delegate.herdr = client
  func waitMux(_ controller: TerminalWindowController? = nil) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while (delegate.muxOpening || (controller?.muxBusy == true || controller?.hasPendingMuxActions == true)) && Date() < deadline { drain() }
    precondition(!delegate.muxOpening && controller?.muxBusy != true)
  }
  delegate.newWindow()
  waitMux()
  let controller = delegate.windows.last!
  let a = controller.session!
  precondition(a.herdrTerminal != nil && controller.workspaceView.muxEnabled)
  precondition("new_split:right".withCString { velokit_surface_binding_action(a.surface!, $0, 15) })
  drain()
  waitMux(controller)
  let right = controller.session!
  controller.splitPane("down")
  waitMux(controller)
  let bottom = controller.session!
  controller.workspaceView.layoutSubtreeIfNeeded()
  precondition(controller.tabs.count == 1 && controller.activeTab.panes.count == 3)
  precondition(right.chrome!.frame.minX > a.chrome!.frame.minX)
  precondition(bottom.chrome!.frame.minY < right.chrome!.frame.minY)
  precondition(a.view!.window === controller.window && right.view!.window === controller.window)
  controller.focusPane("up")
  precondition(controller.session === right)
  let height = right.chrome!.frame.height
  controller.resizePane("down")
  waitMux(controller)
  controller.workspaceView.layoutSubtreeIfNeeded()
  precondition(right.chrome!.frame.height != height)
  controller.newTab()
  waitMux(controller)
  let b = controller.session!
  precondition(a !== b && controller.tabs.count == 2)
  controller.newNamespace()
  waitMux(controller)
  let c = controller.session!
  precondition(controller.namespaces.count == 2 && controller.tabs.count == 1)
  controller.selectNamespace(at: 0)
  precondition(controller.session === b)
  controller.selectTab(a)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let marker = directory.appendingPathComponent("streamed")
  drain(); drain()
  let command = "printf VELOCITTY_HERDR_STREAM; printf ok > " + HerdrClient.quote(marker.path) + "\n"
  command.withCString { velokit_surface_text(a.surface!, $0, UInt(command.utf8.count)) }
  let deadline = Date(timeIntervalSinceNow: 8)
  while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { drain() }
  precondition(FileManager.default.fileExists(atPath: marker.path), "Input must reach the herdr shell")
  drain()
  precondition((a.view!.accessibilityValue() as? String)?.contains("VELOCITTY_HERDR_STREAM") == true)
  let ids = Set(controller.allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id })
  let workspace = controller.activeNamespace.herdrID!
  try client.rename(workspace: workspace, name: "Agents", subtitle: "Local tasks")
  controller.window?.performClose(nil)
  drain()
  precondition(a.surface == nil && b.surface == nil && c.surface == nil)
  let detached = try client.snapshot()
  precondition(Set(detached.panes.map(\.terminal_id)) == ids)
  delegate.newWindow()
  waitMux()
  let restored = delegate.windows.last!
  precondition(Set(restored.allPanes.compactMap { $0.herdrTerminal?.pane.terminal_id }) == ids)
  precondition(restored.namespaces.contains { $0.name == "Agents" && $0.subtitle == "Local tasks" })
  precondition(restored.namespaces.flatMap(\.tabs).contains { $0.panes.count == 3 })
  restored.selectNamespace(at: 1)
  let exiting = restored.session!
  drain(); drain()
  "exit\n".withCString { velokit_surface_text(exiting.surface!, $0, 5) }
  let exitDeadline = Date(timeIntervalSinceNow: 8)
  while exiting.surface != nil && Date() < exitDeadline { drain() }
  precondition(exiting.surface == nil && restored.namespaces.count == 1,
    "A herdr shell exit must close its tab without another keypress")
  let remaining = try client.snapshot()
  precondition(remaining.workspaces.count == 1 && remaining.panes.count == 4)
  let splitTab = restored.tabs.first { $0.panes.count == 3 }!
  restored.selectTab(splitTab)
  let closedPane = restored.session!
  restored.closePane(confirm: false)
  waitMux(restored)
  precondition(closedPane.surface == nil && splitTab.panes.count == 2)
  precondition(splitTab.panes.allSatisfy { $0.surface != nil })
  restored.closeTab(confirm: false)
  waitMux(restored)
  precondition(restored.tabs.count == 1 && restored.allPanes.count == 1)
  restored.window?.performClose(nil)
  drain()
}

if CommandLine.arguments.contains("--configuration-only") {
  delegate.terminating = true
  for controller in delegate.windows {
    controller.closing = true
    controller.window?.close()
  }
  print("Configuration reload tests passed.")
  exit(0)
}

// Native window navigation uses creation order, not the current stacking order.
do {
  let empty = AppDelegate()
  empty.gotoWindow(GHOSTTY_GOTO_WINDOW_NEXT, from: nil)
  empty.gotoWindow(GHOSTTY_GOTO_WINDOW_PREVIOUS, from: nil)
  precondition(empty.windows.isEmpty && empty.runtime == nil)

  delegate.newWindow()
  drain()
  let third = delegate.windows.last!
  func waitFor(_ message: String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition() && Date() < deadline {
      pumpEvents(until: Date(timeIntervalSinceNow: 0.02))
    }
    precondition(condition(), message)
  }
  func cycle(_ source: TerminalWindowController, _ direction: String,
    to destination: TerminalWindowController)
  {
    let action = "goto_window:" + direction
    precondition(action.withCString {
      velokit_surface_binding_action(source.session!.surface!, $0, UInt(action.utf8.count))
    })
    waitFor("Window cycling did not focus the expected destination") {
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
  waitFor("Destination did not minimize") { second.window!.isMiniaturized }
  first.window!.makeKeyAndOrderFront(nil)
  cycle(first, "next", to: second)

  // Closing entries cannot become destinations, even before deregistration.
  third.closing = true
  cycle(second, "next", to: first)
  third.window!.close()
  drain()
  precondition(delegate.windows.count == 2)
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_APP
  var action = ghostty_action_s()
  action.tag = GHOSTTY_ACTION_GOTO_WINDOW
  action.action.goto_window = GHOSTTY_GOTO_WINDOW_PREVIOUS
  precondition(delegate.runtime!.context.handleAction(target: target, action: action))
  waitFor("App navigation did not wrap past the closed window") { second.window!.isKeyWindow }
  precondition(delegate.windows[0] === first && delegate.windows[1] === second)
}

// Independent sessions retain independent sheets, and queued callbacks cannot reach replacements.
do {
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
  drain()
  precondition(replacement.window != nil && replacement.window!.title != "Stale title")
  precondition(first.session!.links.confirmation != nil && session.links.confirmation == nil)
  first.session!.links.cancel()
  replacement.closing = true
  replacement.window!.close()
  drain()
  precondition(delegate.windows.count == 2)
}

// A retained session keeps the engine alive; a retained view does not own either resource.
do {
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
do {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("velocitty-focus-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = directory.appendingPathComponent("record.sh")
  let input = directory.appendingPathComponent("input")
  let ready = directory.appendingPathComponent("ready")
  try Data("""
  stty raw -echo
  printf '\\033[?1004h'
  : > "$2"
  exec cat > "$1"
  """.utf8).write(to: script)
  let command = "/bin/sh " + ShellInput.paths([script.path, input.path, ready.path])
  let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  let recordingSettings = try AppConfiguration.parse(Data("""
  [terminal]
  command = "\(escapedCommand)"
  shell_integration = "none"
  theme = ""
  confirm_close_surface = false
  window_save_state = "never"
  """.utf8))
  let runtime = delegate.runtime!
  try runtime.updateConfiguration(recordingSettings)
  defer { try! runtime.updateConfiguration(settings) }
  let session = runtime.makeSession()
  let controller = TerminalWindowController(session: session, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  let window = controller.window!
  let terminal = session.view!
  func waitUntil(_ message: @autoclosure () -> String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition() && Date() < deadline {
      pumpEvents(until: Date(timeIntervalSinceNow: 0.02))
    }
    precondition(condition(), message())
  }
  app.activate(ignoringOtherApps: true)
  window.makeKeyAndOrderFront(nil)
  window.makeFirstResponder(terminal)
  waitUntil("Test application did not activate: active=\(app.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), keyWindow=\(String(describing: app.keyWindow)), target=\(window)") { app.isActive && window.isKeyWindow }
  waitUntil("Focus recorder did not start") { FileManager.default.fileExists(atPath: ready.path) }
  drain()
  func received() -> Data { (try? Data(contentsOf: input)) ?? Data() }
  var expected = received()
  func expect(_ delta: String, _ message: String) {
    expected.append(Data(delta.utf8))
    waitUntil("\(message); expected \(Array(expected)), received \(Array(received())); "
      + "active=\(app.isActive) key=\(window.isKeyWindow) "
      + "responder=\(window.firstResponder === terminal) sheet=\(window.attachedSheet != nil)") {
      received() == expected
    }
  }
  first.window!.makeKeyAndOrderFront(nil)
  expect("\u{1b}[O", "Background terminal did not report focus loss")
  precondition(window.firstResponder === terminal)
  window.makeFirstResponder(terminal) // A background first responder is still unfocused.
  runtime.updateFocus()
  drain()
  precondition(received() == expected)
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
  session.links = TerminalLinks { _ in fatalError("Unexpected link opening") }
  session.links.open("custom:focus-test", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: terminal)
  expect("\u{1b}[O", "Confirmation sheet retained terminal focus")
  session.links.cancel()
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
  drain()
  precondition(delegate.windows.count == 2)
}

// Exercise the actual native action routing with a fake OS opener.
do {
  delegate.newWindow()
  drain()
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
  drain()
  precondition(links.confirmation != nil && links.confirmation !== alert,
    "The next queued link should appear after cancelling the first")
  let queuedText = (links.confirmation!.accessoryView as! NSScrollView).documentView as! NSTextView
  precondition(queuedText.string == "file:///tmp/another")
  links.confirmation!.buttons[0].performClick(nil)
  drain()
  precondition(links.confirmation == nil && opened.count == 2,
    "Return cancellation: active=\(app.isActive), key=\(alert.window.isKeyWindow), "
      + "modifiers=\(alert.buttons[0].keyEquivalentModifierMask.rawValue), "
      + "default=\(String(describing: alert.window.defaultButtonCell?.title)), opened=\(opened.count)")
  sendLink(destination)
  links.confirmation!.buttons[1].performClick(nil)
  drain()
  precondition(opened.count == 3 && opened.last!.absoluteString == destination)
  sendLink("file:///tmp/test")
  precondition(links.confirmation != nil)
  controller.closing = true
  controller.window!.close()
  drain()
  precondition(links.confirmation == nil && opened.count == 3)
  precondition(delegate.windows.count == 2)
}

// Clipboard ownership: queue order, other sheets, and exactly-once teardown replies.
do {
  let runtime = delegate.runtime!
  let session = runtime.makeSession()
  let controller = TerminalWindowController(session: session, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  let view = session.view!
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
  drain()
  let firstAlert = queue.confirmation!
  precondition(firstAlert.messageText == "Clipboard test 1" && replies.isEmpty)
  firstAlert.suppressionButton!.state = .on
  firstAlert.buttons[0].performClick(nil)
  drain()
  precondition(replies.count == 1 && replies[0].0 == 1 && replies[0].1 && replies[0].2)
  precondition(queue.confirmation!.messageText == "Clipboard test 2")
  queue.confirmation!.suppressionButton!.state = .on
  queue.confirmation!.buttons[1].performClick(nil)
  drain()
  precondition(replies.count == 2 && replies[1].0 == 2 && !replies[1].1 && !replies[1].2)
  precondition(queue.confirmation == nil)

  controller.window!.makeKeyAndOrderFront(nil)
  session.links.open("custom:clipboard-test", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: view)
  precondition(session.links.confirmation != nil)
  enqueue(3)
  drain()
  precondition(queue.confirmation == nil && replies.count == 2)
  session.links.cancel()
  drain()
  precondition(queue.confirmation?.messageText == "Clipboard test 3")
  enqueue(4)
  let closingAlert = queue.confirmation!
  controller.closing = true
  controller.window!.close()
  precondition(view.surface == nil && replies.count == 4)
  precondition(replies[2].0 == 3 && !replies[2].1 && replies[3].0 == 4 && !replies[3].1)
  closingAlert.buttons[0].performClick(nil) // A late UI response cannot complete again.
  queue.cancel()
  drain()
  precondition(replies.count == 4 && queue.confirmation == nil)
}

// Cancellation before presentation, including the no-request-state write callback.
do {
  let runtime = delegate.runtime!
  let session = runtime.makeSession()
  let controller = TerminalWindowController(session: session, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  let view = session.view!
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
  drain()
  precondition(view.clipboard.confirmation == nil && denied == 1)
  precondition(board.string(forType: .string) == "unchanged")
}

do {
  let runtime = try TerminalRuntime(settings: settings)
  let session = runtime.makeSession()
  let view = session.createView()! // Never attached to a window.
  var denied = 0
  view.clipboard.enqueue(title: "Unattached", message: "Test") { allow, _ in
    precondition(!allow && view.surface != nil)
    denied += 1
  }
  drain()
  precondition(denied == 1 && view.clipboard.confirmation == nil)
  session.close()
  precondition(denied == 1)
}

// Exercise native request allocation, copied clipboard bytes, completion and denial at a PTY.
do {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("velocitty-clipboard-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = directory.appendingPathComponent("record.sh")
  let input = directory.appendingPathComponent("input")
  let ready = directory.appendingPathComponent("ready")
  try Data("stty raw -echo\n: > \"$2\"\nexec cat > \"$1\"\n".utf8).write(to: script)
  let command = "/bin/sh " + ShellInput.paths([script.path, input.path, ready.path])
  let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  let recordingSettings = try AppConfiguration.parse(Data("""
  [terminal]
  command = "\(escapedCommand)"
  shell_integration = "none"
  theme = ""
  confirm_close_surface = false
  window_save_state = "never"
  clipboard_paste_protection = true
  clipboard_paste_bracketed_safe = false
  """.utf8))
  let runtime = delegate.runtime!
  try runtime.updateConfiguration(recordingSettings)
  defer { try! runtime.updateConfiguration(settings) }
  let session = runtime.makeSession()
  let controller = TerminalWindowController(session: session, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  let view = session.view!
  func waitFor(_ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition() && Date() < deadline { drain() }
    precondition(condition(), "Clipboard PTY check timed out")
  }
  waitFor { FileManager.default.fileExists(atPath: ready.path) }
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
  waitFor { view.clipboard.confirmation != nil }
  precondition(view.clipboard.confirmation!.informativeText.contains("first\nsecond"))
  view.clipboard.confirmation!.buttons[0].performClick(nil)
  waitFor { view.clipboard.confirmation?.informativeText.contains("denied\ntext") == true }
  view.clipboard.confirmation!.buttons[1].performClick(nil)
  let expected = Data("first\rsecond".utf8)
  waitFor { (try? Data(contentsOf: input)) == expected }
  drain()
  precondition((try? Data(contentsOf: input)) == expected)
  paste("pending\none")
  paste("pending\ntwo")
  waitFor { view.clipboard.confirmation != nil }
  controller.closing = true
  controller.window!.close()
  drain()
  precondition(view.surface == nil && view.clipboard.confirmation == nil)
  precondition((try? Data(contentsOf: input)) == expected)
  precondition(delegate.windows.count == 2)
}

if testAutomaticQuit {
  precondition(delegate.native.quitAfterLastWindowClosed)
  first.window?.performClose(nil)
  drain()
  precondition(delegate.windows.count == 1)
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
drain()
precondition(first.window?.title == "Background terminal")
precondition(second.window?.title != "Background terminal")
second.window?.makeKeyAndOrderFront(nil)
drain()
let close = menuItem("Close Window")
precondition(close.keyEquivalent == "w")
precondition(app.sendAction(close.action!, to: close.target, from: close))
drain()
precondition(delegate.windows.count == 1)
precondition(first.session?.view?.surface != nil)
precondition(second.session?.view == nil)
delegate.gotoWindow(GHOSTTY_GOTO_WINDOW_NEXT, from: first)
delegate.gotoWindow(GHOSTTY_GOTO_WINDOW_PREVIOUS, from: first)
drain()
precondition(first.window!.isKeyWindow && delegate.windows.count == 1)
first.window?.performClose(nil)
drain()
precondition(delegate.windows.isEmpty)
precondition(terminal.surface == nil && terminal.config == nil)
precondition(!delegate.validateMenuItem(closeMenuItem))
precondition(delegate.runtime?.app == originalEngine)
precondition(app.sendAction(new.action!, to: new.target, from: new))
precondition(app.sendAction(new.action!, to: new.target, from: new))
drain()
precondition(delegate.windows.count == 2)
precondition(delegate.windows.allSatisfy { $0.session?.runtime.app == originalEngine })
let quit = menuItem("Quit Velocitty")
precondition(quit.keyEquivalent == "q")
precondition(quit.action == #selector(NSApplication.terminate(_:)))
precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
precondition(delegate.windows.count == 2, "Quit must preserve windows for AppKit state capture")
delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
precondition(delegate.windows.allSatisfy { $0.session?.surface == nil })
for controller in delegate.windows { controller.closing = true; controller.window?.close() }
precondition(delegate.windows.isEmpty)
print("Window lifecycle tests passed.")

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
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { application.terminate(nil) }
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


func runWorkspacePersistenceCheck() throws {
  guard let executable = HerdrClient.discover() else { fatalError("herdr is required for this check") }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("velocitty-state-" + UUID().uuidString)
  let file = directory.appendingPathComponent("workspace.json")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let herdrConfig = directory.appendingPathComponent("herdr.toml")
  try Data("[terminal]\ndefault_shell='/bin/zsh'\n".utf8).write(to: herdrConfig)
  let previousConfig = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
  setenv("HERDR_CONFIG_PATH", herdrConfig.path, 1)
  defer {
    if let previousConfig { setenv("HERDR_CONFIG_PATH", previousConfig, 1) }
    else { unsetenv("HERDR_CONFIG_PATH") }
  }
  let client = HerdrClient(executable: executable, sessionName: "velocitty-test-" + UUID().uuidString.lowercased())
  defer {
    _ = try? client.run(["server", "stop"])
    _ = try? client.run(["session", "delete", client.sessionName])
    try? FileManager.default.removeItem(at: directory)
  }
  let settings = try AppConfiguration.parse(Data("[terminal]\nconfirm_close_surface=false\ntheme=''\n".utf8))
  func makeOwner() throws -> AppDelegate {
    let owner = AppDelegate()
    owner.workspaceStateURL = file
    owner.runtime = try TerminalRuntime(settings: settings)
    owner.herdr = client
    return owner
  }
  func wait(_ owner: AppDelegate, _ controller: TerminalWindowController? = nil) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while (owner.muxOpening || (controller?.muxBusy == true || controller?.hasPendingMuxActions == true)) && Date() < deadline {
      pumpEvents(until: Date(timeIntervalSinceNow: 0.02))
    }
    precondition(!owner.muxOpening && controller?.muxBusy != true)
  }
  let first = try makeOwner()
  first.newWindow(); wait(first)
  let window = first.windows.last!
  let integrationMarker = directory.appendingPathComponent("integration")
  pumpEvents(until: Date(timeIntervalSinceNow: 0.5))
  let integrationCommand = "(( $+_ghostty_state )) && printf ok > " + HerdrClient.quote(integrationMarker.path) + "\n"
  integrationCommand.withCString { velokit_surface_text(window.session!.surface!, $0, UInt(integrationCommand.utf8.count)) }
  let shellDeadline = Date(timeIntervalSinceNow: 5)
  while !FileManager.default.fileExists(atPath: integrationMarker.path) && Date() < shellDeadline { pumpEvents(until: Date(timeIntervalSinceNow: 0.02)) }
  precondition(FileManager.default.fileExists(atPath: integrationMarker.path), "New herdr shells must load integration")
  let running = try client.hasRunningTask(paneID: window.session!.herdrTerminal!.pane.pane_id)
  precondition(running == false, "An idle shell should not prompt to close")
  let recoveredPane = window.session!
  let terminalID = recoveredPane.herdrTerminal!.pane.terminal_id
  recoveredPane.attachmentExited()
  recoveredPane.attachmentExited()
  let recoveryDeadline = Date(timeIntervalSinceNow: 8)
  while recoveredPane.recovering && Date() < recoveryDeadline { pumpEvents(until: Date(timeIntervalSinceNow: 0.02)) }
  precondition(!recoveredPane.recovering && window.session === recoveredPane)
  precondition(recoveredPane.herdrTerminal!.pane.terminal_id == terminalID)
  let recoveryMarker = directory.appendingPathComponent("recovered")
  let recoveredCommand = "printf ok > " + HerdrClient.quote(recoveryMarker.path) + "\n"
  recoveredCommand.withCString { velokit_surface_text(recoveredPane.surface!, $0, UInt(recoveredCommand.utf8.count)) }
  let inputDeadline = Date(timeIntervalSinceNow: 5)
  while !FileManager.default.fileExists(atPath: recoveryMarker.path) && Date() < inputDeadline { pumpEvents(until: Date(timeIntervalSinceNow: 0.02)) }
  precondition(FileManager.default.fileExists(atPath: recoveryMarker.path), "Recovered attachment must accept input in the same shell")
  window.newTab()
  window.newTab()
  wait(first, window)
  precondition(window.tabs.count == 3, "Busy mux actions must queue instead of disappearing")
  let beforeSelection = try client.snapshot().workspaces.map(\.active_tab_id)
  window.selectTab(window.tabs[0])
  window.selectTab(window.tabs[2])
  wait(first, window)
  let afterSelection = try client.snapshot().workspaces.map(\.active_tab_id)
  precondition(afterSelection == beforeSelection, "Velocitty navigation must not change herdr focus")
  window.splitPane("right"); wait(first, window)
  let splitTabID = window.activeTab.herdrID!
  window.setSplitRatio(tabID: splitTabID, path: [], ratio: 0.3); wait(first, window)
  let resizedTree = try client.layoutTree(tabID: splitTabID)
  precondition(abs((resizedTree.ratio ?? 0) - 0.3) < 0.01)
  window.equalizePanes(); wait(first, window)
  let equalTree = try client.layoutTree(tabID: splitTabID)
  precondition(abs((equalTree.ratio ?? 0) - 0.5) < 0.01)
  let originalPane = window.session!
  window.splitPane("left"); wait(first, window)
  window.workspaceView.layoutSubtreeIfNeeded()
  precondition(window.session!.chrome!.frame.midX < originalPane.chrome!.frame.midX, "Left split must appear before the original pane")
  window.selectTab(originalPane)
  let selectedPane = originalPane.herdrTerminal!.pane.pane_id
  window.togglePaneZoom()
  precondition(window.activeTab.zoomed && window.session!.herdrTerminal!.pane.pane_id == selectedPane)
  window.newTab(); wait(first, window)
  window.moveTab(-1)
  let order = window.tabs.map { $0.herdrID! }
  window.selectTab(window.tabs.first { $0.herdrID == splitTabID }!)
  window.newNamespace(); wait(first, window)
  let selectedNamespace = window.activeNamespace.herdrID!
  window.workspaceView.restoreSidebarState(.init(width: 276, compact: true))
  window.workspaceView.layoutSubtreeIfNeeded()
  first.scheduleWorkspaceSave(window)
  first.flushWorkspaceSave()
  let saved = try WorkspaceStateStore(url: file).load()
  precondition(saved.selectedNamespaceID == selectedNamespace)
  window.window?.performClose(nil)
  pumpEvents(until: Date(timeIntervalSinceNow: 0.05))
  // A fresh owner loads the file, rather than reusing the in-memory state.
  let second = try makeOwner()
  second.newWindow(); wait(second)
  let restored = second.windows.last!
  restored.workspaceView.layoutSubtreeIfNeeded()
  precondition(restored.activeNamespace.herdrID == selectedNamespace)
  precondition(restored.namespaces[0].tabs.map { $0.herdrID! } == order)
  let split = restored.namespaces[0].tabs.first { $0.herdrID == splitTabID }!
  precondition(split.selected.herdrTerminal!.pane.pane_id == selectedPane)
  precondition(split.zoomed, "Local pane zoom must survive relaunch")
  precondition(restored.workspaceView.savedSidebarState == .init(width: 276, compact: true))
  // External changes must attach exactly once without importing backend focus.
  let localSelection = restored.session!
  let previousTabs = Set(restored.namespaces.flatMap(\.tabs).compactMap(\.herdrID))
  var eventReceived = false
  let eventHandler = client.onWorkspaceEvent
  client.onWorkspaceEvent = { eventReceived = true; eventHandler?() }
  let external = try client.create(workspace: selectedNamespace, name: "External", directory: directory.path)
  let added = external.panes.first { !previousTabs.contains($0.tab_id) }!
  let beforeRollback = restored.allPanes.count
  let invalid = HerdrClient.Snapshot(layouts: external.layouts, workspaces: external.workspaces, tabs: external.tabs, panes: [added, added])
  do { try restored.addHerdrTerminals(invalid, excluding: []); preconditionFailure("Expected duplicate rejection") }
  catch { precondition(restored.allPanes.count == beforeRollback, "A failed attachment must roll back prepared views") }
  let eventDeadline = Date(timeIntervalSinceNow: 3)
  while !eventReceived && Date() < eventDeadline { pumpEvents(until: Date(timeIntervalSinceNow: 0.02)) }
  precondition(client.eventsConnected && eventReceived, "Structural events must arrive over the read-only API")
  second.synchronizeHerdr(external, client: client)
  let count = restored.allPanes.count
  second.synchronizeHerdr(external, client: client)
  precondition(restored.allPanes.count == count && restored.session === localSelection)
  let externalTab = external.tabs.first { !previousTabs.contains($0.tab_id) }!
  _ = try client.request(["tab", "close", externalTab.tab_id])
  second.synchronizeHerdr(try client.snapshot(), client: client)
  precondition(restored.allPanes.count == count - 1 && restored.session === localSelection)
  // A second window has independent ownership and geometry across relaunch.
  second.newWindow(); wait(second)
  let extra = second.windows.first { $0 !== restored }!
  let extraID = extra.workspaceWindowID
  let extraNamespace = extra.activeNamespace.herdrID
  extra.window?.setFrame(NSRect(x: 100, y: 100, width: 850, height: 650), display: true)
  second.scheduleWorkspaceSave(extra); second.flushWorkspaceSave()
  extra.window?.performClose(nil)
  second.synchronizeHerdr(try client.snapshot(), client: client)
  precondition(!restored.namespaces.contains { $0.herdrID == extraNamespace }, "Detached windows must stay detached")
  restored.window?.performClose(nil)
  let third = try makeOwner()
  third.newWindow(); wait(third)
  precondition(third.windows.count == 2, "Window assignments must survive relaunch")
  let extraRestored = third.windows.first { $0.workspaceWindowID == extraID }!
  precondition(extraRestored.activeNamespace.herdrID == extraNamespace)
  precondition(extraRestored.window!.frame.width == 850)
  for controller in Array(third.windows) { controller.window?.performClose(nil) }
  print("Workspace persistence tests passed.")
}

// Runs without creating NSApplication or a real herdr server, including in Core CI.
func runHerdrControlCheck() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("velocitty-control-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
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
  try script("(sleep 0.3; touch " + HerdrClient.quote(descendant.path) + ") &\nwait")
  let started = ProcessInfo.processInfo.systemUptime
  do { _ = try client.run(["read"], timeout: 0.1); preconditionFailure("Expected timeout") }
  catch let error as HerdrClient.RequestError { precondition(error.code == "timeout") }
  precondition(ProcessInfo.processInfo.systemUptime - started < 1)
  // A malformed response must not start a server or be treated as an empty workspace.
  try script("if [ \"$3\" = '--version' ]; then echo 'herdr 0.8.2'; else echo invalid; fi")
  do { _ = try client.connect(directory: root); preconditionFailure("Expected invalid snapshot") }
  catch { precondition(!(error is HerdrClient.RequestError)) }
  try script("printf '%s' '{\"result\":{\"snapshot\":{\"workspaces\":[],\"tabs\":[],\"panes\":[],\"layouts\":[]}}}'")
  let empty = try client.snapshot()
  precondition(empty.panes.isEmpty)
  Thread.sleep(forTimeInterval: 0.4)
  precondition(!FileManager.default.fileExists(atPath: descendant.path), "Timeout must also terminate request descendants")
  print("Herdr control tests passed.")
}
