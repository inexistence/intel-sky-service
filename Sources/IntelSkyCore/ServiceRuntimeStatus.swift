import Darwin
import Foundation

public struct ServiceRuntimeStatus: Codable, Equatable, Sendable {
  public let permissions: ServicePermissionStatus
  public let processIdentifier: Int32
  public let updatedAt: Date

  public init(
    permissions: ServicePermissionStatus,
    processIdentifier: Int32,
    updatedAt: Date
  ) {
    self.permissions = permissions
    self.processIdentifier = processIdentifier
    self.updatedAt = updatedAt
  }
}

public enum ServiceRuntimeStatusError: Error, CustomStringConvertible {
  case fileOperationFailed(String, String, Int32)

  public var description: String {
    switch self {
    case .fileOperationFailed(let operation, let path, let code):
      return
        "Could not \(operation) runtime status file \(path): \(String(cString: strerror(code)))"
    }
  }
}

public enum ServiceRuntimeStatusWriter {
  public static let fileName = "service-status.json"

  public static func write(
    _ status: ServiceRuntimeStatus,
    nextToSocketAt socketPath: String
  ) throws {
    let url = URL(fileURLWithPath: socketPath)
      .deletingLastPathComponent()
      .appendingPathComponent(fileName, isDirectory: false)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(status)
    let temporaryPath = url.path + ".\(UUID().uuidString).tmp"
    let descriptor = open(
      temporaryPath,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw ServiceRuntimeStatusError.fileOperationFailed("create", temporaryPath, errno)
    }
    var shouldRemoveTemporaryFile = true
    defer {
      close(descriptor)
      if shouldRemoveTemporaryFile { unlink(temporaryPath) }
    }

    try data.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          throw ServiceRuntimeStatusError.fileOperationFailed("write", temporaryPath, errno)
        }
        if count == 0 {
          throw ServiceRuntimeStatusError.fileOperationFailed("write", temporaryPath, EIO)
        }
        pointer = pointer.advanced(by: count)
        remaining -= count
      }
    }
    guard fsync(descriptor) == 0 else {
      throw ServiceRuntimeStatusError.fileOperationFailed("sync", temporaryPath, errno)
    }
    guard rename(temporaryPath, url.path) == 0 else {
      throw ServiceRuntimeStatusError.fileOperationFailed("replace", url.path, errno)
    }
    shouldRemoveTemporaryFile = false
  }
}
