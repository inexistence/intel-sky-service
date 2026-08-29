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

@Test func singleLeftElementClickPrefersAccessibilityPress() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(
    CapturedAccessibilitySnapshot(
      text: "test",
      elementsByID: ["7": AXUIElementCreateApplication(app.processIdentifier)]
    ),
    for: app
  )
  let mouse = RecordingMouseClickPoster()
  let axClick = RecordingAccessibilityPrimaryClicker(didClick: true)
  let visualizer = RecordingComputerUseVisualizer()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: CGRect(x: 20, y: 40, width: 100, height: 200)),
    mouseClickPoster: mouse,
    accessibilityPrimaryClicker: axClick,
    visualizer: visualizer
  )

  _ = try performer.performAction(
    request: actionRequest(
      name: "click",
      payload: [
        "at": ["elementID": ["_0": "7"]],
        "clickCount": 1,
        "mouseButton": 0,
      ]
    )
  )

  #expect(axClick.elements.count == 1)
  #expect(mouse.clicks.isEmpty)
  #expect(visualizer.clicks == [CGPoint(x: 70, y: 140)])
}

@Test func coordinateClickRequiresCurrentSnapshot() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
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
      RecordedClick(point: CGPoint(x: 162.75, y: 270.125), button: .right, count: 1)
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
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
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
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
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
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
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

@Test func emptyTypeTextIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let activator = RecordingActivator()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: ElementSnapshotCache(),
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster()
  )

  #expect(throws: MacAppActionError.self) {
    try performer.performAction(request: actionRequest(name: "type", payload: ["_0": ""]))
  }
  #expect(activator.activatedApps.isEmpty)
}

@Test func elementScrollUsesLatestSnapshotFrameCenter() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(
    CapturedAccessibilitySnapshot(
      text: "test",
      elementsByID: ["8": AXUIElementCreateApplication(app.processIdentifier)]
    ),
    for: app
  )
  let activator = RecordingActivator()
  let scroll = RecordingScrollEventPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: CGRect(x: 20, y: 40, width: 100, height: 200)),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll
  )

  _ = try performer.performAction(
    request: scrollRequest(
      at: ["elementID": ["_0": "8"]],
      direction: "down",
      pages: 1.5
    )
  )

  #expect(activator.activatedApps == [app])
  #expect(
    scroll.scrolls == [
      RecordedScroll(point: CGPoint(x: 70, y: 140), direction: .down, pages: 1.5)
    ])
}

@Test func elementScrollUsesAXPageActionsBeforePixelFallback() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(
    CapturedAccessibilitySnapshot(
      text: "test",
      elementsByID: ["8": AXUIElementCreateApplication(app.processIdentifier)]
    ),
    for: app
  )
  let scroll = RecordingScrollEventPoster()
  let axScroll = RecordingAccessibilityPageScroller(completedPages: 1)
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: CGRect(x: 20, y: 40, width: 100, height: 200)),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll,
    accessibilityPageScroller: axScroll
  )

  _ = try performer.performAction(
    request: scrollRequest(
      at: ["elementID": ["_0": "8"]],
      direction: "down",
      pages: 1.5
    )
  )

  #expect(axScroll.requests.count == 1)
  #expect(axScroll.requests.first?.direction == .down)
  #expect(axScroll.requests.first?.pageCount == 1)
  #expect(scroll.scrolls.first?.pages == 0.5)
}

@Test func completeAXPageScrollDoesNotMovePointer() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(
    CapturedAccessibilitySnapshot(
      text: "test",
      elementsByID: ["8": AXUIElementCreateApplication(app.processIdentifier)]
    ),
    for: app
  )
  let scroll = RecordingScrollEventPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll,
    accessibilityPageScroller: RecordingAccessibilityPageScroller(completedPages: 2)
  )

  _ = try performer.performAction(
    request: scrollRequest(
      at: ["elementID": ["_0": "8"]],
      direction: "right",
      pages: 2
    )
  )

  #expect(scroll.scrolls.isEmpty)
}

@Test func coordinateScrollRequiresCurrentSnapshot() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
  let scroll = RecordingScrollEventPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll
  )

  _ = try performer.performAction(
    request: scrollRequest(
      at: ["coordinate": ["_0": [125.5, 240.25]]],
      direction: "left",
      pages: 2
    )
  )

  #expect(
    scroll.scrolls == [
      RecordedScroll(point: CGPoint(x: 162.75, y: 270.125), direction: .left, pages: 2)
    ])
}

