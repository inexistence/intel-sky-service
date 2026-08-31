import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IntelSkyCore

@Test func fogCursorRendererProducesLayeredDirectionalArtwork() throws {
  let image = try #require(FogCursorRenderer.makeImage())
  #expect(image.width == 126)
  #expect(image.height == 126)

  let pixels = try CursorPixels(image: image)
  let transparentCorner = pixels.rgba(x: 0, y: 0)
  let center = pixels.rgba(x: 63, y: 63)
  let pointerOutline = pixels.rgba(x: 60, y: 59)
  let warmRim = pixels.rgba(x: 34, y: 67)
  let coolRim = pixels.rgba(x: 78, y: 41)

  #expect(transparentCorner.a == 0)
  #expect(center.a > 220)
  #expect(center.r < 90 && center.g < 90 && center.b < 90)
  #expect(pointerOutline.r > 170 && pointerOutline.g > 170 && pointerOutline.b > 170)
  #expect(warmRim.r > warmRim.b)
  #expect(coolRim.b > coolRim.r)
}

@Test func fogCursorPressedArtworkChangesShellWithoutChangingCanvasOrHotspot() throws {
  let idle = try #require(FogCursorRenderer.makeImage())
  var state = FogCursorStyleState()
  state.isPressed = true
  let pressed = try #require(FogCursorRenderer.makeImage(state: state))

  #expect(pressed.width == idle.width)
  #expect(pressed.height == idle.height)
  #expect(abs(FogCursorMetrics.artworkHotspot.x - 60.07188) < 0.000_01)
  #expect(abs(FogCursorMetrics.artworkHotspot.y - 60.22096) < 0.000_01)
  #expect(
    abs(FogCursorMetrics.layerAnchorPoint.y - (1 - 60.22096 / 126)) < 0.000_01
  )
  #expect(idle.dataProvider?.data != pressed.dataProvider?.data)
}

@Test func fogCursorConvertsRecoveredSwiftUIAnchorsIntoOuterCanvasCoordinates() {
  #expect(abs(FogCursorMetrics.effectiveCursorScaleAnchor.x - 55.8) < 0.000_01)
  #expect(abs(FogCursorMetrics.effectiveCursorScaleAnchor.y - 55.8) < 0.000_01)
  #expect(FogCursorMetrics.effectiveFogScaleAnchor == CGPoint(x: 52.5, y: 52.5))
  #expect(
    FogCursorMetrics.effectiveScootScaleAnchor(pivotX: FogCursorStyleState().scootStretchPivotX)
      == CGPoint(x: 63, y: 63)
  )
  #expect(
    FogCursorMetrics.effectiveScootScaleAnchor(pivotX: -1)
      == CGPoint(x: 54, y: 63)
  )
  #expect(
    FogCursorMetrics.effectiveScootScaleAnchor(pivotX: 2)
      == CGPoint(x: 72, y: 63)
  )
}

@Test func fogCursorStyleDefaultsPreserveCompleteARM64StateContract() {
  let state = FogCursorStyleState()

  #expect(state.velocity == .zero)
  #expect(state.isPressed == false)
  #expect(state.activityState == .idle)
  #expect(state.isAttached)
  #expect(state.angle == 0)
  #expect(state.scootStretchXScale == 1)
  #expect(state.scootStretchScale == 1)
  #expect(state.scootStretchPivotX == 0.5)
  #expect(state.scootStretchAngle == 0)
  #expect(state.scootTiltAngle == 0)
}

@Test func fogCursorUsesRecoveredARMVelocityComponentAverage() {
  #expect(FogCursorRenderer.velocityScale(for: .zero) == 1)
  #expect(FogCursorRenderer.velocityScale(for: CGVector(dx: 3_000, dy: 3_000)) == 2.5)
  #expect(FogCursorRenderer.velocityScale(for: CGVector(dx: 3_000, dy: 0)) == 1.75)
  #expect(FogCursorRenderer.velocityScale(for: CGVector(dx: 3_000, dy: -3_000)) == 1)
}

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

private struct CursorPixels {
  struct RGBA {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
  }

  let width: Int
  let bytes: [UInt8]

  init(image: CGImage) throws {
    let pixelWidth = image.width
    let pixelHeight = image.height
    var storage = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    let rendered = storage.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: pixelWidth,
          height: pixelHeight,
          bitsPerComponent: 8,
          bytesPerRow: pixelWidth * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      return true
    }
    guard rendered else { throw RemoteHostedPIPSurfaceError.invalidImage }
    width = pixelWidth
    bytes = storage
  }

  func rgba(x: Int, y: Int) -> RGBA {
    let offset = (y * width + x) * 4
    return RGBA(
      r: bytes[offset],
      g: bytes[offset + 1],
      b: bytes[offset + 2],
      a: bytes[offset + 3]
    )
  }
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
  #expect(abs(frame.minX - (100 - FogCursorMetrics.artworkHotspot.x)) < 0.000_01)
  #expect(
    abs(
      frame.minY
        - (50 - (FogCursorMetrics.canvasSize.height - FogCursorMetrics.artworkHotspot.y))
    ) < 0.000_01
  )

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
