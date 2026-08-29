import AppKit
import CoreGraphics
import Foundation

public enum MacAppActionError: Error, CustomStringConvertible {
  case invalidAction(String)
  case unsupportedAction(String)
  case activationFailed(String)
  case missingElementFrame(String)
  case targetOutsideDisplays(CGPoint)
  case eventCreationFailed

  public var description: String {
    switch self {
    case .invalidAction(let message): return "Invalid Computer Use action: \(message)"
    case .unsupportedAction(let name): return "Unsupported Computer Use action: \(name)"
    case .activationFailed(let app): return "Could not activate app: \(app)"
    case .missingElementFrame(let elementID):
      return "Element \(elementID) has no usable Accessibility frame"
    case .targetOutsideDisplays(let point):
      return "Target coordinate (\(point.x), \(point.y)) is outside active displays"
    case .eventCreationFailed: return "CoreGraphics could not create an input event"
    }
  }
}

enum ComputerUseTarget: Equatable {
  case elementID(String)
  case coordinate(CGPoint)
}

enum ComputerUseMouseButton: Int, Equatable {
  case left = 0
  case right = 1
  case middle = 2
}

protocol AppActivating: Sendable {
  func activate(_ app: ResolvedMacApp) throws
}

protocol MouseClickPosting: Sendable {
  func click(at point: CGPoint, button: ComputerUseMouseButton, count: Int) throws
}

struct WorkspaceAppActivator: AppActivating {
  func activate(_ app: ResolvedMacApp) throws {
    guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier),
      !runningApp.isTerminated
    else {
      throw MacAppActionError.activationFailed(app.bundleIdentifier)
    }
    if runningApp.isActive { return }

    if runningApp.activate(options: [.activateAllWindows]),
      waitUntilActive(runningApp, timeout: 0.5)
    {
      return
    }

    guard !app.appPath.isEmpty else {
      throw MacAppActionError.activationFailed(app.bundleIdentifier)
    }
    let openProcess = Process()
    openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    openProcess.arguments = [app.appPath]
    openProcess.standardOutput = FileHandle.nullDevice
    openProcess.standardError = FileHandle.nullDevice
    do {
      try openProcess.run()
      openProcess.waitUntilExit()
    } catch {
      throw MacAppActionError.activationFailed(app.bundleIdentifier)
    }
    guard openProcess.terminationStatus == 0 else {
      throw MacAppActionError.activationFailed(app.bundleIdentifier)
    }
    guard waitUntilActive(runningApp, timeout: 2) else {
      throw MacAppActionError.activationFailed(app.bundleIdentifier)
    }
  }

  private func waitUntilActive(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !app.isActive, !app.isTerminated, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    return app.isActive && !app.isTerminated
  }
}

struct CGMouseClickPoster: MouseClickPosting {
  func click(at point: CGPoint, button: ComputerUseMouseButton, count: Int) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    let types: (down: CGEventType, up: CGEventType, button: CGMouseButton)
    switch button {
    case .left: types = (.leftMouseDown, .leftMouseUp, .left)
    case .right: types = (.rightMouseDown, .rightMouseUp, .right)
    case .middle: types = (.otherMouseDown, .otherMouseUp, .center)
    }

    for clickIndex in 1...count {
      guard
        let down = CGEvent(
          mouseEventSource: nil,
          mouseType: types.down,
          mouseCursorPosition: point,
          mouseButton: types.button
        ),
        let up = CGEvent(
          mouseEventSource: nil,
          mouseType: types.up,
          mouseCursorPosition: point,
          mouseButton: types.button
        )
      else {
        throw MacAppActionError.eventCreationFailed
      }
      down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      if clickIndex < count { Thread.sleep(forTimeInterval: 0.05) }
    }
  }
}

public struct MacAppActionPerformer: AppActionPerforming {
  private let resolver: any MacAppResolving
  private let snapshotCache: ElementSnapshotCache
  private let activator: any AppActivating
  private let frameReader: any AccessibilityFrameReading
  private let mouseClickPoster: any MouseClickPosting
  private let keyboardInputPoster: any KeyboardInputPosting
  private let scrollEventPoster: any ScrollEventPosting

  public init(
    resolver: any MacAppResolving = MacAppResolver(),
    snapshotCache: ElementSnapshotCache
  ) {
    self.init(
      resolver: resolver,
      snapshotCache: snapshotCache,
      activator: WorkspaceAppActivator(),
      frameReader: AccessibilityElementGeometry(),
      mouseClickPoster: CGMouseClickPoster(),
      keyboardInputPoster: CGKeyboardInputPoster(),
      scrollEventPoster: CGScrollEventPoster()
    )
  }

  init(
    resolver: any MacAppResolving,
    snapshotCache: ElementSnapshotCache,
    activator: any AppActivating,
    frameReader: any AccessibilityFrameReading,
    mouseClickPoster: any MouseClickPosting,
    keyboardInputPoster: any KeyboardInputPosting = CGKeyboardInputPoster(),
    scrollEventPoster: any ScrollEventPosting = CGScrollEventPoster()
  ) {
    self.resolver = resolver
    self.snapshotCache = snapshotCache
    self.activator = activator
    self.frameReader = frameReader
    self.mouseClickPoster = mouseClickPoster
    self.keyboardInputPoster = keyboardInputPoster
    self.scrollEventPoster = scrollEventPoster
  }

