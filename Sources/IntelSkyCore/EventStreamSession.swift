import AppKit
import ApplicationServices
import Carbon
@preconcurrency import CoreGraphics
import Foundation

public protocol EventStreamProviding: Sendable {
  func startEventStream(request: [String: Any]) throws -> [String: Any]
  func eventStreamStatus(request: [String: Any]) throws -> [String: Any]
  func stopEventStream(request: [String: Any]) throws -> [String: Any]
}

protocol EventStreamLifecycleHandling: ComputerUseTurnLifecycleEventHandling {
  func clientDisconnected(_ clientIdentifier: String)
  func handle(_ event: ComputerUseTurnLifecycleEvent)
  func shutdown()
}

enum EventStreamSessionError: Error, CustomStringConvertible {
  case invalidRequest(String)
  case inputMonitoringUnavailable
  case storageFailure(String)

  var description: String {
    switch self {
    case .invalidRequest(let message): return message
    case .inputMonitoringUnavailable:
      return "Input Monitoring permission is required for Event Stream recording"
    case .storageFailure(let message): return "Could not create Event Stream storage: \(message)"
    }
  }
}

public final class EventStreamSessionManager: EventStreamProviding, EventStreamLifecycleHandling,
  @unchecked Sendable
{
  private struct RecordedEvent: @unchecked Sendable {
    let type: CGEventType
    let event: CGEvent
  }

  private struct PendingRecord: @unchecked Sendable {
    let record: [String: Any]
    let suppressed: Bool
  }

  private struct BufferedRecord: @unchecked Sendable {
    var record: [String: Any]
    let contextKey: Data
  }

  static let maximumDurationSeconds = 30 * 60

  private final class Session: @unchecked Sendable {
    let identifier: String
    let owner: String
    let originatingThreadID: String?
    let directoryURL: URL
    let eventsURL: URL
    let metadataURL: URL
    let suppressedEventsURL: URL
    let startedAt: Date
    let eventsHandle: FileHandle
    let suppressedEventsHandle: FileHandle
    var eventObserverID: UUID?
    var accessibilityMonitor: NativeEventStreamAccessibilityMonitor?
    var timer: DispatchSourceTimer?
    var sequence = 0
    var eventCount = 0
    var suppressedEventCount = 0
    var endedAt: Date?
    var endReason: String?
    var mouseDownByButton: [String: MouseEndpoint] = [:]
    var seenApplicationProcesses: Set<String> = []
    var lastSelectionSignature: Data?
    var lastTerminalValue: String?
    var textBuffer: BufferedRecord?
    var textFlushTask: DispatchWorkItem?
    var textFlushGeneration = 0
    var terminalValueChangedBuffer: [String: Any]?
    var terminalValueChangedFlushTask: DispatchWorkItem?
    var terminalValueChangedFlushGeneration = 0
    var pendingAXNotificationRecords: [String: [String: Any]] = [:]
    var axNotificationDebounceTasks: [String: DispatchWorkItem] = [:]
    var axNotificationDebounceGenerations: [String: Int] = [:]
    var layoutFlushTask: DispatchWorkItem?
    var layoutFlushGeneration = 0
    var pendingRecords: [PendingRecord] = []
    var recordProcessingScheduled = false
    var lastAccessibilityRefreshAt = Date.distantPast
    var storageFailed = false

    init(
      identifier: String,
      owner: String,
      originatingThreadID: String?,
      directoryURL: URL,
      eventsURL: URL,
      metadataURL: URL,
      suppressedEventsURL: URL,
      startedAt: Date,
      eventsHandle: FileHandle,
      suppressedEventsHandle: FileHandle
    ) {
      self.identifier = identifier
      self.owner = owner
      self.originatingThreadID = originatingThreadID
      self.directoryURL = directoryURL
      self.eventsURL = eventsURL
      self.metadataURL = metadataURL
      self.suppressedEventsURL = suppressedEventsURL
      self.startedAt = startedAt
      self.eventsHandle = eventsHandle
      self.suppressedEventsHandle = suppressedEventsHandle
    }
  }

  private struct MouseEndpoint {
    let point: CGPoint
    let app: [String: Any]?
    let window: [String: Any]?
    let element: [String: Any]?

    var descriptor: [String: Any] {
      var value: [String: Any] = [:]
      if let app { value["app"] = app }
      if let window { value["window"] = window }
      if let element { value["element"] = element }
      return value
    }
  }

  private let lock = NSLock()
  private let processingQueue = DispatchQueue(
    label: "dev.huangjianbin.intel-sky-service.event-stream",
    qos: .userInitiated
  )
  private let rootDirectoryURL: URL
  private let inputMonitor: any EventStreamInputMonitoring
  private let screenLockChecker: any ScreenLockChecking
  private let accessibilitySnapshotter = AccessibilitySnapshotter()
  private let accessibilityTreeDiffer = AccessibilityTreeDiffer()
  private let usesNativeAccessibilityMonitor: Bool
  private var activeSession: Session?
  private var latestStatus: [String: Any]?

  public init(rootDirectoryURL: URL) {
    self.rootDirectoryURL = rootDirectoryURL
    inputMonitor = PhysicalInputMonitor.shared
    screenLockChecker = CGSessionScreenLockChecker()
    usesNativeAccessibilityMonitor = true
  }

  init(
    rootDirectoryURL: URL,
    inputMonitor: any EventStreamInputMonitoring,
    screenLockChecker: any ScreenLockChecking = NoopScreenLockChecker(),
    usesNativeAccessibilityMonitor: Bool = false
  ) {
    self.rootDirectoryURL = rootDirectoryURL
    self.inputMonitor = inputMonitor
    self.screenLockChecker = screenLockChecker
    self.usesNativeAccessibilityMonitor = usesNativeAccessibilityMonitor
  }

  public func startEventStream(request: [String: Any]) throws -> [String: Any] {
    guard request.keys.allSatisfy({ $0 == "_originatingThreadID" }) else {
      throw EventStreamSessionError.invalidRequest("Event Stream start request must be empty")
    }
    guard inputMonitor.isAvailable else {
      throw EventStreamSessionError.inputMonitoringUnavailable
    }
    return try lock.withLock {
      if let activeSession { return status(for: activeSession, isRecording: true) }
      do {
        try SecureDirectoryPreparer.prepare(rootDirectoryURL)
        let identifier = UUID().uuidString.lowercased()
        let directory = rootDirectoryURL.appendingPathComponent(identifier, isDirectory: true)
        try SecureDirectoryPreparer.prepare(directory)
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let suppressedURL = directory.appendingPathComponent("suppressed.jsonl")
        let eventsHandle = try Self.createOwnerOnlyFile(at: eventsURL)
        let suppressedHandle = try Self.createOwnerOnlyFile(at: suppressedURL)
        let session = Session(
          identifier: identifier,
          owner: ComputerUseClientContext.identifier,
          originatingThreadID: request["_originatingThreadID"] as? String,
          directoryURL: directory,
          eventsURL: eventsURL,
          metadataURL: metadataURL,
          suppressedEventsURL: suppressedURL,
          startedAt: Date(),
          eventsHandle: eventsHandle,
          suppressedEventsHandle: suppressedHandle
        )
        activeSession = session
        processingQueue.sync {
          appendBoundary(kind: "session.started", to: session)
          captureAccessibilityChange(for: session, buffered: false)
          writeMetadata(for: session)
        }
        guard !session.storageFailed else {
          try? session.eventsHandle.close()
          try? session.suppressedEventsHandle.close()
          activeSession = nil
          throw EventStreamSessionError.storageFailure("initial Event Stream write failed")
        }
        session.eventObserverID = inputMonitor.addEventObserver { [weak self] type, event in
          guard let copied = event.copy() else { return }
          self?.enqueue(type: type, event: copied)
        }
        if usesNativeAccessibilityMonitor {
          let monitor = NativeEventStreamAccessibilityMonitor { [weak self, weak session] notification in
            guard let self, let session else { return }
            self.processingQueue.async { [weak self, weak session] in
              guard let self, let session,
                self.lock.withLock({ self.activeSession === session })
              else { return }
              self.captureAccessibilityChange(for: session, notification: notification)
            }
          }
          session.accessibilityMonitor = monitor
          monitor.start()
        }
        installTimer(for: session)
        return status(for: session, isRecording: true)
      } catch let error as EventStreamSessionError {
        throw error
      } catch {
        throw EventStreamSessionError.storageFailure(String(describing: error))
      }
    }
  }

  public func eventStreamStatus(request: [String: Any]) throws -> [String: Any] {
    guard request.isEmpty else {
      throw EventStreamSessionError.invalidRequest("Event Stream status request must be empty")
    }
    return lock.withLock {
      if let activeSession { return status(for: activeSession, isRecording: true) }
      return latestStatus ?? emptyStatus()
    }
  }

  public func stopEventStream(request: [String: Any]) throws -> [String: Any] {
    guard request.count == 1, let reason = request["reason"] as? String,
      Self.endReasons.contains(reason)
    else {
      throw EventStreamSessionError.invalidRequest("Event Stream stop requires a valid reason")
    }
    return stop(reason: reason)
  }

  func clientDisconnected(_ clientIdentifier: String) {
    guard lock.withLock({ activeSession?.owner == clientIdentifier }) else { return }
    _ = stop(reason: "serviceTerminated")
  }

  func handle(_ event: ComputerUseTurnLifecycleEvent) {
    let endedThreadID: String?
    switch event {
    case .started: return
    case .transitioned(let from, _): endedThreadID = from.threadID
    case .ended(let identity): endedThreadID = identity.threadID
    case .safetyTerminated(let identity, _): endedThreadID = identity.threadID
    case .safetyRevoked:
      guard lock.withLock({ activeSession != nil }) else { return }
      _ = stop(reason: "toolStopped")
      return
    }
    guard lock.withLock({ activeSession?.originatingThreadID == endedThreadID }) else { return }
    _ = stop(reason: "toolStopped")
  }

  func shutdown() {
    guard lock.withLock({ activeSession != nil }) else { return }
    _ = stop(reason: "serviceTerminated")
  }

  private func enqueue(type: CGEventType, event: CGEvent) {
    let recorded = RecordedEvent(type: type, event: event)
    processingQueue.async { [weak self] in
      self?.process(type: recorded.type, event: recorded.event)
    }
  }

  private func process(type: CGEventType, event: CGEvent) {
    guard let session = lock.withLock({ activeSession }) else { return }
    do {
      try screenLockChecker.requireUnlocked()
    } catch {
      finalizeFromProcessingQueue(session, reason: "serviceTerminated")
      return
    }
    if type != .keyDown { flushTextBuffer(for: session) }
    guard let record = makeRecord(type: type, event: event, session: session) else { return }
    if Self.isBufferableTextInput(record) {
      bufferTextInput(record, for: session)
    } else {
      flushTextBuffer(for: session)
      enqueueRecord(record, suppressed: Self.shouldSuppress(record), for: session)
    }
    if session.storageFailed { finalizeFromProcessingQueue(session, reason: "serviceTerminated") }
  }

  private func makeRecord(type: CGEventType, event: CGEvent, session: Session) -> [String: Any]? {
    let targetPID = eventTargetProcessIdentifier(event)
    let app = appDescriptor(processIdentifier: targetPID)
    let window = windowDescriptor(processIdentifier: targetPID, point: event.location)
    let element = type == .keyDown
      ? focusedAccessibilityElementDescriptor(processIdentifier: targetPID)
      : accessibilityElementDescriptor(processIdentifier: targetPID, point: event.location)
    let secureInput = (app?["secureInput"] as? Bool) == true
      || element?["role"] as? String == "AXSecureTextField"
    var record = baseRecord(session: session, kind: "", app: app, window: window)

    switch type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      let button = Self.buttonName(for: type)
      session.mouseDownByButton[button] = MouseEndpoint(
        point: event.location,
        app: app,
        window: window,
        element: element
      )
      return nil
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      let button = Self.buttonName(for: type)
      let destination = MouseEndpoint(
        point: event.location,
        app: app,
        window: window,
        element: element
      )
      let origin = session.mouseDownByButton.removeValue(forKey: button)
      let distance = origin.map { hypot($0.point.x - event.location.x, $0.point.y - event.location.y) } ?? 0
      var mouse: [String: Any] = [
        "button": button,
        "modifiers": Self.modifierNames(event.flags),
      ]
      if distance >= 4, let origin {
        record["kind"] = "mouse.drag"
        mouse["origin"] = origin.descriptor
        mouse["destination"] = destination.descriptor
      } else {
        record["kind"] = button == "right" ? "mouse.context_menu" : "mouse.click"
        mouse["clickCount"] = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
        if let element { mouse["target"] = element }
      }
      record["mouse"] = mouse
      return record
    case .keyDown:
      var keyboard: [String: Any] = ["modifiers": Self.modifierNames(event.flags)]
      if let element { keyboard["target"] = element }
      let text = Self.unicodeText(event)
      let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
      if keyCode == 36 || keyCode == 76 {
        record["kind"] = "keyboard.submit"
        keyboard["keyEquivalent"] = "Return"
      } else if !Self.shortcutModifiers(event.flags).isEmpty {
        record["kind"] = "keyboard.shortcut"
        if !secureInput { keyboard["keyEquivalent"] = text ?? "keycode:\(keyCode)" }
      } else {
        record["kind"] = "keyboard.text_input"
        if !secureInput, let text, !text.isEmpty { keyboard["text"] = text }
      }
      record["keyboard"] = keyboard
      return record
    default:
      return nil
    }
  }

  private func baseRecord(
    session: Session,
    kind: String,
    app: [String: Any]?,
    window: [String: Any]?
  ) -> [String: Any] {
    var record: [String: Any] = [
      "id": session.sequence,
      "timestamp": Self.dateString(Date()),
      "kind": kind,
    ]
    session.sequence += 1
    if let app { record["app"] = app }
    if let window { record["window"] = window }
    return record
  }

  private func appendBoundary(kind: String, to session: Session) {
    append(baseRecord(session: session, kind: kind, app: nil, window: nil), suppressed: false, to: session)
  }

  private func append(_ record: [String: Any], suppressed: Bool, to session: Session) {
    let storedRecord = suppressed ? Self.redactedRecord(record) : Self.scrubSecrets(in: record)
    guard let data = try? JSONSerialization.data(withJSONObject: storedRecord, options: [.sortedKeys]) else {
      return
    }
    var line = data
    line.append(0x0A)
    do {
      if suppressed {
        try session.suppressedEventsHandle.write(contentsOf: line)
        session.suppressedEventCount += 1
      } else {
        try session.eventsHandle.write(contentsOf: line)
        session.eventCount += 1
      }
    } catch {
      session.storageFailed = true
    }
  }

  private static func isBufferableTextInput(_ record: [String: Any]) -> Bool {
    guard record["kind"] as? String == "keyboard.text_input",
      let keyboard = record["keyboard"] as? [String: Any],
      let text = keyboard["text"] as? String,
      !text.isEmpty
    else { return false }
    return !shouldSuppress(record)
  }

  private static func textInputContextKey(_ record: [String: Any]) -> Data? {
    guard var keyboard = record["keyboard"] as? [String: Any] else { return nil }
    keyboard.removeValue(forKey: "text")
    var context: [String: Any] = ["keyboard": keyboard]
    if let app = record["app"] { context["app"] = app }
    if let window = record["window"] { context["window"] = window }
    return try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
  }

  private func bufferTextInput(_ record: [String: Any], for session: Session) {
    guard let contextKey = Self.textInputContextKey(record),
      let keyboard = record["keyboard"] as? [String: Any],
      let text = keyboard["text"] as? String
    else {
      enqueueRecord(record, suppressed: Self.shouldSuppress(record), for: session)
      return
    }
    if var buffered = session.textBuffer, buffered.contextKey == contextKey,
      var bufferedKeyboard = buffered.record["keyboard"] as? [String: Any]
    {
      bufferedKeyboard["text"] = (bufferedKeyboard["text"] as? String ?? "") + text
      buffered.record["keyboard"] = bufferedKeyboard
      session.textBuffer = buffered
      // ARM allocates one EventStreamRecordIdentity for the whole text buffer.
      session.sequence -= 1
    } else {
      flushTextBuffer(for: session)
      session.textBuffer = BufferedRecord(record: record, contextKey: contextKey)
    }
    scheduleTextFlush(for: session)
  }

  private func scheduleTextFlush(for session: Session) {
    session.textFlushTask?.cancel()
    session.textFlushGeneration += 1
    let generation = session.textFlushGeneration
    let task = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session,
        self.lock.withLock({ self.activeSession === session }),
        session.textFlushGeneration == generation
      else { return }
      self.flushTextBuffer(for: session)
      self.drainPendingRecords(for: session)
    }
    session.textFlushTask = task
    processingQueue.asyncAfter(deadline: .now() + 0.75, execute: task)
  }

  private func flushTextBuffer(for session: Session) {
    session.textFlushTask?.cancel()
    session.textFlushTask = nil
    guard let buffered = session.textBuffer else { return }
    session.textBuffer = nil
    enqueueRecord(
      buffered.record,
      suppressed: Self.shouldSuppress(buffered.record),
      for: session
    )
  }

  private func bufferTerminalValueChanged(_ record: [String: Any], for session: Session) {
    session.terminalValueChangedBuffer = record
    session.terminalValueChangedFlushTask?.cancel()
    session.terminalValueChangedFlushGeneration += 1
    let generation = session.terminalValueChangedFlushGeneration
    let task = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session,
        self.lock.withLock({ self.activeSession === session }),
        session.terminalValueChangedFlushGeneration == generation
      else { return }
      self.flushTerminalValueChangedBuffer(for: session)
      self.drainPendingRecords(for: session)
    }
    session.terminalValueChangedFlushTask = task
    processingQueue.asyncAfter(deadline: .now() + 0.75, execute: task)
  }

  private func flushTerminalValueChangedBuffer(for session: Session) {
    session.terminalValueChangedFlushTask?.cancel()
    session.terminalValueChangedFlushTask = nil
    guard let record = session.terminalValueChangedBuffer else { return }
    session.terminalValueChangedBuffer = nil
    enqueueRecord(record, suppressed: Self.shouldSuppress(record), for: session)
  }

  private func bufferAXNotificationRecord(
    _ record: [String: Any],
    key: String,
    for session: Session
  ) {
    session.pendingAXNotificationRecords[key] = record
    if key.hasPrefix("window:") || key.hasPrefix("sensitive:") {
      scheduleLayoutFlush(for: session)
      return
    }
    session.axNotificationDebounceTasks[key]?.cancel()
    let generation = (session.axNotificationDebounceGenerations[key] ?? 0) + 1
    session.axNotificationDebounceGenerations[key] = generation
    let task = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session,
        self.lock.withLock({ self.activeSession === session }),
        session.axNotificationDebounceGenerations[key] == generation
      else { return }
      self.flushAXNotificationRecord(key: key, for: session)
      self.drainPendingRecords(for: session)
    }
    session.axNotificationDebounceTasks[key] = task
    let delay = key.hasPrefix("selectedText:") ? 0.5 : 0.25
    processingQueue.asyncAfter(deadline: .now() + delay, execute: task)
  }

  private func scheduleLayoutFlush(for session: Session) {
    session.layoutFlushTask?.cancel()
    session.layoutFlushGeneration += 1
    let generation = session.layoutFlushGeneration
    let task = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session,
        self.lock.withLock({ self.activeSession === session }),
        session.layoutFlushGeneration == generation
      else { return }
      let keys = session.pendingAXNotificationRecords.keys.filter {
        $0.hasPrefix("window:") || $0.hasPrefix("sensitive:")
      }.sorted()
      for key in keys { self.flushAXNotificationRecord(key: key, for: session) }
      session.layoutFlushTask = nil
      self.drainPendingRecords(for: session)
    }
    session.layoutFlushTask = task
    processingQueue.asyncAfter(deadline: .now() + 0.25, execute: task)
  }

  private func flushAXNotificationRecord(key: String, for session: Session) {
    session.axNotificationDebounceTasks.removeValue(forKey: key)?.cancel()
    session.axNotificationDebounceGenerations.removeValue(forKey: key)
    guard let record = session.pendingAXNotificationRecords.removeValue(forKey: key) else { return }
    enqueueRecord(record, suppressed: Self.shouldSuppress(record), for: session)
  }

  private func enqueueRecord(_ record: [String: Any], suppressed: Bool, for session: Session) {
    session.pendingRecords.append(PendingRecord(record: record, suppressed: suppressed))
    guard !session.recordProcessingScheduled else { return }
    session.recordProcessingScheduled = true
    processingQueue.async { [weak self, weak session] in
      guard let self, let session,
        self.lock.withLock({ self.activeSession === session })
      else { return }
      self.drainPendingRecords(for: session)
    }
  }

  private func drainPendingRecords(
    for session: Session,
    terminateOnStorageFailure: Bool = true
  ) {
    session.recordProcessingScheduled = false
    let pending = session.pendingRecords
    session.pendingRecords.removeAll(keepingCapacity: true)
    for item in pending {
      append(item.record, suppressed: item.suppressed, to: session)
    }
    if terminateOnStorageFailure, session.storageFailed,
      lock.withLock({ activeSession === session })
    {
      finalizeFromProcessingQueue(session, reason: "serviceTerminated")
    }
  }

  /// Mirrors ARM EventStreamRecorder.flushPendingRecords(): text, Terminal, AX, then service writes.
  private func flushPendingRecords(for session: Session) {
    flushTextBuffer(for: session)
    flushTerminalValueChangedBuffer(for: session)
    let keys = session.pendingAXNotificationRecords.keys.sorted()
    for key in keys { flushAXNotificationRecord(key: key, for: session) }
    drainPendingRecords(for: session, terminateOnStorageFailure: false)
  }

  static func shouldSuppress(_ record: [String: Any]) -> Bool {
    if containsSecureTextField(record) { return true }
    guard let app = record["app"] as? [String: Any] else { return false }
    if app["secureInput"] as? Bool == true { return true }
    guard let bundle = (app["bundleIdentifier"] as? String)?.lowercased() else { return false }
    return Self.sensitiveBundlePrefixes.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
  }

  private static func containsSecureTextField(_ value: Any) -> Bool {
    if let dictionary = value as? [String: Any] {
      if dictionary["role"] as? String == "AXSecureTextField" { return true }
      return dictionary.values.contains(where: containsSecureTextField)
    }
    if let array = value as? [Any] { return array.contains(where: containsSecureTextField) }
    return false
  }

  static func redactedRecord(_ record: [String: Any]) -> [String: Any] {
    redact(record, key: nil) as? [String: Any] ?? [:]
  }

  static func scrubSecrets(in record: [String: Any]) -> [String: Any] {
    scrub(record) as? [String: Any] ?? [:]
  }

  private static func scrub(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] { return dictionary.mapValues(scrub) }
    if let array = value as? [Any] { return array.map(scrub) }
    guard let string = value as? String else { return value }
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    return secretPattern.stringByReplacingMatches(
      in: string,
      range: range,
      withTemplate: "$1$2[REDACTED]"
    )
  }

  private static func redact(_ value: Any, key: String?) -> Any {
    if let key, sensitiveContentKeys.contains(key) { return "[REDACTED]" }
    if let dictionary = value as? [String: Any] {
      var result: [String: Any] = [:]
      for (childKey, child) in dictionary {
        result[childKey] = redact(child, key: childKey)
      }
      return result
    }
    if let array = value as? [Any] { return array.map { redact($0, key: key) } }
    return value
  }

  private func eventTargetProcessIdentifier(_ event: CGEvent) -> pid_t? {
    let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
    if target > 0 { return target }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  private func captureAccessibilityChange(
    for session: Session,
    buffered: Bool = true,
    notification: String? = nil
  ) {
    session.lastAccessibilityRefreshAt = Date()
    guard let running = NSWorkspace.shared.frontmostApplication, !running.isTerminated else { return }
    let processIdentifier = running.processIdentifier
    let app = appDescriptor(processIdentifier: processIdentifier)
    let window = windowDescriptor(processIdentifier: processIdentifier, point: .zero)
    if let app, Self.shouldSuppress(["app": app]) {
      let key = "sensitive:\(processIdentifier):\(window?["windowID"] ?? "none")"
      guard session.seenApplicationProcesses.insert(key).inserted else { return }
      var record = baseRecord(session: session, kind: "window.changed", app: app, window: window)
      record["ax"] = ["mode": "fullTree", "text": "[REDACTED]"]
      if buffered {
        bufferAXNotificationRecord(record, key: key, for: session)
      } else {
        append(record, suppressed: true, to: session)
      }
      return
    }
    let resolved = ResolvedMacApp(
      processIdentifier: processIdentifier,
      bundleIdentifier: running.bundleIdentifier ?? "pid:\(processIdentifier)",
      displayName: running.localizedName ?? "Unknown",
      appPath: running.bundleURL?.path ?? ""
    )
    guard let snapshot = try? accessibilitySnapshotter.capture(app: resolved) else { return }
    let firstForProcess = session.seenApplicationProcesses.insert(
      "\(resolved.bundleIdentifier):\(processIdentifier)"
    ).inserted
    let rawText = accessibilityTreeDiffer.output(
      for: snapshot,
      app: resolved,
      disableDiff: firstForProcess
    )
    guard firstForProcess || !rawText.hasPrefix("There has been no change") else { return }
    let containsSecureTextField = rawText.contains("AXSecureTextField")
    let text = Self.redactSecureAXLines(rawText)
    var record = baseRecord(session: session, kind: "window.changed", app: app, window: window)
    record["ax"] = [
      "mode": firstForProcess ? "fullTree" : "diffFromPrevious",
      "text": text,
    ]
    let recordKey = "window:\(resolved.bundleIdentifier):\(processIdentifier):\(window?["windowID"] ?? "none")"
    if buffered {
      bufferAXNotificationRecord(record, key: recordKey, for: session)
    } else {
      append(record, suppressed: containsSecureTextField, to: session)
    }
    guard !containsSecureTextField else { return }
    captureSelectionAndTerminalChanges(
      for: session,
      application: running,
      app: app,
      window: window,
      buffered: buffered,
      notification: notification
    )
  }

  private func captureSelectionAndTerminalChanges(
    for session: Session,
    application: NSRunningApplication,
    app: [String: Any]?,
    window: [String: Any]?,
    buffered: Bool,
    notification: String?
  ) {
    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let focused = Self.copyAXElement(
      applicationElement,
      attribute: kAXFocusedUIElementAttribute
    ) else { return }
    let target = Self.axElementDescriptor(focused)
    var selection: [String: Any] = ["target": target, "selectedItems": []]
    if target["role"] as? String != "AXSecureTextField" {
      if let selectedText = Self.copyAXAttribute(
        focused,
        attribute: kAXSelectedTextAttribute
      ) as? String, !selectedText.isEmpty {
        selection["selectedText"] = String(selectedText.prefix(2_000))
      }
      if let rangeValue = Self.copyAXAttribute(
        focused,
        attribute: kAXSelectedTextRangeAttribute
      ), CFGetTypeID(rangeValue) == AXValueGetTypeID() {
        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        var range = CFRange()
        if AXValueGetType(axValue) == .cfRange,
          AXValueGetValue(axValue, .cfRange, &range)
        {
          selection["selectedRange"] = ["location": range.location, "length": range.length]
        }
      }
      if let children = Self.copyAXAttribute(
        focused,
        attribute: kAXSelectedChildrenAttribute
      ) as? [Any] {
        selection["selectedItems"] = children.compactMap { child -> [String: Any]? in
          let reference = child as CFTypeRef
          guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
          return Self.axElementDescriptor(unsafeDowncast(reference, to: AXUIElement.self))
        }
      }
    }
    let signature = try? JSONSerialization.data(withJSONObject: selection, options: [.sortedKeys])
    if let previous = session.lastSelectionSignature, signature != previous {
      var record = baseRecord(session: session, kind: "selection.changed", app: app, window: window)
      record["selection"] = selection
      if buffered {
        let prefix = notification == kAXSelectedTextChangedNotification
          || notification == nil ? "selectedText" : "selection"
        let key = "\(prefix):\(application.processIdentifier):\(window?["windowID"] ?? "none")"
        bufferAXNotificationRecord(record, key: key, for: session)
      } else {
        append(record, suppressed: Self.shouldSuppress(record), to: session)
      }
    }
    session.lastSelectionSignature = signature

    let terminalBundles = ["com.apple.Terminal", "com.googlecode.iterm2"]
    guard let bundleIdentifier = application.bundleIdentifier,
      terminalBundles.contains(bundleIdentifier),
      let currentValue = Self.copyAXAttribute(focused, attribute: kAXValueAttribute) as? String
    else {
      session.lastTerminalValue = nil
      return
    }
    if let previous = session.lastTerminalValue, currentValue != previous {
      let delta = currentValue.hasPrefix(previous)
        ? String(currentValue.dropFirst(previous.count).suffix(2_000))
        : "[terminal content changed]"
      var record = baseRecord(
        session: session,
        kind: "terminal.value_changed",
        app: app,
        window: window
      )
      record["keyboard"] = ["text": delta, "modifiers": [], "target": target]
      if buffered {
        bufferTerminalValueChanged(record, for: session)
      } else {
        append(record, suppressed: Self.shouldSuppress(record), to: session)
      }
    }
    session.lastTerminalValue = currentValue
  }

  private func appDescriptor(processIdentifier: pid_t?) -> [String: Any]? {
    guard let processIdentifier,
      let application = NSRunningApplication(processIdentifier: processIdentifier)
    else { return nil }
    var value: [String: Any] = [
      "secureInput": IsSecureEventInputEnabled(),
      "processIdentifier": Int(processIdentifier),
    ]
    if let name = application.localizedName { value["name"] = name }
    if let bundleIdentifier = application.bundleIdentifier {
      value["bundleIdentifier"] = bundleIdentifier
    }
    return value
  }

  private func windowDescriptor(processIdentifier: pid_t?, point: CGPoint) -> [String: Any]? {
    guard let processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]],
      let window = windows.first(where: { raw in
        guard (raw[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier,
          (raw[kCGWindowLayer] as? NSNumber)?.intValue == 0,
          let bounds = raw[kCGWindowBounds] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return false }
        return frame.contains(point)
      }) ?? windows.first(where: { raw in
        (raw[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier
          && (raw[kCGWindowLayer] as? NSNumber)?.intValue == 0
      })
    else { return nil }
    var value: [String: Any] = [:]
    if let title = window[kCGWindowName] as? String, !title.isEmpty { value["title"] = title }
    if let identifier = window[kCGWindowNumber] as? NSNumber {
      value["windowID"] = identifier.uint32Value
    }
    if let url = focusedWindowURL(processIdentifier: processIdentifier) { value["url"] = url }
    return value
  }

  private func focusedWindowURL(processIdentifier: pid_t) -> String? {
    let application = AXUIElementCreateApplication(processIdentifier)
    guard let window = Self.copyAXElement(application, attribute: kAXFocusedWindowAttribute),
      let raw = Self.copyAXAttribute(window, attribute: kAXDocumentAttribute) as? String,
      var components = URLComponents(string: raw),
      ["http", "https"].contains(components.scheme?.lowercased() ?? "")
    else { return nil }
    components.user = nil
    components.password = nil
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.string
  }

  private func accessibilityElementDescriptor(
    processIdentifier: pid_t?,
    point: CGPoint
  ) -> [String: Any]? {
    guard let processIdentifier else { return nil }
    let application = AXUIElementCreateApplication(processIdentifier)
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
      == .success, let element
    else {
      return Self.copyAXElement(application, attribute: kAXFocusedUIElementAttribute)
        .map(Self.axElementDescriptor)
    }
    return Self.axElementDescriptor(element)
  }

  private func focusedAccessibilityElementDescriptor(
    processIdentifier: pid_t?
  ) -> [String: Any]? {
    guard let processIdentifier else { return nil }
    let application = AXUIElementCreateApplication(processIdentifier)
    return Self.copyAXElement(application, attribute: kAXFocusedUIElementAttribute)
      .map(Self.axElementDescriptor)
  }

  private static func axElementDescriptor(_ element: AXUIElement) -> [String: Any] {
    var value: [String: Any] = [:]
    let fields: [(String, String)] = [
      ("role", kAXRoleAttribute),
      ("subrole", kAXSubroleAttribute),
      ("title", kAXTitleAttribute),
      ("description", kAXDescriptionAttribute),
      ("placeholder", kAXPlaceholderValueAttribute),
      ("identifier", kAXIdentifierAttribute),
    ]
    for (name, attribute) in fields {
      if let text = copyAXAttribute(element, attribute: attribute) as? String, !text.isEmpty {
        value[name] = String(text.prefix(500))
      }
    }
    if value["role"] as? String != "AXSecureTextField",
      let text = copyAXAttribute(element, attribute: kAXValueAttribute) as? String,
      !text.isEmpty
    {
      value["value"] = String(text.prefix(500))
    }
    return value
  }

  private static func redactSecureAXLines(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
      let line = String(rawLine)
      guard line.contains("AXSecureTextField") else { return line }
      return secureAXValuePattern.stringByReplacingMatches(
        in: line,
        range: NSRange(line.startIndex..<line.endIndex, in: line),
        withTemplate: "$1=\"[REDACTED]\""
      )
    }.joined(separator: "\n")
  }

  private func installTimer(for session: Session) {
    let timer = DispatchSource.makeTimerSource(queue: processingQueue)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler { [weak self, weak session] in
      guard let self, let session,
        self.lock.withLock({ self.activeSession === session })
      else { return }
      if Date().timeIntervalSince(session.startedAt) >= TimeInterval(Self.maximumDurationSeconds) {
        self.finalizeFromProcessingQueue(session, reason: "maxDuration")
        return
      }
      if session.storageFailed {
        self.finalizeFromProcessingQueue(session, reason: "serviceTerminated")
        return
      }
      do { try self.screenLockChecker.requireUnlocked() } catch {
        self.finalizeFromProcessingQueue(session, reason: "serviceTerminated")
        return
      }
      if Date().timeIntervalSince(session.lastAccessibilityRefreshAt) >= 2 {
        self.captureAccessibilityChange(for: session)
      }
    }
    session.timer = timer
    timer.resume()
  }

  private func stop(reason: String) -> [String: Any] {
    guard let session = lock.withLock({ activeSession }) else {
      return lock.withLock { latestStatus ?? emptyStatus() }
    }
    processingQueue.sync { finalize(session, reason: reason) }
    return lock.withLock { latestStatus ?? emptyStatus() }
  }

  private func finalizeFromProcessingQueue(_ session: Session, reason: String) {
    finalize(session, reason: reason)
  }

  private func finalize(_ session: Session, reason: String) {
    guard lock.withLock({ activeSession === session }) else { return }
    flushPendingRecords(for: session)
    session.endedAt = Date()
    session.endReason = reason
    appendBoundary(kind: "session.ended", to: session)
    if let identifier = session.eventObserverID {
      inputMonitor.removeEventObserver(identifier)
      session.eventObserverID = nil
    }
    session.accessibilityMonitor?.stop()
    session.accessibilityMonitor = nil
    session.timer?.cancel()
    session.timer = nil
    session.textBuffer = nil
    session.textFlushTask?.cancel()
    session.textFlushTask = nil
    session.terminalValueChangedBuffer = nil
    session.terminalValueChangedFlushTask?.cancel()
    session.terminalValueChangedFlushTask = nil
    session.pendingAXNotificationRecords.removeAll()
    for task in session.axNotificationDebounceTasks.values { task.cancel() }
    session.axNotificationDebounceTasks.removeAll()
    session.axNotificationDebounceGenerations.removeAll()
    session.layoutFlushTask?.cancel()
    session.layoutFlushTask = nil
    session.pendingRecords.removeAll()
    session.recordProcessingScheduled = false
    writeMetadata(for: session)
    try? session.eventsHandle.synchronize()
    try? session.suppressedEventsHandle.synchronize()
    try? session.eventsHandle.close()
    try? session.suppressedEventsHandle.close()
    let finalStatus = status(for: session, isRecording: false)
    lock.withLock {
      guard activeSession === session else { return }
      latestStatus = finalStatus
      activeSession = nil
    }
  }

  private func writeMetadata(for session: Session) {
    var metadata: [String: Any] = [
      "id": session.identifier,
      "eventsPath": session.eventsURL.path,
      "startedAt": Self.dateString(session.startedAt),
      "eventCount": session.eventCount,
      "suppressedEventCount": session.suppressedEventCount,
    ]
    if let endedAt = session.endedAt { metadata["endedAt"] = Self.dateString(endedAt) }
    if let endReason = session.endReason { metadata["endReason"] = endReason }
    guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) else {
      return
    }
    do {
      try data.write(to: session.metadataURL, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.metadataURL.path)
    } catch {
      session.storageFailed = true
    }
  }

  private func status(for session: Session, isRecording: Bool) -> [String: Any] {
    [
      "isRecording": isRecording,
      "sessionID": session.identifier,
      "sessionDirectoryPath": session.directoryURL.path,
      "eventsPath": session.eventsURL.path,
      "metadataPath": session.metadataURL.path,
      "suppressedEventsPath": session.suppressedEventsURL.path,
      "startedAt": Self.dateString(session.startedAt),
      "endedAt": session.endedAt.map(Self.dateString) ?? NSNull(),
      "endReason": session.endReason ?? NSNull(),
      "maxDurationSeconds": Self.maximumDurationSeconds,
    ]
  }

  private func emptyStatus() -> [String: Any] {
    [
      "isRecording": false,
      "sessionID": NSNull(),
      "sessionDirectoryPath": NSNull(),
      "eventsPath": NSNull(),
      "metadataPath": NSNull(),
      "suppressedEventsPath": NSNull(),
      "startedAt": NSNull(),
      "endedAt": NSNull(),
      "endReason": NSNull(),
      "maxDurationSeconds": Self.maximumDurationSeconds,
    ]
  }

  private static func createOwnerOnlyFile(at url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(
      atPath: url.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw EventStreamSessionError.storageFailure("could not create \(url.path)")
    }
    return try FileHandle(forWritingTo: url)
  }

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func copyAXAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private static func copyAXElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    guard let value = copyAXAttribute(element, attribute: attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func unicodeText(_ event: CGEvent) -> String? {
    var length = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
    guard length > 0 else { return nil }
    var units = [UniChar](repeating: 0, count: length)
    event.keyboardGetUnicodeString(
      maxStringLength: length,
      actualStringLength: &length,
      unicodeString: &units
    )
    return String(utf16CodeUnits: units, count: length)
  }

  private static func modifierNames(_ flags: CGEventFlags) -> [String] {
    var names: [String] = []
    if flags.contains(.maskCommand) { names.append("command") }
    if flags.contains(.maskShift) { names.append("shift") }
    if flags.contains(.maskAlternate) { names.append("option") }
    if flags.contains(.maskControl) { names.append("control") }
    if flags.contains(.maskSecondaryFn) { names.append("function") }
    if flags.contains(.maskAlphaShift) { names.append("capsLock") }
    return names
  }

  private static func shortcutModifiers(_ flags: CGEventFlags) -> [String] {
    modifierNames(flags).filter { $0 != "shift" && $0 != "capsLock" }
  }

  private static func buttonName(for type: CGEventType) -> String {
    switch type {
    case .rightMouseDown, .rightMouseUp: return "right"
    case .otherMouseDown, .otherMouseUp: return "other"
    default: return "left"
    }
  }

  private static let endReasons: Set<String> = [
    "toolStopped",
    "debugUIStopped",
    "recordingControlsStopped",
    "recordingControlsCancelled",
    "maxDuration",
    "serviceTerminated",
  ]

  private static let sensitiveBundlePrefixes: Set<String> = [
    "com.1password.1password",
    "com.1password.safari",
    "com.agilebits.onepassword",
    "com.apple.passwords",
    "com.apple.securityagent",
    "com.bitwarden.desktop",
    "com.dashlane.dashlanephonefinal",
    "com.lastpass.lastpass",
    "com.openai.chat",
    "com.openai.codex",
    "dev.huangjianbin.intel-sky-service",
  ]

  private static let sensitiveContentKeys: Set<String> = [
    "text", "keyEquivalent", "value", "selectedText", "selectedItems", "url",
  ]

  private static let secretPattern = try! NSRegularExpression(
    pattern: #"(?i)\b(password|passwd|token|api[_-]?key|authorization|bearer)(\s*[:=]?\s*)\S+"#
  )
  private static let secureAXValuePattern = try! NSRegularExpression(
    pattern: #"\b(value|selectedText)=\"(?:\\.|[^\"])*\""#
  )
}

