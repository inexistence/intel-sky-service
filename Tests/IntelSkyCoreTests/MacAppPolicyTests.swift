import Foundation
import Testing

@testable import IntelSkyCore

@Test func finderIsAllowedWithoutHighRiskWarning() {
  let policy = OfficialCompatibleMacAppPolicyEvaluator().policy(
    for: ResolvedMacApplication(
      bundleIdentifier: "com.apple.finder",
      displayName: "Finder",
      appPath: "/System/Library/CoreServices/Finder.app"
    )
  )

  #expect(policy.decision == .allowed)
  #expect(policy.risk == .low)
  #expect(policy.warningSubtitle == nil)
  #expect(policy.allowPersistentApproval)
}

@Test(
  arguments: [
    "com.1password.1password",
    "com.apple.Terminal",
    "com.openai.codex",
    "com.openai.chat",
    "com.apple.Safari",
    "org.mozilla.firefox",
    "com.apple.SecurityAgent",
  ])
func officialSafetyCategoriesAreForbidden(bundleIdentifier: String) {
  let policy = OfficialCompatibleMacAppPolicyEvaluator().policy(
    for: ResolvedMacApplication(
      bundleIdentifier: bundleIdentifier,
      displayName: "Fixture",
      appPath: "/Applications/Fixture.app"
    )
  )

  #expect(policy.decision == .forbidden)
  #expect(policy.risk == .high)
  #expect(policy.warningSubtitle == OfficialCompatibleMacAppPolicyEvaluator.highRiskWarning)
}

@Test func nonFinderAllowedAppIsHighRiskWithOfficialWarning() {
  let policy = OfficialCompatibleMacAppPolicyEvaluator().policy(
    for: ResolvedMacApplication(
      bundleIdentifier: "com.apple.calculator",
      displayName: "Calculator",
      appPath: "/System/Applications/Calculator.app"
    )
  )

  #expect(policy.decision == .allowed)
  #expect(policy.risk == .high)
  #expect(policy.warningSubtitle == OfficialCompatibleMacAppPolicyEvaluator.highRiskWarning)
}

@Test func chromiumPrincipalClassIsForbiddenWithoutKnownBundleIdentifier() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
    .appendingPathExtension("app")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let info: [String: Any] = [
    "CFBundleIdentifier": "example.unlisted-browser",
    "CFBundlePackageType": "APPL",
    "NSPrincipalClass": "BrowserCrApplication",
  ]
  let data = try PropertyListSerialization.data(
    fromPropertyList: info,
    format: .xml,
    options: 0
  )
  try data.write(to: directory.appendingPathComponent("Info.plist"))

  let policy = OfficialCompatibleMacAppPolicyEvaluator().policy(
    for: ResolvedMacApplication(
      bundleIdentifier: "example.unlisted-browser",
      displayName: "Browser Fixture",
      appPath: directory.path
    )
  )

  #expect(policy.decision == .forbidden)
}

@Test func HTTPURLSchemeIsClassifiedAsBrowser() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
    .appendingPathExtension("app")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let info: [String: Any] = [
    "CFBundleIdentifier": "example.scheme-browser",
    "CFBundlePackageType": "APPL",
    "CFBundleURLTypes": [["CFBundleURLSchemes": ["custom", "HTTP"]]],
  ]
  let data = try PropertyListSerialization.data(
    fromPropertyList: info,
    format: .xml,
    options: 0
  )
  try data.write(to: directory.appendingPathComponent("Info.plist"))

  let policy = OfficialCompatibleMacAppPolicyEvaluator().policy(
    for: ResolvedMacApplication(
      bundleIdentifier: "example.scheme-browser",
      displayName: "Scheme Browser Fixture",
      appPath: directory.path
    )
  )

  #expect(policy.decision == .forbidden)
}

private struct StaticApplicationResolver: MacAppResolving {
  let app: ResolvedMacApplication

  func resolve(_ value: Any?) throws -> ResolvedMacApp {
    throw MacAppResolutionError.notRunning("fixture")
  }

