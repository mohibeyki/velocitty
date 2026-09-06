// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class TerminalView: NSView, NSTextInputClient {
    var surface: ghostty_surface_t?
    var markedText = NSAttributedString()
    var tracking: NSTrackingArea?
    var keyInProgress: NSEvent?
    var keyHandled = false
    var linkURL: String?
    var pointer: NSCursor = .iBeam
    var config: ghostty_config_t?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { pointer.set() }
    func mousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        velokit_surface_mouse_pos(surface, point.x, bounds.height - point.y, Int32(ghosttyMods(event.modifierFlags).rawValue))
    }
    override func mouseMoved(with event: NSEvent) { mousePosition(event) }
    override func mouseEntered(with event: NSEvent) { mousePosition(event); pointer.set() }
    override func mouseExited(with event: NSEvent) {
        if let surface { velokit_surface_mouse_pos(surface, -1, -1, 0) }
        toolTip = nil
        NSCursor.arrow.set()
    }
    func mouseButton(_ event: NSEvent, down: Bool) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        mousePosition(event)
        let button = event.buttonNumber == 0 ? 1 : event.buttonNumber == 1 ? 2 : event.buttonNumber == 2 ? 3 : event.buttonNumber + 1
        _ = velokit_surface_mouse_button(surface, down ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
            ghostty_input_mouse_button_e(rawValue: UInt32(button)), Int32(ghosttyMods(event.modifierFlags).rawValue))
    }
    override func mouseDown(with event: NSEvent) { mouseButton(event, down: true) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, down: false) }
    override func rightMouseDown(with event: NSEvent) {
        mouseButton(event, down: true)
        if let surface, !velokit_surface_mouse_captured(surface), settingString("right-click-action") == "context-menu" {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copyMenuItem(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Paste", action: #selector(pasteMenuItem(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Select All", action: #selector(selectAllMenuItem(_:)), keyEquivalent: "").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, down: false) }
    override func mouseDragged(with event: NSEvent) { mousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { mousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { mousePosition(event) }
    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        mousePosition(event)
        let phase: Int32 = event.momentumPhase.contains(.began) ? 1 : event.momentumPhase.contains(.changed) ? 3 : event.momentumPhase.contains(.ended) ? 4 : event.momentumPhase.contains(.cancelled) ? 5 : 0
        let scale = event.hasPreciseScrollingDeltas ? (window?.backingScaleFactor ?? 1) : 1
        velokit_surface_mouse_scroll(surface, event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, (event.hasPreciseScrollingDeltas ? 1 : 0) | (phase << 1))
    }
    override func pressureChange(with event: NSEvent) {
        if let surface { velokit_surface_mouse_pressure(surface, UInt32(max(0, min(2, event.stage))), Double(event.pressure)) }
    }
    override func flagsChanged(with event: NSEvent) {
        mousePosition(event)
        let mask: NSEvent.ModifierFlags
        switch event.keyCode { case 56,60: mask = .shift; case 59,62: mask = .control; case 58,61: mask = .option; case 55,54: mask = .command; default: return }
        sendKey(event, action: event.modifierFlags.contains(mask) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
    }
    func settingString(_ key: String) -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<CChar>?
        guard key.withCString({ velokit_config_get(config, &value, $0, UInt(key.utf8.count)) }) else { return nil }
        return value.map { String(cString: $0) }
    }


    override var acceptsFirstResponder: Bool { true }

    init?(app: ghostty_app_t, workingDirectory: URL) {
        super.init(frame: .zero)

        var surfaceConfig = velokit_surface_config_new()
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.userdata = viewPointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: viewPointer))
        surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

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

    func updateSurfaceSize() {
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let surface else { return false }
        return withKey(event, action: GHOSTTY_ACTION_PRESS) { key in
            guard velokit_surface_key_is_binding(surface, key, nil) else { return false }
            return velokit_surface_key(surface, key)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        if withKey(event, action: GHOSTTY_ACTION_PRESS, { key in
            velokit_surface_key_is_binding(surface, key, nil) && velokit_surface_key(surface, key)
        }) { return }
        let translated = velokit_surface_key_translation_mods(surface, Int32(ghosttyMods(event.modifierFlags).rawValue))
        if event.modifierFlags.contains(.option), translated & Int32(GHOSTTY_MODS_ALT.rawValue) == 0 {
            sendKey(event, action: GHOSTTY_ACTION_PRESS)
            return
        }
        keyInProgress = event
        keyHandled = false
        interpretKeyEvents([event])
        if !keyHandled && !hasMarkedText() { sendKey(event, action: GHOSTTY_ACTION_PRESS) }
        keyInProgress = nil
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        _ = withKey(event, action: action) { velokit_surface_key(surface, $0) }
    }

    func withKey(_ event: NSEvent, action: ghostty_input_action_e, overrideText: String? = nil, _ body: (ghostty_input_key_s) -> Bool) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = event.isARepeat && action == GHOSTTY_ACTION_PRESS ? GHOSTTY_ACTION_REPEAT : action
        key.mods = ghosttyMods(event.modifierFlags)
        let translated = velokit_surface_key_translation_mods(surface, Int32(key.mods.rawValue))
        var flags = event.modifierFlags.subtracting([.control, .command])
        if translated & Int32(GHOSTTY_MODS_ALT.rawValue) == 0 { flags.remove(.option) }
        key.consumed_mods = ghosttyMods(flags)
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        key.composing = hasMarkedText()
        let characters = overrideText ?? event.characters(byApplyingModifiers: flags)
        if action != GHOSTTY_ACTION_RELEASE, let text = characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) {
            return text.withCString { key.text = $0; return body(key) }
        }
        return body(key)
    }

    func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.rawValue & 0x40 != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if flags.rawValue & 0x4 != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if flags.rawValue & 0x2000 != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if flags.rawValue & 0x10 != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(raw)
    }

    func performSurfaceAction(_ action: String) {
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
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        velokit_surface_ime_point(surface, &x, &y, &width, &height)
        return window.convertToScreen(convert(NSRect(x: x, y: bounds.height - y - height, width: width, height: height), to: nil))
    }

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
        keyHandled = true
        guard let surface else { return }
        if let event = keyInProgress {
            _ = withKey(event, action: GHOSTTY_ACTION_PRESS, overrideText: text) { velokit_surface_key(surface, $0) }
            return
        }
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

    override func doCommand(by selector: Selector) {
        if let event = keyInProgress { keyHandled = true; sendKey(event, action: GHOSTTY_ACTION_PRESS) }
    }
}


