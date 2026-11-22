// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit

struct TerminalTextSnapshot {
  var text = ""
  var rects: [NSRect] = []
  var selectedText: String?
  var selection = NSRange(location: NSNotFound, length: 0)
  var cursor = NSNotFound
  static func read(_ surface: ghostty_surface_t) -> Self {
    var value = velokit_accessibility_s()
    guard velokit_surface_read_accessibility(surface, &value) else { return Self() }
    defer { velokit_free_accessibility(&value) }
    func string(_ pointer: UnsafePointer<CChar>?, _ count: Int) -> String {
      guard let pointer else { return "" }
      return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(count)), as: UTF8.self)
    }
    let text = string(value.text, value.text_len)
    let utf8 = text.utf8
    func offset(_ byte: Int) -> Int? {
      guard byte >= 0, byte <= utf8.count,
        let index = utf8.index(utf8.startIndex, offsetBy: byte, limitedBy: utf8.endIndex),
        let utf16Index = index.samePosition(in: text.utf16) else { return nil }
      return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }
    var snapshot = Self(text: text)
    if let rects = value.rects {
      snapshot.rects.reserveCapacity(text.utf16.count)
      var byte = 0
      for scalar in text.unicodeScalars {
        let cell = rects[byte]
        let rect = NSRect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)
        snapshot.rects.append(contentsOf: repeatElement(rect, count: scalar.utf16.count))
        byte += scalar.utf8.count
      }
    }
    if value.selected_text != nil { snapshot.selectedText = string(value.selected_text, value.selected_text_len) }
    if let start = offset(value.selection_start), let end = offset(value.selection_end), end >= start {
      snapshot.selection = NSRange(location: start, length: end - start)
    }
    snapshot.cursor = offset(value.cursor) ?? NSNotFound
    return snapshot
  }
}

