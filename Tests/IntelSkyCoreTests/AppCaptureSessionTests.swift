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
  for _ in 0..<2 {
    let update = try manager.nextCaptureUpdate(request: ["requestId": "capture-1"])
    updateTypes.append(try #require(update["type"] as? String))
  }
  #expect(updateTypes == ["metadata", "axText", "screenshot", "screenshot", "completed"])
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

  let finalFrame = try manager.nextCaptureUpdate(request: ["requestId": "unscoped-safety"])
  let terminal = try manager.nextCaptureUpdate(request: ["requestId": "unscoped-safety"])
  #expect(finalFrame["type"] as? String == "screenshot")
  #expect(terminal["type"] as? String == "completed")
}

@Test func startingScopedTurnCompletesLegacyUnscopedCapture() throws {
  let manager = AppCaptureSessionManager(appStateProvider: CaptureStateProvider())
  try start(manager, requestID: "legacy-unscoped")
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )

  manager.handle(.started(identity))

  #expect(manager.activeCaptureRequestIDs.isEmpty)
}

@Test func endingOneThreadPreservesAnotherThreadsCapture() throws {
  let manager = AppCaptureSessionManager(appStateProvider: CaptureStateProvider())
  let first = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "first", "turn_id": "1"])
  )
  let second = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "second", "turn_id": "1"])
  )

  try ComputerUseTurnContext.withIdentity(first) { try start(manager, requestID: "first") }
  try ComputerUseTurnContext.withIdentity(second) { try start(manager, requestID: "second") }
  manager.handle(.ended(first))

  #expect(manager.activeCaptureRequestIDs == ["second"])
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

@Test func nativeChangeSignalDrivesCaptureWithoutWaitingForFallbackPoll() throws {
  let provider = ChangingCaptureStateProvider()
  let monitorBox = CaptureChangeMonitorBox()
  let manager = AppCaptureSessionManager(
    appStateProvider: provider,
    pollInterval: 60,
    changeMonitorFactory: { processIdentifier, changeHandler in
      #expect(processIdentifier == 123)
      return monitorBox.make(changeHandler: changeHandler)
    }
  )
  try start(manager, requestID: "native-change")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "native-change"])
  }
  let monitor = try #require(monitorBox.monitor)
  #expect(monitor.started)

  monitor.trigger()
  let update = try RequestDeadlineContext.withDeadline(Date().addingTimeInterval(1)) {
    try manager.nextCaptureUpdate(request: ["requestId": "native-change"])
  }

  #expect(update["type"] as? String == "axText")
  #expect(update["text"] as? String == "[0] AXWindow title=\"Changed\"")
  manager.shutdown()
  #expect(monitor.stopped)
}

@Test func completedCaptureStopsNativeChangeMonitorImmediately() throws {
  let provider = ChangingCaptureStateProvider()
  let monitorBox = CaptureChangeMonitorBox()
  let manager = AppCaptureSessionManager(
    appStateProvider: provider,
    pollInterval: 60,
    changeMonitorFactory: { _, changeHandler in
      monitorBox.make(changeHandler: changeHandler)
    }
  )
  try start(manager, requestID: "monitor-stop")
  let monitor = try #require(monitorBox.monitor)

  try manager.completeCapture(request: ["requestId": "monitor-stop"])

  #expect(monitor.stopped)
  monitor.trigger()
  var updateTypes: [String] = []
  for _ in 0..<6 {
    let update = try manager.nextCaptureUpdate(request: ["requestId": "monitor-stop"])
    updateTypes.append(try #require(update["type"] as? String))
  }
  #expect(
    updateTypes == ["metadata", "axText", "screenshot", "axText", "screenshot", "completed"]
  )
  #expect(provider.calls == 2)
}

