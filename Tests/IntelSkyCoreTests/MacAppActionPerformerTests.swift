import ApplicationServices
import Foundation
import Testing

@testable import IntelSkyCore

@Test func elementClickUsesLatestSnapshotFrameCenter() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(
    CapturedAccessibilitySnapshot(
      text: "test",
      elementsByID: ["7": AXUIElementCreateApplication(app.processIdentifier)]
    ),
    for: app
  )
  let activator = RecordingActivator()
  let mouse = RecordingMouseClickPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: CGRect(x: 10, y: 20, width: 40, height: 60)),
    mouseClickPoster: mouse
  )

  _ = try performer.performAction(
    request: clickRequest(
      at: ["elementID": ["_0": "7"]],
      clickCount: 2,
      mouseButton: 0
    ))

  #expect(activator.activatedApps == [app])
  #expect(mouse.clicks == [RecordedClick(point: CGPoint(x: 30, y: 50), button: .left, count: 2)])
}

@Test func coordinateClickRequiresCurrentSnapshot() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app)
  let mouse = RecordingMouseClickPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: mouse
  )

  _ = try performer.performAction(
    request: clickRequest(
      at: ["coordinate": ["_0": [125.5, 240.25]]],
      clickCount: 1,
      mouseButton: 1
    ))

  #expect(
    mouse.clicks == [
      RecordedClick(point: CGPoint(x: 125.5, y: 240.25), button: .right, count: 1)
    ])
}

@Test func coordinateClickWithoutSnapshotIsRejected() throws {
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: actionTestApp()),
    snapshotCache: ElementSnapshotCache(),
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster()
  )

  #expect(throws: ElementSnapshotCacheError.self) {
    try performer.performAction(
      request: clickRequest(
        at: ["coordinate": ["_0": [10, 20]]],
        clickCount: 1,
        mouseButton: 0
      ))
  }
}

@Test func elementClickWithoutSnapshotIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let activator = RecordingActivator()
  let mouse = RecordingMouseClickPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: ElementSnapshotCache(),
    activator: activator,
    frameReader: StubFrameReader(frame: .zero),
    mouseClickPoster: mouse
  )

  #expect(throws: ElementSnapshotCacheError.self) {
    try performer.performAction(
      request: clickRequest(
        at: ["elementID": ["_0": "7"]],
        clickCount: 1,
        mouseButton: 0
      ))
  }
  #expect(activator.activatedApps.isEmpty)
  #expect(mouse.clicks.isEmpty)
}

@Test func malformedClickValuesAreRejected() throws {
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: actionTestApp()),
    snapshotCache: ElementSnapshotCache(),
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster()
  )

  #expect(throws: MacAppActionError.self) {
    try performer.performAction(
      request: clickRequest(
        at: ["coordinate": ["_0": [10, 20]]],
        clickCount: 4,
        mouseButton: 0
      ))
  }
  #expect(throws: MacAppActionError.self) {
    try performer.performAction(
      request: clickRequest(
        at: ["coordinate": ["_0": [true, false]]],
        clickCount: 1,
        mouseButton: 0
      ))
  }
}

@Test func clickPayloadWithUnexpectedFieldsIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app)
  let activator = RecordingActivator()
  let mouse = RecordingMouseClickPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: mouse
  )
  var request = clickRequest(
    at: ["coordinate": ["_0": [10, 20]]],
    clickCount: 1,
    mouseButton: 0
  )
  var action = try #require(request["action"] as? [String: Any])
  var click = try #require(action["click"] as? [String: Any])
  click["unexpected"] = true
  action["click"] = click
  request["action"] = action

  #expect(throws: MacAppActionError.self) {
    try performer.performAction(request: request)
  }
  #expect(activator.activatedApps.isEmpty)
  #expect(mouse.clicks.isEmpty)
}

