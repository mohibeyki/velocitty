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
    var category: String { SettingsCatalog.category(table: table, key: key) }
    var summary: String { SettingsCatalog.summary(table: table, key: key) }
  }
  private weak var appOwner: AppDelegate?
  private var configDocument: ConfigurationDocument
  private let defaults: ConfigurationDocument
  private var files: [URL]
  private let filePicker = NSPopUpButton()
  private let search = NSSearchField()
  private let category = NSPopUpButton()
  private let choices = NSComboBox()
  private let reset = NSButton(title: "Reset Override", target: nil, action: nil)
  private let table = NSTableView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let value = NSTextField()
  private let number = NSStepper()
  private let color = NSColorWell()
  private let browseThemes = NSButton(title: "Browse Themes…", target: nil, action: nil)
  private let addEntry = NSButton(title: "Add Entry…", target: nil, action: nil)
  private let removeEntry = NSButton(title: "Remove Entry…", target: nil, action: nil)
  private let diagnostics = NSButton(title: "Diagnostics…", target: nil, action: nil)
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
    defaults = try Self.buildDefaultsDocument()
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
    let controls = buildControls(appOwner: appOwner)
    for view in controls.allViews {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    activateConstraints(root: root, controls)
    detail.font = .systemFont(ofSize: 12)
    detail.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    filterSettings()
  }

  /// The engine's default value for each setting, as an unsaved document for lookups.
  private static func buildDefaultsDocument() throws -> ConfigurationDocument {
    let document = try ConfigurationDocument(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    guard let engine = velokit_config_new() else { throw ConfigurationError("Could not load setting defaults.") }
    defer { velokit_config_free(engine) }
    let template = try ConfigurationTemplate.render { key in
      guard let formatted = key.withCString({ velokit_config_format(engine, $0) }) else { throw ConfigurationError("Could not format \(key).") }
      return String(cString: formatted)
    }
    document.text = template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line)
    }.filter { line in
      line.hasPrefix("[") || line.contains(" = ") || line.hasPrefix("  ") || line == "]" || line.isEmpty
    }.joined(separator: "\n")
    return document
  }

  /// The controls the layout needs by name, besides the stored ones.
  private struct Controls {
    let list: NSScrollView, advanced: NSScrollView
    let apply: NSButton, save: NSButton, revert: NSButton, external: NSButton
    let rawLabel: NSTextField
    var allViews: [NSView] = []
  }

  /// Creates the controls, wires their targets and returns them in the order they are added.
  private func buildControls(appOwner: AppDelegate) -> Controls {
    search.placeholderString = "Search settings"
    search.delegate = self
    search.target = self
    search.action = #selector(filterSettings)
    category.addItems(withTitles: ["All Settings"] + SettingsCatalog.categories)
    category.target = self; category.action = #selector(filterSettings)
    number.target = self; number.action = #selector(stepValue); number.minValue = -1_000_000; number.maxValue = 1_000_000
    color.target = self; color.action = #selector(colorValue)
    browseThemes.target = appOwner; browseThemes.action = #selector(AppDelegate.showThemePicker)
    addEntry.target = self; addEntry.action = #selector(appendEntry)
    removeEntry.target = self; removeEntry.action = #selector(deleteEntry)
    diagnostics.target = self; diagnostics.action = #selector(showDiagnostics)
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
    var controls = Controls(list: list, advanced: advanced, apply: apply, save: save, revert: revert, external: external, rawLabel: rawLabel)
    controls.allViews = [filePicker, search, category, list, detail, value, choices, enabled, reset, apply, rawLabel, advanced, status, save, revert, external, number, color, addEntry, removeEntry, diagnostics, browseThemes]
    return controls
  }

  private func activateConstraints(root: NSView, _ controls: Controls) {
    let (list, advanced, apply, save, revert, external, rawLabel) = (controls.list, controls.advanced, controls.apply, controls.save, controls.revert, controls.external, controls.rawLabel)
    NSLayoutConstraint.activate([
      filePicker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), filePicker.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), filePicker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      search.topAnchor.constraint(equalTo: filePicker.bottomAnchor, constant: 12), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), search.widthAnchor.constraint(equalToConstant: 245),
      category.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), category.leadingAnchor.constraint(equalTo: search.leadingAnchor), category.widthAnchor.constraint(equalTo: search.widthAnchor),
      list.topAnchor.constraint(equalTo: category.bottomAnchor, constant: 8), list.leadingAnchor.constraint(equalTo: search.leadingAnchor), list.widthAnchor.constraint(equalTo: search.widthAnchor), list.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
      detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), detail.topAnchor.constraint(equalTo: search.topAnchor), detail.heightAnchor.constraint(equalToConstant: 158),
      value.leadingAnchor.constraint(equalTo: detail.leadingAnchor), value.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -38), value.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
      number.trailingAnchor.constraint(equalTo: detail.trailingAnchor), number.centerYAnchor.constraint(equalTo: value.centerYAnchor),
      color.trailingAnchor.constraint(equalTo: detail.trailingAnchor), color.centerYAnchor.constraint(equalTo: value.centerYAnchor), color.widthAnchor.constraint(equalToConstant: 30), color.heightAnchor.constraint(equalToConstant: 24),
      browseThemes.leadingAnchor.constraint(equalTo: detail.leadingAnchor), browseThemes.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
      addEntry.leadingAnchor.constraint(equalTo: detail.leadingAnchor), addEntry.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
      removeEntry.leadingAnchor.constraint(equalTo: addEntry.trailingAnchor, constant: 8), removeEntry.centerYAnchor.constraint(equalTo: addEntry.centerYAnchor),
      diagnostics.leadingAnchor.constraint(equalTo: detail.leadingAnchor), diagnostics.centerYAnchor.constraint(equalTo: rawLabel.centerYAnchor),
      choices.leadingAnchor.constraint(equalTo: value.leadingAnchor), choices.trailingAnchor.constraint(equalTo: value.trailingAnchor), choices.topAnchor.constraint(equalTo: value.topAnchor),
      reset.trailingAnchor.constraint(equalTo: detail.trailingAnchor), reset.centerYAnchor.constraint(equalTo: rawLabel.centerYAnchor),
      enabled.leadingAnchor.constraint(equalTo: detail.leadingAnchor), enabled.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
      apply.trailingAnchor.constraint(equalTo: detail.trailingAnchor), apply.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
      rawLabel.leadingAnchor.constraint(equalTo: diagnostics.trailingAnchor, constant: 12), rawLabel.topAnchor.constraint(equalTo: apply.bottomAnchor, constant: 12),
      advanced.leadingAnchor.constraint(equalTo: detail.leadingAnchor), advanced.trailingAnchor.constraint(equalTo: detail.trailingAnchor), advanced.topAnchor.constraint(equalTo: rawLabel.bottomAnchor, constant: 6), advanced.bottomAnchor.constraint(equalTo: list.bottomAnchor),
      save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
      revert.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8), revert.centerYAnchor.constraint(equalTo: save.centerYAnchor),
      external.trailingAnchor.constraint(equalTo: revert.leadingAnchor, constant: -8), external.centerYAnchor.constraint(equalTo: save.centerYAnchor),
      status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: external.leadingAnchor, constant: -12), status.centerYAnchor.constraint(equalTo: save.centerYAnchor), status.heightAnchor.constraint(lessThanOrEqualToConstant: 46),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard filtered.indices.contains(row) else { return nil }
    return NSTextField(labelWithString: filtered[row].key.replacingOccurrences(of: "_", with: " "))
  }
  @objc private func filterSettings() {
    let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].table + "." + filtered[table.selectedRow].key : nil
    let query = search.stringValue.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    filtered = settings.filter {
      (category.indexOfSelectedItem == 0 || $0.category == category.titleOfSelectedItem) &&
      (query.isEmpty || ($0.table + "." + $0.key).localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(search.stringValue))
    }
    table.reloadData()
    if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: filtered.firstIndex { $0.table + "." + $0.key == selected } ?? 0), byExtendingSelection: false); refreshControls() }
    else { browseThemes.isHidden = true; number.isHidden = true; color.isHidden = true; addEntry.isHidden = true; removeEntry.isHidden = true; detail.stringValue = "No matching settings"; value.isEnabled = false; choices.isHidden = true; enabled.isHidden = true; reset.isEnabled = false }
  }
  func controlTextDidChange(_ obj: Notification) { filterSettings() }
  func tableViewSelectionDidChange(_ notification: Notification) { refreshControls() }
  /// Shows the selected setting's value, controls and description.
  private func refreshControls() {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    browseThemes.isHidden = setting.table != "terminal" || setting.key != "theme"
    value.isEnabled = true; reset.isEnabled = true
    let fallback = defaults.value(table: setting.table, key: setting.key) ?? "\"\""
    value.stringValue = configDocument.value(table: setting.table, key: setting.key) ?? fallback
    configureControls(for: setting, normalized: normalizedValue(for: setting))
    showDetail(for: setting, fallback: fallback)
  }
  /// The value field as the parser reads it, so booleans, numbers and colors are recognized.
  private func normalizedValue(for setting: Setting) -> String {
    let fragment = try? AppConfiguration.parseFragment(table: setting.table, key: setting.key, value: value.stringValue, source: configDocument.url)
    let decoded = setting.table == "interface" ? fragment?.interface[setting.key] : fragment?.options.first { $0.key == setting.key.replacingOccurrences(of: "_", with: "-") }?.value
    return decoded ?? value.stringValue
  }
  /// Show the editing controls that fit the setting's current value.
  private func configureControls(for setting: Setting, normalized: String) {
    enabled.isHidden = !["true", "false"].contains(normalized)
    enabled.state = normalized == "true" ? .on : .off
    choices.removeAllItems()
    var suggestions: [String] = []
    switch setting.key {
    case "font_family": suggestions = NSFontManager.shared.availableFontFamilies.sorted()
    case "theme": suggestions = TerminalTheme.names
    case "cursor_style": suggestions = ["block", "bar", "underline", "block_hollow"]
    default: break
    }
    if setting.table == "interface", setting.key == "theme" { suggestions = ["auto", "light", "dark"] }
    if value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") { suggestions = [] }
    choices.addItems(withObjectValues: suggestions)
    choices.stringValue = normalized
    choices.isHidden = suggestions.isEmpty
    value.isHidden = !choices.isHidden
    number.isHidden = Double(normalized).map { !$0.isFinite } ?? true
    if let numeric = Double(normalized), numeric.isFinite {
      number.doubleValue = numeric; number.increment = normalized.contains(".") ? 0.1 : 1
    }
    let swatch = normalized.hasPrefix("#") ? NSColor(hex: normalized) : nil
    color.isHidden = swatch == nil
    if let swatch { color.color = swatch }
    let repeatable = setting.table == "terminal" && TerminalSettings.repeatable.contains(setting.key.replacingOccurrences(of: "_", with: "-"))
    addEntry.isHidden = !repeatable; removeEntry.isHidden = !repeatable
    if repeatable { enabled.isHidden = true }
    reset.isHidden = false
  }
  /// Describe the setting: its effective value, this file's override and where it was loaded from.
  private func showDetail(for setting: Setting, fallback: String) {
    let config = appOwner?.runtime?.settings
    let key = setting.key.replacingOccurrences(of: "_", with: "-")
    let sources = setting.table == "interface" ? [config?.interfaceSources[setting.key]?.path].compactMap { $0 } : config?.options.filter { $0.key == key }.compactMap { $0.source?.path } ?? []
    var effective = fallback
    if setting.table == "interface" { effective = config?.interface[setting.key] ?? NamespaceAppearance.defaults[setting.key] ?? fallback }
    else if key == "theme" { effective = config?.options.last { $0.key == "theme" }?.value ?? TerminalTheme.defaultSelection }
    else if let config = appOwner?.runtime?.config, let raw = key.withCString({ velokit_config_format(config, $0) }) { effective = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines) }
    let newTerminal = ["command", "initial_command", "working_directory", "env", "shell_integration", "term"].contains(setting.key)
    let effect = newTerminal ? "Applies to new terminals; herdr owns existing processes." : "Reload applies supported changes to open terminals. Window creation options apply to new windows."
    let override = configDocument.value(table: setting.table, key: setting.key).map { String($0.prefix(90)) } ?? "None in this file"
    detail.stringValue = setting.table + "." + setting.key + "\n" + setting.summary
      + "\nEffective: " + String(effective.prefix(160)) + "\nFile override: " + override
      + "\nSource: " + (sources.last ?? "Built-in default") + "\n" + effect
    detail.toolTip = "Default: " + fallback + "\nEffective: " + effective + "\nSources in load order: " + sources.joined(separator: " → ")
  }
  func textDidChange(_ notification: Notification) {
    configDocument.text = editor.string
    window?.isDocumentEdited = configDocument.hasChanges
  }
  @objc private func stepValue() { value.stringValue = String(format: "%g", number.doubleValue); applyValue() }
  @objc private func colorValue() {
    guard let rgb = color.color.usingColorSpace(.sRGB) else { return }
    value.stringValue = String(format: "\"#%02X%02X%02X\"", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    applyValue()
  }
  private func entries() throws -> [String] {
    guard filtered.indices.contains(table.selectedRow) else { return [] }
    return try AppConfiguration.entries(fromTOML: value.stringValue)
  }
  private func setEntries(_ values: [String]) {
    value.stringValue = "[" + values.map(ConfigurationDocument.quote).joined(separator: ", ") + "]"
    choices.isHidden = true; value.isHidden = false; applyValue()
  }
  @objc private func appendEntry() {
    guard let window, filtered.indices.contains(table.selectedRow) else { return }
    let alert = NSAlert(); alert.messageText = "Add " + filtered[table.selectedRow].key.replacingOccurrences(of: "_", with: " ")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = filtered[table.selectedRow].key == "keybind" ? "super+shift+t=new_tab" : "Entry value"
    alert.accessoryView = field; alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      do { self.setEntries(try self.entries() + [field.stringValue]) } catch { self.showError(error) }
    }
    window.attachedSheet?.makeFirstResponder(field)
  }
  @objc private func deleteEntry() {
    guard let window else { return }
    let values: [String]
    do { values = try entries() } catch { showError(error); return }
    guard !values.isEmpty else { return }
    let alert = NSAlert(); alert.messageText = "Remove Entry"
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); picker.addItems(withTitles: values)
    alert.accessoryView = picker; alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, values.indices.contains(picker.indexOfSelectedItem) else { return }
      var updated = values; updated.remove(at: picker.indexOfSelectedItem); self?.setEntries(updated)
    }
  }
  @objc private func showDiagnostics() {
    guard let window else { return }
    let messages = appOwner?.runtime?.settings.diagnostics ?? []
    let alert = NSAlert(); alert.messageText = messages.isEmpty ? "No configuration warnings" : "Configuration warnings"
    alert.informativeText = messages.joined(separator: "\n"); alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
  }

  @objc private func chooseValue() { value.stringValue = ConfigurationDocument.quote(choices.stringValue) }
  @objc private func resetValue() {
    guard filtered.indices.contains(table.selectedRow) else { return }
    let setting = filtered[table.selectedRow]
    do {
      try configDocument.removeValue(table: setting.table, key: setting.key)
      editor.string = configDocument.text; window?.isDocumentEdited = configDocument.hasChanges
      refreshControls()
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
      let fragment = try AppConfiguration.parseFragment(table: setting.table, key: setting.key, value: value.stringValue, source: configDocument.url)
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
      if let config = appOwner?.runtime?.settings {
        let edited = configDocument.url
        files = [config.source] + config.sourceFiles.filter { $0 != config.source }
        if !files.contains(edited) { files.append(edited) }
        filePicker.removeAllItems(); filePicker.addItems(withTitles: files.map(\.path))
        currentFile = files.firstIndex(of: edited) ?? 0; filePicker.selectItem(at: currentFile)
      }
      let diagnostics = appOwner?.runtime?.settings.diagnostics ?? []
      status.textColor = diagnostics.isEmpty ? .secondaryLabelColor : .systemOrange
      status.stringValue = diagnostics.isEmpty ? "Saved. Process settings apply to new terminals." : "Saved with configuration warnings. " + diagnostics.joined(separator: "\n")
      status.toolTip = status.stringValue
      refreshControls()
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
      refreshControls()
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
  private let message = NSTextField(wrappingLabelWithString: "Local servers start automatically. SSH connections use your keys and known hosts; start herdr on the destination first.")
  private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
  private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
  private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  private let tabButton = NSButton(title: "New Tab", target: nil, action: nil)
  private var rows: [HerdrConnection] = []
  private var timer: Timer?
  init(owner: AppDelegate) {
    self.appOwner = owner
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Herdr Connections"; window.minSize = NSSize(width: 720, height: 320); window.center()
    let root = NSView(); window.contentView = root
    for (id, title, width) in [("enabled", "Enabled", 65.0), ("name", "Connection", 270.0), ("status", "Status", 260.0)] {
      let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
    }
    table.dataSource = self; table.delegate = self; table.rowHeight = 44
    table.setAccessibilityLabel("Herdr connections")
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
    let add = NSButton(title: "Add…", target: self, action: #selector(addConnection))
    editButton.target = self; editButton.action = #selector(editConnection)
    removeButton.target = self; removeButton.action = #selector(removeConnection)
    retryButton.target = self; retryButton.action = #selector(retry)
    tabButton.target = self; tabButton.action = #selector(newTab)
    let source = NSButton(title: "Open Config…", target: self, action: #selector(editConfig))
    let buttons = NSStackView(views: [add, editButton, removeButton, retryButton, tabButton, source]); buttons.spacing = 8
    table.target = self; table.doubleAction = #selector(editConnection)
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
    rows = appOwner?.herdr == nil ? (appOwner?.runtime?.settings.connections ?? [.local]) : (appOwner?.connections ?? []); table.reloadData()
    if let index = rows.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    if rows.isEmpty, message.textColor != .systemRed { message.stringValue = "No connections configured. Add a local server or an SSH destination to get started." }
    if appOwner?.herdr == nil, message.textColor != .systemRed { message.stringValue = "Install herdr and relaunch to connect. You can configure instances now." }
    updateButtons()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let profile = rows[row]
    if column?.identifier.rawValue == "enabled" {
      let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleConnection(_:)))
      toggle.state = profile.enabled ? .on : .off; toggle.identifier = NSUserInterfaceItemIdentifier(profile.id)
      toggle.setAccessibilityLabel("Enable " + profile.label); return toggle
    }
    if column?.identifier.rawValue == "name" {
      let title = NSTextField(labelWithString: profile.label); title.font = .systemFont(ofSize: 12, weight: .medium)
      let subtitle = NSTextField(labelWithString: (profile.target ?? "Local") + " · " + profile.session)
      subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
      for label in [title, subtitle] { label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
      let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
      let icon = NSImageView(image: NSImage(systemSymbolName: profile.target == nil ? "desktopcomputer" : "network", accessibilityDescription: profile.target == nil ? "Local" : "SSH")!)
      icon.contentTintColor = .secondaryLabelColor; icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
      let row = NSStackView(views: [icon, labels]); row.spacing = 8; row.alignment = .centerY
      row.toolTip = profile.label + "\n" + subtitle.stringValue + "\nID: " + profile.id
      return row
    }
    let text = appOwner?.connectionStatus[profile.id]?.description ?? (profile.enabled ? "Not connected" : "Disabled")
    let label = NSTextField(wrappingLabelWithString: text); label.maximumNumberOfLines = 2; label.toolTip = text
    label.font = .systemFont(ofSize: 12); label.textColor = profile.enabled ? .labelColor : .secondaryLabelColor
    return label
  }
  func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
  private func updateButtons() {
    let profile = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    editButton.isEnabled = profile != nil; removeButton.isEnabled = profile != nil
    let available = profile?.enabled == true && appOwner?.herdr != nil
    retryButton.isEnabled = available; tabButton.isEnabled = available
    if let profile, case .connecting = appOwner?.connectionStatus[profile.id] {
      retryButton.isEnabled = false; tabButton.isEnabled = false
    }
  }
  private func save(_ updated: [HerdrConnection]) throws {
    guard let owner = appOwner, let config = owner.runtime?.settings else { return }
    let fresh = AppConfiguration.load(from: config.source, home: config.home)
    guard (fresh.connections ?? [.local]) == rows else {
      throw ConfigurationError("Connections changed on disk. Reload configuration before editing them.")
    }
    let source = try fresh.sourceFiles.reversed().first { file in
      try AppConfiguration.parse(Data(contentsOf: file), source: file).connections != nil
    } ?? config.source
    let document = try ConfigurationDocument(url: source)
    try document.setConnections(updated); try document.save()
    owner.reloadConfiguration(nil)
    message.textColor = .secondaryLabelColor
    message.stringValue = "Saved to " + source.path
    message.toolTip = message.stringValue
    refresh()
  }
  private func showError(_ error: Error) {
    message.stringValue = error.localizedDescription; message.toolTip = message.stringValue; message.textColor = .systemRed
  }
  @objc private func toggleConnection(_ sender: NSButton) {
    guard let index = rows.firstIndex(where: { $0.id == sender.identifier?.rawValue }) else { return }
    var updated = rows; updated[index].enabled = sender.state == .on
    do { try save(updated) } catch { showError(error); refresh() }
  }
  @objc private func addConnection() { edit(nil) }
  @objc private func editConnection() {
    guard rows.indices.contains(table.selectedRow) else { return }; edit(rows[table.selectedRow])
  }
  private func edit(_ existing: HerdrConnection?) {
    let alert = NSAlert(); alert.messageText = existing == nil ? "Add Herdr Connection" : "Edit Herdr Connection"
    alert.informativeText = "Changing the host or session creates a new identity. Existing terminals retain their original connection."
    let identity = NSTextField(string: existing?.id ?? UUID().uuidString.lowercased())
    identity.isEditable = existing == nil; identity.isSelectable = true
    identity.toolTip = "Reuse a removed connection’s ID to recover its saved panes."
    let name = NSTextField(string: existing?.label ?? "")
    let type = NSPopUpButton(); type.addItems(withTitles: ["Local", "Remote (SSH)"]); type.selectItem(at: existing?.target == nil ? 0 : 1)
    let host = NSTextField(string: existing?.target ?? ""); host.placeholderString = "user@host or SSH alias (remote only)"
    let session = NSTextField(string: existing?.session ?? "velocitty")
    let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil); enabled.state = existing?.enabled == false ? .off : .on
    let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 8
    for (label, control) in [("Name", name as NSView), ("Location", type), ("SSH destination", host), ("Herdr session", session), ("Connection ID", identity)] {
      form.addArrangedSubview(NSTextField(labelWithString: label)); form.addArrangedSubview(control)
      control.widthAnchor.constraint(equalToConstant: 380).isActive = true
      control.setAccessibilityLabel(label)
    }
    form.addArrangedSubview(enabled); form.frame = NSRect(x: 0, y: 0, width: 380, height: 355)
    alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
    while alert.runModal() == .alertFirstButtonReturn {
      let target = type.indexOfSelectedItem == 1 ? host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
      let sessionName = session.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let sameEndpoint = existing?.target == target && existing?.session == sessionName
      let profile = HerdrConnection(id: existing == nil ? identity.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : sameEndpoint ? existing!.id : UUID().uuidString.lowercased(),
        label: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), session: sessionName, target: target, enabled: enabled.state == .on)
      do {
        try profile.validate()
        var updated = rows
        if let existing, let index = updated.firstIndex(where: { $0.id == existing.id }) {
          if profile.id == existing.id { updated[index] = profile }
          else { updated.remove(at: index); updated.append(profile) }
        }
        else { updated.append(profile) }
        try save(updated); return
      } catch { alert.informativeText = error.localizedDescription }
    }
  }
  @objc private func removeConnection() {
    guard rows.indices.contains(table.selectedRow), let window else { return }
    let profile = rows[table.selectedRow]
    let alert = NSAlert(); alert.messageText = "Remove “" + profile.label + "”?"
    alert.informativeText = "Its terminals keep running. Saved panes remain unavailable until this connection is restored with the same ID: " + profile.id
    alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      do { try self.save(self.rows.filter { $0.id != profile.id }) } catch { self.showError(error) }
    }
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
  @objc private func editConfig() {
    guard let file = appOwner?.runtime?.settings.source else { return }
    ConfigurationEditor().open(file) { [weak self] error in if let error { self?.message.stringValue = error.localizedDescription } }
  }
}

