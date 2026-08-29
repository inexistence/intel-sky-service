import ApplicationServices
import CoreGraphics
import Foundation

enum KeyboardModifier: CaseIterable, Equatable, Hashable, Sendable {
  case command
  case commandRight
  case shift
  case shiftRight
  case option
  case optionRight
  case control
  case controlRight

  var keyCode: CGKeyCode {
    switch self {
    case .command: return 55
    case .commandRight: return 54
    case .shift: return 56
    case .shiftRight: return 60
    case .option: return 58
    case .optionRight: return 61
    case .control: return 59
    case .controlRight: return 62
    }
  }

  var eventFlag: CGEventFlags {
    switch self {
    case .command, .commandRight: return .maskCommand
    case .shift, .shiftRight: return .maskShift
    case .option, .optionRight: return .maskAlternate
    case .control, .controlRight: return .maskControl
    }
  }
}

struct ParsedKeyChord: Equatable, Sendable {
  let keyCode: CGKeyCode
  let modifiers: Set<KeyboardModifier>
}

struct MacKeyChordParser: Sendable {
  private struct KeyMapping: Sendable {
    let keyCode: CGKeyCode
    let requiresShift: Bool
  }

  private static let modifierAliases: [String: KeyboardModifier] = [
    "alt": .option,
    "alt_l": .option,
    "alt_r": .optionRight,
    "cmd": .command,
    "command": .command,
    "control": .control,
    "control_l": .control,
    "control_r": .controlRight,
    "ctrl": .control,
    "meta": .command,
    "meta_l": .command,
    "meta_r": .commandRight,
    "option": .option,
    "shift": .shift,
    "shift_l": .shift,
    "shift_r": .shiftRight,
    "super": .command,
    "super_l": .command,
    "super_r": .commandRight,
  ]

