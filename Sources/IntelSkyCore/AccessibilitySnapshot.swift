import ApplicationServices
import Foundation

public enum AccessibilitySnapshotError: Error, CustomStringConvertible {
  case permissionRequired
  case noWindow(String)

  public var description: String {
    switch self {
    case .permissionRequired:
      return "Accessibility permission is required for intel-sky-service"
    case .noWindow(let app):
      return "Could not read an Accessibility window for \(app)"
    }
  }
}

public struct AccessibilitySnapshotter: Sendable {
  public let maximumDepth: Int
  public let maximumElements: Int
  private let geometry = AccessibilityElementGeometry()

  public init(maximumDepth: Int = 12, maximumElements: Int = 1_500) {
    self.maximumDepth = max(0, maximumDepth)
    self.maximumElements = max(1, maximumElements)
  }

  func capture(app: ResolvedMacApp) throws -> CapturedAccessibilitySnapshot {
    guard AXIsProcessTrusted() else {
      throw AccessibilitySnapshotError.permissionRequired
    }

    let application = AXUIElementCreateApplication(app.processIdentifier)
    let window =
      copyElement(application, kAXFocusedWindowAttribute as CFString)
      ?? copyElements(application, kAXWindowsAttribute as CFString).first
    guard let window else {
      throw AccessibilitySnapshotError.noWindow(app.displayName)
    }

    var lines = [
      "Application \(quoted(app.displayName)) bundle=\(quoted(app.bundleIdentifier)) pid=\(app.processIdentifier)"
    ]
    var state = TraversalState()
    append(window, depth: 0, state: &state, lines: &lines)
    if state.wasTruncated {
      lines.append("… snapshot truncated at \(maximumElements) elements")
    }
    return CapturedAccessibilitySnapshot(
      text: lines.joined(separator: "\n"),
      elementsByID: state.elementsByID
    )
  }

  private func append(
    _ element: AXUIElement,
    depth: Int,
    state: inout TraversalState,
    lines: inout [String]
  ) {
    guard state.count < maximumElements else {
      state.wasTruncated = true
      return
    }
    let index = state.count
    state.count += 1
    state.elementsByID[String(index)] = element

    var fields = [
      "[\(index)]", stringAttribute(element, kAXRoleAttribute as CFString) ?? "AXUnknown",
    ]
    appendField("title", stringAttribute(element, kAXTitleAttribute as CFString), to: &fields)
    appendField(
      "description", stringAttribute(element, kAXDescriptionAttribute as CFString), to: &fields)
    appendField(
      "value", printableValue(copyAttribute(element, kAXValueAttribute as CFString)), to: &fields)
    appendField(
      "selectedText", stringAttribute(element, kAXSelectedTextAttribute as CFString), to: &fields)
    if let enabled = copyAttribute(element, kAXEnabledAttribute as CFString) as? Bool {
      fields.append("enabled=\(enabled)")
    }
    if let focused = copyAttribute(element, kAXFocusedAttribute as CFString) as? Bool, focused {
      fields.append("focused=true")
    }
    if let frame = frameDescription(element) {
      fields.append("frame=\(frame)")
    }
    lines.append(String(repeating: "  ", count: depth) + fields.joined(separator: " "))

    guard depth < maximumDepth else {
      if !copyElements(element, kAXChildrenAttribute as CFString).isEmpty {
        state.wasTruncated = true
      }
      return
    }
    let children = copyElements(element, kAXChildrenAttribute as CFString)
    for (offset, child) in children.enumerated() {
      append(child, depth: depth + 1, state: &state, lines: &lines)
      if state.count >= maximumElements {
        if offset < children.count - 1 { state.wasTruncated = true }
        break
      }
    }
  }

  private func appendField(_ name: String, _ value: String?, to fields: inout [String]) {
    guard let value, !value.isEmpty else { return }
    fields.append("\(name)=\(quoted(value))")
  }

  private func quoted(_ value: String) -> String {
    let compact =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let limited = compact.count > 500 ? String(compact.prefix(500)) + "…" : compact
    return "\"\(limited)\""
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    copyAttribute(element, attribute) as? String
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
  }

  private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func copyElements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
    guard let values = copyAttribute(element, attribute) as? [Any] else { return [] }
    return values.compactMap { value in
      let reference = value as CFTypeRef
      guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
      return unsafeDowncast(reference, to: AXUIElement.self)
    }
  }

  private func printableValue(_ value: CFTypeRef?) -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private func frameDescription(_ element: AXUIElement) -> String? {
    guard let frame = geometry.frame(of: element) else { return nil }
    return "(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
  }
}

private struct TraversalState {
  var count = 0
  var wasTruncated = false
  var elementsByID: [String: AXUIElement] = [:]
}

struct CapturedAccessibilitySnapshot {
  let text: String
  let elementsByID: [String: AXUIElement]
}
