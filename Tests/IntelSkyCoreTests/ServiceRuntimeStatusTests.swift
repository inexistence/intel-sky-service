import Darwin
import Foundation
import Testing

@testable import IntelSkyCore

@Test func writesOwnerOnlyRuntimeStatusNextToSocket() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let socketPath = directory.appendingPathComponent("computeruse.sock").path
  let expected = ServiceRuntimeStatus(
    permissions: ServicePermissionStatus(accessibility: true, screenRecording: false),
    processIdentifier: 42,
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )

  try ServiceRuntimeStatusWriter.write(expected, nextToSocketAt: socketPath)

  let statusURL = directory.appendingPathComponent(ServiceRuntimeStatusWriter.fileName)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(ServiceRuntimeStatus.self, from: Data(contentsOf: statusURL))
  var metadata = stat()
  #expect(lstat(statusURL.path, &metadata) == 0)
  #expect((metadata.st_mode & 0o777) == 0o600)
  #expect(decoded == expected)
}

@Test func atomicallyReplacesExistingRuntimeStatusWithoutTemporaryFiles() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let socketPath = directory.appendingPathComponent("computeruse.sock").path
  let statusURL = directory.appendingPathComponent(ServiceRuntimeStatusWriter.fileName)
  try Data("stale".utf8).write(to: statusURL)
  let expected = ServiceRuntimeStatus(
    permissions: ServicePermissionStatus(accessibility: false, screenRecording: true),
    processIdentifier: 84,
    updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
  )

  try ServiceRuntimeStatusWriter.write(expected, nextToSocketAt: socketPath)

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(ServiceRuntimeStatus.self, from: Data(contentsOf: statusURL))
  let directoryEntries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  var metadata = stat()
  #expect(lstat(statusURL.path, &metadata) == 0)
  #expect(decoded == expected)
  #expect((metadata.st_mode & 0o777) == 0o600)
  #expect(directoryEntries == [ServiceRuntimeStatusWriter.fileName])
}
