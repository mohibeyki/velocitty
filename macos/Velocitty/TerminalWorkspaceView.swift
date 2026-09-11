// SPDX-License-Identifier: GPL-3.0
import AppKit
import QuartzCore
import VelocittyConfiguration

// Window navigation is independent of the terminal views inside each tab.
final class TerminalWorkspaceView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate {
  weak var controller: TerminalWindowController?
  var muxEnabled: Bool { controller?.session?.herdrTerminal != nil }
  var chromeIsDark: Bool {
    switch controller?.session?.settings.interface["theme"] ?? "dark" {
    case "light": return false
    case "auto": return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    default: return true
    }
  }
  var appearanceValues: [String: String] {
    var defaults = NamespaceAppearance.defaults
    if !chromeIsDark {
      defaults.merge(["chrome_background_color": "#F0F0F0", "chrome_foreground_color": "#242424",
        "chrome_selected_color": "#FFFFFF", "chrome_border_color": "#BBBBBB"]) { _, new in new }
    }
    return defaults.merging(controller?.session?.settings.interface ?? [:]) { _, custom in custom }
  }
  func chromeColor(_ key: String) -> NSColor {
    let hex = UInt32((appearanceValues[key] ?? NamespaceAppearance.defaults[key] ?? "#000000").dropFirst(), radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
      green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
  func metric(_ key: String) -> CGFloat { CGFloat(Double(appearanceValues[key] ?? "") ?? Double(NamespaceAppearance.defaults[key] ?? "") ?? 0) }
  private var paneDividers: [PaneDivider] = []
  private var displayedNamespaces: [TerminalNamespace] = []
  private let splitView = WorkspaceSplitView()
  private let sidebar = NSVisualEffectView()
  private let content = NSView()
  private let toggleSidebar = NSButton()
  private var sidebarCompact = false
  private var sidebarAnimation: Timer?
  private var animatedSidebarWidth: CGFloat?
  private var configuredWidth: CGFloat = 0
  private var expandedSidebarWidth: CGFloat?
  private var refreshingNamespaces = false
  var sidebarInset: CGFloat { muxEnabled ? sidebar.frame.width + splitView.dividerThickness : 0 }
  struct Agent: Equatable {
    let name: String
    let status: String
  }
  var agents: [String: Agent] = [:]
  private var paneTitles: [String: String] = [:]
  private var paneDirectories: [String: String] = [:]
  private var branches: [String: String] = [:]
  private var remoteBranches: [String: String] = [:]
  private var remoteBranchChecks: [String: TimeInterval] = [:]
  private var pollingBranches = false
  private var branchPaths: Set<String> = []
  private var branchesCheckedAt = -Double.infinity
  private var gitWatchers: [String: DispatchSourceFileSystemObject] = [:]
  private var gitRefresh: Timer?
  private var agentTimer: Timer?
  private var pollingAgents = false
  private var lastAgentPoll = -Double.infinity

  var showsTabBar: Bool {
    guard muxEnabled else { return false }
    switch controller?.native.tabBarVisibility ?? "auto" {
    case "never": return false
    case "always": return true
    default: return (controller?.tabs.count ?? 0) > 1
    }
  }
  var tabHeight: CGFloat { showsTabBar ? 34 : 0 }
  let namespaceScroll = NSScrollView()
  let namespaceList = NSOutlineView()
  private let tabMaterial = NSVisualEffectView()
  let tabScroll = NSScrollView()
  let tabButtons = NSStackView()
  let addTab = NSButton(title: "+", target: nil, action: nil)
  let panes = NSView()

  init(controller: TerminalWindowController) {
    self.controller = controller
    super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    autoresizingMask = [.width, .height]
    wantsLayer = true
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.delegate = self
    splitView.frame = bounds
    splitView.autoresizingMask = [.width, .height]
    sidebar.material = .titlebar
    sidebar.blendingMode = .behindWindow
    sidebar.state = .followsWindowActiveState
    sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: bounds.height)
    content.frame = NSRect(x: 221, y: 0, width: bounds.width - 221, height: bounds.height)
    splitView.addArrangedSubview(sidebar)
    splitView.addArrangedSubview(content)
    addSubview(splitView)
    content.addSubview(panes)
    tabScroll.documentView = tabButtons
    tabScroll.drawsBackground = false
    tabScroll.hasHorizontalScroller = true
    tabScroll.autohidesScrollers = true
    tabButtons.orientation = .horizontal
    tabButtons.spacing = 0
    tabMaterial.material = .titlebar
    tabMaterial.blendingMode = .behindWindow
    tabMaterial.state = .followsWindowActiveState
    content.addSubview(tabMaterial)
    content.addSubview(tabScroll)
    content.addSubview(addTab)
    addTab.target = self
    addTab.action = #selector(createTab)
    addTab.toolTip = "New Tab"
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("namespace"))
    column.minWidth = 20
    namespaceList.addTableColumn(column)
    namespaceList.outlineTableColumn = column
    namespaceList.headerView = nil
    namespaceList.style = .sourceList
    namespaceList.backgroundColor = .clear
    namespaceList.intercellSpacing = NSSize(width: 0, height: 6)
    namespaceList.indentationPerLevel = 0
    namespaceList.allowsEmptySelection = false
    namespaceList.dataSource = self
    namespaceList.delegate = self
    namespaceList.setAccessibilityLabel("Namespaces")
    namespaceScroll.documentView = namespaceList
    namespaceScroll.hasVerticalScroller = true
    namespaceScroll.autohidesScrollers = true
    namespaceScroll.drawsBackground = false
    sidebar.addSubview(namespaceScroll)
    toggleSidebar.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
    toggleSidebar.target = self
    toggleSidebar.action = #selector(toggleNamespaceSidebar)
    toggleSidebar.refusesFirstResponder = true
    addTab.refusesFirstResponder = true
    toggleSidebar.toolTip = "Compact Sidebar"
    content.addSubview(toggleSidebar)
    for button in [addTab, toggleSidebar] {
      button.isBordered = false
      button.font = .systemFont(ofSize: 14)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { agentTimer?.invalidate(); sidebarAnimation?.invalidate(); gitRefresh?.invalidate(); gitWatchers.values.forEach { $0.cancel() } }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    agentTimer?.invalidate()
    agentTimer = nil
    if window != nil {
      pollAgents()
      agentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollAgents() }
    }
  }

