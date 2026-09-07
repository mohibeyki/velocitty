// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon

// Only this owner balances process-wide Carbon calls. Failed releases remain
// owned and are retried on the next state transition, as in upstream.
final class SecureInputOwner {
  var acquire: () -> OSStatus = { EnableSecureEventInput() }
  var release: () -> OSStatus = { DisableSecureEventInput() }
  private(set) var enabled = false
  func update(wanted: Bool) {
    guard wanted != enabled else { return }
    let result = wanted ? acquire() : release()
    if result == noErr { enabled = wanted }
    else { NSLog("Secure Input update failed: %d", result) }
  }
  deinit { if enabled { _ = release() } }
}

// Presentation options belong to the app, not to each fullscreen window.
final class FullscreenPresentation {
  private var previous: NSApplication.PresentationOptions?
  func update(_ options: NSApplication.PresentationOptions?) {
    if let options {
      if previous == nil { previous = NSApp.presentationOptions }
      NSApp.presentationOptions = options
    } else if let previous {
      NSApp.presentationOptions = previous
      self.previous = nil
    }
  }
}
