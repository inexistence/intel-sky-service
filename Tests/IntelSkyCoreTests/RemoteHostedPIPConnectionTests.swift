@preconcurrency import Darwin
import Foundation
import Testing
import XPC

@testable import IntelSkyCore

@inline(__always)
private nonisolated(unsafe) func pipTestTaskPort() -> mach_port_t {
  mach_task_self_
}

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
  let hostInterface = NSXPCInterface(with: RemoteHostedPIPContentHostXPCProtocol.self)
  RemoteHostedPIPConnectionController.configureFencePayload(on: hostInterface)
  client.exportedInterface = hostInterface
  let host = RecordingPIPHost()
  client.exportedObject = host
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

  try controller.publishPresentation(
    id: "presentation",
    threadID: "thread",
    turnID: "turn",
    contextID: 42,
    size: CGSize(width: 640, height: 480)
  )
  try controller.setSourceProcessIdentifier(321, presentationID: "presentation")
  let surface = try RemoteHostedPIPSurface(size: CGSize(width: 800, height: 600))
  let fencePort = try surface.createFencePort()
  defer { mach_port_deallocate(pipTestTaskPort(), fencePort) }
  try controller.prepareResize(
    presentationID: "presentation",
    operationID: 1,
    contextID: surface.contextID,
    size: surface.size,
    fencePort: fencePort
  )
  try controller.completeOperation(presentationID: "presentation", operationID: 1)
  try controller.prepareContextReplacement(
    presentationID: "presentation",
    operationID: 2,
    contextID: surface.contextID,
    size: surface.size,
    fencePort: fencePort
  )
  try controller.completeOperation(presentationID: "presentation", operationID: 2)
  #expect(
    host.events == [
      "publish:presentation:42:640x480",
      "source:presentation:321",
      "prepare:presentation:1:resize:800x600:fence",
      "complete:presentation:1",
      "prepare:presentation:2:replace-context:800x600:fence",
      "complete:presentation:2",
    ]
  )
}

@Test func pipHostInvalidationRequestsManagedServiceShutdown() throws {
  let controller = RemoteHostedPIPConnectionController(
    hostAuthorizer: AllowAnyProcessAuthorizer(),
    enforceConnectionCodeSigningRequirement: false
  )
  let invalidated = DispatchSemaphore(value: 0)
  controller.setHostInvalidationHandler { invalidated.signal() }

  let client = NSXPCConnection(listenerEndpoint: controller.endpoint)
  client.remoteObjectInterface = NSXPCInterface(
    with: RemoteHostedPIPContentProducerXPCProtocol.self
  )
  let hostInterface = NSXPCInterface(with: RemoteHostedPIPContentHostXPCProtocol.self)
  RemoteHostedPIPConnectionController.configureFencePayload(on: hostInterface)
  client.exportedInterface = hostInterface
  client.exportedObject = RecordingPIPHost()
  client.activate()

  let connected = DispatchSemaphore(value: 0)
  let proxy = try #require(
    client.remoteObjectProxyWithErrorHandler { _ in connected.signal() }
      as? RemoteHostedPIPContentProducerXPCProtocol
  )
  proxy.connect { _ in connected.signal() }
  #expect(connected.wait(timeout: .now() + 2) == .success)
  client.invalidate()

  #expect(invalidated.wait(timeout: .now() + 2) == .success)
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

@Test func pipProducerReportsConnectionStateTransitionsOnce() {
  let producer = RemoteHostedPIPContentProducer()
  let states = PIPConnectionStateRecorder()
  producer.setConnectionStateHandler { states.append($0) }

  producer.connect { _ in }
  producer.connect { _ in }
  producer.connectionDidInvalidate()
  producer.connectionDidInvalidate()

  #expect(states.values == [true, false])
}

@Test func pipProducerReplaysAndPublishesMaximumDisplaySize() {
  let producer = RemoteHostedPIPContentProducer()
  let sizes = LockedValues<Double>()
  producer.setMaxDisplaySize(200) { error in #expect(error == nil) }

  producer.setMaximumDisplaySizeHandler { sizes.append($0) }
  producer.setMaxDisplaySize(320) { error in #expect(error == nil) }

  #expect(sizes.values == [200, 320])
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

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Value] = []
  var values: [Value] { lock.withLock { stored } }
  func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private final class PIPConnectionStateRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Bool] = []
  var values: [Bool] { lock.withLock { stored } }
  func append(_ value: Bool) { lock.withLock { stored.append(value) } }
}

private final class RecordingPIPHost: NSObject, RemoteHostedPIPContentHostXPCProtocol {
  private let lock = NSLock()
  private var storedEvents: [String] = []
  var events: [String] { lock.withLock { storedEvents } }

  func publishPresentation(
    id presentationID: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    width: Double,
    height: Double,
    reply: @escaping RemoteHostedPIPReply
  ) {
    lock.withLock {
      storedEvents.append("publish:\(presentationID):\(contextID):\(Int(width))x\(Int(height))")
    }
    reply(nil)
  }

  func setSourceProcessIdentifier(
    _ processIdentifier: Int32,
    presentationID: String,
    reply: @escaping RemoteHostedPIPReply
  ) {
    lock.withLock {
      storedEvents.append("source:\(presentationID):\(processIdentifier)")
    }
    reply(nil)
  }

  func prepareOperation(
    presentationID: String,
    operationID: UInt64,
    kind: String,
    contextID: UInt32,
    width: Double,
    height: Double,
    fencePayload: xpc_object_t,
    reply: @escaping RemoteHostedPIPReply
  ) {
    let fencePort = xpc_dictionary_copy_mach_send(fencePayload, "fence")
    let hasFence = fencePort != MACH_PORT_NULL
    if hasFence { mach_port_deallocate(pipTestTaskPort(), fencePort) }
    lock.withLock {
      storedEvents.append(
        "prepare:\(presentationID):\(operationID):\(kind):\(Int(width))x\(Int(height)):\(hasFence ? "fence" : "missing")"
      )
    }
    reply(nil)
  }

  func completeOperation(
    presentationID: String,
    operationID: UInt64,
    reply: @escaping RemoteHostedPIPReply
  ) {
    lock.withLock { storedEvents.append("complete:\(presentationID):\(operationID)") }
    reply(nil)
  }

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