  private func pollAgents() {
    guard !pollingAgents, let controller, !controller.muxBusy,
      window?.isVisible == true, NSApp.isActive,
      let client = controller.session?.herdrTerminal?.client else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastAgentPoll >= (client.eventsConnected ? 10 : 2) else { return }
    lastAgentPoll = now
    pollingAgents = true
    let clients = controller.allPanes.compactMap { $0.herdrTerminal?.client }.filter(\.isEnabled).reduce(into: [String: HerdrClient]()) { $0[$1.endpointID] = $1 }.values
    var remaining = clients.count
    if remaining == 0 { pollingAgents = false; return }
    for client in clients {
      client.perform({ try $0.statusSnapshot() }) { [weak self, weak client] result in
        guard let self, let client else { return }
        remaining -= 1
        if remaining == 0 { self.pollingAgents = false }
        switch result {
        case .success(let snapshot):
          guard self.controller?.closing == false, self.controller?.owner?.terminating != true else { return }
          self.controller?.owner?.synchronizeHerdr(snapshot, client: client)
          self.updateAgents(snapshot)
          self.applyPolledLayouts(snapshot)
        case .failure:
          let stale = self.agents.mapValues { $0 }
          for (id, agent) in stale where client.owns(id) { self.agents[id] = Agent(name: agent.name, status: "unknown") }
          self.refreshTabs()
        }
      }
    }
  }

  func updateAgents(_ snapshot: HerdrClient.Snapshot) {
    let belongs: (String) -> Bool = { id in
      guard let endpoint = snapshot.endpointID, endpoint != "local" else { return !id.contains("::") }
      return id.hasPrefix(endpoint + "::")
    }
    var updated = agents.filter { !belongs($0.key) }
    for pane in snapshot.panes {
      guard let name = [pane.display_agent, pane.agent].compactMap({ $0 })
        .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
      updated[pane.pane_id] = Agent(name: name, status: pane.agent_status ?? "unknown")
    }
    var titles = paneTitles.filter { !belongs($0.key) }
    var directories = paneDirectories.filter { !belongs($0.key) }
    for pane in snapshot.panes {
      titles[pane.pane_id] = pane.terminal_title_stripped ?? pane.terminal_title
      directories[pane.pane_id] = pane.foreground_cwd ?? pane.cwd
    }
    pollBranches(directories: directories)
    for namespace in controller?.namespaces ?? [] {
      guard let terminal = namespace.selected.selected.herdrTerminal, terminal.client.machine != nil else { continue }
      let path = directories[terminal.pane.pane_id] ?? directory(for: namespace)
      let key = terminal.client.endpointID + "::" + path
      let now = ProcessInfo.processInfo.systemUptime
      guard now - (remoteBranchChecks[key] ?? -Double.infinity) >= 60 else { continue }
      remoteBranchChecks[key] = now
      terminal.client.perform({ try $0.gitBranch(directory: path) }) { [weak self] result in
        guard let self else { return }
        if case .success(let branch) = result { self.remoteBranches[key] = branch }
        else { self.remoteBranches[key] = nil }
        if let controller = self.controller { self.refreshNamespaces(controller) }
      }
    }
    guard updated != agents || titles != paneTitles || directories != paneDirectories else { return }
    let previousTitles = controller?.tabs.map { title(for: $0) }
    paneTitles = titles
    paneDirectories = directories
    agents = updated
    if previousTitles != controller?.tabs.map({ title(for: $0) }) { refreshTabs() }
    else if let controller { refreshNamespaces(controller) }
  }

