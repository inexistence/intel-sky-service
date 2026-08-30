import CoreGraphics
import Foundation
import Testing

@testable import IntelSkyCore

@Test func turnBoundaryImmediatelyDeactivatesRemoteCursor() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active in recorder.append(point, active) }
  coordinator.moveCursor(to: CGPoint(x: 12, y: 34))
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )

  coordinator.handle(.ended(identity))

  #expect(recorder.events == ["12:34:true", "12:34:false"])
}

@Test func delayedDragCursorCannotReappearAcrossTurnBoundary() throws {
  let recorder = CursorEventRecorder()
  let coordinator = ComputerUseVisualCoordinator(renderLocalOverlay: false)
  coordinator.setRemoteCursorHandler { point, active in recorder.append(point, active) }
  coordinator.showDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 90, y: 91))
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )
  coordinator.handle(.ended(identity))
  Thread.sleep(forTimeInterval: 0.15)

  #expect(recorder.events == ["1:2:true", "1:2:false"])
}

private final class CursorEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var events: [String] { lock.withLock { stored } }

  func append(_ point: CGPoint, _ active: Bool) {
    lock.withLock {
      stored.append("\(Int(point.x)):\(Int(point.y)):\(active)")
    }
  }
}
