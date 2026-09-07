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
  private var overrideConfig: ghostty_config_t?
  private(set) var opacityOverride: Double?
  private var closed = false
  var links = TerminalLinks()

  var settings: AppConfiguration { runtime.settings }
  var config: ghostty_config_t? { closed ? nil : overrideConfig ?? runtime.config }

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
    let value: Double? = opacityOverride == nil ? 1 : nil
    try applyConfiguration(opacity: value)
    opacityOverride = value
  }

  func refreshConfiguration() throws {
    if opacityOverride != nil { try applyConfiguration(opacity: opacityOverride) }
    if let surface {
      velokit_surface_set_color_scheme(
        surface, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
    }
  }

  private func applyConfiguration(opacity: Double?) throws {
    guard !closed, let surface else { return }
    let candidate = try opacity.map { try TerminalRuntime.makeConfig(settings, opacityOverride: $0) }
    guard let configuration = candidate ?? runtime.config,
      velokit_surface_update_config(surface, configuration)
    else {
      if let candidate { velokit_config_free(candidate) }
      throw ConfigurationError("VeloKit could not apply the terminal configuration.")
    }
    if let overrideConfig { velokit_config_free(overrideConfig) }
    overrideConfig = candidate
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
    if let overrideConfig { velokit_config_free(overrideConfig) }
    overrideConfig = nil
    runtime.remove(self)
  }

  deinit { close() }
}
