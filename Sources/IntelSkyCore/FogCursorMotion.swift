import CoreGraphics
import Foundation

struct FogCursorSpringSample: Equatable, Sendable {
  let value: CGFloat
  let velocity: CGFloat

  static func sample(
    elapsed: TimeInterval,
    response: TimeInterval,
    dampingFraction: Double,
    initialVelocity: CGFloat = 0
  ) -> FogCursorSpringSample {
    let response = max(0.001, response)
    let omega = 2 * Double.pi / response
    let zeta = max(0, dampingFraction)
    let time = max(0, elapsed)
    if zeta < 1 {
      let dampedOmega = omega * sqrt(max(0.000_001, 1 - zeta * zeta))
      let a = -1.0
      let b = (Double(initialVelocity) - zeta * omega) / dampedOmega
      let exponential = exp(-zeta * omega * time)
      let cosine = cos(dampedOmega * time)
      let sine = sin(dampedOmega * time)
      let displacement = exponential * (a * cosine + b * sine)
      let velocity =
        exponential
        * (-zeta * omega * (a * cosine + b * sine)
          + (-a * dampedOmega * sine + b * dampedOmega * cosine))
      return FogCursorSpringSample(value: 1 + displacement, velocity: velocity)
    }

    let exponential = exp(-omega * time)
    let b = Double(initialVelocity) - omega
    let displacement = (-1 + b * time) * exponential
    let velocity = (b - omega * (-1 + b * time)) * exponential
    return FogCursorSpringSample(value: 1 + displacement, velocity: velocity)
  }
}

struct FogCursorScalarSpring: Equatable, Sendable {
  private(set) var value: CGFloat
  private(set) var velocity: CGFloat
  private(set) var target: CGFloat
  private var startValue: CGFloat
  private var startVelocity: CGFloat
  private var startTime: TimeInterval
  private var response: TimeInterval
  private var dampingFraction: Double

  init(value: CGFloat) {
    self.value = value
    velocity = 0
    target = value
    startValue = value
    startVelocity = 0
    startTime = 0
    response = 0.1
    dampingFraction = 1
  }

  mutating func set(value: CGFloat, velocity: CGFloat = 0, at time: TimeInterval) {
    self.value = value
    self.velocity = velocity
    target = value
    startValue = value
    startVelocity = velocity
    startTime = time
  }

  mutating func retarget(
    to newTarget: CGFloat,
    at time: TimeInterval,
    response: TimeInterval,
    dampingFraction: Double
  ) {
    _ = sample(at: time)
    guard
      newTarget != target || self.response != response
        || self.dampingFraction != dampingFraction
    else { return }
    startValue = value
    startVelocity = velocity
    startTime = time
    target = newTarget
    self.response = max(0.001, response)
    self.dampingFraction = max(0, dampingFraction)
  }

  @discardableResult
  mutating func sample(at time: TimeInterval) -> FogCursorSpringSample {
    let elapsed = max(0, time - startTime)
    let omega = 2 * Double.pi / max(0.001, response)
    let zeta = dampingFraction
    let displacement = Double(startValue - target)
    let initialVelocity = Double(startVelocity)
    let sampledDisplacement: Double
    let sampledVelocity: Double

    if zeta < 1 {
      let dampedOmega = omega * sqrt(max(0.000_001, 1 - zeta * zeta))
      let sineCoefficient = (initialVelocity + zeta * omega * displacement) / dampedOmega
      let exponential = exp(-zeta * omega * elapsed)
      let cosine = cos(dampedOmega * elapsed)
      let sine = sin(dampedOmega * elapsed)
      sampledDisplacement = exponential * (displacement * cosine + sineCoefficient * sine)
      sampledVelocity =
        exponential
        * (-zeta * omega * (displacement * cosine + sineCoefficient * sine)
          + (-displacement * dampedOmega * sine + sineCoefficient * dampedOmega * cosine))
    } else {
      let linearCoefficient = initialVelocity + omega * displacement
      let exponential = exp(-omega * elapsed)
      sampledDisplacement = (displacement + linearCoefficient * elapsed) * exponential
      sampledVelocity =
        (linearCoefficient - omega * (displacement + linearCoefficient * elapsed)) * exponential
    }

    value = target + CGFloat(sampledDisplacement)
    velocity = CGFloat(sampledVelocity)
    return FogCursorSpringSample(value: value, velocity: velocity)
  }
}

