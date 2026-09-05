// SPDX-License-Identifier: GPL-3.0

import AppKit
import Foundation
import VeloKit

private final class RuntimeContext: NSObject {
    var app: ghostty_app_t?

    static func fromApp(_ app: ghostty_app_t) -> RuntimeContext? {
        guard let userdata = velokit_app_userdata(app) else { return nil }
        return Unmanaged<RuntimeContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func fromSurfaceUserdata(_ userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    func tick() {
        guard let app else { return }
        velokit_app_tick(app)
    }

    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: TerminalView? = {
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surface = target.target.surface,
               let userdata = velokit_surface_userdata(surface) {
                return Self.fromSurfaceUserdata(userdata)
            }
            return nil
        }()

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            if let surface = target.target.surface {
                velokit_surface_draw(surface)
            }

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_WINDOW_TITLE:
            guard let title = action.action.set_title.title.map({ String(cString: $0) }) else {
                return true
            }
            DispatchQueue.main.async {
                view?.window?.title = title
            }

        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }

        default:
            return false
        }

        return true
    }

    static let wakeup: ghostty_runtime_wakeup_cb = { userdata in
        guard let userdata else { return }
        let context = Unmanaged<RuntimeContext>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            context.tick()
        }
    }

    static let action: ghostty_runtime_action_cb = { app, target, action in
        guard let app, let context = RuntimeContext.fromApp(app) else { return false }
        return context.handleAction(target: target, action: action)
    }

    static let readClipboard: ghostty_runtime_read_clipboard_cb = {
        userdata, location, state, _, _, _ in
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = RuntimeContext.fromSurfaceUserdata(userdata),
              let surface = view.surface,
              let string = NSPasteboard.general.string(forType: .string)
        else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        var bytes = Array(string.utf8)
        if bytes.isEmpty { bytes = [0] }
        let mime = "text/plain"
        mime.withCString { mimePtr in
            bytes.withUnsafeBufferPointer { buffer in
                let data = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
                var content = ghostty_clipboard_content_s(
                    mime: mimePtr,
                    data: data,
                    len: string.utf8.count)
                withUnsafePointer(to: &content) { contentPointer in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentPointer,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: true,
                        remember: false)
                    velokit_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }

        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static let confirmReadClipboard: ghostty_runtime_confirm_read_clipboard_cb = {
        userdata, _, state, _ in
        guard let view = RuntimeContext.fromSurfaceUserdata(userdata),
              let surface = view.surface
        else { return }
        velokit_surface_deny_clipboard_request(surface, state)
    }

    static let writeClipboard: ghostty_runtime_write_clipboard_cb = {
        _, location, content, length, _ in
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              content != nil,
              length > 0
        else { return }

        for index in 0..<length {
            let item = content![index]
            guard let mime = item.mime,
                  String(cString: mime) == "text/plain",
                  item.len > 0,
                  let data = item.data
            else { continue }

            let bytes = Data(bytes: data, count: item.len)
            guard let string = String(data: bytes, encoding: .utf8) else { continue }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
            break
        }
    }

    static let closeSurface: ghostty_runtime_close_surface_cb = { userdata, _ in
        guard let view = RuntimeContext.fromSurfaceUserdata(userdata) else { return }
        DispatchQueue.main.async {
            view.window?.performClose(nil)
        }
    }
}

private final class TerminalRuntime {
    let context = RuntimeContext()
    private(set) var config: ghostty_config_t?
    private(set) var app: ghostty_app_t?
    private(set) var view: TerminalView?

    init?() {
        guard let config = velokit_config_new() else { return nil }
        self.config = config
        // Use engine defaults until Velocitty has its own configuration support.
        velokit_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(context).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: RuntimeContext.wakeup,
            action_cb: RuntimeContext.action,
            read_clipboard_cb: RuntimeContext.readClipboard,
            confirm_read_clipboard_cb: RuntimeContext.confirmReadClipboard,
            write_clipboard_cb: RuntimeContext.writeClipboard,
            close_surface_cb: RuntimeContext.closeSurface)

        guard let app = velokit_app_new(&runtimeConfig, config) else {
            velokit_config_free(config)
            self.config = nil
            return nil
        }

        self.app = app
        context.app = app
        velokit_app_set_focus(app, true)
    }

    func createView() -> TerminalView? {
        guard let app else { return nil }
        let terminalView = TerminalView(app: app)
        view = terminalView
        return terminalView
    }

    deinit {
        if let view, let surface = view.surface {
            view.surface = nil
            velokit_surface_free(surface)
        }
        if let app {
            velokit_app_free(app)
        }
        if let config {
            velokit_config_free(config)
        }
    }
}

