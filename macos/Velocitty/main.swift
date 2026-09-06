// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit

if let resources = Bundle.main.resourceURL {
  setenv("VELOKIT_RESOURCES_DIR", resources.path, 1)
}

guard velokit_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
  NSLog("libghostty initialization failed")
  exit(1)
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
