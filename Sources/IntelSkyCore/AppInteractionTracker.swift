import Foundation

public final class AppInteractionTracker: @unchecked Sendable {
  private struct Key: Hashable {
    let threadID: String?
    let bundleIdentifier: String
    let processIdentifier: pid_t
  }

  private let lock = NSLock()
  private var lastActionByApp: [Key: Date] = [:]

  public init() {}

  func recordAction(for app: ResolvedMacApp, at date: Date = Date()) {
    lock.withLock {
      lastActionByApp[
        Key(
          threadID: ComputerUseTurnContext.threadID,
          bundleIdentifier: app.bundleIdentifier,
          processIdentifier: app.processIdentifier
        )
      ] = date
    }
  }

  func remainingBaseSettleTime(
    for app: ResolvedMacApp,
    at date: Date = Date(),
    settleInterval: TimeInterval = 1
  ) -> TimeInterval {
    lock.withLock {
      let key = Key(
        threadID: ComputerUseTurnContext.threadID,
        bundleIdentifier: app.bundleIdentifier,
        processIdentifier: app.processIdentifier
      )
      guard let lastAction = lastActionByApp[key] else { return 0 }
      return max(0, settleInterval - date.timeIntervalSince(lastAction))
    }
  }

  func clear(threadID: String?) {
    lock.withLock {
      if let threadID {
        lastActionByApp = lastActionByApp.filter {
          $0.key.threadID != nil && $0.key.threadID != threadID
        }
      } else {
        lastActionByApp.removeAll()
      }
    }
  }

  func clearUnscoped() {
    lock.withLock {
      lastActionByApp = lastActionByApp.filter { $0.key.threadID != nil }
    }
  }

  func clear(bundleIdentifier: String, threadID: String?) {
    lock.withLock {
      lastActionByApp = lastActionByApp.filter {
        $0.key.bundleIdentifier != bundleIdentifier
          || (threadID != nil && $0.key.threadID != threadID)
      }
    }
  }
}

enum RunLoopWaiter {
  static func wait(for interval: TimeInterval) throws {
    guard interval > 0 else { return }
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
      try RequestDeadlineContext.check()
      _ = RunLoop.current.run(
        mode: .default,
        before: min(deadline, Date().addingTimeInterval(0.02))
      )
    }
    try RequestDeadlineContext.check()
  }
}
