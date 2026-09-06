// SPDX-License-Identifier: GPL-3.0
// Standalone AppKit lifecycle check; compile with the app sources except main.swift.
import AppKit
import VeloKit
import VelocittyConfiguration

precondition(velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
let testAutomaticQuit = CommandLine.arguments.contains("--quit-on-close")
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
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }
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

if testAutomaticQuit {
  precondition(delegate.native.value("quit-after-last-window-closed", false))
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
