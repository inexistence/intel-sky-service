import Foundation
import Testing

@testable import IntelSkyCore

@Test func permissionDiagnosticsReportsEachIndependentPermission() {
  let diagnostics = ServicePermissionDiagnostics(
    accessibilityCheck: { true },
    screenRecordingCheck: { false }
  )

  let status = diagnostics.currentStatus()

  #expect(status == ServicePermissionStatus(accessibility: true, screenRecording: false))
  #expect(!status.allGranted)
}

@Test func permissionStatusRequiresBothPermissions() {
  #expect(ServicePermissionStatus(accessibility: true, screenRecording: true).allGranted)
  #expect(!ServicePermissionStatus(accessibility: false, screenRecording: true).allGranted)
  #expect(!ServicePermissionStatus(accessibility: true, screenRecording: false).allGranted)
}

@Test func permissionRequesterRequestsOnlyMissingPermissions() {
  final class RequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var accessibility = 0
    private var screenRecording = 0

    func incrementAccessibility() {
      lock.withLock { accessibility += 1 }
    }

    func incrementScreenRecording() {
      lock.withLock { screenRecording += 1 }
    }

    func values() -> (accessibility: Int, screenRecording: Int) {
      lock.withLock { (accessibility, screenRecording) }
    }
  }
  let counts = RequestCounts()
  let requester = ServicePermissionRequester(
    accessibilityCheck: { false },
    accessibilityRequest: { counts.incrementAccessibility() },
    screenRecordingCheck: { true },
    screenRecordingRequest: { counts.incrementScreenRecording() }
  )

  requester.requestMissingPermissions()

  let values = counts.values()
  #expect(values.accessibility == 1)
  #expect(values.screenRecording == 0)
}
