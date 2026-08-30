import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ObjectiveC.runtime
import QuartzCore
import UniformTypeIdentifiers

@_silgen_name("CGSMainConnectionID")
private func mainConnectionID() -> UInt32

@_silgen_name("CGWindowListCreateImage")
private func legacyWindowListCreateImage(
  _ screenBounds: CGRect,
  _ listOption: CGWindowListOption,
  _ windowID: CGWindowID,
  _ imageOption: CGWindowImageOption
) -> CGImage?

@objc private protocol CAContextFactorySPI {
  @objc(contextWithCGSConnection:options:)
  static func makeContext(connection: UInt32, options: [String: Any]?) -> AnyObject?
}

@objc private protocol CAContextSPI {
  @objc var contextId: UInt32 { get }
  @objc(setLayer:)
  func setLayer(_ layer: CALayer)
}

@objc private protocol CALayerHostSPI {
  @objc var contextId: UInt32 { get set }
}

private final class RetainedProducerState {
  let context: NSObject
  let rootLayer: CALayer

  init(context: NSObject, rootLayer: CALayer) {
    self.context = context
    self.rootLayer = rootLayer
  }
}

private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
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

private func makeVideoTestSample() throws -> CMSampleBuffer {
  var pixelBuffer: CVPixelBuffer?
  let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
  guard
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      640,
      360,
      kCVPixelFormatType_32BGRA,
      attributes,
      &pixelBuffer
    ) == kCVReturnSuccess,
    let pixelBuffer
  else {
    throw SmokeError("could not create the video pixel buffer")
  }
  CVPixelBufferLockBaseAddress(pixelBuffer, [])
  if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
    let rowWords = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
    let pixels = baseAddress.assumingMemoryBound(to: UInt32.self)
    let colors: [UInt32] = [0xFFFF_2633, 0xFF40_D926, 0xFFFF_592E]
    for y in 0..<360 {
      for x in 0..<640 {
        pixels[y * rowWords + x] = colors[min(2, x * 3 / 640)]
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

  var formatDescription: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    ) == noErr,
    let formatDescription
  else {
    throw SmokeError("could not create the video format description")
  }
  var timing = CMSampleTimingInfo(
    duration: .invalid,
    presentationTimeStamp: .zero,
    decodeTimeStamp: .invalid
  )
  var sampleBuffer: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    ) == noErr,
    let sampleBuffer
  else {
    throw SmokeError("could not create the video sample buffer")
  }
  markForImmediateDisplay(sampleBuffer)
  return sampleBuffer
}

@MainActor private func runProducer(video: Bool) throws -> Never {
  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)
  application.finishLaunching()
  guard let contextClass = NSClassFromString("CAContext") else {
    throw SmokeError("CAContext is unavailable")
  }
  let factory = unsafeBitCast(contextClass, to: (any CAContextFactorySPI.Type).self)
  guard
    let context = factory.makeContext(connection: mainConnectionID(), options: [:]) as? NSObject
  else {
    throw SmokeError("CAContext creation failed")
  }
  let rootLayer = CALayer()
  rootLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
  if video {
    let displayLayer = AVSampleBufferDisplayLayer()
    displayLayer.frame = rootLayer.bounds
    rootLayer.addSublayer(displayLayer)
    displayLayer.sampleBufferRenderer.enqueue(try makeVideoTestSample())
  } else {
    let colors: [CGColor] = [
      CGColor(red: 0.95, green: 0.15, blue: 0.12, alpha: 1),
      CGColor(red: 0.15, green: 0.85, blue: 0.25, alpha: 1),
      CGColor(red: 0.12, green: 0.35, blue: 0.95, alpha: 1),
    ]
    for (index, color) in colors.enumerated() {
      let stripe = CALayer()
      stripe.frame = CGRect(x: CGFloat(index) * 640 / 3, y: 0, width: 640 / 3, height: 360)
      stripe.backgroundColor = color
      rootLayer.addSublayer(stripe)
    }
  }

  let spi = unsafeBitCast(context, to: (any CAContextSPI).self)
  spi.setLayer(rootLayer)
  CATransaction.flush()
  let retainedState = RetainedProducerState(context: context, rootLayer: rootLayer)
  withExtendedLifetime(retainedState) {
    FileHandle.standardOutput.write(Data("\(spi.contextId)\n".utf8))
    application.run()
  }
  fatalError("producer run loop returned")
}

