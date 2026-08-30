import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum FocusStealProcessNotificationSubtype: UInt16, Sendable {
  case newFront = 0x0002
  case keyFocusTaken = 0x4000
  case keyFocusReturned = 0x8000
  case keyFocusChanged = 0xF102
}

struct FocusStealProcessNotification: Equatable, Sendable {
  let subtype: UInt16
  let targetProcessIdentifier: pid_t
  let subjectProcessIdentifier: pid_t
  let focusTheftIdentifier: UInt32?
}

struct RawFocusStealProcessNotification: Equatable, Sendable {
  let subtype: Int64
  let targetProcessIdentifier: Int64
  let subjectProcessIdentifier: Int64
  let focusTheftIdentifier: Int64
}

enum FocusStealDisposition: Equatable, Sendable {
  case passThrough
  case releaseAndSuppress(focusTheftIdentifier: UInt32)
}

enum FocusStealPolicy {
  static func disposition(
    for notification: FocusStealProcessNotification,
    protectedProcessIdentifiers: Set<pid_t>,
    userIntervened: Bool
  ) -> FocusStealDisposition {
    guard !userIntervened,
      protectedProcessIdentifiers.contains(notification.subjectProcessIdentifier),
      let focusTheftIdentifier = notification.focusTheftIdentifier
    else {
      return .passThrough
    }

    // The official service calls CPSReleaseKeyFocusWithID from its NewFront /
    // KeyFocusChanged state transition handler. KeyFocusTaken and
    // KeyFocusReturned have separate bookkeeping and must not be treated as
    // proof of a reversible theft.
    switch FocusStealProcessNotificationSubtype(rawValue: notification.subtype) {
    case .newFront, .keyFocusChanged:
      return .releaseAndSuppress(focusTheftIdentifier: focusTheftIdentifier)
    default:
      return .passThrough
    }
  }
}

protocol KeyFocusReleasing: Sendable {
  var isAvailable: Bool { get }
  func releaseKeyFocus(with identifier: UInt32) -> Bool
}

protocol FocusSubjectResolving: Sendable {
  func hostProcessIdentifier(for subjectProcessIdentifier: pid_t) -> pid_t
}

struct ViewBridgeFocusSubjectResolver: FocusSubjectResolving {
  func hostProcessIdentifier(for subjectProcessIdentifier: pid_t) -> pid_t {
    guard subjectProcessIdentifier > 0,
      let application = NSRunningApplication(processIdentifier: subjectProcessIdentifier),
      application.activationPolicy == .prohibited
    else {
      return subjectProcessIdentifier
    }

    let applicationElement = AXUIElementCreateApplication(subjectProcessIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      applicationElement,
      kAXFocusedUIElementAttribute as CFString,
      &value
    ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return subjectProcessIdentifier
    }

    let focusedElement = unsafeDowncast(value, to: AXUIElement.self)
    var hostProcessIdentifier: pid_t = 0
    guard AXUIElementGetPid(focusedElement, &hostProcessIdentifier) == .success,
      hostProcessIdentifier > 0,
      hostProcessIdentifier != subjectProcessIdentifier
    else {
      return subjectProcessIdentifier
    }
    return hostProcessIdentifier
  }
}

struct CPSKeyFocusReleaser: KeyFocusReleasing, @unchecked Sendable {
  private typealias ReleaseKeyFocusWithIDFunction = @convention(c) (UInt32) -> Int32

  private let function: ReleaseKeyFocusWithIDFunction?

  init() {
    guard let handle = dlopen(nil, RTLD_LAZY),
      let symbol = dlsym(handle, "CPSReleaseKeyFocusWithID")
    else {
      function = nil
      return
    }
    function = unsafeBitCast(symbol, to: ReleaseKeyFocusWithIDFunction.self)
  }

  var isAvailable: Bool { function != nil }

  func releaseKeyFocus(with identifier: UInt32) -> Bool {
    guard let function else { return false }
    return function(identifier) == 0
  }
}

