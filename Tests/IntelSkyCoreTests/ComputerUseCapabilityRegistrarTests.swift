import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func capabilityRegistrarLinksOfficialSkillAndAcceptsCompatibleNodeRepl() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let output = fixture.compatibleNodeReplJSON()
  let registrar = ComputerUseCapabilityRegistrar(paths: fixture.paths) { _, arguments, _ in
    #expect(arguments == ["mcp", "get", "node_repl", "--json"])
    return CapabilityCommandResult(exitCode: 0, standardOutput: output)
  }

  let result = registrar.register()

  #expect(result.registered)
  #expect(result.skillInjected)
  #expect(result.diagnostic == nil)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: result.skillPath)
      == fixture.paths.officialSkillDirectory
  )
}

@Test func capabilityPreparationLeavesOfficialSkillHealthGated() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let output = fixture.compatibleNodeReplJSON()
  let registrar = ComputerUseCapabilityRegistrar(paths: fixture.paths) { _, _, _ in
    CapabilityCommandResult(exitCode: 0, standardOutput: output)
  }

  let result = registrar.prepareRuntime()

  #expect(result.registered)
  #expect(!result.skillInjected)
  #expect(!FileManager.default.fileExists(atPath: result.skillPath))
}

@Test func capabilityRegistrarAddsMissingNodeReplWithoutOverwritingExistingEntries() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let calls = CapabilityCommandLog()
  let output = fixture.compatibleNodeReplJSON()
  let registrar = ComputerUseCapabilityRegistrar(paths: fixture.paths) { _, arguments, _ in
    let call = calls.append(arguments)
    if call == 1 { return CapabilityCommandResult(exitCode: 1) }
    if call == 2 {
      #expect(arguments.prefix(3) == ["mcp", "add", "node_repl"])
      #expect(arguments.contains("NODE_REPL_TRUSTED_SERVICES={\"sky\":\"@oai/sky/service\"}"))
      return CapabilityCommandResult(exitCode: 0)
    }
    return CapabilityCommandResult(exitCode: 0, standardOutput: output)
  }

  let result = registrar.register()

  #expect(result.registered)
  #expect(result.skillInjected)
  #expect(calls.count == 3)
  #expect(FileManager.default.fileExists(atPath: fixture.paths.codexHome))
}

@Test func capabilityRegistrarMergesSkyIntoExistingBrowserNodeRepl() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let configPath = "\(fixture.paths.codexHome)/config.toml"
  try FileManager.default.createDirectory(
    atPath: fixture.paths.codexHome,
    withIntermediateDirectories: true
  )
  try Data(
    """
    model = "keep-me"

    [mcp_servers.node_repl]
    args = []
    command = "\(fixture.paths.nodeReplExecutable)"
    startup_timeout_sec = 120

    [mcp_servers.node_repl.env]
    NODE_REPL_NODE_MODULE_DIRS = "\(fixture.paths.nodeModulesDirectory)"
    NODE_REPL_NODE_PATH = "\(fixture.paths.nodeExecutable)"
    NODE_REPL_TRUSTED_SERVICES = '{"browser":"/existing/browser-service.mjs"}'
    BROWSER_USE_AVAILABLE_BACKENDS = "chrome,iab"

    [mcp_servers.other]
    command = "/keep/other"
    """.utf8
  ).write(to: URL(fileURLWithPath: configPath))

  let calls = CapabilityCommandLog()
  let registrar = ComputerUseCapabilityRegistrar(paths: fixture.paths) { _, arguments, _ in
    #expect(arguments == ["mcp", "get", "node_repl", "--json"])
    let call = calls.append(arguments)
    return CapabilityCommandResult(
      exitCode: 0,
      standardOutput: call == 1
        ? fixture.browserOnlyNodeReplJSON()
        : fixture.compatibleNodeReplJSON(browserService: "/existing/browser-service.mjs")
    )
  }

  let result = registrar.register()

  #expect(result.registered)
  #expect(calls.count == 2)
  let updated = try String(contentsOfFile: configPath, encoding: .utf8)
  #expect(updated.contains("model = \"keep-me\""))
  #expect(updated.contains("startup_timeout_sec = 120"))
  #expect(updated.contains("BROWSER_USE_AVAILABLE_BACKENDS = \"chrome,iab\""))
  #expect(updated.contains("[mcp_servers.other]"))
  #expect(updated.contains("NODE_REPL_INSTRUCTIONS_USE_CASE_COMPUTER_USE = \"Control desktop apps on macOS through Computer Use.\""))
  #expect(updated.contains("\\\"browser\\\":\\\"/existing/browser-service.mjs\\\""))
  #expect(updated.contains("\\\"sky\\\":\\\"@oai/sky/service\\\""))
}

