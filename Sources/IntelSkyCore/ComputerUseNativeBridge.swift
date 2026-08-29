import Foundation

enum ComputerUseNativeBridgeError: Error, CustomStringConvertible {
  case incompatibleClientVersion(String?)
  case missingSenderProcessIdentifier
  case missingRequestType
  case invalidRequestData
  case unsupportedRequestType(String)

  var description: String {
    switch self {
    case .incompatibleClientVersion(let version):
      return "incompatible native bridge version: \(version ?? "<missing>")"
    case .missingSenderProcessIdentifier:
      return "native bridge request is missing a sender process identifier"
    case .missingRequestType:
      return "native bridge request is missing its request type"
    case .invalidRequestData:
      return "native bridge request data is not a JSON object"
    case .unsupportedRequestType(let requestType):
      return "unsupported native bridge request type: \(requestType)"
    }
  }
}

struct ComputerUseNativeBridgeRequest: @unchecked Sendable {
  static let nativeBridgeVersion = "CodexComputerUseNativeBridge-1"
  static let eventClass: AEEventClass = 0x536B_4375  // SkCu
  static let eventID: AEEventID = 0x536E_6452  // SndR
  static let requestTypeKeyword: AEKeyword = 0x5273_7054  // RspT
  static let requestDataKeyword: AEKeyword = 0x5265_7144  // ReqD
  static let clientVersionKeyword: AEKeyword = 0x436C_566E  // ClVn
  static let senderPIDKeyword: AEKeyword = 0x7370_6964  // spid

  let senderProcessIdentifier: pid_t
  let requestType: String
  let request: [String: Any]

  init(
    version: String?,
    senderProcessIdentifier: Int32?,
    requestType: String?,
    requestData: Data?
  ) throws {
    guard version == Self.nativeBridgeVersion else {
      throw ComputerUseNativeBridgeError.incompatibleClientVersion(version)
    }
    guard let senderProcessIdentifier, senderProcessIdentifier > 0 else {
      throw ComputerUseNativeBridgeError.missingSenderProcessIdentifier
    }
    guard let requestType, !requestType.isEmpty else {
      throw ComputerUseNativeBridgeError.missingRequestType
    }
    guard let requestData,
      let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]
    else {
      throw ComputerUseNativeBridgeError.invalidRequestData
    }
    self.senderProcessIdentifier = senderProcessIdentifier
    self.requestType = requestType
    self.request = request
  }
}

public final class ComputerUseNativeBridgeController: NSObject, @unchecked Sendable {
  private static let directObjectKeyword: AEKeyword = 0x2D2D_2D2D  // ----
  private static let dataDescriptorType: DescType = 0x7464_7461  // tdta
  private static let errorNumberKeyword: AEKeyword = 0x6572_726E  // errn
  private static let errorStringKeyword: AEKeyword = 0x6572_7273  // errs

  private let lock = NSLock()
  private let appStateProvider: any AppStateProviding
  private let appCaptureProvider: any AppCaptureProviding
  private let hostAuthorizer: any ProcessAuthorizing
  private var started = false

  public init(
    appStateProvider: any AppStateProviding,
    appCaptureProvider: any AppCaptureProviding
  ) {
    self.appStateProvider = appStateProvider
    self.appCaptureProvider = appCaptureProvider
    hostAuthorizer = OpenAIChatGPTHostAuthorizer()
    super.init()
  }

  init(
    appStateProvider: any AppStateProviding,
    appCaptureProvider: any AppCaptureProviding,
    hostAuthorizer: any ProcessAuthorizing
  ) {
    self.appStateProvider = appStateProvider
    self.appCaptureProvider = appCaptureProvider
    self.hostAuthorizer = hostAuthorizer
    super.init()
  }

  deinit {
    if started {
      NSAppleEventManager.shared().removeEventHandler(
        forEventClass: ComputerUseNativeBridgeRequest.eventClass,
        andEventID: ComputerUseNativeBridgeRequest.eventID
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
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleRequestEvent(_:withReplyEvent:)),
      forEventClass: ComputerUseNativeBridgeRequest.eventClass,
      andEventID: ComputerUseNativeBridgeRequest.eventID
    )
  }

  @objc private func handleRequestEvent(
    _ event: NSAppleEventDescriptor,
    withReplyEvent replyEvent: NSAppleEventDescriptor
  ) {
    do {
      let request = try ComputerUseNativeBridgeRequest(
        version: event.paramDescriptor(
          forKeyword: ComputerUseNativeBridgeRequest.clientVersionKeyword
        )?.stringValue,
        senderProcessIdentifier: event.attributeDescriptor(
          forKeyword: ComputerUseNativeBridgeRequest.senderPIDKeyword
        )?.int32Value,
        requestType: event.paramDescriptor(
          forKeyword: ComputerUseNativeBridgeRequest.requestTypeKeyword
        )?.stringValue,
        requestData: event.paramDescriptor(
          forKeyword: ComputerUseNativeBridgeRequest.requestDataKeyword
        )?.data
      )
      let response = try process(request)
      let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
      guard
        let responseDescriptor = NSAppleEventDescriptor(
          descriptorType: Self.dataDescriptorType,
          data: data
        )
      else {
        throw ComputerUseNativeBridgeError.invalidRequestData
      }
      replyEvent.setParam(
        responseDescriptor,
        forKeyword: Self.directObjectKeyword
      )
    } catch {
      replyEvent.setParam(
        NSAppleEventDescriptor(int32: Int32(errorNumber(for: error))),
        forKeyword: Self.errorNumberKeyword
      )
      replyEvent.setParam(
        NSAppleEventDescriptor(string: String(describing: error)),
        forKeyword: Self.errorStringKeyword
      )
    }
  }

  func process(_ request: ComputerUseNativeBridgeRequest) throws -> [String: Any] {
    try hostAuthorizer.authorize(processIdentifier: request.senderProcessIdentifier)
    switch request.requestType {
    case "ComputerUseIPCAppGetSkyshotRequest":
      return try appStateProvider.getAppState(request: request.request)
    case "ComputerUseIPCAppStartCaptureRequest":
      return try appCaptureProvider.startCapture(request: request.request)
    case "ComputerUseIPCAppNextCaptureUpdateRequest":
      return try appCaptureProvider.nextCaptureUpdate(request: request.request)
    default:
      throw ComputerUseNativeBridgeError.unsupportedRequestType(request.requestType)
    }
  }

  private func errorNumber(for error: Error) -> Int {
    switch error {
    case ComputerUseNativeBridgeError.incompatibleClientVersion:
      return SkyServerErrorCode.incompatibleClientVersion.rawValue
    case ComputerUseNativeBridgeError.missingSenderProcessIdentifier:
      return SkyServerErrorCode.couldNotGetSenderPID.rawValue
    case ComputerUseNativeBridgeError.missingRequestType:
      return SkyServerErrorCode.couldNotGetRequestTypeName.rawValue
    case ComputerUseNativeBridgeError.invalidRequestData, is AppCaptureSessionError:
      return SkyServerErrorCode.couldNotGetRequestData.rawValue
    case ComputerUseNativeBridgeError.unsupportedRequestType:
      return SkyServerErrorCode.couldNotResolveRequestType.rawValue
    case is PeerAuthorizationError:
      return SkyServerErrorCode.senderProcessNotAuthenticated.rawValue
    default:
      return SkyServerErrorCode.unknownError.rawValue
    }
  }
}
