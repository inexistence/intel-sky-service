import CoreGraphics
import Foundation

protocol UserInterventionMonitoring: AnyObject, Sendable {
  var isAvailable: Bool { get }
  func checkpoint() -> UInt64
}

public final class PhysicalInputMonitor: UserInterventionMonitoring, @unchecked Sendable {
  public static let shared = PhysicalInputMonitor()

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var available = false

  public var isAvailable: Bool { lock.withLock { available } }

  public init() {
    guard CGPreflightListenEventAccess() else { return }
    Thread.detachNewThread { [self] in runEventTap() }
  }

  func checkpoint() -> UInt64 { lock.withLock { generation } }

  fileprivate func record(_ event: CGEvent) {
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    guard sourcePID != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
    lock.withLock { generation &+= 1 }
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

    init(monitor: any UserInterventionMonitoring) {
      self.monitor = monitor
      self.generation = monitor.checkpoint()
    }

    func check() throws {
      guard monitor.isAvailable, monitor.checkpoint() != generation else { return }
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

  static func begin(monitor: any UserInterventionMonitoring) -> Scope {
    let dictionary = Thread.current.threadDictionary
    let scope = Scope(previous: dictionary[key], checkpoint: Checkpoint(monitor: monitor))
    dictionary[key] = scope.checkpoint
    return scope
  }

  static func check() throws {
    try (Thread.current.threadDictionary[key] as? Checkpoint)?.check()
  }
}
