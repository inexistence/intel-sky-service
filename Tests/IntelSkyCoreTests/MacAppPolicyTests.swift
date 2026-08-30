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

@Test func appServerParserMatchesOfficialLegacyComputerUsePolicyShape() throws {
  let policy = try CodexAppServerPolicyResponseParser.parse([
    [
      "id": 2,
      "result": [
        "config": [
          "computer_use": [
            "allow_persistent_approval": false,
            "macos": [
              "denied_bundle_ids": ["example.denied"],
              "allowed_bundle_ids": ["example.allowed"],
            ],
          ]
        ]
      ],
    ]
  ])

  #expect(!policy.allowPersistentApproval)
  #expect(policy.deniedBundleIdentifiers == ["example.denied"])
  #expect(policy.allowedBundleIdentifiers == ["example.allowed"])
}

@Test func appServerParserSupportsCurrentRequirementsPolicyShape() throws {
  let policy = try CodexAppServerPolicyResponseParser.parse([
    ["id": 2, "result": ["config": ["computer_use": NSNull()]]],
    [
      "id": 3,
      "result": [
        "requirements": [
          "computerUse": [
            "allowPersistentApproval": false,
            "defaultAppAccess": "deny",
            "macos": [
              "bundleIds": [
                "example.allowed": "allow",
                "example.denied": "deny",
              ]
            ],
          ]
        ]
      ],
    ],
  ])

  #expect(!policy.allowPersistentApproval)
  #expect(policy.deniedBundleIdentifiers == ["example.denied"])
  #expect(policy.allowedBundleIdentifiers == ["example.allowed"])
}

@Test func appServerParserUsesOfficialDefaultWhenComputerUsePolicyIsAbsent() throws {
  let policy = try CodexAppServerPolicyResponseParser.parse([
    ["id": 2, "result": ["config": ["computer_use": NSNull()]]],
    ["id": 3, "result": ["requirements": NSNull()]],
  ])

  #expect(policy == ComputerUseOrganizationPolicy())
}

