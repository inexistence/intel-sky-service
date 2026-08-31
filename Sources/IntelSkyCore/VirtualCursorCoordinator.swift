import AppKit
import CoreGraphics
import Foundation
import QuartzCore

protocol ComputerUseVisualizing: Sendable {
  func moveCursor(to point: CGPoint)
  func showClick(at point: CGPoint)
  func showDrag(from start: CGPoint, to end: CGPoint)
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
  private let rendersLocalOverlay: Bool

  public init(renderLocalOverlay: Bool = true) {
    rendersLocalOverlay = renderLocalOverlay
  }

  @MainActor
  public static func warmUp() {
    _ = VirtualCursorOverlay.shared
  }

  func moveCursor(to point: CGPoint) {
    let remote = notifyRemoteCursor(at: point, isPressed: false)
    if rendersLocalOverlay {
      performOnMain {
        if remote.handled {
          VirtualCursorOverlay.shared.hideImmediately()
        } else {
          VirtualCursorOverlay.shared.move(to: point)
        }
      }
    }
  }

  func showClick(at point: CGPoint) {
    let remote = notifyRemoteCursor(at: point, isPressed: true)
    scheduleRemoteRelease(at: point, generation: remote.generation, delay: 0.12)
    if rendersLocalOverlay {
      performOnMain {
        if remote.handled {
          VirtualCursorOverlay.shared.hideImmediately()
        } else {
          VirtualCursorOverlay.shared.click(at: point)
        }
      }
    }
  }

  func showDrag(from start: CGPoint, to end: CGPoint) {
    let turnGeneration = lock.withLock { lifecycleGeneration }
    let remote = notifyRemoteCursor(at: start, isPressed: true)
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self,
        lock.withLock({ lifecycleGeneration == turnGeneration })
      else { return }
      let endState = notifyRemoteCursor(at: end, isPressed: true)
      scheduleRemoteRelease(at: end, generation: endState.generation, delay: 0.12)
    }
    if rendersLocalOverlay {
      performOnMain {
        if remote.handled {
          VirtualCursorOverlay.shared.hideImmediately()
        } else {
          VirtualCursorOverlay.shared.drag(from: start, to: end)
        }
      }
    }
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    let inactive = lock.withLock {
      () -> (CGPoint?, (@Sendable (CGPoint, Bool, Bool) -> Bool)?) in
      lifecycleGeneration &+= 1
      remoteCursorGeneration &+= 1
      let point = lastRemoteCursorPoint
      lastRemoteCursorPoint = nil
      return (point, remoteCursorHandler)
    }
    if let point = inactive.0 { _ = inactive.1?(point, false, false) }
    if rendersLocalOverlay {
      performOnMain { VirtualCursorOverlay.shared.hideImmediately() }
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

  private func notifyRemoteCursor(
    at point: CGPoint,
    isPressed: Bool
  ) -> (handled: Bool, generation: UInt64) {
    let (generation, handler) = lock.withLock {
      () -> (UInt64, (@Sendable (CGPoint, Bool, Bool) -> Bool)?) in
      remoteCursorGeneration &+= 1
      lastRemoteCursorPoint = point
      return (remoteCursorGeneration, remoteCursorHandler)
    }
    let handled = handler?(point, true, isPressed) ?? false
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.5) { [weak self] in
      guard let self else { return }
      let handler = lock.withLock { () -> (@Sendable (CGPoint, Bool, Bool) -> Bool)? in
        guard remoteCursorGeneration == generation else { return nil }
        return remoteCursorHandler
      }
      _ = handler?(point, false, false)
    }
    return (handled, generation)
  }

  private func scheduleRemoteRelease(
    at point: CGPoint,
    generation: UInt64,
    delay: TimeInterval
  ) {
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      let handler = lock.withLock { () -> (@Sendable (CGPoint, Bool, Bool) -> Bool)? in
        guard remoteCursorGeneration == generation else { return nil }
        return remoteCursorHandler
      }
      _ = handler?(point, true, false)
    }
  }
}

struct NoopComputerUseVisualizer: ComputerUseVisualizing {
  func moveCursor(to point: CGPoint) {}
  func showClick(at point: CGPoint) {}
  func showDrag(from start: CGPoint, to end: CGPoint) {}
}

@MainActor
private final class VirtualCursorOverlay {
  static let shared = VirtualCursorOverlay()

  private let size = FogCursorMetrics.canvasSize
  private let hotspot = FogCursorMetrics.windowHotspot
  private let panel: NSPanel
  private let cursorView: VirtualCursorView
  private var hideGeneration: UInt64 = 0
  private var currentPoint: CGPoint?

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
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.contentView = cursorView
  }

  func move(to screenPoint: CGPoint) {
    hideGeneration &+= 1
    let destination = windowOrigin(for: screenPoint)
    if panel.isVisible, let currentPoint {
      let distance = hypot(
        panel.frame.origin.x - destination.x,
        panel.frame.origin.y - destination.y
      )
      let duration = min(0.42, max(0.1, TimeInterval(distance / 1_650)))
      if distance > 0.5 {
        cursorView.beginMotion(from: currentPoint, to: screenPoint, duration: duration)
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(
          controlPoints: 0.2,
          0.82,
          0.2,
          1
        )
        panel.animator().setFrameOrigin(destination)
      }
    } else {
      panel.setFrameOrigin(destination)
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.08
        panel.animator().alphaValue = 1
      }
    }
    currentPoint = screenPoint
    scheduleHide()
  }

  func click(at screenPoint: CGPoint) {
    move(to: screenPoint)
    cursorView.isPressed = true
    let generation = hideGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self, generation == hideGeneration else { return }
      cursorView.isPressed = false
    }
  }

  func drag(from start: CGPoint, to end: CGPoint) {
    move(to: start)
    cursorView.isPressed = true
    let generation = hideGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, generation == hideGeneration else { return }
      move(to: end)
      cursorView.isPressed = false
    }
  }

  func hideImmediately() {
    hideGeneration &+= 1
    currentPoint = nil
    cursorView.isPressed = false
    cursorView.endMotion()
    panel.alphaValue = 0
    panel.orderOut(nil)
  }

  private func windowOrigin(for quartzPoint: CGPoint) -> CGPoint {
    let cocoaPoint = Self.cocoaPoint(fromQuartzPoint: quartzPoint)
    return CGPoint(x: cocoaPoint.x - hotspot.x, y: cocoaPoint.y - hotspot.y)
  }

  private static func cocoaPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
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

  private func scheduleHide() {
    let generation = hideGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
      guard let self, generation == hideGeneration else { return }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = 0.18
          panel.animator().alphaValue = 0
        },
        completionHandler: { [weak self] in
          guard let self, generation == hideGeneration else { return }
          panel.orderOut(nil)
          currentPoint = nil
        }
      )
    }
  }
}

@MainActor
private final class VirtualCursorView: NSView {
  private var styleState = FogCursorStyleState()
  private var motionGeneration: UInt64 = 0

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

  func beginMotion(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
    motionGeneration &+= 1
    let generation = motionGeneration
    let dx = end.x - start.x
    let dy = end.y - start.y
    let seconds = max(0.001, duration)
    styleState.velocity = CGVector(dx: dx / seconds, dy: dy / seconds)
    styleState.angle = atan2(-dy, dx) * 0.055
    styleState.scootStretchXScale = 1.07
    styleState.scootStretchScale = 0.97
    styleState.scootStretchPivotX = dx < 0 ? 0.7 : 0.3
    needsDisplay = true

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
      guard let self, generation == motionGeneration else { return }
      endMotion()
    }
  }

  func endMotion() {
    motionGeneration &+= 1
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
