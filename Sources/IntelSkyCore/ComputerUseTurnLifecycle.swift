import Foundation

struct ComputerUseTurnIdentity: Equatable, Sendable {
  let sessionID: String
  let threadID: String
  let turnID: String

  init?(metadata: Any?) {
    guard let metadata = metadata as? [String: Any],
      let threadID = Self.nonempty(metadata["thread_id"]),
      let turnID = Self.nonempty(metadata["turn_id"])
    else {
      return nil
    }
    self.sessionID = Self.nonempty(metadata["session_id"]) ?? threadID
    self.threadID = threadID
    self.turnID = turnID
  }

  private static func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum ComputerUseTurnContext {
  private static let key = "dev.huangjianbin.intel-sky-service.turn-identity"

  static var identity: ComputerUseTurnIdentity? {
    (Thread.current.threadDictionary[key] as? ComputerUseTurnIdentityBox)?.identity
  }

  static var threadID: String? { identity?.threadID }

  static func withIdentity<T>(
    _ identity: ComputerUseTurnIdentity?,
    operation: () throws -> T
  ) rethrows -> T {
    let dictionary = Thread.current.threadDictionary
    let previous = dictionary[key]
    if let identity {
      dictionary[key] = ComputerUseTurnIdentityBox(identity)
    } else {
      dictionary.removeObject(forKey: key)
    }
    defer {
      if let previous { dictionary[key] = previous } else { dictionary.removeObject(forKey: key) }
    }
    return try operation()
  }

  private final class ComputerUseTurnIdentityBox: NSObject {
    let identity: ComputerUseTurnIdentity
    init(_ identity: ComputerUseTurnIdentity) { self.identity = identity }
  }
}

enum ComputerUseTurnSafetyTerminationReason: Equatable, Sendable {
  case screenLocked
  case userIntervened
}

enum ComputerUseTurnLifecycleEvent: Equatable, Sendable {
  case started(ComputerUseTurnIdentity)
  case transitioned(from: ComputerUseTurnIdentity, to: ComputerUseTurnIdentity)
  case ended(ComputerUseTurnIdentity)
  case safetyTerminated(ComputerUseTurnIdentity, ComputerUseTurnSafetyTerminationReason)
  case safetyRevoked(ComputerUseTurnSafetyTerminationReason)
}

protocol ComputerUseTurnLifecycleEventHandling: Sendable {
  func handle(_ event: ComputerUseTurnLifecycleEvent)
}

/// Fans a turn boundary out in safety order. Transient visual/stream/session state is
/// revoked first; focus restoration is deliberately last so no old-turn producer can
/// publish another frame or cursor update after the user's focus has been restored.
final class ComputerUseTurnRuntimeCoordinator: ComputerUseTurnLifecycleEventHandling,
  @unchecked Sendable
{
  private let preRestoreHandlers: [@Sendable (ComputerUseTurnLifecycleEvent) -> Void]
  private let focusHandler: @Sendable (ComputerUseTurnLifecycleEvent) -> Void

  init(
    preRestoreHandlers: [@Sendable (ComputerUseTurnLifecycleEvent) -> Void],
    focusHandler: @escaping @Sendable (ComputerUseTurnLifecycleEvent) -> Void
  ) {
    self.preRestoreHandlers = preRestoreHandlers
    self.focusHandler = focusHandler
  }

  convenience init(
    appStateProvider: (any AppStateProviding)? = nil,
    appCaptureProvider: (any AppCaptureProviding)? = nil,
    eventStreamProvider: (any EventStreamProviding)? = nil,
    requestObserver: (any SkyRequestResultObserving)? = nil
  ) {
    var handlers: [@Sendable (ComputerUseTurnLifecycleEvent) -> Void] = [
      { ComputerUseVisualCoordinator.shared.handle($0) },
      { ComputerUseInterventionCoordinator.shared.handle($0) },
      { ComputerUseSessionCoordinator.shared.handle($0) },
    ]
    if let state = appStateProvider as? any ComputerUseTurnLifecycleEventHandling {
      handlers.append { state.handle($0) }
    }
    if let capture = appCaptureProvider as? any AppCaptureLifecycleHandling {
      handlers.append { capture.handle($0) }
    }
    if let eventStream = eventStreamProvider as? any EventStreamLifecycleHandling {
      handlers.append { eventStream.handle($0) }
    }
    if let observer = requestObserver as? any ComputerUseTurnLifecycleEventHandling {
      handlers.append { observer.handle($0) }
    }
    self.init(
      preRestoreHandlers: handlers,
      focusHandler: { ComputerUseFocusCoordinator.shared.handle($0) }
    )
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    for handler in preRestoreHandlers { handler(event) }
    focusHandler(event)
  }
}

protocol ComputerUseTurnLifecycleHandling: Sendable {
  func observe(metadata: Any?)
  func end(request: [String: Any])
  func terminateForSafety(_ reason: ComputerUseTurnSafetyTerminationReason)
}

final class ComputerUseTurnCoordinator: ComputerUseTurnLifecycleHandling, @unchecked Sendable {
  private let lock = NSLock()
  private let eventHandler: @Sendable (ComputerUseTurnLifecycleEvent) -> Void
  private var activeByThreadID: [String: ComputerUseTurnIdentity] = [:]
  private var observationOrder: [String] = []
  private var pendingEvents: [ComputerUseTurnLifecycleEvent] = []
  private var isDeliveringEvents = false

