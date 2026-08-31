import Foundation

public protocol AppCaptureProviding: Sendable {
  func startCapture(request: [String: Any]) throws -> [String: Any]
  func nextCaptureUpdate(request: [String: Any]) throws -> [String: Any]
}

public protocol AppCaptureChangeMonitoring: Sendable {
  func start()
  func stop()
}

public typealias AppCaptureChangeMonitorFactory = @Sendable (
  _ processIdentifier: pid_t,
  _ changeHandler: @escaping @Sendable () -> Void
) -> any AppCaptureChangeMonitoring

protocol AppCaptureCompleting: Sendable {
  func completeCapture(request: [String: Any]) throws
}

protocol AppCaptureLifecycleHandling: ComputerUseTurnLifecycleEventHandling {
  func clientDisconnected(_ clientIdentifier: String)
  func handle(_ event: ComputerUseTurnLifecycleEvent)
  func stopApplication(bundleIdentifier: String)
  func shutdown()
}

enum ComputerUseClientContext {
  private static let key = "dev.huangjianbin.intel-sky-service.client-identifier"

  static var identifier: String {
    Thread.current.threadDictionary[key] as? String ?? "direct"
  }

  static func withIdentifier<T>(_ identifier: String, operation: () throws -> T) rethrows -> T {
    let dictionary = Thread.current.threadDictionary
    let previous = dictionary[key]
    dictionary[key] = identifier
    defer {
      if let previous { dictionary[key] = previous } else { dictionary.removeObject(forKey: key) }
    }
    return try operation()
  }
}

enum AppCaptureSessionError: Error, CustomStringConvertible {
  case invalidRequest(String)
  case duplicateRequest(String)
  case captureNotFound(String)

  var description: String {
    switch self {
    case .invalidRequest(let message): return message
    case .duplicateRequest(let requestID):
      return "A capture already exists for request ID \(requestID)"
    case .captureNotFound(let requestID):
      return "No capture exists for request ID \(requestID)"
    }
  }
}

