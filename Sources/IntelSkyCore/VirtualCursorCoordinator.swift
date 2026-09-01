import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

protocol ComputerUseVisualizing: Sendable {
  func moveCursor(to point: CGPoint, target: ComputerUseVisualTarget)
  func showClick(at point: CGPoint, target: ComputerUseVisualTarget)
  func showDrag(from start: CGPoint, to end: CGPoint, target: ComputerUseVisualTarget)
}

struct ComputerUseVisualTarget: Sendable, Equatable {
  let processIdentifier: pid_t
  let windowID: CGWindowID?
}

public final class ComputerUseVisualCoordinator: ComputerUseVisualizing,
  ComputerUseTurnLifecycleEventHandling, @unchecked Sendable
{
  public static let shared = ComputerUseVisualCoordinator()

  private let lock = NSLock()
  private var remoteCursorHandler: (@Sendable (CGPoint, Bool, Bool) -> Bool)?
  private var remoteCursorGeneration: UInt64 = 0
  private var lifecycleGeneration: UInt64 = 0
  private var lastRemoteCursorPoint: CGPoint?
  private var cursorOwnerThreadID: String?
  private let rendersLocalOverlay: Bool
  private let localCursorSink: (@Sendable (LocalCursorCommand) -> Void)?

  public init(renderLocalOverlay: Bool = true) {
    rendersLocalOverlay = renderLocalOverlay
    localCursorSink = nil
  }

  init(
    renderLocalOverlay: Bool,
    localCursorSink: @escaping @Sendable (LocalCursorCommand) -> Void
  ) {
    rendersLocalOverlay = renderLocalOverlay
    self.localCursorSink = localCursorSink
  }

  @MainActor
  public static func warmUp() {
    _ = VirtualCursorOverlay.shared
  }

  func moveCursor(to point: CGPoint, target: ComputerUseVisualTarget) {
    notifyRemoteCursor(at: point, isPressed: false)
    if rendersLocalOverlay {
      renderLocal(.move(point, target))
    }
  }

  func showClick(at point: CGPoint, target: ComputerUseVisualTarget) {
    let generation = notifyRemoteCursor(at: point, isPressed: true)
    scheduleRemoteRelease(at: point, generation: generation, delay: 0.12)
    if rendersLocalOverlay {
      renderLocal(.click(point, target))
    }
  }

  func showDrag(from start: CGPoint, to end: CGPoint, target: ComputerUseVisualTarget) {
    let turnGeneration = lock.withLock { lifecycleGeneration }
    let ownerThreadID = ComputerUseTurnContext.threadID
    notifyRemoteCursor(at: start, isPressed: true, ownerThreadID: ownerThreadID)
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self,
        lock.withLock({ lifecycleGeneration == turnGeneration })
      else { return }
      let generation = notifyRemoteCursor(
        at: end,
        isPressed: true,
        ownerThreadID: ownerThreadID
      )
      scheduleRemoteRelease(at: end, generation: generation, delay: 0.12)
    }
    if rendersLocalOverlay {
      renderLocal(.drag(start, end, target))
    }
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    let endedThreadID: String?
    switch event {
    case .started:
      endedThreadID = nil
    case .transitioned(let previous, _), .ended(let previous),
      .safetyTerminated(let previous, _):
      endedThreadID = previous.threadID
    case .safetyRevoked:
      endedThreadID = nil
    }
    let inactive = lock.withLock {
      () -> (CGPoint?, (@Sendable (CGPoint, Bool, Bool) -> Bool)?, Bool) in
      let shouldClear: Bool
      switch event {
      case .started:
        shouldClear = cursorOwnerThreadID == nil
      case .safetyRevoked:
        shouldClear = true
      default:
        shouldClear = cursorOwnerThreadID == nil || cursorOwnerThreadID == endedThreadID
      }
      guard shouldClear else { return (nil, nil, false) }
      lifecycleGeneration &+= 1
      remoteCursorGeneration &+= 1
      let point = lastRemoteCursorPoint
      lastRemoteCursorPoint = nil
      cursorOwnerThreadID = nil
      return (point, remoteCursorHandler, true)
    }
    if let point = inactive.0 { _ = inactive.1?(point, false, false) }
    if rendersLocalOverlay, inactive.2 {
      renderLocal(.hide)
    }
  }

  private func renderLocal(_ command: LocalCursorCommand) {
    if let localCursorSink {
      localCursorSink(command)
      return
    }
    performOnMain {
      switch command {
      case .move(let point, let target):
        VirtualCursorOverlay.shared.move(to: point, target: target)
      case .click(let point, let target):
        VirtualCursorOverlay.shared.click(at: point, target: target)
      case .drag(let start, let end, let target):
        VirtualCursorOverlay.shared.drag(from: start, to: end, target: target)
      case .hide:
        VirtualCursorOverlay.shared.hideImmediately()
      }
    }
  }

  private func performOnMain(_ operation: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        operation()
      }
    }
  }

  func setRemoteCursorHandler(
    _ handler: @escaping @Sendable (CGPoint, Bool, Bool) -> Bool
  ) {
    lock.withLock { remoteCursorHandler = handler }
  }

  @discardableResult
  private func notifyRemoteCursor(
    at point: CGPoint,
    isPressed: Bool,
    ownerThreadID: String? = nil
  ) -> UInt64 {
    let (generation, handler) = lock.withLock {
      () -> (UInt64, (@Sendable (CGPoint, Bool, Bool) -> Bool)?) in
      remoteCursorGeneration &+= 1
      lastRemoteCursorPoint = point
      cursorOwnerThreadID = ownerThreadID ?? ComputerUseTurnContext.threadID
      return (remoteCursorGeneration, remoteCursorHandler)
    }
    _ = handler?(point, true, isPressed)
    return generation
  }

  private func scheduleRemoteRelease(
    at point: CGPoint,
    generation: UInt64,
    delay: TimeInterval
  ) {
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) {
      [weak self] in
      guard let self else { return }
      let handler = lock.withLock { () -> (@Sendable (CGPoint, Bool, Bool) -> Bool)? in
        guard remoteCursorGeneration == generation else { return nil }
        return remoteCursorHandler
      }
      _ = handler?(point, true, false)
    }
  }
}

