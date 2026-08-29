import Foundation
import Testing

@testable import IntelSkyCore

@Test func noArgumentsUseOfficialGroupContainerSocketPath() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: [],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
  )

  #expect(
    configuration.socketPath
      == "/Users/example/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock"
  )
}

@Test func explicitAbsoluteSocketOverridesDefault() throws {
  let configuration = try SkyServiceConfiguration(
    arguments: ["--socket", "/tmp/intel-sky/computeruse.sock"],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
  )

  #expect(configuration.socketPath == "/tmp/intel-sky/computeruse.sock")
}

@Test func invalidArgumentsAndRelativeSocketAreRejected() {
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["unexpected"])
  }
  #expect(throws: SkyServiceConfigurationError.self) {
    try SkyServiceConfiguration(arguments: ["--socket", "relative.sock"])
  }
}
