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
  let scope = UserInterventionContext.begin(monitor: monitor)
  defer { scope.end() }
  try scope.check()

  monitor.generation += 1

  #expect(throws: SkySafetyError.self) { try UserInterventionContext.check() }
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
  var generation: UInt64 = 0
  var isAvailable: Bool { true }
  func checkpoint() -> UInt64 { generation }
}
