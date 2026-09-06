// SPDX-License-Identifier: GPL-3.0

import Foundation
import TOMLDecoder

public struct TerminalOption: Equatable, Sendable {
    public let key: String
    public let value: String
}

public struct AppConfiguration: Equatable, Sendable {
    public let workingDirectory: URL
    public let options: [TerminalOption]
    // Relative asset paths are resolved against the TOML file, not the shell.
    public let source: URL

    public static func fileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("velocitty/config.toml")
    }

    public static func defaults(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        source: URL = fileURL()
    ) -> Self {
        let workspace = home.appendingPathComponent("workspace", isDirectory: true)
        return Self(workingDirectory: isDirectory(workspace) ? workspace : home, options: [], source: source)
    }

    public static func load(
        from url: URL = fileURL(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return defaults(home: home, source: url)
        } catch {
            throw ConfigurationError("\(url.path): \(error.localizedDescription)")
        }
        return try parse(data, home: home, source: url)
    }

    public static func parse(
        _ data: Data,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        source: URL = fileURL()
    ) throws -> Self {
        do {
            let document = try TOMLDecoder().decode(Document.self, from: data)
            var options: [TerminalOption] = []
            var seen: Set<String> = []
            var directory = defaults(home: home, source: source).workingDirectory
            for (spelling, value) in (document.terminal ?? [:]).sorted(by: { $0.key < $1.key }) {
                let key = spelling.replacingOccurrences(of: "_", with: "-")
                guard seen.insert(key).inserted else {
                    throw ConfigurationError("Duplicate setting aliases: terminal.\(spelling)")
                }
                if let reason = TerminalSettings.unavailable[key] {
                    throw ConfigurationError("terminal.\(spelling) is not available yet. \(reason)")
                }
                guard TerminalSettings.supported.contains(key) else {
                    throw ConfigurationError("Unknown configuration key: terminal.\(spelling)")
                }
                let values: [String]
                switch value {
                case .scalar(let scalar): values = [scalar]
                case .array(let array):
                    guard TerminalSettings.repeatable.contains(key) else {
                        throw ConfigurationError("terminal.\(spelling) does not accept an array.")
                    }
                    // Empty repeatable arrays explicitly reset to the engine default.
                    values = array.isEmpty ? [""] : array
                }
                for text in values {
                    guard !text.contains("\0") else {
                        throw ConfigurationError("terminal.\(spelling) cannot contain a NUL character.")
                    }
                    if key == "clipboard-write", text == "ask" {
                        throw ConfigurationError("terminal.\(spelling) = ask needs clipboard confirmation UI. Use allow or deny.")
                    }
                    if key == "working-directory" {
                        directory = try resolveDirectory(text, home: home)
                        options.append(TerminalOption(key: key, value: directory.path))
                    } else {
                        options.append(TerminalOption(key: key, value: text))
                    }
                }
            }
            return Self(workingDirectory: directory.standardizedFileURL, options: options, source: source)
        } catch let error as DecodingError {
            let detail: String
            switch error {
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                detail = "\(path.isEmpty ? "config" : path): \(context.debugDescription)"
            default: detail = String(describing: error)
            }
            throw ConfigurationError("\(source.path): \(detail)")
        } catch {
            let detail = (error as? ConfigurationError)?.message ?? String(describing: error)
            throw ConfigurationError("\(source.path): \(detail)")
        }
    }

    private static func resolveDirectory(_ path: String, home: URL) throws -> URL {
        let directory: URL
        switch path {
        case "~", "home": directory = home
        case "inherit": directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        case "": return defaults(home: home).workingDirectory
        default:
            if path.hasPrefix("~/") {
                directory = home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
            } else if path.hasPrefix("/") {
                directory = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                throw ConfigurationError("terminal.working_directory requires an absolute path, ~/…, home, or inherit.")
            }
        }
        guard isDirectory(directory), FileManager.default.isExecutableFile(atPath: directory.path) else {
            throw ConfigurationError("terminal.working_directory is not an accessible directory: \(directory.path)")
        }
        return directory.standardizedFileURL
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

public struct ConfigurationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct Document: Decodable {
    let terminal: [String: Value]?
    enum CodingKeys: String, CodingKey { case terminal }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        if let unknown = keys.sorted().first(where: { $0 != "terminal" }) {
            throw ConfigurationError("Unknown configuration key: \(unknown)")
        }
        terminal = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String: Value].self, forKey: .terminal)
    }
}

// Decode actual TOML values. Native VeloKit parsers handle enums, packed flags,
// durations, percentages, colors, and other compound setting syntax.
private enum Value: Decodable {
    case scalar(String)
    case array([String])
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [String] = []
            while !array.isAtEnd { values.append(try array.decode(Scalar.self).text) }
            self = .array(values)
        } else {
            self = .scalar(try Scalar(from: decoder).text)
        }
    }
}

private struct Scalar: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { text = string }
        else if let bool = try? value.decode(Bool.self) { text = bool ? "true" : "false" }
        else if let integer = try? value.decode(Int64.self) { text = String(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { text = String(number) }
        else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a string, boolean, or finite number.")
        }
    }
}