enum FogCursorMotionGeometry {
  private static let radiansPerDegree = CGFloat.pi / 180
  private static let degreesPerRadian = 180 / CGFloat.pi

  static func cursorAngle(
    for vector: CGVector,
    clickAngleDegrees: CGFloat
  ) -> CGFloat {
    let normalized = normalized(
      vector, fallback: terminalVector(clickAngleDegrees: clickAngleDegrees))
    let degrees = atan2(-normalized.dy, normalized.dx) * degreesPerRadian
    return (degrees + 90 - clickAngleDegrees) * radiansPerDegree
  }

  static func terminalVector(clickAngleDegrees: CGFloat) -> CGVector {
    let radians = clickAngleDegrees * radiansPerDegree
    return CGVector(dx: sin(radians), dy: cos(radians))
  }

  static func terminalTangent(
    pathTangent: CGVector,
    progress: CGFloat,
    configuration: FogCursorMotionConfiguration
  ) -> CGVector {
    let path = normalized(
      pathTangent,
      fallback: terminalVector(clickAngleDegrees: configuration.clickAngleDegrees)
    )
    let terminal = terminalVector(clickAngleDegrees: configuration.clickAngleDegrees)
    let denominator = max(0.000_001, 1 - configuration.terminalTangentBlendStart)
    let normalizedProgress = min(
      1,
      max(0, (progress - configuration.terminalTangentBlendStart) / denominator)
    )
    let blend = 1 - pow(1 - normalizedProgress, 3)
    return normalized(
      CGVector(
        dx: path.dx * (1 - blend) + terminal.dx * blend,
        dy: path.dy * (1 - blend) + terminal.dy * blend
      ),
      fallback: terminal
    )
  }

  static func scootAxis(for vector: CGVector) -> (angleDegrees: CGFloat, pivot: CGFloat) {
    let length = hypot(vector.dx, vector.dy)
    guard length >= 0.001 else { return (0, 0.5) }
    var angle = atan2(vector.dy, vector.dx) * degreesPerRadian
    var pivot: CGFloat = 1
    while angle < -90 {
      angle += 180
      pivot = 1 - pivot
    }
    while angle > 90 {
      angle -= 180
      pivot = 1 - pivot
    }
    return (angle, pivot)
  }

  static func scootEnvelope(progress: CGFloat) -> CGFloat {
    let progress = min(1, max(0, progress))
    return min(1, progress / 0.22) * pow(max(0, 1 - progress), 0.62)
  }

  static func scootTiltDegrees(
    direction: CGVector,
    envelope: CGFloat,
    maxDegrees: CGFloat
  ) -> CGFloat {
    let direction = normalized(direction, fallback: .zero)
    let signedAmount = min(1, max(-1, 0.75 * direction.dx + 0.62 * direction.dy))
    return envelope * signedAmount * maxDegrees
  }

  static func wrappedDegrees(_ value: CGFloat) -> CGFloat {
    var value = value
    while value > 180 { value -= 360 }
    while value < -180 { value += 360 }
    return value
  }

  private static func normalized(_ vector: CGVector, fallback: CGVector) -> CGVector {
    let length = hypot(vector.dx, vector.dy)
    guard length >= 0.001 else { return fallback }
    return CGVector(dx: vector.dx / length, dy: vector.dy / length)
  }
}

struct FogCursorMotionPath: Equatable, Sendable {
  struct Segment: Equatable, Sendable {
    let start: CGPoint
    let firstControl: CGPoint
    let secondControl: CGPoint
    let end: CGPoint
  }

  struct Metrics: Equatable, Sendable {
    let length: CGFloat
    let squaredTurning: CGFloat
    let maximumTurning: CGFloat
    let totalTurning: CGFloat
    let isContained: Bool
  }

  let segments: [Segment]

  var start: CGPoint { segments[0].start }
  var end: CGPoint { segments[segments.count - 1].end }

  init(start: CGPoint, firstControl: CGPoint, secondControl: CGPoint, end: CGPoint) {
    segments = [
      Segment(
        start: start,
        firstControl: firstControl,
        secondControl: secondControl,
        end: end
      )
    ]
  }

  private init(segments: [Segment]) {
    precondition(!segments.isEmpty)
    self.segments = segments
  }

