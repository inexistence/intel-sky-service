import Foundation

public protocol AppCaptureProviding: Sendable {
  func startCapture(request: [String: Any]) throws -> [String: Any]
  func nextCaptureUpdate(request: [String: Any]) throws -> [String: Any]
}

enum AppCaptureSessionError: Error, CustomStringConvertible {
  case invalidRequest(String)
  case duplicateRequest(String)
  case captureNotFound(String)

  var description: String {
    switch self {
    case .invalidRequest(let message): return message
    case .duplicateRequest(let requestID):
      return "A capture already exists for request ID \(requestID)"
    case .captureNotFound(let requestID):
      return "No capture exists for request ID \(requestID)"
    }
  }
}

public final class AppCaptureSessionManager: AppCaptureProviding, @unchecked Sendable {
  private static let currentVersion = 2

  private let lock = NSLock()
  private let appStateProvider: any AppStateProviding
  private let permissionDiagnostics: ServicePermissionDiagnostics
  private var updatesByRequestID: [String: [[String: Any]]] = [:]

  public init(
    appStateProvider: any AppStateProviding,
    permissionDiagnostics: ServicePermissionDiagnostics = .init()
  ) {
    self.appStateProvider = appStateProvider
    self.permissionDiagnostics = permissionDiagnostics
  }

  public func startCapture(request: [String: Any]) throws -> [String: Any] {
    let requestID = try Self.nonemptyString(request["requestId"], named: "requestId")
    let app = try Self.nonemptyString(request["app"], named: "app")
    _ = try Self.nonemptyString(
      request["permissionRequestId"],
      named: "permissionRequestId"
    )
    guard request["animationTarget"] is [String: Any] else {
      throw AppCaptureSessionError.invalidRequest("Capture animationTarget must be an object")
    }
    guard let version = Self.integer(request["version"]), version == Self.currentVersion else {
      throw AppCaptureSessionError.invalidRequest("Unsupported capture version")
    }
    guard lock.withLock({ updatesByRequestID[requestID] == nil }) else {
      throw AppCaptureSessionError.duplicateRequest(requestID)
    }

    let state = try appStateProvider.getAppState(request: ["app": app, "disableDiff": true])
    guard let appMetadata = state["app"] as? [String: Any],
      let skyshot = state["skyshot"] as? [String: Any],
      let text = skyshot["text"] as? String
    else {
      throw AppCaptureSessionError.invalidRequest("Capture state provider returned an invalid state")
    }

    var updates: [[String: Any]] = [
      ["type": "metadata", "app": appMetadata],
      ["type": "axText", "app": appMetadata, "text": text],
    ]
    if let screenshot = skyshot["screenshot"] as? [String: Any] {
      updates.append(["type": "screenshot", "app": appMetadata, "screenshot": screenshot])
    }
    updates.append(["type": "completed", "app": appMetadata])

    try lock.withLock {
      guard updatesByRequestID[requestID] == nil else {
        throw AppCaptureSessionError.duplicateRequest(requestID)
      }
      updatesByRequestID[requestID] = updates
    }

    return [
      "result": "started",
      "permissionGrantState": permissionGrantState(),
    ]
  }

  public func nextCaptureUpdate(request: [String: Any]) throws -> [String: Any] {
    let requestID = try Self.nonemptyString(request["requestId"], named: "requestId")
    return try lock.withLock {
      guard var updates = updatesByRequestID[requestID], !updates.isEmpty else {
        throw AppCaptureSessionError.captureNotFound(requestID)
      }
      let next = updates.removeFirst()
      if updates.isEmpty || next["type"] as? String == "completed"
        || next["type"] as? String == "failed"
      {
        updatesByRequestID.removeValue(forKey: requestID)
      } else {
        updatesByRequestID[requestID] = updates
      }
      return next
    }
  }

  private func permissionGrantState() -> String {
    let status = permissionDiagnostics.currentStatus()
    switch (status.accessibility, status.screenRecording) {
    case (true, true): return "both_granted"
    case (true, false): return "accessibility_granted"
    case (false, true): return "screen_recording_granted"
    case (false, false): return "none_granted"
    }
  }

  private static func nonemptyString(_ value: Any?, named name: String) throws -> String {
    guard let value = value as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AppCaptureSessionError.invalidRequest("Capture \(name) must be a non-empty string")
    }
    return value
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite,
      number.doubleValue.rounded() == number.doubleValue
    else {
      return nil
    }
    return number.intValue
  }
}
