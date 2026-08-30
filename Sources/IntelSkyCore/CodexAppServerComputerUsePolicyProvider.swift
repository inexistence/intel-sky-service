import Foundation

struct ComputerUseOrganizationPolicy: Sendable, Equatable {
  var allowPersistentApproval = true
  var deniedBundleIdentifiers: Set<String> = []
  var allowedBundleIdentifiers: Set<String>?
}

protocol ComputerUseOrganizationPolicyLoading: Sendable {
  func load(timeout: TimeInterval) throws -> ComputerUseOrganizationPolicy
}

/// Mirrors the ARM64 service's app-server policy cache: a successful policy is reused for fifteen
/// minutes and the local app-server request has a thirty-second deadline.
final class CodexAppServerComputerUsePolicyProvider: @unchecked Sendable {
  static let shared = CodexAppServerComputerUsePolicyProvider()
  static let officialCacheTTL: TimeInterval = 15 * 60
  static let officialTimeout: TimeInterval = 30

  private let condition = NSCondition()
  private let loader: any ComputerUseOrganizationPolicyLoading
  private let cacheTTL: TimeInterval
  private let timeout: TimeInterval
  private let now: @Sendable () -> Date
  private var cachedPolicy: ComputerUseOrganizationPolicy?
  private var cachedAt: Date?
  private var loading = false

  init(
    loader: any ComputerUseOrganizationPolicyLoading = CodexAppServerPolicyLoader(),
    cacheTTL: TimeInterval = officialCacheTTL,
    timeout: TimeInterval = officialTimeout,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.loader = loader
    self.cacheTTL = cacheTTL
    self.timeout = timeout
    self.now = now
  }

  func policy() throws -> ComputerUseOrganizationPolicy {
    condition.lock()
    while true {
      if let cachedPolicy, let cachedAt, now().timeIntervalSince(cachedAt) < cacheTTL {
        condition.unlock()
        return cachedPolicy
      }
      if !loading {
        loading = true
        condition.unlock()
        break
      }
      condition.wait()
    }

    let result = Result { try loader.load(timeout: timeout) }

    condition.lock()
    if case .success(let loaded) = result {
      cachedPolicy = loaded
      cachedAt = now()
    }
    loading = false
    condition.broadcast()
    condition.unlock()
    return try result.get()
  }
}

final class CodexAppServerMacAppPolicyEvaluator: MacAppPolicyEvaluating, @unchecked Sendable {
  static let shared = CodexAppServerMacAppPolicyEvaluator()

  private let localEvaluator: any MacAppPolicyEvaluating
  private let provider: CodexAppServerComputerUsePolicyProvider

  init(
    localEvaluator: any MacAppPolicyEvaluating = OfficialCompatibleMacAppPolicyEvaluator(),
    provider: CodexAppServerComputerUsePolicyProvider = .shared
  ) {
    self.localEvaluator = localEvaluator
    self.provider = provider
  }

  func policy(for app: ResolvedMacApplication) throws -> MacAppPolicy {
    let local = try localEvaluator.policy(for: app)
    let organization = try provider.policy()
    let decision: MacAppPolicyDecision
    if local.decision == .forbidden {
      decision = .forbidden
    } else if organization.deniedBundleIdentifiers.contains(app.bundleIdentifier) {
      decision = .denied
    } else if let allowed = organization.allowedBundleIdentifiers,
      !allowed.contains(app.bundleIdentifier)
    {
      decision = .denied
    } else {
      decision = local.decision
    }
    return MacAppPolicy(
      allowPersistentApproval: organization.allowPersistentApproval,
      decision: decision,
      risk: local.risk,
      warningSubtitle: local.warningSubtitle
    )
  }
}