enum LocalCursorCommand: Sendable, Equatable {
  case move(CGPoint, ComputerUseVisualTarget)
  case click(CGPoint, ComputerUseVisualTarget)
  case drag(CGPoint, CGPoint, ComputerUseVisualTarget)
  case hide
}

struct NoopComputerUseVisualizer: ComputerUseVisualizing {
  func moveCursor(to point: CGPoint, target: ComputerUseVisualTarget) {}
  func showClick(at point: CGPoint, target: ComputerUseVisualTarget) {}
  func showDrag(from start: CGPoint, to end: CGPoint, target: ComputerUseVisualTarget) {}
}

@MainActor
private final class VirtualCursorOverlay {
  static let shared = VirtualCursorOverlay()

  private let size = FogCursorMetrics.canvasSize
  private let hotspot = FogCursorMetrics.windowHotspot
  private let motionConfiguration = FogCursorMotionConfiguration.arm64
  private let panel: NSPanel
  private let cursorView: VirtualCursorView
  private lazy var appMonitor = VirtualCursorApplicationMonitor { [weak self] in
    self?.refreshVisibility()
  }
  private var hideGeneration: UInt64 = 0
  private var currentTarget: ComputerUseVisualTarget?
  private var wantsToBeVisible = false
  private var motionTimer: Timer?
  private var motionPath: FogCursorMotionPath?
  private var motionStartTime: TimeInterval = 0
  private var motionResponse: TimeInterval = 0
  private var motionDampingFraction: Double = 1
  private var motionUsesScoot = false
  private var motionInitialProgressVelocity: CGFloat = 0
  private var currentWindowVelocity = CGVector.zero
  private var lastMotionSampleTime: TimeInterval = 0
  private var lastMotionSamplePoint: CGPoint?

