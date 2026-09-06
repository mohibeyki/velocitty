// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class RuntimeContext: NSObject {
  weak var owner: TerminalWindowController?
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

    // Pending callbacks from a closed surface must not update its replacement.
    let surfaceTarget = target.tag == GHOSTTY_TARGET_SURFACE
    let perform: (@escaping () -> Void) -> Void = { [weak view] body in
      DispatchQueue.main.async {
        if surfaceTarget && view?.surface == nil { return }
        body()
      }
    }
    let owner = self.owner
    switch action.tag {
    case GHOSTTY_ACTION_RENDER:
      if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
        velokit_surface_draw(surface)
      }

    case GHOSTTY_ACTION_SET_TITLE:
      guard let title = action.action.set_title.title.map({ String(cString: $0) }) else {
        return true
      }
      perform {
        owner?.setTitle(title)
      }

    case GHOSTTY_ACTION_SET_WINDOW_TITLE:
      let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
      perform {
        guard let delegate = owner else { return }
        delegate.windowTitleOverride = title.isEmpty ? nil : title
        delegate.setTitle(delegate.terminalTitle)
      }

    case GHOSTTY_ACTION_PROMPT_TITLE:
      let mode = action.action.prompt_title
      guard mode != GHOSTTY_PROMPT_TITLE_TAB else { return false }
      perform { owner?.promptTitle(mode) }

    case GHOSTTY_ACTION_READONLY:
      let readonly = action.action.readonly == GHOSTTY_READONLY_ON
      perform {
        let delegate = owner
        delegate?.readonly = readonly
        delegate?.updateSecureInput()
      }

    case GHOSTTY_ACTION_QUIT_TIMER:
      let start = action.action.quit_timer == GHOSTTY_QUIT_TIMER_START
      perform {
        let delegate = NSApp.delegate as? AppDelegate
        if start { delegate?.scheduleQuitIfNeeded() } else { delegate?.quitTimer?.invalidate() }
      }

    case GHOSTTY_ACTION_GOTO_WINDOW:
      perform { owner?.openWindow() }

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      perform {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(view?.window?.title ?? "Velocitty", forType: .string)
      }

    case GHOSTTY_ACTION_INITIAL_SIZE:
      let size = action.action.initial_size
      view?.initialSize = NSSize(width: Int(size.width), height: Int(size.height))

    case GHOSTTY_ACTION_SIZE_LIMIT:
      let limit = action.action.size_limit
      perform {
        guard let window = view?.window else { return }
        let scale = window.backingScaleFactor
        window.contentMinSize = NSSize(
          width: CGFloat(limit.min_width) / scale, height: CGFloat(limit.min_height) / scale)
      }

    case GHOSTTY_ACTION_CELL_SIZE:
      let cell = action.action.cell_size
      perform {
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
        perform {
          guard let window = view?.window else { return }
          let alpha = window.backgroundColor.alphaComponent
          window.backgroundColor = NSColor(
            srgbRed: Double(color.r) / 255, green: Double(color.g) / 255,
            blue: Double(color.b) / 255, alpha: alpha)
        }
      }

    case GHOSTTY_ACTION_PWD:
      let path = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
      perform { owner?.setDirectory(path) }

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      perform { owner?.resetWindowSize() }

    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      perform { (NSApp.delegate as? AppDelegate)?.closeAllWindows() }

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      perform {
        guard let delegate = owner else { return }
        delegate.opacityOverride = delegate.opacityOverride == nil ? 1 : nil
        delegate.runtime?.opacityOverride = delegate.opacityOverride
        if let runtime = delegate.runtime { try? runtime.updateConfiguration(runtime.settings) }
        delegate.applyWindowSettings()
      }

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      perform { owner?.showCommands() }

    case GHOSTTY_ACTION_NEW_WINDOW:
      perform { (NSApp.delegate as? AppDelegate)?.newWindow() }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      perform { owner?.openWindow() ?? (NSApp.delegate as? AppDelegate)?.openWindow() }

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      perform { view?.window?.zoom(nil) }

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      perform { owner?.toggleFullscreen() }

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      perform {
        guard let window = view?.window else { return }
        if window.styleMask.contains(.titled) {
          window.styleMask.remove(.titled)
        } else {
          window.styleMask.insert(.titled)
        }
      }

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      perform {
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
      perform {
        let delegate = NSApp.delegate as? AppDelegate
        if soft { delegate?.refreshAppearance() } else { delegate?.reloadConfiguration(nil) }
      }

    case GHOSTTY_ACTION_OPEN_CONFIG:
      perform {
        guard let source = (NSApp.delegate as? AppDelegate)?.runtime?.settings.source else {
          return
        }
        if FileManager.default.fileExists(atPath: source.path) {
          NSWorkspace.shared.open(source)
        } else {
          let alert = NSAlert()
          alert.messageText = "Create a configuration file"
          alert.informativeText =
            "Create this TOML file in your text editor, then use Reload Configuration:\n\n"
            + source.path
          alert.addButton(withTitle: "OK")
          if let window = view?.window { alert.beginSheetModal(for: window) }
        }
      }

    case GHOSTTY_ACTION_FLOAT_WINDOW:
      let level = action.action.float_window
      perform {
        guard let window = view?.window else { return }
        window.level =
          level == GHOSTTY_FLOAT_WINDOW_ON
            || (level == GHOSTTY_FLOAT_WINDOW_TOGGLE && window.level != .floating)
          ? .floating : .normal
      }

    case GHOSTTY_ACTION_SECURE_INPUT:
      let mode = action.action.secure_input
      perform { owner?.secureInput(mode) }

    case GHOSTTY_ACTION_RING_BELL:
      perform { owner?.ringBell() }

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let notification = action.action.desktop_notification
      let title = notification.title.map { String(cString: $0) } ?? "Velocitty"
      let body = notification.body.map { String(cString: $0) } ?? ""
      perform { owner?.notify(title: title, body: body) }

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let value = action.action.command_finished
      perform { owner?.commandFinished(value) }

    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let value = action.action.progress_report
      perform { owner?.showProgress(value) }

    case GHOSTTY_ACTION_START_SEARCH:
      let needle = action.action.start_search.needle.map { String(cString: $0) }
      perform { owner?.chrome?.startSearch(needle) }

    case GHOSTTY_ACTION_END_SEARCH:
      perform { owner?.chrome?.hideSearch() }

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = action.action.search_total.total
      perform {
        let chrome = owner?.chrome
        chrome?.total = total
        chrome?.updateCount()
      }

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = action.action.search_selected.selected
      perform {
        let chrome = owner?.chrome
        chrome?.selected = selected
        chrome?.updateCount()
      }

    case GHOSTTY_ACTION_SCROLLBAR:
      let state = action.action.scrollbar
      perform { owner?.chrome?.updateScrollbar(state) }

    case GHOSTTY_ACTION_OPEN_URL:
      let link = action.action.open_url
      guard let ptr = link.url else { return false }
      let value = String(
        decoding: UnsafeBufferPointer(
          start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(link.len)),
        as: UTF8.self)
      let url =
        link.kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
          || link.kind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML
        ? URL(fileURLWithPath: value) : URL(string: value)
      guard let url else { return false }
      perform { NSWorkspace.shared.open(url) }

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      let value = link.url.map {
        String(
          decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: Int(link.len)),
          as: UTF8.self)
      }
      perform {
        view?.linkURL = value
        view?.toolTip = value
      }

    case GHOSTTY_ACTION_MOUSE_SHAPE:
      let shape = action.action.mouse_shape
      perform {
        let cursor: NSCursor =
          shape == GHOSTTY_MOUSE_SHAPE_POINTER
          ? .pointingHand : shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam : .arrow
        view?.pointer = cursor
        cursor.set()
      }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
      perform { NSCursor.setHiddenUntilMouseMoves(hidden) }

    case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
      perform { view?.window?.performClose(nil) }

    case GHOSTTY_ACTION_QUIT:
      perform {
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
    userdata, request, state, _ in
    guard let view = RuntimeContext.fromSurfaceUserdata(userdata), let surface = view.surface,
      let request
    else { return }
    // Copy callback-owned bytes before scheduling the sheet.
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
    DispatchQueue.main.async { [weak view] in
      guard let view, view.surface == surface, let window = view.window else { return }
      let alert = NSAlert()
      alert.messageText = "Allow clipboard access?"
      alert.informativeText =
        "\(name) requested clipboard content or a paste requiring confirmation.\n\n"
        + String(String(data: items.first?.1 ?? Data(), encoding: .utf8)?.prefix(500) ?? "")
      alert.addButton(withTitle: "Allow Once")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = canRemember
      alert.suppressionButton?.title = "Remember for this terminal"
      alert.beginSheetModal(for: window) { [weak view] response in
        guard view?.surface == surface else { return }
        guard response == .alertFirstButtonReturn else {
          velokit_surface_deny_clipboard_request(surface, state)
          return
        }
        RuntimeContext.completeClipboard(
          items, surface: surface, state: state, confirmed: true, available: available,
          remember: canRemember && alert.suppressionButton?.state == .on)
      }
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
    let view = RuntimeContext.fromSurfaceUserdata(userdata)
    DispatchQueue.main.async { [weak view] in
      let write = {
        let board = RuntimeContext.pasteboard(location)
        board.clearContents()
        for (type, data) in items { board.setData(data, forType: type) }
      }
      guard needsConfirmation else {
        write()
        return
      }
      guard let window = view?.window else { return }
      let alert = NSAlert()
      alert.messageText = "Replace clipboard contents?"
      alert.informativeText = "A program in this terminal wants to write to your clipboard."
      alert.addButton(withTitle: "Allow Once")
      alert.addButton(withTitle: "Cancel")
      alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { write() }
      }
    }
  }

  static let closeSurface: ghostty_runtime_close_surface_cb = { userdata, _ in
    guard let view = RuntimeContext.fromSurfaceUserdata(userdata) else { return }
    DispatchQueue.main.async {
      view.window?.performClose(nil)
    }
  }
}
