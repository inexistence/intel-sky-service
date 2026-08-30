import ApplicationServices
import Carbon
import Foundation

enum SkySafetyError: Error, CustomStringConvertible {
  case screenLocked
  case secureInputEnabled
  case userStoppedSession
  case userIntervened

  var description: String {
    switch self {
    case .screenLocked: return "The screen is locked"
    case .secureInputEnabled: return "Secure Event Input is enabled"
    case .userStoppedSession:
      return
        "This application session has been explicitly stopped by the user for this turn. Stop "
        + "your work and send a final message noting they stopped the session and you're ready to "
        + "continue if they want you to. Computer Use can be used again in the next assistant turn."
    case .userIntervened: return "The user intervened during Computer Use"
    }
  }
}

protocol SecureInputChecking: Sendable {
  func requireTextInjectionAllowed() throws
}

struct CarbonSecureInputChecker: SecureInputChecking {
  func requireTextInjectionAllowed() throws {
    guard !IsSecureEventInputEnabled() else { throw SkySafetyError.secureInputEnabled }
  }
}

struct NoopSecureInputChecker: SecureInputChecking {
  func requireTextInjectionAllowed() throws {}
}

public protocol ScreenLockChecking: Sendable {
  func requireUnlocked() throws
}

protocol ScreenLockStateReading: Sendable {
  func isScreenLocked() -> Bool
}

public struct CGSessionScreenLockChecker: ScreenLockChecking, ScreenLockStateReading {
  public init() {}

  public func requireUnlocked() throws {
    guard !isScreenLocked() else { throw SkySafetyError.screenLocked }
  }

  func isScreenLocked() -> Bool {
    guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    let isLocked = dictionary["CGSSessionScreenIsLocked"] as? Bool ?? false
    let isOnConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool ?? false
    return isLocked || !isOnConsole
  }
}

struct NoopScreenLockChecker: ScreenLockChecking {
  func requireUnlocked() throws {}
}

/// Detects lock and console-session transitions even while no Computer Use request is in flight.
/// The callback is emitted once per locked episode and is deliberately independent of AppKit
/// notifications: fast-user switching and a missing CGSession dictionary both fail closed.
public final class ComputerUseScreenLockMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private let stateReader: any ScreenLockStateReading
  private let pollInterval: TimeInterval
  private let queue: DispatchQueue
  private let didLock: @Sendable () -> Void
  private var timer: DispatchSourceTimer?
  private var lastLocked: Bool?

  public convenience init(
    pollInterval: TimeInterval = 0.25,
    didLock: @escaping @Sendable () -> Void
  ) {
    self.init(
      stateReader: CGSessionScreenLockChecker(),
      pollInterval: pollInterval,
      didLock: didLock
    )
  }

  init(
    stateReader: any ScreenLockStateReading,
    pollInterval: TimeInterval = 0.25,
    didLock: @escaping @Sendable () -> Void
  ) {
    self.stateReader = stateReader
    self.pollInterval = max(0.05, pollInterval)
    self.didLock = didLock
    queue = DispatchQueue(
      label: "dev.huangjianbin.intel-sky-service.screen-lock-monitor",
      qos: .userInitiated
    )
  }

  deinit { stop() }

  public func start() {
    let source = lock.withLock { () -> DispatchSourceTimer? in
      guard timer == nil else { return nil }
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(50))
      source.setEventHandler { [weak self] in self?.poll() }
      timer = source
      return source
    }
    source?.resume()
  }

  public func stop() {
    let source = lock.withLock { () -> DispatchSourceTimer? in
      let source = timer
      timer = nil
      lastLocked = nil
      return source
    }
    source?.setEventHandler {}
    source?.cancel()
  }

  func poll() {
    let locked = stateReader.isScreenLocked()
    let shouldNotify = lock.withLock { () -> Bool in
      guard timer != nil else { return false }
      defer { lastLocked = locked }
      return locked && lastLocked != true
    }
    if shouldNotify { didLock() }
  }
}
