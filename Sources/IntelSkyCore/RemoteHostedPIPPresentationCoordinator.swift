import AppKit
@preconcurrency import Darwin
import Foundation

@inline(__always)
private nonisolated(unsafe) func remoteHostedPIPTaskPort() -> mach_port_t {
  mach_task_self_
}

public protocol SkyRequestResultObserving: Sendable {
  func observe(
    requestType: String,
    request: [String: Any],
    codexTurnMetadata: Any?,
    result: Any
  )
}

final class RemoteHostedPIPPresentationCoordinator: SkyRequestResultObserving,
  ComputerUseTurnLifecycleEventHandling, @unchecked Sendable
{
  private struct Key: Hashable {
    let threadID: String
    let turnID: String
    let bundleIdentifier: String
  }

  private struct TurnScope: Hashable {
    let threadID: String
    let turnID: String
  }

  private struct Presentation {
    enum PublicationState {
      case pending
      case publishing
      case published
    }

    let id: String
    let processIdentifier: pid_t
    let surface: RemoteHostedPIPSurface
    let capture: any RemoteHostedPIPWindowCapturing
    var nextOperationID: UInt64
    var publicationState: PublicationState
    var captureStarted: Bool
    var ending: Bool
  }

  private let lock = NSLock()
  private let host: any RemoteHostedPIPHostCalling
  private let surfaceFactory: @Sendable (URL) throws -> RemoteHostedPIPSurface
  private let captureFactory:
    @Sendable (pid_t, CGSize, RemoteHostedPIPSurface) -> any RemoteHostedPIPWindowCapturing
  private var presentations: [Key: Presentation] = [:]
  private var maximumDisplayDimension: CGFloat?

  init(
    host: any RemoteHostedPIPHostCalling,
    surfaceFactory: @escaping @Sendable (URL) throws -> RemoteHostedPIPSurface = {
      try RemoteHostedPIPSurface(imageURL: $0)
    },
    captureFactory: @escaping @Sendable (pid_t, CGSize, RemoteHostedPIPSurface) ->
      any RemoteHostedPIPWindowCapturing = {
        RemoteHostedPIPWindowCapture(processIdentifier: $0, outputSize: $1, surface: $2)
      }
  ) {
    self.host = host
    self.surfaceFactory = surfaceFactory
    self.captureFactory = captureFactory
  }

  deinit {
    let captures = lock.withLock {
      let captures = presentations.values.map(\.capture)
      presentations.removeAll()
      return captures
    }
    for capture in captures { capture.stop() }
  }

  func installProducerCallbacks(on connection: RemoteHostedPIPConnectionController) {
    connection.setActionHandler { [weak self] presentationID, kind in
      try self?.performAction(presentationID: presentationID, kind: kind)
    }
    connection.setDidEndStreamHandler { [weak self] presentationID in
      self?.invalidate(presentationID: presentationID)
    }
    connection.setConnectionStateHandler { [weak self] connected in
      if connected { self?.hostDidReconnect() }
    }
    connection.setMaximumDisplaySizeHandler { [weak self] size in
      self?.setMaximumDisplayDimension(CGFloat(size))
    }
  }

  func hostDidReconnect() {
    let keys = lock.withLock {
      presentations.compactMap { key, presentation in presentation.ending ? nil : key }
    }
    for key in keys { publishPresentation(for: key, allowRepublish: true) }
  }

  @discardableResult
  func updateCursor(point: CGPoint, isActive: Bool, isPressed: Bool) -> Bool {
    let surfaces = lock.withLock {
      presentations.values.compactMap { $0.ending ? nil : $0.surface }
    }
    guard !surfaces.isEmpty else { return false }
    for surface in surfaces {
      surface.updateCursor(screenPoint: point, isActive: isActive, isPressed: isPressed)
    }
    try? host.setCursorLocation(point, isActive: isActive)
    return true
  }

  func setMaximumDisplayDimension(_ maximumDimension: CGFloat) {
    guard maximumDimension.isFinite, maximumDimension > 0 else { return }
    let current = lock.withLock { () -> [(Key, Presentation)] in
      maximumDisplayDimension = maximumDimension
      return presentations.compactMap { key, presentation in
        presentation.ending ? nil : (key, presentation)
      }
    }
    for (key, presentation) in current {
      guard presentation.surface.setMaximumDisplayDimension(maximumDimension) else { continue }
      guard presentation.publicationState == .published else { continue }
      do {
        let fencePort = try presentation.surface.createFencePort()
        defer { mach_port_deallocate(remoteHostedPIPTaskPort(), fencePort) }
        try host.prepareResize(
          presentationID: presentation.id,
          operationID: presentation.nextOperationID,
          contextID: presentation.surface.contextID,
          size: presentation.surface.size,
          fencePort: fencePort
        )
        try host.completeOperation(
          presentationID: presentation.id,
          operationID: presentation.nextOperationID
        )
        lock.withLock {
          guard var stored = presentations[key], stored.id == presentation.id else { return }
          stored.nextOperationID += 1
          presentations[key] = stored
        }
        presentation.capture.refresh(outputSize: presentation.surface.captureOutputSize)
      } catch {
        RemoteHostedPIPDiagnostics.logger.error(
          "maximum display resize failed id=\(presentation.id, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        invalidate(presentationID: presentation.id)
      }
    }
  }

  func stopApplication(bundleIdentifier: String) {
    let presentationIDs = lock.withLock {
      presentations.compactMap { key, presentation in
        key.bundleIdentifier == bundleIdentifier ? presentation.id : nil
      }
    }
    for presentationID in presentationIDs { invalidate(presentationID: presentationID) }
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    switch event {
    case .started:
      break
    case .transitioned(let previous, _), .ended(let previous),
      .safetyTerminated(let previous, _):
      beginEndingPresentations(threadID: previous.threadID, turnID: previous.turnID)
    case .safetyRevoked:
      beginEndingAllPresentations()
    }
  }

  func observe(
    requestType: String,
    request: [String: Any],
    codexTurnMetadata: Any?,
    result: Any
  ) {
    switch requestType {
    case "ComputerUseIPCAppGetSkyshotRequest", "ComputerUseIPCAppStartRequest":
      publishOrUpdate(codexTurnMetadata: codexTurnMetadata, result: result)
    case "ComputerUseIPCCodexTurnEndedRequest":
      endPresentations(request: request)
    default:
      break
    }
  }

  private func publishOrUpdate(codexTurnMetadata: Any?, result: Any) {
    guard let metadata = codexTurnMetadata as? [String: Any],
      let threadID = Self.nonempty(metadata["thread_id"]),
      let turnID = Self.nonempty(metadata["turn_id"]),
      let result = result as? [String: Any],
      let app = result["app"] as? [String: Any],
      let bundleIdentifier = Self.nonempty(app["bundleIdentifier"]),
      let processIdentifier = (app["pid"] as? NSNumber)?.int32Value,
      processIdentifier > 0,
      let skyshot = result["skyshot"] as? [String: Any],
      let screenshot = skyshot["screenshot"] as? [String: Any],
      let rawURL = Self.nonempty(screenshot["url"]),
      let imageURL = URL(string: rawURL), imageURL.isFileURL
    else {
      return
    }

    let key = Key(
      threadID: threadID,
      turnID: turnID,
      bundleIdentifier: bundleIdentifier
    )
    if let existing = lock.withLock({ presentations[key] }), !existing.ending {
      RemoteHostedPIPDiagnostics.logger.notice(
        "refreshing presentation id=\(existing.id, privacy: .public) app=\(bundleIdentifier, privacy: .public)"
      )
      if existing.processIdentifier != processIdentifier {
        switch existing.publicationState {
        case .pending:
          replacePendingContext(
            for: key,
            existing: existing,
            processIdentifier: processIdentifier,
            imageURL: imageURL
          )
        case .publishing:
          // A later state refresh will retry replacement after this publication attempt settles.
          break
        case .published:
          replaceContext(
            for: key,
            existing: existing,
            processIdentifier: processIdentifier,
            imageURL: imageURL
          )
        }
        return
      }
      guard let resized = try? existing.surface.update(imageURL: imageURL) else { return }
      guard existing.publicationState == .published else {
        if host.isConnected { publishPresentation(for: key, allowRepublish: false) }
        return
      }
      if resized {
        do {
          let fencePort = try existing.surface.createFencePort()
          defer { mach_port_deallocate(remoteHostedPIPTaskPort(), fencePort) }
          try host.prepareResize(
            presentationID: existing.id,
            operationID: existing.nextOperationID,
            contextID: existing.surface.contextID,
            size: existing.surface.size,
            fencePort: fencePort
          )
          try host.completeOperation(
            presentationID: existing.id,
            operationID: existing.nextOperationID
          )
          lock.withLock {
            guard var presentation = presentations[key], presentation.id == existing.id else {
              return
            }
            presentation.nextOperationID += 1
            presentations[key] = presentation
          }
        } catch {
          invalidate(presentationID: existing.id)
          return
        }
      }
      existing.capture.refresh(outputSize: existing.surface.captureOutputSize)
      return
    }

    do {
      let surface = try surfaceFactory(imageURL)
      surface.setMaximumDisplayDimension(lock.withLock { maximumDisplayDimension })
      let presentationID = UUID().uuidString
      RemoteHostedPIPDiagnostics.logger.notice(
        "publishing presentation id=\(presentationID, privacy: .public) app=\(bundleIdentifier, privacy: .public) pid=\(processIdentifier, privacy: .public) size=\(surface.size.width, privacy: .public)x\(surface.size.height, privacy: .public)"
      )
      let capture = captureFactory(processIdentifier, surface.captureOutputSize, surface)
      lock.withLock {
        presentations[key] = Presentation(
          id: presentationID,
          processIdentifier: processIdentifier,
          surface: surface,
          capture: capture,
          nextOperationID: 1,
          publicationState: .pending,
          captureStarted: false,
          ending: false
        )
      }
      if host.isConnected {
        publishPresentation(for: key, allowRepublish: false)
      } else {
        RemoteHostedPIPDiagnostics.logger.notice(
          "presentation deferred until native host connects id=\(presentationID, privacy: .public)"
        )
      }
    } catch {
      RemoteHostedPIPDiagnostics.logger.error(
        "presentation publish failed app=\(bundleIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      // Presentation is an optional UX layer; public Computer Use must continue if it is absent.
    }
  }

  private func replaceContext(
    for key: Key,
    existing: Presentation,
    processIdentifier: pid_t,
    imageURL: URL
  ) {
    do {
      let surface = try surfaceFactory(imageURL)
      surface.setMaximumDisplayDimension(lock.withLock { maximumDisplayDimension })
      let capture = captureFactory(processIdentifier, surface.captureOutputSize, surface)
      let fencePort = try surface.createFencePort()
      defer { mach_port_deallocate(remoteHostedPIPTaskPort(), fencePort) }
      try host.prepareContextReplacement(
        presentationID: existing.id,
        operationID: existing.nextOperationID,
        contextID: surface.contextID,
        size: surface.size,
        fencePort: fencePort
      )
      try host.setSourceProcessIdentifier(processIdentifier, presentationID: existing.id)
      try host.completeOperation(
        presentationID: existing.id,
        operationID: existing.nextOperationID
      )
      let didReplace = lock.withLock { () -> Bool in
        guard let current = presentations[key], current.id == existing.id,
          current.processIdentifier == existing.processIdentifier, !current.ending
        else { return false }
        presentations[key] = Presentation(
          id: existing.id,
          processIdentifier: processIdentifier,
          surface: surface,
          capture: capture,
          nextOperationID: existing.nextOperationID + 1,
          publicationState: .published,
          captureStarted: true,
          ending: false
        )
        return true
      }
      guard didReplace else {
        capture.stop()
        invalidate(presentationID: existing.id)
        return
      }
      existing.capture.stop()
      capture.start()
      RemoteHostedPIPDiagnostics.logger.notice(
        "replaced presentation context id=\(existing.id, privacy: .public) oldPID=\(existing.processIdentifier, privacy: .public) newPID=\(processIdentifier, privacy: .public)"
      )
    } catch {
      RemoteHostedPIPDiagnostics.logger.error(
        "presentation context replacement failed id=\(existing.id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      invalidate(presentationID: existing.id)
    }
  }

  private func replacePendingContext(
    for key: Key,
    existing: Presentation,
    processIdentifier: pid_t,
    imageURL: URL
  ) {
    do {
      let surface = try surfaceFactory(imageURL)
      surface.setMaximumDisplayDimension(lock.withLock { maximumDisplayDimension })
      let capture = captureFactory(processIdentifier, surface.captureOutputSize, surface)
      let didReplace = lock.withLock { () -> Bool in
        guard let current = presentations[key], current.id == existing.id,
          current.processIdentifier == existing.processIdentifier, !current.ending,
          current.publicationState == .pending
        else { return false }
        presentations[key] = Presentation(
          id: existing.id,
          processIdentifier: processIdentifier,
          surface: surface,
          capture: capture,
          nextOperationID: existing.nextOperationID,
          publicationState: .pending,
          captureStarted: false,
          ending: false
        )
        return true
      }
      guard didReplace else {
        capture.stop()
        return
      }
      if existing.captureStarted { existing.capture.stop() }
      if host.isConnected { publishPresentation(for: key, allowRepublish: false) }
    } catch {
      RemoteHostedPIPDiagnostics.logger.error(
        "pending presentation context replacement failed id=\(existing.id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  private func performAction(presentationID: String, kind: String) throws {
    guard kind == "focus-presentation" else {
      throw RemoteHostedPIPHostCallError.rejected(
        NSError(
          domain: "dev.huangjianbin.intel-sky-service.remote-hosted-pip",
          code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Unsupported PIP action: \(kind)"]
        )
      )
    }
    guard
      let presentation = lock.withLock({
        presentations.values.first { $0.id == presentationID && !$0.ending }
      }), let app = NSRunningApplication(processIdentifier: presentation.processIdentifier)
    else {
      throw RemoteHostedPIPHostCallError.unavailable
    }
    guard app.activate(options: [.activateAllWindows]) else {
      throw RemoteHostedPIPHostCallError.unavailable
    }
    try? host.noteInteraction(presentationID: presentationID)
  }

  private func endPresentations(request: [String: Any]) {
    guard let threadID = Self.nonempty(request["threadID"]) else { return }
    let turnID = Self.nonempty(request["turnID"])
    beginEndingPresentations(threadID: threadID, turnID: turnID)
  }

  private func beginEndingPresentations(threadID: String, turnID: String?) {
    let ending = lock.withLock { () -> [Presentation] in
      var selected: [Presentation] = []
      for key in presentations.keys
      where key.threadID == threadID && (turnID == nil || key.turnID == turnID) {
        guard var presentation = presentations[key], !presentation.ending else { continue }
        presentation.ending = true
        presentations[key] = presentation
        selected.append(presentation)
      }
      return selected
    }
    for presentation in ending {
      guard presentation.publicationState == .published || presentation.captureStarted else {
        invalidate(presentationID: presentation.id)
        continue
      }
      do {
        try host.willEndStream(presentationID: presentation.id)
        scheduleFallbackInvalidation(presentationID: presentation.id)
      } catch {
        invalidate(presentationID: presentation.id)
      }
    }
  }

  private func beginEndingAllPresentations() {
    let scopes = lock.withLock {
      Set(presentations.keys.map { TurnScope(threadID: $0.threadID, turnID: $0.turnID) })
    }
    for scope in scopes {
      beginEndingPresentations(threadID: scope.threadID, turnID: scope.turnID)
    }
  }

  private func scheduleFallbackInvalidation(presentationID: String) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.invalidate(presentationID: presentationID)
    }
  }

  private func invalidate(presentationID: String, notifyHost: Bool = true) {
    let removed = lock.withLock { () -> Presentation? in
      guard let key = presentations.first(where: { $0.value.id == presentationID })?.key else {
        return nil
      }
      return presentations.removeValue(forKey: key)
    }
    if let removed {
      if removed.captureStarted { removed.capture.stop() }
      RemoteHostedPIPDiagnostics.logger.notice(
        "invalidating presentation id=\(presentationID, privacy: .public)"
      )
      if notifyHost && (removed.publicationState == .published || removed.captureStarted) {
        try? host.invalidatePresentation(id: presentationID)
      }
    }
  }

  private func publishPresentation(for key: Key, allowRepublish: Bool) {
    let attempt = lock.withLock { () -> (Presentation, Bool)? in
      guard var presentation = presentations[key], !presentation.ending,
        presentation.publicationState != .publishing,
        allowRepublish || presentation.publicationState == .pending
      else { return nil }
      let captureWasStarted = presentation.captureStarted
      presentation.publicationState = .publishing
      presentations[key] = presentation
      return (presentation, captureWasStarted)
    }
    guard let (presentation, captureWasStarted) = attempt else { return }

    var hostAcceptedPresentation = false
    do {
      try host.publishPresentation(
        id: presentation.id,
        threadID: key.threadID,
        turnID: key.turnID,
        contextID: presentation.surface.contextID,
        size: presentation.surface.size
      )
      hostAcceptedPresentation = true
      try host.setSourceProcessIdentifier(
        presentation.processIdentifier,
        presentationID: presentation.id
      )
      let shouldStartCapture = lock.withLock { () -> Bool? in
        guard var current = presentations[key], current.id == presentation.id,
          !current.ending
        else { return nil }
        current.publicationState = .published
        let shouldStart = !current.captureStarted
        current.captureStarted = true
        presentations[key] = current
        return shouldStart
      }
      guard let shouldStartCapture else {
        try? host.invalidatePresentation(id: presentation.id)
        invalidate(presentationID: presentation.id, notifyHost: false)
        return
      }
      if shouldStartCapture {
        presentation.capture.start()
        RemoteHostedPIPDiagnostics.logger.notice(
          "presentation capture requested id=\(presentation.id, privacy: .public)"
        )
      } else if captureWasStarted {
        presentation.capture.refresh(outputSize: presentation.surface.captureOutputSize)
      }
    } catch {
      let isUnavailable: Bool
      if let hostError = error as? RemoteHostedPIPHostCallError,
        case .unavailable = hostError
      {
        isUnavailable = true
      } else {
        isUnavailable = false
      }
      if isUnavailable {
        lock.withLock {
          guard var current = presentations[key], current.id == presentation.id else { return }
          current.publicationState = .pending
          presentations[key] = current
        }
        RemoteHostedPIPDiagnostics.logger.notice(
          "presentation deferred after host disconnect id=\(presentation.id, privacy: .public)"
        )
        return
      }
      if hostAcceptedPresentation { try? host.invalidatePresentation(id: presentation.id) }
      RemoteHostedPIPDiagnostics.logger.error(
        "presentation publish failed id=\(presentation.id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      invalidate(presentationID: presentation.id)
    }
  }

  private static func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return value
  }
}