@Test func capabilityRegistrarVerifiesSingleEntryPluginAndRemovesManagedSkillLink() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let paths = fixture.singleEntryPaths()
  let skillPath = "\(paths.agentsHome)/skills/computer-use"
  try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: skillPath).deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try FileManager.default.createSymbolicLink(
    atPath: skillPath,
    withDestinationPath: paths.officialSkillDirectory
  )
  let calls = CapabilityCommandLog()
  let registrar = ComputerUseCapabilityRegistrar(paths: paths) { _, arguments, _ in
    let call = calls.append(arguments)
    switch call {
    case 1:
      #expect(arguments == ["mcp", "get", "intel_sky_repl", "--json"])
      return CapabilityCommandResult(exitCode: 1)
    case 2:
      #expect(arguments == ["plugin", "list", "--json"])
      return CapabilityCommandResult(
        exitCode: 0,
        standardOutput: fixture.compatiblePluginListJSON()
      )
    default:
      #expect(arguments == ["mcp", "get", "intel_sky_cua", "--json"])
      return CapabilityCommandResult(
        exitCode: 0,
        standardOutput: fixture.compatibleSingleEntryCuaReplJSON()
      )
    }
  }

  let result = registrar.register()

  #expect(result.registered)
  #expect(result.unifiedComputerUseEnabled)
  #expect(calls.count == 3)
  #expect(!result.skillInjected)
  #expect(!FileManager.default.fileExists(atPath: skillPath))
}

@Test func capabilityRegistrarRemovesManagedLegacyCuaRepl() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let paths = fixture.singleEntryPaths()
  try FileManager.default.createDirectory(
    atPath: paths.codexHome,
    withIntermediateDirectories: true
  )
  try Data("[features]\njs_repl = false\n".utf8).write(
    to: URL(fileURLWithPath: "\(paths.codexHome)/config.toml")
  )
  let calls = CapabilityCommandLog()
  let registrar = ComputerUseCapabilityRegistrar(paths: paths) { _, arguments, _ in
    switch calls.append(arguments) {
    case 1:
      #expect(arguments == ["mcp", "get", "intel_sky_repl", "--json"])
      return CapabilityCommandResult(exitCode: 0, standardOutput: fixture.compatibleLegacyCuaReplJSON())
    case 2:
      #expect(arguments == ["mcp", "remove", "intel_sky_repl"])
      return CapabilityCommandResult(exitCode: 0)
    case 3:
      return CapabilityCommandResult(
        exitCode: 0,
        standardOutput: fixture.compatiblePluginListJSON()
      )
    default:
      return CapabilityCommandResult(
        exitCode: 0,
        standardOutput: fixture.compatibleSingleEntryCuaReplJSON()
      )
    }
  }

  let result = registrar.register()

  #expect(result.registered)
  #expect(result.unifiedComputerUseEnabled)
  #expect(calls.count == 4)
}

