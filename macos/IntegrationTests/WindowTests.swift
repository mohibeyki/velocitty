// SPDX-License-Identifier: GPL-3.0
import XCTest

final class WindowTests: XCTestCase {
  func testManagementUI() throws {
    try runCheck("WindowChecks", arguments: ["--management-ui"], success: "Management UI tests passed.")
  }
  func testMixedConnections() throws {
    try runCheck("WindowChecks", arguments: ["--mixed-connections"], success: "Mixed connection tests passed.")
  }
  func testWorkspacePersistence() throws {
    try runCheck("WindowChecks", arguments: ["--workspace-persistence"], success: "Workspace persistence tests passed.")
  }
  func testRelaunchRestoration() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("velocitty-restoration-" + UUID().uuidString)
    let bundleID = "app.velocitty.restoration." + UUID().uuidString
    let bundle = root.appendingPathComponent("Restoration.app")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? files.removeItem(at: root)
      try? files.removeItem(at: files.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Saved Application State/" + bundleID + ".savedState"))
      UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }
    try files.copyItem(at: productsDirectory.appendingPathComponent("Velocitty.app"), to: bundle)
    let executable = bundle.appendingPathComponent("Contents/MacOS/Velocitty")
    try files.removeItem(at: executable)
    try files.copyItem(at: productsDirectory.appendingPathComponent("WindowChecks"), to: executable)
    let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
    info["CFBundleIdentifier"] = bundleID
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", bundle.path]
    try signer.run()
    signer.waitUntilExit()
    XCTAssertEqual(signer.terminationStatus, 0)
    let config = root.appendingPathComponent("velocitty/config.toml")
    try files.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("[terminal]\nwindow_save_state='always'\nconfirm_close_surface=false\nshell_integration='none'\ntheme=''\n".utf8).write(to: config)
    for (phase, success) in [("write", "AppKit restoration state written."), ("read", "AppKit relaunch restoration passed.")] {
      let failures = testRun?.failureCount ?? 0
      try runCheck("Restoration " + phase, arguments: ["-ApplePersistenceIgnoreState", "NO"], executable: executable,
        environment: ["VELOKIT_TEST_RESTORATION": phase, "XDG_CONFIG_HOME": root.path,
          "VELOKIT_RESOURCES_DIR": bundle.appendingPathComponent("Contents/Resources").path],
        timeout: 25, success: success)
      if (testRun?.failureCount ?? 0) > failures { return }
    }
  }

  func testConfigurationReload() throws {
    try runCheck("WindowChecks", arguments: ["--configuration-only"], success: "Configuration reload tests passed.")
  }

  func testWindowLifecycle() throws {
    try runCheck("WindowChecks", success: "Window lifecycle tests passed.")
  }

  func testQuitWhenLastWindowCloses() throws {
    try runCheck("WindowChecks", arguments: ["--quit-on-close"], success: "Last-window quit test passed.")
  }
}
