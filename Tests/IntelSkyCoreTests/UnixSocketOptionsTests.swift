import Darwin
import Testing

@testable import IntelSkyCore

@Test func connectedSocketsSuppressSIGPIPE() throws {
  var descriptors = [Int32](repeating: -1, count: 2)
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
  defer {
    for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
  }

  try UnixSocketOptions.suppressSIGPIPE(on: descriptors[0])

  var enabled: Int32 = 0
  var length = socklen_t(MemoryLayout<Int32>.size)
  #expect(
    getsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length) == 0
  )
  #expect(enabled == 1)
}

@Test func disconnectedPeerReturnsEPIPEWithoutTerminatingProcess() throws {
  var descriptors = [Int32](repeating: -1, count: 2)
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
  defer {
    for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
  }

  try UnixSocketOptions.suppressSIGPIPE(on: descriptors[0])
  close(descriptors[1])
  descriptors[1] = -1

  var byte: UInt8 = 0x7f
  errno = 0
  #expect(Darwin.write(descriptors[0], &byte, 1) == -1)
  #expect(errno == EPIPE)
}

@Test func suppressingSIGPIPERejectsInvalidDescriptor() {
  #expect(throws: UnixSocketError.self) {
    try UnixSocketOptions.suppressSIGPIPE(on: -1)
  }
}