@Test func invalidScrollIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
  let activator = RecordingActivator()
  let scroll = RecordingScrollEventPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll
  )

  #expect(throws: MacAppActionError.self) {
    try performer.performAction(
      request: scrollRequest(
        at: ["coordinate": ["_0": [10, 20]]],
        direction: "diagonal",
        pages: 1
      )
    )
  }
  #expect(throws: MacAppActionError.self) {
    try performer.performAction(
      request: scrollRequest(
        at: ["coordinate": ["_0": [10, 20]]],
        direction: "down",
        pages: true
      )
    )
  }
  #expect(activator.activatedApps.isEmpty)
  #expect(scroll.scrolls.isEmpty)
}

@Test func scrollAcceptsMoreThanTenAndFractionalPages() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
  let scroll = RecordingScrollEventPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll
  )

  _ = try performer.performAction(
    request: scrollRequest(
      at: ["coordinate": ["_0": [10, 20]]],
      direction: "down",
      pages: 10.5
    )
  )

  #expect(scroll.scrolls.count == 1)
  #expect(scroll.scrolls.first?.pages == 10.5)
}

@Test func coordinateScrollWithoutSnapshotIsRejectedBeforeActivation() throws {
  let app = actionTestApp()
  let activator = RecordingActivator()
  let scroll = RecordingScrollEventPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: ElementSnapshotCache(),
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    keyboardInputPoster: RecordingKeyboardInputPoster(),
    scrollEventPoster: scroll
  )

  #expect(throws: ElementSnapshotCacheError.self) {
    try performer.performAction(
      request: scrollRequest(
        at: ["coordinate": ["_0": [10, 20]]],
        direction: "down",
        pages: 1
      )
    )
  }
  #expect(activator.activatedApps.isEmpty)
  #expect(scroll.scrolls.isEmpty)
}

@Test func dragMapsBothScreenshotEndpointsBeforePosting() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app, coordinateSpace: testCoordinateSpace())
  let activator = RecordingActivator()
  let drag = RecordingMouseDragPoster()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: activator,
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    mouseDragPoster: drag
  )

  _ = try performer.performAction(
    request: actionRequest(
      name: "drag",
      payload: ["from": [0, 0], "to": [800, 600]]
    )
  )

  #expect(activator.activatedApps == [app])
  #expect(
    drag.drags == [
      RecordedDrag(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 500, y: 450))
    ]
  )
}

@Test func indexedAccessibilityActionsUseLatestSnapshotElement() throws {
  let app = actionTestApp()
  let element = AXUIElementCreateApplication(app.processIdentifier)
  let cache = ElementSnapshotCache()
  cache.store(
    CapturedAccessibilitySnapshot(text: "test", elementsByID: ["9": element]),
    for: app
  )
  let accessibility = RecordingAccessibilityActions()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    accessibilityActions: accessibility
  )

  _ = try performer.performAction(
    request: actionRequest(
      name: "setValue",
      payload: ["elementID": "9", "value": "replacement"]
    )
  )
  _ = try performer.performAction(
    request: actionRequest(
      name: "performSecondaryAction",
      payload: ["elementID": "9", "action": "Show Menu"]
    )
  )
  _ = try performer.performAction(
    request: actionRequest(
      name: "selectText",
      payload: [
        "elementID": "9",
        "text": "needle",
        "prefix": "before ",
        "suffix": " after",
        "selection": "cursor_after",
      ]
    )
  )

  #expect(accessibility.setValues.map(\.value) == ["replacement"])
  #expect(accessibility.secondaryActions.map(\.action) == ["Show Menu"])
  #expect(accessibility.selections.map(\.selection) == [.cursorAfter])
  #expect(accessibility.setValues.allSatisfy { CFEqual($0.element, element) })
}

@Test func pasteUsesOfficialFormatAndRequiresCurrentSnapshot() throws {
  let app = actionTestApp()
  let cache = ElementSnapshotCache()
  cache.store(testActionSnapshot(), for: app)
  let paste = RecordingPasteOperation()
  let performer = MacAppActionPerformer(
    resolver: StubActionResolver(app: app),
    snapshotCache: cache,
    activator: RecordingActivator(),
    frameReader: StubFrameReader(frame: nil),
    mouseClickPoster: RecordingMouseClickPoster(),
    pasteOperation: paste
  )

  _ = try performer.performAction(
    request: actionRequest(
      name: "paste",
      payload: ["text": "**hello**", "format": "md"]
    )
  )

  #expect(paste.requests == [RecordedPaste(text: "**hello**", format: .markdown)])
}

private struct StubActionResolver: MacAppResolving {
  let app: ResolvedMacApp

  func resolve(_ value: Any?) throws -> ResolvedMacApp { app }

