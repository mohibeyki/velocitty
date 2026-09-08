// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest

@testable import VelocittyConfiguration

final class AppConfigurationTests: XCTestCase {
  func parse(_ text: String) throws -> AppConfiguration {
    try AppConfiguration.parse(Data(text.utf8))
  }

  func testInterfaceSettingsAreValidatedSeparatelyFromTerminalOptions() throws {
    let config = try parse("""
      [interface]
      theme = "light"
      chrome_background_color = "#112233"
      agent_icon_size = 18
      waiting_color = "#998877"
      waiting_style = "dotted"
      idle_style = "invalid"
      agent_border_width = -1
      [terminal]
      font_size = 14
      """)
    XCTAssertEqual(config.interface["theme"], "light")
    XCTAssertEqual(config.interface["chrome_background_color"], "#112233")
    XCTAssertEqual(config.interface["agent_icon_size"], "18")
    XCTAssertEqual(config.interface["waiting_color"], "#998877")
    XCTAssertEqual(config.interface["waiting_style"], "dotted")
    XCTAssertNil(config.interface["idle_style"])
    XCTAssertNil(config.interface["agent_border_width"])
    XCTAssertEqual(config.diagnostics.count, 2)
    XCTAssertEqual(config.options.map(\.key), ["font-size"])
  }

