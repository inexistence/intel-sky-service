import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit

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

  public func capture(
    windowID: CGWindowID,
    processIdentifier: pid_t? = nil,
    screenFrame: CGRect? = nil
  ) throws -> CapturedWindowScreenshot {
    guard CGPreflightScreenCaptureAccess() else {
      throw WindowScreenshotError.permissionRequired
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("com.openai.sky.CUAService", isDirectory: true)
      .appendingPathComponent("skyshots", isDirectory: true)
    try SecureDirectoryPreparer.prepare(directory)
    purgeExpiredScreenshots(in: directory)

    let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    if let processIdentifier, let screenFrame {
      let additionalWindowIDs =
        additionalWindowIDs(
          primaryWindowID: windowID,
          processIdentifier: processIdentifier,
          primaryFrame: screenFrame
        ) ?? []
      do {
        return try captureWithScreenCaptureKit(
          primaryWindowID: windowID,
          additionalWindowIDs: additionalWindowIDs,
          screenFrame: screenFrame,
          output: output
        )
      } catch {
        // Never drop the primary screenshot if ScreenCaptureKit is unavailable,
        // times out, or a transient window disappears during filter setup.
        try? FileManager.default.removeItem(at: output)
      }
    }

    return try captureSingleWindow(windowID: windowID, output: output)
  }

  private func captureSingleWindow(
    windowID: CGWindowID,
    output: URL
  ) throws -> CapturedWindowScreenshot {
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

  private func captureWithScreenCaptureKit(
    primaryWindowID: CGWindowID,
    additionalWindowIDs: [CGWindowID],
    screenFrame: CGRect,
    output: URL
  ) throws -> CapturedWindowScreenshot {
    guard #available(macOS 14.0, *) else { throw WindowScreenshotError.invalidImage }
    let image = try ScreenCaptureKitScreenshot.capture(
      primaryWindowID: primaryWindowID,
      additionalWindowIDs: additionalWindowIDs,
      screenFrame: screenFrame
    )
    return try write(image: image, to: output)
  }

  private func write(image: CGImage, to output: URL) throws -> CapturedWindowScreenshot {
    guard
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        "public.png" as CFString,
        1,
        nil
      )
    else {
      throw WindowScreenshotError.invalidImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: output)
      throw WindowScreenshotError.invalidImage
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    return CapturedWindowScreenshot(
      url: output,
      pixelSize: CGSize(width: image.width, height: image.height)
    )
  }

  private func additionalWindowIDs(
    primaryWindowID: CGWindowID,
    processIdentifier: pid_t,
    primaryFrame: CGRect
  ) -> [CGWindowID]? {
    guard
      let rawWindows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else {
      return nil
    }
    return Self.additionalWindowIDs(
      in: rawWindows.compactMap(WindowCaptureCandidate.init),
      primaryWindowID: primaryWindowID,
      processIdentifier: processIdentifier,
      primaryFrame: primaryFrame
    )
  }

  static func additionalWindowIDs(
    in windows: [WindowCaptureCandidate],
    primaryWindowID: CGWindowID,
    processIdentifier: pid_t,
    primaryFrame: CGRect
  ) -> [CGWindowID] {
    windows.compactMap { window in
      guard window.windowID != primaryWindowID,
        window.processIdentifier == processIdentifier,
        window.layer != 0,
        window.alpha > 0,
        window.frame.width > 1,
        window.frame.height > 1,
        window.frame.intersects(primaryFrame)
      else {
        return nil
      }
      return window.windowID
    }
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

@available(macOS 14.0, *)
private enum ScreenCaptureKitScreenshot {
  static func capture(
    primaryWindowID: CGWindowID,
    additionalWindowIDs: [CGWindowID],
    screenFrame: CGRect
  ) throws -> CGImage {
    let contentBox = SendableResultBox<SCShareableContent>()
    SCShareableContent.getExcludingDesktopWindows(
      true,
      onScreenWindowsOnly: true
    ) { content, error in
      contentBox.finish(value: content, error: error)
    }
    let content = try contentBox.wait()
    let requestedIDs = Set(additionalWindowIDs + [primaryWindowID])
    let windows = content.windows.filter { requestedIDs.contains($0.windowID) }
    guard let primaryWindow = windows.first(where: { $0.windowID == primaryWindowID }) else {
      throw WindowScreenshotError.invalidImage
    }

    let filter: SCContentFilter
    let sourceRect: CGRect?
    if additionalWindowIDs.isEmpty {
      filter = SCContentFilter(desktopIndependentWindow: primaryWindow)
      sourceRect = nil
    } else {
      guard windows.count > 1,
        let display = content.displays.first(where: { $0.frame.contains(screenFrame.center) })
      else {
        throw WindowScreenshotError.invalidImage
      }
      filter = SCContentFilter(display: display, including: windows)
      sourceRect = CGRect(
        x: screenFrame.minX - display.frame.minX,
        y: screenFrame.minY - display.frame.minY,
        width: screenFrame.width,
        height: screenFrame.height
      )
    }
    let scale = max(1, CGFloat(filter.pointPixelScale))
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(ceil(screenFrame.width * scale)))
    configuration.height = max(1, Int(ceil(screenFrame.height * scale)))
    if let sourceRect { configuration.sourceRect = sourceRect }
    configuration.showsCursor = false
    configuration.scalesToFit = false
    configuration.ignoreShadowsDisplay = true
    configuration.ignoreShadowsSingleWindow = true
    let backgroundColor = CGColor(gray: 1, alpha: 1)
    configuration.backgroundColor = backgroundColor

    let imageBox = SendableResultBox<CGImage>()
    SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    ) { image, error in
      imageBox.finish(value: image, error: error)
    }
    return try imageBox.wait()
  }
}

