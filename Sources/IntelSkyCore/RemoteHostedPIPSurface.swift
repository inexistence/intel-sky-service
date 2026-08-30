import AVFoundation
import CoreImage
import CoreMedia
import Darwin
import Foundation
import IOSurface
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

  private struct SendableIOSurface: @unchecked Sendable {
    let value: IOSurface
  }

  private struct SendableLayerContents: @unchecked Sendable {
    let value: AnyObject
    let usesCAIOSurface: Bool
  }

  private struct LayerState: @unchecked Sendable {
    let context: NSObject
    let rootLayer: CALayer
    let imageLayer: CALayer
    let displayLayer: AVSampleBufferDisplayLayer
    let cursorLayer: CALayer
    let cursorPressedLayer: CAShapeLayer
    let cursorUsesCAIOSurfaceContents: Bool
    let contextID: UInt32
  }

  private let lock = NSLock()
  private let context: NSObject
  private let rootLayer: CALayer
  private let imageLayer: CALayer
  private let displayLayer: AVSampleBufferDisplayLayer
  private let cursorLayer: CALayer
  private let cursorPressedLayer: CAShapeLayer
  private let cursorUsesCAIOSurfaceContents: Bool
  let contextID: UInt32
  private var storedSize: CGSize
  private var storedSourceSize: CGSize
  private var storedMaximumDisplayDimension: CGFloat?
  private var storedTargetBounds: CGRect?
  private var storedCursorFrame: CGRect?
  private var storedCursorVisible = false
  private var storedCursorPressed = false
  private var dumpedDiagnosticFrame = false
  private var showingDisplayFrame = false
  private var showingCAIOSurfaceContents = false
  var size: CGSize { lock.withLock { storedSize } }
  var sourceSize: CGSize { lock.withLock { storedSourceSize } }
  var captureOutputSize: CGSize {
    lock.withLock {
      let scale: CGFloat = storedMaximumDisplayDimension == nil ? 1 : 2
      return CGSize(width: storedSize.width * scale, height: storedSize.height * scale)
    }
  }
  var cursorFrame: CGRect? { lock.withLock { storedCursorFrame } }
  var isCursorVisible: Bool { lock.withLock { storedCursorVisible } }
  var isCursorPressed: Bool { lock.withLock { storedCursorPressed } }
  var hasCursorContents: Bool {
    Self.onMainThread { self.lock.withLock { self.cursorLayer.contents != nil } }
  }
  var usesCAIOSurfaceCursorContents: Bool { cursorUsesCAIOSurfaceContents }
  var hasImageContents: Bool {
    Self.onMainThread { self.lock.withLock { self.imageLayer.contents != nil } }
  }
  var hasIOSurfaceContents: Bool {
    Self.onMainThread { self.lock.withLock { self.imageLayer.contents != nil } }
  }
  var usesCAIOSurfaceContents: Bool { lock.withLock { showingCAIOSurfaceContents } }
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
      layer.masksToBounds = true
      layer.cornerRadius = min(12, min(size.width, size.height) * 0.08)
      layer.cornerCurve = .continuous

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

      let displayLayer = AVSampleBufferDisplayLayer()
      displayLayer.frame = layer.bounds
      displayLayer.videoGravity = .resizeAspect
      displayLayer.isHidden = true
      layer.addSublayer(displayLayer)

      // CAContext exports ordinary layer contents to CALayerHost. Keep that content above the local
      // AV renderer and publish IOSurface objects there; CGImage and the renderer's private backing
      // store are not reliably transported by the production remote-host path.
      let imageLayer = CALayer()
      imageLayer.frame = layer.bounds
      imageLayer.contentsGravity = .resizeAspect
      layer.addSublayer(imageLayer)

      // ARM uses a separate cursor display layer and cursor capture stream. Keep the cursor above
      // both live video and the last-frame fallback so it is exported through the same CAContext.
      let cursorPressedLayer = CAShapeLayer()
      cursorPressedLayer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
      cursorPressedLayer.path = CGPath(
        ellipseIn: cursorPressedLayer.bounds.insetBy(dx: 2, dy: 2),
        transform: nil
      )
      cursorPressedLayer.fillColor = CGColor(red: 1, green: 0.49, blue: 0.12, alpha: 0.28)
      cursorPressedLayer.strokeColor = CGColor(red: 1, green: 0.49, blue: 0.12, alpha: 0.95)
      cursorPressedLayer.lineWidth = 2
      cursorPressedLayer.isHidden = true
      layer.addSublayer(cursorPressedLayer)

      let cursorLayer = CALayer()
      cursorLayer.bounds = CGRect(x: 0, y: 0, width: 20, height: 23)
      cursorLayer.anchorPoint = CGPoint(x: 0.2, y: 0.88)
      let cursorContents = Self.softwareCursorLayerContents
      cursorLayer.contents = cursorContents?.value
      cursorLayer.contentsGravity = .resizeAspect
      cursorLayer.contentsScale = 2
      cursorLayer.shadowColor = CGColor(gray: 0, alpha: 0.55)
      cursorLayer.shadowOpacity = 0.55
      cursorLayer.shadowRadius = 1.5
      cursorLayer.shadowOffset = CGSize(width: 0, height: -1)
      cursorLayer.isHidden = true
      layer.addSublayer(cursorLayer)

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
        cursorLayer: cursorLayer,
        cursorPressedLayer: cursorPressedLayer,
        cursorUsesCAIOSurfaceContents: cursorContents?.usesCAIOSurface ?? false,
        contextID: contextID
      )
    }

    context = state.context
    rootLayer = state.rootLayer
    imageLayer = state.imageLayer
    displayLayer = state.displayLayer
    cursorLayer = state.cursorLayer
    cursorPressedLayer = state.cursorPressedLayer
    cursorUsesCAIOSurfaceContents = state.cursorUsesCAIOSurfaceContents
    contextID = state.contextID
    storedSize = size
    storedSourceSize = size
    storedMaximumDisplayDimension = nil
    storedTargetBounds = nil
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
        let sourceSize = CGSize(width: image.width, height: image.height)
        let newSize = Self.presentationSize(
          sourceSize: sourceSize,
          maximumDimension: self.storedMaximumDisplayDimension
        )
        let resized = self.storedSize != newSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.storedSourceSize = sourceSize
        if resized {
          self.storedSize = newSize
          self.resizeLayers(to: newSize)
        }
        self.imageLayer.contents = image
        CATransaction.commit()
        CATransaction.flush()
        return resized
      }
    }
  }

  @discardableResult
  func setMaximumDisplayDimension(_ maximumDimension: CGFloat?) -> Bool {
    let sanitized = maximumDimension.flatMap {
      $0.isFinite && $0 > 0 ? $0 : nil
    }
    return Self.onMainThread {
      self.lock.withLock {
        self.storedMaximumDisplayDimension = sanitized
        let newSize = Self.presentationSize(
          sourceSize: self.storedSourceSize,
          maximumDimension: sanitized
        )
        guard newSize != self.storedSize else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.storedSize = newSize
        self.resizeLayers(to: newSize)
        CATransaction.commit()
        CATransaction.flush()
        return true
      }
    }
  }

  func updateTargetBounds(_ bounds: CGRect) {
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
      return
    }
    lock.withLock { storedTargetBounds = bounds }
  }

  func updateCursor(screenPoint: CGPoint, isActive: Bool, isPressed: Bool) {
    Self.onMainThread {
      self.lock.withLock {
        guard isActive, let targetBounds = self.storedTargetBounds,
          targetBounds.contains(screenPoint)
        else {
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          self.cursorLayer.isHidden = true
          self.cursorPressedLayer.isHidden = true
          CATransaction.commit()
          CATransaction.flush()
          self.storedCursorFrame = nil
          self.storedCursorVisible = false
          self.storedCursorPressed = false
          return
        }

        let normalizedX = (screenPoint.x - targetBounds.minX) / targetBounds.width
        let normalizedY = (screenPoint.y - targetBounds.minY) / targetBounds.height
        let contentPoint = CGPoint(
          x: normalizedX * self.storedSize.width,
          y: (1 - normalizedY) * self.storedSize.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.cursorLayer.position = contentPoint
        self.cursorLayer.transform =
          isPressed
          ? CATransform3DMakeScale(0.88, 0.88, 1)
          : CATransform3DIdentity
        self.cursorLayer.isHidden = false
        self.cursorPressedLayer.position = contentPoint
        self.cursorPressedLayer.isHidden = !isPressed
        CATransaction.commit()
        CATransaction.flush()
        self.storedCursorFrame = self.cursorLayer.frame
        self.storedCursorVisible = true
        self.storedCursorPressed = isPressed
      }
    }
  }

  private func resizeLayers(to size: CGSize) {
    rootLayer.frame = CGRect(origin: .zero, size: size)
    rootLayer.cornerRadius = min(12, min(size.width, size.height) * 0.08)
    imageLayer.frame = rootLayer.bounds
    displayLayer.frame = rootLayer.bounds
  }

  private static func presentationSize(
    sourceSize: CGSize,
    maximumDimension: CGFloat?
  ) -> CGSize {
    guard let maximumDimension,
      max(sourceSize.width, sourceSize.height) > maximumDimension
    else { return sourceSize }
    let scale = maximumDimension / max(sourceSize.width, sourceSize.height)
    return CGSize(
      width: max(1, (sourceSize.width * scale).rounded()),
      height: max(1, (sourceSize.height * scale).rounded())
    )
  }

  private static let softwareCursorImage: CGImage? = {
    // Downsampled 2x rendition of the ARM Package_ComputerUse `SoftwareCursor` asset. Keeping the
    // reference pixels here makes the Intel compatibility bundle self-contained at runtime.
    let encoded = """
      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
      """
    guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }()

  private static let softwareCursorLayerContents: SendableLayerContents? = {
    guard let image = softwareCursorImage,
      let pixelBuffer = makeCursorPixelBuffer(from: image),
      let surfaceReference = CVPixelBufferGetIOSurface(pixelBuffer)
    else { return nil }
    return makeLayerContents(from: surfaceReference.takeUnretainedValue())
  }()

  static func makeCursorPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    var pixelBuffer: CVPixelBuffer?
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &pixelBuffer
      ) == kCVReturnSuccess,
      let pixelBuffer,
      CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess
    else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard
      let context = CGContext(
        data: baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
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
    guard let displaySample = Self.makeDisplaySample(from: sampleBuffer),
      let displayImageBuffer = CMSampleBufferGetImageBuffer(displaySample),
      let surfaceReference = CVPixelBufferGetIOSurface(displayImageBuffer)
    else { return false }
    let sendableDisplaySample = SendableSampleBuffer(value: displaySample)
    let sendableSurface = SendableIOSurface(value: surfaceReference.takeUnretainedValue())
    let layerContents = Self.makeLayerContents(from: sendableSurface.value)

    Self.onMainThread {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.displayLayer.sampleBufferRenderer.enqueue(sendableDisplaySample.value)
      self.displayLayer.isHidden = false
      self.imageLayer.contents = layerContents.value
      CATransaction.commit()
      CATransaction.flush()
      self.lock.withLock {
        self.showingDisplayFrame = true
        self.showingCAIOSurfaceContents = layerContents.usesCAIOSurface
      }
    }

    // The IOSurface remains the last-frame fallback if capture pauses or resets.
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

  private typealias CAIOSurfaceCreateFunction =
    @convention(c) (IOSurface) -> Unmanaged<AnyObject>?

  private static let caIOSurfaceCreate: CAIOSurfaceCreateFunction? = {
    // Keep this private QuartzCore SPI soft-linked. WebKit uses the same wrapper for layer contents
    // and falls back to the IOSurface itself when the symbol is unavailable.
    guard let handle = dlopen(nil, RTLD_LAZY),
      let symbol = dlsym(handle, "CAIOSurfaceCreate")
    else { return nil }
    return unsafeBitCast(symbol, to: CAIOSurfaceCreateFunction.self)
  }()

  private static func makeLayerContents(from surface: IOSurface) -> SendableLayerContents {
    guard let contents = caIOSurfaceCreate?(surface)?.takeRetainedValue() else {
      return SendableLayerContents(value: surface, usesCAIOSurface: false)
    }
    return SendableLayerContents(value: contents, usesCAIOSurface: true)
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
