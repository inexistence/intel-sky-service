import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func pipBootstrapListenerStartsBeforeProductionRuntimeInitialization() {
  let controller = RemoteHostedPIPBootstrapController()

  #expect(!controller.hasInitializedRuntime)
  controller.start()
  #expect(!controller.hasInitializedRuntime)
}

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

@Test func pipBootstrapControllerRetriesTransientEndpointEIO() throws {
  let sender = RecordingEndpointSender(transientFailures: 2)
  let controller = RemoteHostedPIPBootstrapController(
    connectionController: RemoteHostedPIPConnectionController(
      hostAuthorizer: AllowBootstrapHost(),
      enforceConnectionCodeSigningRequirement: false
    ),
    endpointSender: sender,
    hostAuthorizer: AllowBootstrapHost(),
    endpointMaximumAttempts: 3,
    endpointRetrySleeper: { _ in }
  )

  try controller.process(bootstrapRequest(pid: 42, port: 99))

  #expect(sender.sentPorts == [99, 99, 99])
}

@Test func pipBootstrapDoesNotResendEndpointAfterNativeHostConnected() throws {
  let sender = RecordingEndpointSender()
  let producer = RemoteHostedPIPContentProducer()
  let controller = RemoteHostedPIPBootstrapController(
    connectionController: RemoteHostedPIPConnectionController(
      producer: producer,
      hostAuthorizer: AllowBootstrapHost(),
      enforceConnectionCodeSigningRequirement: false
    ),
    endpointSender: sender,
    hostAuthorizer: AllowBootstrapHost()
  )
  producer.connect { error in
    #expect(error == nil)
  }

  try controller.process(bootstrapRequest(pid: 42, port: 99))

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
  private var transientFailures: Int
  var sentPorts: [mach_port_t] { lock.withLock { storedPorts } }

  init(transientFailures: Int = 0) {
    self.transientFailures = transientFailures
  }

  func send(endpoint: NSXPCListenerEndpoint, to replyPort: mach_port_t) throws {
    let shouldFail = lock.withLock { () -> Bool in
      storedPorts.append(replyPort)
      guard transientFailures > 0 else { return false }
      transientFailures -= 1
      return true
    }
    if shouldFail { throw RemoteHostedPIPEndpointTransportError.routineFailed(EIO) }
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
