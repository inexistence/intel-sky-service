import AppKit
import Foundation

public struct WorkspaceAppCatalog: AppCatalog {
  public init() {}

  public func listApps() throws -> [[String: Any]] {
    let workspace = NSWorkspace.shared
    let frontmostPID = workspace.frontmostApplication?.processIdentifier

    return workspace.runningApplications
      .filter { $0.activationPolicy != .prohibited }
      .map { app in
        var value: [String: Any] = [
          "displayName": app.localizedName ?? app.bundleIdentifier ?? "Unknown",
          "isFrontmost": app.processIdentifier == frontmostPID,
          "isRunning": !app.isTerminated,
        ]
        if let bundleIdentifier = app.bundleIdentifier {
          value["bundleIdentifier"] = bundleIdentifier
        }
        if let path = app.bundleURL?.path {
          value["appPath"] = path
        }
        return value
      }
      .sorted {
        (($0["displayName"] as? String) ?? "")
          .localizedCaseInsensitiveCompare(($1["displayName"] as? String) ?? "")
          == .orderedAscending
      }
  }
}