final class SystemFocusStealGuard: @unchecked Sendable {
  static let shared = SystemFocusStealGuard()

  struct Protection: Sendable {
    fileprivate let identifier: UUID?
  }

  private struct ProtectedTarget {
    let processIdentifier: pid_t
    let interventionCheckpoint: UInt64?
  }

  private static let processNotificationType = CGEventType(rawValue: 21)!
  private static let targetPIDField = CGEventField(rawValue: 40)!
  private static let subtypeField = CGEventField(rawValue: 64)!
  private static let focusTheftIDField = CGEventField(rawValue: 71)!
  private static let subjectPIDField = CGEventField(rawValue: 73)!

  private let lock = NSLock()
  private let interventionMonitor: any UserInterventionMonitoring
  private let keyFocusReleaser: any KeyFocusReleasing
  private let subjectResolver: any FocusSubjectResolving
  private var protectedTargets: [UUID: ProtectedTarget] = [:]
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var available = false
  private var recentRawNotifications: [RawFocusStealProcessNotification] = []

  var isAvailable: Bool {
    lock.withLock { available }
      && interventionMonitor.isAvailable
      && keyFocusReleaser.isAvailable
  }

  func rawNotifications() -> [RawFocusStealProcessNotification] {
    lock.withLock { recentRawNotifications }
  }

  init(
    interventionMonitor: any UserInterventionMonitoring = PhysicalInputMonitor.shared,
    keyFocusReleaser: any KeyFocusReleasing = CPSKeyFocusReleaser(),
    subjectResolver: any FocusSubjectResolving = ViewBridgeFocusSubjectResolver(),
    startMonitoring: Bool = true
  ) {
    self.interventionMonitor = interventionMonitor
    self.keyFocusReleaser = keyFocusReleaser
    self.subjectResolver = subjectResolver
    if startMonitoring {
      Thread.detachNewThread { [weak self] in self?.runEventTap() }
    }
  }

  func beginProtecting(processIdentifier: pid_t) -> Protection {
    guard processIdentifier > 0 else { return Protection(identifier: nil) }
    let identifier = UUID()
    let checkpoint = interventionMonitor.isAvailable ? interventionMonitor.checkpoint() : nil
    lock.withLock {
      protectedTargets[identifier] = ProtectedTarget(
        processIdentifier: processIdentifier,
        interventionCheckpoint: checkpoint
      )
    }
    return Protection(identifier: identifier)
  }

  func endProtecting(_ protection: Protection) {
    guard let identifier = protection.identifier else { return }
    lock.withLock { _ = protectedTargets.removeValue(forKey: identifier) }
  }

  func withProtection<T>(processIdentifier: pid_t, _ body: () throws -> T) rethrows -> T {
    let protection = beginProtecting(processIdentifier: processIdentifier)
    defer { endProtecting(protection) }
    return try body()
  }

  func handle(_ notification: FocusStealProcessNotification) -> Bool {
    let resolvedSubjectProcessIdentifier = subjectResolver.hostProcessIdentifier(
      for: notification.subjectProcessIdentifier
    )
    let resolvedNotification = FocusStealProcessNotification(
      subtype: notification.subtype,
      targetProcessIdentifier: notification.targetProcessIdentifier,
      subjectProcessIdentifier: resolvedSubjectProcessIdentifier,
      focusTheftIdentifier: notification.focusTheftIdentifier
    )
    let state = lock.withLock { () -> (Set<pid_t>, Bool) in
      let matchingTargets = protectedTargets.values.filter {
        $0.processIdentifier == resolvedSubjectProcessIdentifier
      }
      guard !matchingTargets.isEmpty, interventionMonitor.isAvailable else {
        return ([], false)
      }
      let currentCheckpoint = interventionMonitor.checkpoint()
      let canSafelyProtect = matchingTargets.allSatisfy { target in
        guard let checkpoint = target.interventionCheckpoint else { return false }
        return checkpoint == currentCheckpoint
      }
      return (
        canSafelyProtect ? Set(matchingTargets.map(\.processIdentifier)) : [],
        !canSafelyProtect
      )
    }

    switch FocusStealPolicy.disposition(
      for: resolvedNotification,
      protectedProcessIdentifiers: state.0,
      userIntervened: state.1
    ) {
    case .passThrough:
      return false
    case .releaseAndSuppress(let focusTheftIdentifier):
      // Never conceal an event unless the operating system confirms that the
      // stolen key focus was actually released.
      return keyFocusReleaser.releaseKeyFocus(with: focusTheftIdentifier)
    }
  }

