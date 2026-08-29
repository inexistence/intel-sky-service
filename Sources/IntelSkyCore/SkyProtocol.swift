import Foundation

public enum SkyProtocol {
  public static let apiVersion = "CodexComputerUseIPC-5"
}

public enum SkyServerErrorCode: Int, Sendable {
  case senderProcessNotAuthenticated = -10_000
  case couldNotGetRequestData = -10_001
  case couldNotGetRequestTypeName = -10_002
  case couldNotResolveRequestType = -10_003
  case unhandledEvent = -10_004
  case unknownError = -10_005
  case appNotAllowed = -10_006
  case runningApplicationNotFound = -10_007
  case accessibilityError = -10_008
  case permissionsNotGranted = -10_009
  case invalidApp = -10_010
  case noActiveSession = -10_011
  case userStoppedSession = -10_012
  case incompatibleClientVersion = -10_013
  case permissionsPending = -10_014
  case blockedURL = -10_015
  case userIntervened = -10_016
  case couldNotGetSenderPID = -10_017
  case ambiguousApp = -10_018
  case couldNotGetBootstrapPort = -10_019
  case screenLocked = -10_020
}

enum SkyRuntimeError: Error, CustomStringConvertible {
  case deadlineExceeded

  var description: String {
    switch self {
    case .deadlineExceeded: return "Request deadline exceeded"
    }
  }
}

public enum SkyRPCError: Error, CustomStringConvertible {
  case parseError
  case invalidRequest(String)
  case unsupportedMethod(String)
  case unsupportedRequestType(String)
  case versionMismatch(String?)

  public var description: String {
    switch self {
    case .parseError: return "Invalid JSON"
    case .invalidRequest(let message): return message
    case .unsupportedMethod(let method): return "Unsupported JSON-RPC method: \(method)"
    case .unsupportedRequestType(let type): return "Unsupported Sky request type: \(type)"
    case .versionMismatch(let version):
      return
        "Client API version \(version ?? "<missing>") is incompatible with \(SkyProtocol.apiVersion)"
    }
  }
}

public protocol AppCatalog: Sendable {
  func listApps() throws -> [[String: Any]]
}

public protocol AppStateProviding: Sendable {
  func getAppState(request: [String: Any]) throws -> [String: Any]
  func getAppPolicy(request: [String: Any]) throws -> [String: Any]
}

public protocol AppActionPerforming: Sendable {
  func performAction(request: [String: Any]) throws -> [String: Any]
}

public struct SkyRequestRouter: Sendable {
  private let appCatalog: any AppCatalog
  private let appStateProvider: (any AppStateProviding)?
  private let appActionPerformer: (any AppActionPerforming)?
  private let appCaptureProvider: (any AppCaptureProviding)?
  private let executionGate: SkyRequestExecutionGate
  private let turnLifecycle: any ComputerUseTurnLifecycleHandling
  private let requestObserver: (any SkyRequestResultObserving)?

  public init(
    appCatalog: any AppCatalog,
    appStateProvider: (any AppStateProviding)? = nil,
    appActionPerformer: (any AppActionPerforming)? = nil,
    appCaptureProvider: (any AppCaptureProviding)? = nil,
    requestObserver: (any SkyRequestResultObserving)? = nil
  ) {
    self.init(
      appCatalog: appCatalog,
      appStateProvider: appStateProvider,
      appActionPerformer: appActionPerformer,
      appCaptureProvider: appCaptureProvider,
      requestObserver: requestObserver,
      turnLifecycle: ComputerUseTurnCoordinator()
    )
  }

  init(
    appCatalog: any AppCatalog,
    appStateProvider: (any AppStateProviding)?,
    appActionPerformer: (any AppActionPerforming)?,
    appCaptureProvider: (any AppCaptureProviding)? = nil,
    requestObserver: (any SkyRequestResultObserving)? = nil,
    turnLifecycle: any ComputerUseTurnLifecycleHandling
  ) {
    self.appCatalog = appCatalog
    self.appStateProvider = appStateProvider
    self.appActionPerformer = appActionPerformer
    self.appCaptureProvider = appCaptureProvider
    self.requestObserver = requestObserver
    self.executionGate = SkyRequestExecutionGate()
    self.turnLifecycle = turnLifecycle
  }

  public func handle(_ payload: Data) -> Data {
    executionGate.withLock { handleSerially(payload) }
  }

