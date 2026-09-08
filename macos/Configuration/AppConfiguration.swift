// SPDX-License-Identifier: GPL-3.0

import Foundation
import TOMLDecoder

public struct TerminalOption: Equatable, Sendable {
  public let key: String
  public let value: String
  public var source: URL? = nil
}

public struct AppConfiguration: Equatable, Sendable {
  public var interface: [String: String] = [:]
  public let workingDirectory: URL
  public let options: [TerminalOption]
  public var diagnostics: [String] = []
  // Relative asset paths are resolved against the TOML file, not the shell.
  public let source: URL
  public let home: URL

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
    return Self(
      workingDirectory: isDirectory(workspace) ? workspace : home, options: [], source: source, home: home)
  }

  public static func load(
    from url: URL = fileURL(),
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Self {
    // Match the native loader: apply this file, then includes in queue order.
    // Nested includes join the end of the queue; a file is loaded only once.
    var pending: [(URL, Bool, Int)] = []
    var loaded: Set<URL> = []
    var interface: [String: String] = [:]
    var options: [TerminalOption] = []
    var diagnostics: [String] = []
    var index = -1
    while index < pending.count {
      let (file, optional, depth) = index < 0 ? (url, true, 0) : pending[index]
      defer { index += 1 }
      let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
      guard loaded.insert(canonical).inserted, depth < 64 else {
        diagnostics.append("\(file.path): Configuration include cycle or excessive depth.")
        continue
      }
      do {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile && optional { loaded.remove(canonical); continue }
        let own = try parse(data, home: home, source: file)
        interface.merge(own.interface) { _, new in new }
        diagnostics += own.diagnostics
        for option in own.options {
          if option.key == "config-file" {
            guard !option.value.isEmpty else {
              // The native loader mutates the include list without rewinding its cursor.
              pending.removeAll()
              continue
            }
            let optional = option.value.hasPrefix("?")
            let path = optional ? String(option.value.dropFirst()) : option.value
            guard !path.isEmpty else { continue }
            pending.append((assetURL(path, relativeTo: file, home: home), optional, depth + 1))
          } else {
            // Preserve repeated entries and resets for each setting's native parser.
            options.append(option)
          }
        }
      } catch {
        let detail = error.localizedDescription
        diagnostics.append(detail.hasPrefix(file.path) ? detail : "\(file.path): \(detail)")
      }
    }
    let directory = options.last { $0.key == "working-directory" }
      .map { URL(fileURLWithPath: $0.value, isDirectory: true) }
      ?? defaults(home: home).workingDirectory
    return Self(interface: interface, workingDirectory: directory, options: options, diagnostics: diagnostics,
      source: url, home: home)
  }

  static func assetURL(_ path: String, relativeTo source: URL, home: URL) -> URL {
    if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    return source.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
  }

  public static func parse(
    _ data: Data,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    source: URL = fileURL()
  ) throws -> Self {
    do {
      let document = try TOMLDecoder().decode(Document.self, from: data)
      var options: [TerminalOption] = []
      var diagnostics = document.diagnostics.map { "\(source.path): \($0)" }
      let aliases = Dictionary(grouping: (document.terminal ?? [:]).keys) {
        $0.replacingOccurrences(of: "_", with: "-")
      }
      var interface: [String: String] = [:]
      let interfaceAliases = Dictionary(grouping: (document.interface ?? [:]).keys) { $0.replacingOccurrences(of: "-", with: "_") }
      for (spelling, value) in document.interface ?? [:] {
        let key = spelling.replacingOccurrences(of: "-", with: "_")
        guard interfaceAliases[key]?.count == 1 else {
          diagnostics.append("\(source.path): Duplicate setting aliases: interface.\(spelling)")
          continue
        }
        if case .scalar(let text) = value, NamespaceAppearance.validate(text, for: key) {
          interface[key] = text
        } else {
          diagnostics.append("\(source.path): Invalid or unknown interface.\(key); using the default.")
        }
      }
      var directory = defaults(home: home, source: source).workingDirectory
      for (spelling, value) in (document.terminal ?? [:]).sorted(by: { $0.key < $1.key }) {
        let key = spelling.replacingOccurrences(of: "_", with: "-")
        do {
          guard aliases[key]?.count == 1 else {
            throw ConfigurationError("Duplicate setting aliases: terminal.\(spelling)")
          }
          if TerminalSettings.otherPlatformKeys.contains(key) { continue }
          if let reason = TerminalSettings.unavailable[key] {
            throw ConfigurationError("terminal.\(spelling) is not available yet. \(reason)")
          }
          guard TerminalSettings.supported.contains(key) else {
            throw ConfigurationError("Unknown configuration key: terminal.\(spelling)")
          }
          let values: [String]
          switch value {
          case .invalid(let reason):
            throw ConfigurationError("terminal.\(spelling): \(reason)")
          case .scalar(let scalar): values = [scalar]
          case .array(let array):
            guard TerminalSettings.repeatable.contains(key) else {
              throw ConfigurationError("terminal.\(spelling) does not accept an array.")
            }
            // Empty repeatable arrays explicitly reset to the engine default.
            values =
              array.isEmpty
              ? [""]
              : array.compactMap { element in
                if let text = element.text { return text }
                diagnostics.append(
                  "\(source.path): terminal.\(spelling): Invalid array element; expected a string, boolean, or finite number."
                )
                return nil
              }
          }
          for text in values {
            do {
              guard !text.contains("\0") else {
                throw ConfigurationError("terminal.\(spelling) cannot contain a NUL character.")
              }
              if key == "shell-integration-features" {
                let flags = text.split(separator: ",").map {
                  $0.trimmingCharacters(in: .whitespaces)
                }
                for feature in ["ssh-env", "ssh-terminfo"] {
                  if flags.last(where: { $0 == feature || $0 == "no-" + feature }) == feature {
                    throw ConfigurationError(
                      "terminal.shell_integration_features: \(feature) requires an upstream command-line helper that Velocitty does not bundle."
                    )
                  }
                }
              }
              if key == "working-directory" {
                directory = try resolveDirectory(text, home: home)
                options.append(TerminalOption(key: key, value: directory.path, source: source))
              } else {
                var resolved = text
                if ["background-image", "custom-shader", "bell-audio-path"].contains(key),
                  !text.isEmpty
                {
                  let optional = text.hasPrefix("?")
                  resolved =
                    (optional ? "?" : "")
                    + Self.assetURL(
                      optional ? String(text.dropFirst()) : text, relativeTo: source, home: home
                    ).path
                }
                if key == "input", text.hasPrefix("path:") {
                  resolved =
                    "path:"
                    + Self.assetURL(String(text.dropFirst(5)), relativeTo: source, home: home).path
                }
                options.append(TerminalOption(key: key, value: resolved, source: source))
              }
            } catch { diagnostics.append("\(source.path): \(error.localizedDescription)") }
          }
        } catch { diagnostics.append("\(source.path): \(error.localizedDescription)") }
      }
      return Self(
        interface: interface, workingDirectory: directory.standardizedFileURL, options: options,
        diagnostics: diagnostics, source: source, home: home)
    } catch let error as DecodingError {
      let detail: String
      switch error {
      case .typeMismatch(_, let context), .valueNotFound(_, let context),
        .dataCorrupted(let context):
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
    case "inherit":
      directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    case "": return defaults(home: home).workingDirectory
    default:
      if path.hasPrefix("~/") {
        directory = home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
      } else if path.hasPrefix("/") {
        directory = URL(fileURLWithPath: path, isDirectory: true)
      } else {
        throw ConfigurationError(
          "terminal.working_directory requires an absolute path, ~/…, home, or inherit.")
      }
    }
    guard isDirectory(directory), FileManager.default.isExecutableFile(atPath: directory.path)
    else {
      throw ConfigurationError(
        "terminal.working_directory is not an accessible directory: \(directory.path)")
    }
    return directory.standardizedFileURL
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      && directory.boolValue
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
  let interface: [String: Value]?
  let diagnostics: [String]
  enum CodingKeys: String, CodingKey { case terminal, interface }
  init(from decoder: Decoder) throws {
    let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
    diagnostics = keys.sorted().filter { $0 != "terminal" && $0 != "interface" }.map {
      "Unknown configuration key: \($0)"
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Validate the table explicitly: TOMLDecoder can otherwise decode a scalar
    // dictionary using the enclosing table's keys.
    if container.contains(.terminal) { _ = try container.decode(TOMLTable.self, forKey: .terminal) }
    if container.contains(.interface) { _ = try container.decode(TOMLTable.self, forKey: .interface) }
    interface = try container.decodeIfPresent([String: Value].self, forKey: .interface)
    terminal = try container.decodeIfPresent([String: Value].self, forKey: .terminal)
  }
}

// Decode actual TOML values. Native VeloKit parsers handle enums, packed flags,
// durations, percentages, colors, and other compound setting syntax.
private enum Value: Decodable {
  case scalar(String)
  case array([Element])
  case invalid(String)
  init(from decoder: Decoder) throws {
    do {
      if var array = try? decoder.unkeyedContainer() {
        var values: [Element] = []
        while !array.isAtEnd { values.append(try array.decode(Element.self)) }
        self = .array(values)
      } else {
        self = .scalar(try Scalar(from: decoder).text)
      }
    } catch {
      self = .invalid("Expected a string, boolean, finite number, or an array of these values.")
    }
  }
}

// Array elements use a scalar-only decoder. In TOMLDecoder a scalar element
// shares its parent's unkeyed container; recursively probing it as an array
// would start decoding the parent again.
private struct Element: Decodable {
  let text: String?
  init(from decoder: Decoder) throws { text = try? Scalar(from: decoder).text }
}

private struct Scalar: Decodable {
  let text: String
  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let string = try? value.decode(String.self) {
      text = string
    } else if let bool = try? value.decode(Bool.self) {
      text = bool ? "true" : "false"
    } else if let integer = try? value.decode(Int64.self) {
      text = String(integer)
    } else if let number = try? value.decode(Double.self), number.isFinite {
      text = String(number)
    } else {
      throw DecodingError.dataCorruptedError(
        in: value, debugDescription: "Expected a string, boolean, or finite number.")
    }
  }
}