@Test func appServerPolicyLoaderWaitsForInitializationBeforeReadingPolicy() throws {
  let scriptURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("policy-app-server-\(UUID().uuidString)")
  let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\n' '{"id":1,"result":{"userAgent":"fixture"}}' ;;
        *'"id":2'*) printf '%s\n' '{"id":2,"result":{"config":{"computer_use":{"allow_persistent_approval":false,"macos":{"denied_bundle_ids":["example.denied"],"allowed_bundle_ids":null}}}}}' ;;
        *'"id":3'*) printf '%s\n' '{"id":3,"result":{"requirements":null}}' ;;
      esac
    done
    """#
  try Data(script.utf8).write(to: scriptURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: scriptURL.path
  )
  defer { try? FileManager.default.removeItem(at: scriptURL) }

  let policy = try CodexAppServerPolicyLoader(
    environment: ["CODEX_CLI_PATH": scriptURL.path]
  ).load(timeout: 2)

  #expect(!policy.allowPersistentApproval)
  #expect(policy.deniedBundleIdentifiers == ["example.denied"])
  #expect(policy.allowedBundleIdentifiers == nil)
}

@Test func organizationPolicyCannotOverrideServiceLocalForbiddenClassifier() throws {
  let loader = StaticOrganizationPolicyLoader(
    value: ComputerUseOrganizationPolicy(
      allowPersistentApproval: false,
      deniedBundleIdentifiers: [],
      allowedBundleIdentifiers: ["com.apple.Terminal"]
    ))
  let evaluator = CodexAppServerMacAppPolicyEvaluator(
    provider: CodexAppServerComputerUsePolicyProvider(loader: loader)
  )

  let policy = try evaluator.policy(
    for: ResolvedMacApplication(
      bundleIdentifier: "com.apple.Terminal",
      displayName: "Terminal",
      appPath: "/System/Applications/Utilities/Terminal.app"
    ))

  #expect(policy.decision == .forbidden)
  #expect(!policy.allowPersistentApproval)
}

@Test func organizationPolicyDeniesAppsOutsideAllowList() throws {
  let loader = StaticOrganizationPolicyLoader(
    value: ComputerUseOrganizationPolicy(
      deniedBundleIdentifiers: [],
      allowedBundleIdentifiers: ["example.allowed"]
    ))
  let evaluator = CodexAppServerMacAppPolicyEvaluator(
    provider: CodexAppServerComputerUsePolicyProvider(loader: loader)
  )

  let policy = try evaluator.policy(
    for: ResolvedMacApplication(
      bundleIdentifier: "example.other",
      displayName: "Other",
      appPath: "/Applications/Other.app"
    ))

  #expect(policy.decision == .denied)
}

@Test func appServerPolicyCacheUsesOfficialTTLBehavior() throws {
  let clock = PolicyTestClock(Date(timeIntervalSince1970: 1_000))
  let loader = CountingOrganizationPolicyLoader()
  let provider = CodexAppServerComputerUsePolicyProvider(
    loader: loader,
    cacheTTL: 900,
    now: { clock.value() }
  )

  _ = try provider.policy()
  clock.advance(by: 899)
  _ = try provider.policy()
  #expect(loader.count() == 1)

  clock.advance(by: 2)
  _ = try provider.policy()
  #expect(loader.count() == 2)
}

@Test func appServerPolicyFailuresAreExplicitAndNeverCachedAsAllowAll() {
  let loader = FailingOrganizationPolicyLoader()
  let provider = CodexAppServerComputerUsePolicyProvider(loader: loader)

  #expect(throws: CodexAppServerPolicyError.self) { _ = try provider.policy() }
  #expect(throws: CodexAppServerPolicyError.self) { _ = try provider.policy() }
  #expect(loader.count() == 2)
}

@Test func concurrentPolicyRequestsShareOneAppServerLoad() {
  let loader = SlowOrganizationPolicyLoader()
  let provider = CodexAppServerComputerUsePolicyProvider(loader: loader)
  let group = DispatchGroup()

  for _ in 0..<8 {
    group.enter()
    DispatchQueue.global().async {
      _ = try? provider.policy()
      group.leave()
    }
  }

  #expect(group.wait(timeout: .now() + 3) == .success)
  #expect(loader.count() == 1)
}

private struct StaticOrganizationPolicyLoader: ComputerUseOrganizationPolicyLoading {
  let value: ComputerUseOrganizationPolicy

  func load(timeout: TimeInterval) throws -> ComputerUseOrganizationPolicy { value }
}

private final class CountingOrganizationPolicyLoader: ComputerUseOrganizationPolicyLoading,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var loadCount = 0

  func load(timeout: TimeInterval) throws -> ComputerUseOrganizationPolicy {
    lock.withLock { loadCount += 1 }
    return ComputerUseOrganizationPolicy()
  }

  func count() -> Int { lock.withLock { loadCount } }
}

private final class FailingOrganizationPolicyLoader: ComputerUseOrganizationPolicyLoading,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var loadCount = 0

  func load(timeout: TimeInterval) throws -> ComputerUseOrganizationPolicy {
    lock.withLock { loadCount += 1 }
    throw CodexAppServerPolicyError.invalidResponse
  }

  func count() -> Int { lock.withLock { loadCount } }
}

private final class SlowOrganizationPolicyLoader: ComputerUseOrganizationPolicyLoading,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var loadCount = 0

  func load(timeout: TimeInterval) throws -> ComputerUseOrganizationPolicy {
    lock.withLock { loadCount += 1 }
    Thread.sleep(forTimeInterval: 0.1)
    return ComputerUseOrganizationPolicy()
  }

  func count() -> Int { lock.withLock { loadCount } }
}

private final class PolicyTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  func value() -> Date { lock.withLock { date } }
  func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
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

@Test func httpURLSchemeIsClassifiedAsBrowser() throws {
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
    screenLockChecker: NoopScreenLockChecker(),
    interventionArbitrator: StubPolicyInterventionArbitrator(),
    policyEvaluator: RejectingPolicyEvaluator()
  )

  #expect(throws: MacAppPolicyError.self) {
    _ = try provider.getAppState(request: ["app": "example.forbidden"])
  }
  #expect(resolver.resolveApplicationCount == 1)
  #expect(resolver.resolveOrLaunchCount == 0)
}

@Test func getAppStateRejectsUserStoppedTargetBeforeLaunch() throws {
  let resolver = PolicyTrackingResolver()
  let sessions = ComputerUseSessionCoordinator()
  sessions.recordActive(
    ResolvedMacApp(
      processIdentifier: 123,
      bundleIdentifier: "example.forbidden",
      displayName: "Forbidden Fixture",
      appPath: "/Applications/Forbidden Fixture.app"
    ))
  _ = try sessions.stopApplication(request: ["app": "example.forbidden"])
  let provider = MacAppStateProvider(
    resolver: resolver,
    screenLockChecker: NoopScreenLockChecker(),
    interventionArbitrator: StubPolicyInterventionArbitrator(),
    sessionCoordinator: sessions
  )

  #expect(throws: SkySafetyError.self) {
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
