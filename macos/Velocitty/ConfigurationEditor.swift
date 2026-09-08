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
  private struct Setting { let table: String; let key: String }
  private weak var appOwner: AppDelegate?
  private var configDocument: ConfigurationDocument
  private let defaults: ConfigurationDocument
  private var files: [URL]
  private let filePicker = NSPopUpButton()
  private let search = NSSearchField()
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
    for view in [filePicker, search, list, detail, value, enabled, apply, rawLabel, advanced, status, save, revert, external] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    NSLayoutConstraint.activate([
      filePicker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), filePicker.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), filePicker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      search.topAnchor.constraint(equalTo: filePicker.bottomAnchor, constant: 12), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), search.widthAnchor.constraint(equalToConstant: 245),
      list.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), list.leadingAnchor.constraint(equalTo: search.leadingAnchor), list.widthAnchor.constraint(equalTo: search.widthAnchor), list.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
      detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), detail.topAnchor.constraint(equalTo: search.topAnchor), detail.heightAnchor.constraint(equalToConstant: 78),
      value.leadingAnchor.constraint(equalTo: detail.leadingAnchor), value.trailingAnchor.constraint(equalTo: detail.trailingAnchor), value.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
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
    NSTextField(labelWithString: filtered[row].table + "." + filtered[row].key)
  }
  @objc private func filterSettings() {
    filtered = settings.filter { search.stringValue.isEmpty || ($0.table + "." + $0.key).localizedCaseInsensitiveContains(search.stringValue.replacingOccurrences(of: "-", with: "_")) }
    table.reloadData()
    if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
  }
  func controlTextDidChange(_ obj: Notification) { filterSettings() }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    let fallback = defaults.value(table: setting.table, key: setting.key) ?? "\"\""
    value.stringValue = configDocument.value(table: setting.table, key: setting.key) ?? fallback
    let normalized = value.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    enabled.isHidden = !["true", "false"].contains(normalized)
    enabled.state = normalized == "true" ? .on : .off
    let terminalSources = appOwner?.runtime?.settings.options.filter { $0.key == setting.key.replacingOccurrences(of: "_", with: "-") }.compactMap { $0.source?.path } ?? []
    let sources = setting.table == "interface" ? [appOwner?.runtime?.settings.interfaceSources[setting.key]?.path].compactMap { $0 } : terminalSources
    detail.stringValue = setting.table + "." + setting.key + "\nDefault: " + String(fallback.prefix(180)) + "\n" + (sources.isEmpty ? "Editing this file; includes may override it." : "Contributing source: " + Array(Set(sources)).sorted().joined(separator: ", "))
  }
  func textDidChange(_ notification: Notification) {
    configDocument.text = editor.string
    window?.isDocumentEdited = configDocument.hasChanges
  }
  @objc private func toggleValue() { value.stringValue = enabled.state == .on ? "true" : "false"; applyValue() }
  @objc private func applyValue() {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    do {
      let fragment = try AppConfiguration.parse(Data("[\(setting.table)]\n\(setting.key) = \(value.stringValue)\n".utf8), source: configDocument.url)
      var diagnostics: [String] = []
      let prepared = try TerminalRuntime.makeConfig(fragment, diagnostic: { diagnostics.append($0) })
      velokit_config_free(prepared)
      guard diagnostics.isEmpty else { throw ConfigurationError(diagnostics.joined(separator: "\n")) }
      try configDocument.setValue(table: setting.table, key: setting.key, toml: value.stringValue)
      editor.string = configDocument.text
      window?.isDocumentEdited = configDocument.hasChanges
      status.stringValue = "Draft updated. Save & Reload to apply."
    } catch { status.stringValue = error.localizedDescription }
  }
  @objc private func saveDocument() {
    do {
      configDocument.text = editor.string
      try configDocument.save()
      window?.isDocumentEdited = false
      appOwner?.reloadConfiguration(nil)
      status.stringValue = "Saved. Process settings apply to new terminals."
    } catch { status.stringValue = error.localizedDescription }
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
    } catch { status.stringValue = error.localizedDescription }
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
