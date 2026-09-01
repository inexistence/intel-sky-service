import CoreGraphics
import Foundation
import Testing

@testable import IntelSkyCore

private let cursorTarget = ComputerUseVisualTarget(processIdentifier: 42, windowID: 99)

@Test func turnBoundaryImmediatelyDeactivatesRemoteCursor() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active, pressed in
    recorder.append(point, active, pressed)
    return true
  }
  coordinator.moveCursor(to: CGPoint(x: 12, y: 34), target: cursorTarget)
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )

  coordinator.handle(.ended(identity))

  #expect(recorder.events == ["12:34:true:false", "12:34:false:false"])
}

@Test func startingScopedTurnDeactivatesLegacyUnscopedCursor() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active, pressed in
    recorder.append(point, active, pressed)
    return true
  }
  coordinator.moveCursor(to: CGPoint(x: 12, y: 34), target: cursorTarget)
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )

  coordinator.handle(.started(identity))

  #expect(recorder.events == ["12:34:true:false", "12:34:false:false"])
}

@Test func delayedDragCursorCannotReappearAcrossTurnBoundary() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active, pressed in
    recorder.append(point, active, pressed)
    return true
  }
  coordinator.showDrag(
    from: CGPoint(x: 1, y: 2),
    to: CGPoint(x: 90, y: 91),
    target: cursorTarget
  )
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )
  coordinator.handle(.ended(identity))
  Thread.sleep(forTimeInterval: 0.15)

  #expect(recorder.events == ["1:2:true:true", "1:2:false:false"])
}

@Test func clickPublishesPressedThenReleasedRemoteCursorState() {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active, pressed in
    recorder.append(point, active, pressed)
    return true
  }

  coordinator.showClick(at: CGPoint(x: 40, y: 50), target: cursorTarget)
  Thread.sleep(forTimeInterval: 0.16)

  #expect(recorder.events == ["40:50:true:true", "40:50:true:false"])
}

@Test func remotePresentationMirrorsCursorWithoutSuppressingDesktopCursor() {
  let localRecorder = LocalCursorCommandRecorder()
  let coordinator = ComputerUseVisualCoordinator(
    renderLocalOverlay: true,
    localCursorSink: { localRecorder.append($0) }
  )
  coordinator.setRemoteCursorHandler { _, _, _ in true }

  coordinator.moveCursor(to: CGPoint(x: 12, y: 34), target: cursorTarget)
  coordinator.showClick(at: CGPoint(x: 40, y: 50), target: cursorTarget)
  coordinator.showDrag(
    from: CGPoint(x: 1, y: 2),
    to: CGPoint(x: 90, y: 91),
    target: cursorTarget
  )

  #expect(
    localRecorder.commands == [
      .move(CGPoint(x: 12, y: 34), cursorTarget),
      .click(CGPoint(x: 40, y: 50), cursorTarget),
      .drag(CGPoint(x: 1, y: 2), CGPoint(x: 90, y: 91), cursorTarget),
    ]
  )
}

@Test func cursorVisibilityFollowsArm64WindowAndApplicationGates() {
  #expect(
    VirtualCursorVisibilityPolicy.decide(
      wantsToBeVisible: true,
      targetWindowIsAvailable: true,
      applicationIsActive: false,
      menusOpen: 0,
      hasTargetWindow: true
    ) == VirtualCursorPresentationDecision(isVisible: true, usesOverlayLevel: false)
  )
  #expect(
    VirtualCursorVisibilityPolicy.decide(
      wantsToBeVisible: true,
      targetWindowIsAvailable: true,
      applicationIsActive: true,
      menusOpen: 0,
      hasTargetWindow: true
    ) == VirtualCursorPresentationDecision(isVisible: true, usesOverlayLevel: true)
  )
  #expect(
    VirtualCursorVisibilityPolicy.decide(
      wantsToBeVisible: true,
      targetWindowIsAvailable: false,
      applicationIsActive: true,
      menusOpen: 1,
      hasTargetWindow: true
    ) == VirtualCursorPresentationDecision(isVisible: false, usesOverlayLevel: false)
  )
}

private final class CursorEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var events: [String] { lock.withLock { stored } }

  func append(_ point: CGPoint, _ active: Bool, _ pressed: Bool) {
    lock.withLock {
      stored.append("\(Int(point.x)):\(Int(point.y)):\(active):\(pressed)")
    }
  }
}

private final class LocalCursorCommandRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [LocalCursorCommand] = []
  var commands: [LocalCursorCommand] { lock.withLock { stored } }

  func append(_ command: LocalCursorCommand) {
    lock.withLock { stored.append(command) }
  }
}
