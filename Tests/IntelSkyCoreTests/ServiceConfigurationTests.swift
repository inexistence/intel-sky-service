import Foundation
import Testing

@testable import IntelSkyCore

@Test func noArgumentsUseOfficialGroupContainerSocketPath() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: [],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
    environment: [:]
  )

  #expect(
    configuration.socketPath
      == "/Users/example/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock"
  )
  #expect(!configuration.experimentalPIPEnabled)
}

@Test func explicitAbsoluteSocketOverridesDefault() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: ["--socket", "/tmp/intel-sky/computeruse.sock"],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
    environment: [:]
  )

  #expect(configuration.socketPath == "/tmp/intel-sky/computeruse.sock")
  #expect(!configuration.experimentalPIPEnabled)
}

@Test func experimentalPIPCanBeEnabledByManagedServiceEnvironment() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: [],
    environment: [SkyServiceConfiguration.experimentalPIPEnvironmentVariable: " 1\n"]
  )

  #expect(configuration.experimentalPIPEnabled)
}

@Test func experimentalPIPFlagCanBeCombinedWithSocketInEitherOrder() throws {
  let first = try SkyServiceConfiguration(
    arguments: ["--experimental-pip", "--socket", "/tmp/first.sock"]
  )
  let second = try SkyServiceConfiguration(
    arguments: ["--socket", "/tmp/second.sock", "--experimental-pip"]
  )

  #expect(first.experimentalPIPEnabled)
  #expect(first.socketPath == "/tmp/first.sock")
  #expect(second.experimentalPIPEnabled)
  #expect(second.socketPath == "/tmp/second.sock")
}

@Test func invalidArgumentsAndRelativeSocketAreRejected() {
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["unexpected"])
  }
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["--socket", "relative.sock"])
  }
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["--experimental-pip", "--experimental-pip"])
  }
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["--socket"])
  }
}
