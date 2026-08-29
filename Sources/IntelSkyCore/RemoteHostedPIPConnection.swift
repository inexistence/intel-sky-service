import Foundation
import XPC

final class RemoteHostedPIPContentProducer: NSObject,
  RemoteHostedPIPContentProducerXPCProtocol, @unchecked Sendable
{
  private let lock = NSLock()
  private var connected = false
  private var maximumDisplaySize: Double?

  var isConnected: Bool { lock.withLock { connected } }
  var maxDisplaySize: Double? { lock.withLock { maximumDisplaySize } }

  func connect(reply: @escaping RemoteHostedPIPReply) {
    lock.withLock { connected = true }
    reply(nil)
  }

  func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply) {
    guard size.isFinite, size > 0 else {
      reply(Self.error(code: 2, description: "The PIP maximum display size is invalid."))
      return
    }
    lock.withLock { maximumDisplaySize = size }
    reply(nil)
  }

  func performAction(
    presentationID: String,
    kind: String,
    reply: @escaping RemoteHostedPIPReply
  ) {
    reply(Self.error(code: 3, description: "The PIP presentation is unavailable."))
  }

  func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
    reply(nil)
  }

  func connectionDidInvalidate() {
    lock.withLock { connected = false }
  }

  private static func error(code: Int, description: String) -> NSError {
    NSError(
      domain: "dev.huangjianbin.intel-sky-service.remote-hosted-pip",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: description]
    )
  }
}

final class RemoteHostedPIPConnectionController: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  static let hostCodeSigningRequirement =
    "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"com.openai.codex\""

  private let lock = NSLock()
  private let listener: NSXPCListener
  private let producer: RemoteHostedPIPContentProducer
  private let hostAuthorizer: any ProcessAuthorizing
  private var activeConnection: NSXPCConnection?

  init(
    producer: RemoteHostedPIPContentProducer = RemoteHostedPIPContentProducer(),
    hostAuthorizer: any ProcessAuthorizing = OpenAIChatGPTHostAuthorizer(),
    enforceConnectionCodeSigningRequirement: Bool = true
  ) {
    self.producer = producer
    self.hostAuthorizer = hostAuthorizer
    listener = .anonymous()
    super.init()
    if enforceConnectionCodeSigningRequirement {
      listener.setConnectionCodeSigningRequirement(Self.hostCodeSigningRequirement)
    }
    listener.delegate = self
    listener.activate()
  }

  deinit {
    listener.invalidate()
    activeConnection?.invalidate()
  }

  var endpoint: NSXPCListenerEndpoint { listener.endpoint }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    do {
      try hostAuthorizer.authorize(processIdentifier: newConnection.processIdentifier)
    } catch {
      return false
    }

    let producerInterface = NSXPCInterface(
      with: RemoteHostedPIPContentProducerXPCProtocol.self
    )
    let hostInterface = NSXPCInterface(with: RemoteHostedPIPContentHostXPCProtocol.self)
    configureFencePayload(on: hostInterface)
    newConnection.exportedInterface = producerInterface
    newConnection.exportedObject = producer
    newConnection.remoteObjectInterface = hostInterface

    let connectionReference = UncheckedXPCConnectionReference(newConnection)
    newConnection.invalidationHandler = { [weak self] in
      self?.connectionDidInvalidate(connectionReference.connection)
    }
    newConnection.interruptionHandler = { [weak self] in
      self?.connectionDidInterrupt(connectionReference.connection)
    }

    let previous = lock.withLock { () -> NSXPCConnection? in
      let previous = activeConnection
      activeConnection = newConnection
      return previous
    }
    newConnection.activate()
    previous?.invalidate()
    return true
  }

  private func connectionDidInvalidate(_ connection: NSXPCConnection) {
    let wasActive = lock.withLock { () -> Bool in
      guard activeConnection === connection else { return false }
      activeConnection = nil
      return true
    }
    if wasActive { producer.connectionDidInvalidate() }
  }

  private func connectionDidInterrupt(_ connection: NSXPCConnection) {
    let isActive = lock.withLock { activeConnection === connection }
    if isActive { producer.connectionDidInvalidate() }
  }

  private func configureFencePayload(on interface: NSXPCInterface) {
    let spi = unsafeBitCast(interface, to: (any RemoteHostedPIPXPCInterfaceSPI).self)
    spi.setXPCType(
      XPC_TYPE_DICTIONARY,
      selector: NSSelectorFromString(
        "prepareOperationWithPresentationID:operationID:kind:contextID:width:height:fencePayload:withReply:"
      ),
      argumentIndex: 6,
      ofReply: false
    )
  }
}

private struct UncheckedXPCConnectionReference: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}

@objc private protocol RemoteHostedPIPXPCInterfaceSPI {
  @objc(setXPCType:forSelector:argumentIndex:ofReply:)
  func setXPCType(
    _ type: xpc_type_t,
    selector: Selector,
    argumentIndex: UInt,
    ofReply: Bool
  )
}
