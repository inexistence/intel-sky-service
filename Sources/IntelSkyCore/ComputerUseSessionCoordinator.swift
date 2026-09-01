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

final class ComputerUseSessionCoordinator: ComputerUseSessionCoordinating,
  ComputerUseTurnLifecycleEventHandling, @unchecked Sendable
{
  static let shared = ComputerUseSessionCoordinator()
  private static let unscopedOwner = "__unscoped__"

  private struct ActiveApplication: Sendable {
    let identifier: String
    let name: String
    let bundleIdentifier: String
    let bundleURL: String?
    var ownerThreadIDs: Set<String>

    init(_ app: ResolvedMacApp, ownerThreadID: String) {
      identifier = app.bundleIdentifier
      name = app.displayName
      bundleIdentifier = app.bundleIdentifier
      bundleURL = app.appPath.isEmpty ? nil : app.appPath
      ownerThreadIDs = [ownerThreadID]
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
  private let statusPublisher: @Sendable (Bool) -> Void
  private var activeApplications: [String: ActiveApplication] = [:]
  private var stoppedOwnersByBundleIdentifier: [String: Set<String>] = [:]
  private var stopHandler: (@Sendable (String, String?) -> Void)?
  private var additionalStopHandlers: [UUID: @Sendable (String, String?) -> Void] = [:]
  private var lastPublishedApplicationBundleIdentifiers: Set<String> = []

  init(
    statusPublisher: @escaping @Sendable (Bool) -> Void = { active in
      ManagedServiceReconnectNotification.post(
        processIdentifier: getpid(),
        computerUseActive: active
      )
    }
  ) {
    self.statusPublisher = statusPublisher
  }

  private var currentOwnerThreadID: String {
    ComputerUseTurnContext.threadID ?? Self.unscopedOwner
  }

  func requireNotStopped(_ app: ResolvedMacApplication) throws {
    let ownerThreadID = currentOwnerThreadID
    guard
      !lock.withLock({
        stoppedOwnersByBundleIdentifier[app.bundleIdentifier]?.contains(ownerThreadID) == true
      })
    else {
      throw SkySafetyError.userStoppedSession
    }
  }

  func requireActionAllowed(_ app: ResolvedMacApplication) throws {
    let ownerThreadID = currentOwnerThreadID
    let state = lock.withLock { () -> Int in
      if stoppedOwnersByBundleIdentifier[app.bundleIdentifier]?.contains(ownerThreadID) == true {
        return 2
      }
      if activeApplications[app.bundleIdentifier]?.ownerThreadIDs.contains(ownerThreadID) == true {
        return 1
      }
      return 0
    }
    switch state {
    case 2: throw SkySafetyError.userStoppedSession
    case 1: return
    default: throw ComputerUseSessionError.noActiveSession(app.bundleIdentifier)
    }
  }

  func recordActive(_ app: ResolvedMacApp) {
    let ownerThreadID = currentOwnerThreadID
    lock.withLock {
      guard
        stoppedOwnersByBundleIdentifier[app.bundleIdentifier]?.contains(ownerThreadID) != true
      else { return }
      if var active = activeApplications[app.bundleIdentifier] {
        active.ownerThreadIDs.insert(ownerThreadID)
        activeApplications[app.bundleIdentifier] = active
      } else {
        activeApplications[app.bundleIdentifier] = ActiveApplication(
          app,
          ownerThreadID: ownerThreadID
        )
      }
    }
    publishStatusIfChanged()
  }

  func activateApplication(_ app: ResolvedMacApp) throws -> [String: Any] {
    let ownerThreadID = currentOwnerThreadID
    try requireNotStopped(
      ResolvedMacApplication(
        bundleIdentifier: app.bundleIdentifier,
        displayName: app.displayName,
        appPath: app.appPath
      ))
    lock.withLock {
      if var active = activeApplications[app.bundleIdentifier] {
        active.ownerThreadIDs.insert(ownerThreadID)
        activeApplications[app.bundleIdentifier] = active
      } else {
        activeApplications[app.bundleIdentifier] = ActiveApplication(
          app,
          ownerThreadID: ownerThreadID
        )
      }
    }
    publishStatusIfChanged()
    return ["active": true, "currentApp": Self.appDescriptor(app)]
  }

  func deactivateApplication(_ app: ResolvedMacApp) throws -> [String: Any] {
    let ownerThreadID = currentOwnerThreadID
    let handlers: [@Sendable (String, String?) -> Void] = try lock.withLock {
      guard var active = activeApplications[app.bundleIdentifier],
        active.ownerThreadIDs.remove(ownerThreadID) != nil
      else {
        throw ComputerUseSessionError.noActiveSession(app.bundleIdentifier)
      }
      if active.ownerThreadIDs.isEmpty {
        activeApplications.removeValue(forKey: app.bundleIdentifier)
      } else {
        activeApplications[app.bundleIdentifier] = active
      }
      return [stopHandler].compactMap { $0 } + additionalStopHandlers.values
    }
    for handler in handlers {
      handler(app.bundleIdentifier, Self.externalThreadID(ownerThreadID))
    }
    publishStatusIfChanged()
    return ["active": false, "currentApp": NSNull()]
  }

  func stopApplication(request: [String: Any]) throws -> [String: Any] {
    guard let rawIdentifier = request["app"] as? String else {
      throw ComputerUseSessionError.invalidStopRequest
    }
    let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw ComputerUseSessionError.invalidStopRequest }

    let stopped:
      (application: ActiveApplication, handlers: [@Sendable (String, String?) -> Void])? =
        lock.withLock {
          guard
            let match = activeApplications.first(where: { $0.value.matches(identifier) })
          else {
            return nil
          }
          activeApplications.removeValue(forKey: match.key)
          stoppedOwnersByBundleIdentifier[match.value.bundleIdentifier, default: []]
            .formUnion(match.value.ownerThreadIDs)
          return (
            match.value,
            [stopHandler].compactMap { $0 } + additionalStopHandlers.values
          )
        }
    guard let stopped else { throw ComputerUseSessionError.noActiveSession(identifier) }
    for handler in stopped.handlers { handler(stopped.application.bundleIdentifier, nil) }
    publishStatusIfChanged()
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
    let endedThreadID: String?
    switch event {
    case .started:
      endedThreadID = Self.unscopedOwner
    case .transitioned(let previous, _), .ended(let previous),
      .safetyTerminated(let previous, _):
      endedThreadID = previous.threadID
    case .safetyRevoked:
      endedThreadID = nil
    }
    lock.withLock {
      guard let endedThreadID else {
        activeApplications.removeAll()
        stoppedOwnersByBundleIdentifier.removeAll()
        return
      }
      for bundleIdentifier in Array(activeApplications.keys) {
        guard var active = activeApplications[bundleIdentifier] else { continue }
        active.ownerThreadIDs.remove(endedThreadID)
        active.ownerThreadIDs.remove(Self.unscopedOwner)
        if active.ownerThreadIDs.isEmpty {
          activeApplications.removeValue(forKey: bundleIdentifier)
        } else {
          activeApplications[bundleIdentifier] = active
        }
      }
      for bundleIdentifier in Array(stoppedOwnersByBundleIdentifier.keys) {
        stoppedOwnersByBundleIdentifier[bundleIdentifier]?.remove(endedThreadID)
        stoppedOwnersByBundleIdentifier[bundleIdentifier]?.remove(Self.unscopedOwner)
        if stoppedOwnersByBundleIdentifier[bundleIdentifier]?.isEmpty == true {
          stoppedOwnersByBundleIdentifier.removeValue(forKey: bundleIdentifier)
        }
      }
    }
    publishStatusIfChanged()
  }

  func setStopHandler(_ handler: (@Sendable (String, String?) -> Void)?) {
    lock.withLock { stopHandler = handler }
  }

  @discardableResult
  func addStopHandler(
    _ handler: @escaping @Sendable (String, String?) -> Void
  ) -> UUID {
    let identifier = UUID()
    lock.withLock { additionalStopHandlers[identifier] = handler }
    return identifier
  }

  private static func appDescriptor(_ app: ResolvedMacApp) -> [String: Any] {
    [
      "pid": Int(app.processIdentifier),
      "bundleIdentifier": app.bundleIdentifier,
      "appPath": app.appPath.isEmpty ? NSNull() : app.appPath,
    ]
  }

  private static func externalThreadID(_ ownerThreadID: String) -> String? {
    ownerThreadID == unscopedOwner ? nil : ownerThreadID
  }

  private func publishStatusIfChanged() {
    let active = lock.withLock { () -> Bool? in
      let applicationBundleIdentifiers = Set(activeApplications.keys)
      guard applicationBundleIdentifiers != lastPublishedApplicationBundleIdentifiers else {
        return nil
      }
      lastPublishedApplicationBundleIdentifiers = applicationBundleIdentifiers
      return !applicationBundleIdentifiers.isEmpty
    }
    if let active { statusPublisher(active) }
  }
}
