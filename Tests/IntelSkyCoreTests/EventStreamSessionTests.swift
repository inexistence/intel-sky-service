import CoreGraphics
import Foundation
import Testing

@testable import IntelSkyCore

@Test func eventStreamStartStatusAndStopPersistOfficialSessionFiles() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = TestEventStreamInputMonitor()
  let manager = EventStreamSessionManager(rootDirectoryURL: root, inputMonitor: monitor)

  let started = try ComputerUseClientContext.withIdentifier("client-a") {
    try manager.startEventStream(request: ["_originatingThreadID": "thread-a"])
  }
  #expect(started["isRecording"] as? Bool == true)
  #expect(started["maxDurationSeconds"] as? Int == 1_800)
  #expect((started["endedAt"] as? NSNull) != nil)
  let eventsPath = try #require(started["eventsPath"] as? String)
  let metadataPath = try #require(started["metadataPath"] as? String)

  let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
  key.flags = []
  key.setIntegerValueField(
    .eventTargetUnixProcessID,
    value: Int64(ProcessInfo.processInfo.processIdentifier)
  )
  var character: [UniChar] = [65]
  key.keyboardSetUnicodeString(stringLength: character.count, unicodeString: &character)
  monitor.emit(type: .keyDown, event: key)

  let stopped = try manager.stopEventStream(request: ["reason": "toolStopped"])
  #expect(stopped["isRecording"] as? Bool == false)
  #expect(stopped["endReason"] as? String == "toolStopped")
  #expect(FileManager.default.fileExists(atPath: eventsPath))
  #expect(FileManager.default.fileExists(atPath: metadataPath))

  let records = try jsonLines(atPath: eventsPath)
  #expect(records.first?["kind"] as? String == "session.started")
  #expect(records.contains { $0["kind"] as? String == "keyboard.text_input" })
  #expect(records.last?["kind"] as? String == "session.ended")
  let metadata = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: metadataPath)))
      as? [String: Any]
  )
  #expect(metadata["endReason"] as? String == "toolStopped")
  #expect((metadata["eventCount"] as? Int) == records.count)
}

@Test func eventStreamStartIsIdempotentAndStatusRetainsLatestSession() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let manager = EventStreamSessionManager(
    rootDirectoryURL: root,
    inputMonitor: TestEventStreamInputMonitor()
  )

  let first = try manager.startEventStream(request: [:])
  let second = try manager.startEventStream(request: [:])
  #expect(first["sessionID"] as? String == second["sessionID"] as? String)
  _ = try manager.stopEventStream(request: ["reason": "recordingControlsStopped"])
  let status = try manager.eventStreamStatus(request: [:])
  #expect(status["sessionID"] as? String == first["sessionID"] as? String)
  #expect(status["endReason"] as? String == "recordingControlsStopped")
}

@Test func eventStreamRejectsMissingInputMonitoringAndInvalidReasons() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let unavailable = TestEventStreamInputMonitor(isAvailable: false)
  let manager = EventStreamSessionManager(rootDirectoryURL: root, inputMonitor: unavailable)

  #expect(throws: EventStreamSessionError.self) {
    try manager.startEventStream(request: [:])
  }
  #expect(throws: EventStreamSessionError.self) {
    try manager.stopEventStream(request: ["reason": "unknown"])
  }
}

@Test func eventStreamDisconnectAndMatchingTurnEndUseTerminalReasons() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let manager = EventStreamSessionManager(
    rootDirectoryURL: root,
    inputMonitor: TestEventStreamInputMonitor()
  )

  _ = try ComputerUseClientContext.withIdentifier("client-a") {
    try manager.startEventStream(request: ["_originatingThreadID": "thread-a"])
  }
  manager.clientDisconnected("client-b")
  #expect((try manager.eventStreamStatus(request: [:]))["isRecording"] as? Bool == true)
  manager.clientDisconnected("client-a")
  #expect((try manager.eventStreamStatus(request: [:]))["endReason"] as? String == "serviceTerminated")

  _ = try manager.startEventStream(request: ["_originatingThreadID": "thread-a"])
  let other = try #require(
    ComputerUseTurnIdentity(metadata: [
      "session_id": "session", "thread_id": "thread-b", "turn_id": "turn",
    ]))
  manager.handle(.ended(other))
  #expect((try manager.eventStreamStatus(request: [:]))["isRecording"] as? Bool == true)
  let matching = try #require(
    ComputerUseTurnIdentity(metadata: [
      "session_id": "session", "thread_id": "thread-a", "turn_id": "turn",
    ]))
  manager.handle(.ended(matching))
  #expect((try manager.eventStreamStatus(request: [:]))["endReason"] as? String == "toolStopped")
}

