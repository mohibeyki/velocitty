// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

// Search and scrolling are native controls; the engine owns matches and viewport state.
final class TerminalChrome: NSView, NSSearchFieldDelegate {
  static let sidebarWidth: CGFloat = 180
  let namespaceScroll = NSScrollView()
  let namespaceList = NamespaceListView()
  let addNamespace = NSButton(title: "+", target: nil, action: nil)
  let editNamespace = NSButton(title: "Edit…", target: nil, action: nil)
  let closeNamespace = NSButton(title: "×", target: nil, action: nil)
  let progress = TerminalProgress()
  let tabScroll = NSScrollView()
  let tabButtons = NSStackView()
  let addTab = NSButton(title: "+", target: nil, action: nil)
  let closeTab = NSButton(title: "×", target: nil, action: nil)
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
    for view in [search, count, previous, next, close, scroller, secure, resizeLabel, dragHandle, progress] {
      addSubview(view)
    }
    tabScroll.documentView = tabButtons
    tabScroll.drawsBackground = false
    tabScroll.hasHorizontalScroller = true
    tabScroll.autohidesScrollers = true
    tabButtons.orientation = .horizontal
    tabButtons.spacing = 4
    addSubview(tabScroll)
    addSubview(addTab)
    addSubview(closeTab)
    addTab.target = self
    addTab.action = #selector(createTab)
    addTab.toolTip = "New Tab"
    closeTab.target = self
    closeTab.action = #selector(closeActiveTab)
    closeTab.toolTip = "Close Tab"
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
    namespaceScroll.documentView = namespaceList
    namespaceScroll.hasVerticalScroller = true
    namespaceScroll.autohidesScrollers = true
    namespaceScroll.drawsBackground = false
    addSubview(namespaceScroll)
    for (button, action, tip) in [
      (addNamespace, #selector(createNamespace), "New Namespace"),
      (editNamespace, #selector(editActiveNamespace), "Edit Namespace Name and Subtitle"),
      (closeNamespace, #selector(closeActiveNamespace), "Close Namespace")
    ] {
      button.target = self
      button.action = action
      button.toolTip = tip
      addSubview(button)
    }
    refreshVisibility()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    let contentWidth = max(0, bounds.width - Self.sidebarWidth)
    let policy = NativeSettings(config: terminal.config).dragHandle
    let dragging =
      policy == "always" || (policy == "auto" && window?.styleMask.contains(.titled) == false)
    dragHandle.isHidden = !dragging
    dragHandle.frame = NSRect(x: 0, y: bounds.height - 12, width: contentWidth, height: 12)
    let tabTop = bounds.height - (dragging ? 12 : 0)
    tabScroll.frame = NSRect(x: 4, y: tabTop - 30, width: max(0, contentWidth - 72), height: 30)
    addTab.frame = NSRect(x: contentWidth - 66, y: tabTop - 28, width: 30, height: 26)
    closeTab.frame = NSRect(x: contentWidth - 34, y: tabTop - 28, width: 30, height: 26)
    let height: CGFloat = 30 + (searching ? 38 : 0) + (dragging ? 12 : 0)
    let width: CGFloat = showScroll && scroller.scrollerStyle == .legacy ? 14 : 0
    let searchTop = tabTop - 30
    let position = NativeSettings(config: terminal.config).resizeOverlayPosition
    let overlayX: CGFloat =
      position.hasSuffix("left")
      ? 12 : position.hasSuffix("right") ? contentWidth - 152 : (contentWidth - 140) / 2
    let overlayY: CGFloat =
      position.hasPrefix("top")
      ? bounds.height - height - 44
      : position.hasPrefix("bottom") ? 12 : (bounds.height - height - 32) / 2
    resizeLabel.frame = NSRect(x: overlayX, y: overlayY, width: 140, height: 32)
    secure.frame = NSRect(x: max(8, contentWidth - 210), y: 5, width: 205, height: 18)
    terminal.frame = NSRect(x: 0, y: 0, width: contentWidth - width, height: bounds.height - height)
    progress.frame = NSRect(x: 0, y: terminal.frame.maxY - 2, width: terminal.frame.width, height: 2)
    scroller.frame = NSRect(
      x: contentWidth - 14, y: 0, width: 14, height: bounds.height - height)
    search.frame = NSRect(
      x: 8, y: searchTop - 31, width: max(80, contentWidth - 270), height: 24)
    count.frame = NSRect(x: contentWidth - 250, y: searchTop - 28, width: 115, height: 20)
    previous.frame = NSRect(x: contentWidth - 135, y: searchTop - 32, width: 32, height: 26)
    next.frame = NSRect(x: contentWidth - 101, y: searchTop - 32, width: 32, height: 26)
    close.frame = NSRect(x: contentWidth - 67, y: searchTop - 32, width: 60, height: 26)
    for view in subviews where view !== namespaceScroll && view !== addNamespace
      && view !== editNamespace && view !== closeNamespace {
      view.frame.origin.x += Self.sidebarWidth
    }
    namespaceScroll.frame = NSRect(x: 0, y: 34, width: Self.sidebarWidth, height: max(0, bounds.height - 34))
    addNamespace.frame = NSRect(x: 4, y: 4, width: 30, height: 26)
    editNamespace.frame = NSRect(x: 38, y: 4, width: 100, height: 26)
    closeNamespace.frame = NSRect(x: 142, y: 4, width: 30, height: 26)
  }
  func refreshTabs() {
    for view in tabButtons.arrangedSubviews { tabButtons.removeArrangedSubview(view); view.removeFromSuperview() }
    guard let controller = terminal.session?.windowController else { return }
    refreshNamespaces(controller)
    var contentWidth: CGFloat = 0
    for (index, tab) in controller.tabs.enumerated() {
      let button = NSButton(title: (tab.hasBell ? "● " : "") + tab.displayTitle, target: self, action: #selector(activateTab(_:)))
      button.tag = index
      button.setButtonType(.pushOnPushOff)
      button.bezelStyle = .rounded
      button.state = controller.session === tab ? .on : .off
      button.lineBreakMode = .byTruncatingTail
      button.toolTip = tab.displayTitle
      let width = min(180, max(90, button.intrinsicContentSize.width))
      contentWidth += width + (index == 0 ? 0 : 4)
      button.widthAnchor.constraint(equalToConstant: width).isActive = true
      tabButtons.addArrangedSubview(button)
    }
    tabButtons.frame = NSRect(origin: .zero, size: NSSize(width: contentWidth, height: 30))
    needsLayout = true
  }
  private func refreshNamespaces(_ controller: TerminalWindowController) {
    for view in namespaceList.subviews { view.removeFromSuperview() }
    for (index, namespace) in controller.namespaces.enumerated() {
      let button = NSButton(title: namespace.name, target: self, action: #selector(activateNamespace(_:)))
      button.tag = index
      button.setButtonType(.pushOnPushOff)
      button.bezelStyle = .regularSquare
      button.state = controller.activeNamespace === namespace ? .on : .off
      button.alignment = .left
      button.lineBreakMode = .byTruncatingTail
      let title = NSMutableAttributedString(string: namespace.name, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
      if !namespace.subtitle.isEmpty {
        title.append(NSAttributedString(string: "\n" + namespace.subtitle, attributes: [
          .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
      }
      button.attributedTitle = title
      button.cell?.wraps = true
      button.toolTip = namespace.name + (namespace.subtitle.isEmpty ? "" : "\n" + namespace.subtitle)
      button.frame = NSRect(x: 6, y: 6 + CGFloat(index) * 56, width: Self.sidebarWidth - 20, height: 50)
      namespaceList.addSubview(button)
    }
    namespaceList.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth - 14,
      height: CGFloat(controller.namespaces.count) * 56 + 12)
  }
  @objc private func activateNamespace(_ sender: NSButton) {
    terminal.session?.windowController?.selectNamespace(at: sender.tag)
  }
  @objc private func createNamespace() { terminal.session?.windowController?.newNamespace() }
  @objc private func editActiveNamespace() { terminal.session?.windowController?.editNamespace() }
  @objc private func closeActiveNamespace() { terminal.session?.windowController?.closeNamespace() }

  @objc private func activateTab(_ sender: NSButton) {
    guard let controller = terminal.session?.windowController, controller.tabs.indices.contains(sender.tag) else { return }
    controller.selectTab(controller.tabs[sender.tag])
  }
  @objc private func createTab() { terminal.session?.windowController?.newTab() }
  @objc private func closeActiveTab() { terminal.session?.windowController?.closeTab() }

  func refreshVisibility() {
    for view in [search, count, previous, next, close] { view.isHidden = !searching }
    let policy = NativeSettings(config: terminal.config).scrollbar
    scroller.scrollerStyle = NSScroller.preferredScrollerStyle
    showScroll = policy != "never" && scrollState.total > scrollState.len
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

final class NamespaceListView: NSView {
  override var isFlipped: Bool { true }
}
