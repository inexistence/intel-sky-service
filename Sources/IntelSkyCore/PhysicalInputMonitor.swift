import CoreGraphics
import Foundation

protocol UserInterventionMonitoring: AnyObject, Sendable {
  var isAvailable: Bool { get }
  func checkpoint() -> UInt64
  func checkpoint(for processIdentifier: pid_t) -> UInt64
}

extension UserInterventionMonitoring {
  func checkpoint(for processIdentifier: pid_t) -> UInt64 { checkpoint() }
}

public final class PhysicalInputMonitor: UserInterventionMonitoring, @unchecked Sendable {
  public static let shared = PhysicalInputMonitor()

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var unknownTargetGeneration: UInt64 = 0
  private var generationByTargetProcess: [pid_t: UInt64] = [:]
  private var available = false

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

  func record(_ event: CGEvent) {
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    guard sourcePID != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
    let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
    lock.withLock {
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
    }
  }

  private func runEventTap() {
    let types: [CGEventType] = [
      .keyDown,
      .leftMouseDown,
      .rightMouseDown,
      .otherMouseDown,
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
    lock.withLock { available = true }
    CFRunLoopRun()
  }
}

private func physicalInputTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    return Unmanaged.passUnretained(event)
  }
  if let userInfo {
    Unmanaged<PhysicalInputMonitor>.fromOpaque(userInfo).takeUnretainedValue().record(event)
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
  @unchecked Sendable
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
    guard
      let baseline = lock.withLock({ baselineByBundleIdentifier[app.bundleIdentifier] }),
      baseline.processIdentifier == app.processIdentifier
    else {
      return
    }
    guard monitor.checkpoint(for: app.processIdentifier) == baseline.checkpoint else {
      throw SkySafetyError.userIntervened
    }
  }
}

struct NoopComputerUseInterventionArbitrator: ComputerUseInterventionArbitrating {
  func stateRefreshCheckpoint(for app: ResolvedMacApp) -> UInt64? { nil }
  func recordFreshState(for app: ResolvedMacApp, checkpoint: UInt64?) {}
  func requireFreshState(for app: ResolvedMacApp) throws {}
}
