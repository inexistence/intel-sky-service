import CoreGraphics
import Testing

@testable import IntelSkyCore

@Test func dragUsesARMFiveEventPath() throws {
  let target = ComputerUseEventTarget(
    processIdentifier: getpid(),
    windowID: 42,
    screenFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
    activationPoint: nil
  )
  let events = try CGMouseDragPoster.events(
    from: CGPoint(x: 120, y: 240),
    to: CGPoint(x: 320, y: 440),
    target: target
  )

  #expect(events.map(\.type) == [
    .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged, .leftMouseUp,
  ])
  #expect(events.map(\.location) == [
    CGPoint(x: 120, y: 240),
    CGPoint(x: 120, y: 240),
    CGPoint(x: 220, y: 340),
    CGPoint(x: 320, y: 440),
    CGPoint(x: 320, y: 440),
  ])
  #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 0, 0, 0, 1])
  #expect(events.map { $0.getIntegerValueField(.mouseEventNumber) } == [1, 2, 2, 2, 1])
}
