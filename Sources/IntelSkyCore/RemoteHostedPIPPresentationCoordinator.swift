import AppKit
import Foundation

public protocol SkyRequestResultObserving: Sendable {
  func observe(
    requestType: String,
    request: [String: Any],
    codexTurnMetadata: Any?,
    result: Any
  )
}

final class RemoteHostedPIPPresentationCoordinator: SkyRequestResultObserving,
  @unchecked Sendable
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

  func observe(
    requestType: String,
    request: [String: Any],
    codexTurnMetadata: Any?,
    result: Any
  ) {
    switch requestType {
    case "ComputerUseIPCAppGetSkyshotRequest":
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
      try? existing.surface.update(imageURL: imageURL)
      return
    }

    do {
      let surface = try surfaceFactory(imageURL)
      let presentationID = UUID().uuidString
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
          ending: false
        )
      }
      capture.start()
    } catch {
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
    if removed != nil { try? host.invalidatePresentation(id: presentationID) }
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
