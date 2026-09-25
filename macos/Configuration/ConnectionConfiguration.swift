// SPDX-License-Identifier: GPL-3.0
import Foundation

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
