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
  private let elementIDs: AccessibilityElementIDRegistry

  public init(maximumDepth: Int = 12, maximumElements: Int = 1_500) {
    self.maximumDepth = max(0, maximumDepth)
    self.maximumElements = max(1, maximumElements)
    self.elementIDs = AccessibilityElementIDRegistry()
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
    elementIDs.beginCapture(processIdentifier: app.processIdentifier)
    defer { elementIDs.endCapture(processIdentifier: app.processIdentifier) }
    var state = TraversalState(processIdentifier: app.processIdentifier)
    append(window, depth: 0, path: [], rolePath: [], state: &state, lines: &lines)
    if state.wasTruncated {
      lines.append("… snapshot truncated at \(maximumElements) elements")
    }
    let invalidationMonitor = try? NativeAccessibilityInvalidationMonitor(
      processIdentifier: app.processIdentifier,
      application: application,
      window: window,
      actionableElements: state.actionableElements
    )
    return CapturedAccessibilitySnapshot(
      text: lines.joined(separator: "\n"),
      elementsByID: state.elementsByID,
      locatorsByID: state.locatorsByID,
      invalidationMonitor: invalidationMonitor,
      windowActivationPoint: geometry.point(
        of: window,
        attribute: "AXActivationPoint" as CFString
      )
    )
  }

  private func append(
    _ element: AXUIElement,
    depth: Int,
    path: [Int],
    rolePath: [String],
    state: inout TraversalState,
    lines: inout [String]
  ) {
    guard state.count < maximumElements else {
      state.wasTruncated = true
      return
    }
    let index = elementIDs.id(for: element, processIdentifier: state.processIdentifier)
    state.count += 1
    state.elementsByID[String(index)] = element

    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "AXUnknown"
    let locator = AccessibilityElementLocator(
      path: path,
      rolePath: rolePath + [role],
      role: role,
      subrole: stringAttribute(element, kAXSubroleAttribute as CFString),
      identifier: stringAttribute(element, kAXIdentifierAttribute as CFString),
      title: stringAttribute(element, kAXTitleAttribute as CFString),
      description: stringAttribute(element, kAXDescriptionAttribute as CFString),
      frame: geometry.frame(of: element)
    )
    state.locatorsByID[String(index)] = locator

    var fields = [
      "[\(index)]", role,
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
    let actions = actionDescriptions(element)
    if !actions.isEmpty {
      fields.append("actions=\(quoted(actions.joined(separator: ", ")))")
    }
    if !actions.isEmpty || isValueSettable(element) {
      state.actionableElements.append(element)
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
      append(
        child,
        depth: depth + 1,
        path: path + [offset],
        rolePath: locator.rolePath,
        state: &state,
        lines: &lines
      )
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

  private func actionDescriptions(_ element: AXUIElement) -> [String] {
    var rawNames: CFArray?
    guard AXUIElementCopyActionNames(element, &rawNames) == .success,
      let names = rawNames as? [String]
    else {
      return []
    }
    return names.map { name in
      var rawDescription: CFString?
      guard
        AXUIElementCopyActionDescription(element, name as CFString, &rawDescription) == .success,
        let rawDescription
      else {
        return name
      }
      return rawDescription as String
    }
  }

  private func isValueSettable(_ element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
      == .success && settable.boolValue
  }
}

private struct TraversalState {
  let processIdentifier: pid_t
  var count = 0
  var wasTruncated = false
  var elementsByID: [String: AXUIElement] = [:]
  var locatorsByID: [String: AccessibilityElementLocator] = [:]
  var actionableElements: [AXUIElement] = []
}

struct AccessibilityElementLocator: Sendable, Equatable {
  let path: [Int]
  let rolePath: [String]
  let role: String
  let subrole: String?
  let identifier: String?
  let title: String?
  let description: String?
  let frame: CGRect?

  func semanticallyMatches(_ other: Self) -> Bool {
    guard role == other.role, subrole == other.subrole else { return false }
    for (lhs, rhs) in [
      (identifier, other.identifier),
      (title, other.title),
      (description, other.description),
    ] where !(lhs?.isEmpty ?? true) {
      guard lhs == rhs else { return false }
    }
    return true
  }

  var hasStableLabel: Bool {
    [identifier, title, description].contains { !($0?.isEmpty ?? true) }
  }

  func safelyMatchesAtSamePath(_ other: Self) -> Bool {
    guard path == other.path, rolePath == other.rolePath, semanticallyMatches(other) else {
      return false
    }
    if hasStableLabel { return true }
    guard let frame, let otherFrame = other.frame else { return false }
    return abs(frame.minX - otherFrame.minX) <= 2
      && abs(frame.minY - otherFrame.minY) <= 2
      && abs(frame.width - otherFrame.width) <= 2
      && abs(frame.height - otherFrame.height) <= 2
  }
}

final class AccessibilityElementIDRegistry: @unchecked Sendable {
  private struct Entry {
    let id: Int
    let element: AXUIElement
    var lastSeenGeneration: UInt64
  }

  private struct ProcessState {
    var generation: UInt64 = 0
    var nextID = 0
    var entriesByHash: [CFHashCode: [Entry]] = [:]
  }

  private let lock = NSLock()
  private var states: [pid_t: ProcessState] = [:]

  func beginCapture(processIdentifier: pid_t) {
    lock.lock()
    defer { lock.unlock() }
    var state = states[processIdentifier] ?? ProcessState()
    state.generation &+= 1
    states[processIdentifier] = state
  }

  func id(for element: AXUIElement, processIdentifier: pid_t) -> Int {
    lock.lock()
    defer { lock.unlock() }
    var state = states[processIdentifier] ?? ProcessState(generation: 1)
    let hash = CFHash(element)
    var bucket = state.entriesByHash[hash] ?? []
    if let index = bucket.firstIndex(where: { CFEqual($0.element, element) }) {
      let id = bucket[index].id
      bucket[index].lastSeenGeneration = state.generation
      state.entriesByHash[hash] = bucket
      states[processIdentifier] = state
      return id
    }
    let id = state.nextID
    state.nextID += 1
    bucket.append(Entry(id: id, element: element, lastSeenGeneration: state.generation))
    state.entriesByHash[hash] = bucket
    states[processIdentifier] = state
    return id
  }

  func endCapture(processIdentifier: pid_t) {
    lock.lock()
    defer { lock.unlock() }
    guard var state = states[processIdentifier] else { return }
    let oldestGeneration = state.generation > 2 ? state.generation - 2 : 0
    state.entriesByHash = state.entriesByHash.compactMapValues { bucket in
      let retained = bucket.filter { $0.lastSeenGeneration >= oldestGeneration }
      return retained.isEmpty ? nil : retained
    }
    states = states.filter { $0.key == processIdentifier || !$0.value.entriesByHash.isEmpty }
    states[processIdentifier] = state
  }
}

struct CapturedAccessibilitySnapshot: @unchecked Sendable {
  let text: String
  let elementsByID: [String: AXUIElement]
  let locatorsByID: [String: AccessibilityElementLocator]
  let invalidationMonitor: (any AccessibilitySnapshotInvalidationMonitoring)?
  let windowActivationPoint: CGPoint?

  init(
    text: String,
    elementsByID: [String: AXUIElement],
    locatorsByID: [String: AccessibilityElementLocator] = [:],
    invalidationMonitor: (any AccessibilitySnapshotInvalidationMonitoring)? = nil,
    windowActivationPoint: CGPoint? = nil
  ) {
    self.text = text
    self.elementsByID = elementsByID
    self.locatorsByID = locatorsByID
    self.invalidationMonitor = invalidationMonitor
    self.windowActivationPoint = windowActivationPoint
  }
}