@Test func pressKeyRequiresSnapshotThenActivatesAndPostsChord() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app)
  let activator = RecordingActivator()
  let keyboard = RecordingKeyboardInputPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: keyboard
  )

  _ = try performer.performAction(
    request: actionRequest(name: "pressKey", payload: ["_0": "Ctrl+Shift+period"])
  )

  #expect(activator.activatedApps == [app])
  #expect(keyboard.chords == [ParsedKeyChord(keyCode: 47, modifiers: [.control, .shift])])
  #expect(keyboard.typedTexts.isEmpty)
}

@Test func typeTextRequiresSnapshotThenActivatesAndPostsUnicode() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app)
  let activator = RecordingActivator()
  let keyboard = RecordingKeyboardInputPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: keyboard
  )

  _ = try performer.performAction(
    request: actionRequest(name: "type", payload: ["_0": "Hello，世界 👋"])
  )

  #expect(activator.activatedApps == [app])
  #expect(keyboard.typedTexts == ["Hello，世界 👋"])
  #expect(keyboard.chords.isEmpty)
}

@Test func keyboardInputWithoutSnapshotIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let activator = RecordingActivator()
  let keyboard = RecordingKeyboardInputPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: ElementSnapshotCache(),
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: keyboard
  )

  #expect(throws: ElementSnapshotCacheError.self) {
    try performer.performAction(
      request: actionRequest(name: "pressKey", payload: ["_0": "Return"])
    )
  }
  #expect(activator.activatedApps.isEmpty)
  #expect(keyboard.chords.isEmpty)
}

@Test func oversizedTypeTextIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let activator = RecordingActivator()
  let keyboard = RecordingKeyboardInputPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: ElementSnapshotCache(),
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: keyboard
  )

  #expect(throws: MacAppActionError.self) {
    try performer.performAction(
      request: actionRequest(name: "type", payload: ["_0": String(repeating: "a", count: 10_001)])
    )
  }
  #expect(activator.activatedApps.isEmpty)
  #expect(keyboard.typedTexts.isEmpty)
}

private struct StubActionResolver: MacAppResolving {
  let app: ResolvedMacApp

  func resolve(_ value: Any?) throws -> ResolvedMacApp { app }

  func frontWindowID(for app: ResolvedMacApp) throws -> CGWindowID {
    throw MacAppResolutionError.noWindow(app.displayName)
  }
}

private final class RecordingActivator: AppActivating, @unchecked Sendable {
  private(set) var activatedApps: [ResolvedMacApp] = []

  func activate(_ app: ResolvedMacApp) throws {
    activatedApps.append(app)
  }
}

private struct StubFrameReader: AccessibilityFrameReading {
  let frame: CGRect?
  func frame(of element: AXUIElement) -> CGRect? { frame }
}

private struct RecordedClick: Equatable {
  let point: CGPoint
  let button: ComputerUseMouseButton
  let count: Int
}

private final class RecordingMouseClickPoster: MouseClickPosting, @unchecked Sendable {
  private(set) var clicks: [RecordedClick] = []

  func click(at point: CGPoint, button: ComputerUseMouseButton, count: Int) throws {
    clicks.append(RecordedClick(point: point, button: button, count: count))
  }
}

private final class RecordingKeyboardInputPoster: KeyboardInputPosting, @unchecked Sendable {
  private(set) var chords: [ParsedKeyChord] = []
  private(set) var typedTexts: [String] = []

  func press(_ chord: ParsedKeyChord) throws {
    chords.append(chord)
  }

  func typeText(_ text: String) throws {
    typedTexts.append(text)
  }
}

private func actionTestApp() -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: 42,
    bundleIdentifier: "example.app",
    displayName: "Example",
    appPath: "/Applications/Example.app"
  )
}

private func clickRequest(at: [String: Any], clickCount: Any, mouseButton: Any) -> [String: Any] {
  [
    "app": "example.app",
    "action": [
      "click": [
        "at": at,
        "clickCount": clickCount,
        "mouseButton": mouseButton,
      ]
    ],
  ]
}

private func actionRequest(name: String, payload: [String: Any]) -> [String: Any] {
  ["app": "example.app", "action": [name: payload]]
}

private func testActionSnapshot() -> CapturedAccessibilitySnapshot {
  CapturedAccessibilitySnapshot(text: "test", elementsByID: [:])
}