// Search and scrolling are native controls; the engine owns matches and viewport state.
final class TerminalChrome: NSView, NSSearchFieldDelegate {
    let terminal: TerminalView
    let search = NSSearchField()
    let count = NSTextField(labelWithString: "")
    let previous = NSButton(title: "↑", target: nil, action: nil)
    let next = NSButton(title: "↓", target: nil, action: nil)
    let close = NSButton(title: "Done", target: nil, action: nil)
    let scroller = NSScroller()
    var scrollState = ghostty_action_scrollbar_s(total: 0, offset: 0, len: 0)
    var total = 0
    var selected = -1
    var searching = false
    var showScroll = false

    init(_ terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        addSubview(terminal)
        for view in [search, count, previous, next, close, scroller] { addSubview(view) }
        search.placeholderString = "Find in terminal"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(updateSearch)
        previous.target = self; previous.action = #selector(previousMatch)
        next.target = self; next.action = #selector(nextMatch)
        close.target = self; close.action = #selector(endSearch)
        scroller.target = self; scroller.action = #selector(scrollViewport)
        scroller.scrollerStyle = NSScroller.preferredScrollerStyle
        scroller.controlSize = .small
        scroller.isContinuous = true
        refreshVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let height: CGFloat = searching ? 38 : 0
        let width: CGFloat = showScroll ? 14 : 0
        terminal.frame = NSRect(x: 0, y: 0, width: bounds.width - width, height: bounds.height - height)
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height - height)
        search.frame = NSRect(x: 8, y: bounds.height - 31, width: max(80, bounds.width - 270), height: 24)
        count.frame = NSRect(x: bounds.width - 250, y: bounds.height - 28, width: 115, height: 20)
        previous.frame = NSRect(x: bounds.width - 135, y: bounds.height - 32, width: 32, height: 26)
        next.frame = NSRect(x: bounds.width - 101, y: bounds.height - 32, width: 32, height: 26)
        close.frame = NSRect(x: bounds.width - 67, y: bounds.height - 32, width: 60, height: 26)
    }
    func refreshVisibility() {
        for view in [search, count, previous, next, close] { view.isHidden = !searching }
        let policy = NativeSettings(config: terminal.config).string("scrollbar", "system")
        showScroll = policy != "never" && (policy == "always" || scrollState.total > scrollState.len)
        scroller.isHidden = !showScroll
        needsLayout = true
    }
    func startSearch(_ needle: String?) {
        searching = true
        if let needle { search.stringValue = needle }
        refreshVisibility()
        window?.makeFirstResponder(search)
    }
    func updateCount() { count.stringValue = total == 0 ? "No matches" : "\(selected < 0 ? 0 : selected + 1) of \(total)" }
    @objc func updateSearch() { terminal.performSurfaceAction("search:" + search.stringValue) }
    @objc func previousMatch() { terminal.performSurfaceAction("navigate_search:previous") }
    @objc func nextMatch() { terminal.performSurfaceAction("navigate_search:next") }
    @objc func endSearch() { terminal.performSurfaceAction("end_search"); hideSearch() }
    func hideSearch() { searching = false; refreshVisibility(); window?.makeFirstResponder(terminal) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endSearch(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previousMatch() } else { nextMatch() }
            return true
        }
        return false
    }
    func updateScrollbar(_ value: ghostty_action_scrollbar_s) {
        scrollState = value
        scroller.knobProportion = value.total == 0 ? 1 : Double(value.len) / Double(value.total)
        scroller.doubleValue = value.total <= value.len ? 1 : Double(value.offset) / Double(value.total - value.len)
        refreshVisibility()
    }
    @objc func scrollViewport() {
        let limit = scrollState.total > scrollState.len ? scrollState.total - scrollState.len : 0
        var row = Double(scrollState.offset)
        switch scroller.hitPart {
        case .decrementLine: row -= 1
        case .incrementLine: row += 1
        case .decrementPage: row -= Double(scrollState.len)
        case .incrementPage: row += Double(scrollState.len)
        default: row = scroller.doubleValue * Double(limit)
        }
        terminal.performSurfaceAction("scroll_to_row:\(UInt64(max(0, min(Double(limit), row))))")
    }
}
