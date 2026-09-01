import AppKit
import ApplicationServices
import Foundation

struct CapturedFocusRestoreTarget: @unchecked Sendable {
  let processIdentifier: pid_t
  let focusedWindow: AXUIElement?
}

protocol ComputerUseFocusEnvironment: Sendable {
  func captureRestoreTarget() -> CapturedFocusRestoreTarget?
  func currentFrontmostProcessIdentifier() -> pid_t?
  func restore(_ target: CapturedFocusRestoreTarget)
}

protocol ComputerUseFocusArbitrating: Sendable {
  func targetWillBeActivated(_ app: ResolvedMacApp)
}

enum TurnScopedSyntheticFocusResult<Value> {
  case unavailable
  case executed(Value)
}

final class ComputerUseFocusCoordinator: ComputerUseFocusArbitrating,
  ComputerUseTurnLifecycleEventHandling, @unchecked Sendable
{
  static let shared = ComputerUseFocusCoordinator()

  private struct ActiveTurn {
    let identity: ComputerUseTurnIdentity
    var didCaptureRestoreTarget = false
    var restoreTarget: CapturedFocusRestoreTarget?
    var interventionCheckpoint: UInt64?
    var controlledProcessIdentifiers: Set<pid_t> = []
    var syntheticFocusLease: SyntheticFocusLease?
  }

  private struct SyntheticFocusLease {
    let target: ComputerUseEventTarget
    let protection: SystemFocusStealGuard.Protection
  }

  private struct FinishedTurn {
    let turn: ActiveTurn
    let shouldRestore: Bool
  }

  private let lock = NSLock()
  private let environment: any ComputerUseFocusEnvironment
  private let interventionMonitor: any UserInterventionMonitoring
  private let isApplicationActive: @Sendable (pid_t) -> Bool
  private let postSyntheticFocusEvent:
    @Sendable (SyntheticFocusEventDescriptor, ComputerUseEventTarget) throws -> Void
  private let beginFocusProtection: @Sendable (pid_t) -> SystemFocusStealGuard.Protection
  private let endFocusProtection: @Sendable (SystemFocusStealGuard.Protection) -> Void
  private var activeTurns: [String: ActiveTurn] = [:]

  init(
    environment: any ComputerUseFocusEnvironment = WorkspaceFocusEnvironment(),
    interventionMonitor: any UserInterventionMonitoring = PhysicalInputMonitor.shared,
    isApplicationActive: @escaping @Sendable (pid_t) -> Bool = {
      NSRunningApplication(processIdentifier: $0)?.isActive == true
    },
    postSyntheticFocusEvent: @escaping @Sendable (
      SyntheticFocusEventDescriptor, ComputerUseEventTarget
    ) throws -> Void = { descriptor, target in
      try ProcessTargetedEventPoster.postOtherEvent(descriptor, to: target)
    },
    beginFocusProtection: @escaping @Sendable (pid_t) -> SystemFocusStealGuard.Protection = {
      SystemFocusStealGuard.shared.beginProtecting(processIdentifier: $0)
    },
    endFocusProtection: @escaping @Sendable (SystemFocusStealGuard.Protection) -> Void = {
      SystemFocusStealGuard.shared.endProtecting($0)
    }
  ) {
    self.environment = environment
    self.interventionMonitor = interventionMonitor
    self.isApplicationActive = isApplicationActive
    self.postSyntheticFocusEvent = postSyntheticFocusEvent
    self.beginFocusProtection = beginFocusProtection
    self.endFocusProtection = endFocusProtection
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    let finishedTurns: [FinishedTurn] = lock.withLock {
      switch event {
      case .started(let identity):
        activeTurns[identity.threadID] = ActiveTurn(identity: identity)
        return []
      case .transitioned(let previous, let next):
        let previousTurn =
          activeTurns[previous.threadID]?.identity == previous
          ? activeTurns.removeValue(forKey: previous.threadID) : nil
        activeTurns[next.threadID] = ActiveTurn(identity: next)
        return previousTurn.map { [FinishedTurn(turn: $0, shouldRestore: true)] } ?? []
      case .ended(let identity):
        guard activeTurns[identity.threadID]?.identity == identity,
          let ended = activeTurns.removeValue(forKey: identity.threadID)
        else { return [] }
        return [FinishedTurn(turn: ended, shouldRestore: true)]
      case .safetyTerminated(let identity, _):
        guard activeTurns[identity.threadID]?.identity == identity,
          let terminated = activeTurns.removeValue(forKey: identity.threadID)
        else { return [] }
        // Never activate an application while the screen is locked or after the user
        // has taken control. A subsequent request starts a fresh turn baseline.
        return [FinishedTurn(turn: terminated, shouldRestore: false)]
      case .safetyRevoked:
        // Unscoped safety revocation must also forget any partially reconstructed turn and must
        // never restore focus while the screen is locked or the user has taken control.
        let revoked = activeTurns.values.map {
          FinishedTurn(turn: $0, shouldRestore: false)
        }
        activeTurns.removeAll()
        return revoked
      }
    }
    for finishedTurn in finishedTurns {
      endSyntheticFocusLease(finishedTurn.turn.syntheticFocusLease, deactivateIfInactive: true)
      if finishedTurn.shouldRestore { restoreIfSafe(finishedTurn.turn) }
    }
  }

  func withTurnScopedSyntheticFocus<T>(
    on target: ComputerUseEventTarget,
    _ body: () throws -> T
  ) throws -> TurnScopedSyntheticFocusResult<T> {
    let canExecute = try lock.withLock { () throws -> Bool in
      guard let threadID = selectedThreadIDLocked(), var turn = activeTurns[threadID] else {
        return false
      }

      if let lease = turn.syntheticFocusLease {
        if lease.target == target, !isApplicationActive(target.processIdentifier) {
          return true
        }
        endSyntheticFocusLease(lease, deactivateIfInactive: true)
        turn.syntheticFocusLease = nil
        activeTurns[threadID] = turn
      }

      guard !isApplicationActive(target.processIdentifier) else {
        activeTurns[threadID] = turn
        return true
      }

      let protection = beginFocusProtection(target.processIdentifier)
      let sequence = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)
      var postedBeginEvent = false
      do {
        for descriptor in sequence.begin {
          try postSyntheticFocusEvent(descriptor, target)
          postedBeginEvent = true
        }
      } catch {
        if postedBeginEvent, !isApplicationActive(target.processIdentifier) {
          for descriptor in sequence.end {
            try? postSyntheticFocusEvent(descriptor, target)
          }
        }
        endFocusProtection(protection)
        throw error
      }
      turn.syntheticFocusLease = SyntheticFocusLease(target: target, protection: protection)
      activeTurns[threadID] = turn
      return true
    }
    guard canExecute else { return .unavailable }

    do {
      let result = try body()
      releaseLeaseIfApplicationBecameActive(target)
      return .executed(result)
    } catch {
      releaseMatchingLease(target, deactivateIfInactive: true)
      throw error
    }
  }

  func targetWillBeActivated(_ app: ResolvedMacApp) {
    let identityToCapture = lock.withLock { () -> ComputerUseTurnIdentity? in
      guard let threadID = selectedThreadIDLocked(), var turn = activeTurns[threadID] else {
        return nil
      }
      turn.controlledProcessIdentifiers.insert(app.processIdentifier)
      let needsCapture = !turn.didCaptureRestoreTarget
      if needsCapture { turn.didCaptureRestoreTarget = true }
      activeTurns[threadID] = turn
      return needsCapture ? turn.identity : nil
    }
    guard let identityToCapture else { return }

    let target = environment.captureRestoreTarget()
    let checkpoint = interventionMonitor.isAvailable ? interventionMonitor.checkpoint() : nil
    lock.withLock {
      guard var turn = activeTurns[identityToCapture.threadID], turn.identity == identityToCapture,
        turn.didCaptureRestoreTarget
      else {
        return
      }
      turn.restoreTarget = target
      turn.interventionCheckpoint = checkpoint
      activeTurns[identityToCapture.threadID] = turn
    }
  }

  private func restoreIfSafe(_ turn: ActiveTurn) {
    guard let target = turn.restoreTarget else { return }
    if let checkpoint = turn.interventionCheckpoint,
      interventionMonitor.isAvailable,
      interventionMonitor.checkpoint() != checkpoint
    {
      return
    }
    guard let currentPID = environment.currentFrontmostProcessIdentifier(),
      turn.controlledProcessIdentifiers.contains(currentPID)
    else {
      return
    }
    guard
      !lock.withLock({
        activeTurns.values.contains { $0.controlledProcessIdentifiers.contains(currentPID) }
      })
    else { return }
    environment.restore(target)
  }

  private func releaseLeaseIfApplicationBecameActive(_ target: ComputerUseEventTarget) {
    guard isApplicationActive(target.processIdentifier) else { return }
    releaseMatchingLease(target, deactivateIfInactive: false)
  }

  private func releaseMatchingLease(
    _ target: ComputerUseEventTarget,
    deactivateIfInactive: Bool
  ) {
    let lease = lock.withLock { () -> SyntheticFocusLease? in
      guard let threadID = selectedThreadIDLocked(), var turn = activeTurns[threadID],
        turn.syntheticFocusLease?.target == target
      else { return nil }
      let lease = turn.syntheticFocusLease
      turn.syntheticFocusLease = nil
      activeTurns[threadID] = turn
      return lease
    }
    endSyntheticFocusLease(lease, deactivateIfInactive: deactivateIfInactive)
  }

  private func selectedThreadIDLocked() -> String? {
    if let threadID = ComputerUseTurnContext.threadID, activeTurns[threadID] != nil {
      return threadID
    }
    return activeTurns.count == 1 ? activeTurns.keys.first : nil
  }

  private func endSyntheticFocusLease(
    _ lease: SyntheticFocusLease?,
    deactivateIfInactive: Bool
  ) {
    guard let lease else { return }
    defer { endFocusProtection(lease.protection) }
    guard deactivateIfInactive, !isApplicationActive(lease.target.processIdentifier) else { return }
    for descriptor in ProcessTargetedEventPoster.syntheticFocusSequence(for: lease.target).end {
      try? postSyntheticFocusEvent(descriptor, lease.target)
    }
  }
}

struct WorkspaceFocusEnvironment: ComputerUseFocusEnvironment {
  func captureRestoreTarget() -> CapturedFocusRestoreTarget? {
    guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return nil }
    let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    let focusedWindow: AXUIElement?
    if AXUIElementCopyAttributeValue(
      applicationElement,
      kAXFocusedWindowAttribute as CFString,
      &value
    ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    {
      focusedWindow = unsafeDowncast(value, to: AXUIElement.self)
    } else {
      focusedWindow = nil
    }
    return CapturedFocusRestoreTarget(
      processIdentifier: app.processIdentifier,
      focusedWindow: focusedWindow
    )
  }

  func currentFrontmostProcessIdentifier() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  func restore(_ target: CapturedFocusRestoreTarget) {
    guard
      let app = NSRunningApplication(processIdentifier: target.processIdentifier),
      !app.isTerminated
    else {
      return
    }
    _ = app.activate(options: [])
    if let focusedWindow = target.focusedWindow {
      _ = AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
    }
  }
}