struct CodexAppServerPolicyLoader: ComputerUseOrganizationPolicyLoading, @unchecked Sendable {
  private let environment: [String: String]
  private let fileManager: FileManager

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.fileManager = fileManager
  }

  func load(timeout: TimeInterval) throws -> ComputerUseOrganizationPolicy {
    let executable = try resolveExecutable()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["app-server", "--listen", "stdio://"]

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    let responses = JSONLineResponseCollector()
    let errorData = LockedData()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      responses.read(from: output.fileHandleForReading)
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }

    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    do {
      let initialize: [String: Any] = [
        "method": "initialize",
        "id": 1,
        "params": [
          "clientInfo": [
            "name": "codex-computer-use",
            "title": "Codex Computer Use",
            "version": "1",
          ],
          "capabilities": [
            "experimentalApi": true,
            "requestAttestation": false,
            "optOutNotificationMethods": [],
          ],
        ],
      ]
      try Self.send(initialize, to: input.fileHandleForWriting)
      try requireResponse(id: 1, from: responses, deadline: deadline, timeout: timeout)
      try Self.send(
        ["method": "config/read", "id": 2, "params": ["includeLayers": false]],
        to: input.fileHandleForWriting
      )
      try requireResponse(id: 2, from: responses, deadline: deadline, timeout: timeout)
      try Self.send(
        ["method": "configRequirements/read", "id": 3, "params": NSNull()],
        to: input.fileHandleForWriting
      )
      try requireResponse(id: 3, from: responses, deadline: deadline, timeout: timeout)
      try input.fileHandleForWriting.close()
    } catch {
      process.terminate()
      _ = terminated.wait(timeout: .now() + 1)
      throw error
    }

    let remaining = max(0, deadline.timeIntervalSinceNow)
    guard terminated.wait(timeout: .now() + remaining) == .success else {
      process.terminate()
      _ = terminated.wait(timeout: .now() + 1)
      throw CodexAppServerPolicyError.timedOut(timeout)
    }
    _ = readers.wait(timeout: .now() + 1)
    guard process.terminationStatus == 0 else {
      throw CodexAppServerPolicyError.rejected(Self.diagnostic(from: errorData.value()))
    }
    return try CodexAppServerPolicyResponseParser.parse(responses.messages())
  }

  private func resolveExecutable() throws -> String {
    let candidates = [
      environment["CODEX_CLI_PATH"],
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
    ].compactMap { $0 }
    guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
      throw CodexAppServerPolicyError.executableUnavailable
    }
    return path
  }

  private static func send(_ request: [String: Any], to handle: FileHandle) throws {
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    handle.write(data)
    handle.write(Data("\n".utf8))
  }

  private func requireResponse(
    id: Int,
    from responses: JSONLineResponseCollector,
    deadline: Date,
    timeout: TimeInterval
  ) throws {
    guard let response = responses.waitForResponse(id: id, until: deadline) else {
      if responses.hasEnded {
        throw CodexAppServerPolicyError.invalidResponse
      }
      throw CodexAppServerPolicyError.timedOut(timeout)
    }
    if let error = response["error"], id == 1 {
      throw CodexAppServerPolicyError.rejected(String(describing: error))
    }
  }

  private static func diagnostic(from data: Data) -> String {
    let text = String(decoding: data.prefix(1_024), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "app-server exited before returning policy" : text
  }
}

private final class JSONLineResponseCollector: @unchecked Sendable {
  private let condition = NSCondition()
  private var pending = Data()
  private var storedMessages: [[String: Any]] = []
  private var ended = false

  var hasEnded: Bool {
    condition.withLock { ended }
  }

  func read(from handle: FileHandle) {
    while true {
      let data = handle.availableData
      if data.isEmpty { break }
      condition.lock()
      pending.append(data)
      consumeCompleteLines()
      condition.broadcast()
      condition.unlock()
    }
    condition.lock()
    consumeTrailingLine()
    ended = true
    condition.broadcast()
    condition.unlock()
  }

  func waitForResponse(id: Int, until deadline: Date) -> [String: Any]? {
    condition.lock()
    defer { condition.unlock() }
    while true {
      if let response = storedMessages.first(where: {
        ($0["id"] as? NSNumber)?.intValue == id
      }) {
        return response
      }
      if ended || !condition.wait(until: deadline) { return nil }
    }
  }

  func messages() -> [[String: Any]] {
    condition.withLock { storedMessages }
  }

  private func consumeCompleteLines() {
    while let newline = pending.firstIndex(of: 0x0A) {
      appendMessage(Data(pending[..<newline]))
      pending.removeSubrange(...newline)
    }
  }

  private func consumeTrailingLine() {
    guard !pending.isEmpty else { return }
    appendMessage(pending)
    pending.removeAll(keepingCapacity: false)
  }

  private func appendMessage(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }
    storedMessages.append(object)
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func set(_ value: Data) {
    lock.withLock { data = value }
  }

