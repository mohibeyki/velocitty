// SPDX-License-Identifier: GPL-3.0
import Foundation
import XCTest
@testable import VelocittyConfiguration

final class PaneLayoutTests: XCTestCase {
  private func split(_ direction: String, _ ratio: Double = 0.5, _ first: PaneLayout, _ second: PaneLayout) -> PaneLayout {
    .split(direction: direction, ratio: ratio, first: first, second: second)
  }
  private let a = PaneLayout.terminal("a"), b = PaneLayout.terminal("b"), c = PaneLayout.terminal("c")

  func testRetainingCollapsesRemovedLeaves() {
    let tree = split("right", 0.3, a, split("down", 0.6, b, c))
    XCTAssertEqual(tree.retaining(["a", "b", "c"]), tree)
    XCTAssertEqual(tree.retaining(["a", "c"]), split("right", 0.3, a, c))
    XCTAssertEqual(tree.retaining(["b"]), b)
    XCTAssertNil(tree.retaining(["gone"]))
  }

  func testEqualizedWeightsSameAxisRuns() {
    XCTAssertEqual(a.equalized(), a)
    // Three panes in one row each get a third of it.
    let row = split("right", 0.9, a, split("right", 0.1, b, c))
    XCTAssertEqual(row.equalized(), split("right", 1.0 / 3, a, split("right", 0.5, b, c)))
    // A perpendicular split counts as one pane.
    let mixed = split("right", 0.5, split("down", 0.2, a, b), c)
    XCTAssertEqual(mixed.equalized(), split("right", 0.5, split("down", 0.5, a, b), c))
  }

  func testResizedMovesTheNearestMatchingDivider() {
    let tree = split("right", 0.5, a, split("down", 0.5, b, c))
    XCTAssertEqual(tree.resized(terminal: "a", direction: "right", amount: 0.1), split("right", 0.6, a, split("down", 0.5, b, c)))
    XCTAssertEqual(tree.resized(terminal: "a", direction: "left", amount: 0.1), split("right", 0.4, a, split("down", 0.5, b, c)))
    // Recurses into the child holding the terminal.
    XCTAssertEqual(tree.resized(terminal: "c", direction: "down", amount: 0.2), split("right", 0.5, a, split("down", 0.7, b, c)))
    // No divider on that axis around the terminal: unchanged.
    XCTAssertEqual(tree.resized(terminal: "a", direction: "down", amount: 0.1), tree)
    // Falls back to the outer divider when the inner one is on another axis.
    XCTAssertEqual(tree.resized(terminal: "b", direction: "right", amount: 0.1), split("right", 0.6, a, split("down", 0.5, b, c)))
    XCTAssertEqual(tree.resized(terminal: "missing", direction: "right", amount: 0.1), tree)
    // The ratio stays within bounds.
    XCTAssertEqual(tree.resized(terminal: "a", direction: "right", amount: 5), split("right", 0.9, a, split("down", 0.5, b, c)))
  }

  func testSettingRatioFollowsPathAndClamps() {
    let tree = split("right", 0.5, split("down", 0.5, a, b), split("down", 0.5, c, .terminal("d")))
    XCTAssertEqual(tree.settingRatio(path: [], ratio: 0.2), split("right", 0.2, split("down", 0.5, a, b), split("down", 0.5, c, .terminal("d"))))
    XCTAssertEqual(tree.settingRatio(path: [false], ratio: 0.7), split("right", 0.5, split("down", 0.7, a, b), split("down", 0.5, c, .terminal("d"))))
    XCTAssertEqual(tree.settingRatio(path: [true], ratio: 0.05), split("right", 0.5, split("down", 0.5, a, b), split("down", 0.1, c, .terminal("d"))))
    XCTAssertEqual(tree.settingRatio(path: [false, true, true], ratio: 0.3).terminals, tree.terminals)
    XCTAssertEqual(a.settingRatio(path: [true], ratio: 0.3), a)
  }

  func testInsertingPlacesNewTerminalBesideTarget() {
    XCTAssertEqual(a.inserting("n", beside: "a", direction: "right"), split("right", 0.5, a, .terminal("n")))
    XCTAssertEqual(a.inserting("n", beside: "a", direction: "left"), split("right", 0.5, .terminal("n"), a))
    XCTAssertEqual(a.inserting("n", beside: "a", direction: "down"), split("down", 0.5, a, .terminal("n")))
    XCTAssertEqual(a.inserting("n", beside: "a", direction: "up"), split("down", 0.5, .terminal("n"), a))
    let tree = split("right", 0.4, a, b)
    XCTAssertEqual(tree.inserting("n", beside: "b", direction: "down"), split("right", 0.4, a, split("down", 0.5, b, .terminal("n"))))
    XCTAssertEqual(tree.inserting("n", beside: "missing", direction: "down"), tree)
  }
}
