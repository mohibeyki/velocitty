// SPDX-License-Identifier: GPL-3.0
import Foundation

/// Presentation belongs to Velocitty. Leaves reference scoped herdr terminal IDs.
public indirect enum PaneLayout: Codable, Equatable, Sendable {
  case terminal(String)
  case split(direction: String, ratio: Double, first: PaneLayout, second: PaneLayout)

  public var terminals: [String] {
    switch self {
    case .terminal(let id): return [id]
    case .split(_, _, let first, let second): return first.terminals + second.terminals
    }
  }
  public func validated(depth: Int = 0) -> Bool {
    guard depth < 64 else { return false }
    switch self {
    case .terminal(let id): return !id.isEmpty
    case .split(let direction, let ratio, let first, let second):
      return ["right", "down"].contains(direction) && ratio.isFinite && (0.1...0.9).contains(ratio)
        && first.validated(depth: depth + 1) && second.validated(depth: depth + 1)
        && Set(terminals).count == terminals.count
    }
  }
  public func retaining(_ ids: Set<String>) -> PaneLayout? {
    switch self {
    case .terminal(let id): return ids.contains(id) ? self : nil
    case .split(let direction, let ratio, let first, let second):
      let a = first.retaining(ids), b = second.retaining(ids)
      if let a, let b { return .split(direction: direction, ratio: ratio, first: a, second: b) }
      return a ?? b
    }
  }
  public func inserting(_ id: String, beside target: String, direction: String) -> PaneLayout {
    switch self {
    case .terminal(let current):
      guard current == target else { return self }
      let before = direction == "left" || direction == "up"
      return .split(direction: ["left", "right"].contains(direction) ? "right" : "down", ratio: 0.5,
        first: before ? .terminal(id) : self, second: before ? self : .terminal(id))
    case .split(let axis, let ratio, let first, let second):
      return .split(direction: axis, ratio: ratio, first: first.inserting(id, beside: target, direction: direction), second: second.inserting(id, beside: target, direction: direction))
    }
  }
  public func settingRatio(path: [Bool], ratio: Double) -> PaneLayout {
    guard case .split(let direction, let old, let first, let second) = self else { return self }
    guard let side = path.first else { return .split(direction: direction, ratio: max(0.1, min(0.9, ratio)), first: first, second: second) }
    return .split(direction: direction, ratio: old,
      first: side ? first : first.settingRatio(path: Array(path.dropFirst()), ratio: ratio),
      second: side ? second.settingRatio(path: Array(path.dropFirst()), ratio: ratio) : second)
  }
  public func equalized() -> PaneLayout {
    guard case .split(let direction, _, let first, let second) = self else { return self }
    func weight(_ node: PaneLayout) -> Double {
      if case .split(let axis, _, let a, let b) = node, axis == direction { return weight(a) + weight(b) }
      return 1
    }
    return .split(direction: direction, ratio: max(0.1, min(0.9, weight(first) / (weight(first) + weight(second)))), first: first.equalized(), second: second.equalized())
  }
  public func resized(terminal: String, direction: String, amount: Double) -> PaneLayout {
    guard case .split(let axis, let ratio, let first, let second) = self else { return self }
    let inFirst = first.terminals.contains(terminal)
    let child = inFirst ? first : second
    let changed = child.resized(terminal: terminal, direction: direction, amount: amount)
    if changed != child {
      return .split(direction: axis, ratio: ratio, first: inFirst ? changed : first, second: inFirst ? second : changed)
    }
    guard terminals.contains(terminal), axis == (["left", "right"].contains(direction) ? "right" : "down") else { return self }
    return settingRatio(path: [], ratio: ratio + (["left", "up"].contains(direction) ? -amount : amount))
  }
}
