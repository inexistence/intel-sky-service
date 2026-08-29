import Foundation
import ObjectiveC.runtime
import Testing

@testable import IntelSkyCore

@Test func remoteHostedPIPProtocolsExposeExactIntelHostSelectors() throws {
  let host = try #require(NSProtocolFromString(RemoteHostedPIPProtocolABI.hostProtocolName))
  let producer = try #require(
    NSProtocolFromString(RemoteHostedPIPProtocolABI.producerProtocolName)
  )

  for (selectorName, expectedTypes) in RemoteHostedPIPProtocolABI.hostMethodTypes {
    let description = protocol_getMethodDescription(
      host,
      NSSelectorFromString(selectorName),
      true,
      true
    )
    #expect(description.name != nil, "missing host selector \(selectorName)")
    #expect(description.types.map { String(cString: $0) } == expectedTypes)
  }

  for (selectorName, expectedTypes) in RemoteHostedPIPProtocolABI.producerMethodTypes {
    let description = protocol_getMethodDescription(
      producer,
      NSSelectorFromString(selectorName),
      true,
      true
    )
    #expect(description.name != nil, "missing producer selector \(selectorName)")
    #expect(description.types.map { String(cString: $0) } == expectedTypes)
  }
}
