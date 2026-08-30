import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IntelSkyCore

@Test func pipCoordinatorPublishesStateAndBeginsTurnScopedEnd() throws {
  let imageURL = try makePIPTestImage()
  let resizedImageURL = try makePIPTestImage(width: 3, height: 4)
  defer {
    try? FileManager.default.removeItem(at: imageURL)
    try? FileManager.default.removeItem(at: resizedImageURL)
  }
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
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.apple.finder"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.apple.finder", "pid": 123],
      "skyshot": [
        "text": "Finder refreshed",
        "screenshot": ["url": resizedImageURL.absoluteString, "mimeType": "image/png"],
      ],
    ]
  )
  #expect(capture.refreshCount == 1)
  #expect(capture.outputSize == CGSize(width: 3, height: 4))
  #expect(host.events.contains("prepare:\(presentationID):1:3x4"))
  #expect(host.events.contains("complete:\(presentationID):1"))

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

@Test func userStopInvalidatesMatchingPIPOnly() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )
  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": [
        "text": "Fixture",
        "screenshot": ["url": imageURL.absoluteString, "mimeType": "image/png"],
      ],
    ]
  )
  let presentationID = try #require(host.presentationID)

  coordinator.stopApplication(bundleIdentifier: "com.example.other")
  #expect(!capture.stopped)
  coordinator.stopApplication(bundleIdentifier: "com.example.fixture")

  #expect(capture.stopped)
  #expect(host.events.contains("invalidate:\(presentationID)"))
}

@Test func hostMaximumDisplaySizeResizesPublishedContentAndRetinaCapture() throws {
  let imageURL = try makePIPTestImage(width: 1_000, height: 500)
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )
  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )
  let presentationID = try #require(host.presentationID)

  coordinator.setMaximumDisplayDimension(200)

  #expect(host.events.contains("prepare:\(presentationID):1:200x100"))
  #expect(host.events.contains("complete:\(presentationID):1"))
  #expect(capture.outputSize == CGSize(width: 400, height: 200))
}

@Test func turnTransitionEndsPIPWithoutWaitingForExplicitEndRequest() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )
  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn-1"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )
  let first = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn-1"])
  )
  let second = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn-2"])
  )
  let presentationID = try #require(host.presentationID)

  coordinator.handle(.transitioned(from: first, to: second))
  coordinator.observe(
    requestType: "ComputerUseIPCCodexTurnEndedRequest",
    request: ["threadID": "thread", "turnID": "turn-1"],
    codexTurnMetadata: nil,
    result: [:]
  )

  #expect(host.events.filter { $0 == "will-end:\(presentationID)" }.count == 1)
}

@Test func unscopedSafetyRevocationEndsEveryPIPPresentation() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let captures = RecordingPIPCaptureFactory()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { pid, _, _ in captures.make(processIdentifier: pid) }
  )
  for (thread, turn, bundle, pid) in [
    ("thread-1", "turn-1", "com.example.one", Int32(123)),
    ("thread-2", "turn-2", "com.example.two", Int32(456)),
  ] {
    coordinator.observe(
      requestType: "ComputerUseIPCAppGetSkyshotRequest",
      request: ["app": bundle],
      codexTurnMetadata: ["thread_id": thread, "turn_id": turn],
      result: [
        "app": ["bundleIdentifier": bundle, "pid": pid],
        "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
      ]
    )
  }
  let presentationIDs = host.events.compactMap { event -> String? in
    guard event.hasPrefix("publish:") else { return nil }
    return event.split(separator: ":").dropFirst().first.map(String.init)
  }

  coordinator.handle(.safetyRevoked(.screenLocked))

  #expect(presentationIDs.count == 2)
  for presentationID in presentationIDs {
    #expect(host.events.contains("will-end:\(presentationID)"))
  }
}

