import ApplicationServices
import Foundation

enum TextSelectionKind: String, Sendable {
  case text
  case cursorBefore = "cursor_before"
  case cursorAfter = "cursor_after"
}

enum MacAccessibilityActionError: Error, CustomStringConvertible {
  case attributeNotSettable(String)
  case actionNotAvailable(String)
  case operationFailed(String, AXError)
  case valueIsNotText
  case textNotFound
  case ambiguousText
  case invalidSelection(String)

  var description: String {
    switch self {
    case .attributeNotSettable(let attribute):
      return "Accessibility attribute is not settable: \(attribute)"
    case .actionNotAvailable(let action):
      return "Accessibility action is not available on the element: \(action)"
    case .operationFailed(let operation, let error):
      return "Accessibility operation \(operation) failed with AX error \(error.rawValue)"
    case .valueIsNotText:
      return "Accessibility element value is not text"
    case .textNotFound:
      return "Requested text was not found in the Accessibility element"
    case .ambiguousText:
      return "Requested text matches more than once; provide prefix or suffix"
    case .invalidSelection(let selection):
      return "Unsupported text selection type: \(selection)"
    }
  }
}

protocol AccessibilityActionPerforming: Sendable {
  func setValue(_ value: String, on element: AXUIElement) throws
  func performSecondaryAction(_ action: String, on element: AXUIElement) throws
  func selectText(
    _ text: String,
    prefix: String?,
    suffix: String?,
    selection: TextSelectionKind,
    on element: AXUIElement
  ) throws
}

protocol AccessibilityPrimaryClicking: Sendable {
  func click(element: AXUIElement) throws -> Bool
}

struct MacAccessibilityPrimaryClicker: AccessibilityPrimaryClicking {
  func click(element: AXUIElement) throws -> Bool {
    try RequestDeadlineContext.check()
    try UserInterventionContext.check()
    let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
    var rawActions: CFArray?
    let copyResult = AXUIElementCopyActionNames(element, &rawActions)
    let actions = copyResult == .success ? (rawActions as? [String]) ?? [] : []
    guard actions.contains(kAXPressAction as String) else {
      if role == (kAXMenuItemRole as String) {
        throw MacAccessibilityActionError.actionNotAvailable(kAXPressAction as String)
      }
      return try selectElementOrAncestor(element)
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
      throw MacAccessibilityActionError.operationFailed(kAXPressAction as String, result)
    }
    return true
  }

  private func selectElementOrAncestor(_ element: AXUIElement) throws -> Bool {
    var candidate: AXUIElement? = element
    for _ in 0..<8 {
      guard let current = candidate else { return false }
      var settable = DarwinBoolean(false)
      let query = AXUIElementIsAttributeSettable(
        current,
        kAXSelectedAttribute as CFString,
        &settable
      )
      if query == .success, settable.boolValue {
        let result = AXUIElementSetAttributeValue(
          current,
          kAXSelectedAttribute as CFString,
          kCFBooleanTrue
        )
        guard result == .success else {
          throw MacAccessibilityActionError.operationFailed("select", result)
        }
        return true
      }
      candidate = parent(of: current)
    }
    return false
  }

  private func parent(of element: AXUIElement) -> AXUIElement? {
    var rawParent: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXParentAttribute as CFString,
        &rawParent
      ) == .success,
      let rawParent,
      CFGetTypeID(rawParent) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(rawParent, to: AXUIElement.self)
  }

  private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
      return nil
    }
    return rawValue as? String
  }
}

