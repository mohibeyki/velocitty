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
  private(set) var diagnostics: [String] = []

  static func makeConfig(
    _ settings: AppConfiguration,
    diagnostic: (String) -> Void = { NSLog("Configuration: %@", $0) }
  ) throws -> ghostty_config_t {
    func allocate() throws -> ghostty_config_t {
      guard let config = velokit_config_new() else {
        throw ConfigurationError("Could not allocate the terminal configuration.")
      }
      return config
    }
    func set(_ option: TerminalOption, on config: ghostty_config_t) -> Bool {
      option.key.withCString { key in
        option.value.withCString { velokit_config_set(config, key, $0) }
      }
    }
    var config = try allocate()
    do {
      // Keep only accepted inputs. Rebuild on an invalid value to discard any
      // partial parser mutation (including non-finite numbers and repeatables).
      var accepted: [TerminalOption] = []
      for option in try TerminalTheme.options(
        for: settings,
        dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
        diagnostic: diagnostic)
      {
        if set(option, on: config) {
          accepted.append(option)
          continue
        }
        guard let message = velokit_config_error(config).map({ String(cString: $0) }) else {
          throw ConfigurationError("Could not prepare terminal setting: \(option.key)")
        }
        diagnostic("\((option.source ?? settings.source).path): \(message)")
        let clean = try allocate()
        velokit_config_free(config)
        config = clean
        for previous in accepted {
          guard set(previous, on: config) else {
            throw ConfigurationError("Could not prepare terminal setting: \(previous.key)")
          }
        }
      }
      guard
        settings.source.deletingLastPathComponent().path.withCString({
          velokit_config_finalize(config, $0)
        })
      else { throw ConfigurationError("Could not finalize the terminal configuration.") }
      var index: UInt = 0
      while let message = velokit_config_diagnostic(config, index) {
        diagnostic("\(settings.source.path): \(String(cString: message))")
        index += 1
      }
      return config
    } catch {
      velokit_config_free(config)
      throw error
    }
  }

  // Called synchronously: the engine's notification pointer is borrowed.
  func configurationChanged(_ applied: ghostty_config_t) -> Bool {
    guard let copy = velokit_config_clone(applied) else { return false }
    if let config { velokit_config_free(config) }
    config = copy
    return true
  }

  init(settings: AppConfiguration) throws {
    self.settings = settings
    var diagnostics = settings.diagnostics
    let config = try Self.makeConfig(settings) { diagnostics.append($0) }
    self.config = config
    self.diagnostics = diagnostics

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
    context.runtime = self
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
    var diagnostics = settings.diagnostics
    let updated = try Self.makeConfig(settings) { diagnostics.append($0) }
    defer { velokit_config_free(updated) }
    let terminals = sessions.allObjects
    var overrides: [(TerminalSession, ghostty_config_t)] = []
    defer { for (_, config) in overrides { velokit_config_free(config) } }
    // No file reads or configuration preparation once application starts.
    for session in terminals {
      if let config = try session.prepareOverride(from: updated) {
        overrides.append((session, config))
      }
    }

    // Like Ghostty, apply best-effort. Config-change notifications own the
    // host's applied snapshots; failures do not trigger a rollback.
    if velokit_app_update_config(app, updated) {
      self.settings = settings
    } else {
      diagnostics.append("VeloKit could not update every terminal. Some settings may have applied.")
    }
    for (session, config) in overrides {
      if !session.applyPreparedConfiguration(config) {
        diagnostics.append("VeloKit could not apply a terminal's opacity override.")
      }
    }
    for session in terminals {
      if let surface = session.surface {
        velokit_surface_set_color_scheme(
          surface, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
      }
    }
    velokit_app_set_color_scheme(
      app, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
    var seen: Set<String> = []
    self.diagnostics = diagnostics.filter { seen.insert($0).inserted }
    context.owner?.configurationDidChange()
  }

  deinit {
    // Queued wakeups retain the context beyond this runtime's lifetime.
    context.app = nil
    context.owner = nil
    if let app { velokit_app_free(app) }
    if let config { velokit_config_free(config) }
  }
}