@Test func capabilityRegistrarPreservesUnknownCuaReplOverrideAndCustomSkill() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let paths = fixture.singleEntryPaths()
  try FileManager.default.createDirectory(atPath: paths.codexHome, withIntermediateDirectories: true)
  let configPath = "\(paths.codexHome)/config.toml"
  let original = """
    [plugins."unified-computer-use@openai-bundled"]
    enabled = false

    [plugins."intel-sky-computer-use@personal"]
    enabled = true

    [mcp_servers.cua_repl]
    command = "/custom/cua_repl"
    enabled = false
    """
  try Data(original.utf8).write(to: URL(fileURLWithPath: configPath))
  let customSkillMarker = "\(paths.agentsHome)/skills/computer-use/keep.txt"
  try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: customSkillMarker).deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  #expect(FileManager.default.createFile(atPath: customSkillMarker, contents: Data("keep".utf8)))
  let calls = CapabilityCommandLog()
  let registrar = ComputerUseCapabilityRegistrar(paths: paths) { _, arguments, _ in
    switch calls.append(arguments) {
    case 1:
      return CapabilityCommandResult(exitCode: 1)
    case 2:
      return CapabilityCommandResult(
        exitCode: 0,
        standardOutput: fixture.compatiblePluginListJSON()
      )
    default:
      return CapabilityCommandResult(
        exitCode: 0,
        standardOutput: fixture.compatibleSingleEntryCuaReplJSON()
      )
    }
  }

  let result = registrar.register()

  #expect(result.registered)
  #expect(result.unifiedComputerUseEnabled)
  #expect(calls.count == 3)
  #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
  #expect(FileManager.default.fileExists(atPath: customSkillMarker))
}

@Test func capabilityRegistrarDoesNotRewriteIncompatibleNodeRepl() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let configPath = "\(fixture.paths.codexHome)/config.toml"
  try FileManager.default.createDirectory(
    atPath: fixture.paths.codexHome,
    withIntermediateDirectories: true
  )
  let original = "[mcp_servers.node_repl]\ncommand = \"/custom/node_repl\"\n"
  try Data(original.utf8).write(to: URL(fileURLWithPath: configPath))
  let object: [String: Any] = [
    "transport": [
      "type": "stdio",
      "command": "/custom/node_repl",
      "env": [:],
    ]
  ]
  let output = try JSONSerialization.data(withJSONObject: object)
  let registrar = ComputerUseCapabilityRegistrar(paths: fixture.paths) { _, _, _ in
    CapabilityCommandResult(exitCode: 0, standardOutput: output)
  }

  let result = registrar.register()

  #expect(!result.registered)
  #expect(result.diagnostic?.contains("incompatible") == true)
  #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
}

@Test func capabilityRegistrarReportsConflictingSkillWithoutReplacingIt() throws {
  let fixture = try CapabilityFixture()
  defer { fixture.remove() }
  let destination = "\(fixture.paths.agentsHome)/skills/computer-use"
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  let marker = "\(destination)/keep.txt"
  #expect(FileManager.default.createFile(atPath: marker, contents: Data("keep".utf8)))
  let registrar = ComputerUseCapabilityRegistrar(paths: fixture.paths) { _, _, _ in
    Issue.record("Codex CLI must not run after a skill destination conflict")
    return CapabilityCommandResult(exitCode: 1)
  }

  let result = registrar.register()

  #expect(!result.registered)
  #expect(!result.skillInjected)
  #expect(result.diagnostic?.contains("already exists and was not changed") == true)
  #expect(FileManager.default.fileExists(atPath: marker))
}

