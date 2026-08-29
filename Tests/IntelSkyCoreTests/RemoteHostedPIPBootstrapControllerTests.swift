import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func pipBootstrapControllerAuthorizesBeforeSendingEndpoint() throws {
  let sender = RecordingEndpointSender()
  let controller = RemoteHostedPIPBootstrapController(
    connectionController: RemoteHostedPIPConnectionController(
      hostAuthorizer: AllowBootstrapHost(),
      enforceConnectionCodeSigningRequirement: false
    ),
    endpointSender: sender,
    hostAuthorizer: AllowBootstrapHost()
  )
  let request = try bootstrapRequest(pid: 42, port: 99)

  try controller.process(request)

  #expect(sender.sentPorts == [99])
}

@Test func pipBootstrapControllerDoesNotSendEndpointAfterAuthorizationFailure() throws {
  let sender = RecordingEndpointSender()
  let controller = RemoteHostedPIPBootstrapController(
    connectionController: RemoteHostedPIPConnectionController(
      hostAuthorizer: AllowBootstrapHost(),
      enforceConnectionCodeSigningRequirement: false
    ),
    endpointSender: sender,
    hostAuthorizer: DenyBootstrapHost()
  )
  let request = try bootstrapRequest(pid: 42, port: 99)

  #expect(throws: BootstrapAuthorizationFailure.self) {
    try controller.process(request)
  }
  #expect(sender.sentPorts.isEmpty)
}

private struct AllowBootstrapHost: ProcessAuthorizing {
  func authorize(processIdentifier: pid_t) throws {}
}

private struct DenyBootstrapHost: ProcessAuthorizing {
  func authorize(processIdentifier: pid_t) throws { throw BootstrapAuthorizationFailure() }
}

private struct BootstrapAuthorizationFailure: Error {}

private final class RecordingEndpointSender: RemoteHostedPIPEndpointSending, @unchecked Sendable {
  private let lock = NSLock()
  private var storedPorts: [mach_port_t] = []
  var sentPorts: [mach_port_t] { lock.withLock { storedPorts } }

  func send(endpoint: NSXPCListenerEndpoint, to replyPort: mach_port_t) throws {
    lock.withLock { storedPorts.append(replyPort) }
  }
}

private func bootstrapRequest(pid: Int32, port: mach_port_t) throws
  -> RemoteHostedPIPBootstrapRequest
{
  var port = port
  return try RemoteHostedPIPBootstrapRequest(
    version: RemoteHostedPIPBootstrapRequest.nativeBridgeVersion,
    senderProcessIdentifier: pid,
    replyPortData: withUnsafeBytes(of: &port) { Data($0) }
  )
}
