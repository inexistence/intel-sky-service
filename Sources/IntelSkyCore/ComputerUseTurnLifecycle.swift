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

enum ComputerUseTurnLifecycleEvent: Equatable, Sendable {
  case started(ComputerUseTurnIdentity)
  case transitioned(from: ComputerUseTurnIdentity, to: ComputerUseTurnIdentity)
  case ended(ComputerUseTurnIdentity)
}

protocol ComputerUseTurnLifecycleHandling: Sendable {
  func observe(metadata: Any?)
  func end(request: [String: Any])
}

final class ComputerUseTurnCoordinator: ComputerUseTurnLifecycleHandling, @unchecked Sendable {
  private let lock = NSLock()
  private let eventHandler: @Sendable (ComputerUseTurnLifecycleEvent) -> Void
  private var current: ComputerUseTurnIdentity?

  init(
    eventHandler: @escaping @Sendable (ComputerUseTurnLifecycleEvent) -> Void = {
      ComputerUseFocusCoordinator.shared.handle($0)
      ComputerUseSessionCoordinator.shared.handle($0)
    }
  ) {
    self.eventHandler = eventHandler
  }

  convenience init(
    appCaptureProvider: (any AppCaptureProviding)?,
    eventStreamProvider: (any EventStreamProviding)? = nil
  ) {
    self.init { event in
      ComputerUseFocusCoordinator.shared.handle(event)
      ComputerUseSessionCoordinator.shared.handle(event)
      (appCaptureProvider as? any AppCaptureLifecycleHandling)?.handle(event)
      (eventStreamProvider as? any EventStreamLifecycleHandling)?.handle(event)
    }
  }

  var currentIdentity: ComputerUseTurnIdentity? { lock.withLock { current } }

  func observe(metadata: Any?) {
    guard let identity = ComputerUseTurnIdentity(metadata: metadata) else { return }
    let event: ComputerUseTurnLifecycleEvent? = lock.withLock {
      guard current != identity else { return nil }
      if let previous = current {
        current = identity
        return .transitioned(from: previous, to: identity)
      }
      current = identity
      return .started(identity)
    }
    if let event { eventHandler(event) }
  }

  func end(request: [String: Any]) {
    let requestedThread = nonempty(request["threadID"])
    let requestedTurn = nonempty(request["turnID"])
    let ended: ComputerUseTurnIdentity? = lock.withLock {
      guard let current else { return nil }
      guard requestedThread == nil || requestedThread == current.threadID,
        requestedTurn == nil || requestedTurn == current.turnID
      else {
        return nil
      }
      self.current = nil
      return current
    }
    if let ended { eventHandler(.ended(ended)) }
  }

  private func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