@Test func appProcessReplacementUsesHostReplaceContextOperation() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let captures = RecordingPIPCaptureFactory()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { pid, _, _ in captures.make(processIdentifier: pid) }
  )
  func publish(pid: Int32) {
    coordinator.observe(
      requestType: "ComputerUseIPCAppGetSkyshotRequest",
      request: ["app": "com.example.fixture"],
      codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
      result: [
        "app": ["bundleIdentifier": "com.example.fixture", "pid": pid],
        "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
      ]
    )
  }

  publish(pid: 123)
  let presentationID = try #require(host.presentationID)
  publish(pid: 456)

  #expect(captures.capture(for: 123)?.stopped == true)
  #expect(captures.capture(for: 456)?.started == true)
  #expect(host.events.contains("replace:\(presentationID):1:2x2"))
  #expect(host.events.contains("source:456"))
  #expect(host.events.contains("complete:\(presentationID):1"))
  #expect(!host.events.contains("invalidate:\(presentationID)"))
}

@Test func hostReconnectRepublishesLivePresentationAndRefreshesCapture() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )
  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )
  let presentationID = try #require(host.presentationID)

  coordinator.hostDidReconnect()

  #expect(
    host.events.filter { $0 == "publish:\(presentationID):thread:turn:2x2" }.count == 2
  )
  #expect(host.events.filter { $0 == "source:123" }.count == 2)
  #expect(capture.refreshCount == 1)
  #expect(!capture.stopped)
}

@Test func unavailableHostDefersPresentationUntilReconnect() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller(connected: false)
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )

  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )

  #expect(host.presentationID == nil)
  #expect(!capture.started)
  host.connected = true
  coordinator.hostDidReconnect()

  let presentationID = try #require(host.presentationID)
  #expect(host.events.prefix(2) == ["publish:\(presentationID):thread:turn:2x2", "source:123"])
  #expect(capture.started)
  #expect(capture.refreshCount == 0)
}

@Test func deferredPresentationUsesReplacementProcessWhenHostReconnects() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller(connected: false)
  let captures = RecordingPIPCaptureFactory()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { pid, _, _ in captures.make(processIdentifier: pid) }
  )
  func update(pid: Int32) {
    coordinator.observe(
      requestType: "ComputerUseIPCAppGetSkyshotRequest",
      request: ["app": "com.example.fixture"],
      codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
      result: [
        "app": ["bundleIdentifier": "com.example.fixture", "pid": pid],
        "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
      ]
    )
  }

  update(pid: 123)
  update(pid: 456)
  #expect(host.presentationID == nil)
  #expect(captures.capture(for: 123)?.started == false)
  #expect(captures.capture(for: 456)?.started == false)

  host.connected = true
  coordinator.hostDidReconnect()

  #expect(host.events.contains("source:456"))
  #expect(!host.events.contains("source:123"))
  #expect(captures.capture(for: 123)?.started == false)
  #expect(captures.capture(for: 456)?.started == true)
}

@Test func disconnectBetweenConnectionCheckAndPublishKeepsPresentationPending() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  host.failNextPublishAsUnavailable()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )

  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )
  #expect(!capture.started)

  coordinator.hostDidReconnect()

  let presentationID = try #require(host.presentationID)
  #expect(
    host.events.filter { $0 == "publish:\(presentationID):thread:turn:2x2" }.count == 2
  )
  #expect(capture.started)
}

@Test func turnEndRacingHostReconnectCannotRepublishAnEndedPresentation() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )
  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )
  let presentationID = try #require(host.presentationID)
  let turn = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )
  host.setPublishHandler { coordinator.handle(.ended(turn)) }

  coordinator.hostDidReconnect()

  #expect(host.events.contains("will-end:\(presentationID)"))
  #expect(host.events.contains("invalidate:\(presentationID)"))
  #expect(capture.stopped)
  #expect(capture.refreshCount == 0)
}

@Test func turnEndRacingInitialPublishInvalidatesHostPresentation() throws {
  let imageURL = try makePIPTestImage()
  defer { try? FileManager.default.removeItem(at: imageURL) }
  let host = RecordingPIPHostCaller()
  let capture = RecordingPIPWindowCapture()
  let coordinator = RemoteHostedPIPPresentationCoordinator(
    host: host,
    captureFactory: { _, _, _ in capture }
  )
  let turn = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )
  host.setPublishHandler { coordinator.handle(.ended(turn)) }

  coordinator.observe(
    requestType: "ComputerUseIPCAppGetSkyshotRequest",
    request: ["app": "com.example.fixture"],
    codexTurnMetadata: ["thread_id": "thread", "turn_id": "turn"],
    result: [
      "app": ["bundleIdentifier": "com.example.fixture", "pid": 123],
      "skyshot": ["screenshot": ["url": imageURL.absoluteString]],
    ]
  )

  let presentationID = try #require(host.presentationID)
  #expect(host.events.contains("invalidate:\(presentationID)"))
  #expect(!capture.started)
  coordinator.hostDidReconnect()
  #expect(
    host.events.filter { $0 == "publish:\(presentationID):thread:turn:2x2" }.count == 1
  )
}

