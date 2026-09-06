// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

// Search and scrolling are native controls; the engine owns matches and viewport state.
final class TerminalChrome: NSView, NSSearchFieldDelegate {
  let terminal: TerminalView
  let search = NSSearchField()
  let dragHandle = TerminalDragHandle()
  let resizeLabel = NSTextField(labelWithString: "")
  let secure = NSTextField(labelWithString: "")
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
  var fadeTimer: Timer?

  init(_ terminal: TerminalView) {
    self.terminal = terminal
    super.init(frame: terminal.frame)
    addSubview(terminal)
    for view in [search, count, previous, next, close, scroller, secure, resizeLabel, dragHandle] {
      addSubview(view)
    }
    resizeLabel.isHidden = true
    resizeLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
    resizeLabel.alignment = .center
    resizeLabel.drawsBackground = true
    resizeLabel.backgroundColor = .windowBackgroundColor
    secure.font = .systemFont(ofSize: 11)
    secure.textColor = .secondaryLabelColor
    search.placeholderString = "Find in terminal"
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.target = self
    search.action = #selector(updateSearch)
    previous.target = self
    previous.action = #selector(previousMatch)
    next.target = self
    next.action = #selector(nextMatch)
    close.target = self
    close.action = #selector(endSearch)
    scroller.target = self
    scroller.action = #selector(scrollViewport)
    scroller.scrollerStyle = NSScroller.preferredScrollerStyle
    scroller.controlSize = .small
    scroller.isContinuous = true
    refreshVisibility()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    let policy = NativeSettings(config: terminal.config).string("drag-handle", "auto")
    let dragging =
      policy == "always" || (policy == "auto" && window?.styleMask.contains(.titled) == false)
    dragHandle.isHidden = !dragging
    dragHandle.frame = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)
    let height: CGFloat = (searching ? 38 : 0) + (dragging ? 12 : 0)
    let width: CGFloat = showScroll && scroller.scrollerStyle == .legacy ? 14 : 0
    let searchTop = bounds.height - (dragging ? 12 : 0)
    let position = NativeSettings(config: terminal.config).string(
      "resize-overlay-position", "center")
    let overlayX: CGFloat =
      position.hasSuffix("left")
      ? 12 : position.hasSuffix("right") ? bounds.width - 152 : (bounds.width - 140) / 2
    let overlayY: CGFloat =
      position.hasPrefix("top")
      ? bounds.height - height - 44
      : position.hasPrefix("bottom") ? 12 : (bounds.height - height - 32) / 2
    resizeLabel.frame = NSRect(x: overlayX, y: overlayY, width: 140, height: 32)
    secure.frame = NSRect(x: max(8, bounds.width - 210), y: 5, width: 205, height: 18)
    terminal.frame = NSRect(x: 0, y: 0, width: bounds.width - width, height: bounds.height - height)
    scroller.frame = NSRect(
      x: bounds.width - 14, y: 0, width: 14, height: bounds.height - height)
    search.frame = NSRect(
      x: 8, y: searchTop - 31, width: max(80, bounds.width - 270), height: 24)
    count.frame = NSRect(x: bounds.width - 250, y: searchTop - 28, width: 115, height: 20)
    previous.frame = NSRect(x: bounds.width - 135, y: searchTop - 32, width: 32, height: 26)
    next.frame = NSRect(x: bounds.width - 101, y: searchTop - 32, width: 32, height: 26)
    close.frame = NSRect(x: bounds.width - 67, y: searchTop - 32, width: 60, height: 26)
  }
  func refreshVisibility() {
    for view in [search, count, previous, next, close] { view.isHidden = !searching }
    let policy = NativeSettings(config: terminal.config).string("scrollbar", "system")
    scroller.scrollerStyle = NSScroller.preferredScrollerStyle
    showScroll = policy != "never" && (policy == "always" || scrollState.total > scrollState.len)
    scroller.isHidden = !showScroll
    if scroller.scrollerStyle == .legacy { scroller.alphaValue = 1 }
    needsLayout = true
  }
  func startSearch(_ needle: String?) {
    searching = true
    if let needle, !needle.isEmpty { search.stringValue = needle }
    refreshVisibility()
    updateSearch()
    window?.makeFirstResponder(search)
    search.selectText(nil)
  }
  func updateCount() {
    count.stringValue =
      search.stringValue.isEmpty
      ? ""
      : total < 0
        ? "Searching…"
        : total == 0 ? "No matches" : "\(selected < 0 ? 0 : selected + 1) of \(total)"
  }
  @objc func updateSearch() {
    total = search.stringValue.isEmpty ? 0 : -1
    selected = -1
    updateCount()
    terminal.performSurfaceAction("search:" + search.stringValue)
  }
  @objc func previousMatch() { terminal.performSurfaceAction("navigate_search:previous") }
  @objc func nextMatch() { terminal.performSurfaceAction("navigate_search:next") }
  @objc func endSearch() {
    terminal.performSurfaceAction("end_search")
    hideSearch()
  }
  func hideSearch() {
    searching = false
    refreshVisibility()
    window?.makeFirstResponder(terminal)
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      endSearch()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        previousMatch()
      } else {
        nextMatch()
      }
      return true
    }
    return false
  }
  func updateScrollbar(_ value: ghostty_action_scrollbar_s) {
    scrollState = value
    scroller.knobProportion = value.total == 0 ? 1 : Double(value.len) / Double(value.total)
    scroller.doubleValue =
      value.total <= value.len ? 1 : Double(value.offset) / Double(value.total - value.len)
    refreshVisibility()
    revealScroller()
  }
  func revealScroller() {
    guard showScroll else { return }
    scroller.alphaValue = 1
    fadeTimer?.invalidate()
    if scroller.scrollerStyle == .overlay {
      fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
        self?.scroller.animator().alphaValue = 0
      }
    }
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

final class TerminalDragHandle: NSView {
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: (bounds.width - 34) / 2, y: 4, width: 34, height: 3), xRadius: 1.5,
      yRadius: 1.5
    ).fill()
  }
}