  private init() {
    cursorView = VirtualCursorView(frame: CGRect(origin: .zero, size: size))
    panel = NSPanel(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = .normal
    panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
    panel.contentView = cursorView
  }

  func move(to screenPoint: CGPoint, target: ComputerUseVisualTarget) {
    hideGeneration &+= 1
    wantsToBeVisible = true
    if currentTarget?.processIdentifier != target.processIdentifier {
      appMonitor.monitor(processIdentifier: target.processIdentifier)
    }
    let destination = windowOrigin(for: screenPoint)
    if panel.isVisible, currentTarget == target {
      let distance = hypot(
        panel.frame.origin.x - destination.x,
        panel.frame.origin.y - destination.y
      )
      if distance > 0.5 {
        beginMotion(to: destination)
      } else {
        panel.setFrameOrigin(destination)
      }
    } else {
      stopMotion()
      panel.setFrameOrigin(destination)
      panel.alphaValue = 0
    }
    currentTarget = target
    refreshVisibility()
  }

  func click(at screenPoint: CGPoint, target: ComputerUseVisualTarget) {
    move(to: screenPoint, target: target)
    cursorView.isPressed = true
    let generation = hideGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self, generation == hideGeneration else { return }
      cursorView.isPressed = false
    }
  }

  func drag(from start: CGPoint, to end: CGPoint, target: ComputerUseVisualTarget) {
    move(to: start, target: target)
    cursorView.isPressed = true
    let generation = hideGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, generation == hideGeneration else { return }
      move(to: end, target: target)
      cursorView.isPressed = false
    }
  }

  func hideImmediately() {
    hideGeneration &+= 1
    currentTarget = nil
    wantsToBeVisible = false
    appMonitor.stopMonitoring()
    cursorView.isPressed = false
    stopMotion()
    panel.alphaValue = 0
    panel.orderOut(nil)
  }

  private func windowOrigin(for quartzPoint: CGPoint) -> CGPoint {
    let cocoaPoint = Self.cocoaPoint(fromQuartzPoint: quartzPoint)
    return CGPoint(x: cocoaPoint.x - hotspot.x, y: cocoaPoint.y - hotspot.y)
  }

  private func beginMotion(to destination: CGPoint) {
    let start = panel.frame.origin
    let distance = hypot(destination.x - start.x, destination.y - start.y)
    guard distance > 0.5 else {
      panel.setFrameOrigin(destination)
      stopMotion()
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let screenBounds = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    motionUsesScoot = distance <= motionConfiguration.scootDistanceThreshold
    motionPath =
      motionUsesScoot
      ? FogCursorMotionPath.line(start: start, end: destination)
      : FogCursorMotionPath.make(
        start: start,
        end: destination,
        configuration: motionConfiguration,
        constrainedTo: screenBounds
      )
    guard let motionPath else { return }
    let direction = CGVector(
      dx: (destination.x - start.x) / distance,
      dy: (destination.y - start.y) / distance
    )
    motionInitialProgressVelocity = max(
      -2,
      min(
        2,
        (currentWindowVelocity.dx * direction.dx + currentWindowVelocity.dy * direction.dy)
          / distance)
    )
    motionStartTime = now
    motionResponse =
      motionUsesScoot
      ? motionConfiguration.scootPositionResponse
      : motionConfiguration.springResponse(
        for: motionPath,
        constrainedTo: screenBounds
      )
    motionDampingFraction =
      motionUsesScoot
      ? motionConfiguration.scootPositionDampingFraction
      : motionConfiguration.springDampingFraction
    lastMotionSampleTime = now
    lastMotionSamplePoint = start
    if motionUsesScoot {
      cursorView.beginScoot(
        direction: CGVector(dx: destination.x - start.x, dy: destination.y - start.y),
        configuration: motionConfiguration,
        at: now
      )
    }
    motionTimer?.invalidate()
    let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.advanceMotion() }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    motionTimer = timer
    advanceMotion()
  }

  private func advanceMotion() {
    guard let motionPath else {
      stopMotion()
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let sample = FogCursorSpringSample.sample(
      elapsed: now - motionStartTime,
      response: motionResponse,
      dampingFraction: motionDampingFraction,
      initialVelocity: motionInitialProgressVelocity
    )
    let progress = min(1.08, max(-0.08, sample.value))
    let point = motionPath.point(at: progress)
    let sampleDuration = max(0.000_1, now - lastMotionSampleTime)
    if let previous = lastMotionSamplePoint {
      currentWindowVelocity = CGVector(
        dx: (point.x - previous.x) / sampleDuration,
        dy: (point.y - previous.y) / sampleDuration
      )
      let pathDerivative = motionPath.derivative(at: progress)
      if motionUsesScoot {
        cursorView.updateScoot(
          progress: progress,
          direction: CGVector(
            dx: motionPath.end.x - motionPath.start.x,
            dy: motionPath.end.y - motionPath.start.y
          ),
          velocity: currentWindowVelocity,
          configuration: motionConfiguration,
          at: now
        )
      } else {
        cursorView.updatePathMotion(
          velocity: currentWindowVelocity,
          pathDerivative: pathDerivative,
          progress: progress,
          configuration: motionConfiguration
        )
      }
    }
    panel.setFrameOrigin(point)
    lastMotionSamplePoint = point
    lastMotionSampleTime = now

    if abs(1 - sample.value) < 0.001,
      abs(sample.velocity) < 0.01
        || now - motionStartTime > motionResponse * 8
    {
      panel.setFrameOrigin(motionPath.end)
      stopMotion()
    }
  }

  private func stopMotion() {
    motionTimer?.invalidate()
    motionTimer = nil
    motionPath = nil
    motionUsesScoot = false
    currentWindowVelocity = .zero
    lastMotionSamplePoint = nil
    cursorView.endMotion()
  }

  private static func cocoaPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
    for screen in NSScreen.screens {
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else { continue }
      let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
      guard displayBounds.contains(point) else { continue }
      return CGPoint(
        x: screen.frame.minX + point.x - displayBounds.minX,
        y: screen.frame.maxY - (point.y - displayBounds.minY)
      )
    }
    let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
    return CGPoint(x: point.x, y: mainDisplayHeight - point.y)
  }

  private func refreshVisibility() {
    guard let target = currentTarget else {
      panel.alphaValue = 0
      panel.orderOut(nil)
      return
    }
    let decision = VirtualCursorVisibilityPolicy.decide(
      wantsToBeVisible: wantsToBeVisible,
      targetWindowIsAvailable: targetWindowIsAvailable(target),
      applicationIsActive: appMonitor.appIsActive,
      menusOpen: appMonitor.menusOpen,
      hasTargetWindow: target.windowID != nil
    )
    guard decision.isVisible else {
      panel.alphaValue = 0
      panel.orderOut(nil)
      return
    }

    panel.level = decision.usesOverlayLevel ? NSWindow.Level(rawValue: 102) : .normal
    let wasVisible = panel.isVisible
    if decision.usesOverlayLevel || target.windowID == nil {
      panel.orderFrontRegardless()
    } else if let windowID = target.windowID {
      panel.order(.above, relativeTo: Int(windowID))
    }
    if !wasVisible {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.08
        panel.animator().alphaValue = 1
      }
    } else {
      panel.alphaValue = 1
    }
  }

  private func targetWindowIsAvailable(_ target: ComputerUseVisualTarget) -> Bool {
    guard let windowID = target.windowID else { return true }
    guard
      let descriptions = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow, .excludeDesktopElements],
        windowID
      ) as? [[String: Any]],
      let description = descriptions.first,
      (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        == target.processIdentifier,
      (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
    else { return false }
    return true
  }
}

