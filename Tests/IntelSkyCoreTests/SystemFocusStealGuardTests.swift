import CoreGraphics
import Foundation
import Testing

@testable import IntelSkyCore

private final class FocusGuardInterventionMonitor: UserInterventionMonitoring, @unchecked Sendable {
  var isAvailable = true
  var generation: UInt64 = 0
  func checkpoint() -> UInt64 { generation }
  func checkpoint(for processIdentifier: pid_t) -> UInt64 { generation }
}

private final class RecordingKeyFocusReleaser: KeyFocusReleasing, @unchecked Sendable {
  var isAvailable = true
  var result = true
  var identifiers: [UInt32] = []

  func releaseKeyFocus(with identifier: UInt32) -> Bool {
    identifiers.append(identifier)
    return result
  }
}

private func focusNotification(
  subtype: UInt16 = FocusStealProcessNotificationSubtype.newFront.rawValue,
  subjectPID: pid_t = 42,
  focusTheftID: UInt32? = 7
) -> FocusStealProcessNotification {
  FocusStealProcessNotification(
    subtype: subtype,
    targetProcessIdentifier: 99,
    subjectProcessIdentifier: subjectPID,
    focusTheftIdentifier: focusTheftID
  )
}

@Test func focusStealPolicyOnlyReleasesOfficialFocusChangeNotifications() {
  let protected: Set<pid_t> = [42]

  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(),
      protectedProcessIdentifiers: protected,
      userIntervened: false
    ) == .releaseAndSuppress(focusTheftIdentifier: 7)
  )
  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(subtype: FocusStealProcessNotificationSubtype.keyFocusChanged.rawValue),
      protectedProcessIdentifiers: protected,
      userIntervened: false
    ) == .releaseAndSuppress(focusTheftIdentifier: 7)
  )
  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(subtype: FocusStealProcessNotificationSubtype.keyFocusTaken.rawValue),
      protectedProcessIdentifiers: protected,
      userIntervened: false
    ) == .passThrough
  )
  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(subtype: FocusStealProcessNotificationSubtype.keyFocusReturned.rawValue),
      protectedProcessIdentifiers: protected,
      userIntervened: false
    ) == .passThrough
  )
}

@Test func focusStealPolicyPassesUnprotectedIncompleteAndIntervenedEvents() {
  let protected: Set<pid_t> = [42]
  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(subjectPID: 43),
      protectedProcessIdentifiers: protected,
      userIntervened: false
    ) == .passThrough
  )
  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(focusTheftID: nil),
      protectedProcessIdentifiers: protected,
      userIntervened: false
    ) == .passThrough
  )
  #expect(
    FocusStealPolicy.disposition(
      for: focusNotification(),
      protectedProcessIdentifiers: protected,
      userIntervened: true
    ) == .passThrough
  )
}

@Test func focusGuardSuppressesOnlyAfterSuccessfulFocusRelease() {
  let monitor = FocusGuardInterventionMonitor()
  let releaser = RecordingKeyFocusReleaser()
  let guardInstance = SystemFocusStealGuard(
    interventionMonitor: monitor,
    keyFocusReleaser: releaser,
    startMonitoring: false
  )
  let protection = guardInstance.beginProtecting(processIdentifier: 42)

  #expect(guardInstance.handle(focusNotification()))
  #expect(releaser.identifiers == [7])

  releaser.result = false
  #expect(!guardInstance.handle(focusNotification(focusTheftID: 8)))
  #expect(releaser.identifiers == [7, 8])

  guardInstance.endProtecting(protection)
  #expect(!guardInstance.handle(focusNotification(focusTheftID: 9)))
  #expect(releaser.identifiers == [7, 8])
}

@Test func focusGuardStopsSuppressingAfterPhysicalUserIntervention() {
  let monitor = FocusGuardInterventionMonitor()
  let releaser = RecordingKeyFocusReleaser()
  let guardInstance = SystemFocusStealGuard(
    interventionMonitor: monitor,
    keyFocusReleaser: releaser,
    startMonitoring: false
  )
  _ = guardInstance.beginProtecting(processIdentifier: 42)
  monitor.generation = 1

  #expect(!guardInstance.handle(focusNotification()))
  #expect(releaser.identifiers.isEmpty)
}

@Test func focusGuardFailsOpenWithoutPhysicalInputMonitoring() {
  let monitor = FocusGuardInterventionMonitor()
  monitor.isAvailable = false
  let releaser = RecordingKeyFocusReleaser()
  let guardInstance = SystemFocusStealGuard(
    interventionMonitor: monitor,
    keyFocusReleaser: releaser,
    startMonitoring: false
  )
  _ = guardInstance.beginProtecting(processIdentifier: 42)

  #expect(!guardInstance.handle(focusNotification()))
  #expect(releaser.identifiers.isEmpty)
}

@Test func focusNotificationDecoderUsesOfficialRawCGEventFields() throws {
  let source = try #require(CGEventSource(stateID: .hidSystemState))
  let event = try #require(CGEvent(source: source))
  event.type = CGEventType(rawValue: 21)!
  event.setIntegerValueField(CGEventField(rawValue: 40)!, value: 99)
  event.setIntegerValueField(CGEventField(rawValue: 64)!, value: 0xF102)
  event.setIntegerValueField(CGEventField(rawValue: 71)!, value: 1234)
  event.setIntegerValueField(CGEventField(rawValue: 73)!, value: 42)

  #expect(
    SystemFocusStealGuard.decode(event)
      == FocusStealProcessNotification(
        subtype: 0xF102,
        targetProcessIdentifier: 99,
        subjectProcessIdentifier: 42,
        focusTheftIdentifier: 1234
      )
  )

  event.setIntegerValueField(CGEventField(rawValue: 71)!, value: 0)
  #expect(SystemFocusStealGuard.decode(event)?.focusTheftIdentifier == 0)
}

@Test func attendedSessionEventTapRoutesProtectedFocusNotification() async throws {
  guard ProcessInfo.processInfo.environment["INTEL_SKY_FOCUS_SMOKE"] == "1" else { return }
  let monitor = FocusGuardInterventionMonitor()
  let releaser = RecordingKeyFocusReleaser()
  let guardInstance = SystemFocusStealGuard(
    interventionMonitor: monitor,
    keyFocusReleaser: releaser,
    startMonitoring: true
  )
  let readinessDeadline = ContinuousClock.now + .seconds(1)
  while !guardInstance.isAvailable, ContinuousClock.now < readinessDeadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(guardInstance.isAvailable)
  let protection = guardInstance.beginProtecting(processIdentifier: 42)
  defer { guardInstance.endProtecting(protection) }

  let source = try #require(CGEventSource(stateID: .hidSystemState))
  let event = try #require(CGEvent(source: source))
  event.type = CGEventType(rawValue: 21)!
  event.setIntegerValueField(CGEventField(rawValue: 40)!, value: 99)
  event.setIntegerValueField(CGEventField(rawValue: 64)!, value: 0xF102)
  event.setIntegerValueField(CGEventField(rawValue: 71)!, value: 1234)
  event.setIntegerValueField(CGEventField(rawValue: 73)!, value: 42)
  event.post(tap: .cgSessionEventTap)
  try await Task.sleep(for: .milliseconds(250))

  #expect(releaser.identifiers == [1234])
  #expect(
    guardInstance.rawNotifications().contains {
      $0.subtype == 0xF102
        && $0.subjectProcessIdentifier == 42
        && $0.focusTheftIdentifier == 1234
    }
  )
}
