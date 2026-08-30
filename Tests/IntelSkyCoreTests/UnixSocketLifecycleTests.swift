import Foundation
import Testing

@testable import IntelSkyCore

private struct EmptyLifecycleCatalog: AppCatalog {
  func listApps() throws -> [[String: Any]] { [] }
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
