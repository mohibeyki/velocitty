// SPDX-License-Identifier: GPL-3.0
import AppKit
import Foundation
import VeloKit
import VelocittyConfiguration

final class TerminalRuntime {
    let context = RuntimeContext()
    private(set) var config: ghostty_config_t?
    private(set) var app: ghostty_app_t?
    private(set) var view: TerminalView?

    var opacityOverride: Double?
    var settings: AppConfiguration

    static func makeConfig(_ settings: AppConfiguration, opacityOverride: Double? = nil) throws -> ghostty_config_t {
        guard let config = velokit_config_new() else {
            throw ConfigurationError("Could not allocate the terminal configuration.")
        }
        func failure(_ context: String) -> ConfigurationError {
            let detail = velokit_config_error(config).map { String(cString: $0) } ?? context
            return ConfigurationError("\(settings.source.path): \(detail)")
        }
        do {
            for option in try TerminalTheme.options(for: settings, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) {
                let accepted = option.key.withCString { key in
                    option.value.withCString { velokit_config_set(config, key, $0) }
                }
                guard accepted else { throw failure("Invalid terminal setting: \(option.key)") }
            }
            if let opacityOverride {
                _ = String(opacityOverride).withCString { velokit_config_set(config, "background-opacity", $0) }
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
        velokit_app_set_focus(app, true)
        velokit_app_set_color_scheme(app, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
    }

    func updateConfiguration(_ settings: AppConfiguration) throws {
        guard let app else { return }
        let updated = try Self.makeConfig(settings, opacityOverride: opacityOverride)
        guard velokit_app_update_config(app, updated) else {
            velokit_config_free(updated)
            throw ConfigurationError("VeloKit could not apply the configuration.")
        }
        if let config { velokit_config_free(config) }
        config = updated
        view?.config = updated
        let scheme: Int32 = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
        velokit_app_set_color_scheme(app, scheme)
        if let surface = view?.surface { velokit_surface_set_color_scheme(surface, scheme) }
        self.settings = settings
    }

    func createView() -> TerminalView? {
        guard let app else { return nil }
        let terminalView = TerminalView(app: app, workingDirectory: settings.workingDirectory)
        terminalView?.config = config
        view = terminalView
        return terminalView
    }

    func closeView() {
        if let surface = view?.surface {
            view?.surface = nil
            velokit_surface_free(surface)
        }
        view = nil
    }

    deinit {
        if let view, let surface = view.surface {
            view.surface = nil
            velokit_surface_free(surface)
        }
        if let app {
            velokit_app_free(app)
        }
        if let config {
            velokit_config_free(config)
        }
    }
}


// Read finalized engine values, including defaults, rather than re-parsing TOML.
struct NativeSettings {
    let config: ghostty_config_t?
    func value<T>(_ key: String, _ fallback: T) -> T {
        guard let config else { return fallback }
        var result = fallback
        let found = key.withCString { keyPointer in
            withUnsafeMutablePointer(to: &result) { velokit_config_get(config, $0, keyPointer, UInt(key.utf8.count)) }
        }
        return found ? result : fallback
    }
    func string(_ key: String, _ fallback: String = "") -> String {
        let pointer: UnsafePointer<CChar>? = value(key, Optional<UnsafePointer<CChar>>.none)
        return pointer.map { String(cString: $0) } ?? fallback
    }
    func seconds(_ key: String, _ fallback: Double) -> Double {
        Double(value(key, UInt(fallback * 1000))) / 1000
    }
    func color(_ key: String, _ fallback: NSColor = .windowBackgroundColor) -> NSColor {
        let value = value(key, ghostty_config_color_s(r: 0, g: 0, b: 0))
        return NSColor(srgbRed: Double(value.r) / 255, green: Double(value.g) / 255, blue: Double(value.b) / 255, alpha: 1)
    }
}
