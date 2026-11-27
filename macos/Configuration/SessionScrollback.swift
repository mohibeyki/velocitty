// SPDX-License-Identifier: GPL-3.0
import Darwin
import Foundation

/// Pure text handling for saved terminal output: what is kept and how a restored pane shows it.
public enum SessionScrollback {
  public static let maxLines = 2000
  public static let maxBytes = 512 * 1024

  /// The text worth keeping: plain, without terminal control sequences, blank edges or
  /// anything beyond the most recent `maxLines` lines and `maxBytes`.
  public static func bounded(_ text: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> String {
    // Escape sequences in saved text must never be replayed to a terminal.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let plain = String(String.UnicodeScalarView(normalized.unicodeScalars.filter(isPlain)))
    var lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
    while lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
    lines = Array(lines.suffix(maxLines))
    var size = lines.reduce(0) { $0 + $1.utf8.count + 1 }
    while size > maxBytes, !lines.isEmpty { size -= lines.removeFirst().utf8.count + 1 }
    return lines.joined(separator: "\n")
  }

  private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f && !(0x80...0x9f).contains(scalar.value))
  }

  /// Dimmed saved text followed by a separator, as terminal output with "\n" line endings.
  public static func display(_ text: String, savedAt: Date? = nil) -> String {
    let dim = "\u{1B}[2m", reset = "\u{1B}[0m"
    let when = savedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
    return dim + text + reset + "\n" + dim + "─── restored session" + when + " ───" + reset + "\n"
  }

  /// Output for a terminal emulator, which needs a carriage return to start each line.
  public static func terminalOutput(_ text: String, savedAt: Date? = nil) -> String {
    display(text, savedAt: savedAt).replacingOccurrences(of: "\n", with: "\r\n")
  }
}

/// Saved scrollback files, one per terminal, next to the workspace file. They hold terminal
/// output, so they are private to the user and removed with the terminal they belong to.
public struct ScrollbackStore: Sendable {
  public let directory: URL
  public init(besideStateAt stateURL: URL) {
    directory = stateURL.deletingLastPathComponent().appendingPathComponent("scrollback", isDirectory: true)
  }

  public func url(for key: String) -> URL { directory.appendingPathComponent(Self.fileName(key) + ".txt") }

  /// Keys are terminal IDs such as "ssh:host::term_1"; encode everything outside a safe alphabet.
  static func fileName(_ key: String) -> String {
    key.utf8.map { byte in
      let safe = (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
      return safe ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
  }

  public func load(_ key: String) -> (text: String, savedAt: Date?)? {
    let url = url(for: key)
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return (text, date)
  }

  /// Replaces a terminal's saved text with its bounded form; unchanged or empty text leaves the file alone.
  @discardableResult
  public func save(_ text: String, key: String) throws -> Bool {
    let kept = SessionScrollback.bounded(text)
    guard !kept.isEmpty, load(key)?.text != kept else { return false }
    try write(Data(kept.utf8), to: url(for: key))
    return true
  }

  /// Writes a private file next to the scrollback, such as the text a shell prints into a recreated pane.
  public func writeTemporary(_ text: String, name: String) throws -> URL {
    let url = directory.appendingPathComponent(Self.fileName(name) + ".restore")
    try write(Data(text.utf8), to: url)
    return url
  }

  public func remove(_ keys: some Sequence<String>) {
    for key in keys { try? FileManager.default.removeItem(at: url(for: key)) }
  }

  /// Removes files for terminals that are no longer saved, once they are old enough that no
  /// live window can still be about to write them.
  public func prune(keeping keys: Set<String>, olderThan age: TimeInterval = 7 * 24 * 3600) {
    let keep = Set(keys.map { Self.fileName($0) + ".txt" })
    let cutoff = Date(timeIntervalSinceNow: -age)
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files where !keep.contains(file.lastPathComponent) {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      if modified < cutoff { try? FileManager.default.removeItem(at: file) }
    }
  }

  /// An atomic replacement created with owner-only permissions from the start.
  private func write(_ data: Data, to destination: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
    let descriptor = temporary.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    do {
      defer { Darwin.close(descriptor) }
      try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
          guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
          offset += written
        }
      }
      guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}
