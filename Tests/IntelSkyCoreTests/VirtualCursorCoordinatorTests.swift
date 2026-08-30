import CoreGraphics
import Foundation
import Testing

@testable import IntelSkyCore

@Test func turnBoundaryImmediatelyDeactivatesRemoteCursor() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active, pressed in
    recorder.append(point, active, pressed)
    return true
  }
  coordinator.moveCursor(to: CGPoint(x: 12, y: 34))
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )

  coordinator.handle(.ended(identity))

  #expect(recorder.events == ["12:34:true:false", "12:34:false:false"])
}

@Test func delayedDragCursorCannotReappearAcrossTurnBoundary() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active, pressed in
    recorder.append(point, active, pressed)
    return true
  }
  coordinator.showDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 90, y: 91))
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

  coordinator.showClick(at: CGPoint(x: 40, y: 50))
  Thread.sleep(forTimeInterval: 0.16)

  #expect(recorder.events == ["40:50:true:true", "40:50:true:false"])
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