  private func handleSerially(_ payload: Data) -> Data {
    var requestID: Any = NSNull()
    do {
      let decoded: Any
      do {
        decoded = try JSONSerialization.jsonObject(with: payload)
      } catch {
        throw SkyRPCError.parseError
      }
      guard let object = decoded as? [String: Any] else {
        throw SkyRPCError.invalidRequest("Expected a JSON object")
      }
      requestID = object["id"] ?? NSNull()
      let result = try route(object)
      return try encode(["jsonrpc": "2.0", "id": requestID, "result": result])
    } catch {
      return
        (try? encode([
          "jsonrpc": "2.0",
          "id": requestID,
          "error": ["code": errorCode(for: error), "message": String(describing: error)],
        ]))
        ?? Data(
          "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
            .utf8)
    }
  }

  static func isCompatiblePing(_ payload: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      object["jsonrpc"] as? String == "2.0",
      object["method"] as? String == "ping",
      let params = object["params"] as? [String: Any]
    else {
      return false
    }
    return params["clientApiVersion"] as? String == SkyProtocol.apiVersion
  }

  private func route(_ object: [String: Any]) throws -> Any {
    guard object["jsonrpc"] as? String == "2.0",
      let method = object["method"] as? String
    else {
      throw SkyRPCError.invalidRequest("Invalid JSON-RPC 2.0 request")
    }

    guard let params = object["params"] as? [String: Any] else {
      throw SkyRPCError.invalidRequest("Missing or invalid params")
    }
    try validateVersion(params["clientApiVersion"] as? String)
    let deadline = try RequestDeadline(params["deadlineUnixMilliseconds"])
    return try RequestDeadlineContext.withDeadline(deadline.date) {
      try deadline.check()
      turnLifecycle.observe(metadata: params["codexTurnMetadata"])
      switch method {
      case "ping":
        return ["serverApiVersion": SkyProtocol.apiVersion]
      case "request":
        guard let requestType = params["requestType"] as? String else {
          throw SkyRPCError.invalidRequest("Missing requestType")
        }
        guard let request = params["request"] as? [String: Any] else {
          throw SkyRPCError.invalidRequest("Missing or invalid request payload")
        }
        let result: Any
        switch requestType {
        case "ComputerUseIPCCodexTurnEndedRequest":
          turnLifecycle.end(request: request)
          result = [:]
        case "ComputerUseIPCListAppsRequest":
          result = try appCatalog.listApps()
        case "ComputerUseIPCAppGetSkyshotRequest":
          guard let appStateProvider else {
            throw SkyRPCError.unsupportedRequestType(requestType)
          }
          result = try appStateProvider.getAppState(request: request)
        case "ComputerUseIPCAppPolicyRequest":
          guard let appStateProvider else {
            throw SkyRPCError.unsupportedRequestType(requestType)
          }
          result = try appStateProvider.getAppPolicy(request: request)
        case "ComputerUseIPCAppPerformActionRequest":
          guard let appActionPerformer else {
            throw SkyRPCError.unsupportedRequestType(requestType)
          }
          result = try appActionPerformer.performAction(request: request)
        case "ComputerUseIPCAppStartCaptureRequest":
          guard let appCaptureProvider else {
            throw SkyRPCError.unsupportedRequestType(requestType)
          }
          result = try appCaptureProvider.startCapture(request: request)
        case "ComputerUseIPCAppNextCaptureUpdateRequest":
          guard let appCaptureProvider else {
            throw SkyRPCError.unsupportedRequestType(requestType)
          }
          result = try appCaptureProvider.nextCaptureUpdate(request: request)
        default:
          throw SkyRPCError.unsupportedRequestType(requestType)
        }
        requestObserver?.observe(
          requestType: requestType,
          request: request,
          codexTurnMetadata: params["codexTurnMetadata"],
          result: result
        )
        try deadline.check()
        return result
      default:
        throw SkyRPCError.unsupportedMethod(method)
      }
    }
  }

  private func validateVersion(_ version: String?) throws {
    guard version == SkyProtocol.apiVersion else {
      throw SkyRPCError.versionMismatch(version)
    }
  }

