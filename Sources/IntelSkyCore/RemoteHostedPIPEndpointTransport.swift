import Darwin
import Foundation
import XPC

enum RemoteHostedPIPEndpointTransportError: Error, CustomStringConvertible {
  case couldNotCreatePipe
  case routineFailed(Int32)
  case missingReply

  var description: String {
    switch self {
    case .couldNotCreatePipe:
      return "could not create the remote-hosted PIP XPC pipe"
    case .routineFailed(let status):
      return "remote-hosted PIP endpoint transfer failed with status \(status)"
    case .missingReply:
      return "remote-hosted PIP endpoint transfer returned no reply"
    }
  }
}

protocol RemoteHostedPIPEndpointSending: Sendable {
  func send(endpoint: NSXPCListenerEndpoint, to replyPort: mach_port_t) throws
}

struct RemoteHostedPIPEndpointTransport: RemoteHostedPIPEndpointSending {
  func send(endpoint: NSXPCListenerEndpoint, to replyPort: mach_port_t) throws {
    guard let pipe = xpc_pipe_create_from_port(replyPort, 0) else {
      throw RemoteHostedPIPEndpointTransportError.couldNotCreatePipe
    }
    let endpointSPI = unsafeBitCast(
      endpoint,
      to: (any RemoteHostedPIPListenerEndpointSPI).self
    )
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(message, "endpoint", endpointSPI.rawEndpoint())
    var reply: xpc_object_t?
    let status = xpc_pipe_routine(pipe, message, &reply)
    guard status == 0 else {
      throw RemoteHostedPIPEndpointTransportError.routineFailed(status)
    }
    guard reply != nil else {
      throw RemoteHostedPIPEndpointTransportError.missingReply
    }
  }
}

@objc private protocol RemoteHostedPIPListenerEndpointSPI {
  @objc(_endpoint)
  func rawEndpoint() -> xpc_object_t
}

@_silgen_name("xpc_pipe_create_from_port")
private func xpc_pipe_create_from_port(
  _ port: mach_port_t,
  _ flags: UInt32
) -> xpc_object_t?

@_silgen_name("xpc_pipe_routine")
private func xpc_pipe_routine(
  _ pipe: xpc_object_t,
  _ request: xpc_object_t,
  _ reply: UnsafeMutablePointer<xpc_object_t?>
) -> Int32
