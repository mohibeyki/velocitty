// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit

// Terminal output may select a URL handler, but only the user may approve unusual ones.
final class TerminalLinks {
  enum Destination: Equatable {
    case reject
    case direct(URL)
    case confirm(URL)
  }

  private let openURL: (URL) -> Void
  private(set) var confirmation: NSAlert?

  init(openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    self.openURL = openURL
  }

  static func destination(_ value: String, kind: ghostty_action_open_url_kind_e) -> Destination {
    // These are engine-generated export paths, not terminal-supplied hyperlinks.
    if kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT || kind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML {
      guard value.hasPrefix("/"), !value.contains("\0") else { return .reject }
      return .direct(URL(fileURLWithPath: value))
    }
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
      }), !value.contains("\\")
    else { return .reject }
    // Foundation can repair malformed percent escapes; require an actual URL instead.
    let bytes = Array(value.utf8)
    for index in bytes.indices where bytes[index] == 0x25 {
      guard index + 2 < bytes.count,
        bytes[(index + 1)...(index + 2)].allSatisfy({
          (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
        }) else { return .reject }
    }
    guard let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(), let url = components.url
    else { return .reject }
    switch scheme {
    case "javascript", "data":
      return .reject
    case "http", "https":
      guard let host = components.host, !host.isEmpty else { return .reject }
      if let port = components.port, !(0...65535).contains(port) { return .reject }
      return .direct(url)
    case "mailto":
      return .direct(url)
    default:
      return .confirm(url)
    }
  }

  func open(_ value: String, kind: ghostty_action_open_url_kind_e, from view: TerminalView?) {
    switch Self.destination(value, kind: kind) {
    case .reject:
      return
    case .direct(let url):
      openURL(url)
    case .confirm(let url):
      guard confirmation == nil, let view, let surface = view.surface,
        let window = view.window, window.isVisible, window.attachedSheet == nil
      else { return }
      let alert = NSAlert()
      alert.messageText = "Open this terminal link?"
      alert.informativeText = "This link will open a file or another application. Review its destination before opening it."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Open")
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 110))
      scroll.hasVerticalScroller = true
      scroll.borderType = .bezelBorder
      let destination = NSTextView(frame: scroll.bounds)
      destination.isEditable = false
      destination.isSelectable = true
      destination.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      destination.string = url.absoluteString
      destination.textContainerInset = NSSize(width: 6, height: 6)
      destination.isVerticallyResizable = true
      destination.maxSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
      destination.autoresizingMask = [.width]
      destination.textContainer?.widthTracksTextView = true
      destination.setAccessibilityLabel("Link destination")
      scroll.documentView = destination
      alert.accessoryView = scroll
      confirmation = alert
      alert.beginSheetModal(for: window) { [weak self, weak view, weak alert] response in
        guard let self, let alert, self.confirmation === alert else { return }
        self.confirmation = nil
        guard response == .alertSecondButtonReturn,
          view?.surface == surface, view?.window === window, window.isVisible
        else { return }
        self.openURL(url)
      }
      // Presenting a sheet resets NSAlert shortcuts, so configure the safe default afterward.
      alert.buttons[0].keyEquivalent = "\r"
      alert.buttons[1].keyEquivalent = ""
      alert.window.defaultButtonCell = alert.buttons[0].cell as? NSButtonCell
    }
  }

  func cancel() {
    guard let alert = confirmation else { return }
    confirmation = nil
    alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
  }
}