  private func branch(for namespace: TerminalNamespace) -> String? {
    let path = directory(for: namespace)
    if let client = namespace.selected.selected.herdrTerminal?.client, client.machine != nil {
      return remoteBranches[client.endpointID + "::" + path]
    }
    return branches[path]
  }

  private func directory(for namespace: TerminalNamespace) -> String {
    let pane = namespace.selected.selected
    return paneDirectories[pane.herdrTerminal?.pane.pane_id ?? ""] ?? pane.currentDirectory
      ?? pane.initialDirectory?.path ?? pane.settings.workingDirectory.path
  }

  private func pollBranches(directories: [String: String]) {
    guard !pollingBranches, let controller else { return }
    let paths = Set(controller.namespaces.filter { $0.selected.selected.herdrTerminal?.client.machine == nil }.map { namespace in
      directories[namespace.selected.selected.herdrTerminal?.pane.pane_id ?? ""] ?? directory(for: namespace)
    })
    let now = ProcessInfo.processInfo.systemUptime
    guard paths != branchPaths || now - branchesCheckedAt >= 60 else { return }
    branchPaths = paths
    branchesCheckedAt = now
    pollingBranches = true
    DispatchQueue.global(qos: .utility).async { [weak self] in
      var results: [String: String] = [:]
      var metadataPaths: Set<String> = []
      for path in paths {
        func git(_ arguments: [String]) -> String? {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
          process.arguments = ["--no-optional-locks", "-C", path] + arguments
          process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
          let output = Pipe()
          process.standardOutput = output
          process.standardError = FileHandle.nullDevice
          process.standardInput = FileHandle.nullDevice
          do { try process.run() } catch { return nil }
          let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
          DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
          let data = output.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          timeout.cancel()
          guard process.terminationStatus == 0 else { return nil }
          let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          return value.isEmpty ? nil : value
        }
        if let directory = git(["rev-parse", "--absolute-git-dir"]) { metadataPaths.insert(directory) }
        else { metadataPaths.insert(path) }
        if let branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"]) { results[path] = branch }
        else if let commit = git(["rev-parse", "--short", "HEAD"]) { results[path] = "Detached · " + commit }
      }
      let updated = results
      let watched = metadataPaths
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pollingBranches = false
        self.watchGitMetadata(watched)
        if self.branches != updated {
          self.branches = updated
          if let controller = self.controller { self.refreshNamespaces(controller) }
        }
      }
    }
  }

  private func watchGitMetadata(_ paths: Set<String>) {
    for path in Array(gitWatchers.keys) where !paths.contains(path) { gitWatchers.removeValue(forKey: path)?.cancel() }
    for path in paths where gitWatchers[path] == nil {
      let fd = open(path, O_EVTONLY)
      guard fd >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
      source.setCancelHandler { Darwin.close(fd) }
      source.setEventHandler { [weak self] in
        guard let self else { return }
        if self.gitWatchers[path]?.data.contains(.rename) == true || self.gitWatchers[path]?.data.contains(.delete) == true {
          self.gitWatchers.removeValue(forKey: path)?.cancel()
        }
        self.gitRefresh?.invalidate()
        self.gitRefresh = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
          guard let self else { return }
          self.branchesCheckedAt = -Double.infinity
          self.pollBranches(directories: self.paneDirectories)
        }
      }
      gitWatchers[path] = source
      source.resume()
    }
  }

  private func applyPolledLayouts(_ snapshot: HerdrClient.Snapshot) {
    guard let controller, !controller.muxBusy else { return }
    var changed = false
    for tab in controller.namespaces.flatMap(\.tabs) {
      guard let layout = snapshot.layouts.first(where: { $0.tab_id == tab.herdrID }),
        Set(layout.panes.map(\.pane_id)) == Set(tab.panes.compactMap { $0.herdrTerminal?.pane.pane_id }),
        layout != tab.layout else { continue }
      tab.layout = layout
      changed = true
    }
    if changed { needsLayout = true }
  }

  func agent(for pane: TerminalSession) -> Agent? {
    guard let id = pane.herdrTerminal?.pane.pane_id else { return nil }
    return agents[id]
  }

  func present() {
    let visible = controller?.visiblePanes ?? []
    let wanted = visible.compactMap(\.chrome)
    for view in panes.subviews where view is TerminalChrome && !wanted.contains(where: { $0 === view }) { view.removeFromSuperview() }
    for view in wanted where view.superview !== panes { panes.addSubview(view) }
    refreshTabs()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    for view in [tabMaterial, tabScroll, addTab, toggleSidebar] { view.isHidden = !showsTabBar }
    let hideSidebar = !muxEnabled
    if sidebar.isHidden != hideSidebar {
      sidebar.isHidden = hideSidebar
      if hideSidebar {
        splitView.removeArrangedSubview(sidebar)
        sidebar.removeFromSuperview()
      } else {
        splitView.insertArrangedSubview(sidebar, at: 0)
      }
      splitView.adjustSubviews()
    }
    let requestedWidth: CGFloat = sidebarCompact ? 56 : metric("sidebar_width")
    if let animatedSidebarWidth {
      splitView.setPosition(animatedSidebarWidth, ofDividerAt: 0)
    } else if muxEnabled && configuredWidth != requestedWidth {
      let restoredWidth = configuredWidth == 0 ? expandedSidebarWidth ?? requestedWidth : requestedWidth
      configuredWidth = requestedWidth
      splitView.setPosition(sidebarCompact ? 56 : min(restoredWidth, max(160, bounds.width - 320)), ofDividerAt: 0)
    }
    toggleSidebar.refusesFirstResponder = true
    addTab.refusesFirstResponder = true
    toggleSidebar.toolTip = sidebarCompact ? "Expand Sidebar" : "Compact Sidebar"
    toggleSidebar.setAccessibilityLabel(toggleSidebar.toolTip)
    let width = content.bounds.width
    let height = content.bounds.height
    tabMaterial.frame = NSRect(x: 0, y: height - tabHeight, width: width, height: tabHeight)
    toggleSidebar.frame = NSRect(x: 4, y: height - 29, width: 26, height: 24)
    tabScroll.frame = NSRect(x: 34, y: height - 32, width: max(0, width - 72), height: 30)
    let tabWidth = max(150, tabScroll.bounds.width / CGFloat(max(1, tabButtons.arrangedSubviews.count)))
    for item in tabButtons.arrangedSubviews {
      item.constraints.first { $0.identifier == "tabWidth" }?.constant = tabWidth
    }
    tabButtons.setFrameSize(NSSize(width: tabWidth * CGFloat(tabButtons.arrangedSubviews.count), height: 30))
    addTab.frame = NSRect(x: width - 34, y: height - 28, width: 30, height: 26)
    namespaceScroll.frame = sidebar.bounds
    panes.frame = NSRect(x: 0, y: 0, width: width, height: max(0, height - tabHeight))
    guard let controller else { return }
    if !paneDividers.contains(where: \.dragging) {
      paneDividers.forEach { $0.removeFromSuperview() }; paneDividers = []
    }
    for (position, tab) in controller.presentedTabs.enumerated() {
      var region = panes.bounds
      if controller.presentedTabs.count == 2 {
        let split = region.width * controller.companionRatio
        region = position == 0 ? NSRect(x: 0, y: 0, width: split - 3, height: region.height) : NSRect(x: split + 3, y: 0, width: region.width - split - 3, height: region.height)
      }
    let completeLayout = tab.layout.map { layout in
      layout.area.width > 0 && layout.area.height > 0 && layout.panes.count == tab.panes.count && tab.panes.allSatisfy { pane in
        layout.panes.contains { $0.pane_id == pane.herdrTerminal?.pane.pane_id && $0.rect.width > 0 && $0.rect.height > 0 }
      }
    } ?? false
    for (index, pane) in tab.panes.enumerated() {
      // A missing snapshot must never stack interactive terminals on top of one another.
      var frame = NSRect(x: CGFloat(index) * region.width / CGFloat(tab.panes.count), y: 0,
        width: region.width / CGFloat(tab.panes.count), height: region.height)
      if completeLayout, let layout = tab.layout, tab.panes.count > 1,
        let rect = layout.panes.first(where: { $0.pane_id == pane.herdrTerminal?.pane.pane_id })?.rect {
        let sx = region.width / max(1, CGFloat(layout.area.width))
        let sy = region.height / max(1, CGFloat(layout.area.height))
        frame = NSRect(x: CGFloat(rect.x - layout.area.x) * sx,
          y: region.height - CGFloat(rect.y - layout.area.y + rect.height) * sy,
          width: CGFloat(rect.width) * sx, height: CGFloat(rect.height) * sy).insetBy(dx: 2, dy: 2)
      }
      if tab.zoomed { frame = NSRect(origin: .zero, size: region.size) }
      frame.origin.x += region.minX
      frame.origin.y += region.minY
      pane.chrome?.frame = frame
    }
    layoutDividers(tab, region: region)
    }
    if controller.presentedTabs.count == 2, !paneDividers.contains(where: \.dragging) {
      let divider = PaneDivider()
      divider.vertical = true; divider.container = panes.bounds; divider.ratio = controller.companionRatio
      divider.frame = NSRect(x: panes.bounds.width * controller.companionRatio - 3, y: 0, width: 6, height: panes.bounds.height)
      divider.onCommit = { [weak self] ratio in
        guard let self, let controller = self.controller else { return }
        controller.companionRatio = ratio
        self.needsLayout = true
        controller.owner?.scheduleWorkspaceSave(controller)
      }
      panes.addSubview(divider); paneDividers.append(divider)
    }
    needsDisplay = true
  }

  private func layoutDividers(_ tab: TerminalTab, region: NSRect) {
    guard !paneDividers.contains(where: \.dragging) else { return }
    guard !tab.zoomed, tab.layout?.panes.count == tab.panes.count, let root = tab.layoutTree, tab.treeLayout == tab.layout, let tabID = tab.herdrID else { return }
    func visit(_ node: HerdrClient.LayoutNode, frame: NSRect, path: [Bool]) {
      guard let first = node.first, let second = node.second, let direction = node.direction else { return }
      let ratio = CGFloat(node.ratio ?? 0.5)
      let vertical = direction == "right"
      var firstFrame = frame, secondFrame = frame
      let divider = PaneDivider()
      divider.color = controller?.native.dividerColor ?? .separatorColor
      divider.vertical = vertical
      divider.ratio = Double(ratio)
      divider.container = frame
      if vertical {
        firstFrame.size.width *= ratio
        secondFrame.origin.x = firstFrame.maxX
        secondFrame.size.width = frame.width - firstFrame.width
        divider.frame = NSRect(x: firstFrame.maxX - 3, y: frame.minY, width: 6, height: frame.height)
      } else {
        firstFrame.size.height *= ratio
        firstFrame.origin.y = frame.maxY - firstFrame.height
        secondFrame.size.height = frame.height - firstFrame.height
        divider.frame = NSRect(x: frame.minX, y: firstFrame.minY - 3, width: frame.width, height: 6)
      }
      divider.onCommit = { [weak self] ratio in
        self?.controller?.setSplitRatio(tabID: tabID, path: path, ratio: ratio)
        self?.needsLayout = true
      }
      panes.addSubview(divider)
      paneDividers.append(divider)
      visit(first, frame: firstFrame, path: path + [false])
      visit(second, frame: secondFrame, path: path + [true])
    }
    visit(root, frame: region, path: [])
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let controller, controller.visiblePanes.count > 1, let chrome = controller.session?.chrome else { return }
    NSColor.controlAccentColor.setStroke()
    let path = NSBezierPath(rect: convert(chrome.bounds, from: chrome).insetBy(dx: -1, dy: -1))
    path.lineWidth = 2
    path.stroke()
  }
  func refreshTabs() {
    for view in tabButtons.arrangedSubviews { tabButtons.removeArrangedSubview(view); view.removeFromSuperview() }
    guard let controller else { return }
    controller.owner?.scheduleWorkspaceSave(controller)
    refreshNamespaces(controller)
    var contentWidth: CGFloat = 0
    for (index, tab) in controller.tabs.enumerated() {
      let label = title(for: tab)
      let item = WorkspaceTabItem(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
      item.selected = controller.activeTab === tab
      let button = WorkspaceActionButton(title: (tab.hasBell ? "● " : "") + label,
        target: nil, action: nil)
      button.isBordered = false
      button.alignment = .center
      button.font = .systemFont(ofSize: 12, weight: controller.activeTab === tab ? .medium : .regular)
      button.contentTintColor = controller.activeTab === tab ? .labelColor : .secondaryLabelColor
      button.lineBreakMode = .byTruncatingTail
      button.toolTip = label
      button.target = button
      button.action = #selector(WorkspaceActionButton.invoke)
      button.onPress = { [weak controller, weak tab] in
        if let tab { controller?.selectTab(tab) }
      }
      let width = min(220, max(150, button.intrinsicContentSize.width + 88))
      item.frame.size.width = width
      button.frame = NSRect(x: 44, y: 2, width: width - 88, height: 24)
      button.autoresizingMask = [.width]
      let close = WorkspaceActionButton(title: "", target: nil, action: nil)
      close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
      close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
      close.isBordered = false
      close.font = .systemFont(ofSize: 14)
      close.contentTintColor = .secondaryLabelColor
      close.toolTip = "Close \(label)"
      close.setAccessibilityLabel("Close tab \(index + 1): \(label)")
      close.frame = NSRect(x: 4, y: 2, width: 24, height: 24)
      close.target = close
      close.action = #selector(WorkspaceActionButton.invoke)
      close.onPress = { [weak controller, weak tab] in
        if let tab { controller?.closeTab(tab.selected) }
      }
      let shortcut = CommandPalette.formatShortcut(for: "goto_tab:\(index + 1)", config: controller.session?.config)
      let badge = WorkspaceActionButton(title: shortcut.isEmpty ? String(index + 1) : shortcut, target: nil, action: nil)
      badge.isBordered = false
      badge.font = .systemFont(ofSize: 10)
      badge.contentTintColor = .tertiaryLabelColor
      badge.alignment = .right
      badge.frame = NSRect(x: width - 44, y: 2, width: 38, height: 24)
      badge.autoresizingMask = [.minXMargin]
      badge.toolTip = "Switch to tab \(index + 1)" + (shortcut.isEmpty ? "" : " (\(shortcut))")
      badge.target = badge
      badge.action = #selector(WorkspaceActionButton.invoke)
      badge.onPress = button.onPress
      item.addSubview(button)
      item.addSubview(close)
      item.addSubview(badge)
      let widthConstraint = item.widthAnchor.constraint(equalToConstant: width)
      widthConstraint.identifier = "tabWidth"
      widthConstraint.isActive = true
      item.heightAnchor.constraint(equalToConstant: 28).isActive = true
      contentWidth += width
      tabButtons.addArrangedSubview(item)
    }
    tabButtons.frame = NSRect(origin: .zero, size: NSSize(width: contentWidth, height: 30))
    needsLayout = true
  }
  private func title(for tab: TerminalTab) -> String {
    if let title = tab.title, !title.isEmpty { return title }
    let pane = tab.selected
    let id = pane.herdrTerminal?.pane.pane_id ?? ""
    let reported = paneTitles[id] ?? pane.terminalTitle
    if !reported.isEmpty && !["Velocitty", "zsh", "bash", "fish", "sh"].contains(reported) { return reported }
    if let agent = agent(for: pane) { return agent.name }
    let directory = paneDirectories[id] ?? pane.currentDirectory ?? pane.initialDirectory?.path ?? pane.settings.workingDirectory.path
    let home = pane.settings.home.path
    return directory == home ? "~" : directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
  }

  private func refreshNamespaces(_ controller: TerminalWindowController) {
    refreshingNamespaces = true
    defer { refreshingNamespaces = false }
    displayedNamespaces = controller.namespaces
    namespaceList.reloadData()
    if let index = controller.namespaces.firstIndex(where: { $0 === controller.activeNamespace }) {
      namespaceList.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    item == nil ? displayedNamespaces.count : 0
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    // AppKit may request a cached row while a window or namespace is being removed.
    guard displayedNamespaces.indices.contains(index) else { return NSNull() }
    return displayedNamespaces[index]
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
  private func namespace(for item: Any) -> TerminalNamespace? {
    guard let namespace = item as? TerminalNamespace,
      controller?.namespaces.contains(where: { $0 === namespace }) == true else { return nil }
    return namespace
  }
  func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { NamespaceHoverRow() }
  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    if sidebarCompact { return 34 }
    guard let namespace = namespace(for: item) else { return 34 }
    let hasBranch = branch(for: namespace) != nil
    let hasAgents = namespace.tabs.flatMap(\.panes).contains { agent(for: $0) != nil }
    return 50 + (hasBranch ? 18 : 0) + (hasAgents ? metric("agent_icon_size") + 8 : 0)
  }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let namespace = namespace(for: item) else { return nil }
    let cell = NSTableCellView()
    let number = (controller?.namespaces.firstIndex { $0 === namespace } ?? 0) + 1
    let title = NSTextField(labelWithString: sidebarCompact ? String(number) : namespace.name)
    title.alignment = sidebarCompact ? .center : .left
    title.setAccessibilityLabel(sidebarCompact ? "Namespace \(number): \(namespace.name)" : namespace.name)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    title.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(title)
    cell.textField = title
    cell.toolTip = namespace.name + " — " + (namespace.selected.selected.herdrTerminal?.client.endpointLabel ?? "Local")
    let members = namespace.tabs.flatMap(\.panes).filter { agent(for: $0) != nil }
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      sidebarCompact
        ? title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        : title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
    ])
    if sidebarCompact { return cell }
    let cwd = directory(for: namespace)
    let home = namespace.selected.selected.settings.home.path
    let displayDirectory = cwd == home ? "~" : cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
    func detail(_ text: String, top: CGFloat, tooltip: String? = nil) {
      let label = NSTextField(labelWithString: text)
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingMiddle
      label.toolTip = tooltip ?? text
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        label.topAnchor.constraint(equalTo: cell.topAnchor, constant: top),
      ])
    }
    var detailTop: CGFloat = 27
    if let branch = branch(for: namespace) {
      detail(branch, top: detailTop)
      detailTop += 18
    }
    let host = namespace.selected.selected.herdrTerminal?.client.machine?.label
    detail(host.map { $0 + ": " + displayDirectory } ?? displayDirectory, top: detailTop, tooltip: cwd)
    guard !members.isEmpty else { return cell }
    let size = metric("agent_icon_size")
    let statusScroll = NSScrollView()
    statusScroll.drawsBackground = false
    statusScroll.hasHorizontalScroller = true
    statusScroll.autohidesScrollers = true
    statusScroll.scrollerStyle = .overlay
    let statusRow = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(members.count) * (size + 6) - 6, height: size + 4))
    statusScroll.documentView = statusRow
    statusScroll.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(statusScroll)
    NSLayoutConstraint.activate([
      statusScroll.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      statusScroll.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      statusScroll.topAnchor.constraint(equalTo: cell.topAnchor, constant: detailTop + 21),
      statusScroll.heightAnchor.constraint(equalToConstant: size + 4),
    ])
    for (offset, pane) in members.enumerated() {
      guard let agent = agent(for: pane) else { continue }
      let chip = AgentIconButton(agent: agent, values: appearanceValues)
      chip.onSelect = { [weak controller, weak pane] in
        if let pane { controller?.selectTab(pane) }
      }
      chip.toolTip = "\(agent.name) — \(chip.statusLabel) · \(pane.displayTitle)"
      chip.setAccessibilityLabel(chip.toolTip)
      chip.frame = NSRect(x: CGFloat(offset) * (size + 6), y: 2, width: size, height: size)
      statusRow.addSubview(chip)
    }
    return cell
  }
  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !refreshingNamespaces, namespaceList.selectedRow >= 0 else { return }
    let keyboardFocus = NSApp.currentEvent?.type == .keyDown && window?.firstResponder === namespaceList
    if let namespace = namespaceList.item(atRow: namespaceList.selectedRow) as? TerminalNamespace { controller?.selectTab(namespace.selected) }
    if keyboardFocus { window?.makeFirstResponder(namespaceList) }
  }
  func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === content }
  func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { animatedSidebarWidth != nil || sidebarCompact ? 56 : 160 }
  func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { sidebarCompact && animatedSidebarWidth == nil ? 56 : max(160, min(400, bounds.width - 320)) }
  func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { sidebar.isHidden }
  func splitViewDidResizeSubviews(_ notification: Notification) {
    needsLayout = true
    if animatedSidebarWidth == nil, let controller { controller.owner?.scheduleWorkspaceSave(controller) }
    if let controller { refreshNamespaces(controller) }
  }
  var savedSidebarState: WorkspaceState.Sidebar {
    let width = sidebarCompact || animatedSidebarWidth != nil ? expandedSidebarWidth ?? metric("sidebar_width") : sidebar.frame.width
    return WorkspaceState.Sidebar(width: Double(min(400, max(160, width))), compact: sidebarCompact)
  }
  func restoreSidebarState(_ state: WorkspaceState.Sidebar) {
    sidebarCompact = state.compact
    expandedSidebarWidth = CGFloat(state.width)
    configuredWidth = 0
    needsLayout = true
  }
  @objc func toggleNamespaceSidebar() {
    sidebarAnimation?.invalidate()
    sidebarAnimation = nil
    let startWidth = sidebar.frame.width
    if !sidebarCompact && animatedSidebarWidth == nil { expandedSidebarWidth = startWidth }
    sidebarCompact.toggle()
    let targetWidth: CGFloat = sidebarCompact ? 56 : min(expandedSidebarWidth ?? metric("sidebar_width"), max(160, bounds.width - 320))
    if let controller { refreshNamespaces(controller) }
    configuredWidth = 0
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      animatedSidebarWidth = nil
      needsLayout = true
      return
    }
    let started = ProcessInfo.processInfo.systemUptime
    animatedSidebarWidth = startWidth
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
      guard let self else { timer.invalidate(); return }
      let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.2)
      let eased = progress * progress * (3 - 2 * progress)
      self.animatedSidebarWidth = startWidth + (targetWidth - startWidth) * eased
      self.needsLayout = true
      self.layoutSubtreeIfNeeded()
      if progress >= 1 {
        timer.invalidate()
        self.sidebarAnimation = nil
        self.animatedSidebarWidth = nil
        self.configuredWidth = self.sidebarCompact ? 56 : self.metric("sidebar_width")
        if let controller = self.controller { controller.owner?.scheduleWorkspaceSave(controller) }
      }
    }
    sidebarAnimation = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func createTab() { controller?.newTab() }

}

