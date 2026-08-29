import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IntelSkyCore

@Test func pipCoordinatorPublishesStateAndBeginsTurnScopedEnd() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  var coordinator: RemoteHostedPIPPresentationCoordinator? =
    RemoteHostedPIPPresentationCoordinator(
      host: host,
      captureFactory: { _, _, _ in capture }
    )

  coordinator?.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.apple.finder"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.apple.finder", "pid": 123],
      "skyshot": [
        "text": "Finder",
        "screenshot": ["url": imageURL.absoluteString, "mimeType": "image/png"],
      ],
    ]
  )

  let presentationID = try #require(host.presentationID)
  #expect(host.events.prefix(2) == ["publish:\(presentationID):thread:turn:2x2", "source:123"])
  #expect(capture.started)

  coordinator?.observe(
    requestType: "ComputerUseIPCCodexTurnEndedRequest",
    request: ["threadID": "thread", "turnID": "turn"],
    codexTurnMetadata: nil,
    result: [:]
  )
  #expect(host.events.contains("will-end:\(presentationID)"))

  coordinator = nil
  #expect(capture.stopped)
}

private final class RecordingPIPWindowCapture: RemoteHostedPIPWindowCapturing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var didStart = false
  private var didStop = false
  var started: Bool { lock.withLock { didStart } }
  var stopped: Bool { lock.withLock { didStop } }

  func start() { lock.withLock { didStart = true } }
  func stop() { lock.withLock { didStop = true } }
}

private final class RecordingPIPHostCaller: RemoteHostedPIPHostCalling, @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [String] = []
  private var storedPresentationID: String?
  var events: [String] { lock.withLock { storedEvents } }
  var presentationID: String? { lock.withLock { storedPresentationID } }

  func publishPresentation(
    id: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    size: CGSize
  ) throws {
    lock.withLock {
      storedPresentationID = id
      storedEvents.append(
        "publish:\(id):\(threadID):\(turnID):\(Int(size.width))x\(Int(size.height))")
    }
  }

  func setSourceProcessIdentifier(_ pid: pid_t, presentationID: String) throws {
    lock.withLock { storedEvents.append("source:\(pid)") }
  }

  func willEndStream(presentationID: String) throws {
    lock.withLock { storedEvents.append("will-end:\(presentationID)") }
  }

  func invalidatePresentation(id: String) throws {
    lock.withLock { storedEvents.append("invalidate:\(id)") }
  }

  func noteInteraction(presentationID: String) throws {
    lock.withLock { storedEvents.append("interaction:\(presentationID)") }
  }

  func setCursorLocation(_ point: CGPoint, isActive: Bool) throws {
    lock.withLock {
      storedEvents.append("cursor:\(Int(point.x)):\(Int(point.y)):\(isActive)")
    }
  }
}

private func makePIPTestImage() throws -> URL {
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil,
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 8,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
  let image = try #require(context.makeImage())
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("png")
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  )
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  return url
}