final class ThemePickerWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private weak var appOwner: AppDelegate?
  private let themeDocument: ConfigurationDocument
  private let configuration: AppConfiguration
  private let table = NSTableView()
  private let search = NSSearchField()
  private let mode = NSPopUpButton()
  private let variant = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
  private let preview = NSTextView()
  private let selection = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let apply = NSButton(title: "Apply Theme", target: nil, action: nil)
  private var themes: [String] = []
  private var filtered: [String] = []
  private var single = "Rose Pine"
  private var light = "Rose Pine Dawn"
  private var dark = "Rose Pine"
  private var selecting = false

  init(owner: AppDelegate) throws {
    appOwner = owner
    configuration = owner.runtime?.settings ?? AppConfiguration.load()
    let setting = configuration.options.last { $0.key == "theme" }
    themeDocument = try ConfigurationDocument(url: setting?.source ?? configuration.source)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Terminal Themes"; window.minSize = NSSize(width: 740, height: 440); window.center()
    mode.addItems(withTitles: ["Single theme", "Follow system appearance"])
    let current = setting?.value ?? TerminalTheme.defaultSelection
    if current.hasPrefix("light:") || current.hasPrefix("dark:") {
      for part in current.split(separator: ",") {
        let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if pair.count == 2, pair[0] == "light" { light = pair[1] }
        if pair.count == 2, pair[0] == "dark" { dark = pair[1] }
      }
      mode.selectItem(at: 1)
    } else { single = current }
    variant.selectedSegment = NSApp.effectiveAppearance.isDark ? 1 : 0
    let customDirectory = themeDocument.url.deletingLastPathComponent().appendingPathComponent("themes")
    let custom = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil))?
      .filter { $0.pathExtension == "itermcolors" }.map { $0.deletingPathExtension().lastPathComponent } ?? []
    themes = Array(Set(TerminalTheme.names + custom + [single, light, dark])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let root = NSView(); window.contentView = root
    search.placeholderString = "Search themes"; search.delegate = self; search.target = self; search.action = #selector(filterThemes)
    mode.target = self; mode.action = #selector(updateThemeMode)
    variant.target = self; variant.action = #selector(updateThemeMode)
    apply.target = self; apply.action = #selector(saveTheme); apply.keyEquivalent = "\r"
    let close = NSButton(title: "Cancel", target: self, action: #selector(cancel)); close.keyEquivalent = "\u{1b}"
    let column = NSTableColumn(identifier: .init("theme")); table.addTableColumn(column)
    table.headerView = nil; table.style = .sourceList; table.rowHeight = 28
    table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("Terminal themes")
    let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
    preview.isEditable = false; preview.isSelectable = true; preview.isRichText = true
    preview.textContainerInset = NSSize(width: 20, height: 20); preview.autoresizingMask = [.width, .height]
    preview.setAccessibilityLabel("Theme preview")
    let sample = NSScrollView(); sample.documentView = preview; sample.hasVerticalScroller = true
    selection.font = .systemFont(ofSize: 12); selection.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
    status.stringValue = "Preview only until applied. Explicit terminal colors override theme colors."
    for view in [mode, variant, search, list, sample, selection, status, apply, close] {
      root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      mode.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), mode.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
      variant.leadingAnchor.constraint(equalTo: mode.trailingAnchor, constant: 12), variant.centerYAnchor.constraint(equalTo: mode.centerYAnchor),
      search.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 14), search.leadingAnchor.constraint(equalTo: mode.leadingAnchor), search.widthAnchor.constraint(equalToConstant: 235),
      list.leadingAnchor.constraint(equalTo: search.leadingAnchor), list.trailingAnchor.constraint(equalTo: search.trailingAnchor), list.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), list.bottomAnchor.constraint(equalTo: apply.topAnchor, constant: -16),
      sample.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16), sample.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), sample.topAnchor.constraint(equalTo: search.topAnchor), sample.bottomAnchor.constraint(equalTo: selection.topAnchor, constant: -10),
      selection.leadingAnchor.constraint(equalTo: sample.leadingAnchor), selection.trailingAnchor.constraint(equalTo: sample.trailingAnchor), selection.bottomAnchor.constraint(equalTo: list.bottomAnchor), selection.heightAnchor.constraint(equalToConstant: 38),
      apply.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), apply.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      close.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8), close.centerYAnchor.constraint(equalTo: apply.centerYAnchor),
      status.leadingAnchor.constraint(equalTo: list.leadingAnchor), status.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -12), status.centerYAnchor.constraint(equalTo: apply.centerYAnchor), status.heightAnchor.constraint(lessThanOrEqualToConstant: 44),
    ])
    updateThemeMode()
    window.makeFirstResponder(search)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private var chosen: String { mode.indexOfSelectedItem == 0 ? single : variant.selectedSegment == 0 ? light : dark }
  private var value: String { mode.indexOfSelectedItem == 0 ? single : "light:" + light + ",dark:" + dark }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard filtered.indices.contains(row) else { return nil }
    return NSTextField(labelWithString: filtered[row].isEmpty ? "None (engine defaults)" : filtered[row])
  }
  func controlTextDidChange(_ notification: Notification) { filterThemes() }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
      guard !filtered.isEmpty else { return true }
      let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let row = min(filtered.count - 1, max(0, table.selectedRow + delta))
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row); return true
    }
    if selector == #selector(NSResponder.insertNewline(_:)), apply.isEnabled { saveTheme(); return true }
    if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
    return false
  }
  @objc private func filterThemes() {
    selecting = true
    filtered = themes.filter { mode.indexOfSelectedItem == 0 || !$0.isEmpty }.filter { search.stringValue.isEmpty || $0.localizedCaseInsensitiveContains(search.stringValue) }
    table.reloadData()
    if let row = filtered.firstIndex(of: chosen) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    else { table.deselectAll(nil) }
    selecting = false
  }
  @objc private func updateThemeMode() { variant.isHidden = mode.indexOfSelectedItem == 0; filterThemes(); renderPreview() }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !selecting, filtered.indices.contains(table.selectedRow) else { return }
    let name = filtered[table.selectedRow]
    if mode.indexOfSelectedItem == 0 { single = name }
    else if variant.selectedSegment == 0 { light = name } else { dark = name }
    renderPreview()
  }
  private func renderPreview() {
    var diagnostics: [String] = []
    do {
      let config = try AppConfiguration.parseFragment(table: "terminal", key: "theme", value: ConfigurationDocument.quote(chosen), home: configuration.home, source: themeDocument.url)
      let options = try TerminalTheme.options(for: config, dark: variant.selectedSegment == 1) { diagnostics.append($0) }
      guard diagnostics.isEmpty else { throw ConfigurationError(diagnostics.joined(separator: "\n")) }
      preview.backgroundColor = NSColor(hex: options.last { $0.key == "background" }?.value) ?? .black
      preview.textStorage?.setAttributedString(previewText(options: options))
      selection.stringValue = mode.indexOfSelectedItem == 0 ? "Theme: " + (single.isEmpty ? "None" : single) : "Light: " + light + "\nDark: " + dark
      apply.isEnabled = true
      status.textColor = .secondaryLabelColor; status.stringValue = "Preview only until applied. Explicit terminal colors override theme colors."
    } catch {
      preview.string = "Preview unavailable"; preview.textColor = .secondaryLabelColor
      apply.isEnabled = false; status.textColor = .systemRed; status.stringValue = error.localizedDescription
      status.toolTip = status.stringValue
    }
  }
  /// A sample terminal session drawn in the theme's foreground and palette colors.
  private func previewText(options: [TerminalOption]) -> NSAttributedString {
    func color(_ hex: String?, fallback: NSColor) -> NSColor { NSColor(hex: hex) ?? fallback }
    let foreground = color(options.last { $0.key == "foreground" }?.value, fallback: .white)
    let text = NSMutableAttributedString()
    func append(_ string: String, _ tint: NSColor = .white) {
      text.append(NSAttributedString(string: string, attributes: [.foregroundColor: tint, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
    }
    let palette = (0..<16).map { index in
      color(options.last { $0.key == "palette" && $0.value.hasPrefix("\(index)=") }?.value.split(separator: "=").last.map(String.init), fallback: foreground)
    }
    append((chosen.isEmpty ? "Engine defaults" : chosen) + "\n\n", foreground)
    append("~/workspace/velocitty ", palette[4]); append("main\n", palette[2])
    append("❯ ", palette[5]); append("just build\n", foreground)
    append("✓ Build completed\n\n", palette[2])
    append("const ", palette[5]); append("session", foreground); append(" = ", palette[6]); append("\"velocitty\";\n", palette[3])
    append("// Your agents, one window.\n\n", palette[8])
    append("Error  ", palette[1]); append("Warning  ", palette[3]); append("Success\n\n", palette[2])
    for row in 0..<2 { for index in row*8..<row*8+8 { append("██ ", palette[index]) }; append("\n") }
    return text
  }
  @objc private func saveTheme() {
    do {
      let fresh = AppConfiguration.load(from: configuration.source, home: configuration.home)
      let previous = configuration.options.last { $0.key == "theme" }
      let latest = fresh.options.last { $0.key == "theme" }
      guard previous?.value == latest?.value && previous?.source == latest?.source else {
        throw ConfigurationError("The theme changed on disk. Reopen the picker to load the latest selection.")
      }
      let candidate = try AppConfiguration.parseFragment(table: "terminal", key: "theme", value: ConfigurationDocument.quote(value), home: configuration.home, source: themeDocument.url)
      var diagnostics: [String] = []
      for dark in [false, true] { _ = try TerminalTheme.options(for: candidate, dark: dark) { diagnostics.append($0) } }
      guard diagnostics.isEmpty else { throw ConfigurationError(diagnostics.joined(separator: "\n")) }
      try themeDocument.setValue(table: "terminal", key: "theme", toml: ConfigurationDocument.quote(value))
      try themeDocument.save(); appOwner?.reloadConfiguration(nil); close()
    } catch { status.textColor = .systemRed; status.stringValue = error.localizedDescription; status.toolTip = status.stringValue }
  }
  @objc private func cancel() { close() }
}
