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
  func click(
    at point: CGPoint,
    button: ComputerUseMouseButton,
    count: Int,
    target: ComputerUseEventTarget
  ) throws
}

struct WorkspaceAppActivator: AppActivating {
  private let focusArbitrator: any ComputerUseFocusArbitrating

  init(focusArbitrator: any ComputerUseFocusArbitrating = ComputerUseFocusCoordinator.shared) {
    self.focusArbitrator = focusArbitrator
  }

  func activate(_ app: ResolvedMacApp) throws {
    guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier),
      !runningApp.isTerminated
    else {
      throw MacAppActionError.activationFailed(app.bundleIdentifier)
    }
    if runningApp.isActive { return }
    focusArbitrator.targetWillBeActivated(app)

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
  func click(
    at point: CGPoint,
    button: ComputerUseMouseButton,
    count: Int,
    target: ComputerUseEventTarget
  ) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    let types: (down: CGEventType, up: CGEventType, button: CGMouseButton)
    switch button {
    case .left: types = (.leftMouseDown, .leftMouseUp, .left)
    case .right: types = (.rightMouseDown, .rightMouseUp, .right)
    case .middle: types = (.otherMouseDown, .otherMouseUp, .center)
    }

    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      for clickIndex in 1...count {
        try RequestDeadlineContext.check()
        try UserInterventionContext.check()
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
        ProcessTargetedEventPoster.post(down, to: target)
        ProcessTargetedEventPoster.post(up, to: target)
        if clickIndex < count { Thread.sleep(forTimeInterval: 0.05) }
      }
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
  private let accessibilityPageScroller: any AccessibilityPageScrolling
  private let mouseDragPoster: any MouseDragPosting
  private let accessibilityActions: any AccessibilityActionPerforming
  private let accessibilityPrimaryClicker: any AccessibilityPrimaryClicking
  private let pasteOperation: any PastePerforming
  private let interactionTracker: AppInteractionTracker
  private let screenLockChecker: any ScreenLockChecking
  private let secureInputChecker: any SecureInputChecking
  private let userInterventionMonitor: any UserInterventionMonitoring
  private let interventionArbitrator: any ComputerUseInterventionArbitrating
  private let visualizer: any ComputerUseVisualizing
  private let policyEvaluator: any MacAppPolicyEvaluating
  private let sessionCoordinator: any ComputerUseSessionCoordinating

  public init(
    resolver: any MacAppResolving = MacAppResolver(),
    snapshotCache: ElementSnapshotCache,
    interactionTracker: AppInteractionTracker = AppInteractionTracker()
  ) {
    self.init(
      resolver: resolver,
      snapshotCache: snapshotCache,
      activator: WorkspaceAppActivator(),
      frameReader: AccessibilityElementGeometry(),
      mouseClickPoster: CGMouseClickPoster(),
      keyboardInputPoster: CGKeyboardInputPoster(),
      scrollEventPoster: CGScrollEventPoster(),
      accessibilityPageScroller: MacAccessibilityPageScroller(),
      mouseDragPoster: CGMouseDragPoster(),
      accessibilityActions: MacAccessibilityActionPerformer(),
      accessibilityPrimaryClicker: MacAccessibilityPrimaryClicker(),
      pasteOperation: MacPasteOperation(),
      interactionTracker: interactionTracker,
      screenLockChecker: CGSessionScreenLockChecker(),
      secureInputChecker: CarbonSecureInputChecker(),
      userInterventionMonitor: PhysicalInputMonitor.shared,
      interventionArbitrator: ComputerUseInterventionCoordinator.shared,
      visualizer: ComputerUseVisualCoordinator.shared,
      policyEvaluator: OfficialCompatibleMacAppPolicyEvaluator(),
      sessionCoordinator: ComputerUseSessionCoordinator.shared
    )
  }