struct VirtualCursorPresentationDecision: Equatable, Sendable {
  let isVisible: Bool
  let usesOverlayLevel: Bool
}

enum VirtualCursorVisibilityPolicy {
  static func decide(
    wantsToBeVisible: Bool,
    targetWindowIsAvailable: Bool,
    applicationIsActive: Bool,
    menusOpen: Int,
    hasTargetWindow: Bool
  ) -> VirtualCursorPresentationDecision {
    let isVisible = wantsToBeVisible && (!hasTargetWindow || targetWindowIsAvailable)
    return VirtualCursorPresentationDecision(
      isVisible: isVisible,
      usesOverlayLevel: isVisible && (applicationIsActive || menusOpen > 0)
    )
  }
}

@MainActor
private final class VirtualCursorApplicationMonitor {
  private let onChange: @MainActor () -> Void
  private var processIdentifier: pid_t?
  private var runningApplication: NSRunningApplication?
  private var axObserver: AXObserver?
  private var workspaceObservers: [NSObjectProtocol] = []
  private(set) var appIsActive = false
  private(set) var menusOpen = 0

  init(onChange: @escaping @MainActor () -> Void) {
    self.onChange = onChange
  }

  func monitor(processIdentifier: pid_t) {
    guard self.processIdentifier != processIdentifier else {
      refreshApplicationState()
      return
    }
    stopMonitoring()
    self.processIdentifier = processIdentifier
    runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
    refreshApplicationState()

    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.refreshApplicationState()
          }
        }
      )
    }
    installAccessibilityObserver(processIdentifier: processIdentifier)
  }

  func stopMonitoring() {
    let center = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers { center.removeObserver(observer) }
    workspaceObservers.removeAll()
    axObserver = nil
    processIdentifier = nil
    runningApplication = nil
    appIsActive = false
    menusOpen = 0
  }

  private func refreshApplicationState() {
    let newValue = runningApplication?.isActive == true
    if appIsActive != newValue { appIsActive = newValue }
    onChange()
  }

  private func installAccessibilityObserver(processIdentifier: pid_t) {
    var observer: AXObserver?
    let result = AXObserverCreate(
      processIdentifier,
      { _, _, notification, context in
        guard let context else { return }
        let monitor = Unmanaged<VirtualCursorApplicationMonitor>
          .fromOpaque(context).takeUnretainedValue()
        let name = notification as String
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            monitor.handleAccessibilityNotification(name)
          }
        }
      },
      &observer
    )
    guard result == .success, let observer else { return }
    let application = AXUIElementCreateApplication(processIdentifier)
    let context = Unmanaged.passUnretained(self).toOpaque()
    let opened = AXObserverAddNotification(
      observer,
      application,
      kAXMenuOpenedNotification as CFString,
      context
    )
    let closed = AXObserverAddNotification(
      observer,
      application,
      kAXMenuClosedNotification as CFString,
      context
    )
    guard opened == .success || closed == .success else { return }
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
    axObserver = observer
  }

  private func handleAccessibilityNotification(_ notification: String) {
    if notification == kAXMenuOpenedNotification as String {
      menusOpen += 1
    } else if notification == kAXMenuClosedNotification as String {
      menusOpen = max(0, menusOpen - 1)
    }
    onChange()
  }
}

