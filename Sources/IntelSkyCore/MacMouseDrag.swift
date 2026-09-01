import ApplicationServices
import CoreGraphics
import Foundation

protocol MouseDragPosting: Sendable {
  func drag(from start: CGPoint, to end: CGPoint, target: ComputerUseEventTarget) throws
}

struct CGMouseDragPoster: MouseDragPosting {
  func drag(from start: CGPoint, to end: CGPoint, target: ComputerUseEventTarget) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    let down = try ProcessTargetedEventPoster.makeWindowMouseEvent(
      type: .leftMouseDown,
      location: start,
      button: .left,
      target: target
    )
    let up = try ProcessTargetedEventPoster.makeWindowMouseEvent(
      type: .leftMouseUp,
      location: end,
      button: .left,
      target: target
    )

    let distance = hypot(end.x - start.x, end.y - start.y)
    let stepCount = min(60, max(6, Int(ceil(distance / 20))))
    var dragEvents: [CGEvent] = []
    for step in 1...stepCount {
      let progress = CGFloat(step) / CGFloat(stepCount)
      let point = CGPoint(
        x: start.x + (end.x - start.x) * progress,
        y: start.y + (end.y - start.y) * progress
      )
      let event = try ProcessTargetedEventPoster.makeWindowMouseEvent(
        type: .leftMouseDragged,
        location: point,
        button: .left,
        target: target
      )
      dragEvents.append(event)
    }

    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      try RequestDeadlineContext.check()
      try UserInterventionContext.check()
      ProcessTargetedEventPoster.post(down, to: target)
      do {
        for event in dragEvents {
          try RequestDeadlineContext.check()
          try UserInterventionContext.check()
          ProcessTargetedEventPoster.post(event, to: target)
          Thread.sleep(forTimeInterval: 0.008)
        }
      } catch {
        ProcessTargetedEventPoster.post(up, to: target)
        throw error
      }
      ProcessTargetedEventPoster.post(up, to: target)
    }
  }
}