  static func make(
    start: CGPoint,
    end: CGPoint,
    configuration: FogCursorMotionConfiguration,
    constrainedTo bounds: CGRect?
  ) -> FogCursorMotionPath {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let distance = hypot(dx, dy)
    guard distance > configuration.straightPathDistanceThreshold else {
      return line(start: start, end: end)
    }

    let direction = CGVector(dx: dx / distance, dy: dy / distance)
    let clickRadians = configuration.clickAngleDegrees * .pi / 180
    let clickDirection = CGVector(dx: sin(clickRadians), dy: cos(clickRadians))
    let perpendicularSign: CGFloat =
      clickDirection.dy * direction.dx - clickDirection.dx * direction.dy >= 0 ? 1 : -1
    let perpendicular = CGVector(
      dx: -direction.dy * perpendicularSign,
      dy: direction.dx * perpendicularSign
    )
    let insetBounds = bounds?.insetBy(
      dx: configuration.boundsMargin,
      dy: configuration.boundsMargin
    )
    let startHandle = min(640, distance * configuration.startHandle, distance * 0.9)
    let endHandle = min(640, distance * configuration.endpointHandle, distance * 0.9)
    let firstBase = CGPoint(
      x: start.x + clickDirection.dx * startHandle,
      y: start.y + clickDirection.dy * startHandle
    )
    let secondBase = CGPoint(
      x: end.x - clickDirection.dx * endHandle,
      y: end.y - clickDirection.dy * endHandle
    )
    var candidates = [
      FogCursorMotionPath(
        start: start,
        firstControl: firstBase,
        secondControl: secondBase,
        end: end
      ),
      FogCursorMotionPath(
        start: start,
        firstControl: interpolate(from: start, to: firstBase, amount: 0.65),
        secondControl: interpolate(from: end, to: secondBase, amount: 0.65),
        end: end
      ),
    ]
    let arcExtent = min(520, distance * configuration.arcSize)
    let flowExtent = min(440, distance * configuration.arcFlow)
    let arcCenter = CGPoint(
      x: (start.x + end.x) * 0.5 + clickDirection.dx * startHandle * 0.16,
      y: (start.y + end.y) * 0.5 + clickDirection.dy * startHandle * 0.16
    )
    for arcWeight in [CGFloat(0.55), 0.8, 1.05] {
      for flowWeight in [CGFloat(0.65), 1, 1.35] {
        for side in [CGFloat(1), -1] {
          let arcPoint = CGPoint(
            x: arcCenter.x + perpendicular.dx * arcExtent * arcWeight * side,
            y: arcCenter.y + perpendicular.dy * arcExtent * arcWeight * side
          )
          let flow = flowExtent * flowWeight
          candidates.append(
            FogCursorMotionPath(
              segments: [
                Segment(
                  start: start,
                  firstControl: firstBase,
                  secondControl: CGPoint(
                    x: arcPoint.x - direction.dx * flow,
                    y: arcPoint.y - direction.dy * flow
                  ),
                  end: arcPoint
                ),
                Segment(
                  start: arcPoint,
                  firstControl: CGPoint(
                    x: arcPoint.x + direction.dx * flow,
                    y: arcPoint.y + direction.dy * flow
                  ),
                  secondControl: secondBase,
                  end: end
                ),
              ]
            )
          )
        }
      }
    }
    let limitedCandidates = Array(candidates.prefix(max(1, configuration.candidateCount)))
    let containedCandidates = limitedCandidates.filter {
      $0.metrics(constrainedTo: insetBounds, margin: 0).isContained
    }
    let eligibleCandidates = containedCandidates.isEmpty ? limitedCandidates : containedCandidates
    return eligibleCandidates.min { lhs, rhs in
      let lhsScore = selectionScore(
        lhs,
        bounds: insetBounds,
        clickDirection: clickDirection
      )
      let rhsScore = selectionScore(
        rhs,
        bounds: insetBounds,
        clickDirection: clickDirection
      )
      return lhsScore < rhsScore
    } ?? candidates[0]
  }

  static func line(start: CGPoint, end: CGPoint) -> FogCursorMotionPath {
    let delta = CGVector(dx: end.x - start.x, dy: end.y - start.y)
    return FogCursorMotionPath(
      start: start,
      firstControl: CGPoint(x: start.x + delta.dx / 3, y: start.y + delta.dy / 3),
      secondControl: CGPoint(x: start.x + delta.dx * 2 / 3, y: start.y + delta.dy * 2 / 3),
      end: end
    )
  }