  private static let namedKeys: [String: KeyMapping] = [
    "backspace": .init(keyCode: 51, requiresShift: false),
    "caps_lock": .init(keyCode: 57, requiresShift: false),
    "capslock": .init(keyCode: 57, requiresShift: false),
    "clear": .init(keyCode: 71, requiresShift: false),
    "delete": .init(keyCode: 117, requiresShift: false),
    "down": .init(keyCode: 125, requiresShift: false),
    "end": .init(keyCode: 119, requiresShift: false),
    "esc": .init(keyCode: 53, requiresShift: false),
    "escape": .init(keyCode: 53, requiresShift: false),
    "f1": .init(keyCode: 122, requiresShift: false),
    "f2": .init(keyCode: 120, requiresShift: false),
    "f3": .init(keyCode: 99, requiresShift: false),
    "f4": .init(keyCode: 118, requiresShift: false),
    "f5": .init(keyCode: 96, requiresShift: false),
    "f6": .init(keyCode: 97, requiresShift: false),
    "f7": .init(keyCode: 98, requiresShift: false),
    "f8": .init(keyCode: 100, requiresShift: false),
    "f9": .init(keyCode: 101, requiresShift: false),
    "f10": .init(keyCode: 109, requiresShift: false),
    "f11": .init(keyCode: 103, requiresShift: false),
    "f12": .init(keyCode: 111, requiresShift: false),
    "f13": .init(keyCode: 105, requiresShift: false),
    "f14": .init(keyCode: 107, requiresShift: false),
    "f15": .init(keyCode: 113, requiresShift: false),
    "f16": .init(keyCode: 106, requiresShift: false),
    "f17": .init(keyCode: 64, requiresShift: false),
    "f18": .init(keyCode: 79, requiresShift: false),
    "f19": .init(keyCode: 80, requiresShift: false),
    "f20": .init(keyCode: 90, requiresShift: false),
    "forward_delete": .init(keyCode: 117, requiresShift: false),
    "forwarddelete": .init(keyCode: 117, requiresShift: false),
    "home": .init(keyCode: 115, requiresShift: false),
    "help": .init(keyCode: 114, requiresShift: false),
    "insert": .init(keyCode: 114, requiresShift: false),
    "kp_0": .init(keyCode: 82, requiresShift: false),
    "kp_1": .init(keyCode: 83, requiresShift: false),
    "kp_2": .init(keyCode: 84, requiresShift: false),
    "kp_3": .init(keyCode: 85, requiresShift: false),
    "kp_4": .init(keyCode: 86, requiresShift: false),
    "kp_5": .init(keyCode: 87, requiresShift: false),
    "kp_6": .init(keyCode: 88, requiresShift: false),
    "kp_7": .init(keyCode: 89, requiresShift: false),
    "kp_8": .init(keyCode: 91, requiresShift: false),
    "kp_9": .init(keyCode: 92, requiresShift: false),
    "kp_add": .init(keyCode: 69, requiresShift: false),
    "kp_begin": .init(keyCode: 87, requiresShift: false),
    "kp_decimal": .init(keyCode: 65, requiresShift: false),
    "kp_delete": .init(keyCode: 65, requiresShift: false),
    "kp_divide": .init(keyCode: 75, requiresShift: false),
    "kp_down": .init(keyCode: 84, requiresShift: false),
    "kp_end": .init(keyCode: 83, requiresShift: false),
    "kp_enter": .init(keyCode: 76, requiresShift: false),
    "kp_equal": .init(keyCode: 81, requiresShift: false),
    "kp_f1": .init(keyCode: 122, requiresShift: false),
    "kp_f2": .init(keyCode: 120, requiresShift: false),
    "kp_f3": .init(keyCode: 99, requiresShift: false),
    "kp_f4": .init(keyCode: 118, requiresShift: false),
    "kp_home": .init(keyCode: 89, requiresShift: false),
    "kp_insert": .init(keyCode: 82, requiresShift: false),
    "kp_left": .init(keyCode: 86, requiresShift: false),
    "kp_multiply": .init(keyCode: 67, requiresShift: false),
    "kp_next": .init(keyCode: 85, requiresShift: false),
    "kp_page_down": .init(keyCode: 85, requiresShift: false),
    "kp_page_up": .init(keyCode: 92, requiresShift: false),
    "kp_prior": .init(keyCode: 92, requiresShift: false),
    "kp_right": .init(keyCode: 88, requiresShift: false),
    "kp_separator": .init(keyCode: 95, requiresShift: false),
    "kp_space": .init(keyCode: 49, requiresShift: false),
    "kp_subtract": .init(keyCode: 78, requiresShift: false),
    "kp_tab": .init(keyCode: 48, requiresShift: false),
    "kp_up": .init(keyCode: 91, requiresShift: false),
    "linefeed": .init(keyCode: 36, requiresShift: false),
    "left": .init(keyCode: 123, requiresShift: false),
    "pagedown": .init(keyCode: 121, requiresShift: false),
    "page_down": .init(keyCode: 121, requiresShift: false),
    "pageup": .init(keyCode: 116, requiresShift: false),
    "page_up": .init(keyCode: 116, requiresShift: false),
    "prior": .init(keyCode: 116, requiresShift: false),
    "next": .init(keyCode: 121, requiresShift: false),
    "num_lock": .init(keyCode: 71, requiresShift: false),
    "pause": .init(keyCode: 113, requiresShift: false),
    "break": .init(keyCode: 113, requiresShift: false),
    "print": .init(keyCode: 105, requiresShift: false),
    "scroll_lock": .init(keyCode: 107, requiresShift: false),
    "sys_req": .init(keyCode: 105, requiresShift: false),
    "return": .init(keyCode: 36, requiresShift: false),
    "enter": .init(keyCode: 36, requiresShift: false),
    "right": .init(keyCode: 124, requiresShift: false),
    "space": .init(keyCode: 49, requiresShift: false),
    "tab": .init(keyCode: 48, requiresShift: false),
    "up": .init(keyCode: 126, requiresShift: false),
  ]

  private static let namedCharacters: [String: Character] = [
    "ampersand": "&", "apostrophe": "'", "asciicircum": "^", "asciitilde": "~",
    "asterisk": "*", "at": "@", "backslash": "\\", "bar": "|", "braceleft": "{",
    "braceright": "}", "bracketleft": "[", "bracketright": "]", "colon": ":",
    "comma": ",", "dollar": "$", "equal": "=", "exclam": "!", "grave": "`",
    "greater": ">", "less": "<", "minus": "-", "numbersign": "#", "parenleft": "(",
    "parenright": ")", "percent": "%", "period": ".", "plus": "+", "question": "?",
    "quotedbl": "\"", "semicolon": ";", "slash": "/", "underscore": "_",
  ]

  private static let characterKeys: [Character: KeyMapping] = makeCharacterKeys()