private struct CapabilityFixture {
  let root: URL
  let paths: ComputerUseCapabilityPaths

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let resources = root.appendingPathComponent("ChatGPT/Contents/Resources", isDirectory: true)
    let modules = resources.appendingPathComponent("cua_node/lib/node_modules", isDirectory: true)
    let skill = modules.appendingPathComponent(
      "@oai/sky/docs/skills/oai_sky_lib/macos",
      isDirectory: true
    )
    let codex = resources.appendingPathComponent("codex").path
    let nodeRepl = resources.appendingPathComponent("cua_node/bin/node_repl").path
    let node = resources.appendingPathComponent("cua_node/bin/node").path
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: node).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("---\nname: computer-use\n---\n".utf8).write(
      to: skill.appendingPathComponent("SKILL.md")
    )
    try FileManager.default.createDirectory(
      at: modules.appendingPathComponent("@oai/sky"),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(
      to: modules.appendingPathComponent("@oai/sky/package.json")
    )
    for executable in [codex, nodeRepl, node] {
      #expect(FileManager.default.createFile(atPath: executable, contents: Data()))
      #expect(chmod(executable, 0o700) == 0)
    }
    paths = ComputerUseCapabilityPaths(
      codexHome: root.appendingPathComponent(".codex").path,
      agentsHome: root.appendingPathComponent(".agents").path,
      codexExecutable: codex,
      nodeReplExecutable: nodeRepl,
      nodeExecutable: node,
      nodeModulesDirectory: modules.path,
      officialSkillDirectory: skill.path
    )
  }

  func compatibleNodeReplJSON(browserService: String? = nil) -> Data {
    var services = ["sky": "@oai/sky/service"]
    if let browserService { services["browser"] = browserService }
    let trustedServices = String(
      decoding: try! JSONSerialization.data(withJSONObject: services, options: [.sortedKeys]),
      as: UTF8.self
    )
    let object: [String: Any] = [
      "transport": [
        "type": "stdio",
        "command": paths.nodeReplExecutable,
        "env": [
          "NODE_REPL_NODE_PATH": paths.nodeExecutable,
          "NODE_REPL_NODE_MODULE_DIRS": paths.nodeModulesDirectory,
          "NODE_REPL_TRUSTED_SERVICES": trustedServices,
        ],
      ]
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  func browserOnlyNodeReplJSON() -> Data {
    let object: [String: Any] = [
      "transport": [
        "type": "stdio",
        "command": paths.nodeReplExecutable,
        "args": [],
        "env": [
          "NODE_REPL_NODE_PATH": paths.nodeExecutable,
          "NODE_REPL_NODE_MODULE_DIRS": paths.nodeModulesDirectory,
          "NODE_REPL_TRUSTED_SERVICES":
            "{\"browser\":\"/existing/browser-service.mjs\"}",
        ],
      ]
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  func singleEntryPaths() -> ComputerUseCapabilityPaths {
    ComputerUseCapabilityPaths(
      codexHome: paths.codexHome,
      agentsHome: paths.agentsHome,
      codexExecutable: paths.codexExecutable,
      nodeReplExecutable: paths.nodeReplExecutable,
      nodeExecutable: paths.nodeExecutable,
      nodeModulesDirectory: paths.nodeModulesDirectory,
      officialSkillDirectory: paths.officialSkillDirectory,
      singleEntryPluginID: "intel-sky-computer-use@personal"
    )
  }

  func compatibleLegacyCuaReplJSON() -> Data {
    let object: [String: Any] = [
      "transport": [
        "type": "stdio",
        "command": paths.nodeExecutable,
        "args": ["\(paths.nodeModulesDirectory)/@oai/cua-repl/bin/cua-repl.mjs"],
        "env": [
          "CUA_REPL_ENABLED_SURFACES": "computer",
          "CUA_REPL_NODE_REPL_PATH": paths.nodeReplExecutable,
          "NODE_REPL_NODE_MODULE_DIRS": paths.nodeModulesDirectory,
          "NODE_REPL_TRUSTED_SERVICES": "{\"sky\":\"@oai/sky/service\"}",
        ],
      ]
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  func compatibleSingleEntryCuaReplJSON() -> Data {
    let object: [String: Any] = [
      "name": "intel_sky_cua",
      "enabled": true,
      "transport": [
        "type": "stdio",
        "command": "./scripts/cua-repl-launcher",
        "args": [],
        "cwd": "\(paths.codexHome)/plugins/cache/personal/intel-sky-computer-use/0.1.0",
      ],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  func compatiblePluginListJSON() -> Data {
    let object: [String: Any] = [
      "installed": [
        [
          "pluginId": "unified-computer-use@openai-bundled",
          "enabled": false,
        ],
        [
          "pluginId": "intel-sky-computer-use@personal",
          "enabled": true,
        ],
      ]
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private final class CapabilityCommandLog: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [[String]] = []

  var count: Int {
    lock.withLock { calls.count }
  }

  @discardableResult
  func append(_ arguments: [String]) -> Int {
    lock.withLock {
      calls.append(arguments)
      return calls.count
    }
  }
}
