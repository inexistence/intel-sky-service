import Darwin
import Foundation

public struct ComputerUseCapabilityRegistration: Codable, Equatable, Sendable {
  public let registered: Bool
  public let skillInjected: Bool
  public let skillPath: String
  public let nodeReplPath: String
  public let skyModulePath: String
  public let diagnostic: String?

  public init(
    registered: Bool,
    skillInjected: Bool,
    skillPath: String,
    nodeReplPath: String,
    skyModulePath: String,
    diagnostic: String? = nil
  ) {
    self.registered = registered
    self.skillInjected = skillInjected
    self.skillPath = skillPath
    self.nodeReplPath = nodeReplPath
    self.skyModulePath = skyModulePath
    self.diagnostic = diagnostic
  }
}

public struct ComputerUseCapabilityPaths: Sendable {
  public let codexHome: String
  public let agentsHome: String
  public let codexExecutable: String
  public let nodeReplExecutable: String
  public let nodeExecutable: String
  public let nodeModulesDirectory: String
  public let officialSkillDirectory: String

  public init(
    codexHome: String,
    agentsHome: String,
    codexExecutable: String,
    nodeReplExecutable: String,
    nodeExecutable: String,
    nodeModulesDirectory: String,
    officialSkillDirectory: String
  ) {
    self.codexHome = codexHome
    self.agentsHome = agentsHome
    self.codexExecutable = codexExecutable
    self.nodeReplExecutable = nodeReplExecutable
    self.nodeExecutable = nodeExecutable
    self.nodeModulesDirectory = nodeModulesDirectory
    self.officialSkillDirectory = officialSkillDirectory
  }

  public static func installed(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let home = environment["HOME"] ?? NSHomeDirectory()
    let codexHome = environment["CODEX_HOME"] ?? "\(home)/.codex"
    let resources = "/Applications/ChatGPT.app/Contents/Resources"
    let modules = "\(resources)/cua_node/lib/node_modules"
    return Self(
      codexHome: codexHome,
      agentsHome: "\(home)/.agents",
      codexExecutable: "\(resources)/codex",
      nodeReplExecutable: "\(resources)/cua_node/bin/node_repl",
      nodeExecutable: "\(resources)/cua_node/bin/node",
      nodeModulesDirectory: modules,
      officialSkillDirectory:
        "\(modules)/@oai/sky/docs/skills/oai_sky_lib/macos"
    )
  }
}

public struct CapabilityCommandResult: Sendable {
  public let exitCode: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public struct ComputerUseCapabilityRegistrar {
  public typealias CommandRunner = @Sendable (
    _ executable: String, _ arguments: [String], _ environment: [String: String]
  ) -> CapabilityCommandResult

  private let paths: ComputerUseCapabilityPaths
  private let commandRunner: CommandRunner
  private let fileManager: FileManager

  public init(
    paths: ComputerUseCapabilityPaths = .installed(),
    fileManager: FileManager = .default
  ) {
    self.paths = paths
    self.fileManager = fileManager
    self.commandRunner = Self.runCommand
  }

  public init(
    paths: ComputerUseCapabilityPaths,
    fileManager: FileManager = .default,
    commandRunner: @escaping CommandRunner
  ) {
    self.paths = paths
    self.fileManager = fileManager
    self.commandRunner = commandRunner
  }

  public func register() -> ComputerUseCapabilityRegistration {
    configure(injectOfficialSkill: true)
  }

  public func prepareRuntime() -> ComputerUseCapabilityRegistration {
    configure(injectOfficialSkill: false)
  }

  private func configure(injectOfficialSkill: Bool) -> ComputerUseCapabilityRegistration {
    let skillDestination = "\(paths.agentsHome)/skills/computer-use"
    let skyModule = "\(paths.nodeModulesDirectory)/@oai/sky"
    do {
      try requireExecutable(paths.codexExecutable, label: "Codex CLI")
      try requireExecutable(paths.nodeReplExecutable, label: "node_repl")
      try requireExecutable(paths.nodeExecutable, label: "bundled Node.js")
      try requireRegularFile(
        "\(paths.officialSkillDirectory)/SKILL.md",
        label: "official Computer Use skill"
      )
      try requireRegularFile("\(skyModule)/package.json", label: "@oai/sky")
      try fileManager.createDirectory(
        atPath: paths.codexHome,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      if injectOfficialSkill {
        try validateOfficialSkillDestination(at: skillDestination)
      }
      try ensureNodeReplConfiguration()
      if injectOfficialSkill {
        try installOfficialSkillLink(at: skillDestination)
      }
      return ComputerUseCapabilityRegistration(
        registered: true,
        skillInjected: injectOfficialSkill,
        skillPath: skillDestination,
        nodeReplPath: paths.nodeReplExecutable,
        skyModulePath: skyModule
      )
    } catch {
      return ComputerUseCapabilityRegistration(
        registered: false,
        skillInjected: false,
        skillPath: skillDestination,
        nodeReplPath: paths.nodeReplExecutable,
        skyModulePath: skyModule,
        diagnostic: String(describing: error)
      )
    }
  }

  private func requireExecutable(_ path: String, label: String) throws {
    guard fileManager.isExecutableFile(atPath: path) else {
      throw CapabilityRegistrationError.missing("\(label) is unavailable at \(path)")
    }
  }

  private func requireRegularFile(_ path: String, label: String) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
      throw CapabilityRegistrationError.missing("\(label) is unavailable at \(path)")
    }
  }

