import ApplicationServices
import CoreGraphics
import Foundation

protocol MouseDragPosting: Sendable {
  func drag(from start: CGPoint, to end: CGPoint) throws
}

struct CGMouseDragPoster: MouseDragPosting {
  func drag(from start: CGPoint, to end: CGPoint) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    guard
      let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: start,
        mouseButton: .left
      ),
      let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: end,
        mouseButton: .left
      )
    else {
      throw MacAppActionError.eventCreationFailed
    }

    let distance = hypot(end.x - start.x, end.y - start.y)
    let stepCount = min(60, max(6, Int(ceil(distance / 20))))
    var dragEvents: [CGEvent] = []
    for step in 1...stepCount {
      let progress = CGFloat(step) / CGFloat(stepCount)
      let point = CGPoint(
        x: start.x + (end.x - start.x) * progress,
        y: start.y + (end.y - start.y) * progress
      )
      guard
        let event = CGEvent(
          mouseEventSource: nil,
          mouseType: .leftMouseDragged,
          mouseCursorPosition: point,
          mouseButton: .left
        )
      else {
        throw MacAppActionError.eventCreationFailed
      }
      dragEvents.append(event)
    }

    try RequestDeadlineContext.check()
    try UserInterventionContext.check()
    down.post(tap: .cghidEventTap)
    do {
      for event in dragEvents {
        try RequestDeadlineContext.check()
        try UserInterventionContext.check()
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)
      }
    } catch {
      up.post(tap: .cghidEventTap)
      throw error
    }
    up.post(tap: .cghidEventTap)
  }
}
