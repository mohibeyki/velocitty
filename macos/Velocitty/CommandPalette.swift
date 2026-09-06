// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class CommandPalette: NSPanel, NSSearchFieldDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  struct Entry {
    let title: String
    let detail: String
    let action: String
  }
  let query = NSSearchField()
  let table = NSTableView()
  let list = NSScrollView()
  var entries: [Entry] = []
  var filtered: [Entry] = []
  weak var terminal: TerminalView?

  static let unsupported: Set<String> = [
    "new_tab", "previous_tab", "next_tab", "last_tab", "close_tab", "prompt_tab_title",
    "set_tab_title", "show_on_screen_keyboard", "new_split", "goto_tab", "goto_split", "move_tab",
    "move_tab_to_new_window",
    "resize_split", "equalize_splits", "toggle_split_zoom", "toggle_tab_overview",
    "toggle_quick_terminal",
    "undo", "redo", "check_for_updates", "inspector", "show_gtk_inspector", "crash",
    "export_terminal_io",
  ]
  init(terminal: TerminalView) {
    self.terminal = terminal
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    title = "Commands"
    isReleasedWhenClosed = false
    let native = NativeSettings(config: terminal.config)
    entries = native.commands.compactMap { command in
      guard !Self.unsupported.contains(command.actionKey), command.title != "Ghostty"
      else { return nil }
      return Entry(title: command.title, detail: command.detail, action: command.action)
    }
    query.frame = NSRect(x: 12, y: 376, width: 596, height: 28)
    query.placeholderString = "Search commands"
    query.delegate = self
    contentView?.addSubview(query)
    list.frame = NSRect(x: 12, y: 12, width: 596, height: 352)
    list.hasVerticalScroller = true
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
    column.width = 580
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 45
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.doubleAction = #selector(runSelected)
    list.documentView = table
    contentView?.addSubview(list)
    filter()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let entry = filtered[row]
    let text = NSTextField(
      labelWithString: entry.title + (entry.detail.isEmpty ? "" : "\n" + entry.detail))
    text.maximumNumberOfLines = 2
    text.lineBreakMode = .byTruncatingTail
    text.font = .systemFont(ofSize: 12)
    return text
  }
  func controlTextDidChange(_ obj: Notification) { filter() }
  func filter() {
    let needle = query.stringValue
    filtered = entries.filter {
      needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
        || $0.detail.localizedCaseInsensitiveContains(needle)
    }
    table.reloadData()
    if !filtered.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
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
      let row = min(filtered.count - 1, max(0, table.selectedRow + direction))
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
    let action = filtered[table.selectedRow].action
    close()
    terminal?.window?.makeFirstResponder(terminal)
    terminal?.performSurfaceAction(action)
  }
}
