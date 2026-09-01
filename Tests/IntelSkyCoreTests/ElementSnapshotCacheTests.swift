import ApplicationServices
import Foundation
import Testing

@testable import IntelSkyCore

@Test func snapshotCacheResolvesElementFromLatestSnapshot() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  let element = AXUIElementCreateApplication(10)
  cache.store(testSnapshot(["7": element]), for: app)

  let resolved = try cache.element(id: "7", for: app)

  #expect(CFEqual(resolved, element))
}

@Test func replacingSnapshotInvalidatesOldElementIDs() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  cache.store(testSnapshot(["1": AXUIElementCreateApplication(10)]), for: app)
  cache.store(testSnapshot(["2": AXUIElementCreateApplication(10)]), for: app)

  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.element(id: "1", for: app)
  }
  _ = try cache.element(id: "2", for: app)
}

@Test func snapshotCacheIsThreadScopedAndClearsOnlyEndedThread() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  let first = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "first", "turn_id": "1"])
  )
  let second = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "second", "turn_id": "1"])
  )

  ComputerUseTurnContext.withIdentity(first) {
    cache.store(testSnapshot(["1": AXUIElementCreateApplication(10)]), for: app)
  }
  #expect(throws: ElementSnapshotCacheError.self) {
    try ComputerUseTurnContext.withIdentity(second) { try cache.element(id: "1", for: app) }
  }
  ComputerUseTurnContext.withIdentity(second) {
    cache.store(testSnapshot(["2": AXUIElementCreateApplication(10)]), for: app)
  }

  cache.clear(threadID: first.threadID)
  _ = try ComputerUseTurnContext.withIdentity(second) { try cache.element(id: "2", for: app) }
}

@Test func scopedBoundaryClearsOnlyLegacyUnscopedSnapshots() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  let identity = try #require(
    ComputerUseTurnIdentity(metadata: ["thread_id": "thread", "turn_id": "turn"])
  )
  cache.store(testSnapshot(["legacy": AXUIElementCreateApplication(10)]), for: app)
  ComputerUseTurnContext.withIdentity(identity) {
    cache.store(testSnapshot(["scoped": AXUIElementCreateApplication(10)]), for: app)
  }

  cache.clearUnscoped()

  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.element(id: "legacy", for: app)
  }
  _ = try ComputerUseTurnContext.withIdentity(identity) {
    try cache.element(id: "scoped", for: app)
  }
}

@Test func newProcessInvalidatesPreviousProcessSnapshot() throws {
  let cache = ElementSnapshotCache()
  let oldApp = testApp(pid: 10)
  let relaunchedApp = testApp(pid: 11)
  cache.store(testSnapshot(["1": AXUIElementCreateApplication(10)]), for: oldApp)
  cache.store(testSnapshot(["2": AXUIElementCreateApplication(11)]), for: relaunchedApp)

  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.element(id: "1", for: oldApp)
  }
  _ = try cache.element(id: "2", for: relaunchedApp)
}

@Test func expiredSnapshotIsRejectedAndRemoved() throws {
  let cache = ElementSnapshotCache(maximumAge: 10)
  let app = testApp(pid: 10)
  let createdAt = Date(timeIntervalSince1970: 100)
  cache.store(testSnapshot(["1": AXUIElementCreateApplication(10)]), for: app, at: createdAt)

  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.element(id: "1", for: app, at: createdAt.addingTimeInterval(11))
  }
  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.element(id: "1", for: app, at: createdAt.addingTimeInterval(12))
  }
}

@Test func cacheEvictsOldestAppWhenCapacityIsExceeded() throws {
  let cache = ElementSnapshotCache(maximumEntries: 1)
  let first = testApp(bundleIdentifier: "example.first", pid: 10)
  let second = testApp(bundleIdentifier: "example.second", pid: 20)
  cache.store(
    testSnapshot(["1": AXUIElementCreateApplication(10)]),
    for: first,
    at: Date(timeIntervalSince1970: 100)
  )
  cache.store(
    testSnapshot(["2": AXUIElementCreateApplication(20)]),
    for: second,
    at: Date(timeIntervalSince1970: 101)
  )

  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.element(id: "1", for: first, at: Date(timeIntervalSince1970: 102))
  }
  _ = try cache.element(id: "2", for: second, at: Date(timeIntervalSince1970: 102))
}

@Test func screenshotCoordinatesMapThroughWindowOriginAndRetinaScale() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot([:]),
    for: app,
    coordinateSpace: WindowCoordinateSpace(
      windowID: 77,
      screenFrame: CGRect(x: 100, y: 200, width: 400, height: 300),
      screenshotPixelSize: CGSize(width: 800, height: 600)
    )
  )

  let point = try cache.screenPoint(for: CGPoint(x: 200, y: 100), in: app)
  let target = try cache.eventTarget(for: app)

  #expect(point == CGPoint(x: 200, y: 250))
  #expect(
    target
      == ComputerUseEventTarget(
        processIdentifier: 10,
        windowID: 77,
        screenFrame: CGRect(x: 100, y: 200, width: 400, height: 300)
      )
  )
}

