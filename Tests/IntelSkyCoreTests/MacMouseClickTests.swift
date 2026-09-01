import CoreGraphics
import Testing

@testable import IntelSkyCore

private func clickTestTarget() -> ComputerUseEventTarget {
  ComputerUseEventTarget(
    processIdentifier: getpid(),
    windowID: 42,
    screenFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
    activationPoint: nil
  )
}

@Test func clickUsesARMEventNumbersAndClickCounts() throws {
  let target = clickTestTarget()
  let events = try CGMouseClickPoster.events(
    at: CGPoint(x: 120, y: 240),
    button: .left,
    count: 4,
    target: target
  )

  #expect(events.map(\.type) == [
    .leftMouseDown, .leftMouseUp,
    .leftMouseDown, .leftMouseUp,
    .leftMouseDown, .leftMouseUp,
    .leftMouseDown, .leftMouseUp,
  ])
  #expect(events.map { $0.getIntegerValueField(.mouseEventNumber) } == [1, 1, 2, 2, 3, 3, 4, 4])
  #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2, 3, 3, 4, 4])
}

@Test func clickEventBuilderRejectsNonpositiveCountsWithoutTrapping() {
  #expect(throws: MacAppActionError.self) {
    try CGMouseClickPoster.events(
      at: CGPoint(x: 10, y: 20),
      button: .left,
      count: 0,
      target: clickTestTarget()
    )
  }
}
