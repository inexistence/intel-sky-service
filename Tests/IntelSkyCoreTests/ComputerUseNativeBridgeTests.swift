import Foundation
import Testing

@testable import IntelSkyCore

@Test func nativeBridgeParsesExactIntelAppleEventEnvelope() throws {
  let request = try ComputerUseNativeBridgeRequest(
    version: "CodexComputerUseNativeBridge-1",
    senderProcessIdentifier: 123,
    requestType: "ComputerUseIPCAppStartCaptureRequest",
    requestData: Data(
      """
      {"app":"com.apple.finder","requestId":"capture","permissionRequestId":"permission","animationTarget":{},"version":2}
      """.utf8
    )
  )

  #expect(ComputerUseNativeBridgeRequest.eventClass == 0x536B_4375)
  #expect(ComputerUseNativeBridgeRequest.eventID == 0x536E_6452)
  #expect(request.senderProcessIdentifier == 123)
  #expect(request.request["requestId"] as? String == "capture")
  #expect(request.request["version"] as? Int == 2)
}

@Test func nativeBridgeAuthorizesBeforeRoutingCaptureRequest() throws {
  let state = NativeBridgeState()
  let controller = ComputerUseNativeBridgeController(
    appStateProvider: NativeBridgeStateProvider(state: state),
    appCaptureProvider: NativeBridgeCaptureProvider(state: state),
    hostAuthorizer: NativeBridgeAuthorizer(state: state)
  )
  let request = try ComputerUseNativeBridgeRequest(
    version: "CodexComputerUseNativeBridge-1",
    senderProcessIdentifier: 123,
    requestType: "ComputerUseIPCAppStartCaptureRequest",
    requestData: Data("{}".utf8)
  )

  let response = try controller.process(request)

  #expect(response["result"] as? String == "started")
  #expect(state.events == ["authorize:123", "start"])
}

private final class NativeBridgeState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [String] = []
  var events: [String] { lock.withLock { storedEvents } }
  func append(_ event: String) { lock.withLock { storedEvents.append(event) } }
}

private struct NativeBridgeAuthorizer: ProcessAuthorizing {
  let state: NativeBridgeState
  func authorize(processIdentifier: pid_t) throws {
    state.append("authorize:\(processIdentifier)")
  }
}

private struct NativeBridgeStateProvider: AppStateProviding {
  let state: NativeBridgeState
  func getAppState(request: [String: Any]) throws -> [String: Any] {
    state.append("state")
    return [:]
  }
  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}

private struct NativeBridgeCaptureProvider: AppCaptureProviding {
  let state: NativeBridgeState
  func startCapture(request: [String: Any]) throws -> [String: Any] {
    state.append("start")
    return ["result": "started"]
  }
  func nextCaptureUpdate(request: [String: Any]) throws -> [String: Any] {
    state.append("next")
    return ["type": "completed"]
  }
}