@Test func unscopedSafetyRevocationStopsEventStreamWithoutTurnMetadata() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let manager = EventStreamSessionManager(
    rootDirectoryURL: root,
    inputMonitor: TestEventStreamInputMonitor()
  )
  _ = try manager.startEventStream(request: [:])

  manager.handle(.safetyRevoked(.screenLocked))

  let status = try manager.eventStreamStatus(request: [:])
  #expect(status["isRecording"] as? Bool == false)
  #expect(status["endReason"] as? String == "toolStopped")
}

@Test func eventStreamPrivacyFilterSuppressesSecureAndSensitiveApplicationRecords() {
  #expect(
    EventStreamSessionManager.shouldSuppress([
      "app": ["bundleIdentifier": "com.example.fixture", "secureInput": true]
    ]))
  #expect(
    EventStreamSessionManager.shouldSuppress([
      "app": ["bundleIdentifier": "com.1password.1password", "secureInput": false]
    ]))
  #expect(
    !EventStreamSessionManager.shouldSuppress([
      "app": ["bundleIdentifier": "com.apple.TextEdit", "secureInput": false]
    ]))
  let redacted = EventStreamSessionManager.redactedRecord([
    "app": ["bundleIdentifier": "com.1password.1password"],
    "keyboard": ["text": "secret", "keyEquivalent": "s"],
    "ax": ["mode": "fullTree", "text": "password=secret"],
  ])
  let encoded = String(
    data: try! JSONSerialization.data(withJSONObject: redacted),
    encoding: .utf8
  )
  #expect(encoded?.contains("secret") == false)
  let scrubbed = EventStreamSessionManager.scrubSecrets(in: [
    "keyboard": ["text": "token=abc123 safe words"]
  ])
  let scrubbedText = (scrubbed["keyboard"] as? [String: Any])?["text"] as? String
  #expect(scrubbedText == "token=[REDACTED] safe words")
}

@Test(
  arguments: [
    "com.1password.1password",
    "com.1password.safari",
    "com.bitwarden.desktop",
    "com.dashlane.dashlanephonefinal",
    "com.lastpass.LastPass",
  ]
)
func eventStreamSuppressesARMObservedCredentialManagers(bundleIdentifier: String) {
  #expect(
    EventStreamSessionManager.shouldSuppress([
      "app": ["bundleIdentifier": bundleIdentifier, "secureInput": false]
    ])
  )
}

@Test func eventStreamDirectMouseEventsProduceClickAndDragRecords() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = TestEventStreamInputMonitor()
  let manager = EventStreamSessionManager(rootDirectoryURL: root, inputMonitor: monitor)
  let status = try manager.startEventStream(request: [:])
  let eventsPath = try #require(status["eventsPath"] as? String)

  let down = try #require(
    CGEvent(
      mouseEventSource: nil,
      mouseType: .leftMouseDown,
      mouseCursorPosition: CGPoint(x: 10, y: 10),
      mouseButton: .left
    ))
  let up = try #require(
    CGEvent(
      mouseEventSource: nil,
      mouseType: .leftMouseUp,
      mouseCursorPosition: CGPoint(x: 100, y: 100),
      mouseButton: .left
    ))
  for event in [down, up] {
    event.setIntegerValueField(
      .eventTargetUnixProcessID,
      value: Int64(ProcessInfo.processInfo.processIdentifier)
    )
  }
  monitor.emit(type: .leftMouseDown, event: down)
  monitor.emit(type: .leftMouseUp, event: up)
  _ = try manager.stopEventStream(request: ["reason": "toolStopped"])

  let records = try jsonLines(atPath: eventsPath)
  let drag = try #require(records.first { $0["kind"] as? String == "mouse.drag" })
  let mouse = try #require(drag["mouse"] as? [String: Any])
  #expect(mouse["origin"] is [String: Any])
  #expect(mouse["destination"] is [String: Any])
}

