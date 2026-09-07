// SPDX-License-Identifier: GPL-3.0
import AppKit
import VeloKit

// OSC 9;4 belongs to a surface. Like upstream, display a thin bar and expire
// stale reports after 15 seconds; windows never compete for a shared Dock tile.
final class TerminalProgress: NSView {
  private let bar = CALayer()
  private var timer: Timer?
  private(set) var report: ghostty_action_progress_report_s?
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(bar)
    isHidden = true
    setAccessibilityElement(true)
    setAccessibilityRole(.progressIndicator)
    setAccessibilityLabel("Terminal progress")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  func clear() {
    timer?.invalidate()
    timer = nil
    report = nil
    bar.removeAllAnimations()
    isHidden = true
  }
  func update(_ value: ghostty_action_progress_report_s) {
    clear()
    guard value.state != GHOSTTY_PROGRESS_STATE_REMOVE else { return }
    report = value
    isHidden = false
    needsLayout = true
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
      self?.clear()
    }
  }
  override func layout() {
    super.layout()
    guard let report else { return }
    let indeterminate = report.state == GHOSTTY_PROGRESS_STATE_INDETERMINATE
      || (report.state == GHOSTTY_PROGRESS_STATE_ERROR && report.progress < 0)
    let percent = report.progress < 0 && report.state == GHOSTTY_PROGRESS_STATE_PAUSE
      ? 100 : max(0, min(100, Int(report.progress)))
    let color: NSColor = report.state == GHOSTTY_PROGRESS_STATE_ERROR ? .systemRed
      : report.state == GHOSTTY_PROGRESS_STATE_PAUSE ? .systemOrange : .controlAccentColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bar.backgroundColor = color.cgColor
    bar.frame = NSRect(x: 0, y: 0, width: bounds.width * (indeterminate ? 0.25 : Double(percent) / 100),
      height: bounds.height)
    bar.removeAllAnimations()
    if indeterminate {
      let animation = CABasicAnimation(keyPath: "transform.translation.x")
      animation.fromValue = 0
      animation.toValue = bounds.width * 0.75
      animation.duration = 1
      animation.autoreverses = true
      animation.repeatCount = .infinity
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bar.add(animation, forKey: "progress")
    }
    CATransaction.commit()
    setAccessibilityValue(indeterminate ? "In progress" : "\(percent)%")
  }
  deinit { timer?.invalidate() }
}