  func testConfigurationTemplateRoundTrip() throws {
    let template = try ConfigurationTemplate.render { key in
      switch key {
      case "title": return "title = a \"quote\" \\ path\t雪\n"
      case "font-family": return "font-family = Menlo\nfont-family = Monaco\n"
      default: return "\(key) = \n"
      }
    }
    XCTAssertEqual(try parse(template).options, [])
    let active = template.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.hasPrefix("# ") && ($0.contains(" = ") || $0.hasPrefix("#   ") || $0 == "# ]")
        ? String($0.dropFirst(2)) : String($0)
    }.joined(separator: "\n")
    let settings = try parse(active)
    XCTAssertEqual(Set(settings.options.map(\.key)), TerminalSettings.supported)
    XCTAssertEqual(settings.interface, NamespaceAppearance.defaults)
    XCTAssertEqual(settings.options.first { $0.key == "title" }?.value, "a \"quote\" \\ path\t雪")
    XCTAssertEqual(
      settings.options.filter { $0.key == "font-family" }.map(\.value), ["Menlo", "Monaco"])
    XCTAssertEqual(
      settings.options.first { $0.key == "theme" }?.value, TerminalTheme.defaultSelection)
  }

  func testDroppedPathsAreLiteralShellArguments() throws {
    let paths = [
      "/tmp/a b", "/tmp/it's", "/tmp/$(printf WRONG)", "/tmp/a;printf WRONG", "/tmp/雪\nline",
    ]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf '%s\\0' " + ShellInput.paths(paths)]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(bytes, Data((paths.joined(separator: "\0") + "\0").utf8))
    XCTAssertEqual(ShellInput.paths([]), "")
    XCTAssertFalse(ShellInput.paths(paths).hasSuffix("\n"))
  }

  func testDefaultsAndMissingFile() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertEqual(AppConfiguration.defaults(home: home).workingDirectory, home)
    let workspace = home.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let source = home.appendingPathComponent("missing.toml")
    let defaults = AppConfiguration.defaults(home: home, source: source)
    XCTAssertEqual(defaults.workingDirectory, workspace)
    XCTAssertEqual(AppConfiguration.load(from: source, home: home), defaults)
    XCTAssertEqual(try AppConfiguration.parse(Data(), home: home, source: source), defaults)
  }

  func testIncludesNativeOrderAndCycles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("config.toml")
    let child = root.appendingPathComponent("colors.toml")
    try Data("[terminal]\nfont_size = 18\nforeground = '#ffffff'".utf8).write(to: child)
    try Data("[terminal]\nconfig_file = ['colors.toml', '?absent.toml']\nfont_size = 14".utf8)
      .write(to: parent)
    let config = AppConfiguration.load(from: parent)
    XCTAssertEqual(config.options.filter { $0.key == "font-size" }.map(\.value), ["14", "18"])
    XCTAssertEqual(config.options.first { $0.key == "foreground" }?.source, child)
    XCTAssertFalse(config.options.contains { $0.key == "config-file" })
    try Data("[terminal]\nconfig_file = 'config.toml'".utf8).write(to: child)
    let cycle = AppConfiguration.load(from: parent)
    XCTAssertTrue(cycle.diagnostics.contains { $0.contains("cycle") })
    XCTAssertEqual(cycle.options.first { $0.key == "font-size" }?.value, "14")
    try Data("[terminal]\nconfig_file = 'absent.toml'".utf8).write(to: parent)
    XCTAssertTrue(
      AppConfiguration.load(from: parent).diagnostics.contains { $0.contains("absent.toml") })
  }

  func testIncludeQueueAndRepeatableValues() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("config.toml")
    try Data("[terminal]\nconfig_file=['a.toml','b.toml']\nfont_family=['Menlo']".utf8).write(to: file)
    try Data("[terminal]\nconfig_file='c.toml'\nfont_family=['Monaco']".utf8).write(to: root.appendingPathComponent("a.toml"))
    try Data("[terminal]\nfont_family=[]".utf8).write(to: root.appendingPathComponent("b.toml"))
    try Data("[terminal]\nfont_family=['Courier']".utf8).write(to: root.appendingPathComponent("c.toml"))
    let config = AppConfiguration.load(from: file)
    XCTAssertTrue(config.diagnostics.isEmpty)
    XCTAssertEqual(config.options.map(\.value), ["Menlo", "Monaco", "", "Courier"])
  }

  func testInterfaceIncludesAndOptionalRequiredFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("config.toml")
    try Data("[interface]\nagent-icon-size=20\n[terminal]\nconfig_file=['?missing.toml','missing.toml','child.toml']".utf8).write(to: file)
    try Data("[interface]\nagent_icon_size=24\n".utf8).write(to: root.appendingPathComponent("child.toml"))
    let config = AppConfiguration.load(from: file)
    XCTAssertEqual(config.interface["agent_icon_size"], "24")
    XCTAssertEqual(config.diagnostics.count, 1)
    XCTAssertFalse(config.diagnostics[0].contains("cycle"))
    let duplicate = try AppConfiguration.parse(Data("[interface]\nagent_icon_size=20\nagent-icon-size=24".utf8))
    XCTAssertNil(duplicate.interface["agent_icon_size"])
    XCTAssertFalse(duplicate.diagnostics.isEmpty)
  }

  func testIncludeResets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ body: String) throws {
      try Data(("[terminal]\n" + body).utf8).write(to: root.appendingPathComponent(name))
    }
    try write("a.toml", "font_size=12")
    try write("b.toml", "font_size=18")
    try write("config.toml", "config_file=['a.toml','','b.toml','?']")
    var loaded = AppConfiguration.load(from: root.appendingPathComponent("config.toml"))
    XCTAssertTrue(loaded.diagnostics.isEmpty)
    XCTAssertEqual(loaded.options.map(\.value), ["18"])
    // A nested reset ends the pending queue but retains settings already applied.
    try write("config.toml", "config_file=['a.toml','b.toml']")
    try write("a.toml", "config_file=[]\nfont_size=12")
    loaded = AppConfiguration.load(from: root.appendingPathComponent("config.toml"))
    XCTAssertTrue(loaded.diagnostics.isEmpty)
    XCTAssertEqual(loaded.options.map(\.value), ["12"])
    // Like the native loader, a nested reset does not rewind the queue cursor.
    try write("a.toml", "config_file=['','missing.toml','b.toml']\nfont_size=12")
    loaded = AppConfiguration.load(from: root.appendingPathComponent("config.toml"))
    XCTAssertTrue(loaded.diagnostics.isEmpty)
    XCTAssertEqual(loaded.options.map(\.value), ["12", "18"])
  }

  func testPortableDefaultsAndInjectedThemeHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let color: [String: Any] = ["Red Component": 0.0, "Green Component": 0.0,
      "Blue Component": 0.0, "Color Space": "sRGB"]
    try PropertyListSerialization.data(fromPropertyList: ["Background Color": color,
      "Foreground Color": color], format: .xml, options: 0)
      .write(to: root.appendingPathComponent("home.itermcolors"))
    let config = try AppConfiguration.parse(Data("[terminal]\ntheme='~/home.itermcolors'".utf8), home: root)
    var diagnostics: [String] = []
    let colors = try TerminalTheme.options(for: config, dark: true) { diagnostics.append($0) }
    XCTAssertTrue(diagnostics.isEmpty)
    XCTAssertEqual(colors.first { $0.key == "background" }?.value, "#000000")
    let template = try ConfigurationTemplate.render { "\($0) = \n" }
    XCTAssertTrue(template.contains("# working_directory = \"\""))
    XCTAssertFalse(template.contains(FileManager.default.homeDirectoryForCurrentUser.path))
  }

  func testBundledThemesAndAppearance() throws {
    for name in TerminalTheme.names {
      let config = try parse("[terminal]\ntheme = '\(name)'")
      let colors = try TerminalTheme.options(for: config, dark: true)
      XCTAssertEqual(colors.filter { $0.key == "palette" }.count, 16, name)
    }
    let defaults = AppConfiguration.defaults()
    XCTAssertNotEqual(
      try TerminalTheme.options(for: defaults, dark: true),
      try TerminalTheme.options(for: defaults, dark: false))
    let config = try parse("[terminal]\nbackground = '#123456'")
    XCTAssertEqual(
      try TerminalTheme.options(for: config, dark: true).filter { $0.key == "background" }.map(
        \.value), ["#123456"])
    var diagnostics: [String] = []
    let fallback = try TerminalTheme.options(
      for: parse("[terminal]\ntheme = 'missing-theme'"), dark: true,
      diagnostic: { diagnostics.append($0) })
    XCTAssertEqual(fallback, try TerminalTheme.options(for: defaults, dark: true))
    XCTAssertTrue(diagnostics.first?.contains("missing-theme") == true)
  }

  func testCustomThemeColorSpacesAndInvalidColors() throws {
    let source = URL(fileURLWithPath: "/tmp/custom.itermcolors")
    let white: [String: Any] = [
      "Red Component": 1.0, "Green Component": 1.0, "Blue Component": 1.0, "Color Space": "sRGB",
    ]
    let orange: [String: Any] = [
      "Red Component": 1.0, "Green Component": 0.5, "Blue Component": 0.0, "Color Space": "P3",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["Background Color": orange, "Foreground Color": white], format: .xml,
      options: 0)
    let options = try TerminalTheme.decode(data, source: source)
    XCTAssertEqual(options.first { $0.key == "foreground" }?.value, "#ffffff")
    XCTAssertNotEqual(options.first { $0.key == "background" }?.value, "#ff8000")
    let invalid = try PropertyListSerialization.data(
      fromPropertyList: ["Background Color": ["Red Component": 2.0], "Foreground Color": white],
      format: .xml, options: 0)
    XCTAssertThrowsError(try TerminalTheme.decode(invalid, source: source))
    XCTAssertTrue(TerminalSettings.supported.isDisjoint(with: TerminalSettings.unavailable.keys))
    XCTAssertTrue(TerminalSettings.repeatable.isSubset(of: TerminalSettings.supported))
  }

  func testInvalidThemesUseBundledDefaultsAndKeepOverrides() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let themes = directory.appendingPathComponent("themes")
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A broken custom theme shadowing the default must not break fallback too.
    try Data("broken plist".utf8).write(to: themes.appendingPathComponent("Rose Pine.itermcolors"))
    for selection in ["Rose Pine", "light:Rose Pine Dawn", "dark:,light:Rose Pine Dawn"] {
      var diagnostics: [String] = []
      let config = try AppConfiguration.parse(
        Data("[terminal]\ntheme = '\(selection)'\nbackground = '#123456'".utf8),
        source: directory.appendingPathComponent("config.toml"))
      let colors = try TerminalTheme.options(for: config, dark: true) { diagnostics.append($0) }
      XCTAssertEqual(diagnostics.count, 1)
      XCTAssertEqual(colors.first { $0.key == "background" }?.value, "#123456")
      XCTAssertEqual(colors.filter { $0.key == "palette" }.count, 16)
    }
  }

  func testConfigLocation() {
    let home = URL(fileURLWithPath: "/example")
    XCTAssertEqual(
      AppConfiguration.fileURL(environment: [:], home: home).path,
      "/example/.config/velocitty/config.toml")
    XCTAssertEqual(
      AppConfiguration.fileURL(environment: ["XDG_CONFIG_HOME": "/custom"], home: home).path,
      "/custom/velocitty/config.toml")
    XCTAssertEqual(
      AppConfiguration.fileURL(environment: ["XDG_CONFIG_HOME": "relative"], home: home).path,
      "/example/.config/velocitty/config.toml")
  }

  func testNativeValuesAndRepeatedOptions() throws {
    let config = try parse(
      """
      [terminal]
      font_family = ["Menlo", "Monaco"]
      font_size = 14.5
      cursor_style_blink = false
      palette = ["0=#112233", "1=#445566"]
      env = ["FOO=a=b", "BAR=line one\\nline two"]
      font_feature = ["-calt", "-liga"]
      keybind = ["ctrl+a=text:hello", "ctrl+b=text:world"]
      scrollback_limit_bytes = 50_000_000
      """)
    XCTAssertEqual(
      config.options.filter { $0.key == "font-family" }.map(\.value), ["Menlo", "Monaco"])
    XCTAssertEqual(config.options.first { $0.key == "font-size" }?.value, "14.5")
    XCTAssertEqual(config.options.first { $0.key == "cursor-style-blink" }?.value, "false")
    XCTAssertEqual(
      config.options.filter { $0.key == "env" }.map(\.value), ["FOO=a=b", "BAR=line one\nline two"])
    XCTAssertEqual(config.options.first { $0.key == "scrollback-limit-bytes" }?.value, "50000000")
  }

  func testAliasesAndReset() throws {
    XCTAssertEqual(
      try parse("[terminal]\nfont-size = 14").options,
      try parse("[terminal]\nfont_size = 14").options)
    let duplicate = try parse("[terminal]\nfont-size = 14\nfont_size = 15")
    XCTAssertTrue(duplicate.options.isEmpty)
    XCTAssertTrue(duplicate.diagnostics.allSatisfy { $0.contains("Duplicate setting aliases") })
    XCTAssertEqual(duplicate.diagnostics.count, 2)
    XCTAssertEqual(try parse("[terminal]\nfont_family = []").options.first?.value, "")
    XCTAssertEqual(try parse("[terminal]\nfont_size = ''").options.first?.value, "")
  }

  func testDirectoryValues() throws {
    let home = FileManager.default.temporaryDirectory.standardizedFileURL
    for value in ["~", "home", home.path] {
      XCTAssertEqual(
        try AppConfiguration.parse(
          Data("[terminal]\nworking_directory = '\(value)'".utf8), home: home
        ).workingDirectory, home)
    }
    XCTAssertEqual(
      try parse("[terminal]\nworking_directory = 'inherit'").workingDirectory.path,
      FileManager.default.currentDirectoryPath)
  }

  func testSkipsInvalidValues() throws {
    for source in [
      "unknown = true", "[terminal]\nfont_siz = 14", "[terminal]\nfont_size = [14]",
      "[terminal]\nfont_size = nan", "[terminal]\nfont_size = inf",
      "[terminal]\nfont_family = { name = 'Menlo' }", "[terminal]\nfont_family = [['Menlo']]",
      "[terminal]\nworking_directory = 'relative'",
      "[terminal]\nworking_directory = '/nonexistent-velocitty-test-directory'",
      "[terminal]\nenv = ['BAD=\\u0000']".replacingOccurrences(of: "'", with: "\""),
      "[terminal]\nfont_size = 2026-09-06",
    ] {
      let config = try parse(source)
      XCTAssertTrue(config.options.isEmpty, source)
      XCTAssertFalse(config.diagnostics.isEmpty, source)
    }
  }

  func testMalformedDocumentsFallBackWhenLoaded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    for source in ["[terminal]\nfont_size = 12\nfont_size = 14", "[terminal", "terminal = 1"] {
      XCTAssertThrowsError(try parse(source), source)
      try Data(source.utf8).write(to: file)
      let config = AppConfiguration.load(from: file, home: directory)
      XCTAssertTrue(config.options.isEmpty)
      XCTAssertEqual(config.workingDirectory, directory)
      XCTAssertTrue(config.diagnostics.first?.hasPrefix(file.path) == true)
    }
  }

  func testValidNeighborsSurviveInvalidValues() throws {
    let config = try parse(
      """
      unknown = true
      [terminal]
      font_size = { invalid = 12 }
      font_family = ["Menlo", ["invalid"], 2026-09-06, "Monaco"]
      background_opacity = 0.5
      working_directory = "relative"
      """)
    XCTAssertEqual(
      config.options.filter { $0.key == "font-family" }.map(\.value), ["Menlo", "Monaco"])
    XCTAssertEqual(config.options.first { $0.key == "background-opacity" }?.value, "0.5")
    XCTAssertEqual(config.diagnostics.count, 5)
    XCTAssertEqual(config.workingDirectory, AppConfiguration.defaults().workingDirectory)
  }

  func testUnavailableOptionsExplainMissingBehavior() throws {
    for (key, reason) in TerminalSettings.unavailable {
      let config = try parse("[terminal]\n\(key) = ''")
      XCTAssertTrue(config.options.isEmpty, key)
      if TerminalSettings.otherPlatformKeys.contains(key) {
        XCTAssertTrue(config.diagnostics.isEmpty, key)
      } else {
        XCTAssertTrue(config.diagnostics.first?.contains(reason) == true, key)
      }
    }
    XCTAssertNoThrow(try parse("[terminal]\nclipboard_write = 'ask'"))
  }

  func testErrorsIdentifyKeyAndFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".toml")
    try Data("[terminal]\nfont_siz = 12".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let config = AppConfiguration.load(from: file)
    XCTAssertTrue(config.diagnostics.first?.contains(file.path) == true)
    XCTAssertTrue(config.diagnostics.first?.contains("terminal.font_siz") == true)
  }
}