public final class AppCaptureSessionManager: AppCaptureProviding, AppCaptureCompleting,
  AppCaptureLifecycleHandling, @unchecked Sendable
{
  private static let currentVersion = 2

  private final class Session: @unchecked Sendable {
    let requestID: String
    let owner: String
    let app: String
    let condition = NSCondition()
    var appMetadata: [String: Any]
    var updates: [[String: Any]]
    var lastText: String
    var lastScreenshotSignature: Data?
    var lastScreenshotURL: URL?
    var changeMonitor: (any AppCaptureChangeMonitoring)?
    var refreshRequested = false
    var terminalQueued = false
    var disconnected = false

    init(
      requestID: String,
      owner: String,
      app: String,
      appMetadata: [String: Any],
      text: String,
      screenshot: [String: Any]?,
      transitionSnapshotURL: URL?
    ) {
      self.requestID = requestID
      self.owner = owner
      self.app = app
      self.appMetadata = appMetadata
      lastText = text
      lastScreenshotSignature = Self.screenshotSignature(screenshot)
      lastScreenshotURL = Self.screenshotURL(screenshot)
      updates = [
        ["type": "metadata", "app": appMetadata],
        ["type": "axText", "app": appMetadata, "text": text],
      ]
      if let screenshot {
        updates.append(
          Self.screenshotUpdate(
            app: appMetadata,
            screenshot: screenshot,
            transitionSnapshotURL: transitionSnapshotURL
          ))
      }
    }

    func requestRefresh() {
      condition.lock()
      guard !terminalQueued, !disconnected else {
        condition.unlock()
        return
      }
      refreshRequested = true
      condition.broadcast()
      condition.unlock()
    }

    func installChangeMonitor(_ monitor: any AppCaptureChangeMonitoring) -> Bool {
      condition.lock()
      defer { condition.unlock() }
      guard !terminalQueued, !disconnected, changeMonitor == nil else { return false }
      changeMonitor = monitor
      return true
    }

    static func screenshotUpdate(
      app: [String: Any],
      screenshot: [String: Any],
      transitionSnapshotURL: URL? = nil
    ) -> [String: Any] {
      var update: [String: Any] = [
        "type": "screenshot",
        "app": app,
        "screenshot": screenshot,
      ]
      if let transitionSnapshotURL {
        update["transitionSnapshotURL"] = transitionSnapshotURL.absoluteString
      }
      return update
    }

    static func screenshotSignature(_ screenshot: [String: Any]?) -> Data? {
      guard let screenshot else { return nil }
      if let value = screenshot["url"] as? String,
        let url = URL(string: value), url.isFileURL,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
      {
        return data
      }
      return try? JSONSerialization.data(withJSONObject: screenshot, options: [.sortedKeys])
    }

    static func screenshotURL(_ screenshot: [String: Any]?) -> URL? {
      guard let value = screenshot?["url"] as? String,
        let url = URL(string: value), url.isFileURL
      else { return nil }
      return url
    }
  }

  private let lock = NSLock()
  private let appStateProvider: any AppStateProviding
  private let permissionDiagnostics: ServicePermissionDiagnostics
  private let pollInterval: TimeInterval
  private let maximumQueuedUpdates: Int
  private let changeMonitorFactory: AppCaptureChangeMonitorFactory?
  private let transitionSnapshotRenderer: any AppshotTransitionSnapshotRendering
  private let producerQueue = DispatchQueue(
    label: "dev.huangjianbin.intel-sky-service.capture-stream",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private var sessions: [String: Session] = [:]
  private var isShuttingDown = false
  private var lifecycleGeneration: UInt64 = 0

  public init(
    appStateProvider: any AppStateProviding,
    permissionDiagnostics: ServicePermissionDiagnostics = .init(),
    pollInterval: TimeInterval = 2,
    maximumQueuedUpdates: Int = 32,
    changeMonitorFactory: AppCaptureChangeMonitorFactory? = nil,
    transitionSnapshotRenderer: any AppshotTransitionSnapshotRendering =
      AppshotTransitionSnapshotRenderer()
  ) {
    self.appStateProvider = appStateProvider
    self.permissionDiagnostics = permissionDiagnostics
    self.pollInterval = max(0.01, pollInterval)
    self.maximumQueuedUpdates = max(4, maximumQueuedUpdates)
    self.changeMonitorFactory = changeMonitorFactory
    self.transitionSnapshotRenderer = transitionSnapshotRenderer
  }

  public func installSessionStopHandling() {
    ComputerUseSessionCoordinator.shared.addStopHandler { [weak self] bundleIdentifier in
      self?.stopApplication(bundleIdentifier: bundleIdentifier)
    }
  }

  public func startCapture(request: [String: Any]) throws -> [String: Any] {
    let requestID = try Self.nonemptyString(request["requestId"], named: "requestId")
    let app = try Self.nonemptyString(request["app"], named: "app")
    _ = try Self.nonemptyString(
      request["permissionRequestId"],
      named: "permissionRequestId"
    )
    guard let animationTarget = request["animationTarget"] as? [String: Any] else {
      throw AppCaptureSessionError.invalidRequest("Capture animationTarget must be an object")
    }
    guard let version = Self.integer(request["version"]), version == Self.currentVersion else {
      throw AppCaptureSessionError.invalidRequest("Unsupported capture version")
    }
    let startingGeneration = try lock.withLock { () throws -> UInt64 in
      guard !isShuttingDown else {
        throw AppCaptureSessionError.invalidRequest("Capture service is shutting down")
      }
      guard sessions[requestID] == nil else {
        throw AppCaptureSessionError.duplicateRequest(requestID)
      }
      return lifecycleGeneration
    }

    let state = try appStateProvider.getAppState(request: ["app": app, "disableDiff": true])
    guard let appMetadata = state["app"] as? [String: Any],
      let skyshot = state["skyshot"] as? [String: Any],
      let text = skyshot["text"] as? String
    else {
      throw AppCaptureSessionError.invalidRequest(
        "Capture state provider returned an invalid state")
    }

    let screenshot = skyshot["screenshot"] as? [String: Any]
    let transitionSnapshot = screenshot.flatMap {
      transitionSnapshotRenderer.render(
        screenshot: $0,
        bundleIdentifier: (appMetadata["bundleIdentifier"] as? String) ?? app,
        animationTarget: animationTarget
      )
    }
    var transitionSnapshotIsOwnedBySession = false
    defer {
      if !transitionSnapshotIsOwnedBySession, let transitionSnapshot {
        Self.removeUnusedGeneratedImage(transitionSnapshot.url)
      }
    }
    let session = Session(
      requestID: requestID,
      owner: ComputerUseClientContext.identifier,
      app: app,
      appMetadata: appMetadata,
      text: text,
      screenshot: screenshot,
      transitionSnapshotURL: transitionSnapshot?.url ?? Session.screenshotURL(screenshot)
    )

    try lock.withLock {
      guard !isShuttingDown, lifecycleGeneration == startingGeneration else {
        throw AppCaptureSessionError.invalidRequest("Capture turn ended before start completed")
      }
      guard sessions[requestID] == nil else {
        throw AppCaptureSessionError.duplicateRequest(requestID)
      }
      sessions[requestID] = session
    }
    transitionSnapshotIsOwnedBySession = true
    if !session.owner.hasPrefix("native:"),
      let processIdentifier = (appMetadata["pid"] as? NSNumber)?.int32Value,
      processIdentifier > 0,
      let changeMonitorFactory
    {
      let monitor = changeMonitorFactory(processIdentifier) { [weak session] in
        session?.requestRefresh()
      }
      monitor.start()
      if !session.installChangeMonitor(monitor) { monitor.stop() }
    }
    beginProducing(session)

    var response: [String: Any] = [
      "result": "started",
      "permissionGrantState": permissionGrantState(),
    ]
    if let transitionSnapshot {
      response["animationDuration"] = 0.35
      response["transitionSnapshotHeight"] = transitionSnapshot.height
      response["transitionSpringResponse"] = 0.35
      response["transitionSpringDampingFraction"] = 0.73
    }
    return response
  }

  public func nextCaptureUpdate(request: [String: Any]) throws -> [String: Any] {
    let requestID = try Self.nonemptyString(request["requestId"], named: "requestId")
    guard let session = lock.withLock({ sessions[requestID] }),
      session.owner == ComputerUseClientContext.identifier
    else {
      throw AppCaptureSessionError.captureNotFound(requestID)
    }

    while true {
      session.condition.lock()
      if session.disconnected {
        session.condition.unlock()
        throw AppCaptureSessionError.captureNotFound(requestID)
      }
      if !session.updates.isEmpty {
        let update = session.updates.removeFirst()
        session.condition.unlock()
        if Self.isTerminal(update) {
          lock.withLock {
            if sessions[requestID] === session { sessions.removeValue(forKey: requestID) }
          }
        }
        return update
      }
      let wakeDate = min(
        Date().addingTimeInterval(0.1),
        RequestDeadlineContext.deadline ?? Date().addingTimeInterval(0.1)
      )
      _ = session.condition.wait(until: wakeDate)
      session.condition.unlock()
      try RequestDeadlineContext.check()
    }
  }

  func completeCapture(request: [String: Any]) throws {
    let requestID = try Self.nonemptyString(request["requestId"], named: "requestId")
    guard let session = lock.withLock({ sessions[requestID] }),
      session.owner == ComputerUseClientContext.identifier
    else {
      throw AppCaptureSessionError.captureNotFound(requestID)
    }
    terminate(session, update: terminalUpdate(type: "completed", session: session))
  }

  func clientDisconnected(_ clientIdentifier: String) {
    let removed = lock.withLock { () -> [Session] in
      let matches = sessions.values.filter { $0.owner == clientIdentifier }
      for session in matches { sessions.removeValue(forKey: session.requestID) }
      return matches
    }
    for session in removed { disconnect(session) }
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    switch event {
    case .started: return
    case .transitioned, .ended, .safetyTerminated, .safetyRevoked:
      lock.withLock { lifecycleGeneration &+= 1 }
      terminateAllWithCompleted()
    }
  }

  public func stopApplication(bundleIdentifier: String) {
    let matches = lock.withLock {
      sessions.values.filter {
        ($0.appMetadata["bundleIdentifier"] as? String) == bundleIdentifier
          || $0.app == bundleIdentifier
      }
    }
    for session in matches {
      terminate(session, update: terminalUpdate(type: "completed", session: session))
    }
  }

  func shutdown() {
    let removed = lock.withLock { () -> [Session] in
      guard !isShuttingDown else { return [] }
      isShuttingDown = true
      let values = Array(sessions.values)
      sessions.removeAll()
      return values
    }
    for session in removed { disconnect(session) }
  }

  private func beginProducing(_ session: Session) {
    producerQueue.async { [weak self, weak session] in
      guard let self, let session else { return }
      while self.waitForRefresh(session) {
        do {
          let state = try self.appStateProvider.getAppState(
            request: ["app": session.app, "disableDiff": true]
          )
          try self.process(state: state, for: session)
        } catch {
          let reason: String
          switch error {
          case is MacAppPolicyError: reason = "blockedByPolicy"
          case is WindowScreenshotError: reason = "screenshotCaptureFailed"
          default: reason = "unknownCaptureFailed"
          }
          self.terminate(
            session,
            update: self.terminalUpdate(type: "failed", session: session, failureReason: reason)
          )
          return
        }
      }
    }
  }

  private func waitForRefresh(_ session: Session) -> Bool {
    session.condition.lock()
    defer { session.condition.unlock() }
    guard !session.terminalQueued, !session.disconnected else { return false }
    let deadline = Date().addingTimeInterval(pollInterval)
    while !session.refreshRequested, !session.terminalQueued, !session.disconnected,
      Date() < deadline
    {
      _ = session.condition.wait(until: deadline)
    }
    session.refreshRequested = false
    return !session.terminalQueued && !session.disconnected
  }

  private func process(state: [String: Any], for session: Session) throws {
    guard let appMetadata = state["app"] as? [String: Any],
      let skyshot = state["skyshot"] as? [String: Any],
      let text = skyshot["text"] as? String
    else {
      throw AppCaptureSessionError.invalidRequest(
        "Capture state provider returned an invalid state")
    }
    session.condition.lock()
    guard !session.terminalQueued, !session.disconnected else {
      session.condition.unlock()
      return
    }
    let previousProcessIdentifier = (session.appMetadata["pid"] as? NSNumber)?.int32Value
    let nextProcessIdentifier = (appMetadata["pid"] as? NSNumber)?.int32Value
    if !NSDictionary(dictionary: session.appMetadata).isEqual(to: appMetadata) {
      session.appMetadata = appMetadata
      enqueue(["type": "metadata", "app": appMetadata], in: session)
    }
    if text != session.lastText {
      session.lastText = text
      enqueue(["type": "axText", "app": appMetadata, "text": text], in: session)
    }
    if let screenshot = skyshot["screenshot"] as? [String: Any] {
      let signature = Session.screenshotSignature(screenshot)
      if signature != session.lastScreenshotSignature {
        session.lastScreenshotSignature = signature
        session.lastScreenshotURL = Session.screenshotURL(screenshot)
        enqueue(Session.screenshotUpdate(app: appMetadata, screenshot: screenshot), in: session)
      } else if let unusedURL = Session.screenshotURL(screenshot),
        unusedURL != session.lastScreenshotURL
      {
        Self.removeUnusedGeneratedImage(unusedURL)
      }
    }
    session.condition.broadcast()
    session.condition.unlock()
    if let nextProcessIdentifier, nextProcessIdentifier > 0,
      previousProcessIdentifier != nextProcessIdentifier
    {
      replaceChangeMonitor(for: session, processIdentifier: nextProcessIdentifier)
    }
  }

  private func replaceChangeMonitor(for session: Session, processIdentifier: pid_t) {
    guard !session.owner.hasPrefix("native:"), let changeMonitorFactory else { return }
    let replacement = changeMonitorFactory(processIdentifier) { [weak session] in
      session?.requestRefresh()
    }
    replacement.start()
    session.condition.lock()
    guard !session.terminalQueued, !session.disconnected else {
      session.condition.unlock()
      replacement.stop()
      return
    }
    let previous = session.changeMonitor
    session.changeMonitor = replacement
    session.condition.unlock()
    previous?.stop()
  }

  private func enqueue(_ update: [String: Any], in session: Session) {
    let type = update["type"] as? String
    if session.updates.count >= maximumQueuedUpdates,
      let index = session.updates.firstIndex(where: { $0["type"] as? String == type })
    {
      session.updates[index] = update
    } else if session.updates.count < maximumQueuedUpdates {
      session.updates.append(update)
    }
  }

  private func terminateAllWithCompleted() {
    let values = lock.withLock { Array(sessions.values) }
    for session in values {
      terminate(session, update: terminalUpdate(type: "completed", session: session))
    }
  }

  private func terminate(_ session: Session, update: [String: Any]) {
    session.condition.lock()
    guard !session.terminalQueued, !session.disconnected else {
      session.condition.unlock()
      return
    }
    session.terminalQueued = true
    let changeMonitor = session.changeMonitor
    session.changeMonitor = nil
    if session.updates.count >= maximumQueuedUpdates { session.updates.removeFirst() }
    session.updates.append(update)
    session.condition.broadcast()
    session.condition.unlock()
    changeMonitor?.stop()
  }

  private func disconnect(_ session: Session) {
    session.condition.lock()
    let changeMonitor = session.changeMonitor
    session.changeMonitor = nil
    session.disconnected = true
    session.updates.removeAll()
    session.condition.broadcast()
    session.condition.unlock()
    changeMonitor?.stop()
  }

  private func terminalUpdate(
    type: String,
    session: Session,
    failureReason: String? = nil
  ) -> [String: Any] {
    var update: [String: Any] = ["type": type, "app": session.appMetadata]
    if let failureReason { update["failureReason"] = failureReason }
    return update
  }

  private static func isTerminal(_ update: [String: Any]) -> Bool {
    let type = update["type"] as? String
    return type == "completed" || type == "failed"
  }

  private static func removeUnusedGeneratedImage(_ url: URL) {
    let expectedDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("com.openai.sky.CUAService", isDirectory: true)
      .appendingPathComponent("skyshots", isDirectory: true)
      .standardizedFileURL
    let candidate = url.standardizedFileURL
    guard candidate.deletingLastPathComponent() == expectedDirectory,
      candidate.pathExtension.lowercased() == "png"
    else { return }
    try? FileManager.default.removeItem(at: candidate)
  }

  private func permissionGrantState() -> String {
    let status = permissionDiagnostics.currentStatus()
    switch (status.accessibility, status.screenRecording) {
    case (true, true): return "both_granted"
    case (true, false): return "accessibility_granted"
    case (false, true): return "screen_recording_granted"
    case (false, false): return "none_granted"
    }
  }

  private static func nonemptyString(_ value: Any?, named name: String) throws -> String {
    guard let value = value as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AppCaptureSessionError.invalidRequest("Capture \(name) must be a non-empty string")
    }
    return value
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite,
      number.doubleValue.rounded() == number.doubleValue
    else {
      return nil
    }
    return number.intValue
  }
}
