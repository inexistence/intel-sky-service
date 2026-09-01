import Foundation
import Testing

@testable import IntelSkyCore

private final class SafetyLifecycleRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ComputerUseTurnLifecycleEvent] = []
  var events: [ComputerUseTurnLifecycleEvent] { lock.withLock { stored } }
  func append(_ event: ComputerUseTurnLifecycleEvent) { lock.withLock { stored.append(event) } }
}

private final class ThreadActivityRecorder: ComputerUseThreadActivityObserving,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var stored: [String] = []
  var threadIDs: [String] { lock.withLock { stored } }
  func observe(threadID: String) { lock.withLock { stored.append(threadID) } }
}

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

private final class BlockingCaptureProvider: AppCaptureProviding, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)

  func startCapture(request: [String: Any]) throws -> [String: Any] {
    ["result": "started"]
  }

  func nextCaptureUpdate(request: [String: Any]) throws -> [String: Any] {
    entered.signal()
    release.wait()
    return ["type": "completed", "app": ["bundleIdentifier": "com.apple.finder"]]
  }
}

private final class StubEventStreamProvider: EventStreamProviding, @unchecked Sendable {
  private(set) var starts: [[String: Any]] = []
  private(set) var statuses: [[String: Any]] = []
  private(set) var stops: [[String: Any]] = []

  func startEventStream(request: [String: Any]) throws -> [String: Any] {
    starts.append(request)
    return ["isRecording": true, "maxDurationSeconds": 1_800]
  }

  func eventStreamStatus(request: [String: Any]) throws -> [String: Any] {
    statuses.append(request)
    return ["isRecording": true, "maxDurationSeconds": 1_800]
  }

  func stopEventStream(request: [String: Any]) throws -> [String: Any] {
    stops.append(request)
    return [
      "isRecording": false,
      "endReason": request["reason"] as? String ?? NSNull(),
      "maxDurationSeconds": 1_800,
    ]
  }
}

private final class StubAppLifecycleProvider: AppLifecycleProviding, @unchecked Sendable {
  private(set) var frontmostRequests: [[String: Any]] = []
  private(set) var modifyRequests: [[String: Any]] = []

  func frontmostWindow(request: [String: Any]) throws -> Any {
    frontmostRequests.append(request)
    return [
      "bundleIdentifier": "com.apple.finder",
      "name": "Finder",
      "windowTitle": "Downloads",
    ]
  }

  func modifyApp(request: [String: Any]) throws -> [String: Any] {
    modifyRequests.append(request)
    return [
      "active": request["modification"] as? String == "activate",
      "currentApp": request["modification"] as? String == "activate"
        ? ["pid": 123, "bundleIdentifier": "com.apple.finder"]
        : NSNull(),
    ]
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

@Test func scopedRequestSubscribesTurnCompletionObserver() throws {
  let observer = ThreadActivityRecorder()
  let router = SkyRequestRouter(appCatalog: StubCatalog())
  router.installThreadActivityObserver(observer)

  _ = try decode(
    router.handle(
      try requestPayloadWithMetadata(
        id: 36,
        type: "ComputerUseIPCListAppsRequest",
        request: [:],
        metadata: [
          "session_id": "session", "thread_id": "thread-1", "turn_id": "turn-1",
        ]
      )))

  #expect(observer.threadIDs == ["thread-1"])
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
  let lifecycleEvents = SafetyLifecycleRecorder()
  let lifecycle = ComputerUseTurnCoordinator { lifecycleEvents.append($0) }
  let request = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 19,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "codexTurnMetadata": [
        "session_id": "session", "thread_id": "thread", "turn_id": "turn",
      ],
      "requestType": "ComputerUseIPCAppPerformActionRequest",
      "request": ["app": "com.apple.finder", "action": ["pressKey": ["_0": "Escape"]]],
    ],
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: nil,
    appActionPerformer: LockedActionPerformer(),
    turnLifecycle: lifecycle
  )