private final class TerminalView: NSView, NSTextInputClient {
    var surface: ghostty_surface_t?
    private var markedText = NSAttributedString()

    override var acceptsFirstResponder: Bool { true }

    init?(app: ghostty_app_t) {
        super.init(frame: .zero)

        var surfaceConfig = velokit_surface_config_new()
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.userdata = viewPointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: viewPointer))
        surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // Use the development workspace regardless of the launcher's directory.
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspace", isDirectory: true)
        surface = workingDirectory.path.withCString { path in
            surfaceConfig.working_directory = path
            return velokit_surface_new(app, &surfaceConfig)
        }
        if surface == nil {
            NSLog("VeloKit failed to create terminal surface")
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let surface {
            velokit_surface_free(surface)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            velokit_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            velokit_surface_set_focus(surface, false)
        }
        return result
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let backing = convertToBacking(bounds.size)
        let xScale = backing.width / bounds.width
        let yScale = backing.height / bounds.height
        velokit_surface_set_content_scale(surface, xScale, yScale)
        velokit_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    @objc(copy:)
    func copyMenuItem(_ sender: Any?) {
        performSurfaceAction("copy_to_clipboard")
    }

    @objc(paste:)
    func pasteMenuItem(_ sender: Any?) {
        performSurfaceAction("paste_from_clipboard")
    }

    @objc(selectAll:)
    func selectAllMenuItem(_ sender: Any?) {
        performSurfaceAction("select_all")
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = ghosttyMods(event.modifierFlags)
        keyEvent.consumed_mods = ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.unshifted_codepoint = event.characters(byApplyingModifiers: [])?
            .unicodeScalars.first?.value ?? 0
        keyEvent.composing = hasMarkedText()

        let text = action == GHOSTTY_ACTION_RELEASE ? nil : terminalText(for: event)
        if let text {
            text.withCString { pointer in
                keyEvent.text = pointer
                _ = velokit_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = velokit_surface_key(surface, keyEvent)
        }
    }

    private func terminalText(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        guard characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) else {
            return nil
        }
        return characters
    }

    private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }

    private func performSurfaceAction(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { pointer in
            velokit_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { convert(bounds, to: nil) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = value
        case let value as NSString:
            markedText = NSAttributedString(string: value as String)
        default:
            markedText = NSAttributedString()
        }

        guard let surface else { return }
        let text = markedText.string
        text.withCString { pointer in
            velokit_surface_preedit(surface, pointer, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        markedText = NSAttributedString()
        if let surface {
            velokit_surface_preedit(surface, "", 0)
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as NSString: text = value as String
        default: return
        }

        unmarkText()
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s(
            action: GHOSTTY_ACTION_PRESS,
            mods: GHOSTTY_MODS_NONE,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: 0,
            text: nil,
            unshifted_codepoint: 0,
            composing: false)
        text.withCString { pointer in
            keyEvent.text = pointer
            _ = velokit_surface_key(surface, keyEvent)
        }
    }

    override func doCommand(by selector: Selector) {}
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var runtime: TerminalRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled artwork directly so the running Dock tile doesn't
        // depend on Launch Services resolving an icon for a development build.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        installMainMenu()

        guard let runtime = TerminalRuntime(),
              let terminalView = runtime.createView()
        else {
            NSLog("VeloKit failed to initialize")
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

    private func installMainMenu() {
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

guard velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    NSLog("libghostty initialization failed")
    exit(1)
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
