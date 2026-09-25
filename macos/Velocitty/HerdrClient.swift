// SPDX-License-Identifier: GPL-3.0
import Darwin
import Foundation
import VelocittyConfiguration

// Control requests use the CLI; interactive I/O uses herdr's direct attach client.
// Control work runs off the main thread and is serialized per endpoint.
final class HerdrClient {
  struct Machine: Codable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool
  }
  var endpointID: String { identity ?? machine.map { "ssh:" + $0.id } ?? (sessionName == "velocitty" ? "local" : "local:" + sessionName) }
  private let identity: String?
  private let label: String?
  private let availabilityLock = NSLock()
  private var enabled = true
  private var availabilityGeneration = UUID()
  var isEnabled: Bool { availabilityLock.lock(); defer { availabilityLock.unlock() }; return enabled }
  var endpointLabel: String { label ?? machine?.label ?? (sessionName == "velocitty" ? "Local" : sessionName) }
  func owns(_ id: String) -> Bool { endpointID == "local" ? !id.contains("::") : id.hasPrefix(endpointID + "::") }
  func qualify(_ id: String) -> String { endpointID == "local" || id.isEmpty ? id : endpointID + "::" + id }
  private func raw(_ id: String) -> String { let prefix = endpointID + "::"; return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id }
  private func mapIDs(_ value: Any, incoming: Bool, key: String = "") -> Any {
    if let dictionary = value as? [String: Any] { return dictionary.mapValues { $0 }.reduce(into: [String: Any]()) { $0[$1.key] = mapIDs($1.value, incoming: incoming, key: $1.key) } }
    if let array = value as? [Any] { return array.map { mapIDs($0, incoming: incoming, key: key) } }
    if ["workspace_id", "tab_id", "pane_id", "terminal_id", "active_tab_id", "focused_pane_id", "target_pane_id", "source_pane_id"].contains(key), let id = value as? String { return incoming ? qualify(id) : raw(id) }
    return value
  }

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
  struct Rect: Decodable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
  }
  struct LayoutPane: Decodable, Equatable {
    let pane_id: String
    let rect: Rect
  }
  struct Layout: Decodable, Equatable {
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
    var endpointID: String? = nil
    func excluding(terminals: Set<String>) -> Snapshot {
      let panes = panes.filter { !terminals.contains($0.terminal_id) }
      let tabIDs = Set(panes.map(\.tab_id)), namespaceIDs = Set(panes.map(\.workspace_id))
      return Snapshot(layouts: layouts.filter { tabIDs.contains($0.tab_id) }, workspaces: workspaces.filter { namespaceIDs.contains($0.workspace_id) }, tabs: tabs.filter { tabIDs.contains($0.tab_id) }, panes: panes, endpointID: endpointID)
    }
    func filtered(namespaceIDs: Set<String>) -> Snapshot {
      let tabs = tabs.filter { namespaceIDs.contains($0.workspace_id) }
      let tabIDs = Set(tabs.map(\.tab_id))
      return Snapshot(layouts: layouts.filter { tabIDs.contains($0.tab_id) },
        workspaces: workspaces.filter { namespaceIDs.contains($0.workspace_id) }, tabs: tabs,
        panes: panes.filter { namespaceIDs.contains($0.workspace_id) }, endpointID: endpointID)
    }
  }
  final class LayoutNode: Decodable {
    let type: String
    let direction: String?
    let ratio: Double?
    let pane_id: String?
    let first: LayoutNode?
    let second: LayoutNode?
    func weight(along direction: String) -> Double {
      guard type == "split", self.direction == direction, let first, let second else { return 1 }
      return first.weight(along: direction) + second.weight(along: direction)
    }
  }

  struct Terminal {
    let client: HerdrClient
    let pane: Pane
    var command: String {
      var environment = ["/usr/bin/env", "-u", "HERDR_SESSION", "-u", "HERDR_SOCKET_PATH"]
      if let socket = client.forwardedSocket { environment.append("HERDR_SOCKET_PATH=" + socket) }
      return (environment + [client.executable.path] + client.connectionArguments + ["terminal", "attach", client.raw(pane.terminal_id)]).map(HerdrClient.quote).joined(separator: " ")
    }
  }

  let executable: URL
  let sessionName: String
  let machine: Machine?
  private let sshOptions: [String]
  private let remoteExecutable: String?
  private let remoteEnvironment: [String: String]
  private var tunnel: Process?
  private var tunnelDirectory: URL?
  private(set) var forwardedSocket: String?
  private var connectionArguments: [String] { machine == nil ? ["--session", sessionName] : [] }
  private let queue = DispatchQueue(label: "velocitty.herdr", qos: .userInitiated)
  private var server: Process?
  private var eventStream: HerdrEventStream?
  private var eventStarting = false
  private var eventPaneIDs: Set<String> = []
  private var eventGeneration = UUID()
  var eventsConnected: Bool { eventStream?.isSubscribed == true && eventStream?.isActive == true }
  var onWorkspaceEvent: (() -> Void)?
  private var cachedStatus: (TimeInterval, Snapshot)?

  init(executable: URL, sessionName: String = "velocitty", machine: Machine? = nil, sshOptions: [String] = [], remoteExecutable: String? = nil, remoteEnvironment: [String: String] = [:], identity: String? = nil, label: String? = nil) {
    self.identity = identity
    self.label = label
    self.executable = executable
    self.sessionName = machine?.session ?? sessionName
    self.machine = machine
    self.sshOptions = sshOptions
    self.remoteExecutable = remoteExecutable
    self.remoteEnvironment = remoteEnvironment
  }

  func observeEvents(panes: [Pane]) {
    let ids = Set(panes.map(\.pane_id))
    guard isEnabled, !eventStarting, eventStream?.isActive != true || eventPaneIDs != ids else { return }
    eventStarting = true
    let generation = UUID()
    eventGeneration = generation
    eventStream?.stop()
    eventStream = nil
    eventPaneIDs = ids
    perform({ client -> HerdrEventStream in
      let path = try client.socketPath()
      return try HerdrEventStream(path: path, paneIDs: Set(ids.map(client.raw)), changed: { [weak client] in
        DispatchQueue.main.async { client?.onWorkspaceEvent?() }
      }, ended: { [weak client] in
        DispatchQueue.main.async {
          if client?.eventGeneration == generation { client?.eventStream = nil }
        }
      })
    }) { [weak self] result in
      guard let self, self.eventGeneration == generation else {
        if case .success(let stream) = result { stream.stop() }
        return
      }
      self.eventStarting = false
      if case .success(let stream) = result, stream.isActive { self.eventStream = stream }
    }
  }

  /// True only with evidence of a foreground task; nil means we must ask.
  func hasRunningTask(paneID: String) throws -> Bool? {
    let result = try request(["pane", "process-info", "--pane", paneID], timeout: 1)
    guard let info = result["process_info"] as? [String: Any],
      let shell = info["shell_pid"] as? Int,
      let group = info["foreground_process_group_id"] as? Int,
      let processes = info["foreground_processes"] as? [[String: Any]] else { return nil }
    if group != shell { return true }
    guard !processes.isEmpty else { return nil }
    return processes.contains { ($0["pid"] as? Int) != shell }
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
    availabilityLock.lock()
    let generation = availabilityGeneration, submittedEnabled = enabled
    availabilityLock.unlock()
    queue.async {
      self.availabilityLock.lock()
      let enabled = self.enabled && self.availabilityGeneration == generation && submittedEnabled
      self.availabilityLock.unlock()
      let result = Result { guard enabled else { throw ConfigurationError("Connection disabled or changed.") }; return try work(self) }
      DispatchQueue.main.async {
        self.availabilityLock.lock()
        let current = self.enabled && generation == self.availabilityGeneration
        self.availabilityLock.unlock()
        completion(current ? result : .failure(ConfigurationError("Connection disabled or changed.")))
      }
    }
  }

  func setEnabled(_ value: Bool) {
    availabilityLock.lock(); enabled = value; availabilityGeneration = UUID(); availabilityLock.unlock()
    eventGeneration = UUID(); eventStarting = false
    eventStream?.stop(); eventStream = nil
    if !value { queue.async { self.cachedStatus = nil; self.disconnectTransport() } }
  }

  private func process(_ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = connectionArguments + arguments.map(raw)
    process.environment = ProcessInfo.processInfo.environment.filter {
      !$0.key.hasPrefix("HERDR_") || $0.key == "HERDR_CONFIG_PATH"
    }
    if process.environment?["SHELL"] == nil, let user = getpwuid(getuid()) {
      process.environment?["SHELL"] = String(cString: user.pointee.pw_shell)
    }
    if let forwardedSocket { process.environment?["HERDR_SOCKET_PATH"] = forwardedSocket }
    process.standardInput = FileHandle.nullDevice
    return process
  }

  // Only short-lived CLI requests use this launcher. The persistent server
  // is launched separately and can never share a request's process group.
  private final class RequestProcess {
    let processIdentifier: pid_t
    private var status: Int32 = 0
    private var reaped = false
    var isRunning: Bool {
      if !reaped { reaped = waitpid(processIdentifier, &status, WNOHANG) == processIdentifier }
      return !reaped
    }
    var terminationStatus: Int32 { (status >> 8) & 255 }
    var terminationReason: Process.TerminationReason { status & 127 == 0 ? .exit : .uncaughtSignal }
    init(executable: String, arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32) throws {
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      posix_spawn_file_actions_init(&actions)
      posix_spawnattr_init(&attributes)
      defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
      posix_spawnattr_setpgroup(&attributes, 0)
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
      posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
      posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
      let argv = ([executable] + arguments).map { strdup($0) } + [nil]
      let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer { argv.forEach { free($0) }; env.forEach { free($0) } }
      var pid: pid_t = 0
      let code = argv.withUnsafeBufferPointer { argv in env.withUnsafeBufferPointer { env in
        posix_spawn(&pid, executable, &actions, &attributes,
          UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
      } }
      guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
      processIdentifier = pid
    }
    func waitUntilExit() { if !reaped { while waitpid(processIdentifier, &status, 0) == -1 && errno == EINTR {}; reaped = true } }
    func killGroup() { kill(-processIdentifier, SIGKILL); waitUntilExit() }
  }

  struct RequestError: LocalizedError {
    let code: String?
    let message: String
    var errorDescription: String? { message }
  }

  // Drain both streams without allowing an inherited pipe in a descendant to
  // extend the deadline. JSON is always read from stdout, never mixed with logs.
  func run(_ arguments: [String], timeout: TimeInterval = 5) throws -> Data {
    if machine != nil { try ensureRemoteTransport() }
    return try runProgram(executable: executable, arguments: connectionArguments + arguments.map(raw), environment: process(arguments).environment ?? [:], timeout: timeout)
  }

  private func runProgram(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> Data {
    let output = Pipe(), errors = Pipe()
    let child = try RequestProcess(executable: executable.path, arguments: arguments,
      environment: environment, stdout: output.fileHandleForWriting.fileDescriptor,
      stderr: errors.fileHandleForWriting.fileDescriptor)
    try output.fileHandleForWriting.close()
    try errors.fileHandleForWriting.close()
    let handles = [output.fileHandleForReading, errors.fileHandleForReading]
    defer { handles.forEach { try? $0.close() } }
    for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
    var streams = [Data(), Data()]
    var ended = [false, false]
    var buffer = [UInt8](repeating: 0, count: 16384)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while child.isRunning || !ended.allSatisfy({ $0 }) {
      for index in handles.indices where !ended[index] {
        let count = read(handles[index].fileDescriptor, &buffer, buffer.count)
        if count > 0 { streams[index].append(contentsOf: buffer.prefix(count)) }
        else if count == 0 { ended[index] = true }
        else if errno != EAGAIN && errno != EINTR { ended[index] = true }
      }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        child.killGroup()
        throw RequestError(code: "timeout", message: "herdr request timed out.")
      }
      if streams.contains(where: { $0.count > 64 * 1024 * 1024 }) {
        child.killGroup()
        throw RequestError(code: nil, message: "herdr response exceeded the size limit.")
      }
      if !ended.allSatisfy({ $0 }) || child.isRunning { Thread.sleep(forTimeInterval: 0.001) }
    }
    child.waitUntilExit()
    guard child.terminationReason == .exit, child.terminationStatus == 0 else {
      for data in streams {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = json["error"] as? [String: Any] {
          throw RequestError(code: error["code"] as? String, message: error["message"] as? String ?? "herdr request failed.")
        }
      }
      let detail = String(decoding: streams[1].isEmpty ? streams[0] : streams[1], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw RequestError(code: nil, message: detail.isEmpty ? "herdr did not complete the request." : String(detail.prefix(1500)))
    }
    return streams[0]
  }

  private func socketPath() throws -> String {
    if machine != nil { try ensureRemoteTransport(); if let forwardedSocket { return forwardedSocket } }
    let data = try run(["session", "list", "--json"])
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let sessions = json?["sessions"] as? [[String: Any]],
      let path = sessions.first(where: { $0["name"] as? String == sessionName })?["socket_path"] as? String else {
      throw ConfigurationError("herdr did not report its API socket.")
    }
    return path
  }

  // Explicit-ID operations absent from the CLI use the same framed API as herdr.
  func api(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
    let path = try socketPath()
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ConfigurationError("herdr socket path is too long.") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in pathBytes.withUnsafeBytes { buffer.copyBytes(from: $0) } }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw ConfigurationError("Could not connect to herdr.") }
    var data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": mapIDs(params, incoming: false)])
    data.append(10)
    var sent = 0
    while sent < data.count {
      let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), data.count - sent) }
      guard count > 0 else { throw ConfigurationError("herdr API write failed.") }
      sent += count
    }
    var received = Data()
    var bytes = [UInt8](repeating: 0, count: 16384)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while received.count < 4 * 1024 * 1024 && ProcessInfo.processInfo.systemUptime < deadline {
      let count = Darwin.read(fd, &bytes, bytes.count)
      guard count > 0 else { throw ConfigurationError("herdr API connection ended or timed out.") }
      received.append(contentsOf: bytes.prefix(count))
      if let end = received.firstIndex(of: 10) {
        let json = try JSONSerialization.jsonObject(with: received.prefix(upTo: end)) as? [String: Any]
        if let error = json?["error"] as? [String: Any] { throw RequestError(code: error["code"] as? String, message: error["message"] as? String ?? "herdr API request failed.") }
        guard let result = json?["result"] as? [String: Any] else { throw ConfigurationError("Invalid herdr API response.") }
        cachedStatus = nil
        return mapIDs(result, incoming: true) as? [String: Any] ?? result
      }
    }
    throw ConfigurationError("herdr API response exceeded its limit.")
  }

  func layoutTree(tabID: String) throws -> LayoutNode {
    let response = try api("layout.export", ["tab_id": tabID])
    guard let layout = response["layout"] as? [String: Any], let root = layout["root"] else { throw ConfigurationError("herdr did not return a layout tree.") }
    return try JSONDecoder().decode(LayoutNode.self, from: JSONSerialization.data(withJSONObject: root))
  }

  func moveTab(tabID: String, workspaceID: String?, label: String?, namespaceLabel: String? = nil) throws {
    let before = try snapshot()
    let root = try layoutTree(tabID: tabID)
    let terminals = Dictionary(uniqueKeysWithValues: before.panes.map { ($0.pane_id, $0.terminal_id) })
    func firstTerminal(_ node: LayoutNode) throws -> String {
      if let id = node.pane_id, let terminal = terminals[id] { return terminal }
      if let first = node.first { return try firstTerminal(first) }
      throw ConfigurationError("Invalid source pane layout.")
    }
    func current(_ terminal: String) throws -> Pane {
      guard let pane = try snapshot().panes.first(where: { $0.terminal_id == terminal }) else { throw ConfigurationError("A terminal disappeared while moving the tab.") }
      return pane
    }
    let firstID = try firstTerminal(root)
    let firstPane = try current(firstID)
    var destination: [String: Any]
    if let workspaceID {
      destination = ["type": "new_tab", "workspace_id": workspaceID]
      if let label { destination["label"] = label }
    } else {
      destination = ["type": "new_workspace", "label": namespaceLabel ?? "Namespace"]
      if let label { destination["tab_label"] = label }
    }
    _ = try api("pane.move", ["pane_id": firstPane.pane_id, "destination": destination, "focus": false])
    let moved = try current(firstID)
    guard moved.tab_id != firstPane.tab_id,
      workspaceID.map({ moved.workspace_id == $0 }) ?? (moved.workspace_id != firstPane.workspace_id) else {
      throw ConfigurationError("herdr did not move the tab. Check whether another client has zoomed its layout.")
    }
    let newTabID = moved.tab_id
    func build(_ node: LayoutNode) throws {
      guard let first = node.first, let second = node.second, let direction = node.direction else { return }
      let target = try current(firstTerminal(first))
      let source = try current(firstTerminal(second))
      _ = try api("pane.move", ["pane_id": source.pane_id, "destination": ["type": "tab", "tab_id": newTabID, "target_pane_id": target.pane_id, "split": direction, "ratio": node.ratio ?? 0.5], "focus": false])
      guard try current(source.terminal_id).tab_id == newTabID else { throw ConfigurationError("herdr did not move a pane; the partial move has been retained.") }
      try build(first)
      try build(second)
    }
    try build(root)
  }

  func equalize(tabID: String) throws {
    let root = try layoutTree(tabID: tabID)
    func apply(_ node: LayoutNode, path: [Bool]) throws {
      guard let first = node.first, let second = node.second, let direction = node.direction else { return }
      let weight = first.weight(along: direction)
      let ratio = weight / (weight + second.weight(along: direction))
      if abs((node.ratio ?? 0.5) - ratio) > 0.001 {
        _ = try api("layout.set_split_ratio", ["tab_id": tabID, "path": path, "ratio": ratio])
      }
      try apply(first, path: path + [false])
      try apply(second, path: path + [true])
    }
    try apply(root, path: [])
  }

  func request(_ arguments: [String], timeout: TimeInterval = 5) throws -> [String: Any] {
    cachedStatus = nil
    let data = try run(arguments, timeout: timeout)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let result = response["result"] as? [String: Any]
    else {
      throw ConfigurationError("herdr returned an invalid response.")
    }
    return mapIDs(result, incoming: true) as? [String: Any] ?? result
  }

  // Shared by all windows; structural operations always request a fresh snapshot.
  func statusSnapshot() throws -> Snapshot {
    let now = ProcessInfo.processInfo.systemUptime
    if let (time, snapshot) = cachedStatus, now - time < 1 { return snapshot }
    let value = try snapshot(timeout: 0.75)
    cachedStatus = (now, value)
    return value
  }

  func snapshot(timeout: TimeInterval = 5) throws -> Snapshot {
    let result = try request(["api", "snapshot"], timeout: timeout)
    guard let value = result["snapshot"] else {
      throw ConfigurationError("herdr did not return a session snapshot.")
    }
    var snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: value))
    snapshot.endpointID = endpointID
    let workspaceIDs = snapshot.workspaces.map(\.workspace_id)
    let tabIDs = snapshot.tabs.map(\.tab_id)
    let paneIDs = snapshot.panes.map(\.pane_id)
    let terminalIDs = snapshot.panes.map(\.terminal_id)
    guard [workspaceIDs, tabIDs, paneIDs, terminalIDs].allSatisfy({ Set($0).count == $0.count && !$0.contains("") }),
      snapshot.tabs.allSatisfy({ tab in workspaceIDs.contains(tab.workspace_id) && snapshot.panes.filter { $0.tab_id == tab.tab_id }.count == tab.pane_count }),
      snapshot.panes.allSatisfy({ pane in snapshot.tabs.contains { $0.tab_id == pane.tab_id && $0.workspace_id == pane.workspace_id } })
    else { throw ConfigurationError("herdr returned an inconsistent session snapshot.") }
    cachedStatus = (ProcessInfo.processInfo.systemUptime, snapshot)
    return snapshot
  }

  func connect(directory: URL) throws -> Snapshot {
    let version = String(decoding: try run(["--version"]), as: UTF8.self)
    let match = version.range(of: #"^herdr\s+v?([0-9]+\.[0-9]+\.[0-9]+)"#, options: .regularExpression)
    let numbers = match.map { version[$0].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } } ?? []
    guard numbers.count >= 3,
      Array(numbers.prefix(3)).lexicographicallyPrecedes([0, 8, 2]) == false
    else {
      throw ConfigurationError("herdr 0.8.2 or newer is required for direct terminal attachment.")
    }
    do { return try snapshot() }
    catch let error as RequestError where error.code == "server_not_running" { /* Start only an absent server. */ }
    guard machine == nil else { throw ConfigurationError("Start the selected herdr session on " + endpointLabel + " before connecting.") }
    let child = process(["server"])
    child.currentDirectoryURL = directory
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    server = child  // Closing the app does not stop this server or its terminals.
    let deadline = Date(timeIntervalSinceNow: 5)
    repeat {
      if let value = try? snapshot(timeout: min(0.5, max(0.05, deadline.timeIntervalSinceNow))) { return value }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline && child.isRunning
    if child.isRunning { child.terminate() }
    server = nil
    throw ConfigurationError(
      "Could not connect to the herdr session ‘\(sessionName)’. Check herdr's server log.")
  }

  func gitBranch(directory: String) throws -> String? {
    guard machine != nil else { return nil }
    let command = "git -C " + Self.quote(directory) + " symbolic-ref --quiet --short HEAD 2>/dev/null || git -C " + Self.quote(directory) + " rev-parse --short HEAD 2>/dev/null || true"
    let value = String(decoding: try ssh(command, timeout: 3), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  func machines() throws -> [Machine] {
    try JSONDecoder().decode([Machine].self, from: run(["machine", "list", "--json"]))
  }

  private func ssh(_ command: String, timeout: TimeInterval = 10) throws -> Data {
    guard let machine, !machine.target.isEmpty, !machine.target.hasPrefix("-") else { throw ConfigurationError("Invalid SSH destination.") }
    return try runProgram(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
      arguments: sshOptions + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", machine.target, command],
      environment: ProcessInfo.processInfo.environment, timeout: timeout)
  }

  private func ensureRemoteTransport() throws {
    guard let machine else { return }
    if tunnel?.isRunning == true, let forwardedSocket, FileManager.default.fileExists(atPath: forwardedSocket) { return }
    disconnectTransport()
    let executable: String
    if let remoteExecutable { executable = remoteExecutable }
    else {
      let lookup = "command -v herdr || for p in \"$HOME/.local/bin/herdr\" \"$HOME/.cargo/bin/herdr\" /opt/homebrew/bin/herdr \"$HOME/.nix-profile/bin/herdr\" \"/etc/profiles/per-user/$(id -un)/bin/herdr\"; do if test -x \"$p\"; then printf '%s' \"$p\"; break; fi; done"
      let output = try ssh("/bin/sh -lc " + Self.quote(lookup))
      executable = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !executable.isEmpty, !executable.contains("\n") else { throw ConfigurationError("herdr was not found on " + machine.label) }
    }
    let command = (["/usr/bin/env"] + remoteEnvironment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value } + [executable, "--session", machine.session, "session", "list", "--json"]).map(Self.quote).joined(separator: " ")
    let response = try JSONSerialization.jsonObject(with: ssh(command)) as? [String: Any]
    guard let sessions = response?["sessions"] as? [[String: Any]], let socket = sessions.first(where: { $0["name"] as? String == machine.session })?["socket_path"] as? String else { throw ConfigurationError("The selected herdr session was not found on " + machine.label) }
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("vt-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let local = directory.appendingPathComponent("herdr.sock").path
    let remoteClient = String(socket.dropLast(5)) + "-client.sock"
    let connection = Process()
    connection.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    connection.arguments = sshOptions + ["-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-L", local + ":" + socket, "-L", directory.appendingPathComponent("herdr-client.sock").path + ":" + remoteClient, machine.target]
    connection.standardInput = FileHandle.nullDevice
    connection.standardOutput = FileHandle.nullDevice
    connection.standardError = FileHandle.nullDevice
    do { try connection.run() } catch { try? FileManager.default.removeItem(at: directory); throw error }
    tunnel = connection
    tunnelDirectory = directory
    let deadline = Date(timeIntervalSinceNow: 6)
    while connection.isRunning && !FileManager.default.fileExists(atPath: local) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    guard connection.isRunning, FileManager.default.fileExists(atPath: local) else { disconnectTransport(); throw ConfigurationError("SSH forwarding failed for " + machine.label + ". Check your SSH login and server availability.") }
    forwardedSocket = local
  }

  func disconnectTransport() {
    if tunnel?.isRunning == true { tunnel?.terminate() }
    tunnel = nil
    forwardedSocket = nil
    if let tunnelDirectory { try? FileManager.default.removeItem(at: tunnelDirectory) }
    tunnelDirectory = nil
  }
  deinit { disconnectTransport() }

  func shellEnvironment(settings: AppConfiguration) -> [String: String] {
    // Local bundle paths are not valid on another host.
    if machine != nil { return [:] }
    let inherited = ProcessInfo.processInfo.environment
    let home = settings.home
    let config = inherited["HERDR_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }
      ?? URL(fileURLWithPath: inherited["XDG_CONFIG_HOME"] ?? home.appendingPathComponent(".config").path).appendingPathComponent("herdr/config.toml")
    let fallback = inherited["SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    let shell = HerdrShellIntegration.configuredShell(from: config, fallback: fallback)
    guard let resources = inherited["VELOKIT_RESOURCES_DIR"].map({ URL(fileURLWithPath: $0) }) ?? Bundle.main.resourceURL else { return [:] }
    return HerdrShellIntegration.environment(settings: settings, resources: resources, shell: shell, inherited: inherited)
  }
  static func environmentArguments(_ environment: [String: String]) -> [String] {
    environment.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
  }

  func createPane(workspace: String?, name: String, directory: String?, environment: [String: String] = [:]) throws -> Pane {
    let response: [String: Any]
    if let workspace {
      response = try request(["tab", "create", "--workspace", workspace, "--no-focus"] + (directory.map { ["--cwd", $0] } ?? []) + Self.environmentArguments(environment))
    } else {
      response = try request(["workspace", "create", "--label", name, "--no-focus"] + (directory.map { ["--cwd", $0] } ?? []) + Self.environmentArguments(environment))
    }
    guard let pane = response["root_pane"] else { throw ConfigurationError("herdr did not identify the created terminal.") }
    return try JSONDecoder().decode(Pane.self, from: JSONSerialization.data(withJSONObject: pane))
  }

  func create(workspace: String?, name: String, directory: String?, environment: [String: String] = [:]) throws -> Snapshot {
    _ = try createPane(workspace: workspace, name: name, directory: directory, environment: environment)
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

// A read-only event connection. All mutations and terminal I/O still use explicit IDs.
private final class HerdrEventStream {
  private let source: DispatchSourceRead
  private var buffer = Data()
  private var stopped = false
  private(set) var isSubscribed = false
  var isActive: Bool { !stopped }
  init(path: String, paneIDs: Set<String>, changed: @escaping () -> Void, ended: @escaping () -> Void) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ConfigurationError("herdr socket path is too long.") }
    withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let types = ["workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed", "tab.created", "tab.closed", "tab.renamed", "tab.moved", "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.exited", "pane.agent_detected", "layout.updated"]
    let subscriptions: [[String: String]] = types.map { ["type": $0] }
      + paneIDs.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
    var request = try JSONSerialization.data(withJSONObject: ["id": "velocitty-events", "method": "events.subscribe", "params": ["subscriptions": subscriptions]])
    request.append(10)
    let sent = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == request.count else { Darwin.close(fd); throw POSIXError(.EIO) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setCancelHandler { Darwin.close(fd) }
    source.setEventHandler { [weak self] in
      guard let self, !self.stopped else { return }
      var bytes = [UInt8](repeating: 0, count: 16384)
      let count = read(fd, &bytes, bytes.count)
      if count <= 0 {
        if count == 0 || (errno != EAGAIN && errno != EINTR) { self.stop(); ended() }
        return
      }
      self.buffer.append(contentsOf: bytes.prefix(count))
      guard self.buffer.count < 4 * 1024 * 1024 else { self.stop(); ended(); return }
      var updated = false
      while let end = self.buffer.firstIndex(of: 10) {
        let line = self.buffer.prefix(upTo: end)
        self.buffer.removeSubrange(...end)
        if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
          if json["error"] != nil { self.stop(); ended(); return }
          if let result = json["result"] as? [String: Any], result["type"] as? String == "subscription_started" { self.isSubscribed = true }
          if json["event"] != nil { updated = true }
        }
      }
      if updated { changed() }
    }
    source.resume()
  }
  func stop() { guard !stopped else { return }; stopped = true; source.cancel() }
  deinit { source.cancel() }
}
