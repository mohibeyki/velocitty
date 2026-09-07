// SPDX-License-Identifier: GPL-3.0
import AppKit
import UniformTypeIdentifiers
import VelocittyConfiguration

// Editor selection follows the upstream macOS opener. See VeloKit/THIRD_PARTY_NOTICES.md.
struct ConfigurationEditor {
  var applicationForType: (String) -> URL? = { type in
    LSCopyDefaultApplicationURLForContentType(type as CFString, .all, nil)?
      .takeRetainedValue() as? URL
  }
  var openFile: (URL, URL?, @escaping (Error?) -> Void) -> Void = { file, editor, completion in
    if let editor {
      NSWorkspace.shared.open([file], withApplicationAt: editor,
        configuration: NSWorkspace.OpenConfiguration()) { _, error in completion(error) }
    } else {
      completion(NSWorkspace.shared.open(file) ? nil : ConfigurationError("macOS could not open \(file.path)."))
    }
  }

  func open(_ file: URL, completion: @escaping (Error?) -> Void) {
    do {
      if !FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        do {
          try Data("# Velocitty configuration. Empty settings use defaults.\n[terminal]\n".utf8)
            .write(to: file, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          // Another writer created the file; open it without overwriting it.
        }
      }
      let associated = UTType(filenameExtension: file.pathExtension)
        .flatMap { applicationForType($0.identifier) }
      let editor = associated ?? applicationForType(UTType.plainText.identifier)
      openFile(file, editor, completion)
    } catch { completion(error) }
  }
}
