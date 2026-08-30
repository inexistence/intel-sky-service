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

  private struct Presentation {
    let id: String
    let processIdentifier: pid_t
    let surface: RemoteHostedPIPSurface
    let capture: any RemoteHostedPIPWindowCapturing
    var nextOperationID: UInt64
    var ending: Bool
  }

  private let lock = NSLock()
  private let host: any RemoteHostedPIPHostCalling
  private let surfaceFactory: @Sendable (URL) throws -> RemoteHostedPIPSurface
  private let captureFactory:
    @Sendable (pid_t, CGSize, RemoteHostedPIPSurface) -> any RemoteHostedPIPWindowCapturing
  private var presentations: [Key: Presentation] = [:]

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
  }

  func updateCursor(point: CGPoint, isActive: Bool) {
    guard lock.withLock({ !presentations.isEmpty }) else { return }
    try? host.setCursorLocation(point, isActive: isActive)
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
      guard let resized = try? existing.surface.update(imageURL: imageURL) else { return }
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
      existing.capture.refresh(outputSize: existing.surface.size)
      return
    }

    do {
      let surface = try surfaceFactory(imageURL)
      let presentationID = UUID().uuidString
      RemoteHostedPIPDiagnostics.logger.notice(
        "publishing presentation id=\(presentationID, privacy: .public) app=\(bundleIdentifier, privacy: .public) pid=\(processIdentifier, privacy: .public) size=\(surface.size.width, privacy: .public)x\(surface.size.height, privacy: .public)"
      )
      try host.publishPresentation(
        id: presentationID,
        threadID: threadID,
        turnID: turnID,
        contextID: surface.contextID,
        size: surface.size
      )
      do {
        try host.setSourceProcessIdentifier(
          processIdentifier,
          presentationID: presentationID
        )
      } catch {
        try? host.invalidatePresentation(id: presentationID)
        throw error
      }
      let capture = captureFactory(processIdentifier, surface.size, surface)
      lock.withLock {
        presentations[key] = Presentation(
          id: presentationID,
          processIdentifier: processIdentifier,
          surface: surface,
          capture: capture,
          nextOperationID: 1,
          ending: false
        )
      }
      capture.start()
      RemoteHostedPIPDiagnostics.logger.notice(
        "presentation capture requested id=\(presentationID, privacy: .public)"
      )
    } catch {
      RemoteHostedPIPDiagnostics.logger.error(
        "presentation publish failed app=\(bundleIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      // Presentation is an optional UX layer; public Computer Use must continue if it is absent.
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
      do {
        try host.willEndStream(presentationID: presentation.id)
        scheduleFallbackInvalidation(presentationID: presentation.id)
      } catch {
        invalidate(presentationID: presentation.id)
      }
    }
  }

  private func scheduleFallbackInvalidation(presentationID: String) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.invalidate(presentationID: presentationID)
    }
  }

  private func invalidate(presentationID: String) {
    let removed = lock.withLock { () -> Presentation? in
      guard let key = presentations.first(where: { $0.value.id == presentationID })?.key else {
        return nil
      }
      return presentations.removeValue(forKey: key)
    }
    removed?.capture.stop()
    if removed != nil {
      RemoteHostedPIPDiagnostics.logger.notice(
        "invalidating presentation id=\(presentationID, privacy: .public)"
      )
      try? host.invalidatePresentation(id: presentationID)
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
