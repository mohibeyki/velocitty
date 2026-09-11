// SPDX-License-Identifier: GPL-3.0
import AppKit
import UniformTypeIdentifiers
import VeloKit
import VelocittyConfiguration

// Editor selection follows the upstream macOS opener. See VeloKit/THIRD_PARTY_NOTICES.md.
struct ConfigurationEditor {
  var applicationForType: (String) -> URL? = { type in
    LSCopyDefaultApplicationURLForContentType(type as CFString, .all, nil)?
      .takeRetainedValue() as? URL
  }
  var openFile: (URL, URL?, @escaping (Error?) -> Void) -> Void = { file, editor, completion in
    if let editor {
      NSWorkspace.shared.open([file], withApplicationAt: editor,
        configuration: NSWorkspace.OpenConfiguration()) { _, error in completion(error) }
    } else {
      completion(NSWorkspace.shared.open(file) ? nil : ConfigurationError("macOS could not open \(file.path)."))
    }
  }

  func open(_ file: URL, completion: @escaping (Error?) -> Void) {
    do {
      if !FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        do {
          try Data("# Velocitty configuration. Empty settings use defaults.\n[terminal]\n".utf8)
            .write(to: file, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          // Another writer created the file; open it without overwriting it.
        }
      }
      let associated = UTType(filenameExtension: file.pathExtension)
        .flatMap { applicationForType($0.identifier) }
      let editor = associated ?? applicationForType(UTType.plainText.identifier)
      openFile(file, editor, completion)
    } catch { completion(error) }
  }
}

