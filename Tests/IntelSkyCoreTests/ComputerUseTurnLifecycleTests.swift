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

@Test func turnCoordinatorKeepsIndependentThreadsActive() throws {
  let recorder = TurnEventRecorder()
  let coordinator = ComputerUseTurnCoordinator { recorder.append($0) }
  let first = try #require(
    ComputerUseTurnIdentity(metadata: turnMetadata(session: "s1", thread: "a", turn: "1"))
  )
  let second = try #require(
    ComputerUseTurnIdentity(metadata: turnMetadata(session: "s2", thread: "b", turn: "1"))
  )

  coordinator.observe(metadata: turnMetadata(session: "s1", thread: "a", turn: "1"))
  coordinator.observe(metadata: turnMetadata(session: "s2", thread: "b", turn: "1"))
  coordinator.end(request: ["threadID": "a"])

  #expect(recorder.events == [.started(first), .started(second), .ended(first)])
  #expect(coordinator.activeIdentities == [second])
  #expect(coordinator.currentIdentity == second)
}

@Test func runtimeCoordinatorRevokesTransientStateBeforeFocusRestoration() throws {
  let recorder = StringRecorder()
  let runtime = ComputerUseTurnRuntimeCoordinator(
    preRestoreHandlers: [
      { _ in recorder.append("visual") },
      { _ in recorder.append("streams") },
    ],
    focusHandler: { _ in recorder.append("focus") }
  )
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: turnMetadata(session: "s", thread: "t", turn: "1"))
  )

  runtime.handle(.ended(identity))

  #expect(recorder.values == ["visual", "streams", "focus"])
}

@Test func concurrentTurnEventsAreDeliveredInStateTransitionOrder() {
  let recorder = TurnEventRecorder()
  let startedDelivery = DispatchSemaphore(value: 0)
  let allowStartedDeliveryToFinish = DispatchSemaphore(value: 0)
  let transitionCallReturned = DispatchSemaphore(value: 0)
  let coordinator = ComputerUseTurnCoordinator { event in
    recorder.append(event)
    if case .started = event {
      startedDelivery.signal()
      allowStartedDeliveryToFinish.wait()
    }
  }

  DispatchQueue.global().async {
    coordinator.observe(metadata: turnMetadata(session: "s", thread: "t", turn: "1"))
  }
  #expect(startedDelivery.wait(timeout: .now() + 5) == .success)
  DispatchQueue.global().async {
    coordinator.observe(metadata: turnMetadata(session: "s", thread: "t", turn: "2"))
    transitionCallReturned.signal()
  }
  #expect(transitionCallReturned.wait(timeout: .now() + 5) == .success)
  allowStartedDeliveryToFinish.signal()

  let deadline = Date().addingTimeInterval(5)
  while recorder.events.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
  #expect(recorder.events.count == 2)
  if recorder.events.count == 2 {
    #expect({ if case .started = recorder.events[0] { true } else { false } }())
    #expect({ if case .transitioned = recorder.events[1] { true } else { false } }())
  }
}

@Test func safetyTerminationRequiresFreshLifecycleEvenForSameMetadata() throws {
  let recorder = TurnEventRecorder()
  let coordinator = ComputerUseTurnCoordinator { recorder.append($0) }
  let metadata = turnMetadata(session: "s", thread: "t", turn: "1")
  let identity = try #require(ComputerUseTurnIdentity(metadata: metadata))

  coordinator.observe(metadata: metadata)
  coordinator.terminateForSafety(.screenLocked)
  #expect(coordinator.currentIdentity == nil)
  coordinator.observe(metadata: metadata)

  #expect(
    recorder.events == [
      .started(identity),
      .safetyTerminated(identity, .screenLocked),
      .started(identity),
    ]
  )
}

@Test func safetyTerminationWithoutTurnStillRevokesUnscopedRuntime() {
  let recorder = TurnEventRecorder()
  let coordinator = ComputerUseTurnCoordinator { recorder.append($0) }

  coordinator.terminateForSafety(.screenLocked)

  #expect(recorder.events == [.safetyRevoked(.screenLocked)])
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

private final class StringRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var values: [String] { lock.withLock { stored } }
  func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private func turnMetadata(session: String, thread: String, turn: String) -> [String: Any] {
  ["session_id": session, "thread_id": thread, "turn_id": turn]
}
