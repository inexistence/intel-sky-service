import AppKit
import CoreGraphics
import Foundation
import QuartzCore

protocol ComputerUseVisualizing: Sendable {
  func moveCursor(to point: CGPoint)
  func showClick(at point: CGPoint)
  func showDrag(from start: CGPoint, to end: CGPoint)
}

public final class ComputerUseVisualCoordinator: ComputerUseVisualizing, @unchecked Sendable {
  public static let shared = ComputerUseVisualCoordinator()

  private let lock = NSLock()
  private var remoteCursorHandler: (@Sendable (CGPoint, Bool) -> Void)?
  private var remoteCursorGeneration: UInt64 = 0

  public init() {}

  @MainActor
  public static func warmUp() {
    _ = VirtualCursorOverlay.shared
  }

  func moveCursor(to point: CGPoint) {
    notifyRemoteCursor(at: point)
    performOnMain { VirtualCursorOverlay.shared.move(to: point) }
  }

  func showClick(at point: CGPoint) {
    notifyRemoteCursor(at: point)
    performOnMain { VirtualCursorOverlay.shared.click(at: point) }
  }

  func showDrag(from start: CGPoint, to end: CGPoint) {
    notifyRemoteCursor(at: start)
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.notifyRemoteCursor(at: end)
    }
    performOnMain { VirtualCursorOverlay.shared.drag(from: start, to: end) }
  }

  private func performOnMain(_ operation: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        operation()
      }
    }
  }

  func setRemoteCursorHandler(
    _ handler: @escaping @Sendable (CGPoint, Bool) -> Void
  ) {
    lock.withLock { remoteCursorHandler = handler }
  }

  private func notifyRemoteCursor(at point: CGPoint) {
    let (generation, handler) = lock.withLock { () -> (UInt64, (@Sendable (CGPoint, Bool) -> Void)?) in
      remoteCursorGeneration &+= 1
      return (remoteCursorGeneration, remoteCursorHandler)
    }
    handler?(point, true)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.5) { [weak self] in
      guard let self else { return }
      let handler = lock.withLock { () -> (@Sendable (CGPoint, Bool) -> Void)? in
        guard remoteCursorGeneration == generation else { return nil }
        return remoteCursorHandler
      }
      handler?(point, false)
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

  private let size = CGSize(width: 30, height: 34)
  private let hotspot = CGPoint(x: 4, y: 29)
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
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.contentView = cursorView
  }

  func move(to screenPoint: CGPoint) {
    hideGeneration &+= 1
    let destination = windowOrigin(for: screenPoint)
    if panel.isVisible, currentPoint != nil {
      let distance = hypot(
        panel.frame.origin.x - destination.x,
        panel.frame.origin.y - destination.y
      )
      NSAnimationContext.runAnimationGroup { context in
        context.duration = min(0.35, max(0.08, TimeInterval(distance / 1_800)))
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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

  private func windowOrigin(for quartzPoint: CGPoint) -> CGPoint {
    let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
    let cocoaPoint = CGPoint(x: quartzPoint.x, y: mainDisplayHeight - quartzPoint.y)
    return CGPoint(x: cocoaPoint.x - hotspot.x, y: cocoaPoint.y - hotspot.y)
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
  var isPressed = false {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 4, y: 3))
    path.line(to: CGPoint(x: 4, y: 25))
    path.line(to: CGPoint(x: 10, y: 19))
    path.line(to: CGPoint(x: 15, y: 30))
    path.line(to: CGPoint(x: 20, y: 27))
    path.line(to: CGPoint(x: 15, y: 17))
    path.line(to: CGPoint(x: 24, y: 17))
    path.close()
    path.lineJoinStyle = .round
    (isPressed ? NSColor.systemOrange : NSColor.white).setFill()
    NSColor.black.withAlphaComponent(0.9).setStroke()
    path.lineWidth = 2
    path.fill()
    path.stroke()
  }
}
