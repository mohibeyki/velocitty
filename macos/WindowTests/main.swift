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
precondition(app.sendAction(new.action!, to: new.target, from: new))
drain()
let first = delegate.windows[0]
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
