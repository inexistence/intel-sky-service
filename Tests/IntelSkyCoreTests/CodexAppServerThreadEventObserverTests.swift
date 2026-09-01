import Foundation
import Testing

@testable import IntelSkyCore

@Test func appServerObserverUsesArmSocketOverrideAndCodexHomeFallback() {
  #expect(
    CodexAppServerThreadEventObserver.resolveSocketPath(
      environment: [
        "SKY_CUA_SERVICE_NATIVE_PIPE_PATH": " /tmp/arm.sock ",
        "CODEX_HOME": "/tmp/codex-home",
      ],
      homeDirectoryURL: URL(fileURLWithPath: "/tmp/home")
    ) == "/tmp/arm.sock"
  )
  #expect(
    CodexAppServerThreadEventObserver.resolveSocketPath(
      environment: ["CODEX_HOME": "/tmp/codex-home"],
      homeDirectoryURL: URL(fileURLWithPath: "/tmp/home")
    ) == "/tmp/codex-home/ipc/ipc.sock"
  )
  #expect(
    CodexAppServerThreadEventObserver.resolveSocketPath(
      environment: [:],
      homeDirectoryURL: URL(fileURLWithPath: "/tmp/home")
    ) == "/tmp/home/.codex/ipc/ipc.sock"
  )
}

@Test func appServerObserverBuildsArmInitializeRequest() throws {
  let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let data = try CodexAppServerThreadEventObserver.initializePayload(identifier: identifier)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["type"] as? String == "request")
  #expect(object["requestId"] as? String == identifier.uuidString)
  #expect(object["method"] as? String == "initialize")
  let params = try #require(object["params"] as? [String: String])
  #expect(params == ["clientType": "Codex AppServer Thread Events"])

  let response = try JSONSerialization.data(withJSONObject: [
    "type": "response",
    "requestId": identifier.uuidString,
    "method": "initialize",
    "resultType": "success",
    "result": ["clientId": "client-1"],
  ])
  #expect(
    CodexAppServerThreadEventObserver.initializeSucceeded(
      requestID: identifier.uuidString,
      data: response
    )
  )
}

@Test func appServerObserverBuildsArmThreadFollowingBroadcast() throws {
  let data = try CodexAppServerThreadEventObserver.threadFollowingPayload(threadID: "thread-1")
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["type"] as? String == "broadcast")
  #expect(object["method"] as? String == "thread-stream-following-changed")
  #expect(object["version"] as? Int == 1)
  let params = try #require(object["params"] as? [String: Any])
  #expect(params["conversationId"] as? String == "thread-1")
  #expect(params["hostId"] as? String == "local")
  #expect(params["following"] as? Bool == true)
}

@Test func appServerObserverAcceptsOnlyCompletedTurnNotificationsWithThreadIDs() throws {
  let completed = try JSONSerialization.data(withJSONObject: [
    "type": "broadcast",
    "method": "turn/completed",
    "params": ["threadId": " thread-1 ", "turn": ["id": "turn-1"]],
  ])
  #expect(CodexAppServerThreadEventObserver.completedThreadID(from: completed) == "thread-1")

  let started = try JSONSerialization.data(withJSONObject: [
    "method": "turn/started", "params": ["threadId": "thread-1"],
  ])
  #expect(CodexAppServerThreadEventObserver.completedThreadID(from: started) == nil)

  let missingThread = try JSONSerialization.data(withJSONObject: [
    "method": "turn/completed", "params": ["threadId": "  "],
  ])
  #expect(CodexAppServerThreadEventObserver.completedThreadID(from: missingThread) == nil)
}

@Test func appServerObserverRecognizesArmTurnStatusPatches() throws {
  let active = try JSONSerialization.data(withJSONObject: [
    "type": "broadcast",
    "method": "thread-stream-state-changed",
    "version": 11,
    "params": [
      "conversationId": "thread-1",
      "hostId": "local",
      "change": [
        "type": "patches",
        "patches": [["path": ["turns", "turn-1", "status"], "value": "inProgress"]],
      ],
    ],
  ])
  #expect(CodexAppServerThreadEventObserver.completedThreadID(from: active) == nil)

  let completed = try JSONSerialization.data(withJSONObject: [
    "type": "broadcast",
    "method": "thread-stream-state-changed",
    "version": 11,
    "params": [
      "conversationId": "thread-1",
      "hostId": "local",
      "change": [
        "type": "patches",
        "patches": [
          [
            "path": ["turnHistory", "history", "entitiesByKey", "turn-1", "status"],
            "value": "completed",
          ]
        ],
      ],
    ],
  ])
  #expect(CodexAppServerThreadEventObserver.completedThreadID(from: completed) == "thread-1")
}

@Test func appServerObserverAnswersArmFollowingStatusRequest() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "type": "broadcast",
    "method": "thread-stream-following-status-requested",
    "version": 1,
    "sourceClientId": "owner-1",
    "params": ["conversationId": "thread-1", "hostId": "local"],
  ])
  let status = try #require(CodexAppServerThreadEventObserver.followingStatusRequest(from: request))
  #expect(status.threadID == "thread-1")
  #expect(status.clientID == "owner-1")

  let wrongVersion = try JSONSerialization.data(withJSONObject: [
    "type": "broadcast",
    "method": "thread-stream-following-status-requested",
    "version": 2,
    "sourceClientId": "owner-1",
    "params": ["conversationId": "thread-1", "hostId": "local"],
  ])
  #expect(CodexAppServerThreadEventObserver.followingStatusRequest(from: wrongVersion) == nil)

  let response = try CodexAppServerThreadEventObserver.threadFollowingPayload(
    threadID: status.threadID,
    targetClientID: status.clientID
  )
  let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
  #expect(object["targetClientIds"] as? [String] == ["owner-1"])
}

@Test func appServerObserverDeclinesUnimplementedDiscoveryRequests() throws {
  let request = try JSONSerialization.data(withJSONObject: [
    "type": "client-discovery-request",
    "requestId": "discovery-1",
    "request": ["method": "ide-context", "params": [:]],
  ])
  let responseData = try #require(
    CodexAppServerThreadEventObserver.clientDiscoveryResponse(from: request)
  )
  let response = try #require(
    JSONSerialization.jsonObject(with: responseData) as? [String: Any]
  )
  #expect(response["type"] as? String == "client-discovery-response")
  #expect(response["requestId"] as? String == "discovery-1")
  #expect((response["response"] as? [String: Bool]) == ["canHandle": false])
}
