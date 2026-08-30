import ApplicationServices
import Foundation

public enum ElementSnapshotCacheError: Error, CustomStringConvertible, Equatable {
  case missingSnapshot(String)
  case expiredSnapshot(String)
  case unknownElement(String, app: String)
  case elementAmbiguousBeforeRefetch
  case elementAmbiguousAfterRefetch
  case elementNoLongerValid
  case elementNoLongerValidAfterRefetch
  case missingCoordinateSpace(String)
  case coordinateOutsideScreenshot(CGPoint, size: CGSize)

  public var description: String {
    switch self {
    case .missingSnapshot(let app):
      return "No Accessibility snapshot is cached for \(app); call getAppState first"
    case .expiredSnapshot(let app):
      return "The Accessibility snapshot for \(app) has expired; call getAppState again"
    case .unknownElement(let elementID, app: _):
      return "\(elementID) is an invalid element ID"
    case .elementAmbiguousBeforeRefetch:
      return "The element was invalidated, and an attempt was made to refetch it, but the refetch couldn't be started because multiple elements were found that match the criteria. Try to get the on-screen content again and see if that resolves the issue."
    case .elementAmbiguousAfterRefetch:
      return "The element was invalidated, and an attempt was made to refetch it, but the refetch couldn't be finished because multiple elements were found that match the criteria. Try to get the on-screen content again and see if that resolves the issue."
    case .elementNoLongerValid, .elementNoLongerValidAfterRefetch:
      return "The element ID is no longer valid. Try to get the on-screen content again and see if that resolves the issue."
    case .missingCoordinateSpace(let app):
      return "The latest state for \(app) has no screenshot coordinate space"
    case .coordinateOutsideScreenshot(let point, let size):
      return
        "Screenshot coordinate (\(point.x), \(point.y)) is outside \(size.width)x\(size.height)"
    }
  }
}

enum AccessibilityElementValidity: Sendable {
  case valid
  case invalid
  case indeterminate
}

protocol AccessibilityElementValidityChecking: Sendable {
  func validity(of element: AXUIElement) -> AccessibilityElementValidity
}

struct NativeAccessibilityElementValidityChecker: AccessibilityElementValidityChecking {
  func validity(of element: AXUIElement) -> AccessibilityElementValidity {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) {
    case .success: return .valid
    case .invalidUIElement: return .invalid
    default: return .indeterminate
    }
  }
}

protocol AccessibilitySnapshotRefetching: Sendable {
  func capture(app: ResolvedMacApp) throws -> CapturedAccessibilitySnapshot
}

extension AccessibilitySnapshotter: AccessibilitySnapshotRefetching {}

struct WindowCoordinateSpace: Sendable, Equatable {
  let windowID: CGWindowID
  let screenFrame: CGRect
  let screenshotPixelSize: CGSize
  let activationPoint: CGPoint?

  init(
    windowID: CGWindowID,
    screenFrame: CGRect,
    screenshotPixelSize: CGSize,
    activationPoint: CGPoint? = nil
  ) {
    self.windowID = windowID
    self.screenFrame = screenFrame
    self.screenshotPixelSize = screenshotPixelSize
    self.activationPoint = activationPoint
  }

  func screenPoint(for screenshotPoint: CGPoint) throws -> CGPoint {
    guard screenshotPixelSize.width > 0, screenshotPixelSize.height > 0,
      screenshotPoint.x.isFinite, screenshotPoint.y.isFinite,
      screenshotPoint.x >= 0, screenshotPoint.y >= 0,
      screenshotPoint.x <= screenshotPixelSize.width,
      screenshotPoint.y <= screenshotPixelSize.height
    else {
      throw ElementSnapshotCacheError.coordinateOutsideScreenshot(
        screenshotPoint,
        size: screenshotPixelSize
      )
    }
    return CGPoint(
      x: screenFrame.minX + screenshotPoint.x * screenFrame.width / screenshotPixelSize.width,
      y: screenFrame.minY + screenshotPoint.y * screenFrame.height / screenshotPixelSize.height
    )
  }
}

struct ComputerUseEventTarget: Sendable, Equatable {
  let processIdentifier: pid_t
  let windowID: CGWindowID
  let screenFrame: CGRect
  let activationPoint: CGPoint?

  init(
    processIdentifier: pid_t,
    windowID: CGWindowID,
    screenFrame: CGRect,
    activationPoint: CGPoint? = nil
  ) {
    self.processIdentifier = processIdentifier
    self.windowID = windowID
    self.screenFrame = screenFrame
    self.activationPoint = activationPoint
  }
}

