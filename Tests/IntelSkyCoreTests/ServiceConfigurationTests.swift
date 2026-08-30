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
  #expect(configuration.remoteHostedPIPEnabled)
}

@Test func explicitAbsoluteSocketOverridesDefault() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: ["--socket", "/tmp/intel-sky/computeruse.sock"],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
    environment: [:]
  )

  #expect(configuration.socketPath == "/tmp/intel-sky/computeruse.sock")
  #expect(configuration.remoteHostedPIPEnabled)
}

@Test func managedServiceLaunchEnablesAuthenticatedRemoteHostedPIPByDefault() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: [],
    environment: ["INTEL_SKY_EXPERIMENTAL_PIP": "1"]
  )

  #expect(configuration.remoteHostedPIPEnabled)
}

@Test func experimentalPIPFlagCanBeCombinedWithSocketInEitherOrder() throws {
  let first = try SkyServiceConfiguration(
    arguments: ["--experimental-pip", "--socket", "/tmp/first.sock"]
  )
  let second = try SkyServiceConfiguration(
    arguments: ["--socket", "/tmp/second.sock", "--experimental-pip"]
  )

  #expect(first.remoteHostedPIPEnabled)
  #expect(first.socketPath == "/tmp/first.sock")
  #expect(second.remoteHostedPIPEnabled)
  #expect(second.socketPath == "/tmp/second.sock")
}

@Test func remoteHostedPIPHasExplicitRollbackSwitch() throws {
  let configuration = try SkyServiceConfiguration(arguments: ["--disable-pip"])

  #expect(!configuration.remoteHostedPIPEnabled)
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
    try SkyServiceConfiguration(arguments: ["--disable-pip", "--experimental-pip"])
  }
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["--socket"])
  }
}
