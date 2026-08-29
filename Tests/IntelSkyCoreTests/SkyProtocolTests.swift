import Foundation
import Testing

@testable import IntelSkyCore

private struct StubCatalog: AppCatalog {
  func listApps() throws -> [[String: Any]] {
    [
      [
        "bundleIdentifier": "com.apple.finder",
        "displayName": "Finder",
        "isFrontmost": true,
        "isRunning": true,
      ]
    ]
  }
}

private struct StubAppStateProvider: AppStateProviding {
  func getAppState(request: [String: Any]) throws -> [String: Any] {
    [
      "app": ["bundleIdentifier": request["app"] as? String ?? "unknown", "pid": 123],
      "skyshot": ["text": "[0] AXWindow title=\"Finder\""],
    ]
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] {
    [
      "allowPersistentApproval": true,
      "decision": "allowed",
      "target": ["bundleIdentifier": request["app"] as? String ?? "unknown"],
    ]
  }
}

private final class TrackingStartAppStateProvider: AppStateProviding, @unchecked Sendable {
  private(set) var startRequests: [[String: Any]] = []

  func startApp(request: [String: Any]) throws -> [String: Any] {
    startRequests.append(request)
    return [
      "app": ["bundleIdentifier": request["app"] as? String ?? "unknown", "pid": 456],
      "skyshot": ["text": "[0] AXWindow title=\"Started\""],
    ]
  }

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    throw SkyRPCError.invalidRequest("start request was routed as get state")
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}

private final class DefaultStartAppStateProvider: AppStateProviding, @unchecked Sendable {
  private(set) var stateRequests: [[String: Any]] = []

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    stateRequests.append(request)
    return ["app": ["bundleIdentifier": request["app"] as? String ?? "unknown"]]
  }

  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }
}

private struct StubActionPerformer: AppActionPerforming {
  func performAction(request: [String: Any]) throws -> [String: Any] {
    [:]
  }
}

private struct LockedActionPerformer: AppActionPerforming {
  func performAction(request: [String: Any]) throws -> [String: Any] {
    throw SkySafetyError.screenLocked
  }
}

private struct PolicyRejectedActionPerformer: AppActionPerforming {
  func performAction(request: [String: Any]) throws -> [String: Any] {
    throw MacAppPolicyError.forbidden("com.apple.Terminal")
  }
}

private struct UserStoppedActionPerformer: AppActionPerforming {
  func performAction(request: [String: Any]) throws -> [String: Any] {
    throw SkySafetyError.userStoppedSession
  }
}

private func decode(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func pingReportsExactIPCVersion() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 1,
    "method": "ping",
    "params": ["clientApiVersion": SkyProtocol.apiVersion],
  ])

  let response = try decode(SkyRequestRouter(appCatalog: StubCatalog()).handle(request))
  let result = try #require(response["result"] as? [String: Any])

  #expect(result["serverApiVersion"] as? String == SkyProtocol.apiVersion)
  #expect(SkyRequestRouter.isCompatiblePing(request))
}

@Test func listAppsUsesObservedRequestType() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 2,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCListAppsRequest",
      "request": [:],
    ],
  ])

  let response = try decode(SkyRequestRouter(appCatalog: StubCatalog()).handle(request))
  let result = try #require(response["result"] as? [[String: Any]])

  #expect(result.count == 1)
  #expect(result[0]["bundleIdentifier"] as? String == "com.apple.finder")
}

@Test func rejectsWrongProtocolVersion() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 3,
    "method": "ping",
    "params": ["clientApiVersion": "CodexComputerUseIPC-4"],
  ])

  let response = try decode(SkyRequestRouter(appCatalog: StubCatalog()).handle(request))
  let error = try #require(response["error"] as? [String: Any])

  #expect(error["code"] as? Int == SkyServerErrorCode.incompatibleClientVersion.rawValue)
  #expect(!SkyRequestRouter.isCompatiblePing(request))
}

@Test func expiredRequestDeadlineUsesOfficialServiceErrorFamily() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 8,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "deadlineUnixMilliseconds": 1,
      "requestType": "ComputerUseIPCListAppsRequest",
      "request": [:],
    ],
  ])

  let response = try decode(SkyRequestRouter(appCatalog: StubCatalog()).handle(request))
  let error = try #require(response["error"] as? [String: Any])

  #expect(error["code"] as? Int == SkyServerErrorCode.unknownError.rawValue)
  #expect(error["message"] as? String == "Request deadline exceeded")
}

@Test func screenLockedUsesOfficialServiceErrorCode() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 19,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppPerformActionRequest",
      "request": ["app": "com.apple.finder", "action": ["pressKey": ["_0": "Escape"]]],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appActionPerformer: LockedActionPerformer()
  )

  let response = try decode(router.handle(request))
  let error = try #require(response["error"] as? [String: Any])
  #expect(error["code"] as? Int == SkyServerErrorCode.screenLocked.rawValue)
}

@Test func forbiddenTargetUsesOfficialAppNotAllowedErrorCode() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 20,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppPerformActionRequest",
      "request": ["app": "com.apple.Terminal", "action": ["pressKey": ["_0": "Escape"]]],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appActionPerformer: PolicyRejectedActionPerformer()
  )

  let response = try decode(router.handle(request))
  let error = try #require(response["error"] as? [String: Any])
  #expect(error["code"] as? Int == SkyServerErrorCode.appNotAllowed.rawValue)
}

@Test func userStoppedSessionUsesOfficialErrorCodeAndMessage() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 22,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppPerformActionRequest",
      "request": ["app": "com.example.fixture", "action": ["pressKey": ["_0": "A"]]],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appActionPerformer: UserStoppedActionPerformer()
  )

  let response = try decode(router.handle(request))
  let error = try #require(response["error"] as? [String: Any])
  #expect(error["code"] as? Int == SkyServerErrorCode.userStoppedSession.rawValue)
  #expect((error["message"] as? String)?.contains("explicitly stopped by the user") == true)
}

