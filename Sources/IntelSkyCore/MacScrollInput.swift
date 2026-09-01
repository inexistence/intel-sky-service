import ApplicationServices
import CoreGraphics
import Foundation

enum ComputerUseScrollDirection: String, Equatable, Sendable {
  case up
  case down
  case left
  case right
}

protocol ScreenFrameProviding: Sendable {
  func frame(containing point: CGPoint) -> CGRect?
}

struct CGScreenFrameProvider: ScreenFrameProviding {
  func frame(containing point: CGPoint) -> CGRect? {
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
    var displayCount: UInt32 = 0
    guard
      CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success
    else {
      return nil
    }
    return displayIDs.prefix(Int(displayCount)).lazy.map(CGDisplayBounds).first {
      $0.contains(point)
    }
  }
}

protocol ScrollEventPosting: Sendable {
  func scroll(
    at point: CGPoint,
    direction: ComputerUseScrollDirection,
    pages: Double,
    target: ComputerUseEventTarget
  ) throws
}

protocol AccessibilityPageScrolling: Sendable {
  func scroll(
    element: AXUIElement,
    direction: ComputerUseScrollDirection,
    pageCount: Int
  ) throws -> Int
}

struct MacAccessibilityPageScroller: AccessibilityPageScrolling {
  func scroll(
    element: AXUIElement,
    direction: ComputerUseScrollDirection,
    pageCount: Int
  ) throws -> Int {
    guard pageCount > 0, let target = scrollTarget(from: element, direction: direction) else {
      return 0
    }
    let action = actionName(for: direction)
    var completed = 0
    for _ in 0..<pageCount {
      try RequestDeadlineContext.check()
      try UserInterventionContext.check()
      let positionBefore = scrollPosition(of: target, direction: direction)
      guard AXUIElementPerformAction(target, action as CFString) == .success else { break }
      if let positionBefore {
        var positionAfter = scrollPosition(of: target, direction: direction)
        for _ in 0..<4 where positionAfter == positionBefore {
          Thread.sleep(forTimeInterval: 0.02)
          try RequestDeadlineContext.check()
          try UserInterventionContext.check()
          positionAfter = scrollPosition(of: target, direction: direction)
        }
        // Some controls advertise and accept AXScroll*ByPage while ignoring it.
        // Count only observable page movement so the caller can synthesize the
        // remaining wheel distance instead of returning a false success.
        guard positionAfter.map({ $0 != positionBefore }) == true else { break }
      }
      completed += 1
    }
    return completed
  }

  private func scrollPosition(
    of element: AXUIElement,
    direction: ComputerUseScrollDirection
  ) -> Double? {
    let scrollbarAttribute: CFString
    switch direction {
    case .up, .down: scrollbarAttribute = kAXVerticalScrollBarAttribute as CFString
    case .left, .right: scrollbarAttribute = kAXHorizontalScrollBarAttribute as CFString
    }

    let scrollbar: AXUIElement
    if stringAttribute(kAXRoleAttribute as CFString, of: element) == (kAXScrollBarRole as String) {
      scrollbar = element
    } else {
      var rawScrollbar: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, scrollbarAttribute, &rawScrollbar) == .success,
        let rawScrollbar,
        CFGetTypeID(rawScrollbar) == AXUIElementGetTypeID()
      else { return nil }
      scrollbar = unsafeDowncast(rawScrollbar, to: AXUIElement.self)
    }

    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        scrollbar,
        kAXValueAttribute as CFString,
        &rawValue
      ) == .success,
      let number = rawValue as? NSNumber
    else { return nil }
    return number.doubleValue
  }

  private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else {
      return nil
    }
    return rawValue as? String
  }

  private func scrollTarget(
    from element: AXUIElement,
    direction: ComputerUseScrollDirection
  ) -> AXUIElement? {
    let action = actionName(for: direction)
    var candidate: AXUIElement? = element
    for _ in 0..<64 {
      guard let current = candidate else { return nil }
      var rawNames: CFArray?
      if AXUIElementCopyActionNames(current, &rawNames) == .success,
        let names = rawNames as? [String], names.contains(action)
      {
        return current
      }
      candidate = parent(of: current)
    }
    return nil
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
    else {
      return nil
    }
    return unsafeDowncast(rawParent, to: AXUIElement.self)
  }

  private func actionName(for direction: ComputerUseScrollDirection) -> String {
    // The public API names the viewport/navigation direction. AX page actions
    // name the direction that the document content moves, which is the inverse.
    switch direction {
    case .up: return "AXScrollDownByPage"
    case .down: return "AXScrollUpByPage"
    case .left: return "AXScrollRightByPage"
    case .right: return "AXScrollLeftByPage"
    }
  }
}

struct ScrollDelta: Equatable, Sendable {
  let vertical: Int32
  let horizontal: Int32
}

struct ScrollDeltaPlan: Sendable {
  static func make(
    screenFrame: CGRect,
    direction: ComputerUseScrollDirection,
    pages: Double
  ) -> ScrollDelta {
    let axisExtent: Double
    switch direction {
    case .up, .down: axisExtent = screenFrame.height
    case .left, .right: axisExtent = screenFrame.width
    }
    let pageExtent = max(100, axisExtent)
    let rawMagnitude = pageExtent * pages
    let magnitude = Int32(min(Double(Int32.max), rawMagnitude))
    let signedMagnitude: Int32
    switch direction {
    case .up, .left: signedMagnitude = -magnitude
    case .down, .right: signedMagnitude = magnitude
    }

    switch direction {
    case .up, .down:
      return ScrollDelta(vertical: signedMagnitude, horizontal: 0)
    case .left, .right:
      return ScrollDelta(vertical: 0, horizontal: signedMagnitude)
    }
  }
}

struct CGScrollEventPoster: ScrollEventPosting {
  static let eventSourceStateID: CGEventSourceStateID = .hidSystemState

  private let screens: any ScreenFrameProviding

  init(screens: any ScreenFrameProviding = CGScreenFrameProvider()) {
    self.screens = screens
  }

  func scroll(
    at point: CGPoint,
    direction: ComputerUseScrollDirection,
    pages: Double,
    target: ComputerUseEventTarget
  ) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    guard let screen = screens.frame(containing: point) else {
      throw MacAppActionError.targetOutsideDisplays(point)
    }

    // ARM scales a page against ComputerUseAppController.visibleRect, clipped to a
    // minimum of 100 points. The cached target frame is the corresponding window
    // rectangle; intersect it with the containing display for partially off-screen windows.
    let clippedWindowFrame = target.screenFrame.intersection(screen)
    let visibleFrame = clippedWindowFrame.isNull || clippedWindowFrame.isEmpty
      ? target.screenFrame : clippedWindowFrame
    let delta = ScrollDeltaPlan.make(
      screenFrame: visibleFrame,
      direction: direction,
      pages: pages
    )
    guard let source = CGEventSource(stateID: Self.eventSourceStateID) else {
      throw MacAppActionError.eventCreationFailed
    }
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 1,
        wheel1: delta.vertical,
        wheel2: delta.horizontal,
        wheel3: 0
      )
    else {
      throw MacAppActionError.eventCreationFailed
    }
    event.location = point
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)

    let move = try ProcessTargetedEventPoster.makeWindowMouseEvent(
      type: .mouseMoved,
      location: point,
      button: .left,
      target: target
    )

    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      try RequestDeadlineContext.check()
      try UserInterventionContext.check()
      ProcessTargetedEventPoster.post(move, to: target)
      ProcessTargetedEventPoster.post(event, to: target)
    }
  }
}
