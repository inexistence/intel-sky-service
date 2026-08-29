import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func pipBootstrapParsesVersionSenderAndNativeEndianReplyPort() throws {
  var port: mach_port_t = 0x1234_5678
  let data = withUnsafeBytes(of: &port) { Data($0) }
  let request = try RemoteHostedPIPBootstrapRequest(
    version: RemoteHostedPIPBootstrapRequest.nativeBridgeVersion,
    senderProcessIdentifier: 42,
    replyPortData: data
  )

  #expect(request.senderProcessIdentifier == 42)
  #expect(request.replyPort == port)
}

@Test func pipBootstrapFailsClosedForWrongVersionSenderOrPort() {
  var validPort: mach_port_t = 7
  let validData = withUnsafeBytes(of: &validPort) { Data($0) }

  #expect(throws: RemoteHostedPIPBootstrapError.self) {
    try RemoteHostedPIPBootstrapRequest(
      version: "CodexComputerUseNativeBridge-2",
      senderProcessIdentifier: 42,
      replyPortData: validData
    )
  }
  #expect(throws: RemoteHostedPIPBootstrapError.self) {
    try RemoteHostedPIPBootstrapRequest(
      version: RemoteHostedPIPBootstrapRequest.nativeBridgeVersion,
      senderProcessIdentifier: 0,
      replyPortData: validData
    )
  }
  #expect(throws: RemoteHostedPIPBootstrapError.self) {
    try RemoteHostedPIPBootstrapRequest(
      version: RemoteHostedPIPBootstrapRequest.nativeBridgeVersion,
      senderProcessIdentifier: 42,
      replyPortData: Data([1, 2, 3])
    )
  }
  #expect(throws: RemoteHostedPIPBootstrapError.self) {
    try RemoteHostedPIPBootstrapRequest(
      version: RemoteHostedPIPBootstrapRequest.nativeBridgeVersion,
      senderProcessIdentifier: 42,
      replyPortData: Data(repeating: 0, count: MemoryLayout<mach_port_t>.size)
    )
  }
}
