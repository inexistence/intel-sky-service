import CoreGraphics
import Testing

@testable import IntelSkyCore

@Test func scrollUsesARMHIDSystemEventSource() {
  #expect(CGScrollEventPoster.eventSourceStateID == .hidSystemState)
}

@Test func verticalScrollPlanUsesARMVisibleExtentAndSingleDelta() {
  let frame = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
  let down = ScrollDeltaPlan.make(screenFrame: frame, direction: .down, pages: 1.5)
  let up = ScrollDeltaPlan.make(screenFrame: frame, direction: .up, pages: 1.5)

  #expect(down == ScrollDelta(vertical: 1_500, horizontal: 0))
  #expect(up == ScrollDelta(vertical: -1_500, horizontal: 0))
}

@Test func horizontalScrollPlanUsesExpectedAxisAndSign() {
  let frame = CGRect(x: 0, y: 0, width: 500, height: 1_000)
  let left = ScrollDeltaPlan.make(screenFrame: frame, direction: .left, pages: 1)
  let right = ScrollDeltaPlan.make(screenFrame: frame, direction: .right, pages: 1)

  #expect(left == ScrollDelta(vertical: 0, horizontal: -500))
  #expect(right == ScrollDelta(vertical: 0, horizontal: 500))
}

@Test func scrollPlanBoundsTinyAndLargeDisplayPageExtents() {
  let tiny = ScrollDeltaPlan.make(
    screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
    direction: .down,
    pages: 1
  )
  let large = ScrollDeltaPlan.make(
    screenFrame: CGRect(x: 0, y: 0, width: 8_000, height: 8_000),
    direction: .down,
    pages: 1
  )

  #expect(tiny == ScrollDelta(vertical: 100, horizontal: 0))
  #expect(large == ScrollDelta(vertical: 8_000, horizontal: 0))
}

@Test func scrollPlanUsesARMTruncationForSubpixelRequests() {
  let delta = ScrollDeltaPlan.make(
    screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
    direction: .down,
    pages: 0.001
  )

  #expect(delta == ScrollDelta(vertical: 0, horizontal: 0))
}
