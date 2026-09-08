import Darwin
// SPDX-License-Identifier: GPL-3.0
import Foundation
import VelocittyConfiguration

// Control requests use the CLI; interactive I/O uses herdr's direct attach client.
// All control work runs off the main thread and is serialized per app instance.
final class HerdrClient {
  struct Workspace: Decodable {
    let workspace_id: String
    let label: String
    let active_tab_id: String
    let tokens: [String: String]?
  }
  struct Tab: Decodable {
    let tab_id: String
    let workspace_id: String
    let label: String
    let pane_count: Int
    var number: Int? = nil
  }
  struct Pane: Decodable {
    let pane_id: String
    let terminal_id: String
    let workspace_id: String
    let tab_id: String
    let cwd: String?
    var terminal_title: String? = nil
    var terminal_title_stripped: String? = nil
    var foreground_cwd: String? = nil
    var agent: String? = nil
    var display_agent: String? = nil
    var agent_status: String? = nil
  }
  struct Rect: Decodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
  }
  struct LayoutPane: Decodable {
    let pane_id: String
    let rect: Rect
  }
  struct Layout: Decodable {
    let tab_id: String
    let area: Rect
    let focused_pane_id: String
    let panes: [LayoutPane]
  }
  struct Snapshot: Decodable {
    let layouts: [Layout]
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
  }
  struct Terminal {
    let client: HerdrClient
    let pane: Pane
    var command: String {
      ([
        "/usr/bin/env", "-u", "HERDR_SOCKET_PATH", "-u", "HERDR_SESSION",
        client.executable.path, "--session", client.sessionName,
        "terminal", "attach", pane.terminal_id,
      ].map(HerdrClient.quote)).joined(separator: " ")
    }
  }

  let executable: URL
  let sessionName: String
  private let queue = DispatchQueue(label: "velocitty.herdr", qos: .userInitiated)
  private var server: Process?

  init(executable: URL, sessionName: String = "velocitty") {
    self.executable = executable
    self.sessionName = sessionName
  }

  static func discover() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let paths =
      (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
      + [
        "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin",
        "\(home)/.nix-profile/bin", "/etc/profiles/per-user/\(NSUserName())/bin",
        "/run/current-system/sw/bin",
      ]
    return paths.filter { $0.hasPrefix("/") }.map {
      URL(fileURLWithPath: $0).appendingPathComponent("herdr")
    }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  func perform<T>(
    _ work: @escaping (HerdrClient) throws -> T,
    completion: @escaping (Result<T, Error>) -> Void
  ) {
    queue.async {
      let result = Result { try work(self) }
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func process(_ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--session", sessionName] + arguments
    process.environment = ProcessInfo.processInfo.environment.filter {
      !$0.key.hasPrefix("HERDR_") || $0.key == "HERDR_CONFIG_PATH"
    }
    process.standardInput = FileHandle.nullDevice
    return process
  }

  // Drain output while the child runs, with a deadline even for a hung CLI/server.
  func run(_ arguments: [String], timeout: TimeInterval = 5) throws -> Data {
    let child = process(arguments)
    let output = Pipe()
    child.standardOutput = output
    child.standardError = output
    try child.run()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
    timer.resume()
    defer { timer.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    guard child.terminationReason == .exit, child.terminationStatus == 0 else {
      let detail =
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw ConfigurationError(
        detail.isEmpty ? "herdr did not complete the request." : String(detail.prefix(1500)))
    }
    return data
  }

  func request(_ arguments: [String]) throws -> [String: Any] {
    let data = try run(arguments)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let result = response["result"] as? [String: Any]
    else {
      throw ConfigurationError("herdr returned an invalid response.")
    }
    return result
  }

  func snapshot() throws -> Snapshot {
    let result = try request(["api", "snapshot"])
    guard let value = result["snapshot"] else {
      throw ConfigurationError("herdr did not return a session snapshot.")
    }
    return try JSONDecoder().decode(
      Snapshot.self, from: JSONSerialization.data(withJSONObject: value))
  }

  func connect(directory: URL) throws -> Snapshot {
    let version = String(decoding: try run(["--version"]), as: UTF8.self)
    let numbers = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    guard numbers.count >= 3,
      Array(numbers.prefix(3)).lexicographicallyPrecedes([0, 8, 2]) == false
    else {
      throw ConfigurationError("herdr 0.8.2 or newer is required for direct terminal attachment.")
    }
    if let existing = try? snapshot() { return existing }
    let child = process(["server"])
    child.currentDirectoryURL = directory
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    server = child  // Closing the app does not stop this server or its terminals.
    let deadline = Date(timeIntervalSinceNow: 5)
    repeat {
      if let value = try? snapshot() { return value }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline && child.isRunning
    throw ConfigurationError(
      "Could not connect to the herdr session ‘\(sessionName)’. Check herdr's server log.")
  }

  func create(workspace: String?, name: String, directory: String) throws -> Snapshot {
    if let workspace {
      _ = try request(["tab", "create", "--workspace", workspace, "--cwd", directory, "--no-focus"])
    } else {
      _ = try request(["workspace", "create", "--label", name, "--cwd", directory, "--no-focus"])
    }
    return try snapshot()
  }

  func rename(workspace: String, name: String, subtitle: String) throws {
    _ = try request(["workspace", "rename", workspace, name])
    // Metadata updates are display-only and are owned by herdr along with the workspace.
    _ = try run([
      "workspace", "report-metadata", workspace, "--source", "velocitty",
      "--token", "subtitle=" + subtitle,
    ])
  }
}
