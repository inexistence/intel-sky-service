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
  #expect(params == ["clientType": "desktop"])
}

@Test func appServerObserverBuildsMetadataOnlyThreadResumeSubscription() throws {
  let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let data = try CodexAppServerThreadEventObserver.threadResumePayload(
    threadID: "thread-1",
    identifier: identifier
  )
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["type"] as? String == "request")
  #expect(object["requestId"] as? String == identifier.uuidString)
  #expect(object["method"] as? String == "thread/resume")
  let params = try #require(object["params"] as? [String: Any])
  #expect(params["threadId"] as? String == "thread-1")
  #expect(params["excludeTurns"] as? Bool == true)
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
