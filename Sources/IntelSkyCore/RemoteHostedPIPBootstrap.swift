import Carbon
import Darwin
import Foundation

enum RemoteHostedPIPBootstrapError: Error, Equatable, CustomStringConvertible {
  case incompatibleClientVersion(String?)
  case missingSenderProcessIdentifier
  case invalidReplyPort

  var description: String {
    switch self {
    case .incompatibleClientVersion(let version):
      return "incompatible PIP client version: \(version ?? "<missing>")"
    case .missingSenderProcessIdentifier:
      return "PIP bootstrap is missing a sender process identifier"
    case .invalidReplyPort:
      return "PIP bootstrap contains an invalid Mach reply port"
    }
  }
}

struct RemoteHostedPIPBootstrapRequest: Equatable, Sendable {
  static let nativeBridgeVersion = "CodexComputerUseNativeBridge-1"
  static let eventClass: AEEventClass = 0x536B_4375  // SkCu
  static let eventID: AEEventID = 0x5069_5042  // PiPB
  static let clientVersionKeyword: AEKeyword = 0x436C_566E  // ClVn
  static let senderPIDKeyword: AEKeyword = 0x7370_6964  // spid
  static let replyPortKeyword: AEKeyword = 0x7265_7070  // repp

  let senderProcessIdentifier: pid_t
  let replyPort: mach_port_t

  init(version: String?, senderProcessIdentifier: Int32?, replyPortData: Data?) throws {
    guard version == Self.nativeBridgeVersion else {
      throw RemoteHostedPIPBootstrapError.incompatibleClientVersion(version)
    }
    guard let senderProcessIdentifier, senderProcessIdentifier > 0 else {
      throw RemoteHostedPIPBootstrapError.missingSenderProcessIdentifier
    }
    guard let replyPortData, replyPortData.count == MemoryLayout<mach_port_t>.size else {
      throw RemoteHostedPIPBootstrapError.invalidReplyPort
    }
    var replyPort: mach_port_t = 0
    _ = withUnsafeMutableBytes(of: &replyPort) { destination in
      replyPortData.copyBytes(to: destination)
    }
    guard replyPort != MACH_PORT_NULL else {
      throw RemoteHostedPIPBootstrapError.invalidReplyPort
    }
    self.senderProcessIdentifier = senderProcessIdentifier
    self.replyPort = replyPort
  }
}