extension TerminalView {
  // Cache briefly, like upstream, to avoid formatting the screen for every AX query.
  func accessibilitySnapshot() -> TerminalTextSnapshot {
    guard let surface else { return TerminalTextSnapshot() }
    if accessibilityTimer == nil {
      // Observe output only after an accessibility client has requested this terminal.
      let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
        self?.refreshAccessibilityText()
      }
      accessibilityTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
    // Output does not always signal a render, so a stale snapshot is re-read even when not marked dirty.
    if accessibilityDirty || ProcessInfo.processInfo.systemUptime - accessibilityReadAt > 0.5 {
      accessibilityText = TerminalTextSnapshot.read(surface)
      accessibilityReadAt = ProcessInfo.processInfo.systemUptime
      accessibilityDirty = false
    }
    return accessibilityText
  }
  func refreshAccessibilityText() {
    guard let surface else { stopAccessibility(); return }
    // A hidden terminal is refreshed on its next direct query or when it becomes visible.
    guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return }
    let previous = accessibilityText
    accessibilityText = TerminalTextSnapshot.read(surface)
    accessibilityReadAt = ProcessInfo.processInfo.systemUptime
    accessibilityDirty = false
    if previous.text != accessibilityText.text { postAccessibility(self, .valueChanged) }
    if previous.selection != accessibilityText.selection || previous.cursor != accessibilityText.cursor {
      postAccessibility(self, .selectedTextChanged)
    }
  }
  func invalidateAccessibilityText() {
    accessibilityDirty = true
    accessibilityReadAt = -.infinity
  }
  func accessibilitySelectionChanged() {
    invalidateAccessibilityText()
    accessibilitySelectionWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.surface != nil else { return }
      self.postAccessibility(self, .selectedTextChanged)
      self.accessibilitySelectionWork = nil
    }
    accessibilitySelectionWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
  }
  func stopAccessibility() {
    accessibilityTimer?.invalidate()
    accessibilityTimer = nil
    accessibilitySelectionWork?.cancel()
    accessibilitySelectionWork = nil
    accessibilityText = TerminalTextSnapshot()
    invalidateAccessibilityText()
  }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  // Tab, space and pane changes alter the label; tell assistive technology only when it did.
  func announceAccessibilityLabelChange() {
    let label = accessibilityLabel()
    guard label != announcedAccessibilityLabel else { return }
    let first = announcedAccessibilityLabel == nil
    announcedAccessibilityLabel = label
    // Only the focused pane speaks; the others pick the new label up when focused.
    if !first, window?.firstResponder === self { postAccessibility(self, .titleChanged) }
  }
  override func accessibilityLabel() -> String? {
    guard let session, let controller = session.windowController,
      let tab = controller.tab(for: session) else { return session?.displayTitle ?? "Terminal" }
    let namespace = controller.namespace(for: session)?.name ?? "Workspace"
    let pane = (tab.panes.firstIndex(where: { $0 === session }) ?? 0) + 1
    let connection = session.herdrTerminal?.client.endpointLabel ?? "Standalone"
    let position = tab.panes.count > 1 ? ", pane \(pane) of \(tab.panes.count)" : ""
    // The program-set title changes constantly, so only the user's tab title is spoken.
    let title = tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Terminal"
    return "\(title)\(position), \(namespace), \(connection)"
  }
  override func accessibilityHelp() -> String? { "Terminal input and output" }
  override func accessibilityValue() -> Any? { accessibilitySnapshot().text }
  override func accessibilitySelectedText() -> String? { accessibilitySnapshot().selectedText }
  override func accessibilitySelectedTextRange() -> NSRange {
    let snapshot = accessibilitySnapshot()
    if snapshot.selection.location != NSNotFound { return snapshot.selection }
    return NSRange(location: snapshot.cursor, length: 0)
  }
  override func accessibilityNumberOfCharacters() -> Int { accessibilitySnapshot().text.utf16.count }
  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessibilityNumberOfCharacters())
  }
  override func accessibilityString(for range: NSRange) -> String? {
    let text = accessibilitySnapshot().text
    guard let range = Range(range, in: text) else { return nil }
    return String(text[range])
  }
  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    accessibilityString(for: range).map { NSAttributedString(string: $0) }
  }
  override func accessibilityLine(for index: Int) -> Int {
    let text = accessibilitySnapshot().text as NSString
    guard index >= 0, index <= text.length else { return NSNotFound }
    var line = 0
    var start = 0
    while start < text.length {
      let range = text.lineRange(for: NSRange(location: start, length: 0))
      if index < NSMaxRange(range) || (index == text.length &&
        !(text as String).last.map { $0.isNewline }!) { return line }
      start = NSMaxRange(range)
      line += 1
    }
    return line
  }
  override func accessibilityRange(forLine line: Int) -> NSRange {
    guard line >= 0 else { return NSRange(location: NSNotFound, length: 0) }
    let text = accessibilitySnapshot().text as NSString
    var current = 0
    var start = 0
    while start < text.length {
      let range = text.lineRange(for: NSRange(location: start, length: 0))
      if current == line { return range }
      start = NSMaxRange(range)
      current += 1
    }
    return current == line && (text.length == 0 || (text as String).last?.isNewline == true)
      ? NSRange(location: start, length: 0)
      : NSRange(location: NSNotFound, length: 0)
  }
  override func accessibilityFrame(for range: NSRange) -> NSRect {
    let snapshot = accessibilitySnapshot()
    guard let window, range.location >= 0, range.location <= snapshot.rects.count,
      range.length >= 0, range.length <= snapshot.rects.count - range.location else { return .zero }
    let rect: NSRect
    if range.length == 0 {
      guard range.location < snapshot.rects.count else { return .zero }
      let cell = snapshot.rects[range.location]
      rect = NSRect(x: cell.minX, y: cell.minY, width: 1, height: cell.height)
    } else {
      rect = snapshot.rects[range.location..<NSMaxRange(range)].filter { !$0.isEmpty }
        .reduce(NSRect.null) { $0.union($1) }
    }
    guard !rect.isNull, rect.height > 0 else { return .zero }
    return window.convertToScreen(convert(NSRect(x: rect.minX, y: bounds.height - rect.maxY,
      width: rect.width, height: rect.height), to: nil))
  }
}
