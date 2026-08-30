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
  private var activeSession: Session?
  private var latestStatus: [String: Any]?

  public init(rootDirectoryURL: URL) {
    self.rootDirectoryURL = rootDirectoryURL
    inputMonitor = PhysicalInputMonitor.shared
    screenLockChecker = CGSessionScreenLockChecker()
  }

  init(
    rootDirectoryURL: URL,
    inputMonitor: any EventStreamInputMonitoring,
    screenLockChecker: any ScreenLockChecking = NoopScreenLockChecker()
  ) {
    self.rootDirectoryURL = rootDirectoryURL
    self.inputMonitor = inputMonitor
    self.screenLockChecker = screenLockChecker
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
          captureAccessibilityChange(for: session)
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
    guard let record = makeRecord(type: type, event: event, session: session) else { return }
    let suppressed = Self.shouldSuppress(record)
    append(record, suppressed: suppressed, to: session)
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

  private func captureAccessibilityChange(for session: Session) {
    guard let running = NSWorkspace.shared.frontmostApplication, !running.isTerminated else { return }
    let processIdentifier = running.processIdentifier
    let app = appDescriptor(processIdentifier: processIdentifier)
    let window = windowDescriptor(processIdentifier: processIdentifier, point: .zero)
    if let app, Self.shouldSuppress(["app": app]) {
      let key = "sensitive:\(processIdentifier):\(window?["windowID"] ?? "none")"
      guard session.seenApplicationProcesses.insert(key).inserted else { return }
      var record = baseRecord(session: session, kind: "window.changed", app: app, window: window)
      record["ax"] = ["mode": "fullTree", "text": "[REDACTED]"]
      append(record, suppressed: true, to: session)
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
    append(record, suppressed: containsSecureTextField, to: session)
    guard !containsSecureTextField else { return }
    captureSelectionAndTerminalChanges(
      for: session,
      application: running,
      app: app,
      window: window
    )
  }

  private func captureSelectionAndTerminalChanges(
    for session: Session,
    application: NSRunningApplication,
    app: [String: Any]?,
    window: [String: Any]?
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
      append(record, suppressed: Self.shouldSuppress(record), to: session)
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
      append(record, suppressed: Self.shouldSuppress(record), to: session)
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
      self.captureAccessibilityChange(for: session)
    }
    session.timer = timer
    timer.resume()
  }

  private func stop(reason: String) -> [String: Any] {
    guard let session = lock.withLock({ activeSession }) else {
      return lock.withLock { latestStatus ?? emptyStatus() }
    }
    if let identifier = session.eventObserverID { inputMonitor.removeEventObserver(identifier) }
    processingQueue.sync { finalize(session, reason: reason) }
    return lock.withLock { latestStatus ?? emptyStatus() }
  }

  private func finalizeFromProcessingQueue(_ session: Session, reason: String) {
    if let identifier = session.eventObserverID { inputMonitor.removeEventObserver(identifier) }
    finalize(session, reason: reason)
  }

  private func finalize(_ session: Session, reason: String) {
    guard lock.withLock({ activeSession === session }) else { return }
    session.timer?.cancel()
    session.timer = nil
    session.endedAt = Date()
    session.endReason = reason
    appendBoundary(kind: "session.ended", to: session)
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
    "com.agilebits.onepassword",
    "com.apple.passwords",
    "com.apple.securityagent",
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
