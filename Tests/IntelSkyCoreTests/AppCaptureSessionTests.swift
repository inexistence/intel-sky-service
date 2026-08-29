import Foundation
import Testing

@testable import IntelSkyCore

@Test func captureSessionEmitsOfficialUpdateSequenceAndThenExpires() throws {
  let manager = AppCaptureSessionManager(
    appStateProvider: CaptureStateProvider(),
    permissionDiagnostics: ServicePermissionDiagnostics(
      accessibilityCheck: { true },
      screenRecordingCheck: { true }
    )
  )
  let request: [String: Any] = [
    "app": "com.apple.finder",
    "requestId": "capture-1",
    "permissionRequestId": "permission-1",
    "animationTarget": ["destinationCornerRadius": 12],
    "version": 2,
  ]

  let response = try manager.startCapture(request: request)
  #expect(response["result"] as? String == "started")
  #expect(response["permissionGrantState"] as? String == "both_granted")

  var updateTypes: [String] = []
  for _ in 0..<4 {
    let update = try manager.nextCaptureUpdate(request: ["requestId": "capture-1"])
    updateTypes.append(try #require(update["type"] as? String))
  }
  #expect(updateTypes == ["metadata", "axText", "screenshot", "completed"])
  #expect(throws: AppCaptureSessionError.self) {
    try manager.nextCaptureUpdate(request: ["requestId": "capture-1"])
  }
}

@Test func captureSessionValidatesHiddenRequestSchemaBeforeCapturing() {
  let manager = AppCaptureSessionManager(appStateProvider: CaptureStateProvider())

  #expect(throws: AppCaptureSessionError.self) {
    try manager.startCapture(request: [
      "app": "com.apple.finder",
      "requestId": "capture-1",
      "permissionRequestId": "permission-1",
      "animationTarget": [:],
      "version": 3,
    ])
  }
}

private struct CaptureStateProvider: AppStateProviding {
  func getAppState(request: [String: Any]) throws -> [String: Any] {
    [
      "app": ["bundleIdentifier": "com.apple.finder", "pid": 123],
      "skyshot": [
        "text": "[0] AXWindow title=\"Finder\"",
        "screenshot": ["url": "file:///tmp/finder.png", "mimeType": "image/png"],
      ],
    ]
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}
