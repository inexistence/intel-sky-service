import Foundation
import Testing

@testable import IntelSkyCore

@Test func sessionRegistryPublishesExactStatusMenuShape() throws {
  let coordinator = ComputerUseSessionCoordinator()
  coordinator.recordActive(sessionTestApp(bundleIdentifier: "com.example.zed", name: "Zed"))
  coordinator.recordActive(sessionTestApp(bundleIdentifier: "com.example.alpha", name: "Alpha"))

  let state = coordinator.statusItemMenuState()
  let computerUse = try #require(state["computerUse"] as? [String: Any])
  let applications = try #require(computerUse["activeApplications"] as? [[String: Any]])
  let history = try #require(state["computerHistory"] as? [String: Any])
  let clear = try #require(history["canClearHistory"] as? [String: Any])

  #expect(applications.count == 2)
  #expect(applications[0]["id"] as? String == "com.example.alpha")
  #expect(applications[0]["name"] as? String == "Alpha")
  #expect(applications[0]["bundleIdentifier"] as? String == "com.example.alpha")
  #expect(applications[0]["bundleURL"] as? String == "/Applications/Alpha.app")
  #expect(history["state"] as? String == "stopped")
  #expect(clear["lastTenMinutes"] as? Bool == false)
  #expect(clear["lastHour"] as? Bool == false)
  #expect(clear["lastDay"] as? Bool == false)
  #expect((history["recentApplications"] as? [Any])?.isEmpty == true)
}

@Test func userStopLatchesUntilTurnBoundaryAndInvokesPresentationHandler() throws {
  let coordinator = ComputerUseSessionCoordinator()
  let stopRecorder = SessionStopRecorder()
  coordinator.setStopHandler { bundleIdentifier, _ in stopRecorder.record(bundleIdentifier) }
  let app = sessionTestApp(bundleIdentifier: "com.example.fixture", name: "Fixture")
  let target = ResolvedMacApplication(app)
  #expect(throws: ComputerUseSessionError.self) {
    try coordinator.requireActionAllowed(target)
  }
  coordinator.recordActive(app)
  try coordinator.requireActionAllowed(target)

  let response = try coordinator.stopApplication(request: ["app": app.bundleIdentifier])

  #expect(response.isEmpty)
  #expect(stopRecorder.bundleIdentifiers == [app.bundleIdentifier])
  #expect(throws: SkySafetyError.self) { try coordinator.requireNotStopped(target) }
  let stoppedState = coordinator.statusItemMenuState()
  let stoppedUse = try #require(stoppedState["computerUse"] as? [String: Any])
  #expect((stoppedUse["activeApplications"] as? [Any])?.isEmpty == true)

  let identity = try #require(
    ComputerUseTurnIdentity(metadata: [
      "session_id": "session", "thread_id": "thread", "turn_id": "next",
    ]))
  coordinator.handle(.started(identity))
  try coordinator.requireNotStopped(target)
  #expect(throws: ComputerUseSessionError.self) {
    try coordinator.requireActionAllowed(target)
  }
}

@Test func stopRejectsMalformedAndInactiveTargets() {
  let coordinator = ComputerUseSessionCoordinator()

  #expect(throws: ComputerUseSessionError.self) {
    _ = try coordinator.stopApplication(request: [:])
  }
  #expect(throws: ComputerUseSessionError.self) {
    _ = try coordinator.stopApplication(request: ["app": "com.example.missing"])
  }
}