  let response = try decode(router.handle(request))
  let error = try #require(response["error"] as? [String: Any])
  #expect(error["code"] as? Int == SkyServerErrorCode.screenLocked.rawValue)
  #expect(lifecycle.currentIdentity == nil)
  #expect(lifecycleEvents.events.count == 2)
  if lifecycleEvents.events.count == 2 {
    #expect({ if case .started = lifecycleEvents.events[0] { true } else { false } }())
    #expect(
      {
        if case .safetyTerminated(_, .screenLocked) = lifecycleEvents.events[1] {
          true
        } else {
          false
        }
      }()
    )
  }
}

@Test func appServerTurnCompletionEndsOnlyTheMatchingThread() {
  let lifecycle = ComputerUseTurnCoordinator(eventHandler: { _ in })
  lifecycle.observe(metadata: [
    "session_id": "session", "thread_id": "thread", "turn_id": "turn",
  ])
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: nil,
    appActionPerformer: nil,
    turnLifecycle: lifecycle
  )

  router.codexTurnDidEnd(threadID: "other-thread")
  #expect(lifecycle.currentIdentity?.threadID == "thread")

  router.codexTurnDidEnd(threadID: "thread")
  #expect(lifecycle.currentIdentity == nil)
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

@Test func cataloguedOutOfScopeRequestsFailSafelyWithoutDispatchingProviders() throws {
  #expect(SkyProtocol.outOfScopeRequestTypes.count == 19)
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appStateProvider: StubAppStateProvider(),
    appActionPerformer: StubActionPerformer()
  )

  for requestType in SkyProtocol.outOfScopeRequestTypes.sorted() {
    let payload = try requestPayload(id: 900, type: requestType, request: [:])
    let response = try decode(router.handle(payload))
    let error = try #require(response["error"] as? [String: Any])
    #expect(error["code"] as? Int == SkyServerErrorCode.couldNotResolveRequestType.rawValue)
    #expect((error["message"] as? String)?.contains(requestType) == true)
  }
}

@Test func protocolRequestCatalogPartitionsEveryKnownARMRequest() {
  #expect(SkyProtocol.implementedRequestTypes.count == 16)
  #expect(SkyProtocol.outOfScopeRequestTypes.count == 19)
  #expect(
    SkyProtocol.implementedRequestTypes.isDisjoint(with: SkyProtocol.outOfScopeRequestTypes)
  )
  #expect(
    SkyProtocol.implementedRequestTypes.union(SkyProtocol.outOfScopeRequestTypes).count == 35
  )
}

@Test func appUsageRequestReturnsTheDiscoveredAppCatalog() throws {
  let router = SkyRequestRouter(appCatalog: StubCatalog())
  let response = try decode(
    router.handle(
      try requestPayload(
        id: 901,
        type: "ComputerUseIPCAppUsageRequest",
        request: [:]
      )))
  let result = try #require(response["result"] as? [[String: Any]])

  #expect(result.count == 1)
  #expect(result[0]["bundleIdentifier"] as? String == "com.apple.finder")
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

@Test func frontmostWindowUsesConfirmedMetadataOnlyRequestAndResultShape() throws {
  let provider = StubAppLifecycleProvider()
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appLifecycleProvider: provider
  )

  let response = try decode(
    router.handle(
      try requestPayload(
        id: 25,
        type: "ComputerUseIPCFrontmostWindowRequest",
        request: [:]
      )))
  let result = try #require(response["result"] as? [String: Any])

  #expect(provider.frontmostRequests.count == 1)
  #expect(result["bundleIdentifier"] as? String == "com.apple.finder")
  #expect(result["name"] as? String == "Finder")
  #expect(result["windowTitle"] as? String == "Downloads")
}

