// SPDX-License-Identifier: GPL-3.0
// Standalone AppKit lifecycle check; compile with the app sources except main.swift.
import AppKit
import VeloKit
import VelocittyConfiguration

precondition(velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
let previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
pumpEvents(until: Date(timeIntervalSinceNow: 0.2))
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

let settings = try AppConfiguration.parse(Data(("""
[terminal]
command = "/bin/sh"
shell_integration = "none"
theme = ""
confirm_close_surface = false
window_save_state = "never"
""" + (testAutomaticQuit ? "\nquit_after_last_window_closed = true" : "")).utf8))
delegate.idleRuntime = try TerminalRuntime(settings: settings)
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
  let invalid = try AppConfiguration.load(from: root)
  do {
    let config = try TerminalRuntime.makeConfig(invalid)
    velokit_config_free(config)
    fatalError("Invalid included setting was accepted")
  } catch {
    precondition(error.localizedDescription.hasPrefix(included.path + ":"))
  }
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
let terminal = first.runtime!.view!
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
  try first.runtime!.updateConfiguration(updated)
  first.chrome!.scrollState = ghostty_action_scrollbar_s(total: 100, offset: 0, len: 10)
  first.applyWindowSettings()
  precondition(first.chrome!.showScroll == (scrollbar == "system"))
  precondition((first.titleAccessory == nil) == (style == "hidden"))
}
try first.runtime!.updateConfiguration(settings)
first.applyWindowSettings()

precondition(app.sendAction(new.action!, to: new.target, from: new))
drain()
precondition(delegate.windows.count == 2)
precondition(delegate.validateMenuItem(closeMenuItem))
let second = delegate.windows[1]
precondition(first.runtime?.view?.surface != second.runtime?.view?.surface)
precondition(first.runtime?.context.owner === first)
precondition(second.runtime?.context.owner === second)
precondition(second.window!.frame.minX > first.window!.frame.minX)
precondition(second.window!.frame.maxY < first.window!.frame.maxY)

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
  let runtime = try TerminalRuntime(settings: recordingSettings)
  let controller = TerminalWindowController(runtime: runtime, owner: delegate)
  delegate.windows.append(controller)
  controller.openWindow(cascadingFrom: second.window)
  let window = controller.window!
  let terminal = runtime.view!
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
  waitUntil("Test application did not activate") { app.isActive && window.isKeyWindow }
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
  runtime.context.links = TerminalLinks { _ in fatalError("Unexpected link opening") }
  runtime.context.links.open("custom:focus-test", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, from: terminal)
  expect("\u{1b}[O", "Confirmation sheet retained terminal focus")
  runtime.context.links.cancel()
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
  terminal.insertText("日本" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
  expect("日本", "Committed composition did not reach the PTY exactly once")
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
  let context = controller.runtime!.context
  var opened: [URL] = []
  context.links = TerminalLinks { opened.append($0) }
  let links = context.links
  var target = ghostty_target_s()
  target.tag = GHOSTTY_TARGET_SURFACE
  target.target.surface = controller.runtime!.view!.surface
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
target.target.surface = first.runtime!.view!.surface
var action = ghostty_action_s()
action.tag = GHOSTTY_ACTION_SET_TITLE
"Background terminal".withCString {
  action.action.set_title.title = $0
  precondition(first.runtime!.context.handleAction(target: target, action: action))
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
precondition(first.runtime?.view?.surface != nil)
precondition(second.runtime?.view == nil)
first.window?.performClose(nil)
drain()
precondition(delegate.windows.isEmpty)
precondition(terminal.surface == nil && terminal.config == nil)
precondition(!delegate.validateMenuItem(closeMenuItem))
precondition(delegate.idleRuntime != nil)
precondition(app.sendAction(new.action!, to: new.target, from: new))
precondition(app.sendAction(new.action!, to: new.target, from: new))
drain()
precondition(delegate.windows.count == 2)
let quit = menuItem("Quit Velocitty")
precondition(quit.keyEquivalent == "q")
precondition(quit.action == #selector(NSApplication.terminate(_:)))
precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
precondition(delegate.windows.isEmpty)
print("Window lifecycle tests passed.")
