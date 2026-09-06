// SPDX-License-Identifier: GPL-3.0
import Foundation

public enum ShellInput {
    // Quote each path as a single shell argument, without appending Enter.
    public static func paths(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " "
    }
}