/// Border animation uses Core Animation rather than a per-frame UI timer.
private final class AgentIconButton: NSButton {
  var onSelect: (() -> Void)?
  private let border = CAShapeLayer()
  private let agentImage = AgentImageView()
  private let values: [String: String]
  private let agent: TerminalWorkspaceView.Agent
  private var statusKey: String {
    switch agent.status {
    case "working": return "running"
    case "blocked": return "waiting"
    case "idle", "done": return agent.status
    default: return "unknown"
    }
  }
  var statusLabel: String {
    switch statusKey {
    case "running": return "Running"
    case "waiting": return "Waiting for input"
    case "done": return "Done"
    case "idle": return "Idle"
    default: return "Status unknown"
    }
  }

  init(agent: TerminalWorkspaceView.Agent, values: [String: String]) {
    self.agent = agent
    self.values = values
    super.init(frame: .zero)
    title = ""
    isBordered = false
    refusesFirstResponder = true
    wantsLayer = true
    layer?.addSublayer(border)
    agentImage.image = AgentIconCatalog.image(for: agent.name)
    agentImage.contentTintColor = .labelColor
    agentImage.imageScaling = .scaleProportionallyUpOrDown
    addSubview(agentImage)
    target = self
    action = #selector(selectAgent)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func selectAgent() { onSelect?() }

  override func layout() {
    super.layout()
    agentImage.frame = bounds.insetBy(dx: 4, dy: 4)
    let width = CGFloat(Double(values["agent_border_width"] ?? "") ?? 1)
    let rect = bounds.insetBy(dx: width / 2 + 1, dy: width / 2 + 1)
    border.frame = bounds
    border.path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
    border.fillColor = nil
    border.lineWidth = width
    let hex = UInt32((values[statusKey + "_color"] ?? "#666666").dropFirst(), radix: 16) ?? 0x666666
    border.strokeColor = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
      green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1).cgColor
    let style = values[statusKey + "_style"] ?? "solid"
    border.isHidden = style == "none"
    border.removeAnimation(forKey: "activity")
    border.lineDashPattern = nil
    border.lineCap = .round
    if style == "dotted" { border.lineDashPattern = [1, 3] }
    if style == "animated", !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let perimeter = max(1, 2 * (rect.width + rect.height) - 40 + 10 * CGFloat.pi)
      border.lineDashPattern = [NSNumber(value: Double(perimeter * 0.3)), NSNumber(value: Double(perimeter * 0.7))]
      let animation = CABasicAnimation(keyPath: "lineDashPhase")
      animation.fromValue = 0
      animation.toValue = -perimeter
      animation.duration = Double(values["agent_animation_duration"] ?? "") ?? 1.6
      animation.repeatCount = .infinity
      border.add(animation, forKey: "activity")
    }
  }
}

