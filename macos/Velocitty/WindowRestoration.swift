// SPDX-License-Identifier: GPL-3.0
import AppKit
import VelocittyConfiguration

final class TerminalWindowRestoration: NSObject, NSWindowRestoration {
  static let identifier = NSUserInterfaceItemIdentifier("TerminalWindow")
  static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
    state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void)
  {
    guard identifier == Self.identifier, let owner = NSApp.delegate as? AppDelegate else {
      completionHandler(nil, ConfigurationError("Unknown restorable window."))
      return
    }
    do {
      if owner.runtime == nil { owner.runtime = try TerminalRuntime(settings: AppConfiguration.load()) }
      guard owner.herdr == nil, let runtime = owner.runtime, runtime.settings.options.last(where: {
        $0.key == "window-save-state"
      })?.value != "never", state.decodeInteger(forKey: "terminalVersion") == 1 else {
        completionHandler(nil, nil)
        return
      }
      let session = runtime.makeSession()
      if let path = state.decodeObject(of: NSString.self, forKey: "directory") as String?,
        path.hasPrefix("/"), !path.contains("\0") {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
          session.initialDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
      }
      let controller = TerminalWindowController(session: session, owner: owner)
      owner.windows.append(controller)
      controller.openWindow(restoring: true)
      guard let window = controller.window else {
        owner.windows.removeAll { $0 === controller }
        session.close()
        completionHandler(nil, ConfigurationError("Could not restore terminal window."))
        return
      }
      if let title = state.decodeObject(of: NSString.self, forKey: "title") as String? {
        controller.windowTitleOverride = title
        controller.setTitle(controller.terminalTitle)
      }
      let mode = state.decodeObject(of: NSString.self, forKey: "fullscreenMode") as String?
      let normalFrame = state.decodeObject(of: NSString.self, forKey: "normalFrame") as String?
      completionHandler(window, nil)
      // AppKit owns native fullscreen. Restore our borderless mode afterwards.
      if let mode, ["true", "visible-menu", "padded-notch"].contains(mode) {
        DispatchQueue.main.async { [weak controller] in
          if let normalFrame { controller?.window?.setFrame(NSRectFromString(normalFrame), display: false) }
          controller?.toggleFullscreen(modeOverride: mode)
        }
      }
    } catch { completionHandler(nil, error) }
  }
}

extension TerminalWindowController {
  func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    state.encode(1, forKey: "terminalVersion")
    state.encode(currentDirectory, forKey: "directory")
    state.encode(windowTitleOverride, forKey: "title")
    state.encode(fullscreenMode, forKey: "fullscreenMode")
    state.encode(normalFrame.map(NSStringFromRect), forKey: "normalFrame")
  }
}