  func frontWindow(for app: ResolvedMacApp) throws -> ResolvedMacWindow {
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

private struct RecordedScroll: Equatable {
  let point: CGPoint
  let direction: ComputerUseScrollDirection
  let pages: Double
}

private final class RecordingScrollEventPoster: ScrollEventPosting, @unchecked Sendable {
  private(set) var scrolls: [RecordedScroll] = []

  func scroll(
    at point: CGPoint,
    direction: ComputerUseScrollDirection,
    pages: Double
  ) throws {
    scrolls.append(RecordedScroll(point: point, direction: direction, pages: pages))
  }
}

private final class RecordingAccessibilityPageScroller: AccessibilityPageScrolling,
  @unchecked Sendable
{
  struct Request {
    let element: AXUIElement
    let direction: ComputerUseScrollDirection
    let pageCount: Int
  }

  private let completedPages: Int
  private(set) var requests: [Request] = []

  init(completedPages: Int) {
    self.completedPages = completedPages
  }

  func scroll(
    element: AXUIElement,
    direction: ComputerUseScrollDirection,
    pageCount: Int
  ) throws -> Int {
    requests.append(Request(element: element, direction: direction, pageCount: pageCount))
    return min(completedPages, pageCount)
  }
}

private struct RecordedDrag: Equatable {
  let from: CGPoint
  let to: CGPoint
}

private final class RecordingMouseDragPoster: MouseDragPosting, @unchecked Sendable {
  private(set) var drags: [RecordedDrag] = []

  func drag(from start: CGPoint, to end: CGPoint) throws {
    drags.append(RecordedDrag(from: start, to: end))
  }
}

private final class RecordingAccessibilityActions: AccessibilityActionPerforming,
  @unchecked Sendable
{
  struct SetValueRecord {
    let value: String
    let element: AXUIElement
  }
  struct SecondaryRecord {
    let action: String
    let element: AXUIElement
  }
  struct SelectionRecord {
    let text: String
    let prefix: String?
    let suffix: String?
    let selection: TextSelectionKind
    let element: AXUIElement
  }

  private(set) var setValues: [SetValueRecord] = []
  private(set) var secondaryActions: [SecondaryRecord] = []
  private(set) var selections: [SelectionRecord] = []

  func setValue(_ value: String, on element: AXUIElement) throws {
    setValues.append(SetValueRecord(value: value, element: element))
  }

  func performSecondaryAction(_ action: String, on element: AXUIElement) throws {
    secondaryActions.append(SecondaryRecord(action: action, element: element))
  }

  func selectText(
    _ text: String,
    prefix: String?,
    suffix: String?,
    selection: TextSelectionKind,
    on element: AXUIElement
  ) throws {
    selections.append(
      SelectionRecord(
        text: text,
        prefix: prefix,
        suffix: suffix,
        selection: selection,
        element: element
      )
    )
  }
}

private final class RecordingAccessibilityPrimaryClicker: AccessibilityPrimaryClicking,
  @unchecked Sendable
{
  private let didClick: Bool
  private(set) var elements: [AXUIElement] = []

  init(didClick: Bool) {
    self.didClick = didClick
  }

  func click(element: AXUIElement) throws -> Bool {
    elements.append(element)
    return didClick
  }
}

private final class RecordingComputerUseVisualizer: ComputerUseVisualizing,
  @unchecked Sendable
{
  private(set) var moves: [CGPoint] = []
  private(set) var clicks: [CGPoint] = []
  private(set) var drags: [(CGPoint, CGPoint)] = []

  func moveCursor(to point: CGPoint) { moves.append(point) }
  func showClick(at point: CGPoint) { clicks.append(point) }
  func showDrag(from start: CGPoint, to end: CGPoint) { drags.append((start, end)) }
}

private struct RecordedPaste: Equatable {
  let text: String
  let format: PasteContentFormat
}

private final class RecordingPasteOperation: PastePerforming, @unchecked Sendable {
  private(set) var requests: [RecordedPaste] = []

  func paste(
    text: String,
    format: PasteContentFormat,
    keyboard: any KeyboardInputPosting
  ) throws {
    requests.append(RecordedPaste(text: text, format: format))
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

private func scrollRequest(at: [String: Any], direction: Any, pages: Any) -> [String: Any] {
  actionRequest(
    name: "scroll",
    payload: ["at": at, "direction": direction, "pages": pages]
  )
}

private func testActionSnapshot() -> CapturedAccessibilitySnapshot {
  CapturedAccessibilitySnapshot(text: "test", elementsByID: [:])
}

private func testCoordinateSpace() -> WindowCoordinateSpace {
  WindowCoordinateSpace(
    screenFrame: CGRect(x: 100, y: 150, width: 400, height: 300),
    screenshotPixelSize: CGSize(width: 800, height: 600)
  )
}
