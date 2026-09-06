// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit
import VelocittyConfiguration

if let resources = Bundle.main.resourceURL {
  setenv("VELOKIT_RESOURCES_DIR", resources.path, 1)
}

guard velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
  NSLog("libghostty initialization failed")
  exit(1)
}

// Handle CLI output before creating an AppKit application or terminal process.
if CommandLine.arguments.dropFirst().contains("--dump-config") {
  do {
    guard let config = velokit_config_new() else {
      throw ConfigurationError("Could not allocate the terminal configuration.")
    }
    defer { velokit_config_free(config) }
    let output = try ConfigurationTemplate.render { key in
      guard let entry = key.withCString({ velokit_config_format(config, $0) }) else {
        throw ConfigurationError("Could not format default for \(key).")
      }
      return String(cString: entry)
    }
    try FileHandle.standardOutput.write(contentsOf: Data(output.utf8))
    exit(0)
  } catch {
    try? FileHandle.standardError.write(contentsOf: Data("\(error.localizedDescription)\n".utf8))
    exit(1)
  }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
