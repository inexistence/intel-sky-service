import CoreGraphics
import Foundation

protocol UserInterventionMonitoring: AnyObject, Sendable {
  var isAvailable: Bool { get }
  func checkpoint() -> UInt64
  func checkpoint(for processIdentifier: pid_t) -> UInt64
}

protocol EventStreamInputMonitoring: AnyObject, Sendable {
  var isAvailable: Bool { get }
  func addEventObserver(
    _ observer: @escaping @Sendable (CGEventType, CGEvent) -> Void
  ) -> UUID
  func removeEventObserver(_ identifier: UUID)
}

extension UserInterventionMonitoring {
  func checkpoint(for processIdentifier: pid_t) -> UInt64 { checkpoint() }
}

public final class PhysicalInputMonitor: UserInterventionMonitoring, EventStreamInputMonitoring,
  @unchecked Sendable
{
  public static let shared = PhysicalInputMonitor()

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var unknownTargetGeneration: UInt64 = 0
  private var generationByTargetProcess: [pid_t: UInt64] = [:]
  private var available = false
  private var eventObservers: [UUID: @Sendable (CGEventType, CGEvent) -> Void] = [:]
  private var eventTap: CFMachPort?

  public var isAvailable: Bool { lock.withLock { available } }

  public init() {
    startMonitoringIfAuthorized()
  }

  init(startMonitoring: Bool) {
    if startMonitoring { startMonitoringIfAuthorized() }
  }

  private func startMonitoringIfAuthorized() {
    guard CGPreflightListenEventAccess() else { return }
    Thread.detachNewThread { [self] in runEventTap() }
  }

  func checkpoint() -> UInt64 { lock.withLock { generation } }

  func checkpoint(for processIdentifier: pid_t) -> UInt64 {
    lock.withLock {
      unknownTargetGeneration &+ (generationByTargetProcess[processIdentifier] ?? 0)
    }
  }

  func addEventObserver(
    _ observer: @escaping @Sendable (CGEventType, CGEvent) -> Void
  ) -> UUID {
    let identifier = UUID()
    lock.withLock { eventObservers[identifier] = observer }
    return identifier
  }

  func removeEventObserver(_ identifier: UUID) {
    _ = lock.withLock { eventObservers.removeValue(forKey: identifier) }
  }

  func record(_ event: CGEvent, type: CGEventType) {
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    guard sourcePID != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
    let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
    let observers = lock.withLock { () -> [@Sendable (CGEventType, CGEvent) -> Void] in
      generation &+= 1
      if targetPID > 0 {
        if generationByTargetProcess[targetPID] == nil,
          generationByTargetProcess.count >= 256
        {
          generationByTargetProcess.removeAll(keepingCapacity: true)
          unknownTargetGeneration &+= 1
        }
        generationByTargetProcess[targetPID, default: 0] &+= 1
      } else {
        // An unresolved physical target must conservatively invalidate every controlled app.
        unknownTargetGeneration &+= 1
      }
      return Array(eventObservers.values)
    }
    for observer in observers { observer(type, event) }
  }

  func record(_ event: CGEvent) {
    record(event, type: event.type)
  }

  func reenableEventTap() {
    guard let tap = lock.withLock({ eventTap }) else { return }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func runEventTap() {
    let types: [CGEventType] = [
      .keyDown,
      .leftMouseDown,
      .leftMouseUp,
      .rightMouseDown,
      .rightMouseUp,
      .otherMouseDown,
      .otherMouseUp,
      .mouseMoved,
      .leftMouseDragged,
      .rightMouseDragged,
      .otherMouseDragged,
      .scrollWheel,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: physicalInputTapCallback,
        userInfo: refcon
      ),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      return
    }
    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    lock.withLock {
      eventTap = tap
      available = true
    }
    CFRunLoopRun()
    lock.withLock {
      if eventTap === tap { eventTap = nil }
      available = false
    }
  }
}

private func physicalInputTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let userInfo {
      Unmanaged<PhysicalInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        .reenableEventTap()
    }
    return Unmanaged.passUnretained(event)
  }
  if let userInfo {
    Unmanaged<PhysicalInputMonitor>.fromOpaque(userInfo).takeUnretainedValue().record(
      event,
      type: type
    )
  }
  return Unmanaged.passUnretained(event)
}

final class NoopUserInterventionMonitor: UserInterventionMonitoring, @unchecked Sendable {
  var isAvailable: Bool { false }
  func checkpoint() -> UInt64 { 0 }
}

