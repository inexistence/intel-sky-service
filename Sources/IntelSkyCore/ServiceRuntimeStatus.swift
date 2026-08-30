import Darwin
import Foundation

public struct ServiceRuntimeStatus: Codable, Equatable, Sendable {
  public let permissions: ServicePermissionStatus
  public let processIdentifier: Int32
  public let physicalInputMonitoring: Bool
  public let focusStealProtection: Bool?
  public let updatedAt: Date

  public init(
    permissions: ServicePermissionStatus,
    processIdentifier: Int32,
    physicalInputMonitoring: Bool = false,
    focusStealProtection: Bool? = nil,
    updatedAt: Date
  ) {
    self.permissions = permissions
    self.processIdentifier = processIdentifier
    self.physicalInputMonitoring = physicalInputMonitoring
    self.focusStealProtection = focusStealProtection
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

  @discardableResult
  public static func removeIfCurrent(
    processIdentifier: Int32,
    nextToSocketAt socketPath: String,
    effectiveUID: uid_t = geteuid()
  ) throws -> Bool {
    let path = URL(fileURLWithPath: socketPath)
      .deletingLastPathComponent()
      .appendingPathComponent(fileName, isDirectory: false)
      .path
    var pathMetadata = stat()
    guard lstat(path, &pathMetadata) == 0 else {
      if errno == ENOENT { return false }
      throw ServiceRuntimeStatusError.fileOperationFailed("inspect", path, errno)
    }
    guard (pathMetadata.st_mode & S_IFMT) == S_IFREG, pathMetadata.st_uid == effectiveUID else {
      return false
    }

    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT || errno == ELOOP { return false }
      throw ServiceRuntimeStatusError.fileOperationFailed("open", path, errno)
    }
    defer { close(descriptor) }
    var descriptorMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0 else {
      throw ServiceRuntimeStatusError.fileOperationFailed("inspect", path, errno)
    }
    guard descriptorMetadata.st_dev == pathMetadata.st_dev,
      descriptorMetadata.st_ino == pathMetadata.st_ino,
      (descriptorMetadata.st_mode & S_IFMT) == S_IFREG,
      descriptorMetadata.st_uid == effectiveUID
    else { return false }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw ServiceRuntimeStatusError.fileOperationFailed("read", path, errno)
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard
      try decoder.decode(ServiceRuntimeStatus.self, from: data).processIdentifier
        == processIdentifier
    else { return false }

    var currentMetadata = stat()
    guard lstat(path, &currentMetadata) == 0 else {
      if errno == ENOENT { return false }
      throw ServiceRuntimeStatusError.fileOperationFailed("inspect", path, errno)
    }
    guard currentMetadata.st_dev == descriptorMetadata.st_dev,
      currentMetadata.st_ino == descriptorMetadata.st_ino,
      (currentMetadata.st_mode & S_IFMT) == S_IFREG,
      currentMetadata.st_uid == effectiveUID
    else { return false }
    guard unlink(path) == 0 else {
      if errno == ENOENT { return false }
      throw ServiceRuntimeStatusError.fileOperationFailed("remove", path, errno)
    }
    return true
  }

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