@Test func eventStreamStopFlushesBufferedTextBeforeSessionEndedWithoutIdentityGaps() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = TestEventStreamInputMonitor()
  let manager = EventStreamSessionManager(rootDirectoryURL: root, inputMonitor: monitor)
  let status = try manager.startEventStream(request: [:])
  let eventsPath = try #require(status["eventsPath"] as? String)
  let suppressedEventsPath = try #require(status["suppressedEventsPath"] as? String)

  for scalar in "buffered".utf16 {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    event.setIntegerValueField(
      .eventTargetUnixProcessID,
      value: Int64(ProcessInfo.processInfo.processIdentifier)
    )
    var character = [scalar]
    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
    monitor.emit(type: .keyDown, event: event)
  }

  _ = try manager.stopEventStream(request: ["reason": "toolStopped"])
  let records = try jsonLines(atPath: eventsPath)
  let text = records.compactMap { record -> String? in
    guard record["kind"] as? String == "keyboard.text_input" else { return nil }
    return (record["keyboard"] as? [String: Any])?["text"] as? String
  }.joined()
  #expect(text == "buffered")
  #expect(records.last?["kind"] as? String == "session.ended")
  let allRecords = try (records + jsonLines(atPath: suppressedEventsPath)).sorted {
    ($0["id"] as? Int ?? .max) < ($1["id"] as? Int ?? .max)
  }
  #expect(allRecords.compactMap { $0["id"] as? Int } == Array(0..<allRecords.count))
}

@Test func eventStreamTextInputUsesARMSevenHundredFiftyMillisecondDebounce() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = TestEventStreamInputMonitor()
  let manager = EventStreamSessionManager(rootDirectoryURL: root, inputMonitor: monitor)
  let status = try manager.startEventStream(request: [:])
  let eventsPath = try #require(status["eventsPath"] as? String)

  for scalar in "ab".utf16 {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    event.setIntegerValueField(
      .eventTargetUnixProcessID,
      value: Int64(ProcessInfo.processInfo.processIdentifier)
    )
    var character = [scalar]
    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
    monitor.emit(type: .keyDown, event: event)
  }

  let deadline = Date().addingTimeInterval(2)
  var textRecords: [[String: Any]] = []
  repeat {
    Thread.sleep(forTimeInterval: 0.05)
    textRecords = try jsonLines(atPath: eventsPath).filter {
      $0["kind"] as? String == "keyboard.text_input"
    }
  } while textRecords.isEmpty && Date() < deadline

  #expect(textRecords.count == 1)
  let keyboard = try #require(textRecords.first?["keyboard"] as? [String: Any])
  #expect(keyboard["text"] as? String == "ab")
  _ = try manager.stopEventStream(request: ["reason": "toolStopped"])
}

@Test func eventStreamLockedScreenTerminatesWithoutPersistingInput() throws {
  let root = temporaryEventStreamRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = TestEventStreamInputMonitor()
  let manager = EventStreamSessionManager(
    rootDirectoryURL: root,
    inputMonitor: monitor,
    screenLockChecker: AlwaysLockedScreenChecker()
  )
  _ = try manager.startEventStream(request: [:])
  let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
  monitor.emit(type: .keyDown, event: key)

  let deadline = Date().addingTimeInterval(1)
  while Date() < deadline,
    (try manager.eventStreamStatus(request: [:]))["isRecording"] as? Bool == true
  {
    Thread.sleep(forTimeInterval: 0.01)
  }
  let status = try manager.eventStreamStatus(request: [:])
  #expect(status["isRecording"] as? Bool == false)
  #expect(status["endReason"] as? String == "serviceTerminated")
}

private final class TestEventStreamInputMonitor: EventStreamInputMonitoring, @unchecked Sendable {
  private let lock = NSLock()
  private var observers: [UUID: @Sendable (CGEventType, CGEvent) -> Void] = [:]
  let isAvailable: Bool

  init(isAvailable: Bool = true) {
    self.isAvailable = isAvailable
  }

  func addEventObserver(
    _ observer: @escaping @Sendable (CGEventType, CGEvent) -> Void
  ) -> UUID {
    let identifier = UUID()
    lock.withLock { observers[identifier] = observer }
    return identifier
  }

  func removeEventObserver(_ identifier: UUID) {
    _ = lock.withLock { observers.removeValue(forKey: identifier) }
  }

  func emit(type: CGEventType, event: CGEvent) {
    let values = lock.withLock { Array(observers.values) }
    for observer in values { observer(type, event) }
  }
}

private struct AlwaysLockedScreenChecker: ScreenLockChecking {
  func requireUnlocked() throws { throw SkySafetyError.screenLocked }
}

private func temporaryEventStreamRoot() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("event-stream-tests-\(UUID().uuidString)", isDirectory: true)
}

private func jsonLines(atPath path: String) throws -> [[String: Any]] {
  let text = try String(contentsOfFile: path, encoding: .utf8)
  return try text.split(separator: "\n").map { line in
    try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
  }
}
