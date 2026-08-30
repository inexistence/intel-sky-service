import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ObjectiveC.runtime
import QuartzCore

@_silgen_name("CGSMainConnectionID")
private func remoteHostedPIPMainConnectionID() -> UInt32

enum RemoteHostedPIPSurfaceError: Error, CustomStringConvertible {
  case contextClassUnavailable
  case contextCreationFailed
  case invalidContextIdentifier
  case invalidImage
  case fenceUnavailable

  var description: String {
    switch self {
    case .contextClassUnavailable: return "CAContext is unavailable"
    case .contextCreationFailed: return "CAContext could not be created"
    case .invalidContextIdentifier: return "CAContext returned an invalid context identifier"
    case .invalidImage: return "PIP surface image is invalid"
    case .fenceUnavailable: return "The PIP surface could not create a transaction fence"
    }
  }
}

final class RemoteHostedPIPSurface: @unchecked Sendable {
  private static let diagnosticPatternSentinel = "/tmp/intel-sky-pip-test-pattern"

  private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
  }

  private struct LayerState: @unchecked Sendable {
    let context: NSObject
    let rootLayer: CALayer
    let imageLayer: CALayer
    let displayLayer: AVSampleBufferDisplayLayer
    let contextID: UInt32
  }

  private let lock = NSLock()
  private let context: NSObject
  private let rootLayer: CALayer
  private let imageLayer: CALayer
  private let displayLayer: AVSampleBufferDisplayLayer
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  let contextID: UInt32
  private var storedSize: CGSize
  private var dumpedDiagnosticFrame = false
  private var lastImageFrameTime: TimeInterval = 0
  private var showingDisplayFrame = false
  var size: CGSize { lock.withLock { storedSize } }
  var hasImageContents: Bool {
    Self.onMainThread { self.lock.withLock { self.imageLayer.contents != nil } }
  }
  var hasDisplayFrame: Bool { lock.withLock { showingDisplayFrame } }

  init(size: CGSize) throws {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw RemoteHostedPIPSurfaceError.invalidImage
    }
    let state = try Self.onMainThread { () throws -> LayerState in
      guard let contextClass = NSClassFromString("CAContext") else {
        throw RemoteHostedPIPSurfaceError.contextClassUnavailable
      }
      let factorySelector = NSSelectorFromString("contextWithCGSConnection:options:")
      guard class_getClassMethod(contextClass, factorySelector) != nil else {
        throw RemoteHostedPIPSurfaceError.contextCreationFailed
      }
      let factory = unsafeBitCast(
        contextClass,
        to: (any RemoteHostedPIPCAContextFactorySPI.Type).self
      )
      guard
        let context = factory.makeContext(
          connection: remoteHostedPIPMainConnectionID(),
          options: [:]
        ) as? NSObject
      else {
        throw RemoteHostedPIPSurfaceError.contextCreationFailed
      }

      let layer = CALayer()
      layer.frame = CGRect(origin: .zero, size: size)

      if FileManager.default.fileExists(atPath: Self.diagnosticPatternSentinel) {
        let colors: [CGColor] = [
          CGColor(red: 0.95, green: 0.12, blue: 0.12, alpha: 1),
          CGColor(red: 0.12, green: 0.82, blue: 0.24, alpha: 1),
          CGColor(red: 0.10, green: 0.32, blue: 0.95, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
          let stripe = CALayer()
          stripe.frame = CGRect(
            x: size.width * CGFloat(index) / CGFloat(colors.count),
            y: 0,
            width: size.width / CGFloat(colors.count),
            height: size.height
          )
          stripe.backgroundColor = color
          layer.addSublayer(stripe)
        }
      }

      let imageLayer = CALayer()
      imageLayer.frame = layer.bounds
      imageLayer.contentsGravity = .resizeAspect
      layer.addSublayer(imageLayer)

      let displayLayer = AVSampleBufferDisplayLayer()
      displayLayer.frame = layer.bounds
      displayLayer.videoGravity = .resizeAspect
      displayLayer.isHidden = true
      layer.addSublayer(displayLayer)

      let spi = unsafeBitCast(context, to: (any RemoteHostedPIPCAContextSPI).self)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      spi.setLayer(layer)
      CATransaction.commit()
      CATransaction.flush()
      let contextID = spi.contextId
      guard contextID != 0 else {
        throw RemoteHostedPIPSurfaceError.invalidContextIdentifier
      }
      return LayerState(
        context: context,
        rootLayer: layer,
        imageLayer: imageLayer,
        displayLayer: displayLayer,
        contextID: contextID
      )
    }

    context = state.context
    rootLayer = state.rootLayer
    imageLayer = state.imageLayer
    displayLayer = state.displayLayer
    contextID = state.contextID
    storedSize = size
    RemoteHostedPIPDiagnostics.logger.notice(
      "created CAContext on main thread context=\(state.contextID, privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public)"
    )
  }

  convenience init(imageURL: URL) throws {
    let image = try Self.readImage(at: imageURL)
    try self.init(size: CGSize(width: image.width, height: image.height))
    _ = update(image: image)
  }

  @discardableResult
  func update(imageURL: URL) throws -> Bool {
    update(image: try Self.readImage(at: imageURL))
  }

  private func update(image: CGImage) -> Bool {
    Self.onMainThread {
      self.lock.withLock {
        let newSize = CGSize(width: image.width, height: image.height)
        let resized = self.storedSize != newSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if resized {
          self.storedSize = newSize
          self.rootLayer.frame = CGRect(origin: .zero, size: newSize)
          self.imageLayer.frame = self.rootLayer.bounds
          self.displayLayer.frame = self.rootLayer.bounds
        }
        self.imageLayer.contents = image
        CATransaction.commit()
        CATransaction.flush()
        return resized
      }
    }
  }

  func createFencePort() throws -> mach_port_t {
    try Self.onMainThread {
      try self.lock.withLock {
        let selector = NSSelectorFromString("createFencePort")
        guard self.context.responds(to: selector) else {
          throw RemoteHostedPIPSurfaceError.fenceUnavailable
        }
        let spi = unsafeBitCast(self.context, to: (any RemoteHostedPIPCAContextSPI).self)
        let port = spi.createFencePort()
        guard port != MACH_PORT_NULL else { throw RemoteHostedPIPSurfaceError.fenceUnavailable }
        return port
      }
    }
  }

  @discardableResult
  func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    else { return false }
    dumpDiagnosticFrameIfRequested(sampleBuffer)
    guard let displaySample = Self.makeDisplaySample(from: sampleBuffer) else { return false }
    let sendableDisplaySample = SendableSampleBuffer(value: displaySample)

    Self.onMainThread {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.displayLayer.sampleBufferRenderer.enqueue(sendableDisplaySample.value)
      self.displayLayer.isHidden = false
      CATransaction.commit()
      CATransaction.flush()
      self.lock.withLock { self.showingDisplayFrame = true }
    }

    // Keep a low-rate decoded image beneath the video layer. If capture is reset, this becomes the
    // immediately visible fallback without requiring another state request.
    let now = ProcessInfo.processInfo.systemUptime
    let shouldRender = lock.withLock { () -> Bool in
      guard now - lastImageFrameTime >= 0.1 else { return false }
      lastImageFrameTime = now
      return true
    }
    guard shouldRender, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return true
    }
    let image = CIImage(cvImageBuffer: imageBuffer)
    guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return false }
    Self.onMainThread {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.imageLayer.contents = cgImage
      CATransaction.commit()
      CATransaction.flush()
    }
    return true
  }

  func resetToFallbackImage() {
    Self.onMainThread {
      self.displayLayer.sampleBufferRenderer.flush(
        removingDisplayedImage: true,
        completionHandler: nil
      )
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.displayLayer.isHidden = true
      CATransaction.commit()
      CATransaction.flush()
      self.lock.withLock { self.showingDisplayFrame = false }
    }
  }

  private static func readImage(at url: URL) throws -> CGImage {
    guard url.isFileURL,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width > 0,
      image.height > 0
    else {
      throw RemoteHostedPIPSurfaceError.invalidImage
    }
    return image
  }

  private static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: true
      ),
      CFArrayGetCount(attachments) > 0,
      let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
    else { return }
    let dictionary = unsafeBitCast(rawDictionary, to: CFMutableDictionary.self)
    CFDictionarySetValue(
      dictionary,
      Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
    )
  }

  private static func makeDisplaySample(from source: CMSampleBuffer) -> CMSampleBuffer? {
    guard let sourceImageBuffer = CMSampleBufferGetImageBuffer(source),
      let imageBuffer = makeShareableCopy(of: sourceImageBuffer)
    else { return nil }
    var formatDescription: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &formatDescription
      ) == noErr,
      let formatDescription
    else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      ) == noErr,
      let sampleBuffer
    else { return nil }
    markForImmediateDisplay(sampleBuffer)
    return sampleBuffer
  }

  private static func makeShareableCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    guard width > 0, height > 0,
      CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA
    else { return nil }

    let attributes =
      [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true as CFBoolean,
      ] as CFDictionary
    var destination: CVPixelBuffer?
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &destination
      ) == kCVReturnSuccess,
      let destination
    else { return nil }

    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    guard let sourceBase = CVPixelBufferGetBaseAddress(source),
      let destinationBase = CVPixelBufferGetBaseAddress(destination)
    else { return nil }

    let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
    let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
    let bytesToCopy = min(width * 4, sourceBytesPerRow, destinationBytesPerRow)
    for row in 0..<height {
      memcpy(
        destinationBase.advanced(by: row * destinationBytesPerRow),
        sourceBase.advanced(by: row * sourceBytesPerRow),
        bytesToCopy
      )
    }
    return destination
  }

  private func dumpDiagnosticFrameIfRequested(_ sampleBuffer: CMSampleBuffer) {
    let shouldDump = lock.withLock { () -> Bool in
      guard !dumpedDiagnosticFrame,
        FileManager.default.fileExists(atPath: Self.diagnosticPatternSentinel)
      else { return false }
      dumpedDiagnosticFrame = true
      return true
    }
    guard shouldDump, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let image = CIImage(cvImageBuffer: imageBuffer)
    let context = CIContext(options: [.cacheIntermediates: false])
    guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
    let outputURL = URL(fileURLWithPath: "/tmp/intel-sky-pip-captured-frame.png")
    try? FileManager.default.removeItem(at: outputURL)
    guard
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, cgImage, nil)
    if CGImageDestinationFinalize(destination) {
      RemoteHostedPIPDiagnostics.logger.notice(
        "wrote first captured frame to \(outputURL.path, privacy: .public)"
      )
    }
  }

  private static func onMainThread<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) rethrows -> T {
    if Thread.isMainThread { return try operation() }
    return try DispatchQueue.main.sync(execute: operation)
  }
}

@objc private protocol RemoteHostedPIPCAContextFactorySPI {
  @objc(contextWithCGSConnection:options:)
  static func makeContext(connection: UInt32, options: [String: Any]?) -> AnyObject?
}

@objc private protocol RemoteHostedPIPCAContextSPI {
  @objc var contextId: UInt32 { get }
  @objc(setLayer:)
  func setLayer(_ layer: CALayer)
  @objc(createFencePort)
  func createFencePort() -> mach_port_t
}
