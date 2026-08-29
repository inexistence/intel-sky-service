import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol RemoteHostedPIPWindowCapturing: Sendable {
  func start()
  func refresh()
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
  private var capturedWindowID: CGWindowID?
  private var reconciling = false
  private var refreshPending = false
  private var recoveryAttempt = 0
  private var stopped = false

  init(processIdentifier: pid_t, outputSize: CGSize, surface: RemoteHostedPIPSurface) {
    self.processIdentifier = processIdentifier
    self.outputSize = outputSize
    self.surface = surface
  }

  func start() { refresh() }

  func refresh() {
    let shouldReconcile = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      guard !reconciling else {
        refreshPending = true
        return false
      }
      reconciling = true
      return true
    }
    if shouldReconcile { requestShareableContent() }
  }

  func stop() {
    let stream = lock.withLock { () -> SCStream? in
      guard !stopped else { return nil }
      stopped = true
      reconciling = false
      refreshPending = false
      capturedWindowID = nil
      let stream = self.stream
      self.stream = nil
      return stream
    }
    surface.resetToFallbackImage()
    stream?.stopCapture(completionHandler: nil)
  }

  private func requestShareableContent() {
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
      [weak self] content, error in
      guard let self else { return }
      guard error == nil, let content else {
        self.reconciliationFailed(stream: nil)
        return
      }
      self.reconcile(with: content)
    }
  }

  private func reconcile(with content: SCShareableContent) {
    guard let window = Self.bestWindow(in: content.windows, processIdentifier: processIdentifier)
    else {
      reconciliationFailed(stream: nil)
      return
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let existing = lock.withLock { () -> SCStream? in
      guard !stopped else { return nil }
      return stream
    }
    guard !lock.withLock({ stopped }) else {
      finishReconciliation()
      return
    }

    if let existing {
      guard lock.withLock({ capturedWindowID != window.windowID }) else {
        lock.withLock { recoveryAttempt = 0 }
        finishReconciliation()
        return
      }
      existing.updateContentFilter(filter) { [weak self, weak existing] error in
        guard let self, let existing else { return }
        guard error == nil else {
          self.reconciliationFailed(stream: existing)
          return
        }
        self.lock.withLock {
          guard !self.stopped, self.stream === existing else { return }
          self.capturedWindowID = window.windowID
          self.recoveryAttempt = 0
        }
        self.finishReconciliation()
      }
      return
    }

    startCapture(filter: filter, windowID: window.windowID)
  }

  private func startCapture(filter: SCContentFilter, windowID: CGWindowID) {
    let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    } catch {
      reconciliationFailed(stream: nil)
      return
    }

    let shouldStart = lock.withLock { () -> Bool in
      guard !stopped, self.stream == nil else { return false }
      self.stream = stream
      capturedWindowID = windowID
      return true
    }
    guard shouldStart else {
      finishReconciliation()
      return
    }

    stream.startCapture { [weak self, weak stream] error in
      guard let self, let stream else { return }
      guard error == nil else {
        self.reconciliationFailed(stream: stream)
        return
      }
      self.lock.withLock {
        guard !self.stopped, self.stream === stream else { return }
        self.recoveryAttempt = 0
      }
      self.finishReconciliation()
    }
  }

  private func makeConfiguration() -> SCStreamConfiguration {
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
    return configuration
  }

  private func reconciliationFailed(stream failedStream: SCStream?) {
    let state = lock.withLock { () -> (relevant: Bool, discarded: SCStream?, reset: Bool) in
      guard !stopped else { return (false, nil, false) }
      if let failedStream, stream !== failedStream { return (false, nil, false) }
      let shouldDiscard = failedStream != nil
      let discardedStream = shouldDiscard ? stream : nil
      if shouldDiscard {
        stream = nil
        capturedWindowID = nil
      }
      return (true, discardedStream, stream == nil)
    }
    guard state.relevant else { return }
    state.discarded?.stopCapture(completionHandler: nil)
    if state.reset { surface.resetToFallbackImage() }
    finishReconciliation(scheduleRecovery: true)
  }

  private func finishReconciliation(scheduleRecovery: Bool = false) {
    let outcome = lock.withLock { () -> (refresh: Bool, recoveryDelay: TimeInterval?) in
      guard !stopped else { return (false, nil) }
      reconciling = false
      if refreshPending {
        refreshPending = false
        reconciling = true
        return (true, nil)
      }
      guard scheduleRecovery, recoveryAttempt < 3 else { return (false, nil) }
      recoveryAttempt += 1
      return (false, 0.25 * pow(2, Double(recoveryAttempt - 1)))
    }
    if outcome.refresh {
      requestShareableContent()
    } else if let delay = outcome.recoveryDelay {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.refresh()
      }
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
    reconciliationFailed(stream: stream)
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
}
