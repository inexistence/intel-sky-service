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
  }

  private let lock = NSLock()
  private let environment: any ComputerUseFocusEnvironment
  private let interventionMonitor: any UserInterventionMonitoring
  private var activeTurn: ActiveTurn?

  init(
    environment: any ComputerUseFocusEnvironment = WorkspaceFocusEnvironment(),
    interventionMonitor: any UserInterventionMonitoring = PhysicalInputMonitor.shared
  ) {
    self.environment = environment
    self.interventionMonitor = interventionMonitor
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    let turnToRestore: ActiveTurn? = lock.withLock {
      switch event {
      case .started(let identity):
        activeTurn = ActiveTurn(identity: identity)
        return nil
      case .transitioned(let previous, let next):
        let previousTurn = activeTurn?.identity == previous ? activeTurn : nil
        activeTurn = ActiveTurn(identity: next)
        return previousTurn
      case .ended(let identity):
        guard activeTurn?.identity == identity else { return nil }
        let ended = activeTurn
        activeTurn = nil
        return ended
      case .safetyTerminated(let identity, _):
        guard activeTurn?.identity == identity else { return nil }
        // Never activate an application while the screen is locked or after the user
        // has taken control. A subsequent request starts a fresh turn baseline.
        activeTurn = nil
        return nil
      }
    }
    if let turnToRestore { restoreIfSafe(turnToRestore) }
  }

  func targetWillBeActivated(_ app: ResolvedMacApp) {
    let identityToCapture = lock.withLock { () -> ComputerUseTurnIdentity? in
      guard var turn = activeTurn else { return nil }
      turn.controlledProcessIdentifiers.insert(app.processIdentifier)
      let needsCapture = !turn.didCaptureRestoreTarget
      if needsCapture { turn.didCaptureRestoreTarget = true }
      activeTurn = turn
      return needsCapture ? turn.identity : nil
    }
    guard let identityToCapture else { return }

    let target = environment.captureRestoreTarget()
    let checkpoint = interventionMonitor.isAvailable ? interventionMonitor.checkpoint() : nil
    lock.withLock {
      guard var turn = activeTurn, turn.identity == identityToCapture,
        turn.didCaptureRestoreTarget
      else {
        return
      }
      turn.restoreTarget = target
      turn.interventionCheckpoint = checkpoint
      activeTurn = turn
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
    environment.restore(target)
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
