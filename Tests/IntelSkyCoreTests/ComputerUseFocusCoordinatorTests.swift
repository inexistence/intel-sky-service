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
