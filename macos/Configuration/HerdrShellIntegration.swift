// SPDX-License-Identifier: GPL-3.0
import Foundation
import TOMLDecoder

/// Environment-only startup hooks for shells created by herdr. The bundled
/// Ghostty scripts restore startup paths and guard against duplicate injection.
public enum HerdrShellIntegration {
  public static func environment(settings: AppConfiguration, resources: URL, shell: String,
    inherited: [String: String]) -> [String: String] {
    let mode = settings.options.last { $0.key == "shell-integration" }?.value ?? "detect"
    guard mode != "none" else { return [:] }
    let name = mode == "detect" ? URL(fileURLWithPath: shell).lastPathComponent : mode
    var features: Set<String> = ["cursor", "title", "path"]
    for option in settings.options where option.key == "shell-integration-features" {
      for field in option.value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        if field == "false" { features = []; continue }
        if field == "true" { features = ["cursor", "title", "path", "sudo", "ssh-env", "ssh-terminfo"]; continue }
        if field.hasPrefix("no-") { features.remove(String(field.dropFirst(3))) } else { features.insert(field) }
      }
    }
    if features.remove("cursor") != nil {
      features.insert(settings.options.last { $0.key == "cursor-style-blink" }?.value == "false" ? "cursor:steady" : "cursor:blink")
    }
    let integration = resources.appendingPathComponent("shell-integration")
    var env = ["GHOSTTY_RESOURCES_DIR": resources.path, "GHOSTTY_SHELL_FEATURES": features.sorted().joined(separator: ",")]
    switch name {
    case "fish", "elvish", "nu", "nushell":
      let paths = (inherited["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init).filter { $0 != integration.path }
      env["XDG_DATA_DIRS"] = ([integration.path] + paths).joined(separator: ":")
      env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration.path
    case "zsh":
      env["ZDOTDIR"] = integration.appendingPathComponent("zsh").path
      if let original = inherited["GHOSTTY_ZSH_ZDOTDIR"] ?? inherited["ZDOTDIR"], original != env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = original }
    case "bash":
      // Like Ghostty, don't inject into macOS's unsupported Bash 3.2.
      guard shell != "/bin/bash" else { return [:] }
      env["ENV"] = integration.appendingPathComponent("bash/ghostty.bash").path
      env["GHOSTTY_BASH_INJECT"] = "1"
      env["SHELLOPTS"] = [inherited["SHELLOPTS"], "posix"].compactMap { $0 }.joined(separator: ":")
      if let original = inherited["ENV"] { env["GHOSTTY_BASH_ENV"] = original }
    default: return [:]
    }
    return env
  }

  public static func configuredShell(from url: URL, fallback: String) -> String {
    struct Terminal: Decodable { var default_shell: String? }
    struct Config: Decodable { var terminal: Terminal? }
    guard let data = try? Data(contentsOf: url), let config = try? TOMLDecoder().decode(Config.self, from: data),
      let shell = config.terminal?.default_shell?.trimmingCharacters(in: .whitespacesAndNewlines), !shell.isEmpty else { return fallback }
    return shell
  }
}
