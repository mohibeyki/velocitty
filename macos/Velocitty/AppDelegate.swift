// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon
import Foundation
import VeloKit
import VelocittyConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var runtime: TerminalRuntime?
    var appearanceObservation: NSKeyValueObservation?
    var keyboardObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled artwork directly so the running Dock tile doesn't
        // depend on Launch Services resolving an icon for a development build.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        installMainMenu()
        keyboardObservation = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            if let app = self?.runtime?.app { velokit_app_keyboard_changed(app) }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reloadConfiguration(nil) }
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

        guard let terminalView = runtime.createView() else {
            NSLog("VeloKit failed to create the terminal")
            NSApp.terminate(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Velocitty"
        window.isReleasedWhenClosed = false
        window.contentView = terminalView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)

        self.runtime = runtime
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

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
        appMenu.addItem(withTitle: "Hide Velocitty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
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
        appMenu.addItem(withTitle: "Quit Velocitty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        editMenu.addItem(withTitle: "Copy", action: #selector(TerminalView.copyMenuItem(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.pasteMenuItem(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(TerminalView.selectAllMenuItem(_:)),
            keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }

    func configurationAlert(_ error: Error) -> NSAlert {
        NSLog("Configuration error: %@", error.localizedDescription)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not load configuration"
        alert.informativeText = error.localizedDescription
        return alert
    }

    @objc private func reloadConfiguration(_ sender: Any?) {
        guard let runtime else { return }
        do {
            try runtime.updateConfiguration(AppConfiguration.load())
        } catch {
            configurationAlert(error).runModal()
        }
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Velocitty",
            .applicationVersion: "0.1.0",
            .credits: NSAttributedString(string: "A macOS terminal powered by libghostty.")
        ])
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let app = runtime?.app {
            velokit_app_set_focus(app, true)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let app = runtime?.app {
            velokit_app_set_focus(app, false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

