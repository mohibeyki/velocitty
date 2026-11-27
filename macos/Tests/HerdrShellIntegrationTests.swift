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

  func testShellFeaturesParsing() throws {
    func features(_ terminal: String) throws -> String? {
      let settings = try AppConfiguration.parse(Data(("[terminal]\n" + terminal).utf8))
      return HerdrShellIntegration.environment(settings: settings, resources: URL(fileURLWithPath: "/r"), shell: "/bin/zsh", inherited: [:])["GHOSTTY_SHELL_FEATURES"]
    }
    XCTAssertEqual(try features(""), "cursor:blink,path,title")
    XCTAssertEqual(try features("cursor_style_blink = false"), "cursor:steady,path,title")
    XCTAssertEqual(try features("shell_integration_features = 'no-title,no-cursor,sudo'"), "path,sudo")
    XCTAssertEqual(try features("shell_integration_features = 'false'"), "")
    XCTAssertEqual(try features("shell_integration_features = 'false,title'"), "title")
    XCTAssertEqual(try features("shell_integration_features = 'true'"), "cursor:blink,path,ssh-env,ssh-terminfo,sudo,title")
  }

  func testConfiguredShell() throws {
    let directory = try makeTemporaryDirectory()
    func shell(_ contents: String?) throws -> String {
      let url = directory.appendingPathComponent(UUID().uuidString + ".toml")
      if let contents { try Data(contents.utf8).write(to: url) }
      return HerdrShellIntegration.configuredShell(from: url, fallback: "/bin/fallback")
    }
    XCTAssertEqual(try shell("[terminal]\ndefault_shell = ' /bin/fish '"), "/bin/fish")
    XCTAssertEqual(try shell("[terminal]\ndefault_shell = '  '"), "/bin/fallback")
    XCTAssertEqual(try shell("[terminal]\nfont_size = 12"), "/bin/fallback")
    XCTAssertEqual(try shell("not = [valid"), "/bin/fallback")
    XCTAssertEqual(try shell(nil), "/bin/fallback")
  }
}
