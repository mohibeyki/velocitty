// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class CommandPalette: NSPanel, NSTextFieldDelegate, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  struct Entry {
    let title: String
    let detail: String
    let action: String
    var run: (() -> Void)? = nil
  }
  let query = NSTextField()
  let table = NSTableView()
  let list = NSScrollView()
  private var entryProvider: (() -> [Entry])?
  private var refreshTimer: Timer?
  var entries: [Entry] = []
  var filtered: [Entry] = []
  weak var terminal: TerminalView?
  private let emptyLabel = NSTextField(labelWithString: "No matches")
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(terminal: TerminalView, entries provider: (() -> [Entry])? = nil) {
    self.terminal = terminal
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 249), styleMask: [.borderless],
      backing: .buffered, defer: false)
    entryProvider = provider
    title = provider == nil ? "Commands" : "Search Workspace"
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    delegate = self
    let native = NativeSettings(config: terminal.config)
    entries = native.commands.compactMap { command in
      guard command.action.withCString({ velokit_action_supported($0) }), command.title != "Ghostty"
      else { return nil }
      return Entry(title: command.title, detail: command.detail, action: command.action)
    }
    if provider == nil, terminal.session?.herdrTerminal != nil {
      entries += [
        Entry(title: "Show Tab Alongside…", detail: "Show another namespace or server beside this tab.", action: "velocitty:alongside"),
        Entry(title: "Stop Showing Alongside", detail: "Return to one presented tab without closing terminals.", action: "velocitty:stop-alongside"),
        Entry(title: "Move Tab to Namespace…", detail: "Move all panes while retaining their running processes.", action: "velocitty:move-tab"),
        Entry(title: "Move Pane to Tab…", detail: "Move this terminal into another tab.", action: "velocitty:move-pane"),
        Entry(title: "Move Pane to New Tab", detail: "Detach this pane into its own tab.", action: "velocitty:detach-pane"),
      ]
    }
    if let provider { entries = provider() }
    let color = native.background.usingColorSpace(.sRGB) ?? .windowBackgroundColor
    let dark = 0.2126 * color.redComponent + 0.7152 * color.greenComponent
      + 0.0722 * color.blueComponent < 0.5
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 500, height: 249))
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 10
    background.layer?.masksToBounds = true
    background.layer?.borderWidth = 1
    appearance?.performAsCurrentDrawingAppearance {
      background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
    }
    contentView = background
    let tint = NSView(frame: background.bounds)
    tint.autoresizingMask = [.width, .height]
    tint.wantsLayer = true
    tint.layer?.backgroundColor = color.withAlphaComponent(0.75).cgColor
    background.addSubview(tint)

    query.frame = NSRect(x: 16, y: 213, width: 468, height: 26)
    query.placeholderString = "Execute a command…"
    query.font = .systemFont(ofSize: 20)
    query.isBezeled = false
    query.drawsBackground = false
    query.focusRingType = .none
    query.delegate = self
    query.autoresizingMask = [.width, .minYMargin]
    background.addSubview(query)
    let divider = NSBox(frame: NSRect(x: 0, y: 200, width: 500, height: 1))
    divider.boxType = .separator
    divider.autoresizingMask = [.width, .minYMargin]
    background.addSubview(divider)

    list.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
    list.autoresizingMask = [.width, .height]
    list.hasVerticalScroller = true
    list.autohidesScrollers = true
    list.drawsBackground = false
    list.automaticallyAdjustsContentInsets = false
    list.contentInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
    column.width = 480
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.headerView = nil
    table.backgroundColor = .clear
    table.style = .plain
    table.intercellSpacing = NSSize(width: 0, height: 4)
    table.rowHeight = 33
    table.selectionHighlightStyle = .none
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.action = #selector(runSelected)
    list.documentView = table
    background.addSubview(list)
    emptyLabel.alignment = .center
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.frame = NSRect(x: 10, y: 80, width: 480, height: 24)
    background.addSubview(emptyLabel)
    if provider != nil { query.placeholderString = "Search namespaces, tabs, agents…" }
    filter()
    if provider != nil {
      refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        guard let self, let provider = self.entryProvider else { return }
        let updated = provider()
        if updated.map({ $0.action + $0.title + $0.detail }) != self.entries.map({ $0.action + $0.title + $0.detail }) {
          let selected = self.filtered.indices.contains(self.table.selectedRow) ? self.filtered[self.table.selectedRow].action : nil
          self.entries = updated
          self.filter()
          if let index = self.filtered.firstIndex(where: { $0.action == selected }) { self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        }
      }
    }
  }
  deinit { refreshTimer?.invalidate() }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let entry = filtered[row]
    let text = NSTextField(labelWithString: entry.title)
    text.maximumNumberOfLines = 1
    text.lineBreakMode = .byTruncatingTail
    text.font = .systemFont(ofSize: 14)
    let shortcut = NSTextField(labelWithString: shortcut(for: entry.action))
    shortcut.font = .systemFont(ofSize: 13)
    shortcut.textColor = .secondaryLabelColor
    shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
    let cell = NSTableCellView()
    cell.toolTip = entry.detail.isEmpty ? entry.title : entry.detail
    for label in [text, shortcut] {
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)
    }
    cell.textField = text
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
      shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    PaletteRow()
  }
  func shortcut(for action: String) -> String {
    Self.formatShortcut(for: action, config: terminal?.config)
  }
  static func formatShortcut(for action: String, config: ghostty_config_t?) -> String {
    guard let config else { return "" }
    var trigger = ghostty_input_trigger_s()
    guard action.withCString({ velokit_config_trigger(config, $0, &trigger) }) else { return "" }
    let key: String
    if trigger.tag == GHOSTTY_TRIGGER_UNICODE, let scalar = UnicodeScalar(trigger.key.unicode) {
      key = String(scalar)
    } else if trigger.tag == GHOSTTY_TRIGGER_PHYSICAL {
      key = GlobalShortcuts.character(for: velokit_keycode_for_key(trigger.key.physical)) ?? ""
    } else { return "" }
    guard !key.isEmpty else { return "" }
    let mods = trigger.mods.rawValue
    return (mods & GHOSTTY_MODS_CTRL.rawValue != 0 ? "⌃" : "")
      + (mods & GHOSTTY_MODS_ALT.rawValue != 0 ? "⌥" : "")
      + (mods & GHOSTTY_MODS_SHIFT.rawValue != 0 ? "⇧" : "")
      + (mods & GHOSTTY_MODS_SUPER.rawValue != 0 ? "⌘" : "") + key.uppercased()
  }
  func present() {
    if let window = terminal?.window {
      window.addChildWindow(self, ordered: .above)
      let content = window.convertToScreen(window.contentLayoutRect)
      setFrameOrigin(NSPoint(x: content.midX - frame.width / 2,
        y: content.maxY - content.height * 0.05 - frame.height))
    } else { center() }
    makeKeyAndOrderFront(nil)
    makeFirstResponder(query)
  }
  override func close() {
    refreshTimer?.invalidate()
    let restoreFocus = isKeyWindow && NSApp.isActive
    parent?.removeChildWindow(self)
    super.close()
    if restoreFocus {
      terminal?.window?.makeKeyAndOrderFront(nil)
      terminal?.window?.makeFirstResponder(terminal)
    }
  }
  func windowDidResignKey(_ notification: Notification) { if isVisible { close() } }
  func controlTextDidChange(_ obj: Notification) { filter() }
  func filter() {
    let needle = query.stringValue
    filtered = entries.filter {
      needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
        || $0.detail.localizedCaseInsensitiveContains(needle)
    }
    table.reloadData()
    emptyLabel.isHidden = !filtered.isEmpty
    if !filtered.isEmpty && !needle.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    } else { table.deselectAll(nil) }
    list.contentView.scroll(to: NSPoint(x: -10, y: -10))
    list.reflectScrolledClipView(list.contentView)
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      runSelected()
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      close()
      return true
    }
    if commandSelector == #selector(NSResponder.moveDown(_:))
      || commandSelector == #selector(NSResponder.moveUp(_:))
    {
      let direction = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let row = filtered.isEmpty ? -1
        : table.selectedRow < 0 ? (direction > 0 ? 0 : filtered.count - 1)
        : (table.selectedRow + direction + filtered.count) % filtered.count
      if row >= 0 {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
      }
      return true
    }
    return false
  }
  @objc func runSelected() {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let entry = filtered[table.selectedRow]
    let action = entry.action
    close()
    if let run = entry.run { run(); return }
    terminal?.window?.makeFirstResponder(terminal)
    switch action {
    case "velocitty:alongside": terminal?.session?.windowController?.chooseCompanion()
    case "velocitty:stop-alongside": terminal?.session?.windowController?.stopAlongside()
    case "velocitty:move-tab": terminal?.session?.windowController?.chooseTabNamespace()
    case "velocitty:move-pane": terminal?.session?.windowController?.choosePaneTab()
    case "velocitty:detach-pane": terminal?.session?.windowController?.movePaneToNewTab()
    default: terminal?.performSurfaceAction(action)
    }
  }
}

private final class PaletteRow: NSTableRowView {
  private var hover = false
  private var tracking: NSTrackingArea?
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
  override var isSelected: Bool { didSet { needsDisplay = true } }
  override func drawBackground(in dirtyRect: NSRect) {
    if isSelected || hover {
      (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.2)
        : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
  }
}
