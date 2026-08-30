import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IntelSkyCore

@Test func pipSurfaceAppliesInitialFallbackImageToPublishedContext() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("png")
  defer { try? FileManager.default.removeItem(at: url) }
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil,
      width: 2,
      height: 3,
      bitsPerComponent: 8,
      bytesPerRow: 8,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  )
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))

  let surface = try RemoteHostedPIPSurface(imageURL: url)

  #expect(surface.size == CGSize(width: 2, height: 3))
  #expect(surface.hasImageContents)
}

@Test func pipSurfaceCreatesARealCAContextWithoutDesktopCapture() throws {
  let surface = try RemoteHostedPIPSurface(size: CGSize(width: 640, height: 480))

  #expect(surface.contextID != 0)
  #expect(surface.size == CGSize(width: 640, height: 480))
}

@Test func pipSurfaceSeparatesSourcePresentationAndRetinaCaptureSizes() throws {
  let surface = try RemoteHostedPIPSurface(size: CGSize(width: 1_702, height: 1_378))

  #expect(surface.setMaximumDisplayDimension(200))
  #expect(surface.sourceSize == CGSize(width: 1_702, height: 1_378))
  #expect(surface.size == CGSize(width: 200, height: 162))
  #expect(surface.captureOutputSize == CGSize(width: 400, height: 324))
}

@Test func pipSurfaceMapsGlobalCursorIntoPresentationAndTracksPressedState() throws {
  let surface = try RemoteHostedPIPSurface(size: CGSize(width: 1_000, height: 500))
  #expect(surface.hasCursorContents)
  #expect(surface.usesCAIOSurfaceCursorContents)
  surface.setMaximumDisplayDimension(200)
  surface.updateTargetBounds(CGRect(x: 100, y: 200, width: 1_000, height: 500))

  surface.updateCursor(
    screenPoint: CGPoint(x: 600, y: 450),
    isActive: true,
    isPressed: true
  )

  let frame = try #require(surface.cursorFrame)
  #expect(surface.isCursorVisible)
  #expect(surface.isCursorPressed)
  #expect(frame.midX > 80 && frame.midX < 120)
  #expect(frame.midY > 35 && frame.midY < 65)

  surface.updateCursor(
    screenPoint: CGPoint(x: 50, y: 50),
    isActive: true,
    isPressed: false
  )
  #expect(!surface.isCursorVisible)
  #expect(surface.cursorFrame == nil)
}

@Test func pipSurfaceCursorPixelBufferPreservesTopToBottomImageOrientation() throws {
  let rgba: [UInt8] = [
    255, 0, 0, 255,  // top: red
    0, 0, 255, 255,  // bottom: blue
  ]
  let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
  let image = try #require(
    CGImage(
      width: 1,
      height: 2,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  )
  let buffer = try #require(RemoteHostedPIPSurface.makeCursorPixelBuffer(from: image))
  #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  let bytes = try #require(CVPixelBufferGetBaseAddress(buffer))
    .assumingMemoryBound(to: UInt8.self)
  let stride = CVPixelBufferGetBytesPerRow(buffer)

  #expect(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [0, 0, 255, 255])
  #expect(Array(UnsafeBufferPointer(start: bytes + stride, count: 4)) == [255, 0, 0, 255])
}

@Test func pipCaptureRefreshPlanSkipsSteadyWindowEnumeration() {
  #expect(
    RemoteHostedPIPWindowCapture.refreshPlan(
      capturedWindowID: 42,
      configuredOutputSize: CGSize(width: 400, height: 200),
      currentWindowID: 42,
      desiredOutputSize: CGSize(width: 400, height: 200)
    ) == .noChange
  )
  #expect(
    RemoteHostedPIPWindowCapture.refreshPlan(
      capturedWindowID: 42,
      configuredOutputSize: CGSize(width: 400, height: 200),
      currentWindowID: 42,
      desiredOutputSize: CGSize(width: 400, height: 180)
    ) == .updateConfiguration
  )
  #expect(
    RemoteHostedPIPWindowCapture.refreshPlan(
      capturedWindowID: 42,
      configuredOutputSize: CGSize(width: 400, height: 200),
      currentWindowID: nil,
      desiredOutputSize: CGSize(width: 400, height: 200)
    ) == .noChange
  )
  #expect(
    RemoteHostedPIPWindowCapture.refreshPlan(
      capturedWindowID: 42,
      configuredOutputSize: CGSize(width: 400, height: 200),
      currentWindowID: nil,
      desiredOutputSize: CGSize(width: 400, height: 180)
    ) == .updateConfiguration
  )
  #expect(
    RemoteHostedPIPWindowCapture.refreshPlan(
      capturedWindowID: 42,
      configuredOutputSize: CGSize(width: 400, height: 200),
      currentWindowID: 43,
      desiredOutputSize: CGSize(width: 400, height: 200)
    ) == .reconcileWindow
  )
}

@Test func pipSurfaceEnqueuesShareableVideoAndRestoresFallbackVisibility() throws {
  let surface = try RemoteHostedPIPSurface(size: CGSize(width: 8, height: 6))
  var pixelBuffer: CVPixelBuffer?
  let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
  #expect(
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      8,
      6,
      kCVPixelFormatType_32BGRA,
      attributes,
      &pixelBuffer
    ) == kCVReturnSuccess
  )
  let buffer = try #require(pixelBuffer)
  var formatDescription: CMVideoFormatDescription?
  #expect(
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescriptionOut: &formatDescription
    ) == noErr
  )
  var timing = CMSampleTimingInfo(
    duration: .invalid,
    presentationTimeStamp: .zero,
    decodeTimeStamp: .invalid
  )
  var sampleBuffer: CMSampleBuffer?
  #expect(
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescription: try #require(formatDescription),
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    ) == noErr
  )

  #expect(surface.enqueue(try #require(sampleBuffer)))
  #expect(surface.hasDisplayFrame)
  #expect(surface.hasIOSurfaceContents)
  #expect(surface.usesCAIOSurfaceContents)
  surface.resetToFallbackImage()
  #expect(!surface.hasDisplayFrame)
}