  init(
    resolver: any MacAppResolving,
    snapshotCache: ElementSnapshotCache,
    activator: any AppActivating,
    frameReader: any AccessibilityFrameReading,
    mouseClickPoster: any MouseClickPosting,
    keyboardInputPoster: any KeyboardInputPosting = CGKeyboardInputPoster(),
    scrollEventPoster: any ScrollEventPosting = CGScrollEventPoster(),
    accessibilityPageScroller: any AccessibilityPageScrolling = MacAccessibilityPageScroller(),
    mouseDragPoster: any MouseDragPosting = CGMouseDragPoster(),
    accessibilityActions: any AccessibilityActionPerforming = MacAccessibilityActionPerformer(),
    accessibilityPrimaryClicker: any AccessibilityPrimaryClicking =
      MacAccessibilityPrimaryClicker(),
    pasteOperation: any PastePerforming = MacPasteOperation(),
    interactionTracker: AppInteractionTracker = AppInteractionTracker(),
    screenLockChecker: any ScreenLockChecking = NoopScreenLockChecker(),
    secureInputChecker: any SecureInputChecking = NoopSecureInputChecker(),
    userInterventionMonitor: any UserInterventionMonitoring = NoopUserInterventionMonitor(),
    interventionArbitrator: any ComputerUseInterventionArbitrating =
      NoopComputerUseInterventionArbitrator(),
    visualizer: any ComputerUseVisualizing = NoopComputerUseVisualizer(),
    policyEvaluator: any MacAppPolicyEvaluating = OfficialCompatibleMacAppPolicyEvaluator(),
    sessionCoordinator: any ComputerUseSessionCoordinating = NoopComputerUseSessionCoordinator()
  ) {
    self.resolver = resolver
    self.snapshotCache = snapshotCache
    self.activator = activator
    self.frameReader = frameReader
    self.mouseClickPoster = mouseClickPoster
    self.keyboardInputPoster = keyboardInputPoster
    self.scrollEventPoster = scrollEventPoster
    self.accessibilityPageScroller = accessibilityPageScroller
    self.mouseDragPoster = mouseDragPoster
    self.accessibilityActions = accessibilityActions
    self.accessibilityPrimaryClicker = accessibilityPrimaryClicker
    self.pasteOperation = pasteOperation
    self.interactionTracker = interactionTracker
    self.screenLockChecker = screenLockChecker
    self.secureInputChecker = secureInputChecker
    self.userInterventionMonitor = userInterventionMonitor
    self.interventionArbitrator = interventionArbitrator
    self.visualizer = visualizer
    self.policyEvaluator = policyEvaluator
    self.sessionCoordinator = sessionCoordinator
  }