  func value() -> Data {
    lock.withLock { data }
  }
}

enum CodexAppServerPolicyError: Error, CustomStringConvertible {
  case executableUnavailable
  case timedOut(TimeInterval)
  case rejected(String)
  case invalidResponse

  var description: String {
    switch self {
    case .executableUnavailable:
      return "Codex app-server executable is unavailable"
    case .timedOut(let timeout):
      return "timed out after \(Int(timeout)) seconds waiting for policy from Codex app-server"
    case .rejected(let message):
      return "Codex app-server rejected config/read: \(message)"
    case .invalidResponse:
      return "Codex app-server returned an invalid policy response"
    }
  }
}

enum CodexAppServerPolicyResponseParser {
  static func parse(_ messages: [[String: Any]]) throws -> ComputerUseOrganizationPolicy {
    var policy = ComputerUseOrganizationPolicy()
    var sawValidResponse = false

    if let response = response(id: 2, in: messages),
      let result = response["result"] as? [String: Any],
      let config = result["config"] as? [String: Any]
    {
      sawValidResponse = true
      if let computerUse = config["computer_use"] as? [String: Any] {
        applyModernComputerUse(computerUse, to: &policy)
        applyLegacyComputerUse(computerUse, to: &policy)
      }
    }

    if let response = response(id: 3, in: messages),
      let result = response["result"] as? [String: Any]
    {
      sawValidResponse = true
      if let requirements = result["requirements"] as? [String: Any],
        let computerUse = requirements["computerUse"] as? [String: Any]
      {
        applyRequirements(computerUse, to: &policy)
      }
    }

    guard sawValidResponse else { throw CodexAppServerPolicyError.invalidResponse }
    return policy
  }

  private static func response(id: Int, in messages: [[String: Any]]) -> [String: Any]? {
    messages.first { ($0["id"] as? NSNumber)?.intValue == id }
  }

  private static func applyLegacyComputerUse(
    _ computerUse: [String: Any],
    to policy: inout ComputerUseOrganizationPolicy
  ) {
    if let value = computerUse["allow_persistent_approval"] as? Bool {
      policy.allowPersistentApproval = value
    }
    guard let macos = computerUse["macos"] as? [String: Any] else { return }
    if let denied = stringSet(macos["denied_bundle_ids"]) {
      policy.deniedBundleIdentifiers = denied
    }
    if macos.keys.contains("allowed_bundle_ids") {
      policy.allowedBundleIdentifiers = stringSet(macos["allowed_bundle_ids"])
    }
  }

  private static func applyModernComputerUse(
    _ computerUse: [String: Any],
    to policy: inout ComputerUseOrganizationPolicy
  ) {
    applyBundleRules(
      defaultAccess: computerUse["default_app_access"] as? String,
      macos: computerUse["macos"] as? [String: Any],
      bundleRulesKey: "bundle_ids",
      to: &policy
    )
  }

  private static func applyRequirements(
    _ computerUse: [String: Any],
    to policy: inout ComputerUseOrganizationPolicy
  ) {
    if let value = computerUse["allowPersistentApproval"] as? Bool {
      policy.allowPersistentApproval = value
    }
    applyBundleRules(
      defaultAccess: computerUse["defaultAppAccess"] as? String,
      macos: computerUse["macos"] as? [String: Any],
      bundleRulesKey: "bundleIds",
      to: &policy
    )
  }

  private static func applyBundleRules(
    defaultAccess: String?,
    macos: [String: Any]?,
    bundleRulesKey: String,
    to policy: inout ComputerUseOrganizationPolicy
  ) {
    let rules = macos?[bundleRulesKey] as? [String: String]
    if let rules {
      policy.deniedBundleIdentifiers.formUnion(
        rules.compactMap { $0.value == "deny" ? $0.key : nil }
      )
    }
    if defaultAccess == "deny" {
      policy.allowedBundleIdentifiers = Set(
        rules?.compactMap { $0.value == "allow" ? $0.key : nil } ?? []
      )
    } else if defaultAccess == "allow" {
      policy.allowedBundleIdentifiers = nil
    }
  }

  private static func stringSet(_ value: Any?) -> Set<String>? {
    if value is NSNull { return nil }
    guard let strings = value as? [String] else { return nil }
    return Set(strings)
  }
}
