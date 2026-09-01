import Foundation

public struct MacAppStateProvider: AppStateProviding, ComputerUseTurnLifecycleEventHandling {
  private let resolver: any MacAppResolving
  private let accessibility: AccessibilitySnapshotter
  private let screenshots: WindowScreenshotter
  private let snapshotCache: ElementSnapshotCache
  private let interactionTracker: AppInteractionTracker
  private let treeDiffer: AccessibilityTreeDiffer
  private let skyshotClassifier: SkyshotClassifier
  private let screenLockChecker: any ScreenLockChecking
  private let interventionArbitrator: any ComputerUseInterventionArbitrating
  private let policyEvaluator: any MacAppPolicyEvaluating
  private let sessionCoordinator: any ComputerUseSessionCoordinating

  public init(
    resolver: any MacAppResolving = MacAppResolver(),
    accessibility: AccessibilitySnapshotter = .init(),
    screenshots: WindowScreenshotter = .init(),
    snapshotCache: ElementSnapshotCache = .init(),
    interactionTracker: AppInteractionTracker = .init(),
    treeDiffer: AccessibilityTreeDiffer = .init(),
    skyshotClassifier: SkyshotClassifier = .init(),
    screenLockChecker: any ScreenLockChecking = CGSessionScreenLockChecker()
  ) {
    self.init(
      resolver: resolver,
      accessibility: accessibility,
      screenshots: screenshots,
      snapshotCache: snapshotCache,
      interactionTracker: interactionTracker,
      treeDiffer: treeDiffer,
      skyshotClassifier: skyshotClassifier,
      screenLockChecker: screenLockChecker,
      interventionArbitrator: ComputerUseInterventionCoordinator.shared,
      policyEvaluator: CodexAppServerMacAppPolicyEvaluator.shared,
      sessionCoordinator: ComputerUseSessionCoordinator.shared
    )
  }

  init(
    resolver: any MacAppResolving,
    accessibility: AccessibilitySnapshotter = .init(),
    screenshots: WindowScreenshotter = .init(),
    snapshotCache: ElementSnapshotCache = .init(),
    interactionTracker: AppInteractionTracker = .init(),
    treeDiffer: AccessibilityTreeDiffer = .init(),
    skyshotClassifier: SkyshotClassifier = .init(),
    screenLockChecker: any ScreenLockChecking = CGSessionScreenLockChecker(),
    interventionArbitrator: any ComputerUseInterventionArbitrating,
    policyEvaluator: any MacAppPolicyEvaluating = OfficialCompatibleMacAppPolicyEvaluator(),
    sessionCoordinator: any ComputerUseSessionCoordinating = NoopComputerUseSessionCoordinator()
  ) {
    self.resolver = resolver
    self.accessibility = accessibility
    self.screenshots = screenshots
    self.snapshotCache = snapshotCache
    self.interactionTracker = interactionTracker
    self.treeDiffer = treeDiffer
    self.skyshotClassifier = skyshotClassifier
    self.screenLockChecker = screenLockChecker
    self.interventionArbitrator = interventionArbitrator
    self.policyEvaluator = policyEvaluator
    self.sessionCoordinator = sessionCoordinator
  }

  public func getAppState(request: [String: Any]) throws -> [String: Any] {
    try screenLockChecker.requireUnlocked()
    let policyTarget = try resolver.resolveApplication(request["app"])
    try sessionCoordinator.requireNotStopped(policyTarget)
    let sessionScope = ComputerUseSessionOperationContext.begin(
      coordinator: sessionCoordinator,
      app: policyTarget
    )
    defer { sessionScope.end() }
    try policyEvaluator.requireAllowed(policyTarget)
    let app = try resolver.resolveOrLaunch(request["app"])
    let interventionCheckpoint = interventionArbitrator.stateRefreshCheckpoint(for: app)
    try RunLoopWaiter.wait(for: interactionTracker.remainingBaseSettleTime(for: app))
    let initialSnapshot = try captureWhenWindowIsReady(app: app)
    let snapshot = try captureUntilLoadingSettles(initialSnapshot, app: app)
    let disableDiff = request["disableDiff"] as? Bool ?? false
    let outputText = treeDiffer.output(for: snapshot, app: app, disableDiff: disableDiff)
    var skyshot: [String: Any] = ["text": outputText]
    var coordinateSpace: WindowCoordinateSpace?

    if skyshotClassifier.containsImage(snapshot),
      let window = try? resolver.frontWindow(for: app),
      let screenshot = try? screenshots.capture(
        windowID: window.windowID,
        processIdentifier: app.processIdentifier,
        screenFrame: window.screenFrame,
        bundleIdentifier: app.bundleIdentifier
      )
    {
      skyshot["screenshot"] = [
        "url": screenshot.url.absoluteString,
        "mimeType": "image/png",
        // The native PIP controller publishes streams by the skyshot's owner window,
        // not merely by application. Keep the capture identity alongside the image.
        "windowID": Int(window.windowID),
      ]
      coordinateSpace = WindowCoordinateSpace(
        windowID: window.windowID,
        screenFrame: window.screenFrame,
        screenshotPixelSize: screenshot.pixelSize
      )
    }
    try sessionScope.check()
    snapshotCache.store(snapshot, for: app, coordinateSpace: coordinateSpace)
    interventionArbitrator.recordFreshState(for: app, checkpoint: interventionCheckpoint)
    sessionCoordinator.recordActive(app)

    return [
      "app": [
        "bundleIdentifier": app.bundleIdentifier,
        "pid": Int(app.processIdentifier),
      ],
      "skyshot": skyshot,
    ]
  }

