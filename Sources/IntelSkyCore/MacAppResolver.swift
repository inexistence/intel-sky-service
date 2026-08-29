import AppKit
import CoreGraphics
import Foundation

public struct ResolvedMacApp: Sendable, Equatable {
  public let processIdentifier: pid_t
  public let bundleIdentifier: String
  public let displayName: String
  public let appPath: String

  public init(
    processIdentifier: pid_t,
    bundleIdentifier: String,
    displayName: String,
    appPath: String
  ) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
    self.appPath = appPath
  }
}

public enum MacAppResolutionError: Error, CustomStringConvertible {
  case missingIdentifier
  case notRunning(String)
  case missingBundleIdentifier(String)
  case missingAppPath(String)
  case noWindow(String)

  public var description: String {
    switch self {
    case .missingIdentifier: return "App request is missing an identifier"
    case .notRunning(let identifier): return "App is not running: \(identifier)"
    case .missingBundleIdentifier(let name): return "Running app has no bundle identifier: \(name)"
    case .missingAppPath(let name): return "Running app has no application path: \(name)"
    case .noWindow(let name): return "No on-screen window was found for \(name)"
    }
  }
}

public protocol MacAppResolving: Sendable {
  func resolve(_ value: Any?) throws -> ResolvedMacApp
  func frontWindowID(for app: ResolvedMacApp) throws -> CGWindowID
}

public struct MacAppResolver: MacAppResolving {
  public init() {}

  public func resolve(_ value: Any?) throws -> ResolvedMacApp {
    let runningApps = NSWorkspace.shared.runningApplications
    let app: NSRunningApplication?
    let requestedIdentifier: String

    if let identifier = value as? String,
      !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      requestedIdentifier = identifier
      app = runningApps.first { candidate in
        candidate.bundleIdentifier == identifier
          || candidate.localizedName?.caseInsensitiveCompare(identifier) == .orderedSame
          || candidate.bundleURL?.path == identifier
      }
    } else if let object = value as? [String: Any] {
      if let pid = object["pid"] as? NSNumber {
        requestedIdentifier = "pid \(pid)"
        app = NSRunningApplication(processIdentifier: pid_t(pid.int32Value))
      } else if let bundleIdentifier = object["bundleIdentifier"] as? String,
        !bundleIdentifier.isEmpty
      {
        requestedIdentifier = bundleIdentifier
        app = runningApps.first { $0.bundleIdentifier == bundleIdentifier }
      } else {
        throw MacAppResolutionError.missingIdentifier
      }
    } else {
      throw MacAppResolutionError.missingIdentifier
    }

    guard let app else {
      throw MacAppResolutionError.notRunning(requestedIdentifier)
    }
    let displayName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
    guard let bundleIdentifier = app.bundleIdentifier else {
      throw MacAppResolutionError.missingBundleIdentifier(displayName)
    }
    return ResolvedMacApp(
      processIdentifier: app.processIdentifier,
      bundleIdentifier: bundleIdentifier,
      displayName: displayName,
      appPath: app.bundleURL?.path ?? ""
    )
  }

  public func frontWindowID(for app: ResolvedMacApp) throws -> CGWindowID {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else {
      throw MacAppResolutionError.noWindow(app.displayName)
    }

    let candidates = windows.compactMap { window -> CGWindowID? in
      guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == app.processIdentifier,
        (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
        let number = window[kCGWindowNumber] as? NSNumber,
        let bounds = window[kCGWindowBounds] as? [String: Any],
        let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        rectangle.width > 1,
        rectangle.height > 1
      else {
        return nil
      }
      return CGWindowID(number.uint32Value)
    }

    // CGWindowListCopyWindowInfo is front-to-back, so the first normal,
    // non-empty window best matches the AX focused window.
    guard let result = candidates.first else {
      throw MacAppResolutionError.noWindow(app.displayName)
    }
    return result
  }
}
