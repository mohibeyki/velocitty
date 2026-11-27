// SPDX-License-Identifier: GPL-3.0
import Foundation

/// Reads a directory's git branch by running the system git, never blocking for long.
public enum GitBranchReader {
  /// Output of `git` run in `directory`, trimmed; nil when it fails, prints nothing or exceeds `timeout`.
  public static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 2) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["--no-optional-locks", "-C", directory] + arguments
    process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let killer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    guard process.terminationStatus == 0 else { return nil }
    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// The branch name, or "Detached · <commit>"; nil outside a repository.
  public static func branch(at directory: String) -> String? {
    if let branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory) { return branch }
    return run(["rev-parse", "--short", "HEAD"], in: directory).map { "Detached · " + $0 }
  }

  /// The repository's absolute git directory, whose changes mean the branch may have changed.
  public static func gitDirectory(at directory: String) -> String? {
    run(["rev-parse", "--absolute-git-dir"], in: directory)
  }
}