/// Tracks frontmost-App changes and notifications from the active application's Accessibility tree.
/// EventStreamSessionManager owns record coalescing; this object only turns native signals into
/// refresh requests.
private final class NativeEventStreamAccessibilityMonitor: @unchecked Sendable {
  private enum RegistrationScope: Equatable {
    case application
    case focusedWindow
    case focusedElement
  }

  private struct Registration {
    let element: AXUIElement
    let notification: CFString
    let scope: RegistrationScope
  }

  private let lock = NSLock()
  private let changeHandler: @Sendable (String) -> Void
  private var workspaceObserver: NSObjectProtocol?
  private var axObserver: AXObserver?
  private var axSource: CFRunLoopSource?
  private var registrations: [Registration] = []
  private var currentProcessIdentifier: pid_t?
  private var started = false
  private var stopped = false

  init(changeHandler: @escaping @Sendable (String) -> Void) {
    self.changeHandler = changeHandler
  }

  deinit { stop() }

  func start() {
    let shouldStart = lock.withLock { () -> Bool in
      guard !started, !stopped else { return false }
      started = true
      return true
    }
    guard shouldStart else { return }
    let install: @Sendable () -> Void = { [weak self] in
      self?.installOnMainRunLoop()
    }
    if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
  }

  func stop() {
    let state = lock.withLock {
      () -> (NSObjectProtocol?, AXObserver?, CFRunLoopSource?, [Registration]) in
      guard !stopped else { return (nil, nil, nil, []) }
      stopped = true
      let state = (workspaceObserver, axObserver, axSource, registrations)
      workspaceObserver = nil
      axObserver = nil
      axSource = nil
      registrations.removeAll()
      currentProcessIdentifier = nil
      return state
    }
    if let workspaceObserver = state.0 {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
    }
    if let observer = state.1 {
      for registration in state.3 {
        AXObserverRemoveNotification(observer, registration.element, registration.notification)
      }
    }
    if let source = state.2 {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
  }

  private func installOnMainRunLoop() {
    guard lock.withLock({ !stopped }) else { return }
    let token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reconfigureForFrontmostApplication()
      self?.changeHandler("workspace.didActivateApplication")
    }
    let accepted = lock.withLock { () -> Bool in
      guard !stopped, workspaceObserver == nil else { return false }
      workspaceObserver = token
      return true
    }
    guard accepted else {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
      return
    }
    reconfigureForFrontmostApplication()
  }

