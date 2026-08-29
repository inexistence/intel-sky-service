import Foundation

public enum SkyServiceConfigurationError: Error, CustomStringConvertible {
  case invalidArguments
  case relativeSocketPath(String)

  public var description: String {
    switch self {
    case .invalidArguments:
      return "usage: intel-sky-service [--socket /absolute/path/computeruse.sock]"
    case .relativeSocketPath(let path):
      return "socket path must be absolute: \(path)"
    }
  }
}

public struct SkyServiceConfiguration: Equatable, Sendable {
  public static let groupContainerIdentifier = "2DC432GLL2.com.openai.sky.CUAService"

  public let socketPath: String

  public init(
    arguments: [String],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    let rawPath: String
    switch arguments.count {
    case 0:
      rawPath = Self.defaultSocketURL(homeDirectory: homeDirectory).path
    case 2 where arguments[0] == "--socket":
      rawPath = NSString(string: arguments[1]).expandingTildeInPath
    default:
      throw SkyServiceConfigurationError.invalidArguments
    }
    guard rawPath.hasPrefix("/") else {
      throw SkyServiceConfigurationError.relativeSocketPath(rawPath)
    }
    socketPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
  }

  public static func defaultSocketURL(homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent("Library/Group Containers", isDirectory: true)
      .appendingPathComponent(groupContainerIdentifier, isDirectory: true)
      .appendingPathComponent("IPC", isDirectory: true)
      .appendingPathComponent("computeruse.sock", isDirectory: false)
  }
}
