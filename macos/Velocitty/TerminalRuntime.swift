// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class TerminalRuntime {
  let context = RuntimeContext()
  private(set) var config: ghostty_config_t?
  private(set) var app: ghostty_app_t?
  private let sessions = NSHashTable<TerminalSession>.weakObjects()
  private(set) var settings: AppConfiguration

  static func makeConfig(_ settings: AppConfiguration, opacityOverride: Double? = nil) throws
    -> ghostty_config_t
  {
    guard let config = velokit_config_new() else {
      throw ConfigurationError("Could not allocate the terminal configuration.")
    }
    func failure(_ context: String, source: URL? = nil) -> ConfigurationError {
      let detail = velokit_config_error(config).map { String(cString: $0) } ?? context
      return ConfigurationError("\((source ?? settings.source).path): \(detail)")
    }
    do {
      for option in try TerminalTheme.options(
        for: settings,
        dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
      {
        let accepted = option.key.withCString { key in
          option.value.withCString { velokit_config_set(config, key, $0) }
        }
        guard accepted else {
          throw failure("Invalid terminal setting: \(option.key)", source: option.source)
        }
      }
      if let opacityOverride {
        _ = String(opacityOverride).withCString {
          velokit_config_set(config, "background-opacity", $0)
        }
      }
      let finalized = settings.source.deletingLastPathComponent().path.withCString {
        velokit_config_finalize(config, $0)
      }
      guard finalized else { throw failure("Could not finalize the terminal configuration.") }
      return config
    } catch {
      velokit_config_free(config)
      throw error
    }
  }

  init(settings: AppConfiguration) throws {
    self.settings = settings
    let config = try Self.makeConfig(settings)
    self.config = config

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(context).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: RuntimeContext.wakeup,
      action_cb: RuntimeContext.action,
      read_clipboard_cb: RuntimeContext.readClipboard,
      confirm_read_clipboard_cb: RuntimeContext.confirmReadClipboard,
      write_clipboard_cb: RuntimeContext.writeClipboard,
      close_surface_cb: RuntimeContext.closeSurface)

    guard let app = velokit_app_new(&runtimeConfig, config) else {
      velokit_config_free(config)
      self.config = nil
      throw ConfigurationError("VeloKit could not initialize the terminal application.")
    }

    self.app = app
    context.app = app
    velokit_app_set_focus(app, NSApp.isActive)
    velokit_app_set_color_scheme(
      app, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
  }

  func makeSession() -> TerminalSession {
    let session = TerminalSession(runtime: self)
    sessions.add(session)
    return session
  }

  func remove(_ session: TerminalSession) { sessions.remove(session) }

  func updateFocus() {
    if let app { velokit_app_set_focus(app, NSApp.isActive) }
    for session in sessions.allObjects { session.view?.updateFocus() }
  }

  func updateConfiguration(_ settings: AppConfiguration) throws {
    guard let app else { return }
    let updated = try Self.makeConfig(settings)
    guard velokit_app_update_config(app, updated) else {
      velokit_config_free(updated)
      throw ConfigurationError("VeloKit could not apply the configuration.")
    }
    let previous = config
    config = updated
    self.settings = settings
    defer { if let previous { velokit_config_free(previous) } }
    for session in sessions.allObjects { try session.refreshConfiguration() }
    velokit_app_set_color_scheme(
      app, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
  }

  deinit {
    // Queued wakeups retain the context beyond this runtime's lifetime.
    context.app = nil
    context.owner = nil
    if let app { velokit_app_free(app) }
    if let config { velokit_config_free(config) }
  }
}