  private func encode(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func errorCode(for error: Error) -> Int {
    switch error {
    case SkyRPCError.parseError: return -32700
    case SkyRPCError.invalidRequest: return -32600
    case SkyRPCError.unsupportedMethod: return -32601
    case SkyRPCError.unsupportedRequestType:
      return SkyServerErrorCode.couldNotResolveRequestType.rawValue
    case SkyRPCError.versionMismatch:
      return SkyServerErrorCode.incompatibleClientVersion.rawValue
    case SkyRuntimeError.deadlineExceeded:
      // IPC-5 has no dedicated deadline code. The ARM binary exposes this
      // message alongside the generic service error family.
      return SkyServerErrorCode.unknownError.rawValue
    case SkySafetyError.screenLocked:
      return SkyServerErrorCode.screenLocked.rawValue
    case SkySafetyError.secureInputEnabled:
      // ARM exposes secure-input state but no dedicated public code.
      return SkyServerErrorCode.accessibilityError.rawValue
    case SkySafetyError.userIntervened:
      return SkyServerErrorCode.userIntervened.rawValue
    case AccessibilitySnapshotError.permissionRequired,
      WindowScreenshotError.permissionRequired:
      return SkyServerErrorCode.permissionsNotGranted.rawValue
    case AccessibilitySnapshotError.noWindow,
      is MacAccessibilityActionError,
      is MacPasteError:
      return SkyServerErrorCode.accessibilityError.rawValue
    case ElementSnapshotCacheError.missingSnapshot,
      ElementSnapshotCacheError.expiredSnapshot:
      return SkyServerErrorCode.noActiveSession.rawValue
    case ElementSnapshotCacheError.unknownElement,
      ElementSnapshotCacheError.missingCoordinateSpace,
      ElementSnapshotCacheError.coordinateOutsideScreenshot:
      return SkyServerErrorCode.accessibilityError.rawValue
    case MacAppResolutionError.notRunning,
      MacAppResolutionError.launchFailed:
      return SkyServerErrorCode.runningApplicationNotFound.rawValue
    case MacAppResolutionError.missingIdentifier,
      MacAppResolutionError.missingBundleIdentifier,
      MacAppResolutionError.missingAppPath:
      return SkyServerErrorCode.invalidApp.rawValue
    case MacAppResolutionError.noWindow:
      return SkyServerErrorCode.accessibilityError.rawValue
    case MacAppActionError.invalidAction:
      return SkyServerErrorCode.couldNotGetRequestData.rawValue
    case MacAppActionError.unsupportedAction:
      return SkyServerErrorCode.unhandledEvent.rawValue
    case MacAppActionError.activationFailed:
      return SkyServerErrorCode.runningApplicationNotFound.rawValue
    case is AppCaptureSessionError:
      return SkyServerErrorCode.couldNotGetRequestData.rawValue
    case MacAppActionError.missingElementFrame,
      MacAppActionError.targetOutsideDisplays,
      MacAppActionError.eventCreationFailed:
      return SkyServerErrorCode.accessibilityError.rawValue
    default: return SkyServerErrorCode.unknownError.rawValue
    }
  }
}

private final class SkyRequestExecutionGate: @unchecked Sendable {
  private let lock = NSRecursiveLock()

  func withLock<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private struct RequestDeadline {
  private let unixMilliseconds: Double?

  var date: Date? {
    unixMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
  }

  init(_ value: Any?) throws {
    guard let value else {
      unixMilliseconds = nil
      return
    }
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite
    else {
      throw SkyRPCError.invalidRequest("deadlineUnixMilliseconds must be a finite number")
    }
    unixMilliseconds = number.doubleValue
  }

  func check(now: Date = Date()) throws {
    guard let unixMilliseconds else { return }
    if now.timeIntervalSince1970 * 1_000 >= unixMilliseconds {
      throw SkyRuntimeError.deadlineExceeded
    }
  }
}

enum RequestDeadlineContext {
  private static let key = "dev.huangjianbin.intel-sky-service.request-deadline"

  static func withDeadline<T>(_ deadline: Date?, operation: () throws -> T) rethrows -> T {
    let dictionary = Thread.current.threadDictionary
    let previous = dictionary[key]
    if let deadline {
      dictionary[key] = deadline
    } else {
      dictionary.removeObject(forKey: key)
    }
    defer {
      if let previous {
        dictionary[key] = previous
      } else {
        dictionary.removeObject(forKey: key)
      }
    }
    return try operation()
  }

  static func check(now: Date = Date()) throws {
    guard let deadline = Thread.current.threadDictionary[key] as? Date else { return }
    if now >= deadline { throw SkyRuntimeError.deadlineExceeded }
  }
}