@Test func captureProcessReplacementMovesNativeChangeMonitorToNewPID() throws {
  let provider = ReplacingCaptureStateProvider()
  let monitorLog = CaptureChangeMonitorLog()
  let manager = AppCaptureSessionManager(
    appStateProvider: provider,
    pollInterval: 60,
    changeMonitorFactory: { processIdentifier, changeHandler in
      monitorLog.make(processIdentifier: processIdentifier, changeHandler: changeHandler)
    }
  )
  try start(manager, requestID: "pid-replacement")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "pid-replacement"])
  }
  let first = try #require(monitorLog.monitor(for: 123))

  first.trigger()
  let metadata = try RequestDeadlineContext.withDeadline(Date().addingTimeInterval(1)) {
    try manager.nextCaptureUpdate(request: ["requestId": "pid-replacement"])
  }
  let text = try manager.nextCaptureUpdate(request: ["requestId": "pid-replacement"])

  #expect(metadata["type"] as? String == "metadata")
  #expect((metadata["app"] as? [String: Any])?["pid"] as? Int == 456)
  #expect(text["type"] as? String == "axText")
  #expect(first.stopped)
  #expect(monitorLog.monitor(for: 456)?.started == true)
  manager.shutdown()
  #expect(monitorLog.monitor(for: 456)?.stopped == true)
}

@Test func nativeOneShotCompletionPreservesInitialUpdatesAndExpires() throws {
  let manager = AppCaptureSessionManager(
    appStateProvider: CaptureStateProvider(),
    changeMonitorFactory: { _, _ in
      Issue.record("finite native Appshot must not start a continuous change monitor")
      return RecordingCaptureChangeMonitor(changeHandler: {})
    }
  )
  try ComputerUseClientContext.withIdentifier("native:123") {
    try start(manager, requestID: "native-one-shot")
    try manager.completeCapture(request: ["requestId": "native-one-shot"])

    var updateTypes: [String] = []
    for index in 0..<5 {
      let update = try manager.nextCaptureUpdate(request: ["requestId": "native-one-shot"])
      updateTypes.append(try #require(update["type"] as? String))
      if index == 2 {
        #expect(update["transitionSnapshotURL"] as? String == "file:///tmp/finder.png")
      } else if index == 3 {
        #expect(update["transitionSnapshotURL"] == nil)
      }
    }
    #expect(updateTypes == ["metadata", "axText", "screenshot", "screenshot", "completed"])
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
  let transitionDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("com.openai.sky.CUAService", isDirectory: true)
    .appendingPathComponent("skyshots", isDirectory: true)
  try SecureDirectoryPreparer.prepare(transitionDirectory)
  let transitionURL =
    transitionDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("png")
  try Data("transition".utf8).write(to: transitionURL)
  defer { try? FileManager.default.removeItem(at: transitionURL) }
  let manager = AppCaptureSessionManager(
    appStateProvider: provider,
    transitionSnapshotRenderer: FixedCaptureTransitionRenderer(
      result: AppshotTransitionSnapshot(url: transitionURL, height: 160)
    )
  )
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
  #expect(!FileManager.default.fileExists(atPath: transitionURL.path))
  #expect(throws: AppCaptureSessionError.self) {
    try manager.nextCaptureUpdate(request: ["requestId": "racing"])
  }
}

private struct FixedCaptureTransitionRenderer: AppshotTransitionSnapshotRendering {
  let result: AppshotTransitionSnapshot?

  func render(
    screenshot: [String: Any],
    bundleIdentifier: String,
    animationTarget: [String: Any]
  ) -> AppshotTransitionSnapshot? {
    result
  }
}

@Test func captureSessionAcceptsARMInitialAndFutureVersions() throws {
  let manager = AppCaptureSessionManager(appStateProvider: CaptureStateProvider())

  for version in [-1, 0, 1, 2, 3] {
    _ = try manager.startCapture(request: [
      "app": "com.apple.finder",
      "requestId": "capture-\(version)",
      "permissionRequestId": "permission-\(version)",
      "animationTarget": [:],
      "version": version,
    ])
  }

  #expect(throws: AppCaptureSessionError.self) {
    try manager.startCapture(request: [
      "app": "com.apple.finder",
      "requestId": "capture-invalid",
      "permissionRequestId": "permission-invalid",
      "animationTarget": [:],
      "version": "2",
    ])
  }
  manager.shutdown()
}

