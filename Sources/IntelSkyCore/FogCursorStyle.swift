import CoreGraphics
import Foundation
import ImageIO

enum FogCursorActivityState: Equatable, Sendable {
  case idle
  case loading
  case paused
}

// Keep this payload aligned with the ARM64 FogCursorViewModel. Some fields are only driven by
// the staged motion state machine, but retaining the complete contract avoids another model
// migration when that behavior is replicated.
struct FogCursorStyleState: Equatable, Sendable {
  var velocity = CGVector.zero
  var isPressed = false
  var activityState = FogCursorActivityState.idle
  var isAttached = true
  var angle: CGFloat = 0
  var scootStretchXScale: CGFloat = 1
  var scootStretchScale: CGFloat = 1
  var scootStretchPivotX: CGFloat = 0.5
  var scootStretchAngle: CGFloat = 0
  var scootTiltAngle: CGFloat = 0
}

enum FogCursorMetrics {
  // Recovered from ComputerUse.CursorView in the ARM64 CUA service.
  static let cursorRadius: CGFloat = 9
  static let fogRadius: CGFloat = 21
  static let canvasSize = CGSize(width: fogRadius * 6, height: fogRadius * 6)
  static let cursorScaleAnchorPoint = CGPoint(x: 0.1, y: 0.1)
  static let fogScaleAnchorPoint = CGPoint(x: 0.25, y: 0.25)

  // AgentCursor is a 12 x 14 path at (60, 58). Its first path point is the click tip.
  static let artworkHotspot = CGPoint(
    x: 60 + 12 * 0.00599,
    y: 58 + 14 * 0.15864
  )

  // SwiftUI artwork uses top-left coordinates, while CALayer anchors and NSWindow origins use
  // bottom-left coordinates on macOS.
  static let layerAnchorPoint = CGPoint(
    x: artworkHotspot.x / canvasSize.width,
    y: 1 - artworkHotspot.y / canvasSize.height
  )
  static let windowHotspot = CGPoint(
    x: artworkHotspot.x,
    y: canvasSize.height - artworkHotspot.y
  )

  static let effectiveFogScaleAnchor = centeredAnchor(
    diameter: fogRadius * 2,
    unitPoint: fogScaleAnchorPoint
  )
  static let effectiveCursorScaleAnchor = centeredAnchor(
    diameter: cursorRadius * 2,
    unitPoint: cursorScaleAnchorPoint
  )

  static func effectiveScootScaleAnchor(pivotX: CGFloat) -> CGPoint {
    centeredAnchor(
      diameter: cursorRadius * 2,
      unitPoint: CGPoint(x: min(1, max(0, pivotX)), y: 0.5)
    )
  }

  private static func centeredAnchor(diameter: CGFloat, unitPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: (canvasSize.width - diameter) * 0.5 + diameter * unitPoint.x,
      y: (canvasSize.height - diameter) * 0.5 + diameter * unitPoint.y
    )
  }
}

enum FogCursorRenderer {
  private static let referenceImage: CGImage? = {
    guard
      let data = Data(
        base64Encoded: FogCursorReference.pngBase64,
        options: .ignoreUnknownCharacters
      ),
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }()

  static func makeImage(
    state: FogCursorStyleState = FogCursorStyleState()
  ) -> CGImage? {
    guard let referenceImage else { return nil }
    if state == FogCursorStyleState() { return referenceImage }
    let width = referenceImage.width
    let height = referenceImage.height
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.interpolationQuality = .high
    draw(referenceImage: referenceImage, state: state, in: context)
    return context.makeImage()
  }

  private static func draw(
    referenceImage: CGImage,
    state: FogCursorStyleState,
    in context: CGContext
  ) {
    let canvas = CGRect(origin: .zero, size: FogCursorMetrics.canvasSize)
    let pressedScale: CGFloat = state.isPressed ? 0.7 : 1
    let attachedScale: CGFloat = state.isAttached ? 1 : 0.75
    let stateScale = pressedScale * attachedScale
    let velocityScale = velocityScale(for: state.velocity)

    context.saveGState()
    context.setAlpha(state.activityState == .paused ? 0.5 : 1)
    context.concatenate(
      transform(
        around: CGPoint(x: canvas.midX, y: canvas.midY),
        rotation: state.angle + state.scootStretchAngle + state.scootTiltAngle,
        scaleX: 1,
        scaleY: 1 / velocityScale
      )
    )
    context.concatenate(
      transform(
        around: renderingPoint(
          fromArtworkPoint: FogCursorMetrics.effectiveScootScaleAnchor(
            pivotX: state.scootStretchPivotX
          )
        ),
        scaleX: state.scootStretchXScale,
        scaleY: state.scootStretchScale
      )
    )
    context.concatenate(
      transform(
        around: renderingPoint(fromArtworkPoint: FogCursorMetrics.effectiveFogScaleAnchor),
        scaleX: stateScale,
        scaleY: stateScale
      )
    )
    context.draw(referenceImage, in: canvas)
    context.restoreGState()
  }

  // Keep the component average used by ARM64 CursorView. Opposing X/Y values intentionally
  // cancel; replacing this with vector magnitude changes the reference animation.
  static func velocityScale(for velocity: CGVector) -> CGFloat {
    let progress = min(1, abs((velocity.dx + velocity.dy) * 0.5) / 3_000)
    return 1 + progress * 1.5
  }

  private static func renderingPoint(fromArtworkPoint point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: FogCursorMetrics.canvasSize.height - point.y)
  }

  private static func transform(
    around anchor: CGPoint,
    rotation: CGFloat = 0,
    scaleX: CGFloat,
    scaleY: CGFloat
  ) -> CGAffineTransform {
    CGAffineTransform(translationX: anchor.x, y: anchor.y)
      .rotated(by: rotation)
      .scaledBy(x: scaleX, y: scaleY)
      .translatedBy(x: -anchor.x, y: -anchor.y)
  }
}
