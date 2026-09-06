// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon
import UserNotifications
import Foundation
import VeloKit
import VelocittyConfiguration

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var runtime: TerminalRuntime?
    var appearanceObservation: NSKeyValueObservation?
    var quitTimer: Timer?
    var closing = false
    var passwordInput = false
    var manualSecureInput = false
    var secureInputEnabled = false
    var bellSound: NSSound?
    var bellTitle: String?
    var progressTimer: Timer?
    var chrome: TerminalChrome?
    var native: NativeSettings { NativeSettings(config: runtime?.config) }
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

        self.runtime = runtime
        if native.value("initial-window", true) { openWindow() }
        if native.string("macos-hidden") == "always" { NSApp.hide(nil) }
    }

    func openWindow() {
        quitTimer?.invalidate()
        quitTimer = nil
        if let window { window.makeKeyAndOrderFront(nil); return }
        guard let runtime, let terminalView = runtime.createView() else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
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
            let columns = native.value("window-width", UInt32(0))
            let rows = native.value("window-height", UInt32(0))
            if columns > 0 || rows > 0 {
                window.setContentSize(NSSize(width: columns > 0 ? CGFloat(columns) * CGFloat(size.cell_width_px) / scale + 16 : 960,
                                             height: rows > 0 ? CGFloat(rows) * CGFloat(size.cell_height_px) / scale + 16 : 640))
            }
            if native.value("window-step-resize", false) {
                window.contentResizeIncrements = NSSize(width: max(1, CGFloat(size.cell_width_px) / scale), height: max(1, CGFloat(size.cell_height_px) / scale))
            }
        }
        window.center()
        if shouldSaveState { _ = window.setFrameUsingName("TerminalWindow") }
        let x = native.value("window-position-x", Int16.min)
        let y = native.value("window-position-y", Int16.min)
        if x != Int16.min || y != Int16.min, let screen = window.screen {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: x == Int16.min ? window.frame.minX : frame.minX + CGFloat(x),
                                          y: y == Int16.min ? window.frame.minY : frame.maxY - window.frame.height - CGFloat(y)))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
        if native.value("maximize", false) { window.zoom(nil) }
        if native.string("fullscreen", "false") != "false" || (shouldSaveState && UserDefaults.standard.bool(forKey: "TerminalFullscreen")) {
            window.toggleFullScreen(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var shouldSaveState: Bool {
        let policy = native.string("window-save-state", "default")
        return policy == "always" || (policy == "default" && (UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool ?? true))
    }

    func applyWindowSettings() {
        guard let window else { return }
        let titlebar = native.string("macos-titlebar-style", "transparent")
        if native.string("window-decoration") == "none" || titlebar == "hidden" {
            window.styleMask.remove(.titled)
        } else { window.styleMask.insert(.titled) }
        window.titlebarAppearsTransparent = titlebar != "native"
        window.hasShadow = native.value("macos-window-shadow", true)
        window.titleVisibility = titlebar == "hidden" ? .hidden : .visible
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = native.string("macos-window-buttons") == "hidden"
        }
        window.colorSpace = native.string("window-colorspace") == "display-p3" ? .displayP3 : .sRGB
        let theme = native.string("window-theme")
        window.appearance = theme == "dark" ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
        let opacity = native.value("background-opacity", 1.0)
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
        } else if (blur == 0 || opacity >= 1), let terminal = chrome, window.contentView is NSVisualEffectView {
            terminal.removeFromSuperview()
            window.contentView = terminal
        }
    }

    func confirmClose() -> Bool {
        guard let surface = runtime?.view?.surface, velokit_surface_needs_confirm_quit(surface) else { return true }
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
            window?.saveFrame(usingName: "TerminalWindow")
            UserDefaults.standard.set(window?.styleMask.contains(.fullScreen) == true, forKey: "TerminalFullscreen")
        }
        passwordInput = false
        manualSecureInput = false
        updateSecureInput(forceOff: true)
        clearProgress()
        runtime?.closeView()
        window = nil
        chrome = nil
        if native.value("quit-after-last-window-closed", false) {
            quitTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, native.seconds("quit-after-last-window-closed-delay", 0)), repeats: false) { [weak self] _ in
                if self?.window == nil { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmClose() else { return .terminateCancel }
        closing = true
        if let window { window.close() }
        return .terminateNow
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openWindow()
        let text = filenames.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " "
        if let surface = runtime?.view?.surface {
            text.withCString { velokit_surface_text(surface, $0, UInt(text.utf8.count)) }
        }
        sender.reply(toOpenOrPrint: .success)
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

        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(findTerminal), keyEquivalent: "f")
        find.target = self
        let next = editMenu.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        next.target = self
        let previous = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        previous.target = self

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

    @objc func findTerminal() { runtime?.view?.performSurfaceAction("start_search") }
    @objc func findNext() { runtime?.view?.performSurfaceAction("navigate_search:next") }
    @objc func findPrevious() { runtime?.view?.performSurfaceAction("navigate_search:previous") }

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
            applyWindowSettings()
            updateSecureInput()
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
        updateSecureInput()
        if let bellTitle { window?.title = bellTitle; self.bellTitle = nil }
        if let app = runtime?.app {
            velokit_app_set_focus(app, true)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        updateSecureInput(forceOff: true)
        if let app = runtime?.app {
            velokit_app_set_focus(app, false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}



extension AppDelegate {
    func ringBell() {
        let features = native.value("bell-features", UInt32(12))
        if features & 1 != 0 { NSSound.beep() }
        if features & 2 != 0 {
            let pathValue = native.value("bell-audio-path", ghostty_config_path_s(path: nil, optional: false))
            let path = pathValue.path.map { String(cString: $0) } ?? ""
            bellSound = path.isEmpty ? NSSound(named: "Glass") : NSSound(contentsOfFile: path, byReference: true)
            bellSound?.volume = Float(native.value("bell-audio-volume", 0.5))
            bellSound?.play()
        }
        if !NSApp.isActive {
            if features & 4 != 0 { NSApp.requestUserAttention(.informationalRequest) }
            if features & 8 != 0, bellTitle == nil { bellTitle = window?.title; window?.title = "● " + (window?.title ?? "Velocitty") }
        }
        if features & 16 != 0, let chrome {
            chrome.wantsLayer = true
            chrome.layer?.borderColor = NSColor.controlAccentColor.cgColor
            chrome.layer?.borderWidth = 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak chrome] in chrome?.layer?.borderWidth = 0 }
        }
    }

    func notify(title: String, body: String) {
        guard native.value("desktop-notifications", true) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                    if let error { NSLog("Notification failed: %@", error.localizedDescription) }
                }
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional: deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in if allowed { deliver() } }
            default: break
            }
        }
    }

    func commandFinished(_ value: ghostty_action_command_finished_s) {
        let policy = native.string("notify-on-command-finish", "never")
        guard policy != "never", policy == "always" || !NSApp.isActive,
              Double(value.duration) / 1_000_000_000 >= native.seconds("notify-on-command-finish-after", 5) else { return }
        let actions = native.value("notify-on-command-finish-action", UInt32(1))
        if actions & 1 != 0 { ringBell() }
        if actions & 2 != 0 {
            notify(title: "Command finished", body: value.exit_code < 0 ? "The command has finished." : "The command exited with status \(value.exit_code).")
        }
    }

    func clearProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
    }

    func showProgress(_ report: ghostty_action_progress_report_s) {
        guard native.value("progress-style", true), report.state != GHOSTTY_PROGRESS_STATE_REMOVE else { clearProgress(); return }
        let tile = NSApp.dockTile
        let container = NSView(frame: NSRect(origin: .zero, size: tile.size))
        let icon = NSImageView(frame: container.bounds)
        icon.image = NSApp.applicationIconImage
        container.addSubview(icon)
        let progress = NSProgressIndicator(frame: NSRect(x: 10, y: 7, width: max(20, tile.size.width - 20), height: 12))
        progress.style = .bar
        progress.isIndeterminate = report.state == GHOSTTY_PROGRESS_STATE_INDETERMINATE
        progress.minValue = 0; progress.maxValue = 100
        progress.doubleValue = Double(max(0, report.progress))
        container.addSubview(progress)
        if progress.isIndeterminate { progress.startAnimation(nil) }
        tile.contentView = container
        tile.badgeLabel = report.state == GHOSTTY_PROGRESS_STATE_ERROR ? "!" : report.state == GHOSTTY_PROGRESS_STATE_PAUSE ? "Ⅱ" : nil
        tile.display()
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.clearProgress() }
    }
}


extension AppDelegate {
    func secureInput(_ mode: ghostty_action_secure_input_e) {
        if mode == GHOSTTY_SECURE_INPUT_TOGGLE { manualSecureInput.toggle() }
        else { passwordInput = mode == GHOSTTY_SECURE_INPUT_ON }
        updateSecureInput()
    }
    func updateSecureInput(forceOff: Bool = false) {
        let wanted = !forceOff && NSApp.isActive && window?.isKeyWindow == true &&
            (manualSecureInput || (passwordInput && native.value("macos-auto-secure-input", true)))
        if wanted != secureInputEnabled {
            if wanted { secureInputEnabled = EnableSecureEventInput() == noErr }
            else if DisableSecureEventInput() == noErr { secureInputEnabled = false }
        }
        chrome?.secure.stringValue = secureInputEnabled && native.value("macos-secure-input-indication", true) ? "􀎡 Secure Input" : ""
    }
    func windowDidBecomeKey(_ notification: Notification) { updateSecureInput() }
    func windowDidResignKey(_ notification: Notification) { updateSecureInput(forceOff: true) }
}
