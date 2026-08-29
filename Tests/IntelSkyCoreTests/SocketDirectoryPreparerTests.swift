import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func createsOwnerOnlySocketDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let socketPath = root.appendingPathComponent("ipc/computeruse.sock").path

  try SecureDirectoryPreparer.prepare(URL(fileURLWithPath: socketPath).deletingLastPathComponent())

  let attributes = try FileManager.default.attributesOfItem(
    atPath: root.appendingPathComponent("ipc").path
  )
  let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  #expect(permissions & 0o777 == 0o700)
}

@Test func preservesExistingDirectoryPermissions() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let directory = root.appendingPathComponent("existing")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

  try SecureDirectoryPreparer.prepare(directory)

  let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  #expect(permissions & 0o777 == 0o755)
}

@Test func rejectsDirectoryOwnedByAnotherUser() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  #expect(throws: SecureDirectoryError.self) {
    try SecureDirectoryPreparer.prepare(root, effectiveUID: geteuid() &+ 1)
  }
}

@Test func rejectsGroupOrWorldWritableDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)

  #expect(throws: SecureDirectoryError.self) {
    try SecureDirectoryPreparer.prepare(root)
  }
}

@Test func rejectsSymbolicLinkDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let target = root.appendingPathComponent("target")
  let link = root.appendingPathComponent("link")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

  #expect(throws: SecureDirectoryError.self) {
    try SecureDirectoryPreparer.prepare(link)
  }
}
