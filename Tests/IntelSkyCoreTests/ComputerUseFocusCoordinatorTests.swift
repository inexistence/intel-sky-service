import ApplicationServices
import Foundation
import Testing

@testable import IntelSkyCore

@Test func turnEndRestoresOnlyFromControlledFrontmostApp() throws {
  let environment = RecordingFocusEnvironment(frontmostPID: 10)
  let monitor = MutableInterventionMonitor()
  let coordinator = ComputerUseFocusCoordinator(
    environment: environment,
    interventionMonitor: monitor
  )
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))

  coordinator.handle(.started(identity))
  coordinator.targetWillBeActivated(focusTestApp(pid: 20))
  environment.frontmostPID = 20
  coordinator.handle(.ended(identity))

  #expect(environment.restoredProcessIdentifiers == [10])
}

@Test func userFocusChangePreventsTurnEndRestore() throws {
  let environment = RecordingFocusEnvironment(frontmostPID: 10)
  let coordinator = ComputerUseFocusCoordinator(
    environment: environment,
    interventionMonitor: MutableInterventionMonitor()
  )
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))

  coordinator.handle(.started(identity))
  coordinator.targetWillBeActivated(focusTestApp(pid: 20))
  environment.frontmostPID = 30
  coordinator.handle(.ended(identity))

  #expect(environment.restoredProcessIdentifiers.isEmpty)
}

@Test func physicalInputPreventsTurnEndRestore() throws {
  let environment = RecordingFocusEnvironment(frontmostPID: 10)
  let monitor = MutableInterventionMonitor()
  let coordinator = ComputerUseFocusCoordinator(
    environment: environment,
    interventionMonitor: monitor
  )
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))

  coordinator.handle(.started(identity))
  coordinator.targetWillBeActivated(focusTestApp(pid: 20))
  environment.frontmostPID = 20
  monitor.generation += 1
  coordinator.handle(.ended(identity))

  #expect(environment.restoredProcessIdentifiers.isEmpty)
}

@Test func turnTransitionRestoresPreviousAndCapturesFreshTarget() throws {
  let environment = RecordingFocusEnvironment(frontmostPID: 10)
  let coordinator = ComputerUseFocusCoordinator(
    environment: environment,
    interventionMonitor: MutableInterventionMonitor()
  )
  let first = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn-1")))
  let second = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn-2")))

  coordinator.handle(.started(first))
  coordinator.targetWillBeActivated(focusTestApp(pid: 20))
  environment.frontmostPID = 20
  coordinator.handle(.transitioned(from: first, to: second))
  environment.frontmostPID = 30
  coordinator.targetWillBeActivated(focusTestApp(pid: 40))
  environment.frontmostPID = 40
  coordinator.handle(.ended(second))

  #expect(environment.restoredProcessIdentifiers == [10, 30])
}

@Test func safetyTerminationNeverRestoresFocus() throws {
  let environment = RecordingFocusEnvironment(frontmostPID: 10)
  let coordinator = ComputerUseFocusCoordinator(
    environment: environment,
    interventionMonitor: MutableInterventionMonitor()
  )
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))
  coordinator.handle(.started(identity))
  coordinator.targetWillBeActivated(focusTestApp(pid: 20))
  environment.frontmostPID = 20

  coordinator.handle(.safetyTerminated(identity, .screenLocked))
  coordinator.handle(.ended(identity))

  #expect(environment.restoredProcessIdentifiers.isEmpty)
}

@Test func syntheticFocusLeaseSpansActionsUntilTurnEnd() throws {
  let events = RecordingSyntheticFocusEvents()
  let coordinator = focusCoordinator(syntheticEvents: events)
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))
  let target = focusEventTarget(pid: 20, windowID: 200)
  let expected = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)

  coordinator.handle(.started(identity))
  _ = try coordinator.withTurnScopedSyntheticFocus(on: target) {}
  _ = try coordinator.withTurnScopedSyntheticFocus(on: target) {}

  #expect(events.descriptors == expected.begin)
  coordinator.handle(.ended(identity))
  #expect(events.descriptors == expected.begin + expected.end)
}

@Test func syntheticFocusLeaseSwitchesTargetsWithoutOverlap() throws {
  let events = RecordingSyntheticFocusEvents()
  let coordinator = focusCoordinator(syntheticEvents: events)
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))
  let first = focusEventTarget(pid: 20, windowID: 200)
  let second = focusEventTarget(pid: 30, windowID: 300)
  let firstSequence = ProcessTargetedEventPoster.syntheticFocusSequence(for: first)
  let secondSequence = ProcessTargetedEventPoster.syntheticFocusSequence(for: second)

  coordinator.handle(.started(identity))
  _ = try coordinator.withTurnScopedSyntheticFocus(on: first) {}
  _ = try coordinator.withTurnScopedSyntheticFocus(on: second) {}
  coordinator.handle(.ended(identity))

  #expect(
    events.targetPIDs
      == Array(repeating: pid_t(20), count: firstSequence.begin.count + firstSequence.end.count)
        + Array(
          repeating: pid_t(30),
          count: secondSequence.begin.count + secondSequence.end.count
        )
  )
  #expect(
    events.descriptors
      == firstSequence.begin + firstSequence.end + secondSequence.begin + secondSequence.end
  )
}

