import Foundation
import XPC

enum RemoteHostedPIPHostCallError: Error, CustomStringConvertible {
  case unavailable
  case timedOut
  case rejected(Error)

  var description: String {
    switch self {
    case .unavailable: return "The remote-hosted PIP host is unavailable."
    case .timedOut: return "The remote-hosted PIP host call timed out."
    case .rejected(let error): return "The remote-hosted PIP host rejected the call: \(error)"
    }
  }
}

protocol RemoteHostedPIPHostCalling: Sendable {
  func publishPresentation(
    id: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    size: CGSize
  ) throws
  func setSourceProcessIdentifier(_ pid: pid_t, presentationID: String) throws
  func prepareResize(
    presentationID: String,
    operationID: UInt64,
    contextID: UInt32,
    size: CGSize,
    fencePort: mach_port_t
  ) throws
  func completeOperation(presentationID: String, operationID: UInt64) throws
  func willEndStream(presentationID: String) throws
  func invalidatePresentation(id: String) throws
  func noteInteraction(presentationID: String) throws
  func setCursorLocation(_ point: CGPoint, isActive: Bool) throws
}

final class RemoteHostedPIPContentProducer: NSObject,
  RemoteHostedPIPContentProducerXPCProtocol, @unchecked Sendable
{
  private let lock = NSLock()
  private var connected = false
  private var maximumDisplaySize: Double?
  private var actionHandler: (@Sendable (String, String) throws -> Void)?
  private var didEndStreamHandler: (@Sendable (String) -> Void)?

  var isConnected: Bool { lock.withLock { connected } }
  var maxDisplaySize: Double? { lock.withLock { maximumDisplaySize } }

  func connect(reply: @escaping RemoteHostedPIPReply) {
    lock.withLock { connected = true }
    RemoteHostedPIPDiagnostics.logger.notice("native host connected")
    reply(nil)
  }

  func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply) {
    guard size.isFinite, size > 0 else {
      reply(Self.error(code: 2, description: "The PIP maximum display size is invalid."))
      return
    }
    lock.withLock { maximumDisplaySize = size }
    RemoteHostedPIPDiagnostics.logger.notice(
      "native host set maximum display size=\(size, privacy: .public)"
    )
    reply(nil)
  }

  func performAction(
    presentationID: String,
    kind: String,
    reply: @escaping RemoteHostedPIPReply
  ) {
    guard let actionHandler = lock.withLock({ actionHandler }) else {
      reply(Self.error(code: 3, description: "The PIP presentation is unavailable."))
      return
    }
    do {
      try actionHandler(presentationID, kind)
      reply(nil)
    } catch {
      reply(error as NSError)
    }
  }

  func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) {
    let handler = lock.withLock { didEndStreamHandler }
    handler?(presentationID)
    reply(nil)
  }

  func connectionDidInvalidate() {
    lock.withLock { connected = false }
  }

  func setActionHandler(_ handler: @escaping @Sendable (String, String) throws -> Void) {
    lock.withLock { actionHandler = handler }
  }

  func setDidEndStreamHandler(_ handler: @escaping @Sendable (String) -> Void) {
    lock.withLock { didEndStreamHandler = handler }
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
  RemoteHostedPIPHostCalling, @unchecked Sendable
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

  func setActionHandler(_ handler: @escaping @Sendable (String, String) throws -> Void) {
    producer.setActionHandler(handler)
  }

  func setDidEndStreamHandler(_ handler: @escaping @Sendable (String) -> Void) {
    producer.setDidEndStreamHandler(handler)
  }

  func publishPresentation(
    id: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    size: CGSize
  ) throws {
    try performHostCall { host, reply in
      host.publishPresentation(
        id: id,
        threadID: threadID,
        turnID: turnID,
        contextID: contextID,
        width: size.width,
        height: size.height,
        reply: reply
      )
    }
  }

  func setSourceProcessIdentifier(_ pid: pid_t, presentationID: String) throws {
    try performHostCall { host, reply in
      host.setSourceProcessIdentifier(pid, presentationID: presentationID, reply: reply)
    }
  }

  func prepareResize(
    presentationID: String,
    operationID: UInt64,
    contextID: UInt32,
    size: CGSize,
    fencePort: mach_port_t
  ) throws {
    let fencePayload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_mach_send(fencePayload, "fence", fencePort)
    try performHostCall { host, reply in
      host.prepareOperation(
        presentationID: presentationID,
        operationID: operationID,
        kind: "resize",
        contextID: contextID,
        width: size.width,
        height: size.height,
        fencePayload: fencePayload,
        reply: reply
      )
    }
  }

  func completeOperation(presentationID: String, operationID: UInt64) throws {
    try performHostCall { host, reply in
      host.completeOperation(
        presentationID: presentationID,
        operationID: operationID,
        reply: reply
      )
    }
  }

  func willEndStream(presentationID: String) throws {
    try performHostCall { host, reply in
      host.willEndStream(presentationID: presentationID, reply: reply)
    }
  }

  func invalidatePresentation(id: String) throws {
    try performHostCall { host, reply in
      host.invalidatePresentation(id: id, reply: reply)
    }
  }

  func noteInteraction(presentationID: String) throws {
    try performHostCall { host, reply in
      host.noteInteraction(presentationID: presentationID, reply: reply)
    }
  }

  func setCursorLocation(_ point: CGPoint, isActive: Bool) throws {
    try performHostCall { host, reply in
      host.setComputerUseCursorLocation(
        x: point.x,
        y: point.y,
        isActive: ObjCBool(isActive),
        reply: reply
      )
    }
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    do {
      try hostAuthorizer.authorize(processIdentifier: newConnection.processIdentifier)
    } catch {
      RemoteHostedPIPDiagnostics.logger.error(
        "rejected XPC host pid=\(newConnection.processIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return false
    }

    let producerInterface = NSXPCInterface(
      with: RemoteHostedPIPContentProducerXPCProtocol.self
    )
    let hostInterface = NSXPCInterface(with: RemoteHostedPIPContentHostXPCProtocol.self)
    Self.configureFencePayload(on: hostInterface)
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
    RemoteHostedPIPDiagnostics.logger.notice(
      "accepted XPC host pid=\(newConnection.processIdentifier, privacy: .public)"
    )
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

  static func configureFencePayload(on interface: NSXPCInterface) {
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

  private func performHostCall(
    _ operation: (
      RemoteHostedPIPContentHostXPCProtocol,
      @escaping RemoteHostedPIPReply
    ) -> Void
  ) throws {
    guard let connection = lock.withLock({ activeConnection }) else {
      RemoteHostedPIPDiagnostics.logger.error("host call attempted without an active connection")
      throw RemoteHostedPIPHostCallError.unavailable
    }
    let result = RemoteHostedPIPHostCallResult()
    let semaphore = DispatchSemaphore(value: 0)
    guard
      let host = connection.remoteObjectProxyWithErrorHandler({ error in
        result.finish(error)
        semaphore.signal()
      }) as? RemoteHostedPIPContentHostXPCProtocol
    else {
      throw RemoteHostedPIPHostCallError.unavailable
    }
    operation(host) { error in
      result.finish(error)
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 3) == .success else {
      RemoteHostedPIPDiagnostics.logger.error("native host call timed out")
      throw RemoteHostedPIPHostCallError.timedOut
    }
    if let error = result.error {
      RemoteHostedPIPDiagnostics.logger.error(
        "native host call rejected: \(String(describing: error), privacy: .public)"
      )
      throw RemoteHostedPIPHostCallError.rejected(error)
    }
  }
}

private final class RemoteHostedPIPHostCallResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  private var finished = false

  var error: Error? { lock.withLock { storedError } }

  func finish(_ error: Error?) {
    lock.withLock {
      guard !finished else { return }
      finished = true
      storedError = error
    }
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
