import AppKit
import Foundation

struct RecentAppUsage: Sendable, Equatable {
  let appPath: String
  let bundleIdentifier: String?
  let displayName: String
  let lastUsedDate: Date?
  let useCount: Int?
}

protocol RecentAppUsageProviding: Sendable {
  func recentApps() -> [RecentAppUsage]
}

final class SpotlightRecentAppUsageProvider: RecentAppUsageProviding, @unchecked Sendable {
  private let lock = NSLock()
  private let cacheDuration: TimeInterval
  private var cached: (date: Date, apps: [RecentAppUsage])?

  init(cacheDuration: TimeInterval = 300) {
    self.cacheDuration = cacheDuration
  }

  func recentApps() -> [RecentAppUsage] {
    let now = Date()
    if let cached = lock.withLock({ cached }),
      now.timeIntervalSince(cached.date) < cacheDuration
    {
      return cached.apps
    }
    let apps = loadRecentApps()
    lock.withLock { cached = (now, apps) }
    return apps
  }

  private func loadRecentApps() -> [RecentAppUsage] {
    let query =
      "kMDItemContentType == \"com.apple.application-bundle\" && "
      + "kMDItemFSName == \"*.app\" && "
      + "kMDItemLastUsedDate_Ranking >= $time.today(-14)"
    guard let queryData = run("/usr/bin/mdfind", arguments: [query]),
      let output = String(data: queryData, encoding: .utf8)
    else {
      return []
    }
    let paths = output.split(separator: "\n").prefix(256).map(String.init).filter {
      $0.hasSuffix(".app")
    }
    guard !paths.isEmpty,
      let metadataData = run("/usr/bin/mdls", arguments: ["-plist", "-"] + paths),
      let metadata = try? PropertyListSerialization.propertyList(from: metadataData, format: nil)
        as? [[String: Any]],
      metadata.count == paths.count
    else {
      return []
    }
    return zip(paths, metadata).map { path, values in
      let bundle = Bundle(url: URL(fileURLWithPath: path))
      return RecentAppUsage(
        appPath: path,
        bundleIdentifier: (values["kMDItemCFBundleIdentifier"] as? String)
          ?? bundle?.bundleIdentifier,
        displayName: (values["kMDItemDisplayName"] as? String)
          ?? bundleDisplayName(bundle, path: path),
        lastUsedDate: values["kMDItemLastUsedDate"] as? Date,
        useCount: (values["kMDItemUseCount"] as? NSNumber)?.intValue
      )
    }
  }

  private func bundleDisplayName(_ bundle: Bundle?, path: String) -> String {
    if let value = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String {
      return value
    }
    if let value = bundle?.localizedInfoDictionary?["CFBundleName"] as? String {
      return value
    }
    return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  private func run(_ executable: String, arguments: [String]) -> Data? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return process.terminationStatus == 0 ? data : nil
    } catch {
      return nil
    }
  }
}

public struct WorkspaceAppCatalog: AppCatalog {
  private let recentApps: any RecentAppUsageProviding

  public init() {
    self.recentApps = SpotlightRecentAppUsageProvider()
  }

  init(recentApps: any RecentAppUsageProviding) {
    self.recentApps = recentApps
  }

  public func listApps() throws -> [[String: Any]] {
    let workspace = NSWorkspace.shared
    let frontmostPID = workspace.frontmostApplication?.processIdentifier
    var valuesByIdentity: [String: [String: Any]] = [:]

    for app in workspace.runningApplications where app.activationPolicy != .prohibited {
      let bundleIdentifier = app.bundleIdentifier
      let appPath = app.bundleURL?.path
      let identity = bundleIdentifier ?? appPath ?? "pid:\(app.processIdentifier)"
      var value: [String: Any] = [
        "displayName": app.localizedName ?? bundleIdentifier ?? "Unknown",
        "isFrontmost": app.processIdentifier == frontmostPID,
        "isRunning": !app.isTerminated,
      ]
      if let bundleIdentifier { value["bundleIdentifier"] = bundleIdentifier }
      if let appPath { value["appPath"] = appPath }
      valuesByIdentity[identity] = value
    }

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for usage in recentApps.recentApps() {
      let identity = usage.bundleIdentifier ?? usage.appPath
      var value =
        valuesByIdentity[identity] ?? [
          "displayName": usage.displayName,
          "isFrontmost": false,
          "isRunning": false,
        ]
      value["appPath"] = usage.appPath
      if let bundleIdentifier = usage.bundleIdentifier {
        value["bundleIdentifier"] = bundleIdentifier
      }
      if let lastUsedDate = usage.lastUsedDate {
        value["lastUsedDate"] = dateFormatter.string(from: lastUsedDate)
      }
      if let useCount = usage.useCount { value["useCount"] = useCount }
      valuesByIdentity[identity] = value
    }

    return valuesByIdentity.values.sorted {
      let lhsRunning = $0["isRunning"] as? Bool ?? false
      let rhsRunning = $1["isRunning"] as? Bool ?? false
      if lhsRunning != rhsRunning { return lhsRunning && !rhsRunning }
      return (($0["displayName"] as? String) ?? "")
        .localizedCaseInsensitiveCompare(($1["displayName"] as? String) ?? "")
        == .orderedAscending
    }
  }
}