@Test func screenshotCoordinateRequiresImageAndRejectsOutOfBoundsPoint() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  cache.store(testSnapshot([:]), for: app)
  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.screenPoint(for: .zero, in: app)
  }

  cache.store(
    testSnapshot([:]),
    for: app,
    coordinateSpace: WindowCoordinateSpace(
      windowID: 77,
      screenFrame: CGRect(x: 100, y: 200, width: 400, height: 300),
      screenshotPixelSize: CGSize(width: 800, height: 600)
    )
  )
  #expect(throws: ElementSnapshotCacheError.self) {
    try cache.screenPoint(for: CGPoint(x: 801, y: 10), in: app)
  }
}

@Test func invalidActionElementRefetchesOnlyTheSameSemanticPath() throws {
  let original = AXUIElementCreateApplication(10)
  let replacement = AXUIElementCreateApplication(11)
  let locator = testLocator(path: [0, 2], title: "Save")
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.invalid),
    refetcher: FixedSnapshotRefetcher(
      testSnapshot(["91": replacement], locators: ["91": locator])
    )
  )
  let app = testApp(pid: 10)
  cache.store(testSnapshot(["7": original], locators: ["7": locator]), for: app)

  let resolved = try cache.actionElement(id: "7", for: app)
  let resolvedAgain = try cache.element(id: "7", for: app)

  #expect(CFEqual(resolved, replacement))
  #expect(CFEqual(resolvedAgain, replacement))
}

@Test func invalidActionElementCanFollowOneUniquelyLabeledMovedElement() throws {
  let replacement = AXUIElementCreateApplication(11)
  let oldLocator = testLocator(path: [0, 2], title: "Save")
  let movedLocator = testLocator(path: [1, 4], title: "Save")
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.invalid),
    refetcher: FixedSnapshotRefetcher(
      testSnapshot(["91": replacement], locators: ["91": movedLocator])
    )
  )
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(["7": AXUIElementCreateApplication(10)], locators: ["7": oldLocator]),
    for: app
  )

  #expect(CFEqual(try cache.actionElement(id: "7", for: app), replacement))
}

@Test func invalidActionElementFailsClosedWhenRefetchIsAmbiguous() throws {
  let locator = testLocator(path: [0, 2], title: "Save")
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.invalid),
    refetcher: FixedSnapshotRefetcher(
      testSnapshot(
        ["91": AXUIElementCreateApplication(11), "92": AXUIElementCreateApplication(12)],
        locators: [
          "91": testLocator(path: [1, 4], title: "Save"),
          "92": testLocator(path: [1, 5], title: "Save"),
        ]
      )
    )
  )
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(["7": AXUIElementCreateApplication(10)], locators: ["7": locator]),
    for: app
  )

  #expect(throws: ElementSnapshotCacheError.elementAmbiguousAfterRefetch) {
    try cache.actionElement(id: "7", for: app)
  }
}

@Test func invalidUnlabeledElementDoesNotRebindAcrossGeometryChange() throws {
  let locator = testLocator(
    path: [0, 2], title: nil, frame: CGRect(x: 0, y: 0, width: 50, height: 20))
  let moved = testLocator(
    path: [0, 2], title: nil, frame: CGRect(x: 80, y: 0, width: 50, height: 20))
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.invalid),
    refetcher: FixedSnapshotRefetcher(
      testSnapshot(["91": AXUIElementCreateApplication(11)], locators: ["91": moved])
    )
  )
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(["7": AXUIElementCreateApplication(10)], locators: ["7": locator]),
    for: app
  )

  #expect(throws: ElementSnapshotCacheError.elementNoLongerValidAfterRefetch) {
    try cache.actionElement(id: "7", for: app)
  }
}

@Test func destroyedNotificationRefetchesBeforeAXProbeReportsInvalid() throws {
  let original = AXUIElementCreateApplication(10)
  let replacement = AXUIElementCreateApplication(11)
  let locator = testLocator(path: [0, 2], title: "Save")
  let monitor = FixedInvalidationMonitor(destroyedElement: original)
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.valid),
    refetcher: FixedSnapshotRefetcher(
      testSnapshot(["91": replacement], locators: ["91": locator])
    )
  )
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(
      ["7": original],
      locators: ["7": locator],
      invalidationMonitor: monitor
    ),
    for: app
  )

  #expect(CFEqual(try cache.actionElement(id: "7", for: app), replacement))
}

