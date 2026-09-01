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

public final class WindowScreenshotter: @unchecked Sendable {
  private struct Ownership {
    let threadID: String?
    let bundleIdentifier: String?
  }

  private let lock = NSLock()
  private var ownershipByURL: [URL: Ownership] = [:]

  public init() {}

  public func capture(
    windowID: CGWindowID,
    processIdentifier: pid_t? = nil,
    screenFrame: CGRect? = nil,
    bundleIdentifier: String? = nil
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
      guard let windows = captureCandidates(),
        Self.primaryWindowBelongsToTarget(
          in: windows,
          primaryWindowID: windowID,
          processIdentifier: processIdentifier
        )
      else {
        throw WindowScreenshotError.invalidImage
      }
      let additionalWindowIDs = Self.additionalWindowIDs(
        in: windows,
        primaryWindowID: windowID,
        processIdentifier: processIdentifier,
        primaryFrame: screenFrame
      )
      do {
        let screenshot = try captureWithScreenCaptureKit(
          primaryWindowID: windowID,
          additionalWindowIDs: additionalWindowIDs,
          processIdentifier: processIdentifier,
          screenFrame: screenFrame,
          output: output
        )
        recordOwnership(of: screenshot.url, bundleIdentifier: bundleIdentifier)
        return screenshot
      } catch {
        // Never drop the primary screenshot if ScreenCaptureKit is unavailable,
        // times out, or a transient window disappears during filter setup.
        try? FileManager.default.removeItem(at: output)
      }
    }

    let screenshot = try captureSingleWindow(windowID: windowID, output: output)
    recordOwnership(of: screenshot.url, bundleIdentifier: bundleIdentifier)
    return screenshot
  }

  func clear(threadID: String?) {
    removeOwnedScreenshots { ownership in
      threadID == nil || ownership.threadID == nil || ownership.threadID == threadID
    }
  }

  func clearUnscoped() {
    removeOwnedScreenshots { $0.threadID == nil }
  }

  func clear(bundleIdentifier: String, threadID: String?) {
    removeOwnedScreenshots { ownership in
      ownership.bundleIdentifier == bundleIdentifier
        && (threadID == nil || ownership.threadID == threadID)
    }
  }

  private func recordOwnership(of url: URL, bundleIdentifier: String?) {
    lock.withLock {
      ownershipByURL[url.standardizedFileURL] = Ownership(
        threadID: ComputerUseTurnContext.threadID,
        bundleIdentifier: bundleIdentifier
      )
    }
  }

  private func removeOwnedScreenshots(where predicate: (Ownership) -> Bool) {
    let urls = lock.withLock { () -> [URL] in
      let matches = ownershipByURL.compactMap { predicate($0.value) ? $0.key : nil }
      for url in matches { ownershipByURL.removeValue(forKey: url) }
      return matches
    }
    for url in urls { try? FileManager.default.removeItem(at: url) }
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
    processIdentifier: pid_t,
    screenFrame: CGRect,
    output: URL
  ) throws -> CapturedWindowScreenshot {
    guard #available(macOS 14.0, *) else { throw WindowScreenshotError.invalidImage }
    let image = try ScreenCaptureKitScreenshot.capture(
      primaryWindowID: primaryWindowID,
      additionalWindowIDs: additionalWindowIDs,
      processIdentifier: processIdentifier,
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

  private func captureCandidates() -> [WindowCaptureCandidate]? {
    guard
      let rawWindows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else {
      return nil
    }
    return rawWindows.compactMap(WindowCaptureCandidate.init)
  }

  static func primaryWindowBelongsToTarget(
    in windows: [WindowCaptureCandidate],
    primaryWindowID: CGWindowID,
    processIdentifier: pid_t
  ) -> Bool {
    windows.contains {
      $0.windowID == primaryWindowID && $0.processIdentifier == processIdentifier
    }
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
  private static let contentCache = ScreenCaptureShareableContentCache(maxAge: 5)

  static func capture(
    primaryWindowID: CGWindowID,
    additionalWindowIDs: [CGWindowID],
    processIdentifier: pid_t,
    screenFrame: CGRect
  ) throws -> CGImage {
    if let cachedContent = contentCache.current() {
      do {
        return try capture(
          content: cachedContent,
          primaryWindowID: primaryWindowID,
          additionalWindowIDs: additionalWindowIDs,
          processIdentifier: processIdentifier,
          screenFrame: screenFrame
        )
      } catch {
        try RequestDeadlineContext.check()
        contentCache.invalidate(cachedContent)
      }
    }

    let content = try loadShareableContent()
    contentCache.store(content)
    return try capture(
      content: content,
      primaryWindowID: primaryWindowID,
      additionalWindowIDs: additionalWindowIDs,
      processIdentifier: processIdentifier,
      screenFrame: screenFrame
    )
  }

  private static func loadShareableContent() throws -> SCShareableContent {
    let contentBox = SendableResultBox<SCShareableContent>()
    SCShareableContent.getExcludingDesktopWindows(
      true,
      onScreenWindowsOnly: true
    ) { content, error in
      contentBox.finish(value: content, error: error)
    }
    return try contentBox.wait()
  }

  private static func capture(
    content: SCShareableContent,
    primaryWindowID: CGWindowID,
    additionalWindowIDs: [CGWindowID],
    processIdentifier: pid_t,
    screenFrame: CGRect
  ) throws -> CGImage {
    let requestedIDs = Set(additionalWindowIDs + [primaryWindowID])
    let windows = content.windows.filter {
      requestedIDs.contains($0.windowID)
        && $0.owningApplication?.processID == processIdentifier
    }
    guard Set(windows.map(\.windowID)) == requestedIDs else {
      throw WindowScreenshotError.invalidImage
    }
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

@available(macOS 14.0, *)
private final class ScreenCaptureShareableContentCache: @unchecked Sendable {
  private struct Entry {
    let content: SCShareableContent
    let capturedAt: Date
  }

  private let lock = NSLock()
  private let maxAge: TimeInterval
  private var entry: Entry?

  init(maxAge: TimeInterval) {
    self.maxAge = max(0, maxAge)
  }

  func current(at date: Date = Date()) -> SCShareableContent? {
    lock.withLock {
      guard let entry, date.timeIntervalSince(entry.capturedAt) <= maxAge else { return nil }
      return entry.content
    }
  }

  func store(_ content: SCShareableContent, at date: Date = Date()) {
    lock.withLock { entry = Entry(content: content, capturedAt: date) }
  }

  func invalidate(_ content: SCShareableContent) {
    lock.withLock {
      guard entry?.content === content else { return }
      entry = nil
    }
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