// Native settings retain the source document, including comments and includes.
final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
  private struct Setting {
    let table: String; let key: String
    var category: String {
      if table == "interface" { return "Workspace" }
      if key.hasPrefix("font") || key.hasPrefix("adjust_") { return "Font" }
      if ["theme", "background", "foreground", "palette", "cursor", "selection", "unfocused"].contains(where: { key.hasPrefix($0) }) { return "Colors & Appearance" }
      if ["keybind", "mouse", "clipboard", "copy", "paste", "click", "link"].contains(where: { key.hasPrefix($0) }) { return "Input & Clipboard" }
      if ["window", "macos", "tab", "resize", "focus", "split", "quit", "confirm", "undo"].contains(where: { key.hasPrefix($0) }) { return "Windows & Tabs" }
      if ["shell", "command", "initial_command", "working_directory", "env", "term", "scrollback"].contains(where: { key.hasPrefix($0) }) { return "Shell & Terminal" }
      return "Advanced"
    }
    var summary: String {
      switch key {
      case "font_family": return "Typeface for terminal text. Font fallback remains available in Advanced."
      case "font_size": return "Terminal font size in points."
      case "theme": return "Use a bundled theme, a file path, or light:Name,dark:Name for automatic appearance."
      case "working_directory": return "Starting directory for new terminals when directory inheritance does not apply."
      case "command", "initial_command": return "An explicit command creates standalone terminals instead of herdr sessions."
      case "keybind": return "Keyboard bindings. This repeatable setting accepts an array of bindings."
      case "quit_after_last_window_closed": return "Quit after closing the last window. Herdr terminals keep running."
      case "undo_timeout": return "How long explicit terminal closes can be undone before ending the process."
      case "background_opacity": return "Terminal background opacity, from 0 (transparent) to 1 (opaque)."
      case "cursor_style": return "Shape of the terminal cursor. Applications can request a different shape."
      default: return table == "interface" ? "Workspace appearance. Terminal colors are configured separately." : "Edit the value below or use the source document for advanced syntax."
      }
    }
  }
  private weak var appOwner: AppDelegate?
  private var configDocument: ConfigurationDocument
  private let defaults: ConfigurationDocument
  private var files: [URL]
  private let filePicker = NSPopUpButton()
  private let search = NSSearchField()
  private let category = NSPopUpButton()
  private let choices = NSComboBox()
  private let reset = NSButton(title: "Use Default", target: nil, action: nil)
  private let table = NSTableView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let value = NSTextField()
  private let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
  private let editor = NSTextView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private var settings: [Setting] = []
  private var filtered: [Setting] = []
  private var currentFile = 0

  init(appOwner: AppDelegate) throws {
    self.appOwner = appOwner
    let config = appOwner.runtime?.settings ?? AppConfiguration.load()
    files = [config.source] + config.sourceFiles.filter { $0 != config.source }
    configDocument = try ConfigurationDocument(url: config.source)
    defaults = try ConfigurationDocument(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    guard let engine = velokit_config_new() else { throw ConfigurationError("Could not load setting defaults.") }
    defer { velokit_config_free(engine) }
    let template = try ConfigurationTemplate.render { key in
      guard let formatted = key.withCString({ velokit_config_format(engine, $0) }) else { throw ConfigurationError("Could not format \(key).") }
      return String(cString: formatted)
    }
    defaults.text = template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line)
    }.filter { line in
      line.hasPrefix("[") || line.contains(" = ") || line.hasPrefix("  ") || line == "]" || line.isEmpty
    }.joined(separator: "\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Settings"
    window.minSize = NSSize(width: 760, height: 540)
    window.delegate = self
    window.center()
    settings = TerminalSettings.supported.sorted().map { Setting(table: "terminal", key: $0.replacingOccurrences(of: "-", with: "_")) }
      + NamespaceAppearance.defaults.keys.sorted().map { Setting(table: "interface", key: $0) }
    let root = NSView()
    window.contentView = root
    search.placeholderString = "Search settings"
    search.delegate = self
    search.target = self
    search.action = #selector(filterSettings)
    category.addItems(withTitles: ["All Settings", "Font", "Colors & Appearance", "Input & Clipboard", "Windows & Tabs", "Shell & Terminal", "Workspace", "Advanced"])
    category.target = self; category.action = #selector(filterSettings)
    choices.target = self; choices.action = #selector(chooseValue)
    choices.completes = true
    reset.target = self; reset.action = #selector(resetValue)
    filePicker.addItems(withTitles: files.map(\.path))
    filePicker.target = self
    filePicker.action = #selector(selectFile)
    let column = NSTableColumn(identifier: .init("setting"))
    table.addTableColumn(column)
    table.headerView = nil
    table.style = .sourceList
    table.dataSource = self
    table.delegate = self
    let list = NSScrollView()
    list.documentView = table
    list.hasVerticalScroller = true
    editor.isRichText = false
    editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 8, height: 8)
    editor.delegate = self
    editor.string = configDocument.text
    let advanced = NSScrollView()
    advanced.documentView = editor
    advanced.hasVerticalScroller = true
    advanced.borderType = .bezelBorder
    let apply = NSButton(title: "Apply to Draft", target: self, action: #selector(applyValue))
    enabled.target = self
    enabled.action = #selector(toggleValue)
    value.placeholderString = "TOML value, such as \"Menlo\", true, or [\"a\", \"b\"]"
    let rawLabel = NSTextField(labelWithString: "Advanced · source TOML")
    rawLabel.textColor = .secondaryLabelColor
    let save = NSButton(title: "Save & Reload", target: self, action: #selector(saveDocument))
    save.keyEquivalent = "s"
    save.keyEquivalentModifierMask = [.command]
    let revert = NSButton(title: "Reload File", target: self, action: #selector(revertDocument))
    let external = NSButton(title: "Open in Editor", target: self, action: #selector(openExternal))
    status.textColor = .secondaryLabelColor
    for view in [filePicker, search, category, list, detail, value, choices, enabled, reset, apply, rawLabel, advanced, status, save, revert, external] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    NSLayoutConstraint.activate([
      filePicker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), filePicker.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), filePicker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      search.topAnchor.constraint(equalTo: filePicker.bottomAnchor, constant: 12), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), search.widthAnchor.constraint(equalToConstant: 245),
      category.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), category.leadingAnchor.constraint(equalTo: search.leadingAnchor), category.widthAnchor.constraint(equalTo: search.widthAnchor),
      list.topAnchor.constraint(equalTo: category.bottomAnchor, constant: 8), list.leadingAnchor.constraint(equalTo: search.leadingAnchor), list.widthAnchor.constraint(equalTo: search.widthAnchor), list.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
      detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), detail.topAnchor.constraint(equalTo: search.topAnchor), detail.heightAnchor.constraint(equalToConstant: 116),
      value.leadingAnchor.constraint(equalTo: detail.leadingAnchor), value.trailingAnchor.constraint(equalTo: detail.trailingAnchor), value.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
      choices.leadingAnchor.constraint(equalTo: value.leadingAnchor), choices.trailingAnchor.constraint(equalTo: value.trailingAnchor), choices.topAnchor.constraint(equalTo: value.topAnchor),
      reset.centerXAnchor.constraint(equalTo: detail.centerXAnchor), reset.centerYAnchor.constraint(equalTo: enabled.centerYAnchor),
      enabled.leadingAnchor.constraint(equalTo: detail.leadingAnchor), enabled.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
      apply.trailingAnchor.constraint(equalTo: detail.trailingAnchor), apply.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
      rawLabel.leadingAnchor.constraint(equalTo: detail.leadingAnchor), rawLabel.topAnchor.constraint(equalTo: apply.bottomAnchor, constant: 12),
      advanced.leadingAnchor.constraint(equalTo: detail.leadingAnchor), advanced.trailingAnchor.constraint(equalTo: detail.trailingAnchor), advanced.topAnchor.constraint(equalTo: rawLabel.bottomAnchor, constant: 6), advanced.bottomAnchor.constraint(equalTo: list.bottomAnchor),
      save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      revert.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8), revert.centerYAnchor.constraint(equalTo: save.centerYAnchor),
      external.trailingAnchor.constraint(equalTo: revert.leadingAnchor, constant: -8), external.centerYAnchor.constraint(equalTo: save.centerYAnchor),
      status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: external.leadingAnchor, constant: -12), status.centerYAnchor.constraint(equalTo: save.centerYAnchor), status.heightAnchor.constraint(lessThanOrEqualToConstant: 46),
    ])
    filterSettings()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard filtered.indices.contains(row) else { return nil }
    return NSTextField(labelWithString: filtered[row].key.replacingOccurrences(of: "_", with: " "))
  }
  @objc private func filterSettings() {
    let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].key : nil
    let query = search.stringValue.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    filtered = settings.filter {
      (category.indexOfSelectedItem == 0 || $0.category == category.titleOfSelectedItem) &&
      (query.isEmpty || ($0.table + "." + $0.key).localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(search.stringValue))
    }
    table.reloadData()
    if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: filtered.firstIndex { $0.key == selected } ?? 0), byExtendingSelection: false) }
    else { detail.stringValue = "No matching settings"; value.isEnabled = false; choices.isHidden = true; enabled.isHidden = true; reset.isEnabled = false }
  }
  func controlTextDidChange(_ obj: Notification) { filterSettings() }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    value.isEnabled = true; reset.isEnabled = true
    let fallback = defaults.value(table: setting.table, key: setting.key) ?? "\"\""
    value.stringValue = configDocument.value(table: setting.table, key: setting.key) ?? fallback
    let normalized = value.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    enabled.isHidden = !["true", "false"].contains(normalized)
    enabled.state = normalized == "true" ? .on : .off
    choices.removeAllItems()
    var suggestions: [String] = []
    switch setting.key {
    case "font_family": suggestions = NSFontManager.shared.availableFontFamilies.sorted()
    case "theme": suggestions = ["Rose Pine", "Rose Pine Moon", "Rose Pine Dawn", "TokyoNight Moon", "TokyoNight Night", "TokyoNight Storm", "TokyoNight Day", "Catppuccin Latte", "Catppuccin Frappe", "Catppuccin Macchiato", "Catppuccin Mocha"]
    case "cursor_style": suggestions = ["block", "bar", "underline", "block_hollow"]
    default: break
    }
    if value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") { suggestions = [] }
    choices.addItems(withObjectValues: suggestions)
    choices.stringValue = normalized
    choices.isHidden = suggestions.isEmpty
    value.isHidden = !choices.isHidden
    let terminalSources = appOwner?.runtime?.settings.options.filter { $0.key == setting.key.replacingOccurrences(of: "_", with: "-") }.compactMap { $0.source?.path } ?? []
    let sources = setting.table == "interface" ? [appOwner?.runtime?.settings.interfaceSources[setting.key]?.path].compactMap { $0 } : terminalSources
    detail.stringValue = setting.table + "." + setting.key + "\n" + setting.summary + "\nDefault: " + String(fallback.prefix(180)) + "\n" + (sources.isEmpty ? "Editing this file; includes may override it." : "Contributing source: " + Array(Set(sources)).sorted().joined(separator: ", "))
  }
  func textDidChange(_ notification: Notification) {
    configDocument.text = editor.string
    window?.isDocumentEdited = configDocument.hasChanges
  }
  @objc private func chooseValue() {
    // JSON string escaping is also valid TOML basic-string escaping.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    if let data = try? encoder.encode(choices.stringValue), let quoted = String(data: data, encoding: .utf8) { value.stringValue = quoted }
  }
  @objc private func resetValue() {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    do {
      try configDocument.removeValue(table: setting.table, key: setting.key)
      editor.string = configDocument.text; window?.isDocumentEdited = configDocument.hasChanges
      tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
      status.textColor = .secondaryLabelColor
      status.stringValue = "Override removed from this file. Included files may still supply a value."
    } catch { showError(error) }
  }
  private func showError(_ error: Error) { status.textColor = .systemRed; status.stringValue = error.localizedDescription; status.toolTip = status.stringValue }
  @objc private func toggleValue() { value.stringValue = enabled.state == .on ? "true" : "false"; applyValue() }
  @objc private func applyValue() {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    if !choices.isHidden { chooseValue() }
    do {
      let fragment = try AppConfiguration.parse(Data("[\(setting.table)]\n\(setting.key) = \(value.stringValue)\n".utf8), source: configDocument.url)
      var diagnostics: [String] = fragment.diagnostics
      let prepared = try TerminalRuntime.makeConfig(fragment, diagnostic: { diagnostics.append($0) })
      velokit_config_free(prepared)
      guard diagnostics.isEmpty else { throw ConfigurationError(diagnostics.joined(separator: "\n")) }
      try configDocument.setValue(table: setting.table, key: setting.key, toml: value.stringValue)
      editor.string = configDocument.text
      window?.isDocumentEdited = configDocument.hasChanges
      status.textColor = .secondaryLabelColor
      status.stringValue = "Draft updated. Save & Reload to apply."
    } catch { showError(error) }
  }
  @objc private func saveDocument() {
    do {
      configDocument.text = editor.string
      try configDocument.save()
      window?.isDocumentEdited = false
      appOwner?.reloadConfiguration(nil)
      let diagnostics = appOwner?.runtime?.settings.diagnostics ?? []
      status.textColor = diagnostics.isEmpty ? .secondaryLabelColor : .systemOrange
      status.stringValue = diagnostics.isEmpty ? "Saved. Process settings apply to new terminals." : "Saved with configuration warnings. " + diagnostics.joined(separator: "\n")
      status.toolTip = status.stringValue
    } catch { showError(error) }
  }
  private func confirmDiscard(_ proceed: @escaping () -> Void) {
    guard configDocument.hasChanges, let window else { proceed(); return }
    let alert = NSAlert()
    alert.messageText = "Discard unsaved settings?"
    alert.addButton(withTitle: "Keep Editing")
    alert.addButton(withTitle: "Discard")
    alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { proceed() } }
  }
  @objc private func selectFile() {
    let index = filePicker.indexOfSelectedItem
    filePicker.selectItem(at: currentFile)
    confirmDiscard { [weak self] in self?.loadFile(index) }
  }
  private func loadFile(_ index: Int) {
    guard files.indices.contains(index) else { return }
    do {
      configDocument = try ConfigurationDocument(url: files[index])
      currentFile = index
      filePicker.selectItem(at: index)
      editor.string = configDocument.text
      window?.isDocumentEdited = false
      tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
      status.stringValue = ""
    } catch { showError(error) }
  }
  @objc private func revertDocument() { confirmDiscard { [weak self] in guard let self else { return }; self.loadFile(self.currentFile) } }
  @objc private func openExternal() { ConfigurationEditor().open(configDocument.url) { [weak self] error in if let error { self?.status.stringValue = error.localizedDescription } } }
  func confirmQuit() -> Bool {
    guard configDocument.hasChanges else { return true }
    let alert = NSAlert()
    alert.messageText = "Save settings before quitting?"
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Discard")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      do { configDocument.text = editor.string; try configDocument.save(); return true }
      catch { status.stringValue = error.localizedDescription; showWindow(nil); return false }
    case .alertThirdButtonReturn: return true
    default: return false
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard configDocument.hasChanges else { return true }
    confirmDiscard { [weak self] in guard let self else { return }; self.loadFile(self.currentFile); self.window?.close() }
    return false
  }
}

