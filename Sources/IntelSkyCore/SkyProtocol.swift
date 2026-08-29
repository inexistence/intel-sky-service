import Foundation

public enum SkyProtocol {
  public static let apiVersion = "CodexComputerUseIPC-5"
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

public struct SkyRequestRouter: Sendable {
  private let appCatalog: any AppCatalog
  private let appStateProvider: (any AppStateProviding)?

  public init(appCatalog: any AppCatalog, appStateProvider: (any AppStateProviding)? = nil) {
    self.appCatalog = appCatalog
    self.appStateProvider = appStateProvider
  }

  public func handle(_ payload: Data) -> Data {
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
      switch requestType {
      case "ComputerUseIPCListAppsRequest":
        return try appCatalog.listApps()
      case "ComputerUseIPCAppGetSkyshotRequest":
        guard let appStateProvider else {
          throw SkyRPCError.unsupportedRequestType(requestType)
        }
        return try appStateProvider.getAppState(request: request)
      case "ComputerUseIPCAppPolicyRequest":
        guard let appStateProvider else {
          throw SkyRPCError.unsupportedRequestType(requestType)
        }
        return try appStateProvider.getAppPolicy(request: request)
      default:
        throw SkyRPCError.unsupportedRequestType(requestType)
      }
    default:
      throw SkyRPCError.unsupportedMethod(method)
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
    case SkyRPCError.unsupportedRequestType: return -32601
    case SkyRPCError.versionMismatch: return -32001
    default: return -32603
    }
  }
}