  private func captureWhenWindowIsReady(app: ResolvedMacApp) throws
    -> CapturedAccessibilitySnapshot
  {
    let deadline = Date().addingTimeInterval(5)
    while true {
      do {
        return try accessibility.capture(app: app)
      } catch AccessibilitySnapshotError.noWindow where Date() < deadline {
        try RunLoopWaiter.wait(for: 0.1)
      } catch {
        throw error
      }
    }
  }

  private func captureUntilLoadingSettles(
    _ initialSnapshot: CapturedAccessibilitySnapshot,
    app: ResolvedMacApp
  ) throws -> CapturedAccessibilitySnapshot {
    guard AccessibilityLoadingDetector.isLoading(initialSnapshot.text) else {
      return initialSnapshot
    }
    let deadline = Date().addingTimeInterval(5)
    var previous = initialSnapshot
    var stableSamples = 0
    while Date() < deadline {
      try RunLoopWaiter.wait(for: 0.2)
      let current = try accessibility.capture(app: app)
      if current.text == previous.text {
        stableSamples += 1
      } else {
        stableSamples = 0
      }
      previous = current
      if !AccessibilityLoadingDetector.isLoading(current.text) || stableSamples >= 2 {
        return current
      }
    }
    return previous
  }

  public func getAppPolicy(request: [String: Any]) throws -> [String: Any] {
    let app = try resolver.resolveApplication(request["app"])
    guard !app.appPath.isEmpty else {
      throw MacAppResolutionError.missingAppPath(app.displayName)
    }
    let policy = try policyEvaluator.policy(for: app)
    var target: [String: Any] = [
      "appPath": app.appPath,
      "bundleIdentifier": app.bundleIdentifier,
      "displayName": app.displayName,
      "risk": policy.risk.rawValue,
    ]
    if let warningSubtitle = policy.warningSubtitle {
      target["warningSubtitle"] = warningSubtitle
    }
    return [
      "allowPersistentApproval": policy.allowPersistentApproval,
      "decision": policy.decision.rawValue,
      "target": target,
    ]
  }

  public func deactivate(bundleIdentifier: String, threadID: String?) {
    snapshotCache.clear(bundleIdentifier: bundleIdentifier, threadID: threadID)
    interactionTracker.clear(bundleIdentifier: bundleIdentifier, threadID: threadID)
    treeDiffer.clear(bundleIdentifier: bundleIdentifier, threadID: threadID)
    screenshots.clear(bundleIdentifier: bundleIdentifier, threadID: threadID)
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    let endedThreadID: String?
    switch event {
    case .started:
      snapshotCache.clearUnscoped()
      interactionTracker.clearUnscoped()
      treeDiffer.clearUnscoped()
      screenshots.clearUnscoped()
      return
    case .transitioned(let previous, _), .ended(let previous),
      .safetyTerminated(let previous, _):
      endedThreadID = previous.threadID
    case .safetyRevoked:
      endedThreadID = nil
    }
    snapshotCache.clear(threadID: endedThreadID)
    interactionTracker.clear(threadID: endedThreadID)
    treeDiffer.clear(threadID: endedThreadID)
    screenshots.clear(threadID: endedThreadID)
  }
}

enum AccessibilityLoadingDetector {
  private static let roles = [
    "AXBusyIndicator",
    "AXProgressIndicator",
    "AXSpinner",
  ]

  static func isLoading(_ accessibilityText: String) -> Bool {
    roles.contains { accessibilityText.contains($0) }
  }
}