  public func performAction(request: [String: Any]) throws -> [String: Any] {
    let app = try resolver.resolve(request["app"])
    guard let action = request["action"] as? [String: Any], action.count == 1,
      let actionName = action.keys.first
    else {
      throw MacAppActionError.invalidAction("expected exactly one action")
    }
    switch actionName {
    case "click":
      guard let click = action[actionName] as? [String: Any] else {
        throw MacAppActionError.invalidAction("click payload must be an object")
      }
      try performClick(click, app: app)
    case "pressKey":
      let key = try parseSingleStringPayload(action[actionName], actionName: actionName)
      let chord = try MacKeyChordParser().parse(key)
      try prepareForInput(app)
      try keyboardInputPoster.press(chord)
    case "type":
      let text = try parseSingleStringPayload(action[actionName], actionName: actionName)
      guard text.utf16.count <= 10_000 else {
        throw MacAppActionError.invalidAction("type text exceeds 10,000 UTF-16 code units")
      }
      try prepareForInput(app)
      try keyboardInputPoster.typeText(text)
    case "scroll":
      guard let scroll = action[actionName] as? [String: Any] else {
        throw MacAppActionError.invalidAction("scroll payload must be an object")
      }
      try performScroll(scroll, app: app)
    default:
      throw MacAppActionError.unsupportedAction(actionName)
    }
    return [:]
  }

  private func performClick(_ click: [String: Any], app: ResolvedMacApp) throws {
    guard Set(click.keys) == ["at", "clickCount", "mouseButton"] else {
      throw MacAppActionError.invalidAction(
        "click payload must contain at, clickCount, and mouseButton"
      )
    }

    let target = try parseTarget(click["at"], actionName: "click")
    let count = try parseClickCount(click["clickCount"])
    let button = try parseMouseButton(click["mouseButton"])
    let element: (id: String, value: AXUIElement)?
    switch target {
    case .elementID(let elementID):
      element = (elementID, try snapshotCache.element(id: elementID, for: app))
    case .coordinate:
      try snapshotCache.validateSnapshot(for: app)
      element = nil
    }

    try activator.activate(app)
    let point: CGPoint
    switch target {
    case .elementID:
      guard let element, let frame = frameReader.frame(of: element.value) else {
        throw MacAppActionError.missingElementFrame(element?.id ?? "unknown")
      }
      point = CGPoint(x: frame.midX, y: frame.midY)
    case .coordinate(let coordinate):
      point = coordinate
    }
    try mouseClickPoster.click(at: point, button: button, count: count)
  }

  private func performScroll(_ scroll: [String: Any], app: ResolvedMacApp) throws {
    guard Set(scroll.keys) == ["at", "direction", "pages"] else {
      throw MacAppActionError.invalidAction(
        "scroll payload must contain at, direction, and pages"
      )
    }
    let target = try parseTarget(scroll["at"], actionName: "scroll")
    guard let rawDirection = scroll["direction"] as? String,
      let direction = ComputerUseScrollDirection(rawValue: rawDirection)
    else {
      throw MacAppActionError.invalidAction("scroll direction must be up, down, left, or right")
    }
    guard let number = scroll["pages"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite,
      number.doubleValue > 0,
      number.doubleValue <= 10
    else {
      throw MacAppActionError.invalidAction("scroll pages must be greater than 0 and at most 10")
    }

    let element: AXUIElement?
    switch target {
    case .elementID(let elementID):
      element = try snapshotCache.element(id: elementID, for: app)
    case .coordinate:
      try snapshotCache.validateSnapshot(for: app)
      element = nil
    }
    try activator.activate(app)

    let point: CGPoint
    switch target {
    case .elementID(let elementID):
      guard let element, let frame = frameReader.frame(of: element) else {
        throw MacAppActionError.missingElementFrame(elementID)
      }
      point = CGPoint(x: frame.midX, y: frame.midY)
    case .coordinate(let coordinate):
      point = coordinate
    }
    try scrollEventPoster.scroll(
      at: point,
      direction: direction,
      pages: number.doubleValue
    )
  }

  private func prepareForInput(_ app: ResolvedMacApp) throws {
    try snapshotCache.validateSnapshot(for: app)
    try activator.activate(app)
  }

  private func parseSingleStringPayload(_ value: Any?, actionName: String) throws -> String {
    guard let payload = value as? [String: Any], payload.count == 1,
      let string = payload["_0"] as? String
    else {
      throw MacAppActionError.invalidAction("\(actionName) payload must contain one string")
    }
    return string
  }

  private func parseTarget(_ value: Any?, actionName: String) throws -> ComputerUseTarget {
    guard let target = value as? [String: Any], target.count == 1 else {
      throw MacAppActionError.invalidAction("\(actionName).at must contain one target")
    }
    if let element = target["elementID"] as? [String: Any], element.count == 1,
      let id = element["_0"] as? String,
      !id.isEmpty
    {
      return .elementID(id)
    }
    if let coordinate = target["coordinate"] as? [String: Any], coordinate.count == 1,
      let values = coordinate["_0"] as? [NSNumber],
      values.count == 2,
      values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() })
    {
      let point = CGPoint(x: values[0].doubleValue, y: values[1].doubleValue)
      guard point.x.isFinite, point.y.isFinite else {
        throw MacAppActionError.invalidAction("click coordinates must be finite")
      }
      return .coordinate(point)
    }
    throw MacAppActionError.invalidAction("\(actionName) target is malformed")
  }

  private func parseClickCount(_ value: Any?) throws -> Int {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.rounded() == number.doubleValue,
      (1...3).contains(number.intValue)
    else {
      throw MacAppActionError.invalidAction("clickCount must be an integer from 1 through 3")
    }
    return number.intValue
  }

  private func parseMouseButton(_ value: Any?) throws -> ComputerUseMouseButton {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let button = ComputerUseMouseButton(rawValue: number.intValue),
      number.doubleValue.rounded() == number.doubleValue
    else {
      throw MacAppActionError.invalidAction("mouseButton must be 0, 1, or 2")
    }
    return button
  }
}
