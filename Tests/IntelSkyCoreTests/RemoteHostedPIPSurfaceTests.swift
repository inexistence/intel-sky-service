import CoreGraphics
import Testing

@testable import IntelSkyCore

@Test func pipSurfaceCreatesARealCAContextWithoutDesktopCapture() throws {
  let surface = try RemoteHostedPIPSurface(size: CGSize(width: 640, height: 480))

  #expect(surface.contextID != 0)
  #expect(surface.size == CGSize(width: 640, height: 480))
}
