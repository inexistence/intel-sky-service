import Foundation

enum ComputerUseSessionError: Error, CustomStringConvertible {
  case invalidStopRequest
  case noActiveSession(String)

  var description: String {
    switch self {
    case .invalidStopRequest:
      return "Computer Use App stop request requires a non-empty app identifier"
    case .noActiveSession(let identifier):
      return "Computer Use is not active for '\(identifier)'"
    }
  }
}

protocol ComputerUseSessionCoordinating: Sendable {
  func requireNotStopped(_ app: ResolvedMacApplication) throws
  func requireActionAllowed(_ app: ResolvedMacApplication) throws
  func recordActive(_ app: ResolvedMacApp)
  func activateApplication(_ app: ResolvedMacApp) throws -> [String: Any]
  func deactivateApplication(_ app: ResolvedMacApp) throws -> [String: Any]
  func stopApplication(request: [String: Any]) throws -> [String: Any]
  func statusItemMenuState() -> [String: Any]
}

struct NoopComputerUseSessionCoordinator: ComputerUseSessionCoordinating {
  func requireNotStopped(_ app: ResolvedMacApplication) throws {}
  func requireActionAllowed(_ app: ResolvedMacApplication) throws {}
  func recordActive(_ app: ResolvedMacApp) {}
  func activateApplication(_ app: ResolvedMacApp) throws -> [String: Any] {
    ["active": true, "currentApp": Self.appDescriptor(app)]
  }
  func deactivateApplication(_ app: ResolvedMacApp) throws -> [String: Any] {
    ["active": false, "currentApp": NSNull()]
  }
  func stopApplication(request: [String: Any]) throws -> [String: Any] {
    throw ComputerUseSessionError.noActiveSession(String(describing: request["app"]))
  }
  func statusItemMenuState() -> [String: Any] { [:] }

  private static func appDescriptor(_ app: ResolvedMacApp) -> [String: Any] {
    [
      "pid": Int(app.processIdentifier),
      "bundleIdentifier": app.bundleIdentifier,
      "appPath": app.appPath.isEmpty ? NSNull() : app.appPath,
    ]
  }
}

enum ComputerUseSessionOperationContext {
  private static let key = "dev.huangjianbin.intel-sky-service.session-operation"

  final class Checkpoint: NSObject {
    let coordinator: any ComputerUseSessionCoordinating
    let app: ResolvedMacApplication

    init(
      coordinator: any ComputerUseSessionCoordinating,
      app: ResolvedMacApplication
    ) {
      self.coordinator = coordinator
      self.app = app
    }

    func check() throws { try coordinator.requireNotStopped(app) }
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
    coordinator: any ComputerUseSessionCoordinating,
    app: ResolvedMacApplication
  ) -> Scope {
    let dictionary = Thread.current.threadDictionary
    let scope = Scope(
      previous: dictionary[key],
      checkpoint: Checkpoint(coordinator: coordinator, app: app)
    )
    dictionary[key] = scope.checkpoint
    return scope
  }

  static func check() throws {
    try (Thread.current.threadDictionary[key] as? Checkpoint)?.check()
  }
}

final class ComputerUseSessionCoordinator: ComputerUseSessionCoordinating, @unchecked Sendable {
  static let shared = ComputerUseSessionCoordinator()

  private struct ActiveApplication: Sendable {
    let identifier: String
    let name: String
    let bundleIdentifier: String
    let bundleURL: String?

    init(_ app: ResolvedMacApp) {
      identifier = app.bundleIdentifier
      name = app.displayName
      bundleIdentifier = app.bundleIdentifier
      bundleURL = app.appPath.isEmpty ? nil : app.appPath
    }

    func matches(_ value: String) -> Bool {
      [identifier, name, bundleIdentifier, bundleURL]
        .compactMap { $0 }
        .contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    var menuDescriptor: [String: Any] {
      var result: [String: Any] = [
        "id": identifier,
        "name": name,
        "bundleIdentifier": bundleIdentifier,
      ]
      if let bundleURL { result["bundleURL"] = bundleURL }
      return result
    }
  }

