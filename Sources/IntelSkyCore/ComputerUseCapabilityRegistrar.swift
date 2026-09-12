import Darwin
import Foundation

public struct ComputerUseCapabilityRegistration: Codable, Equatable, Sendable {
  public let registered: Bool
  public let skillInjected: Bool
  public let unifiedComputerUseEnabled: Bool
  public let skillPath: String
  public let nodeReplPath: String
  public let skyModulePath: String
  public let diagnostic: String?

  public init(
    registered: Bool,
    skillInjected: Bool,
    unifiedComputerUseEnabled: Bool = false,
    skillPath: String,
    nodeReplPath: String,
    skyModulePath: String,
    diagnostic: String? = nil
  ) {
    self.registered = registered
    self.skillInjected = skillInjected
    self.unifiedComputerUseEnabled = unifiedComputerUseEnabled
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
  public let singleEntryPluginID: String?

  public init(
    codexHome: String,
    agentsHome: String,
    codexExecutable: String,
    nodeReplExecutable: String,
    nodeExecutable: String,
    nodeModulesDirectory: String,
    officialSkillDirectory: String,
    singleEntryPluginID: String? = nil
  ) {
    self.codexHome = codexHome
    self.agentsHome = agentsHome
    self.codexExecutable = codexExecutable
    self.nodeReplExecutable = nodeReplExecutable
    self.nodeExecutable = nodeExecutable
    self.nodeModulesDirectory = nodeModulesDirectory
    self.officialSkillDirectory = officialSkillDirectory
    self.singleEntryPluginID = singleEntryPluginID
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
        "\(modules)/@oai/sky/docs/skills/oai_sky_lib/macos",
      singleEntryPluginID: "intel-sky-computer-use@personal"
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
      try requireRegularFile("\(skyModule)/package.json", label: "@oai/sky")
      try fileManager.createDirectory(
        atPath: paths.codexHome,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      if injectOfficialSkill, paths.singleEntryPluginID == nil {
        try validateOfficialSkillDestination(at: skillDestination)
      }
      let unifiedComputerUseEnabled = try ensureSingleEntryPluginConfiguration()
      if !unifiedComputerUseEnabled {
        try requireRegularFile(
          "\(paths.officialSkillDirectory)/SKILL.md",
          label: "official Computer Use skill"
        )
        try ensureNodeReplConfiguration()
      }
      if injectOfficialSkill {
        if unifiedComputerUseEnabled {
          try removeManagedOfficialSkillLink(at: skillDestination)
        } else {
          try installOfficialSkillLink(at: skillDestination)
        }
      }
      return ComputerUseCapabilityRegistration(
        registered: true,
        skillInjected: injectOfficialSkill && !unifiedComputerUseEnabled,
        unifiedComputerUseEnabled: unifiedComputerUseEnabled,
        skillPath: skillDestination,
        nodeReplPath: paths.nodeReplExecutable,
        skyModulePath: skyModule
      )
    } catch {
      return ComputerUseCapabilityRegistration(
        registered: false,
        skillInjected: false,
        unifiedComputerUseEnabled: false,
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

  private func removeManagedOfficialSkillLink(at destination: String) throws {
    var metadata = stat()
    guard lstat(destination, &metadata) == 0 else {
      if errno == ENOENT { return }
      throw CapabilityRegistrationError.filesystem(
        "could not inspect Computer Use skill destination \(destination): \(String(cString: strerror(errno)))"
      )
    }
    guard (metadata.st_mode & S_IFMT) == S_IFLNK else { return }
    guard
      try fileManager.destinationOfSymbolicLink(atPath: destination)
        == paths.officialSkillDirectory
    else { return }
    try fileManager.removeItem(atPath: destination)
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
    guard result.exitCode == 0 else {
      throw CapabilityRegistrationError.commandFailure(
        "could not inspect node_repl after registration: \(diagnosticText(from: result))"
      )
    }
    if nodeReplConfigurationIsCompatible(result.standardOutput) { return }

    guard let trustedServices = mergeableTrustedServices(from: result.standardOutput) else {
      throw CapabilityRegistrationError.conflict(
        "the existing node_repl configuration is incompatible with the bundled runtime; it was not changed"
      )
    }
    try mergeNodeReplEnvironment(trustedServices: trustedServices)

    result = commandRunner(
      paths.codexExecutable,
      ["mcp", "get", "node_repl", "--json"],
      environment
    )
    guard result.exitCode == 0, nodeReplConfigurationIsCompatible(result.standardOutput) else {
      throw CapabilityRegistrationError.commandFailure(
        "node_repl configuration was updated but Codex did not expose the bundled @oai/sky runtime"
      )
    }
  }

  private func mergeableTrustedServices(from data: Data) -> [String: String]? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let transport = object["transport"] as? [String: Any],
      transport["type"] as? String == "stdio",
      transport["command"] as? String == paths.nodeReplExecutable,
      let environment = transport["env"] as? [String: Any],
      environment["NODE_REPL_NODE_PATH"] as? String == paths.nodeExecutable,
      environment["NODE_REPL_NODE_MODULE_DIRS"] as? String == paths.nodeModulesDirectory,
      let trustedServices = environment["NODE_REPL_TRUSTED_SERVICES"] as? String,
      let trustedData = trustedServices.data(using: .utf8),
      var services = try? JSONSerialization.jsonObject(with: trustedData) as? [String: String]
    else { return nil }
    services["sky"] = "@oai/sky/service"
    return services
  }

  private func mergeNodeReplEnvironment(trustedServices: [String: String]) throws {
    let configPath = "\(paths.codexHome)/config.toml"
    var metadata = stat()
    guard
      lstat(configPath, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid()
    else {
      throw CapabilityRegistrationError.conflict(
        "Codex configuration is not a user-owned regular file and was not changed: \(configPath)"
      )
    }
    let originalData: Data
    do {
      originalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
    } catch {
      throw CapabilityRegistrationError.filesystem(
        "could not read Codex configuration at \(configPath): \(error)"
      )
    }
    guard var text = String(data: originalData, encoding: .utf8) else {
      throw CapabilityRegistrationError.conflict(
        "Codex configuration is not valid UTF-8 and was not changed: \(configPath)"
      )
    }
    let servicesData: Data
    do {
      servicesData = try JSONSerialization.data(
        withJSONObject: trustedServices,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw CapabilityRegistrationError.conflict(
        "could not encode merged node_repl trusted services: \(error)"
      )
    }
    let assignments = [
      "NODE_REPL_INSTRUCTIONS_USE_CASE_COMPUTER_USE":
        "Control desktop apps on macOS through Computer Use.",
      "NODE_REPL_TRUSTED_SERVICES": String(decoding: servicesData, as: UTF8.self),
    ]
    guard let updated = updatingTomlTable(
      "mcp_servers.node_repl.env",
      assignments: assignments,
      in: text
    ) else {
      throw CapabilityRegistrationError.conflict(
        "Codex node_repl environment table was not found and was not changed: \(configPath)"
      )
    }
    text = updated
    let attributes = try? fileManager.attributesOfItem(atPath: configPath)
    do {
      guard try Data(contentsOf: URL(fileURLWithPath: configPath)) == originalData else {
        throw CapabilityRegistrationError.conflict(
          "Codex configuration changed during capability registration; retry without overwriting concurrent changes"
        )
      }
      try Data(text.utf8).write(to: URL(fileURLWithPath: configPath), options: .atomic)
      if let permissions = attributes?[.posixPermissions] {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configPath)
      }
    } catch {
      throw CapabilityRegistrationError.filesystem(
        "could not update Codex configuration at \(configPath): \(error)"
      )
    }
  }

  private func ensureSingleEntryPluginConfiguration() throws -> Bool {
    guard let pluginID = paths.singleEntryPluginID else { return false }
    let environment = ["CODEX_HOME": paths.codexHome, "HOME": NSHomeDirectory()]
    let legacyName = "intel_sky_repl"
    var result = commandRunner(
      paths.codexExecutable,
      ["mcp", "get", legacyName, "--json"],
      environment
    )
    if result.exitCode == 0 {
      guard legacyCuaReplConfigurationIsCompatible(result.standardOutput) else {
        throw CapabilityRegistrationError.conflict(
          "the existing \(legacyName) server is not managed by Intel Sky and was not removed"
        )
      }
      result = commandRunner(
        paths.codexExecutable,
        ["mcp", "remove", legacyName],
        environment
      )
      guard result.exitCode == 0 else {
        throw CapabilityRegistrationError.commandFailure(
          "could not remove legacy \(legacyName): \(diagnosticText(from: result))"
        )
      }
    }

    result = commandRunner(
      paths.codexExecutable,
      ["plugin", "list", "--json"],
      environment
    )
    guard result.exitCode == 0, pluginSelectionIsCompatible(result.standardOutput, pluginID: pluginID)
    else {
      throw CapabilityRegistrationError.commandFailure(
        "Codex did not expose exactly one enabled Computer Use plugin"
      )
    }
    result = commandRunner(
      paths.codexExecutable,
      ["mcp", "get", "intel_sky_cua", "--json"],
      environment
    )
    guard result.exitCode == 0, singleEntryCuaReplConfigurationIsCompatible(result.standardOutput)
    else {
      throw CapabilityRegistrationError.commandFailure(
        "Codex did not expose the intel_sky_cua browser and native App server"
      )
    }
    return true
  }

  private func pluginSelectionIsCompatible(_ data: Data, pluginID: String) -> Bool {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let installed = root["installed"] as? [[String: Any]]
    else { return false }
    let selected = installed.first { $0["pluginId"] as? String == pluginID }
    let bundled = installed.first {
      $0["pluginId"] as? String == "unified-computer-use@openai-bundled"
    }
    return selected?["enabled"] as? Bool == true && bundled?["enabled"] as? Bool == false
  }

  private func legacyCuaReplConfigurationIsCompatible(_ data: Data) -> Bool {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let transport = object["transport"] as? [String: Any],
      transport["type"] as? String == "stdio",
      transport["command"] as? String == paths.nodeExecutable,
      transport["args"] as? [String]
        == ["\(paths.nodeModulesDirectory)/@oai/cua-repl/bin/cua-repl.mjs"],
      let environment = transport["env"] as? [String: Any],
      environment["CUA_REPL_ENABLED_SURFACES"] as? String == "computer",
      environment["CUA_REPL_NODE_REPL_PATH"] as? String == paths.nodeReplExecutable,
      environment["NODE_REPL_NODE_MODULE_DIRS"] as? String == paths.nodeModulesDirectory,
      let trustedText = environment["NODE_REPL_TRUSTED_SERVICES"] as? String,
      let trustedData = trustedText.data(using: .utf8),
      let trustedServices = try? JSONSerialization.jsonObject(with: trustedData)
        as? [String: String],
      trustedServices["sky"] == "@oai/sky/service"
    else { return false }
    return true
  }

  private func writeConfiguration(
    _ updatedData: Data,
    replacing originalData: Data,
    at path: String,
    label: String
  ) throws {
    let attributes = try? fileManager.attributesOfItem(atPath: path)
    do {
      guard try Data(contentsOf: URL(fileURLWithPath: path)) == originalData else {
        throw CapabilityRegistrationError.conflict(
          "\(label) changed during capability registration; retry without overwriting concurrent changes"
        )
      }
      try updatedData.write(to: URL(fileURLWithPath: path), options: .atomic)
      if let permissions = attributes?[.posixPermissions] {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
      }
    } catch {
      throw CapabilityRegistrationError.filesystem("could not update \(label) at \(path): \(error)")
    }
  }

  private func updatingTomlTable(
    _ table: String,
    assignments: [String: String],
    in text: String
  ) -> String? {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let tableIndex = lines.firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces) == "[\(table)]"
    })
    else { return nil }
    let endIndex = lines[(tableIndex + 1)...].firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }) ?? lines.endIndex

