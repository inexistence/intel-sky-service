import Foundation
import Testing
import XPC

@testable import IntelSkyCore

@Test func pipProducerCompletesRealBidirectionalXPCHandshake() throws {
  let producer = RemoteHostedPIPContentProducer()
  let controller = RemoteHostedPIPConnectionController(
    producer: producer,
    hostAuthorizer: AllowAnyProcessAuthorizer(),
    enforceConnectionCodeSigningRequirement: false
  )
  let client = NSXPCConnection(listenerEndpoint: controller.endpoint)
  client.remoteObjectInterface = NSXPCInterface(
    with: RemoteHostedPIPContentProducerXPCProtocol.self
  )
  client.exportedInterface = NSXPCInterface(with: RemoteHostedPIPContentHostXPCProtocol.self)
  client.exportedObject = RecordingPIPHost()
  client.activate()
  defer { client.invalidate() }

  let connected = DispatchSemaphore(value: 0)
  let maxSizeUpdated = DispatchSemaphore(value: 0)
  let result = PIPReplyResult()
  let proxy = try #require(
    client.remoteObjectProxyWithErrorHandler { error in
      result.record(error)
      connected.signal()
      maxSizeUpdated.signal()
    } as? RemoteHostedPIPContentProducerXPCProtocol
  )
  proxy.connect { error in
    result.record(error)
    connected.signal()
  }

  #expect(connected.wait(timeout: .now() + 2) == .success)
  #expect(result.error == nil)
  #expect(producer.isConnected)

  proxy.setMaxDisplaySize(640) { error in
    result.record(error)
    maxSizeUpdated.signal()
  }

  #expect(maxSizeUpdated.wait(timeout: .now() + 2) == .success)
  #expect(result.error == nil)
  #expect(producer.maxDisplaySize == 640)
}

@Test func pipProducerRejectsInvalidSizeAndUnavailablePresentation() {
  let producer = RemoteHostedPIPContentProducer()
  var sizeError: NSError?
  var actionError: NSError?

  producer.setMaxDisplaySize(.nan) { sizeError = $0 }
  producer.performAction(presentationID: "missing", kind: "focus-presentation") {
    actionError = $0
  }

  #expect(sizeError != nil)
  #expect(actionError != nil)
}

private struct AllowAnyProcessAuthorizer: ProcessAuthorizing {
  func authorize(processIdentifier: pid_t) throws {}
}

private final class PIPReplyResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  var error: Error? { lock.withLock { storedError } }
  func record(_ error: Error?) { lock.withLock { storedError = error } }
}

private final class RecordingPIPHost: NSObject, RemoteHostedPIPContentHostXPCProtocol {
  func publishPresentation(
    id presentationID: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    width: Double,
    height: Double,
    reply: @escaping RemoteHostedPIPReply
  ) { reply(nil) }

  func setSourceProcessIdentifier(
    _ processIdentifier: Int32,
    presentationID: String,
    reply: @escaping RemoteHostedPIPReply
  ) { reply(nil) }

  func prepareOperation(
    presentationID: String,
    operationID: UInt64,
    kind: String,
    contextID: UInt32,
    width: Double,
    height: Double,
    fencePayload: xpc_object_t,
    reply: @escaping RemoteHostedPIPReply
  ) { reply(nil) }

  func completeOperation(
    presentationID: String,
    operationID: UInt64,
    reply: @escaping RemoteHostedPIPReply
  ) { reply(nil) }

  func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
    reply(nil)
  }

  func invalidatePresentation(id presentationID: String, reply: @escaping RemoteHostedPIPReply) {
    reply(nil)
  }

  func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
    reply(nil)
  }

  func setComputerUseCursorLocation(
    x: Double,
    y: Double,
    isActive: ObjCBool,
    reply: @escaping RemoteHostedPIPReply
  ) { reply(nil) }
}