private func readLine(from handle: FileHandle) throws -> String {
  var data = Data()
  while true {
    guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
      throw SmokeError("producer closed stdout before publishing a context")
    }
    if byte[byte.startIndex] == 0x0A { return String(decoding: data, as: UTF8.self) }
    data.append(byte)
  }
}

@MainActor private func runHost(outputURL: URL, video: Bool, producerURL: URL? = nil) throws {
  let producer = Process()
  let pipe = Pipe()
  producer.executableURL = producerURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
  producer.arguments = [video ? "--video-producer" : "--producer"]
  producer.standardOutput = pipe
  producer.standardError = FileHandle.standardError
  try producer.run()
  defer {
    producer.terminate()
    producer.waitUntilExit()
  }
  guard let contextID = UInt32(try readLine(from: pipe.fileHandleForReading)) else {
    throw SmokeError("producer returned an invalid context identifier")
  }

  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)
  application.finishLaunching()
  let window = NSWindow(
    contentRect: CGRect(x: 200, y: 200, width: 640, height: 360),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
  )
  window.title = "Intel Sky CAContext smoke"
  guard let contentView = window.contentView else { throw SmokeError("window has no content view") }
  contentView.wantsLayer = true
  contentView.layer?.backgroundColor = CGColor(gray: 0.75, alpha: 1)
  guard let hostClass = NSClassFromString("CALayerHost") as? NSObject.Type else {
    throw SmokeError("CALayerHost is unavailable")
  }
  let hostObject = hostClass.init()
  let host = unsafeBitCast(hostObject, to: (any CALayerHostSPI).self)
  host.contextId = contextID
  guard let hostLayer = hostObject as? CALayer else {
    throw SmokeError("CALayerHost is not a CALayer")
  }
  hostLayer.frame = contentView.bounds
  contentView.layer?.addSublayer(hostLayer)
  window.orderFrontRegardless()

  let deadline = Date().addingTimeInterval(1)
  while Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: deadline)
  }
  guard
    let image = legacyWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      CGWindowID(window.windowNumber),
      .boundsIgnoreFraming
    ),
    let destination = CGImageDestinationCreateWithURL(
      outputURL as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    throw SmokeError("could not capture the layer-host window")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw SmokeError("could not write the smoke image")
  }
  print("context=\(contextID) output=\(outputURL.path)")
}

private struct SmokeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.first == "--producer" || arguments.first == "--video-producer" {
    try runProducer(video: arguments.first == "--video-producer")
  } else {
    var hostArguments = arguments
    var producerURL: URL?
    if hostArguments.first == "--producer-executable" {
      guard hostArguments.count >= 2 else {
        throw SmokeError("--producer-executable requires an absolute path")
      }
      producerURL = URL(fileURLWithPath: hostArguments[1])
      guard producerURL?.path.hasPrefix("/") == true else {
        throw SmokeError("--producer-executable requires an absolute path")
      }
      hostArguments.removeFirst(2)
    }
    let video = hostArguments.first == "--video"
    let outputPath =
      (video ? hostArguments.dropFirst().first : hostArguments.first)
      ?? "/tmp/intel-sky-ca-smoke.png"
    try runHost(
      outputURL: URL(fileURLWithPath: outputPath),
      video: video,
      producerURL: producerURL
    )
  }
} catch {
  fputs("pip-layer-smoke: \(error)\n", stderr)
  exit(1)
}
