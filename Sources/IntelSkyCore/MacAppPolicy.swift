import Foundation

public enum MacAppPolicyDecision: String, Sendable {
  case allowed
  case denied
  case forbidden
}

public enum MacAppPolicyRisk: String, Sendable {
  case low
  case high
}

public struct MacAppPolicy: Sendable, Equatable {
  public let allowPersistentApproval: Bool
  public let decision: MacAppPolicyDecision
  public let risk: MacAppPolicyRisk
  public let warningSubtitle: String?

  public init(
    allowPersistentApproval: Bool,
    decision: MacAppPolicyDecision,
    risk: MacAppPolicyRisk,
    warningSubtitle: String?
  ) {
    self.allowPersistentApproval = allowPersistentApproval
    self.decision = decision
    self.risk = risk
    self.warningSubtitle = warningSubtitle
  }
}

public protocol MacAppPolicyEvaluating: Sendable {
  func policy(for app: ResolvedMacApplication) throws -> MacAppPolicy
}

public enum MacAppPolicyError: Error, CustomStringConvertible {
  case denied(String)
  case forbidden(String)

  public var description: String {
    switch self {
    case .denied(let bundleIdentifier):
      return "Computer Use is blocked from using \(bundleIdentifier) by policy"
    case .forbidden(let bundleIdentifier):
      return "Computer Use is not allowed to use \(bundleIdentifier) for safety reasons"
    }
  }
}

extension MacAppPolicyEvaluating {
  func requireAllowed(_ app: ResolvedMacApplication) throws {
    switch try policy(for: app).decision {
    case .allowed: return
    case .denied: throw MacAppPolicyError.denied(app.bundleIdentifier)
    case .forbidden: throw MacAppPolicyError.forbidden(app.bundleIdentifier)
    }
  }
}

/// Reproduces the service-local safety classifier visible in the official ARM64 runtime.
/// Organization allow/deny policy is a separate upstream input in the official service and is
/// intentionally not inferred here.
public struct OfficialCompatibleMacAppPolicyEvaluator: MacAppPolicyEvaluating {
  public static let highRiskWarning =
    "Allowing ChatGPT to use this app introduces new risks, including those related to prompt "
    + "injection attacks, such as data theft or loss. Carefully monitor ChatGPT while it uses "
    + "this app."

  // These identifiers occur contiguously in the official classifier's static data. Keep the
  // categories explicit so a future ARM oracle or newer binary can update them independently.
  static let forbiddenBundleIdentifiers: Set<String> = [
    // Cross-device surfaces and credential managers.
    "com.apple.ScreenContinuity",
    "com.1password.1password",
    "com.1password.safari",
    "com.bitwarden.desktop",
    "com.dashlane.dashlanephonefinal",
    "com.lastpass.LastPass",
    "com.nordsec.nordpass",
    "me.proton.pass.electron",
    "me.proton.pass.catalyst",

    // Terminals.
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "com.mitchellh.ghostty",
    "com.raphaelamorim.rio",
    "dev.commandline.waveterm",

    // Prevent Computer Use from recursively targeting its controlling OpenAI application.
    "com.openai.codex",
    "com.openai.codex.alpha",
    "com.openai.codex.beta",
    "com.openai.codex.dev",
    "com.openai.codex.nightly",
    "com.openai.chat",
    "com.openai.chat.alpha",
    "com.openai.chat.beta",
    "com.openai.chat.nightly",
    "com.openai.chat.mac-debug",

    // Browsers use the dedicated browser Computer Use surface.
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "com.google.Chrome.canary",
    "com.openai.atlas",
    "com.openai.atlas.alpha",
    "com.openai.atlas.beta",
    "ai.perplexity.comet",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser",
    "company.thebrowser.browser",
    "company.thebrowser.dia",
    "org.chromium.Chromium",
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "com.duckduckgo.macos.browser",

    // Authentication and security-agent UI must remain under direct user control.
    "com.apple.UserNotificationCenter",
    "com.apple.LocalAuthenticationRemoteService",
    "com.apple.LocalAuthentication.UIAgent",
    "com.apple.SecurityAgent",
  ]

  public init() {}

  public func policy(for app: ResolvedMacApplication) -> MacAppPolicy {
    let risk: MacAppPolicyRisk = app.bundleIdentifier == "com.apple.finder" ? .low : .high
    let forbidden =
      Self.forbiddenBundleIdentifiers.contains(app.bundleIdentifier)
      || Self.isWebBrowserApp(atPath: app.appPath)
    return MacAppPolicy(
      allowPersistentApproval: true,
      decision: forbidden ? .forbidden : .allowed,
      risk: risk,
      warningSubtitle: risk == .high ? Self.highRiskWarning : nil
    )
  }

  private static func isWebBrowserApp(atPath path: String) -> Bool {
    guard !path.isEmpty, let bundle = Bundle(url: URL(fileURLWithPath: path)) else { return false }
    if let principalClass = bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String,
      principalClass == "AppleApplication" || principalClass == "BrowserCrApplication"
    {
      return true
    }
    guard let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
    else { return false }
    return urlTypes.contains { urlType in
      guard let schemes = urlType["CFBundleURLSchemes"] as? [String] else { return false }
      return schemes.contains { $0.caseInsensitiveCompare("http") == .orderedSame }
    }
  }
}

extension ResolvedMacApplication {
  init(_ runningApp: ResolvedMacApp) {
    self.init(
      bundleIdentifier: runningApp.bundleIdentifier,
      displayName: runningApp.displayName,
      appPath: runningApp.appPath
    )
  }
}
