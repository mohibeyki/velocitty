// SPDX-License-Identifier: GPL-3.0
import AppKit

// Registered synchronously on the engine's UI thread, before deferring any UI work.
// The terminal must cancel these requests while its native surface is still alive.
final class TerminalClipboard {
  private struct Request {
    let title: String
    let message: String
    let canRemember: Bool
    let reply: (Bool, Bool) -> Void
  }

  private weak var view: TerminalView?
  private var pending: [Request] = []
  private var active: Request?
  private var sheetObserver: NSObjectProtocol?
  private var closed = false
  private(set) var confirmation: NSAlert?

  init(view: TerminalView) { self.view = view }

  func enqueue(
    title: String, message: String, canRemember: Bool = false,
    reply: @escaping (Bool, Bool) -> Void
  ) {
    precondition(Thread.isMainThread)
    guard !closed else { reply(false, false); return }
    pending.append(Request(title: title, message: message, canRemember: canRemember, reply: reply))
    schedulePresentation()
  }

  private func schedulePresentation() {
    DispatchQueue.main.async { [weak self] in self?.presentNext() }
  }

  private func presentNext() {
    guard !closed, active == nil, !pending.isEmpty else { return }
    guard let view, view.surface != nil, let window = view.window, window.isVisible else {
      let abandoned = pending
      pending.removeAll()
      abandoned.forEach { $0.reply(false, false) }
      return
    }
    // Wait for other sheets too, such as external-link confirmations.
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    sheetObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEndSheetNotification, object: window, queue: .main
    ) { [weak self] _ in self?.schedulePresentation() }
    guard window.attachedSheet == nil else { return }

    let request = pending.removeFirst()
    let alert = NSAlert()
    alert.messageText = request.title
    alert.informativeText = request.message
    alert.addButton(withTitle: "Allow Once")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = request.canRemember
    alert.suppressionButton?.title = "Remember for this terminal"
    active = request
    confirmation = alert
    alert.beginSheetModal(for: window) { [weak self, weak alert] response in
      guard let self, let alert, self.confirmation === alert, let request = self.active else { return }
      self.active = nil
      self.confirmation = nil
      let allowed = response == .alertFirstButtonReturn
      request.reply(allowed, allowed && request.canRemember && alert.suppressionButton?.state == .on)
      self.schedulePresentation()
    }
  }

  func cancel() {
    precondition(Thread.isMainThread)
    closed = true
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    sheetObserver = nil
    let requests = active.map { [$0] + pending } ?? pending
    let alert = confirmation
    active = nil
    confirmation = nil
    pending.removeAll()
    // Invalidate the sheet callback before ending it; only this path sends replies.
    requests.forEach { $0.reply(false, false) }
    if let alert {
      alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
    }
  }

  deinit {
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    assert(active == nil && pending.isEmpty, "Clipboard requests must be cancelled before surface teardown")
  }
}
