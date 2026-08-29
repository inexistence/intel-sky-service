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

public struct ResolvedMacWindow: Sendable, Equatable {
  public let windowID: CGWindowID
  public let screenFrame: CGRect

  public init(windowID: CGWindowID, screenFrame: CGRect) {
    self.windowID = windowID
    self.screenFrame = screenFrame
  }
}

public struct ResolvedMacApplication: Sendable, Equatable {
  public let bundleIdentifier: String
  public let displayName: String
  public let appPath: String

  public init(bundleIdentifier: String, displayName: String, appPath: String) {
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
  case launchFailed(String)

  public var description: String {
    switch self {
    case .missingIdentifier: return "App request is missing an identifier"
    case .notRunning(let identifier): return "App is not running: \(identifier)"
    case .missingBundleIdentifier(let name): return "Running app has no bundle identifier: \(name)"
    case .missingAppPath(let name): return "Running app has no application path: \(name)"
    case .noWindow(let name): return "No on-screen window was found for \(name)"
    case .launchFailed(let name): return "Could not launch app: \(name)"
    }
  }
}

public protocol MacAppResolving: Sendable {
  func resolve(_ value: Any?) throws -> ResolvedMacApp
  func resolveOrLaunch(_ value: Any?) throws -> ResolvedMacApp
  func resolveApplication(_ value: Any?) throws -> ResolvedMacApplication
  func frontWindow(for app: ResolvedMacApp) throws -> ResolvedMacWindow
}

extension MacAppResolving {
  func resolveOrLaunch(_ value: Any?) throws -> ResolvedMacApp { try resolve(value) }

  func resolveApplication(_ value: Any?) throws -> ResolvedMacApplication {
    let app = try resolve(value)
    return ResolvedMacApplication(
      bundleIdentifier: app.bundleIdentifier,
      displayName: app.displayName,
      appPath: app.appPath
    )
  }
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

  public func resolveOrLaunch(_ value: Any?) throws -> ResolvedMacApp {
    if let running = try? resolve(value) { return running }
    let target = try resolveApplication(value)
    let result = LaunchResultBox()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: target.appPath),
      configuration: configuration
    ) { application, error in
      result.finish(application: application, error: error)
    }

    let deadline = Date().addingTimeInterval(10)
    while !result.isFinished, Date() < deadline {
      try RequestDeadlineContext.check()
      _ = RunLoop.current.run(
        mode: .default,
        before: min(deadline, Date().addingTimeInterval(0.02))
      )
    }
    try RequestDeadlineContext.check()
    guard let application = result.application, result.error == nil else {
      throw MacAppResolutionError.launchFailed(target.displayName)
    }
    return try resolvedRunningApplication(application)
  }

  public func resolveApplication(_ value: Any?) throws -> ResolvedMacApplication {
    if let running = try? resolve(value) {
      return ResolvedMacApplication(
        bundleIdentifier: running.bundleIdentifier,
        displayName: running.displayName,
        appPath: running.appPath
      )
    }
    guard let identifier = value as? String,
      !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MacAppResolutionError.missingIdentifier
    }

    let appURL: URL?
    if identifier.hasPrefix("/") {
      appURL = URL(fileURLWithPath: identifier)
    } else if identifier.contains(".") {
      appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    } else {
      appURL = installedApplicationURL(named: identifier)
    }
    guard let appURL, appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
      FileManager.default.fileExists(atPath: appURL.path),
      let bundle = Bundle(url: appURL),
      let bundleIdentifier = bundle.bundleIdentifier
    else {
      throw MacAppResolutionError.notRunning(identifier)
    }
    let displayName =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? appURL.deletingPathExtension().lastPathComponent
    return ResolvedMacApplication(
      bundleIdentifier: bundleIdentifier,
      displayName: displayName,
      appPath: appURL.path
    )
  }

  public func frontWindow(for app: ResolvedMacApp) throws -> ResolvedMacWindow {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else {
      throw MacAppResolutionError.noWindow(app.displayName)
    }

    let candidates = windows.compactMap { window -> ResolvedMacWindow? in
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
      return ResolvedMacWindow(
        windowID: CGWindowID(number.uint32Value),
        screenFrame: rectangle
      )
    }

    // CGWindowListCopyWindowInfo is front-to-back, so the first normal,
    // non-empty window best matches the AX focused window.
    guard let result = candidates.first else {
      throw MacAppResolutionError.noWindow(app.displayName)
    }
    return result
  }

  private func resolvedRunningApplication(_ app: NSRunningApplication) throws -> ResolvedMacApp {
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

  private func installedApplicationURL(named requestedName: String) -> URL? {
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications",
        isDirectory: true
      ),
    ]
    var directories = roots.map { ($0, 0) }
    while !directories.isEmpty {
      let (directory, depth) = directories.removeFirst()
      guard
        let children = try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }
      for child in children {
        if child.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
          let fileName = child.deletingPathExtension().lastPathComponent
          if fileName.caseInsensitiveCompare(requestedName) == .orderedSame {
            return child
          }
          if let bundle = Bundle(url: child) {
            let displayName =
              (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
              ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            if displayName?.caseInsensitiveCompare(requestedName) == .orderedSame {
              return child
            }
          }
        } else if depth < 1,
          (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        {
          directories.append((child, depth + 1))
        }
      }
    }
    return nil
  }
}

private final class LaunchResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedApplication: NSRunningApplication?
  private var storedError: Error?
  private var finished = false

  var application: NSRunningApplication? {
    lock.withLock { storedApplication }
  }

  var error: Error? {
    lock.withLock { storedError }
  }

  var isFinished: Bool {
    lock.withLock { finished }
  }

  func finish(application: NSRunningApplication?, error: Error?) {
    lock.withLock {
      storedApplication = application
      storedError = error
      finished = true
    }
  }
}
