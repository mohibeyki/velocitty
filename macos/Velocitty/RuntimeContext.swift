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
    let perform: (@escaping (TerminalView?, TerminalWindowController?) -> Void) -> Void = { [self, view] body in
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
    switch action.tag {
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      guard view?.session?.herdrTerminal != nil else { return false }
      perform { view, _ in view?.session?.attachmentExited() }

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      guard let config = action.action.config_change.config else { return false }
      // Copy before returning; dispatching this borrowed pointer would outlive it.
      let accepted = surfaceTarget
        ? view?.session?.configurationChanged(config) ?? false
        : runtime?.configurationChanged(config) ?? false
      if !accepted { NSLog("Could not retain the applied terminal configuration.") }
      perform { [weak self] _, _ in self?.owner?.configurationDidChange() }
      return accepted

    case GHOSTTY_ACTION_RENDER:
      if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
        velokit_surface_draw(surface)
      }

    case GHOSTTY_ACTION_SET_TITLE:
      guard let title = action.action.set_title.title.map({ String(cString: $0) }) else {
        return true
      }
      perform { view, owner in
        view?.session?.terminalTitle = title
        if let tab = view?.session { owner?.tabMetadataChanged(tab) }
      }

    case GHOSTTY_ACTION_SET_WINDOW_TITLE:
      let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
      perform { view, owner in
        guard let delegate = owner else { return }
        delegate.windowTitleOverride = title.isEmpty ? nil : title
        delegate.setTitle(delegate.terminalTitle)
      }

    case GHOSTTY_ACTION_PROMPT_TITLE:
      let mode = action.action.prompt_title
      perform { view, owner in
        if mode == GHOSTTY_PROMPT_TITLE_TAB { owner?.renameTab(view?.session) }
        else { owner?.promptTitle(mode) }
      }

    case GHOSTTY_ACTION_SET_TAB_TITLE:
      let title = action.action.set_tab_title.title.map { String(cString: $0) } ?? ""
      perform { view, owner in
        if let pane = view?.session {
          owner?.tab(for: pane)?.title = title.isEmpty ? nil : title
          for sibling in owner?.tab(for: pane)?.panes ?? [] { sibling.tabTitle = title.isEmpty ? nil : title }
          owner?.tabMetadataChanged(pane)
        }
      }

    case GHOSTTY_ACTION_READONLY:
      let readonly = action.action.readonly == GHOSTTY_READONLY_ON
      perform { view, owner in
        let delegate = owner
        view?.session?.readonly = readonly
        if delegate?.session === view?.session { delegate?.updateSecureInput() }
      }

    case GHOSTTY_ACTION_QUIT_TIMER:
      let start = action.action.quit_timer == GHOSTTY_QUIT_TIMER_START
      perform { view, owner in
        let delegate = NSApp.delegate as? AppDelegate
        if start { delegate?.scheduleQuitIfNeeded() } else { delegate?.quitTimer?.invalidate() }
      }

    case GHOSTTY_ACTION_GOTO_WINDOW:
      let direction = action.action.goto_window
      perform { [weak self] _, controller in
        self?.owner?.gotoWindow(direction, from: controller)
      }

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      perform { view, owner in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(view?.window?.title ?? "Velocitty", forType: .string)
      }

    case GHOSTTY_ACTION_INITIAL_SIZE:
      let size = action.action.initial_size
      view?.initialSize = NSSize(width: Int(size.width), height: Int(size.height))

    case GHOSTTY_ACTION_SIZE_LIMIT:
      let limit = action.action.size_limit
      perform { view, owner in
        guard let tab = view?.session else { return }
        tab.sizeLimit = limit
        owner?.applySizeLimit(for: tab)
      }

    case GHOSTTY_ACTION_CELL_SIZE:
      let cell = action.action.cell_size
      perform { view, owner in
        guard let window = view?.window,
          NativeSettings(config: view?.config).windowStepResize
        else { return }
        window.contentResizeIncrements = NSSize(
          width: max(1, CGFloat(cell.width) / window.backingScaleFactor),
          height: max(1, CGFloat(cell.height) / window.backingScaleFactor))
      }

    case GHOSTTY_ACTION_COLOR_CHANGE:
      let color = action.action.color_change
      if color.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
        perform { view, owner in
          view?.session?.backgroundColor = NSColor(srgbRed: Double(color.r) / 255,
            green: Double(color.g) / 255, blue: Double(color.b) / 255, alpha: 1)
          if owner?.session === view?.session { owner?.applyBackground() }
        }
      }

    case GHOSTTY_ACTION_PWD:
      let path = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
      perform { view, owner in
        view?.session?.currentDirectory = path
        if let tab = view?.session { owner?.tabMetadataChanged(tab) }
      }

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      perform { view, owner in owner?.resetWindowSize() }

    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      perform { view, owner in (NSApp.delegate as? AppDelegate)?.closeAllWindows() }

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      perform { view, owner in
        guard let delegate = owner else { return }
        do { try view?.session?.toggleOpacity() }
        catch { NSLog("Opacity update failed: %@", error.localizedDescription) }
        if delegate.session === view?.session { delegate.applyWindowSettings() }
      }

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      perform { view, owner in owner?.showCommands() }

    case GHOSTTY_ACTION_RENAME_NAMESPACE:
      guard view?.session?.herdrTerminal != nil else { return false }
      perform { _, owner in owner?.editNamespace() }

    case GHOSTTY_ACTION_NEW_NAMESPACE:
      guard view?.session?.herdrTerminal != nil else { return false }
      perform { _, owner in owner?.newNamespace() }

    case GHOSTTY_ACTION_CLOSE_NAMESPACE:
      guard view?.session?.herdrTerminal != nil else { return false }
      perform { _, owner in owner?.closeNamespace() }

    case GHOSTTY_ACTION_PREVIOUS_NAMESPACE, GHOSTTY_ACTION_NEXT_NAMESPACE:
      guard view?.session?.herdrTerminal != nil else { return false }
      let step = action.tag == GHOSTTY_ACTION_NEXT_NAMESPACE ? 1 : -1
      perform { _, owner in
        guard let owner, let index = owner.namespaces.firstIndex(where: { $0 === owner.activeNamespace }) else { return }
        owner.selectNamespace(at: (index + step + owner.namespaces.count) % owner.namespaces.count)
      }

    case GHOSTTY_ACTION_GOTO_NAMESPACE:
      guard view?.session?.herdrTerminal != nil else { return false }
      let index = Int(action.action.goto_namespace.index) - 1
      perform { _, owner in owner?.selectNamespace(at: index) }

    case GHOSTTY_ACTION_NEW_SPLIT:
      let direction = action.action.new_split
      guard direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_DOWN else { return false }
      perform { view, owner in owner?.splitPane(direction == GHOSTTY_SPLIT_DIRECTION_RIGHT ? "right" : "down", from: view?.session) }

    case GHOSTTY_ACTION_GOTO_SPLIT:
      guard let pane = view?.session, let controller = pane.windowController,
        (controller.tab(for: pane)?.panes.count ?? 0) > 1 else { return false }
      let directions = ["previous", "next", "up", "left", "down", "right"]
      let index = Int(action.action.goto_split.rawValue)
      guard directions.indices.contains(index) else { return false }
      perform { view, owner in owner?.focusPane(directions[index], from: view?.session) }

    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let value = action.action.resize_split
      let directions = ["up", "down", "left", "right"]
      let index = Int(value.direction.rawValue)
      guard directions.indices.contains(index) else { return false }
      perform { view, owner in owner?.resizePane(directions[index], amount: Double(value.amount) / 100, from: view?.session) }

    case GHOSTTY_ACTION_NEW_TAB:
      perform { [weak self] _, owner in
        if let owner { owner.newTab() } else { self?.owner?.newWindow() }
      }

    case GHOSTTY_ACTION_GOTO_TAB:
      let direction = action.action.goto_tab
      perform { view, owner in
        guard let owner, let source = view?.session ?? owner.session,
          let namespace = owner.namespace(for: source) else { return }
        switch direction {
        case GHOSTTY_GOTO_TAB_PREVIOUS: owner.cycleTab(-1, from: view?.session)
        case GHOSTTY_GOTO_TAB_NEXT: owner.cycleTab(1, from: view?.session)
        case GHOSTTY_GOTO_TAB_LAST:
          if let last = namespace.tabs.last { owner.selectTab(last) }
        default:
          let index = Int(direction.rawValue) - 1
          if namespace.tabs.indices.contains(index) { owner.selectTab(namespace.tabs[index]) }
        }
      }

    case GHOSTTY_ACTION_MOVE_TAB:
      let amount = action.action.move_tab.amount
      perform { view, owner in owner?.moveTab(amount, from: view?.session) }

    case GHOSTTY_ACTION_NEW_WINDOW:
      perform { view, owner in (NSApp.delegate as? AppDelegate)?.newWindow() }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      perform { view, owner in
        if let tab = view?.session { owner?.selectTab(tab) }
        owner?.openWindow() ?? (NSApp.delegate as? AppDelegate)?.openWindow()
      }

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      perform { view, owner in view?.window?.zoom(nil) }

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      perform { view, owner in owner?.toggleFullscreen() }

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      perform { view, owner in
        if NSApp.isHidden || !NSApp.isActive {
          NSApp.unhide(nil)
          (NSApp.delegate as? AppDelegate)?.openWindow()
          NSApp.activate(ignoringOtherApps: true)
        } else {
          NSApp.hide(nil)
        }
      }

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      let soft = action.action.reload_config.soft
      perform { view, owner in
        let delegate = NSApp.delegate as? AppDelegate
        if soft { delegate?.refreshAppearance() } else { delegate?.reloadConfiguration(nil) }
      }

    case GHOSTTY_ACTION_OPEN_CONFIG:
      perform { view, owner in
        guard let source = (NSApp.delegate as? AppDelegate)?.runtime?.settings.source else {
          return
        }
        ConfigurationEditor().open(source) { error in
          guard let error else { return }
          DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Could not open configuration"
            alert.informativeText = error.localizedDescription
            alert.runModal()
          }
        }
      }

    case GHOSTTY_ACTION_FLOAT_WINDOW:
      let level = action.action.float_window
      perform { view, owner in
        guard let window = view?.window else { return }
        window.level =
          level == GHOSTTY_FLOAT_WINDOW_ON
            || (level == GHOSTTY_FLOAT_WINDOW_TOGGLE && window.level != .floating)
          ? .floating : .normal
      }

    case GHOSTTY_ACTION_SECURE_INPUT:
      let mode = action.action.secure_input
      perform { view, owner in owner?.secureInput(mode, from: view?.session) }

    case GHOSTTY_ACTION_RING_BELL:
      perform { view, owner in owner?.ringBell(from: view?.session) }

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let notification = action.action.desktop_notification
      let title = notification.title.map { String(cString: $0) } ?? "Velocitty"
      let body = notification.body.map { String(cString: $0) } ?? ""
      perform { view, owner in owner?.notify(title: title, body: body) }

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let value = action.action.command_finished
      perform { view, owner in owner?.commandFinished(value, from: view?.session) }

    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let value = action.action.progress_report
      perform { view, _ in
        if NativeSettings(config: view?.config).progressStyle { view?.session?.chrome?.progress.update(value) }
        else { view?.session?.chrome?.progress.clear() }
      }

    case GHOSTTY_ACTION_START_SEARCH:
      let needle = action.action.start_search.needle.map { String(cString: $0) }
      perform { view, owner in view?.session?.chrome?.startSearch(needle) }

    case GHOSTTY_ACTION_END_SEARCH:
      perform { view, owner in view?.session?.chrome?.hideSearch() }

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = action.action.search_total.total
      perform { view, owner in
        let chrome = view?.session?.chrome
        chrome?.total = total
        chrome?.updateCount()
      }

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = action.action.search_selected.selected
      perform { view, owner in
        let chrome = view?.session?.chrome
        chrome?.selected = selected
        chrome?.updateCount()
      }

    case GHOSTTY_ACTION_SELECTION_CHANGED:
      perform { view, _ in view?.accessibilitySelectionChanged() }

    case GHOSTTY_ACTION_SCROLLBAR:
      let state = action.action.scrollbar
      perform { view, owner in view?.session?.chrome?.updateScrollbar(state) }

    case GHOSTTY_ACTION_OPEN_URL:
      let link = action.action.open_url
      guard let ptr = link.url,
        let value = String(
          bytes: UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(link.len)),
          encoding: .utf8)
      else { return true }
      perform { view, owner in view?.session?.links.open(value, kind: link.kind, from: view) }

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      let value = link.url.map {
        String(
          decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: Int(link.len)),
          as: UTF8.self)
      }
      perform { view, owner in
        view?.linkURL = value
        view?.toolTip = value
      }

    case GHOSTTY_ACTION_MOUSE_SHAPE:
      let shape = action.action.mouse_shape
      perform { view, owner in
        let cursor: NSCursor =
          shape == GHOSTTY_MOUSE_SHAPE_POINTER
          ? .pointingHand : shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam : .arrow
        view?.pointer = cursor
        if view?.pointerIsInside == true { cursor.set() }
      }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
      perform { view, owner in
        if view?.pointerIsInside == true { NSCursor.setHiddenUntilMouseMoves(hidden) }
      }

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      perform { _, owner in owner?.window?.performClose(nil) }

    case GHOSTTY_ACTION_CLOSE_TAB:
      let mode = action.action.close_tab_mode
      perform { view, owner in owner?.closeTabs(mode, from: view?.session) }

    case GHOSTTY_ACTION_QUIT:
      perform { view, owner in
        NSApp.terminate(nil)
      }

    default:
      return false
    }

    return true
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
