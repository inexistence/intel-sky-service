import ApplicationServices
import CoreGraphics
import Foundation

protocol MouseDragPosting: Sendable {
  func drag(from start: CGPoint, to end: CGPoint, target: ComputerUseEventTarget) throws
}

struct CGMouseDragPoster: MouseDragPosting {
  func drag(from start: CGPoint, to end: CGPoint, target: ComputerUseEventTarget) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    let events = try Self.events(from: start, to: end, target: target)

    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      try RequestDeadlineContext.check()
      try UserInterventionContext.check()
      for event in events {
        ProcessTargetedEventPoster.post(event, to: target)
      }
    }
  }

  static func events(
    from start: CGPoint,
    to end: CGPoint,
    target: ComputerUseEventTarget
  ) throws -> [CGEvent] {
    let clickEventNumber = 1
    let dragEventNumber = 2
    let down = try ProcessTargetedEventPoster.makeWindowMouseEvent(
      type: .leftMouseDown,
      location: start,
      button: .left,
      target: target,
      eventNumber: clickEventNumber,
      clickCount: 1
    )
    let midpoint = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
    let dragEvents = try [start, midpoint, end].map { point in
      try ProcessTargetedEventPoster.makeWindowMouseEvent(
        type: .leftMouseDragged,
        location: point,
        button: .left,
        target: target,
        eventNumber: dragEventNumber,
        clickCount: 0
      )
    }
    let up = try ProcessTargetedEventPoster.makeWindowMouseEvent(
      type: .leftMouseUp,
      location: end,
      button: .left,
      target: target,
      eventNumber: clickEventNumber,
      clickCount: 1
    )
    return [down] + dragEvents + [up]
  }
}
