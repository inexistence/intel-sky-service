import CoreVideo
import Testing

@testable import IntelSkyCore

@Test func captureChangeMonitorPixelSignatureTracksFrameContents() throws {
  var pixelBuffer: CVPixelBuffer?
  let attributes: [CFString: Any] = [
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
  ]
  #expect(
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      4,
      4,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &pixelBuffer
    ) == kCVReturnSuccess
  )
  let buffer = try #require(pixelBuffer)
  try fill(buffer, value: 0x11)
  let first = try #require(NativeAppCaptureChangeMonitor.pixelSignature(buffer))
  #expect(NativeAppCaptureChangeMonitor.pixelSignature(buffer) == first)

  try fill(buffer, value: 0x22)
  #expect(NativeAppCaptureChangeMonitor.pixelSignature(buffer) != first)
}

private func fill(_ pixelBuffer: CVPixelBuffer, value: UInt8) throws {
  #expect(CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess)
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
  let address = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
  memset(
    address,
    Int32(value),
    CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
  )
}