public final class RemoteHostedPIPBootstrapController: NSObject, SkyRequestResultObserving,
  ComputerUseTurnLifecycleEventHandling, @unchecked Sendable
{
  private static let errorNumberKeyword: AEKeyword = 0x6572_726E  // errn
  private static let errorStringKeyword: AEKeyword = 0x6572_7273  // errs

  private struct Runtime {
    let connectionController: RemoteHostedPIPConnectionController
    let endpointSender: any RemoteHostedPIPEndpointSending
    let hostAuthorizer: any ProcessAuthorizing
    let presentationCoordinator: RemoteHostedPIPPresentationCoordinator
  }

  private let lock = NSLock()
  private let runtimeLock = NSLock()
  private let injectedConnectionController: RemoteHostedPIPConnectionController?
  private let injectedEndpointSender: (any RemoteHostedPIPEndpointSending)?
  private let injectedHostAuthorizer: (any ProcessAuthorizing)?
  private let injectedPresentationCoordinator: RemoteHostedPIPPresentationCoordinator?
  private let installsProductionCallbacks: Bool
  private let endpointRetrySleeper: @Sendable (TimeInterval) -> Void
  private let endpointMaximumAttempts: Int
  private var started = false
  private var storedRuntime: Runtime?
  private var authorizedHostHandler: (@Sendable (pid_t) -> Void)?

  public override init() {
    injectedConnectionController = nil
    injectedEndpointSender = nil
    injectedHostAuthorizer = nil
    injectedPresentationCoordinator = nil
    installsProductionCallbacks = true
    endpointMaximumAttempts = 3
    endpointRetrySleeper = { Thread.sleep(forTimeInterval: $0) }
    super.init()
  }

  init(
    connectionController: RemoteHostedPIPConnectionController,
    endpointSender: any RemoteHostedPIPEndpointSending,
    hostAuthorizer: any ProcessAuthorizing,
    presentationCoordinator: RemoteHostedPIPPresentationCoordinator? = nil,
    endpointMaximumAttempts: Int = 3,
    endpointRetrySleeper: @escaping @Sendable (TimeInterval) -> Void = {
      Thread.sleep(forTimeInterval: $0)
    }
  ) {
    injectedConnectionController = connectionController
    injectedEndpointSender = endpointSender
    injectedHostAuthorizer = hostAuthorizer
    injectedPresentationCoordinator = presentationCoordinator
    installsProductionCallbacks = false
    self.endpointMaximumAttempts = max(1, endpointMaximumAttempts)
    self.endpointRetrySleeper = endpointRetrySleeper
    super.init()
  }

  var hasInitializedRuntime: Bool { runtimeLock.withLock { storedRuntime != nil } }

  public var isHostConnected: Bool { runtime().connectionController.isConnected }

  public func setHostInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    runtime().connectionController.setHostInvalidationHandler(handler)
  }

  public func setAuthorizedHostHandler(_ handler: @escaping @Sendable (pid_t) -> Void) {
    lock.withLock { authorizedHostHandler = handler }
  }

  deinit {
    if started {
      AERemoveEventHandler(
        RemoteHostedPIPBootstrapRequest.eventClass,
        RemoteHostedPIPBootstrapRequest.eventID,
        remoteHostedPIPBootstrapEventHandler,
        false
      )
    }
  }

  public func start() {
    let shouldStart = lock.withLock { () -> Bool in
      guard !started else { return false }
      started = true
      return true
    }
    guard shouldStart else { return }
    let status = AEInstallEventHandler(
      RemoteHostedPIPBootstrapRequest.eventClass,
      RemoteHostedPIPBootstrapRequest.eventID,
      remoteHostedPIPBootstrapEventHandler,
      Unmanaged.passUnretained(self).toOpaque(),
      false
    )
    guard status == noErr else {
      lock.withLock { started = false }
      RemoteHostedPIPDiagnostics.logger.error(
        "bootstrap listener registration failed status=\(status, privacy: .public)"
      )
      return
    }
    RemoteHostedPIPDiagnostics.logger.notice("bootstrap listener started")
  }

  fileprivate func handleBootstrapEvent(
    _ event: UnsafePointer<AppleEvent>,
    reply: UnsafeMutablePointer<AppleEvent>?
  ) -> OSErr {
    do {
      let request = try RemoteHostedPIPBootstrapRequest(
        version: descriptor(
          from: event,
          keyword: RemoteHostedPIPBootstrapRequest.clientVersionKeyword,
          isAttribute: false
        )?.stringValue,
        senderProcessIdentifier: descriptor(
          from: event,
          keyword: RemoteHostedPIPBootstrapRequest.senderPIDKeyword,
          isAttribute: true
        )?.int32Value,
        replyPortData: descriptor(
          from: event,
          keyword: RemoteHostedPIPBootstrapRequest.replyPortKeyword,
          isAttribute: true
        )?.data
      )
      // The reply port is borrowed from the incoming Apple Event. It must be used
      // before this handler returns; deferring the XPC pipe transfer leaves the
      // native host waiting on a port whose event lifetime has already ended.
      try process(request)
      let replyStatus = Self.writeReply(error: nil, to: reply)
      RemoteHostedPIPDiagnostics.logger.notice(
        "bootstrap event handled for host pid=\(request.senderProcessIdentifier, privacy: .public) replyStatus=\(replyStatus, privacy: .public)"
      )
      return OSErr(noErr)
    } catch {
      _ = Self.writeReply(error: error, to: reply)
      RemoteHostedPIPDiagnostics.logger.error(
        "bootstrap rejected: \(String(describing: error), privacy: .public)"
      )
      return OSErr(errAEEventNotHandled)
    }
  }

  private static func writeReply(
    error: Error?,
    to reply: UnsafeMutablePointer<AppleEvent>?
  ) -> OSErr {
    guard let reply else { return OSErr(errAENoSuchObject) }
    var errorNumber = error == nil ? Int32(noErr) : Int32(errAEEventNotHandled)
    let errorNumberSize = MemoryLayout.size(ofValue: errorNumber)
    let numberStatus = withUnsafePointer(to: &errorNumber) { pointer in
      AEPutParamPtr(
        reply,
        Self.errorNumberKeyword,
        typeSInt32,
        pointer,
        errorNumberSize
      )
    }
    guard numberStatus == noErr, let error else { return numberStatus }
    let message = Data(String(describing: error).utf8)
    return message.withUnsafeBytes { bytes in
      AEPutParamPtr(
        reply,
        Self.errorStringKeyword,
        typeUTF8Text,
        bytes.baseAddress,
        bytes.count
      )
    }
  }

  private func descriptor(
    from event: UnsafePointer<AppleEvent>,
    keyword: AEKeyword,
    isAttribute: Bool
  ) -> NSAppleEventDescriptor? {
    var descriptor = AEDesc()
    let status =
      isAttribute
      ? AEGetAttributeDesc(event, keyword, typeWildCard, &descriptor)
      : AEGetParamDesc(event, keyword, typeWildCard, &descriptor)
    guard status == noErr else { return nil }
    return NSAppleEventDescriptor(aeDescNoCopy: &descriptor)
  }

  func process(_ request: RemoteHostedPIPBootstrapRequest) throws {
    let runtime = runtime()
    RemoteHostedPIPDiagnostics.logger.notice(
      "processing bootstrap request from host pid=\(request.senderProcessIdentifier, privacy: .public)"
    )
    try runtime.hostAuthorizer.authorize(processIdentifier: request.senderProcessIdentifier)
    lock.withLock { authorizedHostHandler }?(request.senderProcessIdentifier)
    guard !runtime.connectionController.isConnected else {
      // ChatGPT can repeat bootstrap for another window or worker after its
      // process-wide native host is already connected. Sending another
      // request/reply transaction to that stale reply port can wait forever
      // and block the service's Apple Event main thread.
      RemoteHostedPIPDiagnostics.logger.notice(
        "bootstrap already satisfied for connected host pid=\(request.senderProcessIdentifier, privacy: .public)"
      )
      return
    }
    try sendEndpoint(for: request, using: runtime)
  }

  private func sendEndpoint(
    for request: RemoteHostedPIPBootstrapRequest,
    using runtime: Runtime
  ) throws {
    var attempt = 1
    while true {
      do {
        try runtime.endpointSender.send(
          endpoint: runtime.connectionController.endpoint,
          to: request.replyPort
        )
        RemoteHostedPIPDiagnostics.logger.notice(
          "bootstrap endpoint sent to host pid=\(request.senderProcessIdentifier, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        return
      } catch RemoteHostedPIPEndpointTransportError.routineFailed(let status)
        where status == EIO && attempt < endpointMaximumAttempts
      {
        RemoteHostedPIPDiagnostics.logger.warning(
          "bootstrap endpoint transfer returned transient EIO for host pid=\(request.senderProcessIdentifier, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        endpointRetrySleeper(0.05 * pow(2, Double(attempt - 1)))
        attempt += 1
      }
    }
  }

  public func observe(
    requestType: String,
    request: [String: Any],
    codexTurnMetadata: Any?,
    result: Any
  ) {
    runtime().presentationCoordinator.observe(
      requestType: requestType,
      request: request,
      codexTurnMetadata: codexTurnMetadata,
      result: result
    )
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    runtime().presentationCoordinator.handle(event)
  }

  private func runtime() -> Runtime {
    runtimeLock.withLock {
      if let storedRuntime { return storedRuntime }

      let connectionController =
        injectedConnectionController ?? RemoteHostedPIPConnectionController()
      let presentationCoordinator =
        injectedPresentationCoordinator
        ?? RemoteHostedPIPPresentationCoordinator(host: connectionController)
      if installsProductionCallbacks {
        presentationCoordinator.installProducerCallbacks(on: connectionController)
        ComputerUseVisualCoordinator.shared.setRemoteCursorHandler {
          [weak presentationCoordinator] point, isActive, isPressed in
          presentationCoordinator?.updateCursor(
            point: point,
            isActive: isActive,
            isPressed: isPressed
          ) ?? false
        }
        ComputerUseSessionCoordinator.shared.setStopHandler {
          [weak presentationCoordinator] bundleIdentifier in
          presentationCoordinator?.stopApplication(bundleIdentifier: bundleIdentifier)
        }
      }
      let runtime = Runtime(
        connectionController: connectionController,
        endpointSender: injectedEndpointSender ?? RemoteHostedPIPEndpointTransport(),
        hostAuthorizer: injectedHostAuthorizer ?? OpenAIChatGPTHostAuthorizer(),
        presentationCoordinator: presentationCoordinator
      )
      storedRuntime = runtime
      RemoteHostedPIPDiagnostics.logger.notice("bootstrap runtime initialized lazily")
      return runtime
    }
  }
}

private let remoteHostedPIPBootstrapEventHandler: AEEventHandlerUPP = {
  event, reply, reference in
  guard let event, let reference else { return OSErr(errAEEventNotHandled) }
  let controller = Unmanaged<RemoteHostedPIPBootstrapController>
    .fromOpaque(reference)
    .takeUnretainedValue()
  return controller.handleBootstrapEvent(event, reply: reply)
}
