import Foundation

public enum SkyServiceConfigurationError: Error, CustomStringConvertible {
  case invalidArguments
  case relativeSocketPath(String)

  public var description: String {
    switch self {
    case .invalidArguments:
      return
        "usage: intel-sky-service [--socket /absolute/path/computeruse.sock] [--experimental-pip]"
    case .relativeSocketPath(let path):
      return "socket path must be absolute: \(path)"
    }
  }
}

public struct SkyServiceConfiguration: Equatable, Sendable {
  public static let groupContainerIdentifier = "2DC432GLL2.com.openai.sky.CUAService"
  public static let experimentalPIPEnvironmentVariable = "INTEL_SKY_EXPERIMENTAL_PIP"

  public let socketPath: String
  public let experimentalPIPEnabled: Bool

  public init(
    arguments: [String],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    var rawPath: String?
    var experimentalPIPEnabled =
      environment[Self.experimentalPIPEnvironmentVariable]?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) == "1"
    var experimentalPIPArgumentSeen = false
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
        guard !experimentalPIPArgumentSeen else {
          throw SkyServiceConfigurationError.invalidArguments
        }
        experimentalPIPArgumentSeen = true
        experimentalPIPEnabled = true
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
    self.experimentalPIPEnabled = experimentalPIPEnabled
  }

  public static func defaultSocketURL(homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent("Library/Group Containers", isDirectory: true)
      .appendingPathComponent(groupContainerIdentifier, isDirectory: true)
      .appendingPathComponent("IPC", isDirectory: true)
      .appendingPathComponent("computeruse.sock", isDirectory: false)
  }
}
