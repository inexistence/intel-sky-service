import CoreGraphics
import Testing

@testable import IntelSkyCore

@Test func frontWindowSelectionSkipsTinyTransientAheadOfDocumentWindow() throws {
  let transient = ResolvedMacWindow(
    windowID: 1,
    screenFrame: CGRect(x: 0, y: 0, width: 52, height: 20)
  )
  let document = ResolvedMacWindow(
    windowID: 2,
    screenFrame: CGRect(x: 0, y: 0, width: 920, height: 436)
  )

  #expect(MacAppResolver.preferredFrontWindow(in: [transient, document]) == document)
}

@Test func frontWindowSelectionPreservesFrontOrderAndSoleCompactWindow() throws {
  let first = ResolvedMacWindow(
    windowID: 1,
    screenFrame: CGRect(x: 0, y: 0, width: 320, height: 240)
  )
  let second = ResolvedMacWindow(
    windowID: 2,
    screenFrame: CGRect(x: 0, y: 0, width: 920, height: 436)
  )
  let compact = ResolvedMacWindow(
    windowID: 3,
    screenFrame: CGRect(x: 0, y: 0, width: 52, height: 20)
  )

  #expect(MacAppResolver.preferredFrontWindow(in: [first, second]) == first)
  #expect(MacAppResolver.preferredFrontWindow(in: [compact]) == compact)
}
