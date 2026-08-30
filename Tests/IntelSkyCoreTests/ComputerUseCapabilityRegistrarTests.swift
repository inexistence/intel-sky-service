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

  func compatibleNodeReplJSON() -> Data {
    let trustedServices = "{\"sky\":\"@oai/sky/service\"}"
    let object: [String: Any] = [
      "transport": [
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