  init(
    eventHandler: @escaping @Sendable (ComputerUseTurnLifecycleEvent) -> Void = {
      ComputerUseTurnRuntimeCoordinator().handle($0)
    }
  ) {
    self.eventHandler = eventHandler
  }

  convenience init(
    appStateProvider: (any AppStateProviding)? = nil,
    appCaptureProvider: (any AppCaptureProviding)?,
    eventStreamProvider: (any EventStreamProviding)? = nil,
    requestObserver: (any SkyRequestResultObserving)? = nil
  ) {
    let runtime = ComputerUseTurnRuntimeCoordinator(
      appStateProvider: appStateProvider,
      appCaptureProvider: appCaptureProvider,
      eventStreamProvider: eventStreamProvider,
      requestObserver: requestObserver
    )
    self.init { runtime.handle($0) }
  }

  var currentIdentity: ComputerUseTurnIdentity? {
    lock.withLock {
      observationOrder.last.flatMap { activeByThreadID[$0] }
    }
  }

  var activeIdentities: [ComputerUseTurnIdentity] {
    lock.withLock { observationOrder.compactMap { activeByThreadID[$0] } }
  }

  func observe(metadata: Any?) {
    guard let identity = ComputerUseTurnIdentity(metadata: metadata) else { return }
    let shouldDeliver = lock.withLock { () -> Bool in
      guard activeByThreadID[identity.threadID] != identity else { return false }
      let event: ComputerUseTurnLifecycleEvent
      if let previous = activeByThreadID[identity.threadID] {
        activeByThreadID[identity.threadID] = identity
        event = .transitioned(from: previous, to: identity)
      } else {
        activeByThreadID[identity.threadID] = identity
        event = .started(identity)
      }
      observationOrder.removeAll { $0 == identity.threadID }
      observationOrder.append(identity.threadID)
      return enqueueLocked(event)
    }
    if shouldDeliver { deliverPendingEvents() }
  }

  func end(request: [String: Any]) {
    let requestedThread = nonempty(request["threadID"])
    let requestedTurn = nonempty(request["turnID"])
    let shouldDeliver = lock.withLock { () -> Bool in
      let identity: ComputerUseTurnIdentity?
      if let requestedThread {
        identity = activeByThreadID[requestedThread]
      } else if let latestThread = observationOrder.last {
        identity = activeByThreadID[latestThread]
      } else {
        identity = nil
      }
      guard let identity, requestedTurn == nil || requestedTurn == identity.turnID else {
        return false
      }
      activeByThreadID.removeValue(forKey: identity.threadID)
      observationOrder.removeAll { $0 == identity.threadID }
      return enqueueLocked(.ended(identity))
    }
    if shouldDeliver { deliverPendingEvents() }
  }

  func terminateForSafety(_ reason: ComputerUseTurnSafetyTerminationReason) {
    let shouldDeliver = lock.withLock { () -> Bool in
      if activeByThreadID.isEmpty {
        // Hidden/native callers can establish transient runtime state without Codex turn metadata.
        // A global safety boundary must still revoke that state rather than becoming a no-op.
        return enqueueLocked(.safetyRevoked(reason))
      }
      let identities = observationOrder.compactMap { activeByThreadID[$0] }
      activeByThreadID.removeAll()
      observationOrder.removeAll()
      var shouldStartDelivery = false
      for identity in identities {
        shouldStartDelivery =
          enqueueLocked(.safetyTerminated(identity, reason)) || shouldStartDelivery
      }
      return shouldStartDelivery
    }
    if shouldDeliver { deliverPendingEvents() }
  }

  private func enqueueLocked(_ event: ComputerUseTurnLifecycleEvent) -> Bool {
    pendingEvents.append(event)
    guard !isDeliveringEvents else { return false }
    isDeliveringEvents = true
    return true
  }

  private func deliverPendingEvents() {
    while true {
      let event = lock.withLock { () -> ComputerUseTurnLifecycleEvent? in
        guard !pendingEvents.isEmpty else {
          isDeliveringEvents = false
          return nil
        }
        return pendingEvents.removeFirst()
      }
      guard let event else { return }
      eventHandler(event)
    }
  }

  private func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
