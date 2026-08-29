import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol RemoteHostedPIPWindowCapturing: Sendable {
  func start()
  func stop()
}

final class RemoteHostedPIPWindowCapture: NSObject, RemoteHostedPIPWindowCapturing,
  SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
  private let lock = NSLock()
  private let processIdentifier: pid_t
  private let outputSize: CGSize
  private let surface: RemoteHostedPIPSurface
  private let sampleQueue = DispatchQueue(
    label: "dev.huangjianbin.intel-sky-service.pip-window-capture",
    qos: .userInteractive
  )
  private var stream: SCStream?
  private var startTask: Task<Void, Never>?
  private var stopped = false

  init(processIdentifier: pid_t, outputSize: CGSize, surface: RemoteHostedPIPSurface) {
    self.processIdentifier = processIdentifier
    self.outputSize = outputSize
    self.surface = surface
  }

  func start() {
    let task = lock.withLock { () -> Task<Void, Never>? in
      guard startTask == nil, stream == nil, !stopped else { return nil }
      let task = Task { [weak self] in
        guard let self else { return }
        await self.startCapture()
      }
      startTask = task
      return task
    }
    _ = task
  }

  func stop() {
    let state = lock.withLock { () -> (Task<Void, Never>?, SCStream?) in
      guard !stopped else { return (nil, nil) }
      stopped = true
      let state = (startTask, stream)
      startTask = nil
      stream = nil
      return state
    }
    state.0?.cancel()
    guard let stream = state.1 else {
      surface.resetToFallbackImage()
      return
    }
    Task { [surface] in
      try? await stream.stopCapture()
      surface.resetToFallbackImage()
    }
  }

  private func startCapture() async {
    do {
      let content = try await SCShareableContent.current
      try Task.checkCancellation()
      guard let window = Self.bestWindow(in: content.windows, processIdentifier: processIdentifier)
      else { throw CaptureError.windowUnavailable }

      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      configuration.width = max(1, Int(outputSize.width.rounded()))
      configuration.height = max(1, Int(outputSize.height.rounded()))
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.queueDepth = 5
      configuration.scalesToFit = true
      configuration.preservesAspectRatio = true
      configuration.showsCursor = false
      configuration.capturesAudio = false

      let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
      let shouldStart = lock.withLock { () -> Bool in
        guard !stopped else { return false }
        self.stream = stream
        return true
      }
      guard shouldStart else { return }
      try await stream.startCapture()
    } catch is CancellationError {
      return
    } catch {
      lock.withLock {
        startTask = nil
        stream = nil
      }
      surface.resetToFallbackImage()
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen, lock.withLock({ !stopped && self.stream === stream }) else {
      return
    }
    surface.enqueue(sampleBuffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let shouldReset = lock.withLock { () -> Bool in
      guard self.stream === stream else { return false }
      self.stream = nil
      startTask = nil
      return true
    }
    if shouldReset { surface.resetToFallbackImage() }
  }

  private static func bestWindow(in windows: [SCWindow], processIdentifier: pid_t) -> SCWindow? {
    let orderedWindowIDs =
      (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[CFString: Any]])?
      .compactMap { info -> CGWindowID? in
        guard (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier,
          (info[kCGWindowLayer] as? NSNumber)?.intValue == 0,
          let identifier = info[kCGWindowNumber] as? NSNumber
        else { return nil }
        return CGWindowID(identifier.uint32Value)
      } ?? []
    let rank = Dictionary(uniqueKeysWithValues: orderedWindowIDs.enumerated().map { ($1, $0) })
    return
      windows
      .filter {
        $0.owningApplication?.processID == processIdentifier && $0.windowLayer == 0
          && ($0.isOnScreen || $0.isActive) && $0.frame.width > 1 && $0.frame.height > 1
      }
      .min { (rank[$0.windowID] ?? Int.max) < (rank[$1.windowID] ?? Int.max) }
  }

  private enum CaptureError: Error {
    case windowUnavailable
  }
}
