// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit
import VelocittyConfiguration

// A terminal owns its native surface and backing view, independently of presentation.
// Retaining the runtime guarantees the engine outlives every surface using it.
final class TerminalSession {
  let runtime: TerminalRuntime
  weak var windowController: TerminalWindowController?
  private(set) var surface: ghostty_surface_t?
  private(set) var view: TerminalView?
  private var appliedConfig: ghostty_config_t?
  private(set) var opacityOverride: Double?
  private var closed = false
  var links = TerminalLinks()

  var settings: AppConfiguration { runtime.settings }
  var config: ghostty_config_t? { closed ? nil : appliedConfig ?? runtime.config }

  init(runtime: TerminalRuntime) { self.runtime = runtime }

  func createView() -> TerminalView? {
    guard !closed, let app = runtime.app else { return nil }
    if let view { return view }
    let terminalView = TerminalView(session: self)
    view = terminalView
    var options = velokit_surface_config_new()
    let pointer = Unmanaged.passUnretained(terminalView).toOpaque()
    options.userdata = pointer
    options.platform_tag = GHOSTTY_PLATFORM_MACOS
    options.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: pointer))
    options.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
    options.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    surface = settings.workingDirectory.path.withCString {
      options.working_directory = $0
      return velokit_surface_new(app, &options)
    }
    guard surface != nil else {
      view = nil
      return nil
    }
    terminalView.updateFocus()
    return terminalView
  }

  func toggleOpacity() throws {
    guard !closed, let base = runtime.config else { return }
    let value: Double? = opacityOverride == nil ? 1 : nil
    let candidate = try Self.prepareConfig(from: base, opacity: value)
    defer { velokit_config_free(candidate) }
    guard applyPreparedConfiguration(candidate) else {
      throw ConfigurationError("VeloKit could not apply the terminal configuration.")
    }
    opacityOverride = value
  }

  func prepareOverride(from base: ghostty_config_t) throws -> ghostty_config_t? {
    guard !closed, surface != nil, let opacityOverride else { return nil }
    return try Self.prepareConfig(from: base, opacity: opacityOverride)
  }

  private static func prepareConfig(from base: ghostty_config_t, opacity: Double?) throws
    -> ghostty_config_t
  {
    guard let candidate = velokit_config_clone(base) else {
      throw ConfigurationError("Could not copy the terminal configuration.")
    }
    // The base is already finalized. Only this scalar needs changing.
    if let opacity,
      !String(opacity).withCString({ velokit_config_set(candidate, "background-opacity", $0) })
    {
      velokit_config_free(candidate)
      throw ConfigurationError("Could not prepare the opacity override.")
    }
    return candidate
  }

  func applyPreparedConfiguration(_ config: ghostty_config_t) -> Bool {
    guard !closed, let surface else { return true }
    return velokit_surface_update_config(surface, config)
  }

  func configurationChanged(_ config: ghostty_config_t) -> Bool {
    guard !closed, let copy = velokit_config_clone(config) else { return false }
    if let appliedConfig { velokit_config_free(appliedConfig) }
    appliedConfig = copy
    return true
  }

  func close() {
    guard !closed else { return }
    view?.clipboard.cancel()
    links.cancel()
    let previous = surface
    surface = nil
    closed = true
    windowController = nil
    if let previous { velokit_surface_free(previous) }
    view = nil
    if let appliedConfig { velokit_config_free(appliedConfig) }
    appliedConfig = nil
    runtime.remove(self)
  }

  deinit { close() }
}
