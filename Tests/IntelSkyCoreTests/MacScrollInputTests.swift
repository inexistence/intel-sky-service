import CoreGraphics
import Testing

@testable import IntelSkyCore

@Test func verticalScrollPlanUsesSmallDeltasWithExactTotal() {
  let frame = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
  let down = ScrollDeltaPlan.make(screenFrame: frame, direction: .down, pages: 1.5)
  let up = ScrollDeltaPlan.make(screenFrame: frame, direction: .up, pages: 1.5)

  #expect(down.reduce(0) { $0 + $1.vertical } == -1_200)
  #expect(up.reduce(0) { $0 + $1.vertical } == 1_200)
  #expect(down.allSatisfy { (-10...10).contains($0.vertical) && $0.horizontal == 0 })
}

@Test func horizontalScrollPlanUsesExpectedAxisAndSign() {
  let frame = CGRect(x: 0, y: 0, width: 500, height: 1_000)
  let left = ScrollDeltaPlan.make(screenFrame: frame, direction: .left, pages: 1)
  let right = ScrollDeltaPlan.make(screenFrame: frame, direction: .right, pages: 1)

  #expect(left.reduce(0) { $0 + $1.horizontal } == 400)
  #expect(right.reduce(0) { $0 + $1.horizontal } == -400)
  #expect(left.allSatisfy { $0.vertical == 0 && (1...10).contains($0.horizontal) })
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

  #expect(tiny.reduce(0) { $0 + $1.vertical } == -240)
  #expect(large.reduce(0) { $0 + $1.vertical } == -1_200)
}
