// SPDX-License-Identifier: GPL-3.0
import Foundation

/// Lossless edits to known TOML assignments. The semantic parser is deliberately
/// not used to serialize the document: comments and unrelated keys stay intact.
public final class ConfigurationDocument {
  public let url: URL
  public var text: String
  private var original: Data?
  private var baselineText: String
  public init(url: URL) throws {
    self.url = url.resolvingSymlinksInPath()
    do { original = try Data(contentsOf: self.url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { original = nil }
    guard original == nil || String(data: original!, encoding: .utf8) != nil else { throw ConfigurationError("The configuration is not UTF-8 text.") }
    text = original.flatMap { String(data: $0, encoding: .utf8) } ?? "# Velocitty configuration\n[terminal]\n"
    baselineText = text
  }
  public var hasChanges: Bool { text != baselineText }

  private struct Assignment { let table: String; let key: String; let value: Range<Int> }
  private func assignments() -> ([Assignment], [String: Int]) {
    let bytes = Array(text.utf8)
    var table = "", position = 0
    var entries: [Assignment] = []
    var ends: [String: Int] = [:]
    while position < bytes.count {
      let lineStart = position
      let lineEnd = bytes[position...].firstIndex(of: 10) ?? bytes.count
      let line = String(decoding: bytes[position..<lineEnd], as: UTF8.self)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("[") {
        ends[table] = lineStart
        if let end = trimmed.firstIndex(of: "]"), !trimmed.hasPrefix("[[") {
          table = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
        } else { table = "<unsupported>" }
      } else if !trimmed.hasPrefix("#"), let equals = bytes[position..<lineEnd].firstIndex(of: 61) {
        var key = String(decoding: bytes[position..<equals], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) { key = String(key.dropFirst().dropLast()) }
        if !key.isEmpty && key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) {
          var start = equals + 1
          while start < bytes.count && [9, 32].contains(bytes[start]) { start += 1 }
          if let end = Self.valueEnd(bytes, from: start) {
            entries.append(.init(table: table, key: key.replacingOccurrences(of: "-", with: "_"), value: start..<end))
            position = end
            while position < bytes.count && bytes[position] != 10 { position += 1 }
            position = min(bytes.count, position + 1)
            continue
          }
        }
      }
      position = min(bytes.count, lineEnd + 1)
    }
    ends[table] = bytes.count
    return (entries, ends)
  }

  private static func valueEnd(_ bytes: [UInt8], from start: Int) -> Int? {
    var index = start, depth = 0, quote: UInt8? = nil, triple = false
    while index < bytes.count {
      let byte = bytes[index]
      if let mark = quote {
        if mark == 34 && byte == 92 { index += 2; continue }
        if byte == mark {
          if !triple { quote = nil }
          else if index + 2 < bytes.count && bytes[index + 1] == mark && bytes[index + 2] == mark { quote = nil; index += 2 }
        }
      } else if byte == 34 || byte == 39 {
        quote = byte
        triple = index + 2 < bytes.count && bytes[index + 1] == byte && bytes[index + 2] == byte
        if triple { index += 2 }
      } else if byte == 91 || byte == 123 { depth += 1 }
      else if byte == 93 || byte == 125 { depth -= 1; if depth < 0 { return nil } }
      else if byte == 35 {
        if depth == 0 { break }
        while index < bytes.count && bytes[index] != 10 { index += 1 }
        continue
      } else if byte == 10 && depth == 0 { break }
      index += 1
    }
    guard quote == nil, depth == 0 else { return nil }
    while index > start && [9, 13, 32].contains(bytes[index - 1]) { index -= 1 }
    return index > start ? index : nil
  }

  public func value(table: String, key: String) -> String? {
    let matches = assignments().0.filter { $0.table == table && $0.key == key.replacingOccurrences(of: "-", with: "_") }
    guard matches.count == 1 else { return nil }
    return String(decoding: Array(text.utf8)[matches[0].value], as: UTF8.self)
  }

  public func setValue(table: String, key: String, toml: String) throws {
    let key = key.replacingOccurrences(of: "-", with: "_")
    let toml = toml.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.valueEnd(Array(toml.utf8), from: 0) == toml.utf8.count else { throw ConfigurationError("Enter one TOML value; use Advanced to edit multiple settings.") }
    guard ["terminal", "interface"].contains(table), !key.isEmpty,
      key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else { throw ConfigurationError("Use the advanced editor for this setting.") }
    let parsed = try AppConfiguration.parse(Data("[\(table)]\n\(key) = \(toml)\n".utf8), source: url)
    guard parsed.diagnostics.isEmpty else { throw ConfigurationError(parsed.diagnostics.joined(separator: "\n")) }
    let (entries, ends) = assignments()
    let matches = entries.filter { $0.table == table && $0.key == key }
    guard matches.count <= 1 else { throw ConfigurationError("Duplicate assignments; resolve them in the advanced editor.") }
    var bytes = Array(text.utf8)
    if let assignment = matches.first {
      bytes.replaceSubrange(assignment.value, with: toml.utf8)
    } else if let end = ends[table] {
      let prefix = end > 0 && bytes[end - 1] != 10 ? "\n" : ""
      bytes.insert(contentsOf: (prefix + "\(key) = \(toml)\n").utf8, at: end)
    } else {
      bytes.append(contentsOf: "\n[\(table)]\n\(key) = \(toml)\n".utf8)
    }
    text = String(decoding: bytes, as: UTF8.self)
  }

  public func save() throws {
    // Syntax validation is mandatory, but unrelated setting diagnostics don't
    // prevent fixing another value. The runtime reports them after reload.
    _ = try AppConfiguration.parse(Data(text.utf8), source: url)
    let disk: Data?
    do { disk = try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { disk = nil }
    guard disk == original else { throw ConfigurationError("This file changed outside Settings. Your draft is retained; copy it before reloading the file.") }
    let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(text.utf8)
    if original == nil { try data.write(to: url, options: .withoutOverwriting) }
    else { try data.write(to: url, options: .atomic) }
    if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    original = data
    baselineText = text
  }
}
