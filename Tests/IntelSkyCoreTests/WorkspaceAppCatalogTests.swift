import Foundation
import Testing

@testable import IntelSkyCore

@Test func recentUsageProviderDataUsesOfficialFields() throws {
  let provider = StubRecentAppUsageProvider(
    apps: [
      RecentAppUsage(
        appPath: "/Applications/Not Running.app",
        bundleIdentifier: "example.not-running",
        displayName: "Not Running",
        lastUsedDate: Date(timeIntervalSince1970: 1_700_000_000),
        useCount: 12
      )
    ]
  )
  let values = try WorkspaceAppCatalog(recentApps: provider).listApps()
  let app = try #require(
    values.first { $0["bundleIdentifier"] as? String == "example.not-running" }
  )

  #expect(app["isRunning"] as? Bool == false)
  #expect(app["useCount"] as? Int == 12)
  #expect((app["lastUsedDate"] as? String)?.hasPrefix("2023-11-14T22:13:20") == true)
}

private struct StubRecentAppUsageProvider: RecentAppUsageProviding {
  let apps: [RecentAppUsage]

  func recentApps() -> [RecentAppUsage] { apps }
}