@MainActor
private final class VirtualCursorView: NSView {
  private var styleState = FogCursorStyleState()
  private var scootBaseAngle: CGFloat = 0
  private var scootBaseRotationSpring = FogCursorScalarSpring(value: 0)
  private var scootAxisSpring = FogCursorScalarSpring(value: 0)
  private var scootStretchSpring = FogCursorScalarSpring(value: 1)
  private var scootRotationSpring = FogCursorScalarSpring(value: 0)

  var isPressed: Bool {
    get { styleState.isPressed }
    set {
      guard newValue != styleState.isPressed else { return }
      styleState.isPressed = newValue
      needsDisplay = true
    }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let image = FogCursorRenderer.makeImage(state: styleState) else { return }
    NSImage(cgImage: image, size: bounds.size).draw(
      in: bounds,
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
  }

  func updatePathMotion(
    velocity: CGVector,
    pathDerivative: CGVector,
    progress: CGFloat,
    configuration: FogCursorMotionConfiguration
  ) {
    styleState.velocity = velocity
    let tangent = FogCursorMotionGeometry.terminalTangent(
      pathTangent: pathDerivative,
      progress: progress,
      configuration: configuration
    )
    styleState.angle = FogCursorMotionGeometry.cursorAngle(
      for: tangent,
      clickAngleDegrees: configuration.clickAngleDegrees
    )
    styleState.scootStretchXScale = 1
    styleState.scootStretchScale = 1
    styleState.scootStretchPivotX = configuration.scootStretchPivotX
    styleState.scootStretchAngle = 0
    styleState.scootTiltAngle = 0
    needsDisplay = true
  }

  func beginScoot(
    direction: CGVector,
    configuration: FogCursorMotionConfiguration,
    at time: TimeInterval
  ) {
    let desiredAngle = FogCursorMotionGeometry.cursorAngle(
      for: direction,
      clickAngleDegrees: configuration.clickAngleDegrees
    )
    let existingAngleDegrees = styleState.angle * 180 / .pi
    scootBaseAngle = desiredAngle
    scootBaseRotationSpring.set(
      value: FogCursorMotionGeometry.wrappedDegrees(
        existingAngleDegrees - desiredAngle * 180 / .pi
      ),
      at: time
    )
    scootBaseRotationSpring.retarget(
      to: 0,
      at: time,
      response: configuration.scootBaseRotationResponse,
      dampingFraction: configuration.scootBaseRotationDampingFraction
    )

    let axis = FogCursorMotionGeometry.scootAxis(for: direction)
    scootAxisSpring.set(value: styleState.scootStretchAngle * 180 / .pi, at: time)
    scootAxisSpring.retarget(
      to: axis.angleDegrees,
      at: time,
      response: configuration.scootAxisResponse,
      dampingFraction: configuration.scootAxisDampingFraction
    )
    scootStretchSpring.set(value: styleState.scootStretchScale, at: time)
    scootRotationSpring.set(value: styleState.scootTiltAngle * 180 / .pi, at: time)
  }

  func updateScoot(
    progress: CGFloat,
    direction: CGVector,
    velocity: CGVector,
    configuration: FogCursorMotionConfiguration,
    at time: TimeInterval
  ) {
    styleState.velocity = velocity
    let envelope = FogCursorMotionGeometry.scootEnvelope(progress: progress)
    let axis = FogCursorMotionGeometry.scootAxis(for: direction)
    scootAxisSpring.retarget(
      to: axis.angleDegrees,
      at: time,
      response: configuration.scootAxisResponse,
      dampingFraction: configuration.scootAxisDampingFraction
    )
    scootStretchSpring.retarget(
      to: 1 - envelope * (1 - configuration.scootStretchMin)
        * configuration.scootSquashYAmount,
      at: time,
      response: configuration.scootStretchResponse,
      dampingFraction: configuration.scootStretchDampingFraction
    )
    scootRotationSpring.retarget(
      to: FogCursorMotionGeometry.scootTiltDegrees(
        direction: direction,
        envelope: envelope,
        maxDegrees: configuration.scootRotationMaxDegrees
      ),
      at: time,
      response: configuration.scootRotationResponse,
      dampingFraction: configuration.scootRotationDampingFraction
    )

    let baseRotation = scootBaseRotationSpring.sample(at: time).value
    let axisRotation = scootAxisSpring.sample(at: time).value
    let stretchScale = scootStretchSpring.sample(at: time).value
    let tilt = scootRotationSpring.sample(at: time).value
    styleState.angle = scootBaseAngle + baseRotation * .pi / 180
    styleState.scootStretchAngle = axisRotation * .pi / 180
    styleState.scootStretchXScale = 1 + envelope * configuration.scootStretchXAmount
    styleState.scootStretchScale = stretchScale
    styleState.scootStretchPivotX =
      (1 - envelope) * configuration.scootStretchPivotX + envelope * axis.pivot
    styleState.scootTiltAngle = tilt * .pi / 180
    needsDisplay = true
  }

  func endMotion() {
    styleState.velocity = .zero
    styleState.angle = 0
    styleState.scootStretchXScale = 1
    styleState.scootStretchScale = 1
    styleState.scootStretchPivotX = 0.5
    styleState.scootStretchAngle = 0
    styleState.scootTiltAngle = 0
    needsDisplay = true
  }
}