final class ConnectionsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  private weak var appOwner: AppDelegate?
  private let table = NSTableView()
  private let message = NSTextField(wrappingLabelWithString: "Disabling a connection leaves its terminals running. Tabs remain in their spaces.")
  private var rows: [HerdrConnection] = []
  private var timer: Timer?
  init(owner: AppDelegate) {
    self.appOwner = owner
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 370), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Herdr Connections"; window.minSize = NSSize(width: 560, height: 280); window.center()
    let root = NSView(); window.contentView = root
    for (id, title, width) in [("enabled", "Enabled", 65.0), ("name", "Connection", 270.0), ("status", "Status", 260.0)] {
      let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
    }
    table.dataSource = self; table.delegate = self; table.rowHeight = 44
    table.setAccessibilityLabel("Herdr connections")
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
    let local = NSButton(title: "Add Local…", target: self, action: #selector(addLocal))
    let remote = NSButton(title: "Add SSH…", target: self, action: #selector(addRemote))
    let retry = NSButton(title: "Retry", target: self, action: #selector(retry))
    let tab = NSButton(title: "New Tab", target: self, action: #selector(newTab))
    let buttons = NSStackView(views: [local, remote, retry, tab]); buttons.spacing = 8
    message.textColor = .secondaryLabelColor
    for view in [scroll, message, buttons] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12),
      message.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), message.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), message.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
      buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
    ])
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in if self?.window?.isVisible == true { self?.refresh() } }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { timer?.invalidate() }
  func refresh() {
    let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
    rows = appOwner?.connections ?? []; table.reloadData()
    if let index = rows.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let profile = rows[row]
    if column?.identifier.rawValue == "enabled" {
      let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
      toggle.state = profile.enabled ? .on : .off; toggle.tag = row
      toggle.setAccessibilityLabel("Enable " + profile.label); return toggle
    }
    let text = column?.identifier.rawValue == "name" ? profile.label + "\n" + (profile.target ?? "Local") + " / " + profile.session : (appOwner?.connectionStatus[profile.id] ?? "Not connected")
    let label = NSTextField(wrappingLabelWithString: text); label.maximumNumberOfLines = 2; label.toolTip = text
    return label
  }
  @objc private func toggle(_ sender: NSButton) {
    guard rows.indices.contains(sender.tag) else { return }; appOwner?.setConnectionEnabled(rows[sender.tag].id, enabled: sender.state == .on); refresh()
  }
  @objc private func retry() {
    guard rows.indices.contains(table.selectedRow), let client = appOwner?.client(for: rows[table.selectedRow].id), client.isEnabled else { NSSound.beep(); return }
    appOwner?.connectEndpoint(client)
  }
  @objc private func newTab() {
    guard rows.indices.contains(table.selectedRow), let client = appOwner?.client(for: rows[table.selectedRow].id), client.isEnabled else { NSSound.beep(); return }
    if let target = appOwner?.activeWindow, target.session?.herdrTerminal != nil { target.newTab(using: client) }
    else { appOwner?.openHerdrWindow(using: client) }
  }
  @objc private func addLocal() { add(remote: false) }
  @objc private func addRemote() { add(remote: true) }
  private func add(remote: Bool) {
    guard let window, window.attachedSheet == nil else { return }
    let alert = NSAlert(); alert.messageText = remote ? "Add SSH Connection" : "Add Local Connection"
    alert.informativeText = remote ? "Uses your existing SSH keys and known hosts. Start herdr on the destination first." : "Connect to an independent local herdr session."
    let name = NSTextField(); name.placeholderString = "Name"
    let session = NSTextField(string: "velocitty"); session.placeholderString = "Herdr session"
    let target = NSTextField(); target.placeholderString = "user@host"
    let fields = NSStackView(views: remote ? [name, target, session] : [name, session]); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 8
    fields.frame = NSRect(x: 0, y: 0, width: 350, height: remote ? 90 : 60)
    for field in [name, session, target] { field.widthAnchor.constraint(equalToConstant: 350).isActive = true }
    alert.accessoryView = fields; alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      let value = session.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let profile = HerdrConnection(id: remote ? "ssh:" + UUID().uuidString : (value == "velocitty" ? "local" : "local:" + value), label: name.stringValue, session: value, target: remote ? target.stringValue : nil)
      do { try self?.appOwner?.addConnection(profile); self?.message.stringValue = "Connection added." }
      catch { self?.message.stringValue = error.localizedDescription }
    }
  }
}