@Test func applicationSetChangesRefreshMenuWhileAnotherThreadRemainsActive() throws {
  let notifications = SessionStatusRecorder()
  let coordinator = ComputerUseSessionCoordinator { notifications.record($0) }
  let first = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "first", "turn_id": "1"])
  )
  let second = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "second", "turn_id": "1"])
  )
  let firstApp = sessionTestApp(bundleIdentifier: "com.example.first", name: "First")
  let secondApp = sessionTestApp(bundleIdentifier: "com.example.second", name: "Second")

  ComputerUseTurnContext.withIdentity(first) { coordinator.recordActive(firstApp) }
  ComputerUseTurnContext.withIdentity(second) { coordinator.recordActive(secondApp) }
  coordinator.handle(.ended(first))

  let activeState = coordinator.statusItemMenuState()
  let computerUse = try #require(activeState["computerUse"] as? [String: Any])
  let applications = try #require(computerUse["activeApplications"] as? [[String: Any]])
  #expect(applications.map { $0["bundleIdentifier"] as? String } == ["com.example.second"])
  // Repeated `true` publications refresh ChatGPT's full application menu even though
  // the aggregate Computer Use state remains active.
  #expect(notifications.values == [true, true, true])

  coordinator.handle(.ended(second))
  #expect(notifications.values == [true, true, true, false])
}

@Test func ownershipChangesDoNotRefreshMenuWhenVisibleApplicationSetIsUnchanged() throws {
  let notifications = SessionStatusRecorder()
  let coordinator = ComputerUseSessionCoordinator { notifications.record($0) }
  let first = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "first", "turn_id": "1"])
  )
  let second = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "second", "turn_id": "1"])
  )
  let app = sessionTestApp(bundleIdentifier: "com.example.shared", name: "Shared")

  ComputerUseTurnContext.withIdentity(first) { coordinator.recordActive(app) }
  ComputerUseTurnContext.withIdentity(second) { coordinator.recordActive(app) }
  coordinator.handle(.ended(first))

  #expect(notifications.values == [true])

  coordinator.handle(.ended(second))
  #expect(notifications.values == [true, false])
}

@Test func appModificationTransitionsReturnConfirmedAppStateShape() throws {
  let coordinator = ComputerUseSessionCoordinator()
  let app = sessionTestApp(bundleIdentifier: "com.example.fixture", name: "Fixture")

  let activeState = try coordinator.activateApplication(app)
  let currentApp = try #require(activeState["currentApp"] as? [String: Any])
  #expect(activeState["active"] as? Bool == true)
  #expect(currentApp["pid"] as? Int == Int(app.processIdentifier))
  #expect(currentApp["bundleIdentifier"] as? String == app.bundleIdentifier)
  #expect(currentApp["appPath"] as? String == app.appPath)
  try coordinator.requireActionAllowed(ResolvedMacApplication(app))

  let inactiveState = try coordinator.deactivateApplication(app)
  #expect(inactiveState["active"] as? Bool == false)
  #expect(inactiveState["currentApp"] is NSNull)
  #expect(throws: ComputerUseSessionError.self) {
    try coordinator.requireActionAllowed(ResolvedMacApplication(app))
  }

  // A normal deactivation is not the user-stop latch and can be reactivated in the same turn.
  _ = try coordinator.activateApplication(app)
  try coordinator.requireNotStopped(ResolvedMacApplication(app))
}

@Test func userStopCancelsAnInFlightOperationCheckpoint() throws {
  let coordinator = ComputerUseSessionCoordinator()
  let app = sessionTestApp(bundleIdentifier: "com.example.fixture", name: "Fixture")
  coordinator.recordActive(app)
  let scope = ComputerUseSessionOperationContext.begin(
    coordinator: coordinator,
    app: ResolvedMacApplication(app)
  )
  defer { scope.end() }

  try RequestDeadlineContext.check()
  _ = try coordinator.stopApplication(request: ["app": app.bundleIdentifier])

  #expect(throws: SkySafetyError.self) { try RequestDeadlineContext.check() }
}

private final class SessionStopRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var bundleIdentifiers: [String] { lock.withLock { stored } }
  func record(_ bundleIdentifier: String) { lock.withLock { stored.append(bundleIdentifier) } }
}

private final class SessionStatusRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var values: [Bool] = []
  func record(_ value: Bool) { lock.withLock { values.append(value) } }
}

private func sessionTestApp(bundleIdentifier: String, name: String) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: 321,
    bundleIdentifier: bundleIdentifier,
    displayName: name,
    appPath: "/Applications/\(name).app"
  )
}
