import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func removesOwnedStaleSocket() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let path = root.appendingPathComponent("computeruse.sock").path
  defer { try? FileManager.default.removeItem(at: root) }
  try SecureDirectoryPreparer.prepare(root)
  let descriptor = try bindTestSocket(at: path, listenForConnections: false)
  close(descriptor)

  try UnixSocketFilePreparer.removeStaleSocketIfSafe(at: path)

  var metadata = stat()
  #expect(lstat(path, &metadata) == -1)
  #expect(errno == ENOENT)
}

@Test func preservesActiveSocket() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let path = root.appendingPathComponent("computeruse.sock").path
  defer { try? FileManager.default.removeItem(at: root) }
  try SecureDirectoryPreparer.prepare(root)
  let descriptor = try bindTestSocket(at: path, listenForConnections: true)
  defer { close(descriptor) }

  #expect(throws: UnixSocketError.self) {
    try UnixSocketFilePreparer.removeStaleSocketIfSafe(at: path)
  }

  var metadata = stat()
  #expect(lstat(path, &metadata) == 0)
  #expect((metadata.st_mode & S_IFMT) == S_IFSOCK)
}

@Test func refusesToReplaceRegularFile() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let file = root.appendingPathComponent("computeruse.sock")
  defer { try? FileManager.default.removeItem(at: root) }
  try SecureDirectoryPreparer.prepare(root)
  try Data("keep".utf8).write(to: file)

  #expect(throws: UnixSocketError.self) {
    try UnixSocketFilePreparer.removeStaleSocketIfSafe(at: file.path)
  }

  #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
}

private func bindTestSocket(at path: String, listenForConnections: Bool) throws -> Int32 {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
  do {
    var address = try makeUnixSocketAddress(path)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, unixSocketAddressLength(path))
      }
    }
    guard result == 0 else { throw UnixSocketError.systemCall("bind", errno) }
    if listenForConnections {
      guard listen(descriptor, 1) == 0 else {
        throw UnixSocketError.systemCall("listen", errno)
      }
    }
    return descriptor
  } catch {
    close(descriptor)
    throw error
  }
}