  private func reconfigureForFrontmostApplication() {
    guard let application = NSWorkspace.shared.frontmostApplication,
      !application.isTerminated
    else {
      tearDownAccessibilityObserver()
      return
    }
    let processIdentifier = application.processIdentifier
    if lock.withLock({ !stopped && currentProcessIdentifier == processIdentifier }) { return }
    tearDownAccessibilityObserver()
    guard lock.withLock({ !stopped }) else { return }

    var createdObserver: AXObserver?
    let result = AXObserverCreateWithInfoCallback(
      processIdentifier,
      { _, _, notification, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<NativeEventStreamAccessibilityMonitor>.fromOpaque(refcon)
          .takeUnretainedValue()
        monitor.accessibilityDidChange(notification: notification as String)
      },
      &createdObserver
    )
    guard result == .success, let createdObserver else { return }
    let source = AXObserverGetRunLoopSource(createdObserver)
    let accepted = lock.withLock { () -> Bool in
      guard !stopped, axObserver == nil else { return false }
      axObserver = createdObserver
      axSource = source
      currentProcessIdentifier = processIdentifier
      return true
    }
    guard accepted else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

    let applicationElement = AXUIElementCreateApplication(processIdentifier)
    for notification in [
      kAXFocusedWindowChangedNotification,
      kAXFocusedUIElementChangedNotification,
      kAXWindowCreatedNotification,
    ] {
      register(
        applicationElement,
        notification: notification as CFString,
        scope: .application
      )
    }
    registerFocusedWindow(processIdentifier: processIdentifier)
    registerFocusedUIElement(processIdentifier: processIdentifier)
  }