@Test func socketTransportAlsoRoutesStatusAndStopRequests() throws {
  let sessions = ComputerUseSessionCoordinator()
  sessions.recordActive(
    ResolvedMacApp(
      processIdentifier: 55,
      bundleIdentifier: "com.example.fixture",
      displayName: "Fixture",
      appPath: "/Applications/Fixture.app"
    ))
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: nil,
    appActionPerformer: nil,
    turnLifecycle: ComputerUseTurnCoordinator(eventHandler: { _ in }),
    sessionCoordinator: sessions
  )

  let statusResponse = try decode(
    router.handle(
      try requestPayload(
        id: 23,
        type: "ComputerUseIPCCodexStatusItemMenuStateRequest",
        request: [:]
      )))
  let status = try #require(statusResponse["result"] as? [String: Any])
  let computerUse = try #require(status["computerUse"] as? [String: Any])
  #expect((computerUse["activeApplications"] as? [[String: Any]])?.count == 1)

  let stopResponse = try decode(
    router.handle(
      try requestPayload(
        id: 24,
        type: "ComputerUseIPCAppStopRequest",
        request: ["app": "com.example.fixture"]
      )))
  #expect((stopResponse["result"] as? [String: Any])?.isEmpty == true)
}

private func requestPayload(id: Int, type: String, request: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": id,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": type,
      "request": request,
    ],
  ])
}

@Test func malformedJSONReturnsStandardParseError() throws {
  let response = try decode(SkyRequestRouter(appCatalog: StubCatalog()).handle(Data("{".utf8)))
  let error = try #require(response["error"] as? [String: Any])

  #expect(response["id"] is NSNull)
  #expect(error["code"] as? Int == -32700)
}

@Test func appRequestRequiresObjectPayload() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 6,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppGetSkyshotRequest",
      "request": NSNull(),
    ],
  ])

  let response = try decode(SkyRequestRouter(appCatalog: StubCatalog()).handle(request))
  let error = try #require(response["error"] as? [String: Any])

  #expect(error["code"] as? Int == -32600)
}

@Test func getAppStateUsesObservedSkyshotEnvelope() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 4,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppGetSkyshotRequest",
      "request": ["app": "com.apple.finder", "disableDiff": false],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: StubAppStateProvider()
  )

  let response = try decode(router.handle(request))
  let result = try #require(response["result"] as? [String: Any])
  let skyshot = try #require(result["skyshot"] as? [String: Any])

  #expect(skyshot["text"] as? String == "[0] AXWindow title=\"Finder\"")
}

@Test func startAppUsesOfficialRequestTypeAndSkyshotEnvelope() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 21,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppStartRequest",
      "request": ["app": "com.example.fixture"],
    ],
  ])
  let provider = TrackingStartAppStateProvider()
  let router = SkyRequestRouter(appCatalog: StubCatalog(), appStateProvider: provider)

  let response = try decode(router.handle(request))
  let result = try #require(response["result"] as? [String: Any])
  let app = try #require(result["app"] as? [String: Any])
  let skyshot = try #require(result["skyshot"] as? [String: Any])

  #expect(provider.startRequests.count == 1)
  #expect(provider.startRequests[0]["app"] as? String == "com.example.fixture")
  #expect(app["bundleIdentifier"] as? String == "com.example.fixture")
  #expect(skyshot["text"] as? String == "[0] AXWindow title=\"Started\"")
}

@Test func defaultStartAppForcesFullInitialState() throws {
  let provider = DefaultStartAppStateProvider()
  _ = try provider.startApp(request: ["app": "com.example.fixture"])

  #expect(provider.stateRequests.count == 1)
  #expect(provider.stateRequests[0]["app"] as? String == "com.example.fixture")
  #expect(provider.stateRequests[0]["disableDiff"] as? Bool == true)
}

@Test func getAppPolicyRoutesBeforeHighLevelApproval() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 5,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppPolicyRequest",
      "request": ["app": "com.apple.finder"],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: StubAppStateProvider()
  )

  let response = try decode(router.handle(request))
  let result = try #require(response["result"] as? [String: Any])

  #expect(result["decision"] as? String == "allowed")
}

@Test func performActionUsesObservedRequestType() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 7,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "requestType": "ComputerUseIPCAppPerformActionRequest",
      "request": [
        "app": "com.apple.finder",
        "action": [
          "click": [
            "at": ["coordinate": ["_0": [100, 200]]],
            "clickCount": 1,
            "mouseButton": 0,
          ]
        ],
      ],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appActionPerformer: StubActionPerformer()
  )

  let response = try decode(router.handle(request))
  let result = try #require(response["result"] as? [String: Any])

  #expect(result.isEmpty)
}

@Test func codexTurnEndedRequestClearsMatchingTurnLifecycle() throws {
  let lifecycle = ComputerUseTurnCoordinator(eventHandler: { _ in })
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 20,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "codexTurnMetadata": [
        "session_id": "session",
        "thread_id": "thread",
        "turn_id": "turn",
      ],
      "requestType": "ComputerUseIPCCodexTurnEndedRequest",
      "request": ["threadID": "thread", "turnID": "turn"],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: nil,
    appActionPerformer: nil,
    turnLifecycle: lifecycle
  )

  let response = try decode(router.handle(request))
  let result = try #require(response["result"] as? [String: Any])

  #expect(result.isEmpty)
  #expect(lifecycle.currentIdentity == nil)
}
