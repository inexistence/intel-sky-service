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

  // AgentCursor is a 12 x 14 path at (60, 58). Keep its tip available for artwork-level tests,
  // but FogCursorStyle.hotSpot in the ARM64 service is the center of hostingView's intrinsic
  // content size, not the arrow tip.
  static let artworkHotspot = CGPoint(
    x: 60 + 12 * 0.00599,
    y: 58 + 14 * 0.15864
  )
  static let interactionHotspot = CGPoint(
    x: canvasSize.width * 0.5,
    y: canvasSize.height * 0.5
  )

  // SwiftUI artwork uses top-left coordinates, while CALayer anchors and NSWindow origins use
  // bottom-left coordinates on macOS.
  static let layerAnchorPoint = CGPoint(
    x: interactionHotspot.x / canvasSize.width,
    y: 1 - interactionHotspot.y / canvasSize.height
  )
  static let windowHotspot = CGPoint(
    x: interactionHotspot.x,
    y: canvasSize.height - interactionHotspot.y
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

struct FogCursorMotionConfiguration: Equatable, Sendable {
  var clickAngleDegrees: CGFloat
  var candidateCount: Int
  var boundsMargin: CGFloat
  var startHandle: CGFloat
  var endpointHandle: CGFloat
  var arcSize: CGFloat
  var arcFlow: CGFloat
  var straightPathDistanceThreshold: CGFloat
  var springResponseScaler: Double
  var springResponseMin: Double
  var springResponseMax: Double
  var springDampingFraction: Double
  var scootDistanceThreshold: CGFloat
  var scootPositionResponse: Double
  var scootPositionDampingFraction: Double
  var scootPositionSettleVelocity: CGFloat
  var scootAxisResponse: Double
  var scootAxisDampingFraction: Double
  var scootBaseRotationResponse: Double
  var scootBaseRotationDampingFraction: Double
  var scootStretchResponse: Double
  var scootStretchDampingFraction: Double
  var scootStretchMin: CGFloat
  var scootStretchPivotX: CGFloat
  var scootStretchXAmount: CGFloat
  var scootSquashYAmount: CGFloat
  var scootRotationResponse: Double
  var scootRotationDampingFraction: Double
  var scootRotationMaxDegrees: CGFloat
  var terminalTangentBlendStart: CGFloat

  // Byte-for-byte values recovered from MotionConfiguration.live in the arm64 service.
  static let arm64 = FogCursorMotionConfiguration(
    clickAngleDegrees: -44,
    candidateCount: 20,
    boundsMargin: 20,
    startHandle: 0.419_602_950_316,
    endpointHandle: 0.15,
    arcSize: 0.276_552_318_806,
    arcFlow: 0.578_355_532_787,
    straightPathDistanceThreshold: 10,
    springResponseScaler: 0.9,
    springResponseMin: 0.12,
    springResponseMax: 2.2,
    springDampingFraction: 0.9,
    scootDistanceThreshold: 196,
    scootPositionResponse: 0.24,
    scootPositionDampingFraction: 0.84,
    scootPositionSettleVelocity: 12,
    scootAxisResponse: 0.07,
    scootAxisDampingFraction: 0.82,
    scootBaseRotationResponse: 0.09,
    scootBaseRotationDampingFraction: 0.86,
    scootStretchResponse: 0.095,
    scootStretchDampingFraction: 0.72,
    scootStretchMin: 0,
    scootStretchPivotX: 0.5,
    scootStretchXAmount: 0.38,
    scootSquashYAmount: 0.18,
    scootRotationResponse: 0.055,
    scootRotationDampingFraction: 0.76,
    scootRotationMaxDegrees: 76,
    terminalTangentBlendStart: 0.99
  )

  func springResponse(
    for path: FogCursorMotionPath,
    constrainedTo bounds: CGRect?
  ) -> TimeInterval {
    let metrics = path.metrics(constrainedTo: bounds, margin: boundsMargin)
    let straightDistance = max(1, hypot(path.end.x - path.start.x, path.end.y - path.start.y))
    let detour = max(0, metrics.length / straightDistance - 1)
    let lengthProgress = min(1, max(0, (metrics.length - 180) / 760))
    let detourProgress = min(1, detour / 0.55)
    let turningProgress = min(1, metrics.totalTurning / (1.4 * .pi))
    let squaredTurningProgress = min(1, metrics.squaredTurning / 1.25)
    let clickRadians = clickAngleDegrees * .pi / 180
    let deltaLength = max(
      0.001,
      hypot(path.end.x - path.start.x, path.end.y - path.start.y)
    )
    let alignment =
      (path.end.x - path.start.x) / deltaLength * sin(clickRadians)
      + (path.end.y - path.start.y) / deltaLength * cos(clickRadians)
    let reverseAlignment = min(1, max(0, (-0.08 - alignment) / 0.92))
    let complexity = max(
      0,
      detourProgress * 0.42 + turningProgress * 0.38 + squaredTurningProgress * 0.2
    )
    let containedMultiplier = metrics.isContained ? 1.0 : 0.9
    let containmentAdjustment = metrics.isContained ? 0.0 : 0.04
    let unscaled =
      reverseAlignment * 0.28 + 0.42 + lengthProgress * 0.22
      + min(complexity, 1) * 0.12 + containmentAdjustment
    return min(
      springResponseMax,
      max(springResponseMin, springResponseScaler * containedMultiplier * unscaled)
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