@Test func actualActivationReleasesLeaseWithoutSyntheticDeactivation() throws {
  let events = RecordingSyntheticFocusEvents()
  let coordinator = focusCoordinator(syntheticEvents: events)
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))
  let target = focusEventTarget(pid: 20, windowID: 200)
  let expected = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)

  coordinator.handle(.started(identity))
  _ = try coordinator.withTurnScopedSyntheticFocus(on: target) {
    events.setActive(true, processIdentifier: 20)
  }
  coordinator.handle(.ended(identity))

  #expect(events.descriptors == expected.begin)
}

@Test func safetyTerminationBalancesSyntheticFocusWithoutRestoringForeground() throws {
  let focusEnvironment = RecordingFocusEnvironment(frontmostPID: 10)
  let events = RecordingSyntheticFocusEvents()
  let coordinator = focusCoordinator(
    environment: focusEnvironment,
    syntheticEvents: events
  )
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))
  let target = focusEventTarget(pid: 20, windowID: 200)
  let expected = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)

  coordinator.handle(.started(identity))
  coordinator.targetWillBeActivated(focusTestApp(pid: 20))
  _ = try coordinator.withTurnScopedSyntheticFocus(on: target) {}
  coordinator.handle(.safetyTerminated(identity, .userIntervened))

  #expect(events.descriptors == expected.begin + expected.end)
  #expect(focusEnvironment.restoredProcessIdentifiers.isEmpty)
}

@Test func failedTurnScopedActionImmediatelyBalancesSyntheticFocus() throws {
  enum ExpectedFailure: Error { case action }

  let events = RecordingSyntheticFocusEvents()
  let coordinator = focusCoordinator(syntheticEvents: events)
  let identity = try #require(ComputerUseTurnIdentity(metadata: focusTurnMetadata("turn")))
  let target = focusEventTarget(pid: 20, windowID: 200)
  let expected = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)

  coordinator.handle(.started(identity))
  #expect(throws: ExpectedFailure.self) {
    _ = try coordinator.withTurnScopedSyntheticFocus(on: target) {
      throw ExpectedFailure.action
    }
  }

  #expect(events.descriptors == expected.begin + expected.end)
}

private final class RecordingFocusEnvironment: ComputerUseFocusEnvironment, @unchecked Sendable {
  private let lock = NSLock()
  private var storedFrontmostPID: pid_t?
  private var restored: [pid_t] = []

  init(frontmostPID: pid_t?) { storedFrontmostPID = frontmostPID }

  var frontmostPID: pid_t? {
    get { lock.withLock { storedFrontmostPID } }
    set { lock.withLock { storedFrontmostPID = newValue } }
  }

  var restoredProcessIdentifiers: [pid_t] { lock.withLock { restored } }

  func captureRestoreTarget() -> CapturedFocusRestoreTarget? {
    lock.withLock {
      storedFrontmostPID.map {
        CapturedFocusRestoreTarget(processIdentifier: $0, focusedWindow: nil)
      }
    }
  }

  func currentFrontmostProcessIdentifier() -> pid_t? { frontmostPID }

  func restore(_ target: CapturedFocusRestoreTarget) {
    lock.withLock { restored.append(target.processIdentifier) }
  }
}

private final class MutableInterventionMonitor: UserInterventionMonitoring, @unchecked Sendable {
  var isAvailable = true
  var generation: UInt64 = 0
  func checkpoint() -> UInt64 { generation }
}

private final class RecordingSyntheticFocusEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var activeProcessIdentifiers: Set<pid_t> = []
  private var recordedDescriptors: [SyntheticFocusEventDescriptor] = []
  private var recordedTargetPIDs: [pid_t] = []

  var descriptors: [SyntheticFocusEventDescriptor] { lock.withLock { recordedDescriptors } }
  var targetPIDs: [pid_t] { lock.withLock { recordedTargetPIDs } }

  func isActive(processIdentifier: pid_t) -> Bool {
    lock.withLock { activeProcessIdentifiers.contains(processIdentifier) }
  }

  func setActive(_ active: Bool, processIdentifier: pid_t) {
    lock.withLock {
      if active {
        activeProcessIdentifiers.insert(processIdentifier)
      } else {
        activeProcessIdentifiers.remove(processIdentifier)
      }
    }
  }

  func post(_ descriptor: SyntheticFocusEventDescriptor, to target: ComputerUseEventTarget) {
    lock.withLock {
      recordedDescriptors.append(descriptor)
      recordedTargetPIDs.append(target.processIdentifier)
    }
  }
}

private func focusCoordinator(
  environment: RecordingFocusEnvironment = RecordingFocusEnvironment(frontmostPID: 10),
  syntheticEvents: RecordingSyntheticFocusEvents
) -> ComputerUseFocusCoordinator {
  ComputerUseFocusCoordinator(
    environment: environment,
    interventionMonitor: MutableInterventionMonitor(),
    isApplicationActive: { syntheticEvents.isActive(processIdentifier: $0) },
    postSyntheticFocusEvent: { syntheticEvents.post($0, to: $1) },
    beginFocusProtection: { _ in .inert },
    endFocusProtection: { _ in }
  )
}

private func focusTurnMetadata(_ turn: String) -> [String: Any] {
  ["session_id": "session", "thread_id": "thread", "turn_id": turn]
}

private func focusTestApp(pid: pid_t) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: pid,
    bundleIdentifier: "com.example.target.\(pid)",
    displayName: "Target \(pid)",
    appPath: "/Applications/Target.app"
  )
}

private func focusEventTarget(pid: pid_t, windowID: CGWindowID) -> ComputerUseEventTarget {
  ComputerUseEventTarget(
    processIdentifier: pid,
    windowID: windowID,
    screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
    activationPoint: CGPoint(x: 12, y: 12)
  )
}