enum UserInterventionContext {
  private static let key = "dev.huangjianbin.intel-sky-service.user-intervention"

  final class Checkpoint: NSObject {
    let monitor: any UserInterventionMonitoring
    let generation: UInt64

    init(monitor: any UserInterventionMonitoring, processIdentifier: pid_t?) {
      self.monitor = monitor
      self.processIdentifier = processIdentifier
      self.generation =
        processIdentifier.map { monitor.checkpoint(for: $0) } ?? monitor.checkpoint()
    }

    let processIdentifier: pid_t?

    func check() throws {
      let current = processIdentifier.map { monitor.checkpoint(for: $0) } ?? monitor.checkpoint()
      guard monitor.isAvailable, current != generation else { return }
      throw SkySafetyError.userIntervened
    }
  }

  struct Scope {
    let previous: Any?
    let checkpoint: Checkpoint

    func check() throws { try checkpoint.check() }

    func end() {
      let dictionary = Thread.current.threadDictionary
      if let previous {
        dictionary[key] = previous
      } else {
        dictionary.removeObject(forKey: key)
      }
    }
  }

  static func begin(
    monitor: any UserInterventionMonitoring,
    processIdentifier: pid_t? = nil
  ) -> Scope {
    let dictionary = Thread.current.threadDictionary
    let scope = Scope(
      previous: dictionary[key],
      checkpoint: Checkpoint(monitor: monitor, processIdentifier: processIdentifier)
    )
    dictionary[key] = scope.checkpoint
    return scope
  }

  static func check() throws {
    try (Thread.current.threadDictionary[key] as? Checkpoint)?.check()
  }
}

protocol ComputerUseInterventionArbitrating: Sendable {
  func stateRefreshCheckpoint(for app: ResolvedMacApp) -> UInt64?
  func recordFreshState(for app: ResolvedMacApp, checkpoint: UInt64?)
  func requireFreshState(for app: ResolvedMacApp) throws
}

final class ComputerUseInterventionCoordinator: ComputerUseInterventionArbitrating,
  ComputerUseTurnLifecycleEventHandling, @unchecked Sendable
{
  static let shared = ComputerUseInterventionCoordinator()

  private struct Baseline {
    let processIdentifier: pid_t
    let checkpoint: UInt64
  }

  private let lock = NSLock()
  private let monitor: any UserInterventionMonitoring
  private var baselineByBundleIdentifier: [String: Baseline] = [:]

  init(monitor: any UserInterventionMonitoring = PhysicalInputMonitor.shared) {
    self.monitor = monitor
  }

  func stateRefreshCheckpoint(for app: ResolvedMacApp) -> UInt64? {
    guard monitor.isAvailable else { return nil }
    return monitor.checkpoint(for: app.processIdentifier)
  }

  func recordFreshState(for app: ResolvedMacApp, checkpoint: UInt64?) {
    guard monitor.isAvailable, let checkpoint else { return }
    let baseline = Baseline(
      processIdentifier: app.processIdentifier,
      checkpoint: checkpoint
    )
    lock.withLock { baselineByBundleIdentifier[app.bundleIdentifier] = baseline }
  }

  func requireFreshState(for app: ResolvedMacApp) throws {
    guard monitor.isAvailable else { return }
    guard let baseline = lock.withLock({ baselineByBundleIdentifier[app.bundleIdentifier] }) else {
      throw SkySafetyError.userIntervened
    }
    // PID replacement is rejected by the snapshot cache with its more specific stale-session error.
    guard baseline.processIdentifier == app.processIdentifier else { return }
    guard monitor.checkpoint(for: app.processIdentifier) == baseline.checkpoint else {
      throw SkySafetyError.userIntervened
    }
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    // A state snapshot authorizes actions only within the turn that produced it.
    // Clearing on start as well as transition/end also fails closed after a service-side
    // lifecycle reconstruction.
    lock.withLock { baselineByBundleIdentifier.removeAll() }
  }
}

struct NoopComputerUseInterventionArbitrator: ComputerUseInterventionArbitrating {
  func stateRefreshCheckpoint(for app: ResolvedMacApp) -> UInt64? { nil }
  func recordFreshState(for app: ResolvedMacApp, checkpoint: UInt64?) {}
  func requireFreshState(for app: ResolvedMacApp) throws {}
}