public final class ElementSnapshotCache: @unchecked Sendable {
  private struct Key: Hashable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
  }

  private struct Entry {
    let createdAt: Date
    let elementsByID: [String: AXUIElement]
    let locatorsByID: [String: AccessibilityElementLocator]
    let coordinateSpace: WindowCoordinateSpace?
  }

  private let lock = NSLock()
  private let maximumAge: TimeInterval
  private let maximumEntries: Int
  private let validityChecker: any AccessibilityElementValidityChecking
  private let refetcher: any AccessibilitySnapshotRefetching
  private var entries: [Key: Entry] = [:]

  public convenience init(maximumAge: TimeInterval = 5 * 60, maximumEntries: Int = 16) {
    self.init(
      maximumAge: maximumAge,
      maximumEntries: maximumEntries,
      validityChecker: NativeAccessibilityElementValidityChecker(),
      refetcher: AccessibilitySnapshotter()
    )
  }

  init(
    maximumAge: TimeInterval = 5 * 60,
    maximumEntries: Int = 16,
    validityChecker: any AccessibilityElementValidityChecking,
    refetcher: any AccessibilitySnapshotRefetching
  ) {
    self.maximumAge = max(0, maximumAge)
    self.maximumEntries = max(1, maximumEntries)
    self.validityChecker = validityChecker
    self.refetcher = refetcher
  }

  func store(
    _ snapshot: CapturedAccessibilitySnapshot,
    for app: ResolvedMacApp,
    coordinateSpace: WindowCoordinateSpace? = nil,
    at date: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }

    let key = Key(
      bundleIdentifier: app.bundleIdentifier,
      processIdentifier: app.processIdentifier
    )
    entries = entries.filter { existing, _ in
      existing.bundleIdentifier != app.bundleIdentifier
    }
    entries[key] = Entry(
      createdAt: date,
      elementsByID: snapshot.elementsByID,
      locatorsByID: snapshot.locatorsByID,
      coordinateSpace: coordinateSpace
    )

    while entries.count > maximumEntries,
      let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
    {
      entries.removeValue(forKey: oldest)
    }
  }

  func actionElement(
    id: String,
    for app: ResolvedMacApp,
    at date: Date = Date()
  ) throws -> AXUIElement {
    let original: AXUIElement
    let locator: AccessibilityElementLocator?
    let key = Key(bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    lock.lock()
    do {
      let entry = try validEntry(for: app, at: date)
      guard let element = entry.elementsByID[id] else {
        throw ElementSnapshotCacheError.unknownElement(id, app: app.bundleIdentifier)
      }
      original = element
      locator = entry.locatorsByID[id]
      lock.unlock()
    } catch {
      lock.unlock()
      throw error
    }

    guard validityChecker.validity(of: original) == .invalid else { return original }
    guard let locator else { throw ElementSnapshotCacheError.elementNoLongerValid }

    let fresh = try refetcher.capture(app: app)
    let pathMatches = fresh.locatorsByID.filter { locator.safelyMatchesAtSamePath($0.value) }
    let semanticMatches = fresh.locatorsByID.filter {
      locator.hasStableLabel && locator.semanticallyMatches($0.value)
    }
    let candidates = pathMatches.isEmpty ? semanticMatches : pathMatches
    guard candidates.count <= 1 else {
      throw ElementSnapshotCacheError.elementAmbiguousAfterRefetch
    }
    guard let match = candidates.first,
      let replacement = fresh.elementsByID[match.key]
    else {
      throw ElementSnapshotCacheError.elementNoLongerValidAfterRefetch
    }

    lock.lock()
    defer { lock.unlock() }
    guard var entry = entries[key], date.timeIntervalSince(entry.createdAt) <= maximumAge else {
      throw ElementSnapshotCacheError.expiredSnapshot(app.bundleIdentifier)
    }
    var elements = entry.elementsByID
    var locators = entry.locatorsByID
    elements[id] = replacement
    locators[id] = match.value
    entry = Entry(
      createdAt: entry.createdAt,
      elementsByID: elements,
      locatorsByID: locators,
      coordinateSpace: entry.coordinateSpace
    )
    entries[key] = entry
    return replacement
  }

  func element(
    id: String,
    for app: ResolvedMacApp,
    at date: Date = Date()
  ) throws -> AXUIElement {
    lock.lock()
    defer { lock.unlock() }

    let entry = try validEntry(for: app, at: date)
    guard let element = entry.elementsByID[id] else {
      throw ElementSnapshotCacheError.unknownElement(id, app: app.bundleIdentifier)
    }
    return element
  }

  func validateSnapshot(for app: ResolvedMacApp, at date: Date = Date()) throws {
    lock.lock()
    defer { lock.unlock() }
    _ = try validEntry(for: app, at: date)
  }

  func screenPoint(
    for screenshotPoint: CGPoint,
    in app: ResolvedMacApp,
    at date: Date = Date()
  ) throws -> CGPoint {
    lock.lock()
    defer { lock.unlock() }
    let entry = try validEntry(for: app, at: date)
    guard let coordinateSpace = entry.coordinateSpace else {
      throw ElementSnapshotCacheError.missingCoordinateSpace(app.bundleIdentifier)
    }
    return try coordinateSpace.screenPoint(for: screenshotPoint)
  }

  func eventTarget(for app: ResolvedMacApp, at date: Date = Date()) throws
    -> ComputerUseEventTarget
  {
    lock.lock()
    defer { lock.unlock() }
    let entry = try validEntry(for: app, at: date)
    guard let coordinateSpace = entry.coordinateSpace else {
      throw ElementSnapshotCacheError.missingCoordinateSpace(app.bundleIdentifier)
    }
    return ComputerUseEventTarget(
      processIdentifier: app.processIdentifier,
      windowID: coordinateSpace.windowID,
      screenFrame: coordinateSpace.screenFrame,
      activationPoint: coordinateSpace.activationPoint
    )
  }

  private func validEntry(for app: ResolvedMacApp, at date: Date) throws -> Entry {
    let key = Key(
      bundleIdentifier: app.bundleIdentifier,
      processIdentifier: app.processIdentifier
    )
    guard let entry = entries[key] else {
      throw ElementSnapshotCacheError.missingSnapshot(app.bundleIdentifier)
    }
    if date.timeIntervalSince(entry.createdAt) > maximumAge {
      entries.removeValue(forKey: key)
      throw ElementSnapshotCacheError.expiredSnapshot(app.bundleIdentifier)
    }
    return entry
  }
}