  func parse(_ value: String) throws -> ParsedKeyChord {
    let tokens = value.split(separator: "+", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else {
      throw MacAppActionError.invalidAction("pressKey must be a non-empty key chord")
    }

    var modifiers: Set<KeyboardModifier> = []
    var keyMapping: KeyMapping?
    for token in tokens {
      let normalized = token.lowercased()
      if let modifier = Self.modifierAliases[normalized] {
        modifiers.insert(modifier)
        continue
      }
      guard keyMapping == nil, let mapping = Self.mapping(for: token) else {
        throw MacAppActionError.invalidAction("unsupported or ambiguous key chord: \(value)")
      }
      keyMapping = mapping
    }

    guard let keyMapping else {
      throw MacAppActionError.invalidAction("pressKey requires a non-modifier key")
    }
    if keyMapping.requiresShift { modifiers.insert(.shift) }
    return ParsedKeyChord(keyCode: keyMapping.keyCode, modifiers: modifiers)
  }

  private static func mapping(for token: String) -> KeyMapping? {
    let normalized = token.lowercased()
    if let named = namedKeys[normalized] { return named }
    if normalized.hasPrefix("numpad_"),
      let named = namedKeys["kp_" + normalized.dropFirst("numpad_".count)]
    {
      return named
    }
    if let character = namedCharacters[normalized] { return characterKeys[character] }
    guard token.count == 1, let character = token.first else { return nil }
    return characterKeys[character]
  }

  private static func makeCharacterKeys() -> [Character: KeyMapping] {
    let unshifted: [(String, CGKeyCode)] = [
      ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6),
      ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14),
      ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
      ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
      ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35),
      ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43),
      ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
    ]
    let shifted = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+{}|:\"<>?~"
    let shiftedBases = "abcdefghijklmnopqrstuvwxyz1234567890-=[]\\;',./`"
    var result: [Character: KeyMapping] = [:]
    for (character, keyCode) in unshifted {
      result[Character(character)] = KeyMapping(keyCode: keyCode, requiresShift: false)
    }
    for (shiftedCharacter, baseCharacter) in zip(shifted, shiftedBases) {
      if let base = result[baseCharacter] {
        result[shiftedCharacter] = KeyMapping(keyCode: base.keyCode, requiresShift: true)
      }
    }
    return result
  }
}

protocol KeyboardInputPosting: Sendable {
  func press(_ chord: ParsedKeyChord, target: ComputerUseEventTarget) throws
  func typeText(_ text: String, target: ComputerUseEventTarget) throws
}

struct CGKeyboardInputPoster: KeyboardInputPosting {
  func press(_ chord: ParsedKeyChord, target: ComputerUseEventTarget) throws {
    try requireAccessibilityPermission()
    let orderedModifiers = KeyboardModifier.allCases.filter(chord.modifiers.contains)
    var flags: CGEventFlags = []
    var events: [CGEvent] = []
    for modifier in orderedModifiers {
      flags.insert(modifier.eventFlag)
      events.append(try makeKeyEvent(keyCode: modifier.keyCode, isDown: true, flags: flags))
    }
    events.append(try makeKeyEvent(keyCode: chord.keyCode, isDown: true, flags: flags))
    events.append(try makeKeyEvent(keyCode: chord.keyCode, isDown: false, flags: flags))
    for modifier in orderedModifiers.reversed() {
      flags.remove(modifier.eventFlag)
      events.append(try makeKeyEvent(keyCode: modifier.keyCode, isDown: false, flags: flags))
    }
    try RequestDeadlineContext.check()
    try UserInterventionContext.check()
    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      for event in events { ProcessTargetedEventPoster.postKeyboard(event, to: target) }
    }
  }

  func typeText(_ text: String, target: ComputerUseEventTarget) throws {
    try requireAccessibilityPermission()
    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      for chunk in Self.utf16Chunks(for: text) {
        try RequestDeadlineContext.check()
        try UserInterventionContext.check()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
          throw MacAppActionError.eventCreationFailed
        }
        chunk.withUnsafeBufferPointer { buffer in
          down.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
          )
          up.keyboardSetUnicodeString(
            stringLength: buffer.count,
            unicodeString: buffer.baseAddress
          )
        }
        ProcessTargetedEventPoster.postKeyboard(down, to: target)
        ProcessTargetedEventPoster.postKeyboard(up, to: target)
      }
    }
  }

  static func utf16Chunks(for text: String, maximumCount: Int = 20) -> [[UInt16]] {
    precondition(maximumCount >= 2)
    let units = Array(text.utf16)
    var result: [[UInt16]] = []
    var start = 0
    while start < units.count {
      var end = min(start + maximumCount, units.count)
      if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
        end -= 1
      }
      result.append(Array(units[start..<end]))
      start = end
    }
    return result
  }

  private func requireAccessibilityPermission() throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
  }

  private func makeKeyEvent(keyCode: CGKeyCode, isDown: Bool, flags: CGEventFlags) throws
    -> CGEvent
  {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown)
    else {
      throw MacAppActionError.eventCreationFailed
    }
    event.flags = flags
    return event
  }
}
