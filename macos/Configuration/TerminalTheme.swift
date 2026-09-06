// SPDX-License-Identifier: GPL-3.0
import Foundation

public enum TerminalTheme {
    public static let names = ["TokyoNight Night", "TokyoNight Storm", "TokyoNight Moon", "TokyoNight Day",
        "Rose Pine", "Rose Pine Moon", "Rose Pine Dawn", "Catppuccin Latte", "Catppuccin Frappe",
        "Catppuccin Macchiato", "Catppuccin Mocha"]

    public static func options(for config: AppConfiguration, dark: Bool) throws -> [TerminalOption] {
        let selection = config.options.last { $0.key == "theme" }
        let requested = selection?.value ?? "light:Rose Pine Dawn,dark:Rose Pine"
        let explicit = config.options.filter { $0.key != "theme" }
        if requested.isEmpty { return explicit }
        var name = requested
        if requested.hasPrefix("light:") || requested.hasPrefix("dark:") {
            var choices: [String: String] = [:]
            for part in requested.split(separator: ",") {
                let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, ["light", "dark"].contains(pair[0]), !pair[1].isEmpty, choices[pair[0]] == nil else {
                    throw ConfigurationError("theme requires light:<name>,dark:<name>.")
                }
                choices[pair[0]] = pair[1]
            }
            guard choices.count == 2 else { throw ConfigurationError("theme requires both light and dark variants.") }
            name = choices[dark ? "dark" : "light"]!
        }
        let source = selection?.source ?? config.source
        let custom: URL
        if name.hasPrefix("/") || name.hasPrefix("~/") {
            custom = AppConfiguration.assetURL(name, relativeTo: source, home: FileManager.default.homeDirectoryForCurrentUser)
        } else {
            guard !name.contains("/") else { throw ConfigurationError("A theme name cannot contain a path separator.") }
            custom = source.deletingLastPathComponent().appendingPathComponent("themes").appendingPathComponent(name.hasSuffix(".itermcolors") ? name : name + ".itermcolors")
        }
        let url: URL
        if FileManager.default.fileExists(atPath: custom.path) { url = custom }
        else if let bundled = Bundle.module.url(forResource: name, withExtension: "itermcolors") { url = bundled }
        else { throw ConfigurationError("\(source.path): theme not found: \(name)") }
        let colors = try decode(Data(contentsOf: url), source: url)
        let overrides = Set(explicit.map(\.key))
        // Palette overrides apply per index in the engine, so keep base entries.
        return colors.filter { $0.key == "palette" || !overrides.contains($0.key) } + explicit
    }

    public static func decode(_ data: Data, source: URL) throws -> [TerminalOption] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ConfigurationError("\(source.path): expected an iTerm2 color-scheme dictionary.")
        }
        var mapping = ["Background Color": "background", "Foreground Color": "foreground", "Cursor Color": "cursor-color",
            "Cursor Text Color": "cursor-text", "Selection Color": "selection-background", "Selected Text Color": "selection-foreground", "Bold Color": "bold-color"]
        for index in 0..<256 { mapping["Ansi \(index) Color"] = "palette" }
        var result: [TerminalOption] = []
        for (label, key) in mapping.sorted(by: { $0.key < $1.key }) {
            guard let entry = plist[label] else { continue }
            guard let components = entry as? [String: Any] else { throw ConfigurationError("\(source.path): invalid color: \(label)") }
            let channels = ["Red Component", "Green Component", "Blue Component"].compactMap { components[$0] as? Double }
            guard channels.count == 3, channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ConfigurationError("\(source.path): invalid RGB components for \(label)")
            }
            let hex = String(format: "#%02x%02x%02x", Int((channels[0] * 255).rounded()), Int((channels[1] * 255).rounded()), Int((channels[2] * 255).rounded()))
            let value = key == "palette" ? "\(label.split(separator: " ")[1])=\(hex)" : hex
            result.append(TerminalOption(key: key, value: value, source: source))
        }
        guard result.contains(where: { $0.key == "background" }), result.contains(where: { $0.key == "foreground" }) else {
            throw ConfigurationError("\(source.path): a theme must define background and foreground colors.")
        }
        return result
    }
}
