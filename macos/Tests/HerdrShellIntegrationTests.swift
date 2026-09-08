// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class HerdrShellIntegrationTests: XCTestCase {
  func testStartupEnvironmentAndOptOut() throws {
    let resources = URL(fileURLWithPath: "/tmp/resources")
    let settings = AppConfiguration.defaults()
    let fish = HerdrShellIntegration.environment(settings: settings, resources: resources, shell: "/bin/fish", inherited: ["XDG_DATA_DIRS": "/tmp/resources/shell-integration:/custom"])
    XCTAssertEqual(fish["XDG_DATA_DIRS"], "/tmp/resources/shell-integration:/custom")
    let zsh = HerdrShellIntegration.environment(settings: settings, resources: resources, shell: "/bin/zsh", inherited: ["ZDOTDIR": "/custom"])
    XCTAssertEqual(zsh["GHOSTTY_ZSH_ZDOTDIR"], "/custom")
    XCTAssertEqual(zsh["ZDOTDIR"], "/tmp/resources/shell-integration/zsh")
    XCTAssertTrue(HerdrShellIntegration.environment(settings: settings, resources: resources, shell: "/bin/bash", inherited: [:]).isEmpty)
    let disabled = try AppConfiguration.parse(Data("[terminal]\nshell_integration='none'".utf8))
    XCTAssertTrue(HerdrShellIntegration.environment(settings: disabled, resources: resources, shell: "/bin/zsh", inherited: [:]).isEmpty)
  }
}
