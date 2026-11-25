// SPDX-License-Identifier: GPL-3.0
import AppKit
import Carbon
import Foundation
import VeloKit
import VelocittyConfiguration

final class GlobalShortcuts {
  var handler: EventHandlerRef?
  var registrations: [EventHotKeyRef] = []
  var events: [UInt32: ghostty_input_key_s] = [:]
  weak var owner: AppDelegate?

  init(owner: AppDelegate) {
    self.owner = owner
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, data in
        guard let event, let data else { return OSStatus(eventNotHandledErr) }
        let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(data).takeUnretainedValue()
        var id = EventHotKeyID()
        guard
          GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
          let key = shortcuts.events[id.id], let app = shortcuts.owner?.runtime?.app
        else { return OSStatus(eventNotHandledErr) }
        return velokit_app_key(app, key) ? noErr : OSStatus(eventNotHandledErr)
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  func reload() {
    registrations.forEach { UnregisterEventHotKey($0) }
    registrations.removeAll()
    events.removeAll()
    guard let config = owner?.runtime?.config else { return }
    var index: UInt = 0
    var trigger = ghostty_input_trigger_s()
    while velokit_config_global_trigger(config, index, &trigger) {
      defer { index += 1 }
      var code = UInt32.max
      if trigger.tag == GHOSTTY_TRIGGER_PHYSICAL {
        code = velokit_keycode_for_key(trigger.key.physical)
      } else if trigger.tag == GHOSTTY_TRIGGER_UNICODE {
        code = Self.keycode(for: trigger.key.unicode) ?? UInt32.max
      }
      guard code < 128 else {
        NSLog("Global shortcut %lu cannot be represented by this keyboard layout", index)
        continue
      }
      let raw = trigger.mods.rawValue
      var mods: UInt32 = 0
      if raw & GHOSTTY_MODS_SHIFT.rawValue != 0 { mods |= UInt32(shiftKey) }
      if raw & GHOSTTY_MODS_CTRL.rawValue != 0 { mods |= UInt32(controlKey) }
      if raw & GHOSTTY_MODS_ALT.rawValue != 0 { mods |= UInt32(optionKey) }
      if raw & GHOSTTY_MODS_SUPER.rawValue != 0 { mods |= UInt32(cmdKey) }
      let id = UInt32(index + 1)
      var reference: EventHotKeyRef?
      let status = RegisterEventHotKey(
        code, mods, EventHotKeyID(signature: 0x5645_4C4F, id: id), GetApplicationEventTarget(), 0,
        &reference)
      guard status == noErr, let reference else {
        NSLog("Global shortcut %u could not be registered (%d)", id, status)
        continue
      }
      registrations.append(reference)
      var event = ghostty_input_key_s()
      event.action = GHOSTTY_ACTION_PRESS
      event.keycode = code
      event.mods = trigger.mods
      event.unshifted_codepoint = trigger.tag == GHOSTTY_TRIGGER_UNICODE ? trigger.key.unicode : 0
      events[id] = event
    }
  }

  /// The key label and modifiers bound to an action, or nil when it has no binding.
  /// The label is empty when the active keyboard layout cannot represent the key.
  static func resolvedShortcut(action: String, config: ghostty_config_t) -> (key: String, mods: ghostty_input_mods_e)? {
    var trigger = ghostty_input_trigger_s()
    guard action.withCString({ velokit_config_trigger(config, $0, &trigger) }) else { return nil }
    let key: String
    if trigger.tag == GHOSTTY_TRIGGER_UNICODE, let scalar = UnicodeScalar(trigger.key.unicode) {
      key = String(scalar)
    } else if trigger.tag == GHOSTTY_TRIGGER_PHYSICAL {
      // Labels use the active keyboard layout, not US-only key labels.
      key = character(for: velokit_keycode_for_key(trigger.key.physical)) ?? ""
    } else { key = "" }
    return (key, trigger.mods)
  }

  static func character(for code: UInt32) -> String? {
    guard code < 128 else { return nil }
    return withCurrentKeyLayout { layout in
      translate(UInt16(code), layout: layout).map { String(utf16CodeUnits: $0, count: $0.count) }
    }
  }

  static func keycode(for scalar: UInt32) -> UInt32? {
    withCurrentKeyLayout { layout in
      (UInt16(0)..<128).first { key in
        guard let chars = translate(key, layout: layout) else { return false }
        return chars.count == 1 && UInt32(chars[0]) == scalar
      }.map(UInt32.init)
    }
  }

  /// Runs body with the current keyboard layout, which is valid only for the duration of the call.
  private static func withCurrentKeyLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T?) -> T? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(
      to: UCKeyboardLayout.self)
    return withExtendedLifetime(source) { body(layout) }
  }

  /// The UTF-16 units an unmodified key press produces, or nil when it produces none.
  private static func translate(_ code: UInt16, layout: UnsafePointer<UCKeyboardLayout>) -> [UniChar]? {
    var dead: UInt32 = 0
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    guard
      UCKeyTranslate(
        layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr, length > 0
    else { return nil }
    return Array(chars.prefix(length))
  }

  deinit {
    registrations.forEach { UnregisterEventHotKey($0) }
    if let handler { RemoveEventHandler(handler) }
  }
}
