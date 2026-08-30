import Foundation
import Testing

@testable import IntelSkyCore

@Test func screenLockMonitorEmitsOncePerLockedEpisode() {
  let state = MutableScreenLockState(false)
  let recorder = LockEpisodeRecorder()
  let monitor = ComputerUseScreenLockMonitor(stateReader: state) { recorder.record() }
  monitor.start()
  defer { monitor.stop() }

  monitor.poll()
  state.locked = true
  monitor.poll()
  monitor.poll()
  state.locked = false
  monitor.poll()
  state.locked = true
  monitor.poll()

  #expect(recorder.count == 2)
}

@Test func screenLockMonitorFailsClosedWhenInitiallyLocked() {
  let recorder = LockEpisodeRecorder()
  let monitor = ComputerUseScreenLockMonitor(stateReader: MutableScreenLockState(true)) {
    recorder.record()
  }
  monitor.start()
  defer { monitor.stop() }

  monitor.poll()
  monitor.poll()

  #expect(recorder.count == 1)
}

@Test func routerProactivelyTerminatesCurrentTurnOnScreenLock() {
  let lifecycle = RecordingScreenLockLifecycle()
  let router = SkyRequestRouter(
    appCatalog: EmptyScreenLockAppCatalog(),
    appStateProvider: nil,
    appActionPerformer: nil,
    turnLifecycle: lifecycle
  )

  router.screenDidLock()

  #expect(lifecycle.reasons == [.screenLocked])
}

private final class MutableScreenLockState: ScreenLockStateReading, @unchecked Sendable {
  private let lock = NSLock()
  private var storedLocked: Bool

  init(_ locked: Bool) { storedLocked = locked }

  var locked: Bool {
    get { lock.withLock { storedLocked } }
    set { lock.withLock { storedLocked = newValue } }
  }

  func isScreenLocked() -> Bool { locked }
}

private final class LockEpisodeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0
  var count: Int { lock.withLock { storedCount } }
  func record() { lock.withLock { storedCount += 1 } }
}

private final class RecordingScreenLockLifecycle: ComputerUseTurnLifecycleHandling,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedReasons: [ComputerUseTurnSafetyTerminationReason] = []
  var reasons: [ComputerUseTurnSafetyTerminationReason] { lock.withLock { storedReasons } }

  func observe(metadata: Any?) {}
  func end(request: [String: Any]) {}
  func terminateForSafety(_ reason: ComputerUseTurnSafetyTerminationReason) {
    lock.withLock { storedReasons.append(reason) }
  }
}

private struct EmptyScreenLockAppCatalog: AppCatalog {
  func listApps() throws -> [[String: Any]] { [] }
}
