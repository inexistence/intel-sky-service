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
  @unchecked Sendable
{
  private static let errorNumberKeyword: AEKeyword = 0x6572_726E  // errn
  private static let errorStringKeyword: AEKeyword = 0x6572_7273  // errs

  private let lock = NSLock()
  private let connectionController: RemoteHostedPIPConnectionController
  private let endpointSender: any RemoteHostedPIPEndpointSending
  private let hostAuthorizer: any ProcessAuthorizing
  private let presentationCoordinator: RemoteHostedPIPPresentationCoordinator
  private let endpointRetrySleeper: @Sendable (TimeInterval) -> Void
  private let endpointMaximumAttempts: Int
  private var started = false

  public override convenience init() {
    let connectionController = RemoteHostedPIPConnectionController()
    let presentationCoordinator = RemoteHostedPIPPresentationCoordinator(
      host: connectionController
    )
    presentationCoordinator.installProducerCallbacks(on: connectionController)
    ComputerUseVisualCoordinator.shared.setRemoteCursorHandler {
      [weak presentationCoordinator] point, isActive in
      presentationCoordinator?.updateCursor(point: point, isActive: isActive)
    }
    ComputerUseSessionCoordinator.shared.setStopHandler {
      [weak presentationCoordinator] bundleIdentifier in
      presentationCoordinator?.stopApplication(bundleIdentifier: bundleIdentifier)
    }
    self.init(
      connectionController: connectionController,
      endpointSender: RemoteHostedPIPEndpointTransport(),
      hostAuthorizer: OpenAIChatGPTHostAuthorizer(),
      presentationCoordinator: presentationCoordinator
    )
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
    self.connectionController = connectionController
    self.endpointSender = endpointSender
    self.hostAuthorizer = hostAuthorizer
    self.presentationCoordinator =
      presentationCoordinator ?? RemoteHostedPIPPresentationCoordinator(host: connectionController)
    self.endpointMaximumAttempts = max(1, endpointMaximumAttempts)
    self.endpointRetrySleeper = endpointRetrySleeper
    super.init()
  }

  deinit {
    if started {
      NSAppleEventManager.shared().removeEventHandler(
        forEventClass: RemoteHostedPIPBootstrapRequest.eventClass,
        andEventID: RemoteHostedPIPBootstrapRequest.eventID
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
    RemoteHostedPIPDiagnostics.logger.notice("bootstrap listener started")
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleBootstrapEvent(_:withReplyEvent:)),
      forEventClass: RemoteHostedPIPBootstrapRequest.eventClass,
      andEventID: RemoteHostedPIPBootstrapRequest.eventID
    )
  }

  @objc private func handleBootstrapEvent(
    _ event: NSAppleEventDescriptor,
    withReplyEvent replyEvent: NSAppleEventDescriptor
  ) {
    do {
      let request = try RemoteHostedPIPBootstrapRequest(
        version: event.paramDescriptor(
          forKeyword: RemoteHostedPIPBootstrapRequest.clientVersionKeyword
        )?.stringValue,
        senderProcessIdentifier: event.attributeDescriptor(
          forKeyword: RemoteHostedPIPBootstrapRequest.senderPIDKeyword
        )?.int32Value,
        replyPortData: event.attributeDescriptor(
          forKeyword: RemoteHostedPIPBootstrapRequest.replyPortKeyword
        )?.data
      )
      try process(request)
    } catch {
      RemoteHostedPIPDiagnostics.logger.error(
        "bootstrap rejected: \(String(describing: error), privacy: .public)"
      )
      replyEvent.setParam(
        NSAppleEventDescriptor(int32: Int32(errAEEventNotHandled)),
        forKeyword: Self.errorNumberKeyword
      )
      replyEvent.setParam(
        NSAppleEventDescriptor(string: String(describing: error)),
        forKeyword: Self.errorStringKeyword
      )
    }
  }

  func process(_ request: RemoteHostedPIPBootstrapRequest) throws {
    RemoteHostedPIPDiagnostics.logger.notice(
      "processing bootstrap request from host pid=\(request.senderProcessIdentifier, privacy: .public)"
    )
    try hostAuthorizer.authorize(processIdentifier: request.senderProcessIdentifier)
    var attempt = 1
    while true {
      do {
        try endpointSender.send(endpoint: connectionController.endpoint, to: request.replyPort)
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
    presentationCoordinator.observe(
      requestType: requestType,
      request: request,
      codexTurnMetadata: codexTurnMetadata,
      result: result
    )
  }
}
