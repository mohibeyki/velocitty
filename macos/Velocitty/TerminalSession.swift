// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit
import VelocittyConfiguration

// A terminal owns its native surface and backing view, independently of presentation.
// Retaining the runtime guarantees the engine outlives every surface using it.
final class TerminalSession {
  let runtime: TerminalRuntime
  let hasCustomCommand: Bool
  weak var windowController: TerminalWindowController?
  private(set) var surface: ghostty_surface_t?
  private(set) var view: TerminalView?
  private var appliedConfig: ghostty_config_t?
  private(set) var opacityOverride: Double?
  private var closed = false
  var herdrTerminal: HerdrClient.Terminal?
  var initialDirectory: URL?
  var initialInput: String?
  var initialFontSize: Float = 0
  var surfaceContext = GHOSTTY_SURFACE_CONTEXT_WINDOW
  var chrome: TerminalChrome?
  var terminalTitle = "Velocitty"
  var tabTitle: String?
  var currentDirectory: String?
  var passwordInput = false
  var manualSecureInput = false
  var hasBell = false
  var readonly = false
  var sizeLimit: ghostty_action_size_limit_s?
  var backgroundColor: NSColor?
  var displayTitle: String { tabTitle ?? terminalTitle }

  var links = TerminalLinks()

  var settings: AppConfiguration { runtime.settings }
  var config: ghostty_config_t? { closed ? nil : appliedConfig ?? runtime.config }

  init(runtime: TerminalRuntime) {
    self.runtime = runtime
    hasCustomCommand = runtime.settings.options.contains {
      ($0.key == "command" || $0.key == "initial-command") && !$0.value.isEmpty
    }
  }

