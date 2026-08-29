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

private struct StubActionPerformer: AppActionPerforming {
  func performAction(request: [String: Any]) throws -> [String: Any] {
    [:]
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

  #expect(error["code"] as? Int == -32001)
  #expect(!SkyRequestRouter.isCompatiblePing(request))
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
