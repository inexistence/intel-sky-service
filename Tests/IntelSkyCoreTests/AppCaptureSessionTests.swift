import Foundation
import Testing

@testable import IntelSkyCore

@Test func captureSessionStreamsUntilTurnEndsAndThenExpires() throws {
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
  for _ in 0..<3 {
    let update = try manager.nextCaptureUpdate(request: ["requestId": "capture-1"])
    updateTypes.append(try #require(update["type"] as? String))
    if update["type"] as? String == "screenshot" {
      #expect(update["transitionSnapshotURL"] as? String == "file:///tmp/finder.png")
    }
  }
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: [
      "session_id": "session", "thread_id": "thread", "turn_id": "turn",
    ]))
  manager.handle(.ended(identity))
  let terminal = try manager.nextCaptureUpdate(request: ["requestId": "capture-1"])
  updateTypes.append(try #require(terminal["type"] as? String))
  #expect(updateTypes == ["metadata", "axText", "screenshot", "completed"])
  #expect(throws: AppCaptureSessionError.self) {
    try manager.nextCaptureUpdate(request: ["requestId": "capture-1"])
  }
}

@Test func unscopedSafetyRevocationCompletesEveryCapture() throws {
  let manager = AppCaptureSessionManager(
    appStateProvider: CaptureStateProvider(),
    permissionDiagnostics: ServicePermissionDiagnostics(
      accessibilityCheck: { true },
      screenRecordingCheck: { true }
    )
  )
  try start(manager, requestID: "unscoped-safety")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "unscoped-safety"])
  }

  manager.handle(.safetyRevoked(.screenLocked))

  let terminal = try manager.nextCaptureUpdate(request: ["requestId": "unscoped-safety"])
  #expect(terminal["type"] as? String == "completed")
}

@Test func captureSessionLongPollEmitsChangedAccessibilityState() throws {
  let provider = ChangingCaptureStateProvider()
  let manager = AppCaptureSessionManager(
    appStateProvider: provider,
    pollInterval: 0.01
  )
  try start(manager, requestID: "changing")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "changing"])
  }

  let update = try RequestDeadlineContext.withDeadline(Date().addingTimeInterval(1)) {
    try manager.nextCaptureUpdate(request: ["requestId": "changing"])
  }

  #expect(update["type"] as? String == "axText")
  #expect(update["text"] as? String == "[0] AXWindow title=\"Changed\"")
  manager.shutdown()
}

@Test func nativeOneShotCompletionPreservesInitialUpdatesAndExpires() throws {
  let manager = AppCaptureSessionManager(appStateProvider: CaptureStateProvider())
  try ComputerUseClientContext.withIdentifier("native:123") {
    try start(manager, requestID: "native-one-shot")
    try manager.completeCapture(request: ["requestId": "native-one-shot"])

    var updateTypes: [String] = []
    for _ in 0..<4 {
      let update = try manager.nextCaptureUpdate(request: ["requestId": "native-one-shot"])
      updateTypes.append(try #require(update["type"] as? String))
      if update["type"] as? String == "screenshot" {
        #expect(update["transitionSnapshotURL"] as? String == "file:///tmp/finder.png")
      }
    }
    #expect(updateTypes == ["metadata", "axText", "screenshot", "completed"])
    #expect(throws: AppCaptureSessionError.self) {
      try manager.nextCaptureUpdate(request: ["requestId": "native-one-shot"])
    }
  }
}

@Test func captureSessionLongPollHonorsRequestDeadline() throws {
  let manager = AppCaptureSessionManager(
    appStateProvider: CaptureStateProvider(),
    pollInterval: 0.01
  )
  try start(manager, requestID: "deadline")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "deadline"])
  }

  #expect(throws: SkyRuntimeError.self) {
    try RequestDeadlineContext.withDeadline(Date().addingTimeInterval(0.03)) {
      try manager.nextCaptureUpdate(request: ["requestId": "deadline"])
    }
  }
  manager.shutdown()
}

@Test func captureSessionIsOwnedByClientAndDisconnectCleansItUp() throws {
  let manager = AppCaptureSessionManager(appStateProvider: CaptureStateProvider())
  try ComputerUseClientContext.withIdentifier("client-a") {
    try start(manager, requestID: "owned")
  }

  #expect(throws: AppCaptureSessionError.self) {
    try ComputerUseClientContext.withIdentifier("client-b") {
      try manager.nextCaptureUpdate(request: ["requestId": "owned"])
    }
  }
  manager.clientDisconnected("client-a")
  #expect(throws: AppCaptureSessionError.self) {
    try ComputerUseClientContext.withIdentifier("client-a") {
      try manager.nextCaptureUpdate(request: ["requestId": "owned"])
    }
  }
}

@Test func captureSessionConvertsProducerFailureToOfficialTerminalUpdate() throws {
  let manager = AppCaptureSessionManager(
    appStateProvider: FailingCaptureStateProvider(),
    pollInterval: 0.01
  )
  try start(manager, requestID: "failure")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "failure"])
  }

  let update = try RequestDeadlineContext.withDeadline(Date().addingTimeInterval(1)) {
    try manager.nextCaptureUpdate(request: ["requestId": "failure"])
  }
  #expect(update["type"] as? String == "failed")
  #expect(update["failureReason"] as? String == "unknownCaptureFailed")
}

@Test func turnEndRacingInitialCaptureCannotCreateOrphanedSession() throws {
  let provider = BlockingInitialCaptureStateProvider()
  let manager = AppCaptureSessionManager(appStateProvider: provider)
  let result = CaptureStartResult()
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    defer { finished.signal() }
    do {
      try start(manager, requestID: "racing")
      result.store(nil)
    } catch {
      result.store(error)
    }
  }
  #expect(provider.entered.wait(timeout: .now() + 1) == .success)
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: [
      "session_id": "session", "thread_id": "thread", "turn_id": "turn",
    ]))
  manager.handle(.ended(identity))
  provider.release.signal()

  #expect(finished.wait(timeout: .now() + 1) == .success)
  #expect(result.error is AppCaptureSessionError)
  #expect(throws: AppCaptureSessionError.self) {
    try manager.nextCaptureUpdate(request: ["requestId": "racing"])
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

private final class ChangingCaptureStateProvider: AppStateProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    let current = lock.withLock { () -> Int in
      callCount += 1
      return callCount
    }
    return captureState(text: current == 1 ? "Initial" : "Changed")
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}

private final class FailingCaptureStateProvider: AppStateProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    let current = lock.withLock { () -> Int in
      callCount += 1
      return callCount
    }
    if current > 1 { throw SkyRPCError.invalidRequest("fixture producer failed") }
    return captureState(text: "Initial")
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}

private final class BlockingInitialCaptureStateProvider: AppStateProviding, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    entered.signal()
    release.wait()
    return captureState(text: "Initial")
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}

private final class CaptureStartResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  var error: Error? { lock.withLock { storedError } }
  func store(_ error: Error?) { lock.withLock { storedError = error } }
}

private func start(_ manager: AppCaptureSessionManager, requestID: String) throws {
  _ = try manager.startCapture(request: [
    "app": "com.apple.finder",
    "requestId": requestID,
    "permissionRequestId": "permission-\(requestID)",
    "animationTarget": [:],
    "version": 2,
  ])
}

private func captureState(text: String) -> [String: Any] {
  [
    "app": ["bundleIdentifier": "com.apple.finder", "pid": 123],
    "skyshot": [
      "text": "[0] AXWindow title=\"\(text)\"",
      "screenshot": ["url": "file:///tmp/finder.png", "mimeType": "image/png"],
    ],
  ]
}
