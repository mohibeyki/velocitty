// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest

extension XCTestCase {
  /// A fresh directory that is removed when the current test finishes.
  func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}
