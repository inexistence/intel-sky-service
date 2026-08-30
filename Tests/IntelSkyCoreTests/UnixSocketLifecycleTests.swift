import Foundation
import Testing

@testable import IntelSkyCore

private struct EmptyLifecycleCatalog: AppCatalog {
  func listApps() throws -> [[String: Any]] { [] }
}

private struct AllowLifecyclePeer: PeerAuthorizing {
  func authorize(_ peer: PeerIdentity) throws {}
}

@Test func shutdownRemovesOwnedSocketAndAllowsImmediateRestart() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let socketPath = root.appendingPathComponent("computeruse.sock").path
  defer { try? FileManager.default.removeItem(at: root) }

  let first = SkyUnixServer(
    socketPath: socketPath,
    router: SkyRequestRouter(appCatalog: EmptyLifecycleCatalog())
  )
  try runThenStop(first, socketPath: socketPath)

  let second = SkyUnixServer(
    socketPath: socketPath,
    router: SkyRequestRouter(appCatalog: EmptyLifecycleCatalog())
  )
  try runThenStop(second, socketPath: socketPath)
}

@Test func managedServerWithoutPIPHostStopsAfterItsLastAuthenticatedClientDisconnects() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let socketPath = root.appendingPathComponent("computeruse.sock").path
  defer { try? FileManager.default.removeItem(at: root) }

  let server = SkyUnixServer(
    socketPath: socketPath,
    router: SkyRequestRouter(appCatalog: EmptyLifecycleCatalog()),
    authorizer: AllowLifecyclePeer(),
    shutdownAfterLastAuthenticatedClientDelay: 0.05,
    shouldShutdownWhenIdle: { true }
  )
  let ready = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    defer { finished.signal() }
    try? server.run { ready.signal() }
  }
  #expect(ready.wait(timeout: .now() + 2) == .success)

  let client = SkyUnixClient(socketPath: socketPath)
  try client.connect()
  let response = try client.request([
    "id": 1,
    "jsonrpc": "2.0",
    "method": "ping",
    "params": ["clientApiVersion": SkyProtocol.apiVersion],
  ])
  #expect(response["result"] != nil)
  client.disconnect()

  #expect(finished.wait(timeout: .now() + 2) == .success)
  #expect(server.isShuttingDown)
  let removalDeadline = Date().addingTimeInterval(1)
  while FileManager.default.fileExists(atPath: socketPath), Date() < removalDeadline {
    Thread.sleep(forTimeInterval: 0.01)
  }
  #expect(!FileManager.default.fileExists(atPath: socketPath))
}

private func runThenStop(_ server: SkyUnixServer, socketPath: String) throws {
  let ready = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    defer { finished.signal() }
    try? server.run { ready.signal() }
  }

  #expect(ready.wait(timeout: .now() + 2) == .success)
  #expect(FileManager.default.fileExists(atPath: socketPath))
  server.shutdown()
  #expect(finished.wait(timeout: .now() + 2) == .success)
  #expect(!FileManager.default.fileExists(atPath: socketPath))
}
