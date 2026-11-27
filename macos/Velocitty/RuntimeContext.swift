// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class RuntimeContext: NSObject {
  weak var owner: AppDelegate?
  weak var runtime: TerminalRuntime?
  var app: ghostty_app_t?

  static func fromApp(_ app: ghostty_app_t) -> RuntimeContext? {
    guard let userdata = velokit_app_userdata(app) else { return nil }
    return Unmanaged<RuntimeContext>.fromOpaque(userdata).takeUnretainedValue()
  }

  static func fromSurfaceUserdata(_ userdata: UnsafeMutableRawPointer?) -> TerminalView? {
    guard let userdata else { return nil }
    return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
  }

  func tick() {
    guard let app else { return }
    velokit_app_tick(app)
  }

  /// Runs a body on the main queue with the action's view and the window controller presenting it.
  typealias Perform = (@escaping (TerminalView?, TerminalWindowController?) -> Void) -> Void

  func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    let view: TerminalView? = {
      if target.tag == GHOSTTY_TARGET_SURFACE,
        let surface = target.target.surface,
        let userdata = velokit_surface_userdata(surface)
      {
        return Self.fromSurfaceUserdata(userdata)
      }
      return nil
    }()

    // Resolve presentation at delivery time. A session may have moved since the callback.
    let surfaceTarget = target.tag == GHOSTTY_TARGET_SURFACE
    let perform: Perform = { [self, view] body in
      DispatchQueue.main.async { [weak self, weak view] in
        guard let self, self.app != nil, self.owner?.terminating != true else { return }
        if surfaceTarget {
          guard let view, view.surface != nil else { return }
          body(view, view.session?.windowController)
        } else {
          let controller = self.owner?.activeWindow
          body(controller?.session?.view, controller)
        }
      }
    }
    return handleTerminalAction(action, target: target, view: view, perform: perform)
      ?? handlePointerAction(action, view: view, perform: perform)
      ?? handleWorkspaceAction(action, view: view, perform: perform)
      ?? handleWindowAction(action, view: view, perform: perform)
      ?? false
  }

  /// Terminal state, titles and notifications reported by a surface.
  private func handleTerminalAction(_ action: ghostty_action_s, target: ghostty_target_s, view: TerminalView?, perform: Perform) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      guard Self.isHerdr(view) else { return false }
      perform { view, _ in view?.session?.attachmentExited() }

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      guard let config = action.action.config_change.config else { return false }
      return applyConfigChange(config, target: target, view: view, perform: perform)

    case GHOSTTY_ACTION_RENDER:
      view?.invalidateAccessibilityText()
      if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
        velokit_surface_draw(surface)
      }

    case GHOSTTY_ACTION_SET_TITLE:
      guard let title = action.action.set_title.title.map({ String(cString: $0) }) else {
        return true
      }
      perform { view, controller in
        view?.session?.terminalTitle = title
        if let tab = view?.session { controller?.tabMetadataChanged(tab) }
      }

    case GHOSTTY_ACTION_READONLY:
      let readonly = action.action.readonly == GHOSTTY_READONLY_ON
      perform { view, controller in
        view?.session?.readonly = readonly
        if controller?.session === view?.session { controller?.updateSecureInput() }
      }

    case GHOSTTY_ACTION_INITIAL_SIZE:
      let size = action.action.initial_size
      view?.initialSize = NSSize(width: Int(size.width), height: Int(size.height))

    case GHOSTTY_ACTION_SIZE_LIMIT:
      let limit = action.action.size_limit
      perform { view, controller in
        guard let tab = view?.session else { return }
        tab.sizeLimit = limit
        controller?.applySizeLimit(for: tab)
      }

    case GHOSTTY_ACTION_COLOR_CHANGE:
      let color = action.action.color_change
      if color.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
        perform { view, controller in Self.applyBackground(color, view: view, controller: controller) }
      }

    case GHOSTTY_ACTION_PWD:
      let path = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
      perform { view, controller in
        view?.session?.currentDirectory = path
        if let tab = view?.session { controller?.tabMetadataChanged(tab) }
      }

    case GHOSTTY_ACTION_SECURE_INPUT:
      let mode = action.action.secure_input
      perform { view, controller in controller?.secureInput(mode, from: view?.session) }

    case GHOSTTY_ACTION_RING_BELL:
      perform { view, controller in controller?.ringBell(from: view?.session) }

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let notification = action.action.desktop_notification
      let title = notification.title.map { String(cString: $0) } ?? "Velocitty"
      let body = notification.body.map { String(cString: $0) } ?? ""
      perform { view, controller in controller?.notify(title: title, body: body) }

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let value = action.action.command_finished
      perform { view, controller in controller?.commandFinished(value, from: view?.session) }

    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let value = action.action.progress_report
      perform { view, _ in Self.updateProgress(value, view: view) }

    default:
      return nil
    }
    return true
  }

  /// Search, selection, scrollbar, link and pointer updates for a surface.
  private func handlePointerAction(_ action: ghostty_action_s, view: TerminalView?, perform: Perform) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_START_SEARCH:
      let needle = action.action.start_search.needle.map { String(cString: $0) }
      perform { view, controller in view?.session?.chrome?.startSearch(needle) }

    case GHOSTTY_ACTION_END_SEARCH:
      perform { view, controller in view?.session?.chrome?.hideSearch() }

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = action.action.search_total.total
      perform { view, controller in
        let chrome = view?.session?.chrome
        chrome?.total = total
        chrome?.updateCount()
      }

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = action.action.search_selected.selected
      perform { view, controller in
        let chrome = view?.session?.chrome
        chrome?.selected = selected
        chrome?.updateCount()
      }

    case GHOSTTY_ACTION_SELECTION_CHANGED:
      perform { view, _ in view?.accessibilitySelectionChanged() }

    case GHOSTTY_ACTION_SCROLLBAR:
      let state = action.action.scrollbar
      perform { view, controller in view?.session?.chrome?.updateScrollbar(state) }

    case GHOSTTY_ACTION_OPEN_URL:
      let link = action.action.open_url
      guard let value = Self.validLinkText(link) else { return true }
      perform { view, controller in view?.session?.links.open(value, kind: link.kind, from: view) }

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      let value = Self.hoveredLinkText(link)
      perform { view, controller in
        view?.linkURL = value
        view?.toolTip = value
      }

    case GHOSTTY_ACTION_MOUSE_SHAPE:
      let shape = action.action.mouse_shape
      perform { view, controller in Self.applyCursor(shape, view: view) }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
      perform { view, controller in
        if view?.pointerIsInside == true { NSCursor.setHiddenUntilMouseMoves(hidden) }
      }

    default:
      return nil
    }
    return true
  }

  /// Namespace, tab and split actions.
  private func handleWorkspaceAction(_ action: ghostty_action_s, view: TerminalView?, perform: Perform) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_PROMPT_TITLE:
      let mode = action.action.prompt_title
      perform { view, controller in
        if mode == GHOSTTY_PROMPT_TITLE_TAB { controller?.renameTab(view?.session) }
        else { controller?.promptTitle(mode) }
      }

    case GHOSTTY_ACTION_SET_TAB_TITLE:
      let title = action.action.set_tab_title.title.map { String(cString: $0) } ?? ""
      perform { view, controller in Self.setTabTitle(title, view: view, controller: controller) }

    case GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW:
      perform { _, controller in controller?.moveTabToNewWindow() }

    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      perform { _, controller in controller?.toggleTabOverview() }

    case GHOSTTY_ACTION_RENAME_NAMESPACE:
      guard Self.isHerdr(view) else { return false }
      perform { _, controller in controller?.editNamespace() }

    case GHOSTTY_ACTION_NEW_NAMESPACE:
      guard Self.isHerdr(view) else { return false }
      perform { _, controller in controller?.newNamespace() }

    case GHOSTTY_ACTION_CLOSE_NAMESPACE:
      guard Self.isHerdr(view) else { return false }
      perform { _, controller in controller?.closeNamespace() }

    case GHOSTTY_ACTION_PREVIOUS_NAMESPACE, GHOSTTY_ACTION_NEXT_NAMESPACE:
      guard Self.isHerdr(view) else { return false }
      let step = action.tag == GHOSTTY_ACTION_NEXT_NAMESPACE ? 1 : -1
      perform { _, controller in Self.stepNamespace(step, controller: controller) }

    case GHOSTTY_ACTION_GOTO_NAMESPACE:
      guard Self.isHerdr(view) else { return false }
      let index = Int(action.action.goto_namespace.index) - 1
      perform { _, controller in controller?.selectNamespace(at: index) }

    case GHOSTTY_ACTION_NEW_SPLIT:
      guard let name = Self.splitName(action.action.new_split) else { return false }
      perform { view, controller in controller?.splitPane(name, from: view?.session) }

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      guard Self.hasMultiplePanes(view) else { return false }
      perform { _, controller in controller?.equalizePanes() }

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      guard Self.hasMultiplePanes(view) else { return false }
      perform { view, controller in controller?.togglePaneZoom(from: view?.session) }

    case GHOSTTY_ACTION_GOTO_SPLIT:
      guard let pane = view?.session, let controller = pane.windowController,
        controller.visiblePanes.count > 1 else { return false }
      let directions = ["previous", "next", "up", "left", "down", "right"]
      let index = Int(action.action.goto_split.rawValue)
      guard directions.indices.contains(index) else { return false }
      let direction = directions[index]
      perform { view, controller in controller?.focusPane(direction, from: view?.session) }

    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let value = action.action.resize_split
      let directions = ["up", "down", "left", "right"]
      let index = Int(value.direction.rawValue)
      guard directions.indices.contains(index) else { return false }
      perform { view, controller in controller?.resizePane(directions[index], amount: Double(value.amount) / 100, from: view?.session) }

    case GHOSTTY_ACTION_NEW_TAB:
      perform { [weak self] _, controller in
        if let controller { controller.newTab() } else { self?.owner?.newWindow() }
      }

    case GHOSTTY_ACTION_GOTO_TAB:
      let direction = action.action.goto_tab
      perform { view, controller in Self.gotoTab(direction, view: view, controller: controller) }

    case GHOSTTY_ACTION_MOVE_TAB:
      let amount = action.action.move_tab.amount
      perform { view, controller in controller?.moveTab(amount, from: view?.session) }

    case GHOSTTY_ACTION_CLOSE_TAB:
      let mode = action.action.close_tab_mode
      perform { view, controller in controller?.closeTabs(mode, from: view?.session) }

    default:
      return nil
    }
    return true
  }

  /// Window and application actions.
  private func handleWindowAction(_ action: ghostty_action_s, view: TerminalView?, perform: Perform) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_SET_WINDOW_TITLE:
      let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
      perform { view, controller in
        guard let controller else { return }
        controller.windowTitleOverride = title.isEmpty ? nil : title
        controller.setTitle(controller.terminalTitle)
      }

    case GHOSTTY_ACTION_QUIT_TIMER:
      let start = action.action.quit_timer == GHOSTTY_QUIT_TIMER_START
      perform { view, controller in
        let delegate = NSApp.delegate as? AppDelegate
        if start { delegate?.scheduleQuitIfNeeded() } else { delegate?.quitTimer?.invalidate() }
      }

    case GHOSTTY_ACTION_GOTO_WINDOW:
      let direction = action.action.goto_window
      perform { [weak self] _, controller in
        self?.owner?.gotoWindow(direction, from: controller)
      }

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      perform { view, controller in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(view?.window?.title ?? "Velocitty", forType: .string)
      }

    case GHOSTTY_ACTION_CELL_SIZE:
      let cell = action.action.cell_size
      perform { view, controller in Self.applyCellSize(cell, view: view) }

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      perform { view, controller in controller?.resetWindowSize() }

    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      perform { view, controller in (NSApp.delegate as? AppDelegate)?.closeAllWindows() }

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      perform { view, controller in Self.toggleOpacity(view: view, controller: controller) }

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      perform { _, controller in controller?.toggleDecorations() }

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      perform { view, controller in controller?.showCommands() }

    case GHOSTTY_ACTION_NEW_WINDOW:
      perform { view, controller in (NSApp.delegate as? AppDelegate)?.newWindow() }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      perform { view, controller in
        if let tab = view?.session { controller?.selectTab(tab) }
        controller?.openWindow() ?? (NSApp.delegate as? AppDelegate)?.openWindow()
      }

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      perform { view, controller in view?.window?.zoom(nil) }

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      perform { view, controller in controller?.toggleFullscreen() }

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      perform { _, _ in Self.toggleApplicationVisibility() }

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      let soft = action.action.reload_config.soft
      perform { view, controller in
        let delegate = NSApp.delegate as? AppDelegate
        if soft { delegate?.refreshAppearance() } else { delegate?.reloadConfiguration(nil) }
      }

    case GHOSTTY_ACTION_OPEN_CONFIG:
      perform { _, controller in controller?.owner?.showSettings() }

    case GHOSTTY_ACTION_FLOAT_WINDOW:
      let level = action.action.float_window
      perform { view, _ in Self.floatWindow(level, view: view) }

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      perform { _, controller in controller?.window?.performClose(nil) }

    case GHOSTTY_ACTION_UNDO:
      perform { _, controller in controller?.owner?.undoClose() }

    case GHOSTTY_ACTION_REDO:
      perform { _, controller in controller?.owner?.redoClose() }

    case GHOSTTY_ACTION_QUIT:
      perform { view, controller in
        NSApp.terminate(nil)
      }

    default:
      return nil
    }
    return true
  }

  // MARK: Action bodies

  /// Accepts a changed surface or app configuration; false when it could not be retained.
  private func applyConfigChange(_ config: ghostty_config_t, target: ghostty_target_s, view: TerminalView?, perform: Perform) -> Bool {
    // Copy before returning; dispatching this borrowed pointer would outlive it.
    let accepted = target.tag == GHOSTTY_TARGET_SURFACE
      ? view?.session?.configurationChanged(config) ?? false
      : runtime?.configurationChanged(config) ?? false
    if !accepted { NSLog("Could not retain the applied terminal configuration.") }
    perform { [weak self] _, _ in self?.owner?.configurationDidChange() }
    return accepted
  }

  private static func applyBackground(_ color: ghostty_action_color_change_s, view: TerminalView?, controller: TerminalWindowController?) {
    view?.session?.backgroundColor = NSColor(srgbRed: Double(color.r) / 255,
      green: Double(color.g) / 255, blue: Double(color.b) / 255, alpha: 1)
    if controller?.session === view?.session { controller?.applyBackground() }
  }

  private static func updateProgress(_ value: ghostty_action_progress_report_s, view: TerminalView?) {
    if NativeSettings(config: view?.config).progressStyle { view?.session?.chrome?.progress.update(value) }
    else { view?.session?.chrome?.progress.clear() }
  }

  /// The URL text of an open-link action; nil when it is not valid UTF-8.
  private static func validLinkText(_ link: ghostty_action_open_url_s) -> String? {
    guard let ptr = link.url else { return nil }
    return String(
      bytes: UnsafeBufferPointer(
        start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(link.len)),
      encoding: .utf8)
  }

  private static func hoveredLinkText(_ link: ghostty_action_mouse_over_link_s) -> String? {
    link.url.map {
      String(
        decoding: UnsafeBufferPointer(
          start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: Int(link.len)),
        as: UTF8.self)
    }
  }

  private static func applyCursor(_ shape: ghostty_action_mouse_shape_e, view: TerminalView?) {
    let cursor: NSCursor =
      shape == GHOSTTY_MOUSE_SHAPE_POINTER
      ? .pointingHand : shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam : .arrow
    view?.pointer = cursor
    if view?.pointerIsInside == true { cursor.set() }
  }

  private static func setTabTitle(_ title: String, view: TerminalView?, controller: TerminalWindowController?) {
    guard let pane = view?.session else { return }
    controller?.tab(for: pane)?.title = title.isEmpty ? nil : title
    for sibling in controller?.tab(for: pane)?.panes ?? [] { sibling.tabTitle = title.isEmpty ? nil : title }
    controller?.tabMetadataChanged(pane)
  }

  private static func stepNamespace(_ step: Int, controller: TerminalWindowController?) {
    guard let controller, let index = controller.namespaces.firstIndex(where: { $0 === controller.activeNamespace }) else { return }
    controller.selectNamespace(at: (index + step + controller.namespaces.count) % controller.namespaces.count)
  }

  private static func splitName(_ direction: ghostty_action_split_direction_e) -> String? {
    switch direction {
    case GHOSTTY_SPLIT_DIRECTION_RIGHT: return "right"
    case GHOSTTY_SPLIT_DIRECTION_DOWN: return "down"
    case GHOSTTY_SPLIT_DIRECTION_LEFT: return "left"
    case GHOSTTY_SPLIT_DIRECTION_UP: return "up"
    default: return nil
    }
  }

  private static func gotoTab(_ direction: ghostty_action_goto_tab_e, view: TerminalView?, controller: TerminalWindowController?) {
    guard let controller, let source = view?.session ?? controller.session,
      let namespace = controller.namespace(for: source) else { return }
    switch direction {
    case GHOSTTY_GOTO_TAB_PREVIOUS: controller.cycleTab(-1, from: view?.session)
    case GHOSTTY_GOTO_TAB_NEXT: controller.cycleTab(1, from: view?.session)
    case GHOSTTY_GOTO_TAB_LAST:
      if let last = namespace.tabs.last { controller.selectTab(last) }
    default:
      let index = Int(direction.rawValue) - 1
      if namespace.tabs.indices.contains(index) { controller.selectTab(namespace.tabs[index]) }
    }
  }

  private static func applyCellSize(_ cell: ghostty_action_cell_size_s, view: TerminalView?) {
    guard let window = view?.window,
      NativeSettings(config: view?.config).windowStepResize
    else { return }
    window.contentResizeIncrements = NSSize(
      width: max(1, CGFloat(cell.width) / window.backingScaleFactor),
      height: max(1, CGFloat(cell.height) / window.backingScaleFactor))
  }

  private static func toggleOpacity(view: TerminalView?, controller: TerminalWindowController?) {
    guard let controller else { return }
    do { try view?.session?.toggleOpacity() }
    catch { NSLog("Opacity update failed: %@", error.localizedDescription) }
    if controller.session === view?.session { controller.applyWindowSettings() }
  }

  private static func toggleApplicationVisibility() {
    if NSApp.isHidden || !NSApp.isActive {
      NSApp.unhide(nil)
      (NSApp.delegate as? AppDelegate)?.openWindow()
      NSApp.activate(ignoringOtherApps: true)
    } else {
      NSApp.hide(nil)
    }
  }

  private static func floatWindow(_ level: ghostty_action_float_window_e, view: TerminalView?) {
    guard let window = view?.window else { return }
    window.level =
      level == GHOSTTY_FLOAT_WINDOW_ON
        || (level == GHOSTTY_FLOAT_WINDOW_TOGGLE && window.level != .floating)
      ? .floating : .normal
  }

  private static func isHerdr(_ view: TerminalView?) -> Bool { view?.session?.herdrTerminal != nil }

  private static func hasMultiplePanes(_ view: TerminalView?) -> Bool {
    guard let pane = view?.session else { return false }
    return (pane.windowController?.tab(for: pane)?.panes.count ?? 0) > 1
  }

  static let wakeup: ghostty_runtime_wakeup_cb = { userdata in
    guard let userdata else { return }
    let context = Unmanaged<RuntimeContext>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      context.tick()
    }
  }

  static let action: ghostty_runtime_action_cb = { app, target, action in
    guard let app, let context = RuntimeContext.fromApp(app) else { return false }
    return context.handleAction(target: target, action: action)
  }

  static let clipboardTypes: [(String, NSPasteboard.PasteboardType)] = [
    ("text/plain", .string), ("text/html", .html), ("image/png", .png),
  ]
  static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard {
    location == GHOSTTY_CLIPBOARD_STANDARD
      ? .general
      : NSPasteboard(name: .init((Bundle.main.bundleIdentifier ?? "app.velocitty") + ".selection"))
  }
  static let readClipboard: ghostty_runtime_read_clipboard_cb = {
    userdata, location, state, requested, requestedCount, wantsAvailable in
    guard let view = RuntimeContext.fromSurfaceUserdata(userdata), let surface = view.surface else {
      return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
    }
    let board = RuntimeContext.pasteboard(location)
    let requestedTypes = (0..<requestedCount).compactMap {
      requested?[$0].map { String(cString: $0) }
    }
    let available = RuntimeContext.clipboardTypes.filter {
      board.availableType(from: [$0.1]) != nil
    }
    let items = available.compactMap { mime, type -> (String, Data)? in
      guard requestedTypes.isEmpty ? mime == "text/plain" : requestedTypes.contains(mime),
        let bytes = board.data(forType: type)
      else { return nil }
      return (mime, bytes)
    }
    guard wantsAvailable || !items.isEmpty else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    RuntimeContext.completeClipboard(
      items, surface: surface, state: state, confirmed: false,
      available: wantsAvailable ? available.map { $0.0 } : [])
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  static let confirmReadClipboard: ghostty_runtime_confirm_read_clipboard_cb = {
    userdata, request, state, kind in
    guard let view = RuntimeContext.fromSurfaceUserdata(userdata), let surface = view.surface
    else { return }
    guard let request else {
      velokit_surface_deny_clipboard_request(surface, state)
      return
    }
    // Copy callback-owned bytes and register ownership before scheduling the sheet.
    let items = (0..<request.pointee.contents_len).compactMap { index -> (String, Data)? in
      guard let item = request.pointee.contents?[index], let mime = item.mime, let data = item.data
      else { return nil }
      return (String(cString: mime), Data(bytes: data, count: item.len))
    }
    let available = (0..<request.pointee.available_len).compactMap {
      request.pointee.available?[$0].map { String(cString: $0) }
    }
    let canRemember = request.pointee.can_remember
    let name = request.pointee.name.map { String(cString: $0) } ?? "The terminal"
    let writing = kind == GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE || kind == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE
    view.clipboard.enqueue(
      title: writing ? "Replace clipboard contents?" : "Allow clipboard access?",
      message: (writing ? "\(name) wants to write to your clipboard.\n\n" : "\(name) requested clipboard content or a paste requiring confirmation.\n\n")
        + String(String(data: items.first?.1 ?? Data(), encoding: .utf8)?.prefix(500) ?? ""),
      canRemember: canRemember
    ) { allowed, remember in
      guard allowed else {
        velokit_surface_deny_clipboard_request(surface, state)
        return
      }
      RuntimeContext.completeClipboard(
        items, surface: surface, state: state, confirmed: true, available: available,
        remember: remember)
    }
  }

  static func completeClipboard(
    _ items: [(String, Data)], surface: ghostty_surface_t, state: UnsafeMutableRawPointer?,
    confirmed: Bool, available: [String] = [], remember: Bool = false
  ) {
    let names = available.map { strdup($0) }
    defer { names.forEach { free($0) } }
    let pointers = names.map { UnsafePointer($0) }
    let mime = items.map { strdup($0.0) }
    let bytes = items.map { item -> UnsafeMutablePointer<CChar> in
      let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, item.1.count))
      item.1.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: item.1.count))
      return pointer
    }
    defer {
      mime.forEach { free($0) }
      bytes.forEach { $0.deallocate() }
    }
    let contents = items.indices.map {
      ghostty_clipboard_content_s(
        mime: UnsafePointer(mime[$0]), data: UnsafePointer(bytes[$0]), len: items[$0].1.count)
    }
    contents.withUnsafeBufferPointer { contents in
      pointers.withUnsafeBufferPointer { names in
        var complete = ghostty_clipboard_complete_s(
          contents: contents.baseAddress, contents_len: contents.count,
          available: names.baseAddress, available_len: names.count, confirmed: confirmed,
          remember: remember)
        velokit_surface_complete_clipboard_request(surface, &complete, state)
      }
    }
  }

  static let writeClipboard: ghostty_runtime_write_clipboard_cb = {
    userdata, location, content, length, needsConfirmation in
    guard let content else { return }
    let items = (0..<length).compactMap { index -> (NSPasteboard.PasteboardType, Data)? in
      let item = content[index]
      guard let mime = item.mime, let data = item.data else { return nil }
      let type: NSPasteboard.PasteboardType
      switch String(cString: mime) {
      case "text/plain": type = .string
      case "text/html": type = .html
      case "image/png": type = .png
      default: return nil
      }
      return (type, Data(bytes: data, count: item.len))
    }
    guard !items.isEmpty else { return }
    guard let view = RuntimeContext.fromSurfaceUserdata(userdata), let surface = view.surface else { return }
    let write = {
      let board = RuntimeContext.pasteboard(location)
      board.clearContents()
      for (type, data) in items { board.setData(data, forType: type) }
    }
    if needsConfirmation {
      // This callback has no engine request state to complete or deny.
      view.clipboard.enqueue(
        title: "Replace clipboard contents?",
        message: "A program in this terminal wants to write to your clipboard."
      ) { allowed, _ in
        if allowed { write() }
      }
    } else {
      DispatchQueue.main.async { [weak view] in
        guard view?.surface == surface else { return }
        write()
      }
    }
  }

  static let closeSurface: ghostty_runtime_close_surface_cb = { userdata, processAlive in
    guard let view = RuntimeContext.fromSurfaceUserdata(userdata) else { return }
    DispatchQueue.main.async { [weak view] in
      guard let view, view.surface != nil else { return }
      if let pane = view.session {
        if processAlive { pane.windowController?.closePane(pane) }
        else if pane.herdrTerminal != nil { pane.attachmentExited() }
        else { pane.windowController?.requestTabClose(pane) }
      }
    }
  }
}