private final class SendableResultBox<Value>: @unchecked Sendable {
  private let condition = NSCondition()
  private var value: Value?
  private var error: Error?
  private var isFinished = false

  func finish(value: Value?, error: Error?) {
    condition.lock()
    self.value = value
    self.error = error
    isFinished = true
    condition.broadcast()
    condition.unlock()
  }

  func wait() throws -> Value {
    condition.lock()
    defer { condition.unlock() }
    let localDeadline = Date().addingTimeInterval(5)
    while !isFinished {
      _ = condition.wait(until: Date().addingTimeInterval(0.05))
      try RequestDeadlineContext.check()
      guard Date() < localDeadline else {
        throw WindowScreenshotError.captureFailed(-1, "ScreenCaptureKit screenshot timed out")
      }
    }
    if let error { throw error }
    guard let value else { throw WindowScreenshotError.invalidImage }
    return value
  }
}

extension CGRect {
  fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}

struct WindowCaptureCandidate: Sendable, Equatable {
  let windowID: CGWindowID
  let processIdentifier: pid_t
  let layer: Int
  let alpha: Double
  let frame: CGRect

  init?(_ raw: [CFString: Any]) {
    guard let windowID = raw[kCGWindowNumber] as? NSNumber,
      let processIdentifier = raw[kCGWindowOwnerPID] as? NSNumber,
      let layer = raw[kCGWindowLayer] as? NSNumber,
      let bounds = raw[kCGWindowBounds] as? [String: Any],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else {
      return nil
    }
    self.windowID = CGWindowID(windowID.uint32Value)
    self.processIdentifier = processIdentifier.int32Value
    self.layer = layer.intValue
    self.alpha = (raw[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1
    self.frame = frame
  }

  init(
    windowID: CGWindowID,
    processIdentifier: pid_t,
    layer: Int,
    alpha: Double = 1,
    frame: CGRect
  ) {
    self.windowID = windowID
    self.processIdentifier = processIdentifier
    self.layer = layer
    self.alpha = alpha
    self.frame = frame
  }
}