  func point(at progress: CGFloat) -> CGPoint {
    let (segment, t) = segment(at: progress)
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT * oneMinusT
    let b = 3 * oneMinusT * oneMinusT * t
    let c = 3 * oneMinusT * t * t
    let d = t * t * t
    return CGPoint(
      x: a * segment.start.x + b * segment.firstControl.x + c * segment.secondControl.x
        + d * segment.end.x,
      y: a * segment.start.y + b * segment.firstControl.y + c * segment.secondControl.y
        + d * segment.end.y
    )
  }

  func derivative(at progress: CGFloat) -> CGVector {
    let (segment, t) = segment(at: progress)
    let oneMinusT = 1 - t
    return CGVector(
      dx: 3 * oneMinusT * oneMinusT * (segment.firstControl.x - segment.start.x)
        + 6 * oneMinusT * t * (segment.secondControl.x - segment.firstControl.x)
        + 3 * t * t * (segment.end.x - segment.secondControl.x),
      dy: 3 * oneMinusT * oneMinusT * (segment.firstControl.y - segment.start.y)
        + 6 * oneMinusT * t * (segment.secondControl.y - segment.firstControl.y)
        + 3 * t * t * (segment.end.y - segment.secondControl.y)
    )
  }

  func metrics(constrainedTo bounds: CGRect?, margin: CGFloat) -> Metrics {
    let insetBounds = bounds?.insetBy(dx: margin, dy: margin)
    var previousPoint = start
    var previousAngle: CGFloat?
    var length: CGFloat = 0
    var squaredTurning: CGFloat = 0
    var maximumTurning: CGFloat = 0
    var totalTurning: CGFloat = 0
    var contained = insetBounds?.contains(start) ?? true
    for segmentIndex in segments.indices {
      for sampleIndex in 1...24 {
        let progress =
          (CGFloat(segmentIndex) + CGFloat(sampleIndex) / 24) / CGFloat(segments.count)
        let point = point(at: progress)
        let delta = CGVector(dx: point.x - previousPoint.x, dy: point.y - previousPoint.y)
        length += hypot(delta.dx, delta.dy)
        if hypot(delta.dx, delta.dy) > 0.01 {
          let angle = atan2(delta.dy, delta.dx)
          if let previousAngle {
            var turn = angle - previousAngle
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            let magnitude = abs(turn)
            squaredTurning += turn * turn
            maximumTurning = max(maximumTurning, magnitude)
            totalTurning += magnitude
          }
          previousAngle = angle
        }
        if let insetBounds { contained = contained && insetBounds.contains(point) }
        previousPoint = point
      }
    }
    return Metrics(
      length: length,
      squaredTurning: squaredTurning,
      maximumTurning: maximumTurning,
      totalTurning: totalTurning,
      isContained: contained
    )
  }

  private static func interpolate(from start: CGPoint, to end: CGPoint, amount: CGFloat) -> CGPoint
  {
    CGPoint(
      x: start.x + (end.x - start.x) * amount,
      y: start.y + (end.y - start.y) * amount
    )
  }

  private static func selectionScore(
    _ path: FogCursorMotionPath,
    bounds: CGRect?,
    clickDirection: CGVector
  ) -> CGFloat {
    let metrics = path.metrics(constrainedTo: bounds, margin: 0)
    let chord = max(1, hypot(path.end.x - path.start.x, path.end.y - path.start.y))
    let firstTangent = path.derivative(at: 0)
    let firstTangentLength = hypot(firstTangent.dx, firstTangent.dy)
    let initialAlignment =
      firstTangentLength >= 0.001
      ? (clickDirection.dx * firstTangent.dx + clickDirection.dy * firstTangent.dy)
        / firstTangentLength
      : 1
    let initialDirectionPenalty = min(1, max(0, (-0.08 - initialAlignment) / 0.92)) * 90
    return (metrics.isContained ? 0 : 45)
      + max(0, metrics.length / chord - 1) * 320
      + metrics.squaredTurning * 140
      + metrics.maximumTurning * 180
      + metrics.totalTurning * 18
      + initialDirectionPenalty
  }

  private func segment(at progress: CGFloat) -> (Segment, CGFloat) {
    let progress = min(1, max(0, progress))
    if progress == 1 { return (segments[segments.count - 1], 1) }
    let scaled = progress * CGFloat(segments.count)
    let index = min(segments.count - 1, max(0, Int(scaled)))
    return (segments[index], scaled - CGFloat(index))
  }
}
