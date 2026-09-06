// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class AppConfigurationTests: XCTestCase {
    func parse(_ text: String) throws -> AppConfiguration { try AppConfiguration.parse(Data(text.utf8)) }

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
        XCTAssertEqual(try AppConfiguration.load(from: source, home: home), defaults)
        XCTAssertEqual(try AppConfiguration.parse(Data(), home: home, source: source), defaults)
    }

    func testIncludesPrecedenceAndCycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("config.toml")
        let child = root.appendingPathComponent("colors.toml")
        try Data("[terminal]\nfont_size = 18\nforeground = '#ffffff'".utf8).write(to: child)
        try Data("[terminal]\nconfig_file = ['colors.toml', '?absent.toml']\nfont_size = 14".utf8).write(to: parent)
        let config = try AppConfiguration.load(from: parent)
        XCTAssertEqual(config.options.first { $0.key == "font-size" }?.value, "14")
        XCTAssertEqual(config.options.first { $0.key == "foreground" }?.source, child)
        XCTAssertFalse(config.options.contains { $0.key == "config-file" })
        try Data("[terminal]\nconfig_file = 'config.toml'".utf8).write(to: child)
        XCTAssertThrowsError(try AppConfiguration.load(from: parent)) { XCTAssertTrue($0.localizedDescription.contains("cycle")) }
        try Data("[terminal]\nconfig_file = 'absent.toml'".utf8).write(to: parent)
        XCTAssertThrowsError(try AppConfiguration.load(from: parent))
    }

    func testBundledThemesAndAppearance() throws {
        for name in TerminalTheme.names {
            let config = try parse("[terminal]\ntheme = '\(name)'")
            let colors = try TerminalTheme.options(for: config, dark: true)
            XCTAssertEqual(colors.filter { $0.key == "palette" }.count, 16, name)
        }
        let defaults = AppConfiguration.defaults()
        XCTAssertNotEqual(try TerminalTheme.options(for: defaults, dark: true), try TerminalTheme.options(for: defaults, dark: false))
        let config = try parse("[terminal]\nbackground = '#123456'")
        XCTAssertEqual(try TerminalTheme.options(for: config, dark: true).filter { $0.key == "background" }.map(\.value), ["#123456"])
        XCTAssertThrowsError(try TerminalTheme.options(for: parse("[terminal]\ntheme = 'missing-theme'"), dark: true))
    }

    func testConfigLocation() {
        let home = URL(fileURLWithPath: "/example")
        XCTAssertEqual(AppConfiguration.fileURL(environment: [:], home: home).path, "/example/.config/velocitty/config.toml")
        XCTAssertEqual(AppConfiguration.fileURL(environment: ["XDG_CONFIG_HOME": "/custom"], home: home).path, "/custom/velocitty/config.toml")
        XCTAssertEqual(AppConfiguration.fileURL(environment: ["XDG_CONFIG_HOME": "relative"], home: home).path, "/example/.config/velocitty/config.toml")
    }

    func testNativeValuesAndRepeatedOptions() throws {
        let config = try parse("""
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
        XCTAssertEqual(config.options.filter { $0.key == "font-family" }.map(\.value), ["Menlo", "Monaco"])
        XCTAssertEqual(config.options.first { $0.key == "font-size" }?.value, "14.5")
        XCTAssertEqual(config.options.first { $0.key == "cursor-style-blink" }?.value, "false")
        XCTAssertEqual(config.options.filter { $0.key == "env" }.map(\.value), ["FOO=a=b", "BAR=line one\nline two"])
        XCTAssertEqual(config.options.first { $0.key == "scrollback-limit-bytes" }?.value, "50000000")
    }

    func testAliasesAndReset() throws {
        XCTAssertEqual(try parse("[terminal]\nfont-size = 14").options, try parse("[terminal]\nfont_size = 14").options)
        XCTAssertThrowsError(try parse("[terminal]\nfont-size = 14\nfont_size = 15"))
        XCTAssertEqual(try parse("[terminal]\nfont_family = []").options.first?.value, "")
        XCTAssertEqual(try parse("[terminal]\nfont_size = ''").options.first?.value, "")
    }

    func testDirectoryValues() throws {
        let home = FileManager.default.temporaryDirectory.standardizedFileURL
        for value in ["~", "home", home.path] {
            XCTAssertEqual(try AppConfiguration.parse(Data("[terminal]\nworking_directory = '\(value)'".utf8), home: home).workingDirectory, home)
        }
        XCTAssertEqual(try parse("[terminal]\nworking_directory = 'inherit'").workingDirectory.path, FileManager.default.currentDirectoryPath)
    }

    func testRejectsInvalidDocuments() {
        for source in [
            "unknown = true", "[terminal]\nfont_siz = 14", "[terminal]\nfont_size = [14]",
            "[terminal]\nfont_size = nan", "[terminal]\nfont_size = inf",
            "[terminal]\nfont_family = { name = 'Menlo' }", "[terminal]\nfont_family = [['Menlo']]",
            "[terminal]\nworking_directory = 'relative'", "[terminal]\nworking_directory = '/nonexistent-velocitty-test-directory'",
            "[terminal]\nfont_size = 12\nfont_size = 14", "[terminal", "terminal = 1",
            "[terminal]\nenv = ['BAD=\\u0000']".replacingOccurrences(of: "'", with: "\""),
            "[terminal]\nfont_size = 2026-09-06"
        ] { XCTAssertThrowsError(try parse(source), source) }
    }

    func testUnavailableOptionsExplainMissingBehavior() {
        for (key, reason) in TerminalSettings.unavailable {
            XCTAssertThrowsError(try parse("[terminal]\n\(key) = ''"), key) {
                XCTAssertTrue($0.localizedDescription.contains(reason), key)
            }
        }
        XCTAssertThrowsError(try parse("[terminal]\nclipboard_write = 'ask'"))
    }

    func testErrorsIdentifyKeyAndFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try Data("[terminal]\nfont_siz = 12".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try AppConfiguration.load(from: file)) {
            XCTAssertTrue($0.localizedDescription.contains(file.path))
            XCTAssertTrue($0.localizedDescription.contains("terminal.font_siz"))
        }
    }
}