    for key in assignments.keys.sorted() {
      let replacement = "\(key) = \(tomlBasicString(assignments[key]!))"
      let matches = lines[(tableIndex + 1)..<endIndex].indices.filter {
        let line = lines[$0].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(key) else { return false }
        return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
      }
      guard matches.count <= 1 else { return nil }
      if let index = matches.first {
        lines[index] = replacement
      } else {
        lines.insert(replacement, at: endIndex)
      }
    }
    return lines.joined(separator: "\n")
  }

  private func tomlBasicString(_ value: String) -> String {
    var encoded = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x08: encoded += "\\b"
      case 0x09: encoded += "\\t"
      case 0x0A: encoded += "\\n"
      case 0x0C: encoded += "\\f"
      case 0x0D: encoded += "\\r"
      case 0x22: encoded += "\\\""
      case 0x5C: encoded += "\\\\"
      case 0x00...0x1F, 0x7F:
        encoded += String(format: "\\u%04X", scalar.value)
      default: encoded.unicodeScalars.append(scalar)
      }
    }
    return encoded + "\""
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

  private func singleEntryCuaReplConfigurationIsCompatible(_ data: Data) -> Bool {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["enabled"] as? Bool == true,
      let transport = object["transport"] as? [String: Any],
      transport["type"] as? String == "stdio",
      transport["command"] as? String == "./scripts/cua-repl-launcher",
      transport["args"] as? [String] == [],
      let workingDirectory = transport["cwd"] as? String,
      workingDirectory.hasPrefix(
        "\(paths.codexHome)/plugins/cache/personal/intel-sky-computer-use/"
      )
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
