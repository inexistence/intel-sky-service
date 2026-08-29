import AVFoundation
import CoreMedia
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
  private let lock = NSLock()
  private let context: NSObject
  private let rootLayer: CALayer
  private let fallbackLayer: CALayer
  private let displayLayer: AVSampleBufferDisplayLayer
  let contextID: UInt32
  private var storedSize: CGSize
  var size: CGSize { lock.withLock { storedSize } }

  init(size: CGSize) throws {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw RemoteHostedPIPSurfaceError.invalidImage
    }
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
    layer.anchorPoint = .zero
    layer.frame = CGRect(origin: .zero, size: size)
    layer.backgroundColor = CGColor(gray: 0.08, alpha: 1)

    let fallbackLayer = CALayer()
    fallbackLayer.anchorPoint = .zero
    fallbackLayer.frame = layer.bounds
    fallbackLayer.contentsGravity = .resizeAspect
    layer.addSublayer(fallbackLayer)

    let displayLayer = AVSampleBufferDisplayLayer()
    displayLayer.anchorPoint = .zero
    displayLayer.frame = layer.bounds
    displayLayer.videoGravity = .resizeAspect
    layer.addSublayer(displayLayer)

    let spi = unsafeBitCast(context, to: (any RemoteHostedPIPCAContextSPI).self)
    spi.setLayer(layer)
    let contextID = spi.contextId
    guard contextID != 0 else {
      throw RemoteHostedPIPSurfaceError.invalidContextIdentifier
    }

    self.context = context
    rootLayer = layer
    self.fallbackLayer = fallbackLayer
    self.displayLayer = displayLayer
    self.contextID = contextID
    storedSize = size
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
    lock.withLock {
      let newSize = CGSize(width: image.width, height: image.height)
      let resized = storedSize != newSize
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if resized {
        storedSize = newSize
        rootLayer.frame = CGRect(origin: .zero, size: newSize)
        fallbackLayer.frame = rootLayer.bounds
        displayLayer.frame = rootLayer.bounds
      }
      fallbackLayer.contents = image
      fallbackLayer.isHidden = false
      CATransaction.commit()
      CATransaction.flush()
      return resized
    }
  }

  func createFencePort() throws -> mach_port_t {
    try lock.withLock {
      let selector = NSSelectorFromString("createFencePort")
      guard context.responds(to: selector) else {
        throw RemoteHostedPIPSurfaceError.fenceUnavailable
      }
      let spi = unsafeBitCast(context, to: (any RemoteHostedPIPCAContextSPI).self)
      let port = spi.createFencePort()
      guard port != MACH_PORT_NULL else { throw RemoteHostedPIPSurfaceError.fenceUnavailable }
      return port
    }
  }

  func enqueue(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    else { return }
    lock.withLock {
      if displayLayer.status == .failed {
        displayLayer.flushAndRemoveImage()
      }
      displayLayer.enqueue(sampleBuffer)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fallbackLayer.isHidden = true
      CATransaction.commit()
    }
  }

  func resetToFallbackImage() {
    lock.withLock {
      displayLayer.flushAndRemoveImage()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fallbackLayer.isHidden = false
      CATransaction.commit()
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
