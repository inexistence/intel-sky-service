import ApplicationServices
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Drives Capture Stream refreshes from the same two native signal families used by the visual
/// runtime: Accessibility lifecycle notifications and ScreenCaptureKit frames. The stream is tiny
/// because it is only a change detector; the state provider remains the single source of AX text,
/// screenshot files, policy checks, and coordinate metadata.
public final class NativeAppCaptureChangeMonitor: NSObject, AppCaptureChangeMonitoring,
  SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
  private struct AXRegistration {
    let element: AXUIElement
    let notification: CFString
  }

  private let lock = NSLock()
  private let processIdentifier: pid_t
  private let changeHandler: @Sendable () -> Void
  private let sampleQueue = DispatchQueue(
    label: "dev.huangjianbin.intel-sky-service.capture-change-monitor",
    qos: .userInitiated
  )
  private var observer: AXObserver?
  private var observerSource: CFRunLoopSource?
  private var registrations: [AXRegistration] = []
  private var stream: SCStream?
  private var capturedWindowID: CGWindowID?
  private var started = false
  private var stopped = false
  private var reconciling = false
  private var reconcilePending = false
  private var recoveryAttempt = 0
  private var lastSignalAt = Date.distantPast
  private var signalGeneration: UInt64 = 0
  private var lastFrameSignature: UInt64?

  public init(
    processIdentifier: pid_t,
    changeHandler: @escaping @Sendable () -> Void
  ) {
    self.processIdentifier = processIdentifier
    self.changeHandler = changeHandler
  }

  deinit { stop() }

  public func start() {
    let shouldStart = lock.withLock { () -> Bool in
      guard !started, !stopped else { return false }
      started = true
      return true
    }
    guard shouldStart else { return }
    installAccessibilityObserver()
    requestReconciliation()
  }

  public func stop() {
    let state = lock.withLock {
      () -> (AXObserver?, CFRunLoopSource?, [AXRegistration], SCStream?) in
      guard !stopped else { return (nil, nil, [], nil) }
      stopped = true
      reconciling = false
      reconcilePending = false
      let state = (observer, observerSource, registrations, stream)
      observer = nil
      observerSource = nil
      registrations.removeAll()
      stream = nil
      capturedWindowID = nil
      lastFrameSignature = nil
      return state
    }
    if let observer = state.0 {
      for registration in state.2 {
        AXObserverRemoveNotification(observer, registration.element, registration.notification)
      }
    }
    if let source = state.1 {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    state.3?.stopCapture(completionHandler: nil)
  }

  private func installAccessibilityObserver() {
    var createdObserver: AXObserver?
    let result = AXObserverCreateWithInfoCallback(
      processIdentifier,
      { _, _, notification, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<NativeAppCaptureChangeMonitor>.fromOpaque(refcon)
          .takeUnretainedValue()
        monitor.accessibilityDidChange(notification: notification as String)
      },
      &createdObserver
    )
    guard result == .success, let createdObserver else { return }
    let source = AXObserverGetRunLoopSource(createdObserver)
    let accepted = lock.withLock { () -> Bool in
      guard !stopped, observer == nil else { return false }
      observer = createdObserver
      observerSource = source
      return true
    }
    guard accepted else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

    let application = AXUIElementCreateApplication(processIdentifier)
    for notification in [
      kAXFocusedWindowChangedNotification,
      kAXWindowCreatedNotification,
      kAXFocusedUIElementChangedNotification,
    ] {
      register(application, notification: notification as CFString)
    }
    registerFocusedWindow()
  }

  private func registerFocusedWindow() {
    let application = AXUIElementCreateApplication(processIdentifier)
    guard let window = Self.copyElementAttribute(
      kAXFocusedWindowAttribute as CFString,
      from: application
    ) else { return }
    for notification in [
      kAXLayoutChangedNotification,
      kAXSelectedChildrenChangedNotification,
      kAXUIElementDestroyedNotification,
      kAXMovedNotification,
      kAXResizedNotification,
      kAXTitleChangedNotification,
      kAXValueChangedNotification,
    ] {
      register(window, notification: notification as CFString)
    }
  }

  private func register(_ element: AXUIElement, notification: CFString) {
    let observer = lock.withLock { self.observer }
    guard let observer else { return }
    let alreadyRegistered = lock.withLock {
      registrations.contains {
        $0.notification == notification && CFEqual($0.element, element)
      }
    }
    guard !alreadyRegistered else { return }
    let result = AXObserverAddNotification(
      observer,
      element,
      notification,
      Unmanaged.passUnretained(self).toOpaque()
    )
    guard result == .success else { return }
    lock.withLock {
      guard !stopped else {
        AXObserverRemoveNotification(observer, element, notification)
        return
      }
      registrations.append(AXRegistration(element: element, notification: notification))
    }
  }

  private func accessibilityDidChange(notification: String) {
    signalAccessibilityChange()
    if notification == kAXFocusedWindowChangedNotification
      || notification == kAXWindowCreatedNotification
      || notification == kAXUIElementDestroyedNotification
    {
      registerFocusedWindow()
      requestReconciliation()
    }
  }

  private func requestReconciliation() {
    let shouldRequest = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      guard !reconciling else {
        reconcilePending = true
        return false
      }
      reconciling = true
      return true
    }
    guard shouldRequest else { return }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
      [weak self] content, error in
      guard let self else { return }
      guard error == nil, let content,
        let window = RemoteHostedPIPWindowCapture.bestWindow(
          in: content.windows,
          processIdentifier: self.processIdentifier
        )
      else {
        self.finishReconciliation(scheduleRecovery: true)
        return
      }
      self.reconcile(
        filter: SCContentFilter(desktopIndependentWindow: window),
        windowID: window.windowID
      )
    }
  }

  private func reconcile(filter: SCContentFilter, windowID: CGWindowID) {
    let existing = lock.withLock { () -> SCStream? in
      guard !stopped else { return nil }
      return stream
    }
    if let existing {
      let needsUpdate = lock.withLock { capturedWindowID != windowID }
      guard needsUpdate else {
        finishReconciliation()
        return
      }
      updateExistingCapture(existing, filter: filter, windowID: windowID)
      return
    }

    startCapture(filter: filter, windowID: windowID)
  }

  private func updateExistingCapture(
    _ stream: SCStream,
    filter: SCContentFilter,
    windowID: CGWindowID
  ) {
    stream.updateContentFilter(filter) { [weak self, weak stream] error in
      guard let self, let stream else { return }
      let accepted = self.lock.withLock { () -> Bool in
        guard !self.stopped, self.stream === stream, error == nil else { return false }
        self.capturedWindowID = windowID
        self.lastFrameSignature = nil
        self.recoveryAttempt = 0
        return true
      }
      if !accepted { self.discard(stream: stream) }
      self.finishReconciliation(scheduleRecovery: !accepted)
    }
  }

  private func startCapture(filter: SCContentFilter, windowID: CGWindowID) {
    let configuration = SCStreamConfiguration()
    configuration.width = 64
    configuration.height = 64
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 2
    configuration.scalesToFit = true
    configuration.preservesAspectRatio = true
    configuration.showsCursor = false
    configuration.capturesAudio = false
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    } catch {
      finishReconciliation(scheduleRecovery: true)
      return
    }
    let accepted = lock.withLock { () -> Bool in
      guard !stopped, self.stream == nil else { return false }
      self.stream = stream
      capturedWindowID = windowID
      lastFrameSignature = nil
      return true
    }
    guard accepted else {
      finishReconciliation()
      return
    }
    stream.startCapture { [weak self, weak stream] error in
      guard let self, let stream else { return }
      let accepted = self.lock.withLock { () -> Bool in
        guard !self.stopped, self.stream === stream, error == nil else { return false }
        self.recoveryAttempt = 0
        return true
      }
      if !accepted {
        self.discard(stream: stream)
      }
      self.finishReconciliation(scheduleRecovery: !accepted)
    }
  }

  private func discard(stream: SCStream) {
    let shouldStop = lock.withLock { () -> Bool in
      guard self.stream === stream else { return false }
      self.stream = nil
      capturedWindowID = nil
      lastFrameSignature = nil
      return true
    }
    if shouldStop { stream.stopCapture(completionHandler: nil) }
  }

  private func finishReconciliation(scheduleRecovery: Bool = false) {
    let outcome = lock.withLock { () -> (refresh: Bool, recoveryDelay: TimeInterval?) in
      guard !stopped else { return (false, nil) }
      reconciling = false
      if reconcilePending {
        reconcilePending = false
        return (true, nil)
      }
      guard scheduleRecovery, recoveryAttempt < 3 else { return (false, nil) }
      recoveryAttempt += 1
      return (false, 0.25 * pow(2, Double(recoveryAttempt - 1)))
    }
    if outcome.refresh {
      requestReconciliation()
    } else if let delay = outcome.recoveryDelay {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.requestReconciliation()
      }
    }
  }

  private func signalAccessibilityChange() {
    let shouldSignal = lock.withLock { !stopped }
    if shouldSignal { changeHandler() }
  }

  private func signalFrameChange() {
    let outcome = lock.withLock { () -> (immediate: Bool, generation: UInt64, delay: TimeInterval)? in
      guard !stopped else { return nil }
      let now = Date()
      signalGeneration &+= 1
      let elapsed = now.timeIntervalSince(lastSignalAt)
      guard elapsed < 0.2 else {
        lastSignalAt = now
        return (true, signalGeneration, 0)
      }
      return (false, signalGeneration, 0.2 - elapsed)
    }
    guard let outcome else { return }
    if outcome.immediate {
      changeHandler()
      return
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + outcome.delay) {
      [weak self] in
      self?.deliverDelayedFrameSignal(generation: outcome.generation)
    }
  }

  private func deliverDelayedFrameSignal(generation: UInt64) {
    let shouldSignal = lock.withLock { () -> Bool in
      guard !stopped, generation == signalGeneration else { return false }
      lastSignalAt = Date()
      return true
    }
    if shouldSignal { changeHandler() }
  }

  public func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
      CMSampleBufferDataIsReady(sampleBuffer),
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      let signature = Self.pixelSignature(pixelBuffer),
      lock.withLock({ !stopped && self.stream === stream })
    else { return }
    let changed = lock.withLock { () -> Bool in
      guard !stopped, self.stream === stream, lastFrameSignature != signature else { return false }
      lastFrameSignature = signature
      return true
    }
    if changed { signalFrameChange() }
  }

  public func stream(_ stream: SCStream, didStopWithError error: any Error) {
    discard(stream: stream)
    signalAccessibilityChange()
    finishReconciliation(scheduleRecovery: true)
  }

  private static func copyElementAttribute(
    _ attribute: CFString,
    from element: AXUIElement
  ) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  static func pixelSignature(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard !CVPixelBufferIsPlanar(pixelBuffer),
      let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
    else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let activeBytesPerRow = min(bytesPerRow, CVPixelBufferGetWidth(pixelBuffer) * 4)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var hash: UInt64 = 0xcbf29ce484222325
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for column in 0..<activeBytesPerRow {
        hash ^= UInt64(bytes[rowStart + column])
        hash &*= 0x100000001b3
      }
    }
    return hash
  }
}
