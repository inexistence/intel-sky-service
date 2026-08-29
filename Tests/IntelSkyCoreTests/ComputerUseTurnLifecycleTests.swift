import Foundation
import Testing

@testable import IntelSkyCore

@Test func turnCoordinatorTracksStartTransitionAndExplicitEnd() throws {
  let recorder = TurnEventRecorder()
  let coordinator = ComputerUseTurnCoordinator { recorder.append($0) }
  let first = turnMetadata(session: "session", thread: "thread", turn: "turn-1")
  let second = turnMetadata(session: "session", thread: "thread", turn: "turn-2")

  coordinator.observe(metadata: first)
  coordinator.observe(metadata: first)
  coordinator.observe(metadata: second)
  coordinator.end(request: ["threadID": "other", "turnID": "turn-2"])
  #expect(coordinator.currentIdentity?.turnID == "turn-2")
  coordinator.end(request: ["threadID": "thread", "turnID": "turn-2"])
  let firstIdentity = try #require(ComputerUseTurnIdentity(metadata: first))
  let secondIdentity = try #require(ComputerUseTurnIdentity(metadata: second))

  #expect(
    recorder.events == [
      .started(firstIdentity),
      .transitioned(from: firstIdentity, to: secondIdentity),
      .ended(secondIdentity),
    ]
  )
  #expect(coordinator.currentIdentity == nil)
}

@Test func turnCoordinatorIgnoresUnscopedAndMalformedMetadata() {
  let recorder = TurnEventRecorder()
  let coordinator = ComputerUseTurnCoordinator { recorder.append($0) }

  coordinator.observe(metadata: nil)
  coordinator.observe(metadata: [:])
  coordinator.observe(metadata: ["thread_id": "thread", "turn_id": " "])
  coordinator.end(request: [:])

  #expect(recorder.events.isEmpty)
  #expect(coordinator.currentIdentity == nil)
}

private final class TurnEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ComputerUseTurnLifecycleEvent] = []

  var events: [ComputerUseTurnLifecycleEvent] { lock.withLock { stored } }

  func append(_ event: ComputerUseTurnLifecycleEvent) {
    lock.withLock { stored.append(event) }
  }
}

private func turnMetadata(session: String, thread: String, turn: String) -> [String: Any] {
  ["session_id": session, "thread_id": thread, "turn_id": turn]
}
