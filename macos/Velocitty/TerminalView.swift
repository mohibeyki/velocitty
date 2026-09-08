// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class TerminalView: NSView, NSTextInputClient {
  var accessibilityText = TerminalTextSnapshot()
  var accessibilityReadAt = -Double.infinity
  var accessibilityTimer: Timer?
  var accessibilitySelectionWork: DispatchWorkItem?
  var postAccessibility: (TerminalView, NSAccessibility.Notification) -> Void = {
    NSAccessibility.post(element: $0, notification: $1)
  }
  lazy var clipboard = TerminalClipboard(view: self)
  weak var session: TerminalSession?
  var surface: ghostty_surface_t? { session?.surface }
  var initialSize: NSSize?
  var markedText = NSAttributedString()
  var tracking: NSTrackingArea?
  var keyInProgress: NSEvent?
  var keyHandled = false
  private var composingBeforeKey = false
  private(set) var terminalFocused = false
  var linkURL: String?
  var pointer: NSCursor = .iBeam
  var config: ghostty_config_t? { surface == nil ? nil : session?.config }

  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [
        .activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
      ], owner: self)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }

  var pointerIsInside: Bool {
    guard let window, window.isKeyWindow else { return false }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return visibleRect.contains(point)
  }

  override func cursorUpdate(with event: NSEvent) { pointer.set() }
  func mousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    velokit_surface_mouse_pos(
      surface, point.x, bounds.height - point.y, Int32(ghosttyMods(event.modifierFlags).rawValue))
  }
  override func mouseMoved(with event: NSEvent) {
    mousePosition(event)
    (superview as? TerminalChrome)?.revealScroller()
  }
  override func mouseEntered(with event: NSEvent) {
    if NativeSettings(config: config).focusFollowsMouse, window?.attachedSheet == nil, let session {
      session.windowController?.selectTab(session)
    }
    mousePosition(event)
    pointer.set()
  }
  override func mouseExited(with event: NSEvent) {
    if let surface { velokit_surface_mouse_pos(surface, -1, -1, 0) }
    toolTip = nil
    NSCursor.arrow.set()
  }
  func mouseButton(_ event: NSEvent, down: Bool) {
    guard let surface else { return }
    window?.makeFirstResponder(self)
    mousePosition(event)
    let button =
      event.buttonNumber == 0
      ? 1 : event.buttonNumber == 1 ? 2 : event.buttonNumber == 2 ? 3 : event.buttonNumber + 1
    defer { invalidateAccessibilityText() }
    _ = velokit_surface_mouse_button(
      surface, down ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
      ghostty_input_mouse_button_e(rawValue: UInt32(button)),
      Int32(ghosttyMods(event.modifierFlags).rawValue))
  }
  override func mouseDown(with event: NSEvent) {
    if let session { session.windowController?.selectTab(session) }
    mouseButton(event, down: true)
  }
  override func mouseUp(with event: NSEvent) { mouseButton(event, down: false) }
  override func rightMouseDown(with event: NSEvent) {
    mouseButton(event, down: true)
    if let surface, !velokit_surface_mouse_captured(surface),
      NativeSettings(config: config).rightClickAction == "context-menu"
    {
      let menu = NSMenu()
      menu.addItem(withTitle: "Copy", action: #selector(copyMenuItem(_:)), keyEquivalent: "")
        .target = self
      menu.addItem(withTitle: "Paste", action: #selector(pasteMenuItem(_:)), keyEquivalent: "")
        .target = self
      menu.addItem(
        withTitle: "Select All", action: #selector(selectAllMenuItem(_:)), keyEquivalent: ""
      ).target = self
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
    let phase: Int32 =
      event.momentumPhase.contains(.began)
      ? 1
      : event.momentumPhase.contains(.changed)
        ? 3
        : event.momentumPhase.contains(.ended)
          ? 4 : event.momentumPhase.contains(.cancelled) ? 5 : 0
    let scale = event.hasPreciseScrollingDeltas ? (window?.backingScaleFactor ?? 1) : 1
    velokit_surface_mouse_scroll(
      surface, event.scrollingDeltaX * scale, event.scrollingDeltaY * scale,
      (event.hasPreciseScrollingDeltas ? 1 : 0) | (phase << 1))
  }
  override func pressureChange(with event: NSEvent) {
    if let surface {
      velokit_surface_mouse_pressure(
        surface, UInt32(max(0, min(2, event.stage))), Double(event.pressure))
    }
  }
  override func flagsChanged(with event: NSEvent) {
    mousePosition(event)
    let mask: NSEvent.ModifierFlags
    switch event.keyCode {
    case 56, 60: mask = .shift
    case 59, 62: mask = .control
    case 58, 61: mask = .option
    case 55, 54: mask = .command
    default: return
    }
    sendKey(
      event,
      action: event.modifierFlags.contains(mask) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
  }
  override var acceptsFirstResponder: Bool { true }

  init(session: TerminalSession) {
    self.session = session
    super.init(frame: .zero)
    registerForDraggedTypes([.fileURL, .string])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { updateFocus(firstResponder: true) }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { inputContext?.discardMarkedText(); unmarkText(); updateFocus(firstResponder: false) }
    return result
  }

  // AppKit updates firstResponder after its responder callbacks return. Use the
  // accepted transition there, and the window's actual responder everywhere else.
  func updateFocus(firstResponder: Bool? = nil, forceOff: Bool = false) {
    guard let surface else { return }
    let focused = !forceOff && NSApp.isActive && window?.isKeyWindow == true
      && window?.attachedSheet == nil && (firstResponder ?? (window?.firstResponder === self))
    if focused && !terminalFocused { session?.windowController?.clearBell() }
    terminalFocused = focused
    session?.windowController?.updateSecureInput(forceOff: forceOff)
    velokit_surface_set_focus(surface, focused)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateFocus()
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
    guard !hasMarkedText(), window?.firstResponder === self, let surface else { return false }
    return withKey(event, action: GHOSTTY_ACTION_PRESS) { key in
      var flags = ghostty_binding_flags_e(rawValue: 0)
      guard velokit_surface_key_is_binding(surface, key, &flags),
        flags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0
      else { return false }
      return velokit_surface_key(surface, key)
    }
  }

  override func keyDown(with event: NSEvent) {
    session?.windowController?.clearBell()
    invalidateAccessibilityText()
    guard let surface else { return }
    if !hasMarkedText() && withKey(
      event, action: GHOSTTY_ACTION_PRESS,
      { key in
        guard velokit_surface_key_is_binding(surface, key, nil) else { return false }
        _ = velokit_surface_key(surface, key)
        return true
      })
    {
      return
    }
    let translated = velokit_surface_key_translation_mods(
      surface, Int32(ghosttyMods(event.modifierFlags).rawValue))
    if !hasMarkedText(), event.modifierFlags.contains(.option), translated & Int32(GHOSTTY_MODS_ALT.rawValue) == 0 {
      sendKey(event, action: GHOSTTY_ACTION_PRESS)
      return
    }
    composingBeforeKey = hasMarkedText()
    keyInProgress = event
    keyHandled = false
    interpretKeyEvents([event])
    if !keyHandled && !hasMarkedText() && !composingBeforeKey { sendKey(event, action: GHOSTTY_ACTION_PRESS) }
    keyInProgress = nil
    composingBeforeKey = false
  }

  override func keyUp(with event: NSEvent) {
    sendKey(event, action: GHOSTTY_ACTION_RELEASE)
  }

  func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
    guard let surface else { return }
    _ = withKey(event, action: action) { velokit_surface_key(surface, $0) }
  }

  func withKey(
    _ event: NSEvent, action: ghostty_input_action_e, overrideText: String? = nil,
    _ body: (ghostty_input_key_s) -> Bool
  ) -> Bool {
    guard let surface else { return false }
    var key = ghostty_input_key_s()
    key.action = event.isARepeat && action == GHOSTTY_ACTION_PRESS ? GHOSTTY_ACTION_REPEAT : action
    key.mods = ghosttyMods(event.modifierFlags)
    let translated = velokit_surface_key_translation_mods(surface, Int32(key.mods.rawValue))
    var flags = event.modifierFlags.subtracting([.control, .command])
    if translated & Int32(GHOSTTY_MODS_ALT.rawValue) == 0 { flags.remove(.option) }
    key.consumed_mods = ghosttyMods(flags)
    key.keycode = UInt32(event.keyCode)
    key.unshifted_codepoint =
      event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    key.composing = hasMarkedText()
    let characters = overrideText ?? event.characters(byApplyingModifiers: flags)
    if action != GHOSTTY_ACTION_RELEASE, let text = characters, !text.isEmpty,
      text.unicodeScalars.allSatisfy({
        $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value)
      })
    {
      return text.withCString {
        key.text = $0
        return body(key)
      }
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
    hasMarkedText()
      ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange { NSRange(location: hasMarkedText() ? markedText.length : NSNotFound, length: 0) }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface, let window else { return .zero }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    velokit_surface_ime_point(surface, &x, &y, &width, &height)
    return window.convertToScreen(
      convert(NSRect(x: x, y: bounds.height - y - height, width: width, height: height), to: nil))
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

    let composed = composingBeforeKey || hasMarkedText()
    unmarkText()
    keyHandled = true
    guard let surface, !text.isEmpty else { return }
    if let event = keyInProgress, !composed {
      _ = withKey(event, action: GHOSTTY_ACTION_PRESS, overrideText: text) {
        velokit_surface_key(surface, $0)
      }
      return
    }
    // Like Ghostty, committed IME text is typed input with no committing
    // Return/Space key or modifiers, never a bracketed paste.
    guard !composed || text.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return }
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    text.withCString { key.text = $0; _ = velokit_surface_key(surface, key) }
  }

  override func doCommand(by selector: Selector) {
    if let event = keyInProgress, !keyHandled, !composingBeforeKey, !hasMarkedText() {
      keyHandled = true
      sendKey(event, action: GHOSTTY_ACTION_PRESS)
    }
  }
}

// MARK: Drag and drop
extension TerminalView {
  static func droppedText(from pasteboard: NSPasteboard) -> String? {
    let strings = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
      if let value = item.propertyList(forType: .fileURL),
        let url = NSURL(pasteboardPropertyList: value, ofType: .fileURL) as URL?, url.isFileURL {
        // ShellInput appends a separator; join pasteboard items ourselves here.
        return String(ShellInput.paths([url.path]).dropLast())
      }
      return item.string(forType: .string)
    }
    return strings.isEmpty ? nil : strings.joined(separator: " ")
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard surface != nil, session?.readonly != true,
      Self.droppedText(from: sender.draggingPasteboard) != nil else { return [] }
    return .copy
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    insertDrop(from: sender.draggingPasteboard)
  }
  @discardableResult
  func insertDrop(from pasteboard: NSPasteboard) -> Bool {
    guard let surface, session?.readonly != true,
      let text = Self.droppedText(from: pasteboard), !text.contains("\0") else { return false }
    window?.makeFirstResponder(self)
    return text.withCString { velokit_surface_paste(surface, $0, UInt(text.utf8.count)) }
  }
}