private final class WorkspaceActionButton: NSButton {
  var onPress: (() -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    target = self
    action = #selector(invoke)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc func invoke() { onPress?() }
}

/// Removing a collapsed arranged subview avoids a leftover divider gutter.
private final class WorkspaceSplitView: NSSplitView {
  override var dividerThickness: CGFloat { arrangedSubviews.count < 2 ? 0 : 1 }
  override func drawDivider(in rect: NSRect) {} // Sidebar material provides the separation.
}

/// Content tabs follow the system window-tab layout without representing NSWindows.
private final class WorkspaceTabItem: NSView {
  var selected = false
  private var hovered = false
  private var hoverTracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverTracking = area
    hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    needsDisplay = true
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    if selected {
      NSColor.controlBackgroundColor.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    } else {
      if hovered {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
      }
      NSColor.separatorColor.setFill()
      NSRect(x: bounds.maxX - 0.5, y: 7, width: 0.5, height: max(0, bounds.height - 14)).fill()
    }
  }
}

private final class NamespaceHoverRow: NSTableRowView {
  private var hovered = false
  private var hoverTracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverTracking = area
    hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    needsDisplay = true
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func drawBackground(in dirtyRect: NSRect) {
    super.drawBackground(in: dirtyRect)
    if hovered && !isSelected {
      NSColor.labelColor.withAlphaComponent(0.07).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
  }
}

/// A single monochrome source, with aliases for herdr's agent names.
private enum AgentIconCatalog {
  static let names = ["codex", "claude", "grok", "gemini", "cursor", "copilot", "opencode",
    "kimi", "amp", "cline", "kilo", "qwen", "devin", "antigravity", "kiro", "qoder"]
  static func image(for agent: String) -> NSImage? {
    let key = agent.lowercased().filter { $0.isLetter || $0.isNumber }
    let aliases = ["claudecode": "claude", "githubcopilot": "copilot", "geminicli": "gemini",
      "cursoragent": "cursor", "grokbuild": "grok", "kilocode": "kilo", "qodercli": "qoder", "qwencode": "qwen"]
    let name = aliases[key] ?? key
    if names.contains(name), let image = NSImage(named: "Agent-" + name) { return image }
    return NSImage(systemSymbolName: "terminal", accessibilityDescription: agent)
  }
}

private final class AgentImageView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// A divider previews its position locally and commits one explicit ratio on release.
private final class PaneDivider: NSView {
  var color = NSColor.separatorColor
  var vertical = true
  var ratio = 0.5
  var container = NSRect.zero
  var onCommit: ((Double) -> Void)?
  private(set) var dragging = false
  override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
  override func mouseDown(with event: NSEvent) { dragging = true }
  override func mouseDragged(with event: NSEvent) {
    guard let parent = superview else { return }
    let point = parent.convert(event.locationInWindow, from: nil)
    let proposed = vertical ? (point.x - container.minX) / max(1, container.width) : (container.maxY - point.y) / max(1, container.height)
    ratio = Double(max(0.1, min(0.9, proposed)))
    if vertical { frame.origin.x = container.minX + container.width * ratio - 3 }
    else { frame.origin.y = container.maxY - container.height * ratio - 3 }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) { dragging = false; onCommit?(ratio) }
  override func draw(_ dirtyRect: NSRect) {
    (dragging ? NSColor.controlAccentColor : color).setFill()
    bounds.insetBy(dx: vertical ? 2 : 0, dy: vertical ? 0 : 2).fill()
  }
}
