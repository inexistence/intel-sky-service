import Darwin
import Foundation

enum SecureDirectoryError: Error, CustomStringConvertible {
  case inspectFailed(String, Int32)
  case unsafeExistingDirectory(String)

  var description: String {
    switch self {
    case .inspectFailed(let path, let code):
      return "Could not inspect directory \(path): \(String(cString: strerror(code)))"
    case .unsafeExistingDirectory(let path):
      return "Directory is not owner-controlled: \(path)"
    }
  }
}

enum SecureDirectoryPreparer {
  static func prepare(
    _ directory: URL,
    effectiveUID: uid_t = geteuid(),
    fileManager: FileManager = .default
  ) throws {
    var metadata = stat()
    if lstat(directory.path, &metadata) == 0 {
      let isDirectory = (metadata.st_mode & S_IFMT) == S_IFDIR
      let hasUnsafeWriteBits = (metadata.st_mode & 0o022) != 0
      guard isDirectory, metadata.st_uid == effectiveUID, !hasUnsafeWriteBits else {
        throw SecureDirectoryError.unsafeExistingDirectory(directory.path)
      }
      return
    }

    let inspectionError = errno
    guard inspectionError == ENOENT else {
      throw SecureDirectoryError.inspectFailed(directory.path, inspectionError)
    }
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    guard lstat(directory.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == effectiveUID,
      (metadata.st_mode & 0o077) == 0
    else {
      throw SecureDirectoryError.unsafeExistingDirectory(directory.path)
    }
  }
}
