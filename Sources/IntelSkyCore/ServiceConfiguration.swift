import Foundation

public enum SkyServiceConfigurationError: Error, CustomStringConvertible {
  case invalidArguments
  case relativeSocketPath(String)

  public var description: String {
    switch self {
    case .invalidArguments:
      return
        "usage: intel-sky-service [--socket /absolute/path/computeruse.sock] [--disable-pip]"
    case .relativeSocketPath(let path):
      return "socket path must be absolute: \(path)"
    }
  }
}

public struct SkyServiceConfiguration: Equatable, Sendable {
  public static let groupContainerIdentifier = "2DC432GLL2.com.openai.sky.CUAService"

  public let socketPath: String
  public let remoteHostedPIPEnabled: Bool

  public init(
    arguments: [String],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    var rawPath: String?
    // The host rendezvous is authenticated twice (Apple Event sender and XPC peer),
    // and presentation failure is isolated from the Computer Use request result.
    // Keep an explicit rollback switch while making the official host path available
    // to ChatGPT's argument-free managed-service launch.
    var remoteHostedPIPEnabled = true
    var pipArgumentSeen = false
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--socket":
        guard rawPath == nil, index + 1 < arguments.count else {
          throw SkyServiceConfigurationError.invalidArguments
        }
        rawPath = NSString(string: arguments[index + 1]).expandingTildeInPath
        index += 2
      case "--experimental-pip":
        // Backward-compatible alias from the development-only phase.
        guard !pipArgumentSeen else {
          throw SkyServiceConfigurationError.invalidArguments
        }
        pipArgumentSeen = true
        remoteHostedPIPEnabled = true
        index += 1
      case "--disable-pip":
        guard !pipArgumentSeen else {
          throw SkyServiceConfigurationError.invalidArguments
        }
        pipArgumentSeen = true
        remoteHostedPIPEnabled = false
        index += 1
      default:
        throw SkyServiceConfigurationError.invalidArguments
      }
    }
    let resolvedPath = rawPath ?? Self.defaultSocketURL(homeDirectory: homeDirectory).path
    guard resolvedPath.hasPrefix("/") else {
      throw SkyServiceConfigurationError.relativeSocketPath(resolvedPath)
    }
    socketPath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
    self.remoteHostedPIPEnabled = remoteHostedPIPEnabled
  }

  public static func defaultSocketURL(homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent("Library/Group Containers", isDirectory: true)
      .appendingPathComponent(groupContainerIdentifier, isDirectory: true)
      .appendingPathComponent("IPC", isDirectory: true)
      .appendingPathComponent("computeruse.sock", isDirectory: false)
  }
}