private final class RecordingPIPWindowCapture: RemoteHostedPIPWindowCapturing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var didStart = false
  private var didStop = false
  private var storedRefreshCount = 0
  private var storedOutputSize: CGSize?
  var started: Bool { lock.withLock { didStart } }
  var stopped: Bool { lock.withLock { didStop } }
  var refreshCount: Int { lock.withLock { storedRefreshCount } }
  var outputSize: CGSize? { lock.withLock { storedOutputSize } }

  func start() { lock.withLock { didStart = true } }
  func refresh(outputSize: CGSize) {
    lock.withLock {
      storedRefreshCount += 1
      storedOutputSize = outputSize
    }
  }
  func stop() { lock.withLock { didStop = true } }
}

private final class RecordingPIPCaptureFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var captures: [pid_t: RecordingPIPWindowCapture] = [:]

  func make(processIdentifier: pid_t) -> RecordingPIPWindowCapture {
    lock.withLock {
      let capture = RecordingPIPWindowCapture()
      captures[processIdentifier] = capture
      return capture
    }
  }

  func capture(for processIdentifier: pid_t) -> RecordingPIPWindowCapture? {
    lock.withLock { captures[processIdentifier] }
  }
}

private final class RecordingPIPHostCaller: RemoteHostedPIPHostCalling, @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [String] = []
  private var storedPresentationID: String?
  private var publishHandler: (() -> Void)?
  private var storedConnected: Bool
  private var publishUnavailableCount = 0
  var events: [String] { lock.withLock { storedEvents } }
  var presentationID: String? { lock.withLock { storedPresentationID } }
  var isConnected: Bool { lock.withLock { storedConnected } }
  var connected: Bool {
    get { isConnected }
    set { lock.withLock { storedConnected = newValue } }
  }

  init(connected: Bool = true) {
    storedConnected = connected
  }

  func setPublishHandler(_ handler: @escaping () -> Void) {
    lock.withLock { publishHandler = handler }
  }

  func failNextPublishAsUnavailable() {
    lock.withLock { publishUnavailableCount += 1 }
  }

  func publishPresentation(
    id: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    size: CGSize
  ) throws {
    let (handler, unavailable) = lock.withLock { () -> ((() -> Void)?, Bool) in
      storedPresentationID = id
      storedEvents.append(
        "publish:\(id):\(threadID):\(turnID):\(Int(size.width))x\(Int(size.height))")
      let unavailable = publishUnavailableCount > 0
      if unavailable { publishUnavailableCount -= 1 }
      return (publishHandler, unavailable)
    }
    if unavailable { throw RemoteHostedPIPHostCallError.unavailable }
    handler?()
  }

  func setSourceProcessIdentifier(_ pid: pid_t, presentationID: String) throws {
    lock.withLock { storedEvents.append("source:\(pid)") }
  }

  func prepareResize(
    presentationID: String,
    operationID: UInt64,
    contextID: UInt32,
    size: CGSize,
    fencePort: mach_port_t
  ) throws {
    #expect(fencePort != MACH_PORT_NULL)
    lock.withLock {
      storedEvents.append(
        "prepare:\(presentationID):\(operationID):\(Int(size.width))x\(Int(size.height))")
    }
  }

  func prepareContextReplacement(
    presentationID: String,
    operationID: UInt64,
    contextID: UInt32,
    size: CGSize,
    fencePort: mach_port_t
  ) throws {
    #expect(fencePort != MACH_PORT_NULL)
    lock.withLock {
      storedEvents.append(
        "replace:\(presentationID):\(operationID):\(Int(size.width))x\(Int(size.height))")
    }
  }

  func completeOperation(presentationID: String, operationID: UInt64) throws {
    lock.withLock { storedEvents.append("complete:\(presentationID):\(operationID)") }
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

private func makePIPTestImage(width: Int = 2, height: Int = 2) throws -> URL {
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