  public func performAction(request: [String: Any]) throws -> [String: Any] {
    try screenLockChecker.requireUnlocked()
    try RequestDeadlineContext.check()
    let app = try resolver.resolve(request["app"])
    let sessionTarget = ResolvedMacApplication(app)
    try sessionCoordinator.requireActionAllowed(sessionTarget)
    let sessionScope = ComputerUseSessionOperationContext.begin(
      coordinator: sessionCoordinator,
      app: sessionTarget
    )
    defer { sessionScope.end() }
    try policyEvaluator.requireAllowed(sessionTarget)
    try interventionArbitrator.requireFreshState(for: app)
    let interventionScope = UserInterventionContext.begin(
      monitor: userInterventionMonitor,
      processIdentifier: app.processIdentifier
    )
    defer { interventionScope.end() }
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
      let target = try snapshotCache.eventTarget(for: app)
      try keyboardInputPoster.press(chord, target: target)
    case "type":
      let text = try parseSingleStringPayload(action[actionName], actionName: actionName)
      guard !text.isEmpty else {
        throw MacAppActionError.invalidAction("no text to type")
      }
      guard text.utf16.count <= 10_000 else {
        throw MacAppActionError.invalidAction("type text exceeds 10,000 UTF-16 code units")
      }
      try secureInputChecker.requireTextInjectionAllowed()
      let target = try snapshotCache.eventTarget(for: app)
      try keyboardInputPoster.typeText(text, target: target)
    case "scroll":
      guard let scroll = action[actionName] as? [String: Any] else {
        throw MacAppActionError.invalidAction("scroll payload must be an object")
      }
      try performScroll(scroll, app: app)
    case "drag":
      guard let drag = action[actionName] as? [String: Any] else {
        throw MacAppActionError.invalidAction("drag payload must be an object")
      }
      try performDrag(drag, app: app)
    case "setValue":
      guard let payload = action[actionName] as? [String: Any],
        Set(payload.keys) == ["elementID", "value"],
        let elementID = payload["elementID"] as? String,
        let value = payload["value"] as? String
      else {
        throw MacAppActionError.invalidAction("setValue requires elementID and value")
      }
      let element = try snapshotCache.element(id: elementID, for: app)
      try accessibilityActions.setValue(value, on: element)
    case "performSecondaryAction":
      guard let payload = action[actionName] as? [String: Any],
        Set(payload.keys) == ["action", "elementID"],
        let elementID = payload["elementID"] as? String,
        let secondaryAction = payload["action"] as? String,
        !secondaryAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw MacAppActionError.invalidAction(
          "performSecondaryAction requires action and elementID"
        )
      }
      let element = try snapshotCache.element(id: elementID, for: app)
      try accessibilityActions.performSecondaryAction(secondaryAction, on: element)
    case "selectText":
      try performSelectText(action[actionName], app: app)
    case "paste":
      guard let payload = action[actionName] as? [String: Any],
        Set(payload.keys) == ["format", "text"],
        let text = payload["text"] as? String,
        let rawFormat = payload["format"] as? String,
        let format = PasteContentFormat(rawValue: rawFormat)
      else {
        throw MacAppActionError.invalidAction("paste requires text and format text, md, or html")
      }
      try secureInputChecker.requireTextInjectionAllowed()
      let target = try snapshotCache.eventTarget(for: app)
      try pasteOperation.paste(
        text: text,
        format: format,
        keyboard: keyboardInputPoster,
        target: target
      )
    default:
      throw MacAppActionError.unsupportedAction(actionName)
    }
    try sessionScope.check()
    try interventionScope.check()
    interactionTracker.recordAction(for: app)
    return [:]
  }

  private func performDrag(_ drag: [String: Any], app: ResolvedMacApp) throws {
    guard Set(drag.keys) == ["from", "to"] else {
      throw MacAppActionError.invalidAction("drag payload must contain from and to")
    }
    let start = try parseCoordinateTuple(drag["from"], name: "drag.from")
    let end = try parseCoordinateTuple(drag["to"], name: "drag.to")
    let screenStart = try snapshotCache.screenPoint(for: start, in: app)
    let screenEnd = try snapshotCache.screenPoint(for: end, in: app)
    let target = try snapshotCache.eventTarget(for: app)
    visualizer.showDrag(from: screenStart, to: screenEnd)
    try mouseDragPoster.drag(from: screenStart, to: screenEnd, target: target)
  }

  private func performSelectText(_ value: Any?, app: ResolvedMacApp) throws {
    guard let payload = value as? [String: Any],
      Set(payload.keys).isSubset(of: ["elementID", "text", "prefix", "suffix", "selection"]),
      payload.keys.contains("elementID"),
      payload.keys.contains("text"),
      let elementID = payload["elementID"] as? String,
      let text = payload["text"] as? String,
      optionalString(payload["prefix"]),
      optionalString(payload["suffix"]),
      let rawSelection = (payload["selection"] as? String) ?? "text" as String?,
      let selection = TextSelectionKind(rawValue: rawSelection)
    else {
      throw MacAppActionError.invalidAction("selectText payload is malformed")
    }
    let element = try snapshotCache.element(id: elementID, for: app)
    try accessibilityActions.selectText(
      text,
      prefix: payload["prefix"] as? String,
      suffix: payload["suffix"] as? String,
      selection: selection,
      on: element
    )
  }

  private func optionalString(_ value: Any?) -> Bool {
    value == nil || value is String
  }

  private func parseCoordinateTuple(_ value: Any?, name: String) throws -> CGPoint {
    guard let values = value as? [NSNumber], values.count == 2,
      values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() })
    else {
      throw MacAppActionError.invalidAction("\(name) must be a two-number coordinate")
    }
    let point = CGPoint(x: values[0].doubleValue, y: values[1].doubleValue)
    guard point.x.isFinite, point.y.isFinite else {
      throw MacAppActionError.invalidAction("\(name) coordinates must be finite")
    }
    return point
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

    let visualizationPoint: CGPoint?
    switch target {
    case .elementID:
      visualizationPoint = element.flatMap { frameReader.frame(of: $0.value) }.map {
        CGPoint(x: $0.midX, y: $0.midY)
      }
    case .coordinate(let coordinate):
      visualizationPoint = try snapshotCache.screenPoint(for: coordinate, in: app)
    }
    if let visualizationPoint { visualizer.showClick(at: visualizationPoint) }
    if let element, button == .left, count == 1,
      try accessibilityPrimaryClicker.click(element: element.value)
    {
      return
    }
    let eventTarget = try snapshotCache.eventTarget(for: app)
    let point: CGPoint
    switch target {
    case .elementID:
      guard let element, let frame = frameReader.frame(of: element.value) else {
        throw MacAppActionError.missingElementFrame(element?.id ?? "unknown")
      }
      point = CGPoint(x: frame.midX, y: frame.midY)
    case .coordinate(let coordinate):
      point = try snapshotCache.screenPoint(for: coordinate, in: app)
    }
    try mouseClickPoster.click(at: point, button: button, count: count, target: eventTarget)
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
      number.doubleValue > 0
    else {
      throw MacAppActionError.invalidAction("scroll pages must be a finite number greater than 0")
    }

    let element: AXUIElement?
    switch target {
    case .elementID(let elementID):
      element = try snapshotCache.element(id: elementID, for: app)
    case .coordinate:
      try snapshotCache.validateSnapshot(for: app)
      element = nil
    }
    let point: CGPoint
    switch target {
    case .elementID(let elementID):
      guard let element, let frame = frameReader.frame(of: element) else {
        throw MacAppActionError.missingElementFrame(elementID)
      }
      point = CGPoint(x: frame.midX, y: frame.midY)
    case .coordinate(let coordinate):
      point = try snapshotCache.screenPoint(for: coordinate, in: app)
    }
    visualizer.moveCursor(to: point)
    let requestedPages = number.doubleValue
    let wholePages = min(240, Int(min(Double(Int.max), requestedPages.rounded(.down))))
    let axPages: Int
    if let element {
      axPages = try accessibilityPageScroller.scroll(
        element: element,
        direction: direction,
        pageCount: wholePages
      )
    } else {
      axPages = 0
    }
    let remainingPages = requestedPages - Double(axPages)
    if remainingPages > 0 {
      let eventTarget = try snapshotCache.eventTarget(for: app)
      try scrollEventPoster.scroll(
        at: point,
        direction: direction,
        pages: remainingPages,
        target: eventTarget
      )
    }
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