  private func installOfficialSkillLink(at destination: String) throws {
    let skillsDirectory = URL(fileURLWithPath: destination).deletingLastPathComponent().path
    try fileManager.createDirectory(
      atPath: skillsDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var metadata = stat()
    if lstat(destination, &metadata) == 0 {
      try validateOfficialSkillDestination(at: destination)
      return
    }
    guard errno == ENOENT else {
      throw CapabilityRegistrationError.filesystem(
        "could not inspect Computer Use skill destination \(destination): \(String(cString: strerror(errno)))"
      )
    }
    try fileManager.createSymbolicLink(
      atPath: destination,
      withDestinationPath: paths.officialSkillDirectory
    )
  }

  private func validateOfficialSkillDestination(at destination: String) throws {
    var metadata = stat()
    guard lstat(destination, &metadata) == 0 else {
      if errno == ENOENT { return }
      throw CapabilityRegistrationError.filesystem(
        "could not inspect Computer Use skill destination \(destination): \(String(cString: strerror(errno)))"
      )
    }
    guard (metadata.st_mode & S_IFMT) == S_IFLNK else {
      throw CapabilityRegistrationError.conflict(
        "Computer Use skill destination already exists and was not changed: \(destination)"
      )
    }
    let existingTarget = try fileManager.destinationOfSymbolicLink(atPath: destination)
    guard existingTarget == paths.officialSkillDirectory else {
      throw CapabilityRegistrationError.conflict(
        "Computer Use skill link points to \(existingTarget), expected \(paths.officialSkillDirectory)"
      )
    }
  }

  private func ensureNodeReplConfiguration() throws {
    let environment = ["CODEX_HOME": paths.codexHome, "HOME": NSHomeDirectory()]
    var result = commandRunner(
      paths.codexExecutable,
      ["mcp", "get", "node_repl", "--json"],
      environment
    )
    if result.exitCode != 0 {
      let trustedServices = #"{"sky":"@oai/sky/service"}"#
      let trustedPaths = "\(paths.codexHome):\(paths.nodeModulesDirectory)"
      result = commandRunner(
        paths.codexExecutable,
        [
          "mcp", "add", "node_repl",
          "--env", "NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS=1000",
          "--env", "NODE_REPL_NODE_MODULE_DIRS=\(paths.nodeModulesDirectory)",
          "--env", "NODE_REPL_NODE_PATH=\(paths.nodeExecutable)",
          "--env", "NODE_REPL_TRUSTED_CODE_PATHS=\(trustedPaths)",
          "--env", "CODEX_HOME=\(paths.codexHome)",
          "--env",
          "NODE_REPL_INSTRUCTIONS_USE_CASE_COMPUTER_USE=Control desktop apps on macOS through Computer Use.",
          "--env", "NODE_REPL_TRUSTED_SERVICES=\(trustedServices)",
          "--", paths.nodeReplExecutable,
        ],
        environment
      )
      guard result.exitCode == 0 else {
        throw CapabilityRegistrationError.commandFailure(
          "could not register node_repl: \(diagnosticText(from: result))"
        )
      }
      result = commandRunner(
        paths.codexExecutable,
        ["mcp", "get", "node_repl", "--json"],
        environment
      )
    }
    guard result.exitCode == 0, nodeReplConfigurationIsCompatible(result.standardOutput) else {
      throw CapabilityRegistrationError.conflict(
        "the existing node_repl configuration does not expose the bundled @oai/sky runtime; it was not overwritten"
      )
    }
  }

  private func nodeReplConfigurationIsCompatible(_ data: Data) -> Bool {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let transport = object["transport"] as? [String: Any],
      transport["command"] as? String == paths.nodeReplExecutable,
      let environment = transport["env"] as? [String: Any],
      environment["NODE_REPL_NODE_PATH"] as? String == paths.nodeExecutable,
      environment["NODE_REPL_NODE_MODULE_DIRS"] as? String == paths.nodeModulesDirectory,
      let trustedServices = environment["NODE_REPL_TRUSTED_SERVICES"] as? String,
      let trustedData = trustedServices.data(using: .utf8),
      let services = try? JSONSerialization.jsonObject(with: trustedData) as? [String: Any],
      services["sky"] as? String == "@oai/sky/service"
    else { return false }
    return true
  }

  private func diagnosticText(from result: CapabilityCommandResult) -> String {
    let data = result.standardError.isEmpty ? result.standardOutput : result.standardError
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "Codex CLI exited with status \(result.exitCode)" : text
  }

  private static func runCommand(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) -> CapabilityCommandResult {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
      process.waitUntilExit()
      return CapabilityCommandResult(
        exitCode: process.terminationStatus,
        standardOutput: output.fileHandleForReading.readDataToEndOfFile(),
        standardError: error.fileHandleForReading.readDataToEndOfFile()
      )
    } catch {
      return CapabilityCommandResult(
        exitCode: 127,
        standardError: Data(String(describing: error).utf8)
      )
    }
  }
}

private enum CapabilityRegistrationError: Error, CustomStringConvertible {
  case missing(String)
  case conflict(String)
  case filesystem(String)
  case commandFailure(String)

  var description: String {
    switch self {
    case .missing(let message), .conflict(let message), .filesystem(let message),
      .commandFailure(let message):
      return message
    }
  }
}
