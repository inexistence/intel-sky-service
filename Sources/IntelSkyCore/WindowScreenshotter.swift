import CoreGraphics
import Foundation
import ImageIO

public enum WindowScreenshotError: Error, CustomStringConvertible {
  case permissionRequired
  case captureFailed(Int32, String)
  case outputMissing
  case invalidImage

  public var description: String {
    switch self {
    case .permissionRequired:
      return "Screen Recording permission is required for intel-sky-service"
    case .captureFailed(let status, let message):
      return "screencapture failed with status \(status): \(message)"
    case .outputMissing:
      return "screencapture completed without producing a PNG"
    case .invalidImage:
      return "screencapture produced a PNG without readable pixel dimensions"
    }
  }
}

public struct CapturedWindowScreenshot: Sendable, Equatable {
  public let url: URL
  public let pixelSize: CGSize

  public init(url: URL, pixelSize: CGSize) {
    self.url = url
    self.pixelSize = pixelSize
  }
}

public struct WindowScreenshotter: Sendable {
  public init() {}

  public func capture(windowID: CGWindowID) throws -> CapturedWindowScreenshot {
    guard CGPreflightScreenCaptureAccess() else {
      throw WindowScreenshotError.permissionRequired
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("intel-sky-service", isDirectory: true)
      .appendingPathComponent("skyshots", isDirectory: true)
    try SecureDirectoryPreparer.prepare(directory)
    purgeExpiredScreenshots(in: directory)

    let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l\(windowID)", "-tpng", output.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    try process.run()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      try? FileManager.default.removeItem(at: output)
      let message = String(decoding: errorData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw WindowScreenshotError.captureFailed(process.terminationStatus, message)
    }
    guard FileManager.default.fileExists(atPath: output.path) else {
      throw WindowScreenshotError.outputMissing
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width > 0,
      image.height > 0
    else {
      try? FileManager.default.removeItem(at: output)
      throw WindowScreenshotError.invalidImage
    }
    return CapturedWindowScreenshot(
      url: output,
      pixelSize: CGSize(width: image.width, height: image.height)
    )
  }

  private func purgeExpiredScreenshots(in directory: URL) {
    let expiration = Date().addingTimeInterval(-24 * 60 * 60)
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
      )
    else {
      return
    }

    for file in files where file.pathExtension.lowercased() == "png" {
      guard
        let values = try? file.resourceValues(forKeys: [
          .contentModificationDateKey, .isRegularFileKey,
        ]),
        values.isRegularFile == true,
        let modified = values.contentModificationDate,
        modified < expiration
      else {
        continue
      }
      try? FileManager.default.removeItem(at: file)
    }
  }
}