  private func runEventTap() {
    let mask = CGEventMask(1) << Self.processNotificationType.rawValue
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: systemFocusStealTapCallback,
        userInfo: refcon
      ),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      return
    }

    let runLoop = CFRunLoopGetCurrent()
    lock.withLock {
      self.tap = tap
      runLoopSource = source
    }
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    lock.withLock { available = true }
    CFRunLoopRun()
  }

  fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = lock.withLock({ self.tap }) {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return false
    }
    guard type == Self.processNotificationType else { return false }
    let rawNotification = Self.decodeRaw(event)
    lock.withLock {
      recentRawNotifications.append(rawNotification)
      if recentRawNotifications.count > 32 {
        recentRawNotifications.removeFirst(recentRawNotifications.count - 32)
      }
    }
    guard let notification = Self.decode(rawNotification) else { return false }
    return handle(notification)
  }

  static func decodeRaw(_ event: CGEvent) -> RawFocusStealProcessNotification {
    RawFocusStealProcessNotification(
      subtype: event.getIntegerValueField(subtypeField),
      targetProcessIdentifier: event.getIntegerValueField(targetPIDField),
      subjectProcessIdentifier: event.getIntegerValueField(subjectPIDField),
      focusTheftIdentifier: event.getIntegerValueField(focusTheftIDField)
    )
  }

  static func decode(_ event: CGEvent) -> FocusStealProcessNotification? {
    decode(decodeRaw(event))
  }

  static func decode(_ raw: RawFocusStealProcessNotification) -> FocusStealProcessNotification? {
    let subtypeValue = raw.subtype
    let targetPIDValue = raw.targetProcessIdentifier
    let subjectPIDValue = raw.subjectProcessIdentifier
    guard subtypeValue >= 0, subtypeValue <= Int64(UInt16.max),
      targetPIDValue >= Int64(Int32.min), targetPIDValue <= Int64(Int32.max),
      subjectPIDValue > 0, subjectPIDValue <= Int64(Int32.max)
    else {
      return nil
    }
    let focusTheftIDValue = raw.focusTheftIdentifier
    let focusTheftIdentifier: UInt32? =
      focusTheftIDValue >= 0 && focusTheftIDValue <= Int64(UInt32.max)
      ? UInt32(focusTheftIDValue) : nil
    return FocusStealProcessNotification(
      subtype: UInt16(subtypeValue),
      targetProcessIdentifier: pid_t(targetPIDValue),
      subjectProcessIdentifier: pid_t(subjectPIDValue),
      focusTheftIdentifier: focusTheftIdentifier
    )
  }
}

public enum ComputerUseFocusProtection {
  public static func warmUp(timeout: TimeInterval = 0.25) -> Bool {
    _ = PhysicalInputMonitor.shared
    let guardInstance = SystemFocusStealGuard.shared
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while !guardInstance.isAvailable, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
    return guardInstance.isAvailable
  }
}

private func systemFocusStealTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let guardInstance = Unmanaged<SystemFocusStealGuard>.fromOpaque(userInfo).takeUnretainedValue()
  if guardInstance.process(type: type, event: event) { return nil }
  return Unmanaged.passUnretained(event)
}