@Test func focusedWindowChangeInvalidatesElementAndCoordinateTargets() throws {
  let cache = ElementSnapshotCache()
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(
      ["7": AXUIElementCreateApplication(10)],
      invalidationMonitor: FixedInvalidationMonitor(focusedWindowChanged: true)
    ),
    for: app,
    coordinateSpace: WindowCoordinateSpace(
      windowID: 77,
      screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
      screenshotPixelSize: CGSize(width: 100, height: 100)
    )
  )

  #expect(throws: ElementSnapshotCacheError.focusedWindowChanged(app.bundleIdentifier)) {
    try cache.element(id: "7", for: app)
  }
  #expect(throws: ElementSnapshotCacheError.focusedWindowChanged(app.bundleIdentifier)) {
    try cache.screenPoint(for: CGPoint(x: 10, y: 10), in: app)
  }
}

@Test func layoutChangeRefetchesElementsButRejectsCoordinateTargets() throws {
  let original = AXUIElementCreateApplication(10)
  let replacement = AXUIElementCreateApplication(11)
  let locator = testLocator(path: [0, 2], title: "Save")
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.valid),
    refetcher: FixedSnapshotRefetcher(
      testSnapshot(["91": replacement], locators: ["91": locator])
    )
  )
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(
      ["7": original],
      locators: ["7": locator],
      invalidationMonitor: FixedInvalidationMonitor(layoutChanged: true)
    ),
    for: app,
    coordinateSpace: WindowCoordinateSpace(
      windowID: 77,
      screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
      screenshotPixelSize: CGSize(width: 100, height: 100)
    )
  )

  #expect(CFEqual(try cache.actionElement(id: "7", for: app), replacement))

  cache.store(
    testSnapshot(
      ["7": original],
      invalidationMonitor: FixedInvalidationMonitor(layoutChanged: true)
    ),
    for: app,
    coordinateSpace: WindowCoordinateSpace(
      windowID: 77,
      screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
      screenshotPixelSize: CGSize(width: 100, height: 100)
    )
  )
  #expect(throws: ElementSnapshotCacheError.layoutChanged(app.bundleIdentifier)) {
    try cache.screenPoint(for: CGPoint(x: 10, y: 10), in: app)
  }
}

@Test func ephemeralElementRequiresFreshTreeMembershipEvenWhenAXReferenceIsValid() throws {
  let original = AXUIElementCreateApplication(10)
  let locator = testLocator(path: [0, 2], title: "Show Info", role: "AXMenuItem")
  let cache = ElementSnapshotCache(
    validityChecker: FixedElementValidityChecker(.valid),
    refetcher: FixedSnapshotRefetcher(testSnapshot([:]))
  )
  let app = testApp(pid: 10)
  cache.store(
    testSnapshot(["7": original], locators: ["7": locator]),
    for: app
  )

  #expect(throws: ElementSnapshotCacheError.elementNoLongerValidAfterRefetch) {
    try cache.actionElement(id: "7", for: app)
  }
}

private func testApp(bundleIdentifier: String = "example.app", pid: pid_t) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: pid,
    bundleIdentifier: bundleIdentifier,
    displayName: bundleIdentifier,
    appPath: "/Applications/Test.app"
  )
}

private func testSnapshot(
  _ elements: [String: AXUIElement],
  locators: [String: AccessibilityElementLocator] = [:],
  invalidationMonitor: (any AccessibilitySnapshotInvalidationMonitoring)? = nil
) -> CapturedAccessibilitySnapshot {
  CapturedAccessibilitySnapshot(
    text: "test",
    elementsByID: elements,
    locatorsByID: locators,
    invalidationMonitor: invalidationMonitor
  )
}

private func testLocator(
  path: [Int],
  title: String?,
  frame: CGRect = CGRect(x: 10, y: 20, width: 50, height: 20),
  role: String = "AXButton"
) -> AccessibilityElementLocator {
  AccessibilityElementLocator(
    path: path,
    rolePath: ["AXWindow", role],
    role: role,
    subrole: nil,
    identifier: nil,
    title: title,
    description: nil,
    frame: frame
  )
}

private struct FixedElementValidityChecker: AccessibilityElementValidityChecking {
  let result: AccessibilityElementValidity

  init(_ result: AccessibilityElementValidity) { self.result = result }

  func validity(of element: AXUIElement) -> AccessibilityElementValidity { result }
}

private struct FixedSnapshotRefetcher: AccessibilitySnapshotRefetching {
  let snapshot: CapturedAccessibilitySnapshot

  init(_ snapshot: CapturedAccessibilitySnapshot) { self.snapshot = snapshot }

  func capture(app: ResolvedMacApp) throws -> CapturedAccessibilitySnapshot { snapshot }
}

private struct FixedInvalidationMonitor: @unchecked Sendable,
  AccessibilitySnapshotInvalidationMonitoring
{
  var focusedWindowChanged = false
  var layoutChanged = false
  var destroyedElement: AXUIElement?

  func wasDestroyed(_ element: AXUIElement) -> Bool {
    destroyedElement.map { CFEqual($0, element) } ?? false
  }
}
