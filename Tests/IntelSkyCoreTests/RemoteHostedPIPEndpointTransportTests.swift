import Darwin
import Foundation
import Testing
import XPC

@testable import IntelSkyCore

@Test func pipEndpointTransportMatchesHostXPCPipeWireFormat() throws {
  let rendezvous = try #require(NSMachPort())
  let listener = NSXPCListener.anonymous()
  let replyPort = rendezvous.machPort
  let endpoint = UncheckedSendableReference(listener.endpoint)
  let receiverFinished = DispatchSemaphore(value: 0)
  let senderFinished = DispatchSemaphore(value: 0)
  let result = EndpointRoundTripResult()

  DispatchQueue.global(qos: .userInitiated).async {
    var request: xpc_object_t?
    let receiveStatus = test_xpc_pipe_receive(replyPort, &request)
    result.recordReceive(status: receiveStatus)
    guard receiveStatus == 0, let request else {
      receiverFinished.signal()
      return
    }
    let endpoint = xpc_dictionary_get_value(request, "endpoint")
    result.recordEndpointType(endpoint.map(xpc_get_type))
    guard let reply = xpc_dictionary_create_reply(request) else {
      receiverFinished.signal()
      return
    }
    result.recordReply(status: test_xpc_pipe_routine_reply(reply))
    receiverFinished.signal()
  }

  DispatchQueue.global(qos: .userInitiated).async {
    do {
      try RemoteHostedPIPEndpointTransport().send(
        endpoint: endpoint.value,
        to: replyPort
      )
      result.recordSender(error: nil)
    } catch {
      result.recordSender(error: error)
    }
    senderFinished.signal()
  }

  #expect(receiverFinished.wait(timeout: .now() + 2) == .success)
  #expect(senderFinished.wait(timeout: .now() + 2) == .success)
  #expect(result.receiveStatus == 0)
  #expect(result.endpointType == XPC_TYPE_ENDPOINT)
  #expect(result.replyStatus == 0)
  #expect(result.senderError == nil)
}

private struct UncheckedSendableReference<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

private final class EndpointRoundTripResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedReceiveStatus: Int32?
  private var storedEndpointType: xpc_type_t?
  private var storedReplyStatus: Int32?
  private var storedSenderError: Error?

  var receiveStatus: Int32? { lock.withLock { storedReceiveStatus } }
  var endpointType: xpc_type_t? { lock.withLock { storedEndpointType } }
  var replyStatus: Int32? { lock.withLock { storedReplyStatus } }
  var senderError: Error? { lock.withLock { storedSenderError } }

  func recordReceive(status: Int32) { lock.withLock { storedReceiveStatus = status } }
  func recordEndpointType(_ type: xpc_type_t?) { lock.withLock { storedEndpointType = type } }
  func recordReply(status: Int32) { lock.withLock { storedReplyStatus = status } }
  func recordSender(error: Error?) { lock.withLock { storedSenderError = error } }
}

@_silgen_name("xpc_pipe_receive")
private func test_xpc_pipe_receive(
  _ port: mach_port_t,
  _ message: UnsafeMutablePointer<xpc_object_t?>
) -> Int32

@_silgen_name("xpc_pipe_routine_reply")
private func test_xpc_pipe_routine_reply(_ reply: xpc_object_t) -> Int32