@Test func appModifyRoutesConfirmedActivateAndDeactivateSchema() throws {
  let provider = StubAppLifecycleProvider()
  let router = SkyRequestRouter(
    appCatalog: StubCatalog(),
    appLifecycleProvider: provider
  )

  for (index, modification) in ["activate", "deactivate"].enumerated() {
    let response = try decode(
      router.handle(
        try requestPayload(
          id: 26 + index,
          type: "ComputerUseIPCAppModifyRequest",
          request: [
            "app": "com.apple.finder",
            "modification": modification,
          ]
        )))
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["active"] as? Bool == (modification == "activate"))
    if modification == "activate" {
      let currentApp = try #require(result["currentApp"] as? [String: Any])
      #expect(currentApp["bundleIdentifier"] as? String == "com.apple.finder")
    } else {
      #expect(result["currentApp"] is NSNull)
    }
  }

  #expect(provider.modifyRequests.count == 2)
  #expect(provider.modifyRequests[0]["modification"] as? String == "activate")
  #expect(provider.modifyRequests[1]["modification"] as? String == "deactivate")
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

@Test func captureLongPollDoesNotBlockIndependentRequests() throws {
  let capture = BlockingCaptureProvider()
  let router = SkyRequestRouter(appCatalog: StubCatalog(), appCaptureProvider: capture)
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    _ = router.handle(
      try! requestPayload(
        id: 30,
        type: "ComputerUseIPCAppNextCaptureUpdateRequest",
        request: ["requestId": "capture"]
      ))
    finished.signal()
  }
  #expect(capture.entered.wait(timeout: .now() + 1) == .success)
  DispatchQueue.global().asyncAfter(deadline: .now() + 1) { capture.release.signal() }

  let started = Date()
  let response = try decode(
    router.handle(try requestPayload(id: 31, type: "ComputerUseIPCListAppsRequest", request: [:])))
  let elapsed = Date().timeIntervalSince(started)

  #expect(response["result"] is [[String: Any]])
  #expect(elapsed < 0.25)
  #expect(finished.wait(timeout: .now() + 2) == .success)
}

@Test func eventStreamRequestsRouteConfirmedStartStatusAndStopSchemas() throws {
  let provider = StubEventStreamProvider()
  let router = SkyRequestRouter(appCatalog: StubCatalog(), eventStreamProvider: provider)
  let metadata: [String: Any] = [
    "session_id": "session", "thread_id": "thread", "turn_id": "turn",
  ]

  let start = try decode(
    router.handle(
      try requestPayloadWithMetadata(
        id: 32,
        type: "ComputerUseIPCEventStreamStartRequest",
        request: [:],
        metadata: metadata
      )))
  #expect((start["result"] as? [String: Any])?["isRecording"] as? Bool == true)
  #expect(provider.starts.first?["_originatingThreadID"] as? String == "thread")

  _ = try decode(
    router.handle(
      try requestPayload(
        id: 33,
        type: "ComputerUseIPCEventStreamStatusRequest",
        request: [:]
      )))
  let stop = try decode(
    router.handle(
      try requestPayload(
        id: 34,
        type: "ComputerUseIPCEventStreamStopRequest",
        request: ["reason": "toolStopped"]
      )))

  #expect(provider.statuses.count == 1)
  #expect(provider.stops.first?["reason"] as? String == "toolStopped")
  #expect((stop["result"] as? [String: Any])?["endReason"] as? String == "toolStopped")

  let forged = try decode(
    router.handle(
      try requestPayload(
        id: 35,
        type: "ComputerUseIPCEventStreamStartRequest",
        request: ["_originatingThreadID": "forged"]
      )))
  #expect((forged["error"] as? [String: Any])?["code"] as? Int == -32600)
}

private func requestPayloadWithMetadata(
  id: Int,
  type: String,
  request: [String: Any],
  metadata: [String: Any]
) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": id,
    "method": "request",
    "params": [
      "clientApiVersion": SkyProtocol.apiVersion,
      "codexTurnMetadata": metadata,
      "requestType": type,
      "request": request,
    ],
  ])
}