  func resolveApplication(_ value: Any?) throws -> ResolvedMacApplication { app }

  func frontWindow(for app: ResolvedMacApp) throws -> ResolvedMacWindow {
    throw MacAppResolutionError.noWindow(app.displayName)
  }
}

private struct StaticPolicyEvaluator: MacAppPolicyEvaluating {
  let policyValue: MacAppPolicy

  func policy(for app: ResolvedMacApplication) -> MacAppPolicy { policyValue }
}

private struct RejectingPolicyEvaluator: MacAppPolicyEvaluating {
  func policy(for app: ResolvedMacApplication) -> MacAppPolicy {
    MacAppPolicy(
      allowPersistentApproval: false,
      decision: .forbidden,
      risk: .high,
      warningSubtitle: nil
    )
  }
}

@Test func appPolicyResponseUsesOfficialTargetSchema() throws {
  let warning = "Fixture warning"
  let provider = MacAppStateProvider(
    resolver: StaticApplicationResolver(
      app: ResolvedMacApplication(
        bundleIdentifier: "example.app",
        displayName: "Fixture",
        appPath: "/Applications/Fixture.app"
      )
    ),
    interventionArbitrator: StubPolicyInterventionArbitrator(),
    policyEvaluator: StaticPolicyEvaluator(
      policyValue: MacAppPolicy(
        allowPersistentApproval: false,
        decision: .denied,
        risk: .high,
        warningSubtitle: warning
      )
    )
  )

  let response = try provider.getAppPolicy(request: ["app": "example.app"])
  let target = try #require(response["target"] as? [String: Any])

  #expect(response["allowPersistentApproval"] as? Bool == false)
  #expect(response["decision"] as? String == "denied")
  #expect(target["appPath"] as? String == "/Applications/Fixture.app")
  #expect(target["bundleIdentifier"] as? String == "example.app")
  #expect(target["displayName"] as? String == "Fixture")
  #expect(target["risk"] as? String == "high")
  #expect(target["warningSubtitle"] as? String == warning)
}

private struct StubPolicyInterventionArbitrator: ComputerUseInterventionArbitrating {
  func stateRefreshCheckpoint(for app: ResolvedMacApp) -> UInt64? { nil }
  func recordFreshState(for app: ResolvedMacApp, checkpoint: UInt64?) {}
  func requireFreshState(for app: ResolvedMacApp) throws {}
}

@Test func getAppStateRejectsForbiddenTargetBeforeLaunch() throws {
  let resolver = PolicyTrackingResolver()
  let provider = MacAppStateProvider(
    resolver: resolver,
    interventionArbitrator: StubPolicyInterventionArbitrator(),
    policyEvaluator: RejectingPolicyEvaluator()
  )

  #expect(throws: MacAppPolicyError.self) {
    _ = try provider.getAppState(request: ["app": "example.forbidden"])
  }
  #expect(resolver.resolveApplicationCount == 1)
  #expect(resolver.resolveOrLaunchCount == 0)
}

private final class PolicyTrackingResolver: MacAppResolving, @unchecked Sendable {
  private(set) var resolveApplicationCount = 0
  private(set) var resolveOrLaunchCount = 0

  func resolve(_ value: Any?) throws -> ResolvedMacApp {
    throw MacAppResolutionError.notRunning("fixture")
  }

  func resolveOrLaunch(_ value: Any?) throws -> ResolvedMacApp {
    resolveOrLaunchCount += 1
    throw MacAppResolutionError.launchFailed("fixture")
  }

  func resolveApplication(_ value: Any?) throws -> ResolvedMacApplication {
    resolveApplicationCount += 1
    return ResolvedMacApplication(
      bundleIdentifier: "example.forbidden",
      displayName: "Forbidden Fixture",
      appPath: "/Applications/Forbidden Fixture.app"
    )
  }

  func frontWindow(for app: ResolvedMacApp) throws -> ResolvedMacWindow {
    throw MacAppResolutionError.noWindow(app.displayName)
  }
}
