// SPDX-License-Identifier: GPL-3.0
import Foundation

/// Velocitty connection preferences do not change herdr's global machine catalog.
public struct HerdrConnection: Codable, Equatable, Sendable {
  public var id: String
  public var label: String
  public var session: String
  public var target: String?
  public var enabled: Bool
  public init(id: String, label: String, session: String, target: String? = nil, enabled: Bool = true) {
    self.id = id; self.label = label; self.session = session; self.target = target; self.enabled = enabled
  }
  public static let local = HerdrConnection(id: "local", label: "Local", session: "velocitty")
  public func validate() throws {
    guard !id.isEmpty, !id.contains("::"), (id != "local" || (target == nil && session == "velocitty")), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !session.isEmpty, session.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
      target.map({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains(where: { $0.isWhitespace || $0.isNewline }) }) ?? true
    else { throw ConfigurationError("Use a name, a session containing letters, numbers, hyphens or underscores, and an SSH destination such as user@host.") }
  }
}

struct ConnectionDefinition: Decodable {
  let id: String
  let name: String?
  let host: String?
  let session: String?
  let enabled: Bool?

  func connection() throws -> HerdrConnection {
    let value = HerdrConnection(id: id, label: name ?? id, session: session ?? "velocitty", target: host, enabled: enabled ?? true)
    try value.validate()
    return value
  }
}

public extension HerdrConnection {
  static func validateList(_ values: [Self]) throws {
    guard Set(values.map(\.id)).count == values.count,
      Set(values.map { ($0.target ?? "local") + " / " + $0.session }).count == values.count else {
      throw ConfigurationError("Each connection needs a unique id and host/session pair.")
    }
    for value in values { try value.validate() }
  }
}