struct MacAccessibilityActionPerformer: AccessibilityActionPerforming {
  func setValue(_ value: String, on element: AXUIElement) throws {
    try RequestDeadlineContext.check()
    try UserInterventionContext.check()
    try requireSettable(kAXValueAttribute as CFString, on: element)
    try focusFieldIfNeeded(element)
    let result = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      value as CFString
    )
    guard result == .success else {
      throw MacAccessibilityActionError.operationFailed("setValue", result)
    }
  }

  func performSecondaryAction(_ action: String, on element: AXUIElement) throws {
    try RequestDeadlineContext.check()
    try UserInterventionContext.check()
    var names: CFArray?
    let copyResult = AXUIElementCopyActionNames(element, &names)
    guard copyResult == .success else {
      throw MacAccessibilityActionError.operationFailed("copyActionNames", copyResult)
    }
    let available = (names as? [String]) ?? []
    guard let resolved = resolve(action, among: available, on: element) else {
      throw MacAccessibilityActionError.actionNotAvailable(action)
    }
    let result = AXUIElementPerformAction(element, resolved as CFString)
    guard result == .success else {
      throw MacAccessibilityActionError.operationFailed(resolved, result)
    }
  }

  func selectText(
    _ text: String,
    prefix: String?,
    suffix: String?,
    selection: TextSelectionKind,
    on element: AXUIElement
  ) throws {
    try RequestDeadlineContext.check()
    try UserInterventionContext.check()
    var rawValue: CFTypeRef?
    let copyResult = AXUIElementCopyAttributeValue(
      element,
      kAXValueAttribute as CFString,
      &rawValue
    )
    guard copyResult == .success else {
      throw MacAccessibilityActionError.operationFailed("copyValue", copyResult)
    }
    guard let value = rawValue as? String else {
      throw MacAccessibilityActionError.valueIsNotText
    }
    let match = try TextSelectionResolver.resolve(
      text: text,
      in: value,
      prefix: prefix,
      suffix: suffix
    )
    let selectedRange: CFRange
    switch selection {
    case .text:
      selectedRange = match
    case .cursorBefore:
      selectedRange = CFRange(location: match.location, length: 0)
    case .cursorAfter:
      selectedRange = CFRange(location: match.location + match.length, length: 0)
    }
    guard let rangeValue = AXValueCreate(.cfRange, [selectedRange]) else {
      throw MacAccessibilityActionError.operationFailed("createSelectedTextRange", .failure)
    }
    try requireSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
    try focusFieldIfNeeded(element)
    let setResult = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      rangeValue
    )
    guard setResult == .success else {
      throw MacAccessibilityActionError.operationFailed("selectText", setResult)
    }
  }

  private func requireSettable(_ attribute: CFString, on element: AXUIElement) throws {
    var settable = DarwinBoolean(false)
    let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
    guard result == .success else {
      throw MacAccessibilityActionError.operationFailed("isAttributeSettable", result)
    }
    guard settable.boolValue else {
      throw MacAccessibilityActionError.attributeNotSettable(attribute as String)
    }
  }

  private func focusFieldIfNeeded(_ element: AXUIElement) throws {
    var rawFocused: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      element,
      kAXFocusedAttribute as CFString,
      &rawFocused
    ) == .success,
      (rawFocused as? Bool) == true
    {
      return
    }

    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        element,
        kAXFocusedAttribute as CFString,
        &settable
      ) == .success,
      settable.boolValue
    else {
      return
    }
    let result = AXUIElementSetAttributeValue(
      element,
      kAXFocusedAttribute as CFString,
      kCFBooleanTrue
    )
    guard result == .success else {
      throw MacAccessibilityActionError.operationFailed("focusField", result)
    }
  }

  private func resolve(
    _ requested: String,
    among available: [String],
    on element: AXUIElement
  ) -> String? {
    for action in available {
      if action == requested { return action }
      var description: CFString?
      if AXUIElementCopyActionDescription(element, action as CFString, &description) == .success,
        let description,
        description as String == requested
      {
        return action
      }
    }
    return nil
  }
}

enum TextSelectionResolver {
  static func resolve(
    text: String,
    in value: String,
    prefix: String?,
    suffix: String?
  ) throws -> CFRange {
    guard !text.isEmpty else { throw MacAccessibilityActionError.textNotFound }
    var matches: [Range<String.Index>] = []
    var searchStart = value.startIndex
    while searchStart <= value.endIndex,
      let range = value.range(of: text, range: searchStart..<value.endIndex)
    {
      let prefixMatches =
        prefix.map { candidate in
          value[..<range.lowerBound].hasSuffix(candidate)
        } ?? true
      let suffixMatches =
        suffix.map { candidate in
          value[range.upperBound...].hasPrefix(candidate)
        } ?? true
      if prefixMatches && suffixMatches { matches.append(range) }
      guard range.lowerBound < value.endIndex else { break }
      searchStart = value.index(after: range.lowerBound)
    }
    guard !matches.isEmpty else { throw MacAccessibilityActionError.textNotFound }
    guard matches.count == 1 else { throw MacAccessibilityActionError.ambiguousText }
    let nsRange = NSRange(matches[0], in: value)
    return CFRange(location: nsRange.location, length: nsRange.length)
  }
}