  func createView() -> TerminalView? {
    guard !closed, let app = runtime.app else { return nil }
    if let view, surface != nil { return view }
    let terminalView = view ?? TerminalView(session: self)
    view = terminalView
    var options = velokit_surface_config_new()
    let pointer = Unmanaged.passUnretained(terminalView).toOpaque()
    options.userdata = pointer
    options.platform_tag = GHOSTTY_PLATFORM_MACOS
    options.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: pointer))
    options.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
    options.context = surfaceContext
    options.font_size = initialFontSize
    let input = initialInput.flatMap { strdup($0) }
    defer { free(input) }
    options.initial_input = input.map { UnsafePointer($0) }
    surface = (initialDirectory ?? settings.workingDirectory).path.withCString {
      options.working_directory = $0
      if let command = herdrTerminal?.command {
        return command.withCString {
          options.command = $0
          options.wait_after_command = true
          return velokit_surface_new(app, &options)
        }
      }
      return velokit_surface_new(app, &options)
    }
    guard surface != nil else {
      view = nil
      return nil
    }
    terminalView.updateFocus()
    return terminalView
  }

  private var recoveryTimer: Timer?
  private var recoveryGeneration = UUID()
  private var recoveryAttempts = 0
  private(set) var recovering = false

  func attachmentExited() {
    guard !closed, herdrTerminal != nil, windowController?.closing == false,
      windowController?.owner?.terminating != true, !recovering else { return }
    recovering = true
    recoveryGeneration = UUID()
    checkAttachment(generation: recoveryGeneration)
  }

  func retryAttachment() {
    guard !closed, herdrTerminal != nil else { return }
    recoveryTimer?.invalidate()
    recoveryAttempts = 0
    recovering = true
    recoveryGeneration = UUID()
    checkAttachment(generation: recoveryGeneration)
  }

  private func checkAttachment(generation: UUID) {
    guard !closed, let terminal = herdrTerminal else { return }
    chrome?.showConnectionStatus("Reconnecting…", retry: false)
    terminal.client.perform({ try $0.snapshot(timeout: 2) }) { [weak self] result in
      guard let self, !self.closed, self.recoveryGeneration == generation,
        self.windowController?.closing == false, self.windowController?.owner?.terminating != true else { return }
      switch result {
      case .success(let snapshot):
        guard let record = snapshot.panes.first(where: { $0.terminal_id == terminal.pane.terminal_id }) else {
          self.recovering = false
          self.windowController?.requestTabClose(self)
          return
        }
        self.herdrTerminal = .init(client: terminal.client, pane: record)
        self.scheduleAttachmentRetry(generation: generation, canAttach: true)
      case .failure:
        self.scheduleAttachmentRetry(generation: generation, canAttach: false)
      }
    }
  }

  private func scheduleAttachmentRetry(generation: UUID, canAttach: Bool) {
    guard recoveryAttempts < 8 else {
      chrome?.showConnectionStatus("Disconnected", retry: true)
      return
    }
    let delay = min(10, pow(2, Double(recoveryAttempts)))
    recoveryAttempts += 1
    chrome?.showConnectionStatus("Disconnected · retrying in \(Int(delay))s", retry: true)
    recoveryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      guard let self, !self.closed, self.recoveryGeneration == generation else { return }
      if canAttach {
        self.view?.inputContext?.discardMarkedText()
        self.view?.clipboard.cancel()
        self.links.cancel()
        let savedConfig = self.config.flatMap { velokit_config_clone($0) }
        defer { if let savedConfig { velokit_config_free(savedConfig) } }
        let old = self.surface
        self.surface = nil
        if let old { velokit_surface_free(old) }
        if self.createView() != nil {
          if let savedConfig { _ = self.applyPreparedConfiguration(savedConfig) }
          self.view?.updateSurfaceSize()
          self.recovering = false
          self.chrome?.showConnectionStatus(nil, retry: false)
          self.chrome?.needsLayout = true
          self.windowController?.workspaceView.needsLayout = true
          self.view?.updateFocus()
          // A process launch isn't an attachment acknowledgement. Keep the retry
          // budget until the replacement has remained alive for a while.
          self.recoveryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, !self.recovering else { return }
            self.recoveryAttempts = 0
          }
          return
        }
      }
      self.checkAttachment(generation: generation)
    }
  }

  private var opacityBase: ghostty_config_t?
  func toggleOpacity() throws {
    guard !closed, let base = opacityBase ?? config else { return }
    if opacityOverride == nil && opacityBase == nil {
      guard let copy = velokit_config_clone(base) else { throw ConfigurationError("Could not copy terminal configuration.") }
      opacityBase = copy
    }
    let value: Double? = opacityOverride == nil ? 1 : nil
    let candidate = try Self.prepareConfig(from: base, opacity: value)
    defer { velokit_config_free(candidate) }
    guard applyPreparedConfiguration(candidate) else {
      throw ConfigurationError("VeloKit could not apply the terminal configuration.")
    }
    opacityOverride = value
    if value == nil, let original = opacityBase { velokit_config_free(original); opacityBase = nil }
  }

  func prepareOverride(from base: ghostty_config_t) throws -> ghostty_config_t? {
    guard !closed, surface != nil, let opacityOverride else { return nil }
    if let original = opacityBase { velokit_config_free(original) }
    opacityBase = velokit_config_clone(base)
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
    recoveryTimer?.invalidate()
    recoveryGeneration = UUID()
    chrome?.progress.clear()
    chrome?.fadeTimer?.invalidate()
    view?.inputContext?.discardMarkedText()
    view?.unmarkText()
    view?.stopAccessibility()
    view?.clipboard.cancel()
    links.cancel()
    let previous = surface
    surface = nil
    closed = true
    windowController = nil
    if let previous { velokit_surface_free(previous) }
    chrome = nil
    view = nil
    if let appliedConfig { velokit_config_free(appliedConfig) }
    appliedConfig = nil
    if let opacityBase { velokit_config_free(opacityBase) }
    opacityBase = nil
    runtime.remove(self)
  }

  deinit { close() }
}
