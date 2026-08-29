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
  coordinator.setStopHandler { stopRecorder.record($0) }
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

private func sessionTestApp(bundleIdentifier: String, name: String) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: 321,
    bundleIdentifier: bundleIdentifier,
    displayName: name,
    appPath: "/Applications/\(name).app"
  )
}