  private func accessibilityDidChange(notification: String) {
    guard lock.withLock({ !stopped }) else { return }
    if notification == kAXFocusedWindowChangedNotification
      || notification == kAXWindowCreatedNotification
      || notification == kAXUIElementDestroyedNotification
    {
      let processIdentifier = lock.withLock { currentProcessIdentifier }
      if let processIdentifier {
        registerFocusedWindow(processIdentifier: processIdentifier)
        registerFocusedUIElement(processIdentifier: processIdentifier)
      }
    } else if notification == kAXFocusedUIElementChangedNotification {
      let processIdentifier = lock.withLock { currentProcessIdentifier }
      if let processIdentifier { registerFocusedUIElement(processIdentifier: processIdentifier) }
    }
    changeHandler(notification)
  }

  private func registerFocusedWindow(processIdentifier: pid_t) {
    removeRegistrations(in: .focusedWindow)
    let application = AXUIElementCreateApplication(processIdentifier)
    guard let window = Self.copyAXElement(
      application,
      attribute: kAXFocusedWindowAttribute as CFString
    ) else { return }
    for notification in [
      kAXLayoutChangedNotification,
      kAXMovedNotification,
      kAXResizedNotification,
      kAXTitleChangedNotification,
      kAXUIElementDestroyedNotification,
    ] {
      register(window, notification: notification as CFString, scope: .focusedWindow)
    }
  }

