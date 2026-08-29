import CoreGraphics
import Foundation
import Testing

@testable import IntelSkyCore

@Test func interactionTrackerWaitsOnlyForSameAppProcess() {
  let tracker = AppInteractionTracker()
  let actionTime = Date(timeIntervalSince1970: 100)
  let app = trackerTestApp(pid: 10)
  tracker.recordAction(for: app, at: actionTime)

  #expect(
    tracker.remainingBaseSettleTime(
      for: app,
      at: actionTime.addingTimeInterval(0.25)
    ) == 0.75
  )
  #expect(
    tracker.remainingBaseSettleTime(
      for: trackerTestApp(pid: 11),
      at: actionTime.addingTimeInterval(0.25)
    ) == 0
  )
  #expect(
    tracker.remainingBaseSettleTime(
      for: app,
      at: actionTime.addingTimeInterval(2)
    ) == 0
  )
}

@Test func loadingDetectorRecognizesKnownAccessibilityRoles() {
  #expect(AccessibilityLoadingDetector.isLoading("[3] AXProgressIndicator value=\"50\""))
  #expect(AccessibilityLoadingDetector.isLoading("[9] AXBusyIndicator"))
  #expect(!AccessibilityLoadingDetector.isLoading("[1] AXButton title=\"Continue\""))
}

@Test func runLoopWaitStopsWhenRequestDeadlineExpires() {
  #expect(throws: SkyRuntimeError.self) {
    try RequestDeadlineContext.withDeadline(Date().addingTimeInterval(0.01)) {
      try RunLoopWaiter.wait(for: 1)
    }
  }
}

@Test func userInterventionContextDetectsNewPhysicalInput() throws {
  let monitor = StubUserInterventionMonitor()
  let scope = UserInterventionContext.begin(monitor: monitor, processIdentifier: 10)
  defer { scope.end() }
  try scope.check()

  monitor.generations[11, default: 0] += 1
  try UserInterventionContext.check()

  monitor.generations[10, default: 0] += 1

  #expect(throws: SkySafetyError.self) { try UserInterventionContext.check() }
}

@Test func physicalInputMonitorAttributesKnownTargetsAndConservativelyHandlesUnknownTargets()
  throws
{
  let monitor = PhysicalInputMonitor(startMonitoring: false)
  let knownTargetEvent = try #require(CGEvent(source: nil))
  knownTargetEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 1234)
  knownTargetEvent.setIntegerValueField(.eventTargetUnixProcessID, value: 10)

  monitor.record(knownTargetEvent)

  #expect(monitor.checkpoint(for: 10) == 1)
  #expect(monitor.checkpoint(for: 11) == 0)

  let unknownTargetEvent = try #require(CGEvent(source: nil))
  unknownTargetEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 1234)
  unknownTargetEvent.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
  monitor.record(unknownTargetEvent)

  #expect(monitor.checkpoint(for: 10) == 2)
  #expect(monitor.checkpoint(for: 11) == 1)
}

@Test func userInterventionRequiresFreshStateOnlyForAffectedAppProcess() throws {
  let monitor = StubUserInterventionMonitor()
  let coordinator = ComputerUseInterventionCoordinator(monitor: monitor)
  let first = trackerTestApp(pid: 10)
  let second = ResolvedMacApp(
    processIdentifier: 11,
    bundleIdentifier: "example.second",
    displayName: "Second",
    appPath: "/Applications/Second.app"
  )
  coordinator.recordFreshState(
    for: first,
    checkpoint: coordinator.stateRefreshCheckpoint(for: first)
  )
  coordinator.recordFreshState(
    for: second,
    checkpoint: coordinator.stateRefreshCheckpoint(for: second)
  )

  monitor.generations[10, default: 0] += 1

  #expect(throws: SkySafetyError.self) { try coordinator.requireFreshState(for: first) }
  try coordinator.requireFreshState(for: second)

  coordinator.recordFreshState(
    for: first,
    checkpoint: coordinator.stateRefreshCheckpoint(for: first)
  )
  try coordinator.requireFreshState(for: first)
}

@Test func physicalInputDuringStateCaptureKeepsAppInRequiresRequeryState() {
  let monitor = StubUserInterventionMonitor()
  let coordinator = ComputerUseInterventionCoordinator(monitor: monitor)
  let app = trackerTestApp(pid: 10)
  let checkpoint = coordinator.stateRefreshCheckpoint(for: app)

  monitor.generations[10, default: 0] += 1
  coordinator.recordFreshState(for: app, checkpoint: checkpoint)

  #expect(throws: SkySafetyError.self) { try coordinator.requireFreshState(for: app) }
}

private func trackerTestApp(pid: pid_t) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: pid,
    bundleIdentifier: "example.test",
    displayName: "Test",
    appPath: "/Applications/Test.app"
  )
}

private final class StubUserInterventionMonitor: UserInterventionMonitoring,
  @unchecked Sendable
{
  var generations: [pid_t: UInt64] = [:]
  var isAvailable: Bool { true }
  func checkpoint() -> UInt64 { generations.values.reduce(0, &+) }
  func checkpoint(for processIdentifier: pid_t) -> UInt64 {
    generations[processIdentifier] ?? 0
  }
}