  private let lock = NSLock()
  private var activeApplications: [String: ActiveApplication] = [:]
  private var stoppedBundleIdentifiers: Set<String> = []
  private var stopHandler: (@Sendable (String) -> Void)?

  func requireNotStopped(_ app: ResolvedMacApplication) throws {
    guard !lock.withLock({ stoppedBundleIdentifiers.contains(app.bundleIdentifier) }) else {
      throw SkySafetyError.userStoppedSession
    }
  }

  func requireActionAllowed(_ app: ResolvedMacApplication) throws {
    let state = lock.withLock { () -> Int in
      if stoppedBundleIdentifiers.contains(app.bundleIdentifier) { return 2 }
      if activeApplications[app.bundleIdentifier] != nil { return 1 }
      return 0
    }
    switch state {
    case 2: throw SkySafetyError.userStoppedSession
    case 1: return
    default: throw ComputerUseSessionError.noActiveSession(app.bundleIdentifier)
    }
  }

  func recordActive(_ app: ResolvedMacApp) {
    lock.withLock {
      guard !stoppedBundleIdentifiers.contains(app.bundleIdentifier) else { return }
      activeApplications[app.bundleIdentifier] = ActiveApplication(app)
    }
  }

  func activateApplication(_ app: ResolvedMacApp) throws -> [String: Any] {
    try requireNotStopped(
      ResolvedMacApplication(
        bundleIdentifier: app.bundleIdentifier,
        displayName: app.displayName,
        appPath: app.appPath
      ))
    lock.withLock {
      activeApplications[app.bundleIdentifier] = ActiveApplication(app)
    }
    return ["active": true, "currentApp": Self.appDescriptor(app)]
  }

  func deactivateApplication(_ app: ResolvedMacApp) throws -> [String: Any] {
    let handler: (@Sendable (String) -> Void)? = try lock.withLock {
      guard activeApplications.removeValue(forKey: app.bundleIdentifier) != nil else {
        throw ComputerUseSessionError.noActiveSession(app.bundleIdentifier)
      }
      return stopHandler
    }
    handler?(app.bundleIdentifier)
    return ["active": false, "currentApp": NSNull()]
  }

  func stopApplication(request: [String: Any]) throws -> [String: Any] {
    guard let rawIdentifier = request["app"] as? String else {
      throw ComputerUseSessionError.invalidStopRequest
    }
    let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw ComputerUseSessionError.invalidStopRequest }

    let stopped: (application: ActiveApplication, handler: (@Sendable (String) -> Void)?)? =
      lock.withLock {
        guard
          let match = activeApplications.first(where: { $0.value.matches(identifier) })
        else {
          return nil
        }
        activeApplications.removeValue(forKey: match.key)
        stoppedBundleIdentifiers.insert(match.value.bundleIdentifier)
        return (match.value, stopHandler)
      }
    guard let stopped else { throw ComputerUseSessionError.noActiveSession(identifier) }
    stopped.handler?(stopped.application.bundleIdentifier)
    return [:]
  }

  func statusItemMenuState() -> [String: Any] {
    let applications = lock.withLock {
      activeApplications.values.sorted {
        if $0.name != $1.name {
          return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return $0.bundleIdentifier < $1.bundleIdentifier
      }.map(\.menuDescriptor)
    }
    return [
      "computerUse": ["activeApplications": applications],
      "computerHistory": [
        "state": "stopped",
        "canClearHistory": [
          "lastTenMinutes": false,
          "lastHour": false,
          "lastDay": false,
        ],
        "recentApplications": [],
      ],
    ]
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    lock.withLock {
      activeApplications.removeAll()
      stoppedBundleIdentifiers.removeAll()
    }
  }

  func setStopHandler(_ handler: (@Sendable (String) -> Void)?) {
    lock.withLock { stopHandler = handler }
  }

  private static func appDescriptor(_ app: ResolvedMacApp) -> [String: Any] {
    [
      "pid": Int(app.processIdentifier),
      "bundleIdentifier": app.bundleIdentifier,
      "appPath": app.appPath.isEmpty ? NSNull() : app.appPath,
    ]
  }
}
