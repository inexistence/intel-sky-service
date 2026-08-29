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

private func testApp(bundleIdentifier: String = "example.app", pid: pid_t) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: pid,
    bundleIdentifier: bundleIdentifier,
    displayName: bundleIdentifier,
    appPath: "/Applications/Test.app"
  )
}

private func testSnapshot(_ elements: [String: AXUIElement]) -> CapturedAccessibilitySnapshot {
  CapturedAccessibilitySnapshot(text: "test", elementsByID: elements)
}