  private func registerFocusedUIElement(processIdentifier: pid_t) {
    removeRegistrations(in: .focusedElement)
    let application = AXUIElementCreateApplication(processIdentifier)
    guard let element = Self.copyAXElement(
      application,
      attribute: kAXFocusedUIElementAttribute as CFString
    ) else { return }
    for notification in [
      kAXLayoutChangedNotification,
      kAXSelectedTextChangedNotification,
      kAXSelectedChildrenChangedNotification,
      kAXSelectedChildrenMovedNotification,
      kAXSelectedRowsChangedNotification,
      kAXSelectedColumnsChangedNotification,
      kAXSelectedCellsChangedNotification,
      kAXValueChangedNotification,
      kAXUIElementDestroyedNotification,
    ] {
      register(element, notification: notification as CFString, scope: .focusedElement)
    }
  }

  private func register(
    _ element: AXUIElement,
    notification: CFString,
    scope: RegistrationScope
  ) {
    let observer = lock.withLock { axObserver }
    guard let observer else { return }
    let duplicate = lock.withLock {
      registrations.contains {
        $0.notification == notification && CFEqual($0.element, element)
      }
    }
    guard !duplicate else { return }
    let result = AXObserverAddNotification(
      observer,
      element,
      notification,
      Unmanaged.passUnretained(self).toOpaque()
    )
    guard result == .success else { return }
    lock.withLock {
      guard !stopped, axObserver === observer else {
        AXObserverRemoveNotification(observer, element, notification)
        return
      }
      registrations.append(
        Registration(element: element, notification: notification, scope: scope)
      )
    }
  }

  private func removeRegistrations(in scope: RegistrationScope) {
    let state = lock.withLock { () -> (AXObserver?, [Registration]) in
      guard let axObserver else { return (nil, []) }
      let removed = registrations.filter { $0.scope == scope }
      registrations.removeAll { $0.scope == scope }
      return (axObserver, removed)
    }
    guard let observer = state.0 else { return }
    for registration in state.1 {
      AXObserverRemoveNotification(observer, registration.element, registration.notification)
    }
  }

  private func tearDownAccessibilityObserver() {
    let state = lock.withLock { () -> (AXObserver?, CFRunLoopSource?, [Registration]) in
      let state = (axObserver, axSource, registrations)
      axObserver = nil
      axSource = nil
      registrations.removeAll()
      currentProcessIdentifier = nil
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
  }

  private static func copyAXElement(
    _ element: AXUIElement,
    attribute: CFString
  ) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }
}
