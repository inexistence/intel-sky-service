import ImageIO
import ObjectiveC.runtime
import QuartzCore

enum RemoteHostedPIPSurfaceError: Error, CustomStringConvertible {
  case contextClassUnavailable
  case contextCreationFailed
  case invalidContextIdentifier
  case invalidImage

  var description: String {
    switch self {
    case .contextClassUnavailable: return "CAContext is unavailable"
    case .contextCreationFailed: return "CAContext could not be created"
    case .invalidContextIdentifier: return "CAContext returned an invalid context identifier"
    case .invalidImage: return "PIP surface image is invalid"
    }
  }
}

final class RemoteHostedPIPSurface: @unchecked Sendable {
  private let lock = NSLock()
  private let context: NSObject
  private let rootLayer: CALayer
  let contextID: UInt32
  private(set) var size: CGSize

  init(size: CGSize) throws {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw RemoteHostedPIPSurfaceError.invalidImage
    }
    guard let contextClass = NSClassFromString("CAContext") else {
      throw RemoteHostedPIPSurfaceError.contextClassUnavailable
    }
    let factorySelector = NSSelectorFromString("localContextWithOptions:")
    guard class_getClassMethod(contextClass, factorySelector) != nil else {
      throw RemoteHostedPIPSurfaceError.contextCreationFailed
    }
    let factory = unsafeBitCast(
      contextClass,
      to: (any RemoteHostedPIPCAContextFactorySPI.Type).self
    )
    guard let context = factory.makeContext(options: nil) as? NSObject else {
      throw RemoteHostedPIPSurfaceError.contextCreationFailed
    }

    let layer = CALayer()
    layer.anchorPoint = .zero
    layer.frame = CGRect(origin: .zero, size: size)
    layer.contentsGravity = .resizeAspect
    layer.backgroundColor = CGColor(gray: 0.08, alpha: 1)

    let spi = unsafeBitCast(context, to: (any RemoteHostedPIPCAContextSPI).self)
    spi.setLayer(layer)
    let contextID = spi.contextId
    guard contextID != 0 else {
      throw RemoteHostedPIPSurfaceError.invalidContextIdentifier
    }

    self.context = context
    rootLayer = layer
    self.contextID = contextID
    self.size = size
  }

  convenience init(imageURL: URL) throws {
    let image = try Self.readImage(at: imageURL)
    try self.init(size: CGSize(width: image.width, height: image.height))
    update(image: image)
  }

  func update(imageURL: URL) throws {
    update(image: try Self.readImage(at: imageURL))
  }

  private func update(image: CGImage) {
    lock.withLock {
      let newSize = CGSize(width: image.width, height: image.height)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if size != newSize {
        size = newSize
        rootLayer.frame = CGRect(origin: .zero, size: newSize)
      }
      rootLayer.contents = image
      CATransaction.commit()
      CATransaction.flush()
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
  @objc(localContextWithOptions:)
  static func makeContext(options: [String: Any]?) -> AnyObject?
}

@objc private protocol RemoteHostedPIPCAContextSPI {
  @objc var contextId: UInt32 { get }
  @objc(setLayer:)
  func setLayer(_ layer: CALayer)
}