@Test func reliableCaptureEmitsChangedFinalFrameBeforeCompleted() throws {
  let provider = ChangingCaptureStateProvider()
  let manager = AppCaptureSessionManager(appStateProvider: provider, pollInterval: 60)
  try start(manager, requestID: "reliable-final")
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "reliable-final"])
  }

  try manager.completeCapture(request: ["requestId": "reliable-final"])

  let finalAXFrame = try manager.nextCaptureUpdate(request: ["requestId": "reliable-final"])
  let finalScreenshot = try manager.nextCaptureUpdate(request: ["requestId": "reliable-final"])
  let completed = try manager.nextCaptureUpdate(request: ["requestId": "reliable-final"])
  #expect(finalAXFrame["type"] as? String == "axText")
  #expect(finalAXFrame["text"] as? String == "[0] AXWindow title=\"Changed\"")
  #expect(finalScreenshot["type"] as? String == "screenshot")
  #expect(completed["type"] as? String == "completed")
  #expect(provider.calls == 2)
}

@Test func initialCaptureCompletesWithoutReliableFinalFrame() throws {
  let provider = ChangingCaptureStateProvider()
  let manager = AppCaptureSessionManager(appStateProvider: provider, pollInterval: 60)
  _ = try manager.startCapture(request: [
    "app": "com.apple.finder",
    "requestId": "initial-version",
    "permissionRequestId": "permission-initial-version",
    "animationTarget": [:],
    "version": 1,
  ])
  for _ in 0..<3 {
    _ = try manager.nextCaptureUpdate(request: ["requestId": "initial-version"])
  }

  try manager.completeCapture(request: ["requestId": "initial-version"])

  let completed = try manager.nextCaptureUpdate(request: ["requestId": "initial-version"])
  #expect(completed["type"] as? String == "completed")
  #expect(provider.calls == 1)
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
  var calls: Int { lock.withLock { callCount } }

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

private final class ReplacingCaptureStateProvider: AppStateProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    let current = lock.withLock { () -> Int in
      callCount += 1
      return callCount
    }
    return captureState(
      text: current == 1 ? "Initial" : "Replaced",
      processIdentifier: current == 1 ? 123 : 456
    )
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

private final class CaptureChangeMonitorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMonitor: RecordingCaptureChangeMonitor?
  var monitor: RecordingCaptureChangeMonitor? { lock.withLock { storedMonitor } }

  func make(changeHandler: @escaping @Sendable () -> Void) -> RecordingCaptureChangeMonitor {
    lock.withLock {
      let monitor = RecordingCaptureChangeMonitor(changeHandler: changeHandler)
      storedMonitor = monitor
      return monitor
    }
  }
}

private final class CaptureChangeMonitorLog: @unchecked Sendable {
  private let lock = NSLock()
  private var monitors: [pid_t: RecordingCaptureChangeMonitor] = [:]

  func make(
    processIdentifier: pid_t,
    changeHandler: @escaping @Sendable () -> Void
  ) -> RecordingCaptureChangeMonitor {
    lock.withLock {
      let monitor = RecordingCaptureChangeMonitor(changeHandler: changeHandler)
      monitors[processIdentifier] = monitor
      return monitor
    }
  }

  func monitor(for processIdentifier: pid_t) -> RecordingCaptureChangeMonitor? {
    lock.withLock { monitors[processIdentifier] }
  }
}

private final class RecordingCaptureChangeMonitor: AppCaptureChangeMonitoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let changeHandler: @Sendable () -> Void
  private var didStart = false
  private var didStop = false
  var started: Bool { lock.withLock { didStart } }
  var stopped: Bool { lock.withLock { didStop } }

  init(changeHandler: @escaping @Sendable () -> Void) {
    self.changeHandler = changeHandler
  }

  func start() { lock.withLock { didStart = true } }
  func stop() { lock.withLock { didStop = true } }
  func trigger() { changeHandler() }
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

private func captureState(text: String, processIdentifier: Int = 123) -> [String: Any] {
  [
    "app": ["bundleIdentifier": "com.apple.finder", "pid": processIdentifier],
    "skyshot": [
      "text": "[0] AXWindow title=\"\(text)\"",
      "screenshot": ["url": "file:///tmp/finder.png", "mimeType": "image/png"],
    ],
  ]
}
