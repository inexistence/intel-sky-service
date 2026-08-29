import Foundation

public struct MacAppStateProvider: AppStateProviding {
  private let resolver: MacAppResolver
  private let accessibility: AccessibilitySnapshotter
  private let screenshots: WindowScreenshotter
  private let snapshotCache: ElementSnapshotCache

  public init(
    resolver: MacAppResolver = .init(),
    accessibility: AccessibilitySnapshotter = .init(),
    screenshots: WindowScreenshotter = .init(),
    snapshotCache: ElementSnapshotCache = .init()
  ) {
    self.resolver = resolver
    self.accessibility = accessibility
    self.screenshots = screenshots
    self.snapshotCache = snapshotCache
  }

  public func getAppState(request: [String: Any]) throws -> [String: Any] {
    let app = try resolver.resolve(request["app"])
    let snapshot = try accessibility.capture(app: app)
    snapshotCache.store(snapshot, for: app)
    var skyshot: [String: Any] = ["text": snapshot.text]

    if let windowID = try? resolver.frontWindowID(for: app),
      let screenshotURL = try? screenshots.capture(windowID: windowID)
    {
      skyshot["screenshot"] = [
        "url": screenshotURL.absoluteString,
        "mimeType": "image/png",
      ]
    }

    return [
      "app": [
        "bundleIdentifier": app.bundleIdentifier,
        "pid": Int(app.processIdentifier),
      ],
      "skyshot": skyshot,
    ]
  }

  public func getAppPolicy(request: [String: Any]) throws -> [String: Any] {
    let app = try resolver.resolve(request["app"])
    guard !app.appPath.isEmpty else {
      throw MacAppResolutionError.missingAppPath(app.displayName)
    }
    return [
      "allowPersistentApproval": true,
      "decision": "allowed",
      "target": [
        "appPath": app.appPath,
        "bundleIdentifier": app.bundleIdentifier,
        "displayName": app.displayName,
        "risk": app.bundleIdentifier == "com.apple.finder" ? "low" : "high",
      ],
    ]
  }
}
