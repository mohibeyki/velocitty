// SPDX-License-Identifier: GPL-3.0
import AppKit
import Darwin

// Numeric blur follows the same WindowServer API used by upstream's macOS host.
// Resolve it dynamically so an unavailable private symbol cannot prevent launch.
enum WindowAppearance {
  private typealias Connection = @convention(c) () -> UnsafeMutableRawPointer
  private typealias SetRadius = @convention(c) (UnsafeMutableRawPointer, UInt, Int32) -> Int32
  static func setBlur(_ radius: Int16, on window: NSWindow) {
    guard window.isVisible,
      let connection = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSDefaultConnectionForThread"),
      let setRadius = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowBackgroundBlurRadius")
    else { return }
    let result = unsafeBitCast(setRadius, to: SetRadius.self)(
      unsafeBitCast(connection, to: Connection.self)(), UInt(window.windowNumber), Int32(max(0, radius)))
    if result != 0 { NSLog("Could not apply window blur: %d", result) }
  }

  static func apply(to window: NSWindow, terminal: TerminalChrome, native: NativeSettings,
    forceOpaque: Bool)
  {
    let opaque = forceOpaque || window.styleMask.contains(.fullScreen)
    let opacity = opaque ? 1 : native.backgroundOpacity
    var glass = false
    if #available(macOS 26, *) { glass = !opaque && native.backgroundBlur < 0 }
    window.isOpaque = opacity >= 1 && !glass
    window.backgroundColor = glass ? .clear : native.background.withAlphaComponent(opacity)
    if #available(macOS 26, *), glass {
      let effect: NSGlassEffectView
      if let existing = window.contentView as? NSGlassEffectView { effect = existing }
      else {
        effect = NSGlassEffectView(frame: terminal.frame)
        terminal.removeFromSuperview()
        window.contentView = effect
        effect.contentView = terminal
        terminal.frame = effect.bounds
        terminal.autoresizingMask = [.width, .height]
      }
      effect.style = native.backgroundBlur == -2 ? .clear : .regular
      effect.tintColor = native.background.withAlphaComponent(opacity)
      effect.cornerRadius = window.styleMask.contains(.titled) ? 10 : 0
    } else if window.contentView !== terminal {
      terminal.removeFromSuperview()
      window.contentView = terminal
    }
    setBlur(!opaque && opacity < 1 && !glass ? native.backgroundBlur : 0, on: window)
  }
}
