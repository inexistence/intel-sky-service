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
    pages: Double
  ) throws
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
  ) -> [ScrollDelta] {
    let axisExtent: Double
    switch direction {
    case .up, .down: axisExtent = screenFrame.height
    case .left, .right: axisExtent = screenFrame.width
    }
    let pageExtent = min(1_200, max(240, axisExtent * 0.8))
    let magnitude = max(1, Int32((pageExtent * pages).rounded()))
    let signedMagnitude: Int32
    switch direction {
    case .up, .left: signedMagnitude = magnitude
    case .down, .right: signedMagnitude = -magnitude
    }

    let eventCount = max(1, Int(ceil(Double(magnitude) / 10)))
    let baseDelta = signedMagnitude / Int32(eventCount)
    let remainder = signedMagnitude % Int32(eventCount)
    return (0..<eventCount).map { index in
      let remainderDelta: Int32
      if Int32(index) < abs(remainder) {
        remainderDelta = remainder.signum()
      } else {
        remainderDelta = 0
      }
      let delta = baseDelta + remainderDelta
      switch direction {
      case .up, .down: return ScrollDelta(vertical: delta, horizontal: 0)
      case .left, .right: return ScrollDelta(vertical: 0, horizontal: delta)
      }
    }
  }
}

struct CGScrollEventPoster: ScrollEventPosting {
  private let screens: any ScreenFrameProviding

  init(screens: any ScreenFrameProviding = CGScreenFrameProvider()) {
    self.screens = screens
  }

  func scroll(
    at point: CGPoint,
    direction: ComputerUseScrollDirection,
    pages: Double
  ) throws {
    guard AXIsProcessTrusted() else { throw AccessibilitySnapshotError.permissionRequired }
    guard let screen = screens.frame(containing: point) else {
      throw MacAppActionError.targetOutsideDisplays(point)
    }

    let deltas = ScrollDeltaPlan.make(screenFrame: screen, direction: direction, pages: pages)
    var events: [CGEvent] = []
    for delta in deltas {
      guard
        let event = CGEvent(
          scrollWheelEvent2Source: nil,
          units: .pixel,
          wheelCount: 2,
          wheel1: delta.vertical,
          wheel2: delta.horizontal,
          wheel3: 0
        )
      else {
        throw MacAppActionError.eventCreationFailed
      }
      event.location = point
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      events.append(event)
    }

    guard
      let move = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
      )
    else {
      throw MacAppActionError.eventCreationFailed
    }

    move.post(tap: .cghidEventTap)
    for (index, event) in events.enumerated() {
      event.post(tap: .cghidEventTap)
      if index + 1 < events.count { Thread.sleep(forTimeInterval: 0.005) }
    }
  }
}
