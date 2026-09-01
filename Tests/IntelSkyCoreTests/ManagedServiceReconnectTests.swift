import Foundation
import Testing

@testable import IntelSkyCore

@Test func managedReconnectNotificationMatchesOfficialStatusItemEnvelope() {
  let info = ManagedServiceReconnectNotification.userInfo(processIdentifier: 42)

  #expect(
    ManagedServiceReconnectNotification.name.rawValue
      == "com.openai.codex.computer-use.status-item-state-changed"
  )
  #expect((info["processIdentifier"] as? NSNumber)?.int32Value == 42)
  #expect((info["computerUseActive"] as? NSNumber)?.boolValue == false)
  #expect(info["computerHistoryState"] as? String == "stopped")
}

@Test func activeStatusNotificationUsesOfficialEnvelope() {
  let info = ManagedServiceReconnectNotification.userInfo(
    processIdentifier: 321,
    computerUseActive: true
  )

  #expect((info["processIdentifier"] as? NSNumber)?.int32Value == 321)
  #expect((info["computerUseActive"] as? NSNumber)?.boolValue == true)
  #expect(info["computerHistoryState"] as? String == "stopped")
}

@Test func managedReconnectWatchdogModeRequiresTwoDistinctProcessIdentifiers() {
  #expect(
    ManagedServiceReconnectWatchdogMode.parse(arguments: [
      "--notify-managed-service-exit", "42", "84",
    ])?.servicePID == 42
  )
  #expect(
    ManagedServiceReconnectWatchdogMode.parse(arguments: [
      "--notify-managed-service-exit", "42", "84",
    ])?.hostPID == 84
  )
  #expect(ManagedServiceReconnectWatchdogMode.parse(arguments: []) == nil)
  #expect(
    ManagedServiceReconnectWatchdogMode.parse(arguments: [
      "--notify-managed-service-exit", "42", "42",
    ]) == nil
  )
  #expect(
    ManagedServiceReconnectWatchdogMode.parse(arguments: [
      "--notify-managed-service-exit", "not-a-pid", "84",
    ]) == nil
  )
}

@Test func managedReconnectWatchdogLauncherIsIdempotentPerHost() throws {
  let recorder = ReconnectProcessRecorder()
  let launcher = ManagedServiceReconnectWatchdogLauncher(
    executableURL: URL(fileURLWithPath: "/tmp/SkyComputerUseService"),
    processStarter: { executableURL, arguments in
      recorder.record(executableURL: executableURL, arguments: arguments)
    }
  )

  #expect(launcher.start(servicePID: 42, hostPID: 84))
  #expect(launcher.start(servicePID: 42, hostPID: 84))
  #expect(launcher.start(servicePID: 42, hostPID: 85))
  #expect(recorder.invocations.count == 2)
  #expect(
    recorder.invocations.first?.arguments
      == ["--notify-managed-service-exit", "42", "84"]
  )
}

@Test func launchServicesFallbackYieldsSocketToChatGPTManagedRespawn() {
  #expect(
    ManagedServiceLaunchPolicy.socketBindDelay(arguments: [], parentProcessIdentifier: 1)
      == 1
  )
  #expect(
    ManagedServiceLaunchPolicy.socketBindDelay(arguments: [], parentProcessIdentifier: 42)
      == 0
  )
  #expect(
    ManagedServiceLaunchPolicy.socketBindDelay(
      arguments: ["--socket", "/tmp/test.sock"],
      parentProcessIdentifier: 1
    ) == 0
  )
}

private final class ReconnectProcessRecorder: @unchecked Sendable {
  struct Invocation {
    let executableURL: URL
    let arguments: [String]
  }

  private let lock = NSLock()
  private var storedInvocations: [Invocation] = []
  var invocations: [Invocation] { lock.withLock { storedInvocations } }

  func record(executableURL: URL, arguments: [String]) {
    lock.withLock {
      storedInvocations.append(
        Invocation(executableURL: executableURL, arguments: arguments)
      )
    }
  }
}
