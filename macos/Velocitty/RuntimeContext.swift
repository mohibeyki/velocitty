// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class RuntimeContext: NSObject {
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
               let userdata = velokit_surface_userdata(surface) {
                return Self.fromSurfaceUserdata(userdata)
            }
            return nil
        }()

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            if let surface = target.target.surface {
                velokit_surface_draw(surface)
            }

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_WINDOW_TITLE:
            guard let title = action.action.set_title.title.map({ String(cString: $0) }) else {
                return true
            }
            DispatchQueue.main.async {
                view?.window?.title = title
            }

        case GHOSTTY_ACTION_OPEN_URL:
            let link = action.action.open_url
            guard let ptr = link.url, let url = URL(string: String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(link.len)), as: UTF8.self)) else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = action.action.mouse_over_link
            let value = link.url.map { String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: Int(link.len)), as: UTF8.self) }
            DispatchQueue.main.async { view?.linkURL = value; view?.toolTip = value }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                let cursor: NSCursor = shape == GHOSTTY_MOUSE_SHAPE_POINTER ? .pointingHand : shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam : .arrow
                view?.pointer = cursor
                cursor.set()
            }

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }

        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            DispatchQueue.main.async {
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

    static let readClipboard: ghostty_runtime_read_clipboard_cb = {
        userdata, location, state, _, _, _ in
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = RuntimeContext.fromSurfaceUserdata(userdata),
              let surface = view.surface,
              let string = NSPasteboard.general.string(forType: .string)
        else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        var bytes = Array(string.utf8)
        if bytes.isEmpty { bytes = [0] }
        let mime = "text/plain"
        mime.withCString { mimePtr in
            bytes.withUnsafeBufferPointer { buffer in
                let data = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
                var content = ghostty_clipboard_content_s(
                    mime: mimePtr,
                    data: data,
                    len: string.utf8.count)
                withUnsafePointer(to: &content) { contentPointer in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentPointer,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: false,
                        remember: false)
                    velokit_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }

        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static let confirmReadClipboard: ghostty_runtime_confirm_read_clipboard_cb = {
        userdata, _, state, _ in
        guard let view = RuntimeContext.fromSurfaceUserdata(userdata),
              let surface = view.surface
        else { return }
        velokit_surface_deny_clipboard_request(surface, state)
    }

    static let writeClipboard: ghostty_runtime_write_clipboard_cb = {
        _, location, content, length, needsConfirmation in
        guard !needsConfirmation, location == GHOSTTY_CLIPBOARD_STANDARD,
              content != nil,
              length > 0
        else { return }

        for index in 0..<length {
            let item = content![index]
            guard let mime = item.mime,
                  String(cString: mime) == "text/plain",
                  item.len > 0,
                  let data = item.data
            else { continue }

            let bytes = Data(bytes: data, count: item.len)
            guard let string = String(data: bytes, encoding: .utf8) else { continue }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
            break
        }
    }

    static let closeSurface: ghostty_runtime_close_surface_cb = { userdata, _ in
        guard let view = RuntimeContext.fromSurfaceUserdata(userdata) else { return }
        DispatchQueue.main.async {
            view.window?.performClose(nil)
        }
    }
}

