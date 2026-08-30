import CoreGraphics
import Testing

@testable import IntelSkyCore

@Test func compositeScreenshotIncludesOnlyIntersectingTransientWindowsFromTargetProcess() {
  let primaryFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
  let windows = [
    WindowCaptureCandidate(
      windowID: 20,
      processIdentifier: 42,
      layer: 101,
      frame: CGRect(x: 150, y: 150, width: 120, height: 200)
    ),
    WindowCaptureCandidate(
      windowID: 21,
      processIdentifier: 42,
      layer: 3,
      frame: CGRect(x: 550, y: 200, width: 100, height: 100)
    ),
    WindowCaptureCandidate(
      windowID: 22,
      processIdentifier: 99,
      layer: 101,
      frame: CGRect(x: 150, y: 150, width: 120, height: 200)
    ),
    WindowCaptureCandidate(
      windowID: 23,
      processIdentifier: 42,
      layer: 101,
      frame: CGRect(x: 700, y: 700, width: 100, height: 100)
    ),
    WindowCaptureCandidate(
      windowID: 24,
      processIdentifier: 42,
      layer: 101,
      alpha: 0,
      frame: CGRect(x: 150, y: 150, width: 120, height: 200)
    ),
    WindowCaptureCandidate(
      windowID: 10,
      processIdentifier: 42,
      layer: 0,
      frame: primaryFrame
    ),
    WindowCaptureCandidate(
      windowID: 25,
      processIdentifier: 42,
      layer: 0,
      frame: CGRect(x: 120, y: 120, width: 300, height: 200)
    ),
  ]

  let result = WindowScreenshotter.additionalWindowIDs(
    in: windows,
    primaryWindowID: 10,
    processIdentifier: 42,
    primaryFrame: primaryFrame
  )

  #expect(result == [20, 21])
}
