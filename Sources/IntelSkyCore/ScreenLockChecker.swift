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

public struct CGSessionScreenLockChecker: ScreenLockChecking {
  public init() {}

  public func requireUnlocked() throws {
    guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
      throw SkySafetyError.screenLocked
    }
    let isLocked = dictionary["CGSSessionScreenIsLocked"] as? Bool ?? false
    let isOnConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool ?? false
    guard !isLocked, isOnConsole else { throw SkySafetyError.screenLocked }
  }
}

struct NoopScreenLockChecker: ScreenLockChecking {
  func requireUnlocked() throws {}
}
