import ApplicationServices
import Foundation

public enum ElementSnapshotCacheError: Error, CustomStringConvertible {
  case missingSnapshot(String)
  case expiredSnapshot(String)
  case unknownElement(String, app: String)
  case missingCoordinateSpace(String)
  case coordinateOutsideScreenshot(CGPoint, size: CGSize)

  public var description: String {
    switch self {
    case .missingSnapshot(let app):
      return "No Accessibility snapshot is cached for \(app); call getAppState first"
    case .expiredSnapshot(let app):
      return "The Accessibility snapshot for \(app) has expired; call getAppState again"
    case .unknownElement(let elementID, let app):
      return "Element \(elementID) is not present in the latest Accessibility snapshot for \(app)"
    case .missingCoordinateSpace(let app):
      return "The latest state for \(app) has no screenshot coordinate space"
    case .coordinateOutsideScreenshot(let point, let size):
      return
        "Screenshot coordinate (\(point.x), \(point.y)) is outside \(size.width)x\(size.height)"
    }
  }
}

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
    let coordinateSpace: WindowCoordinateSpace?
  }

  private let lock = NSLock()
  private let maximumAge: TimeInterval
  private let maximumEntries: Int
  private var entries: [Key: Entry] = [:]

  public init(maximumAge: TimeInterval = 5 * 60, maximumEntries: Int = 16) {
    self.maximumAge = max(0, maximumAge)
    self.maximumEntries = max(1, maximumEntries)
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
      coordinateSpace: coordinateSpace
    )

    while entries.count > maximumEntries,
      let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
    {
      entries.removeValue(forKey: oldest)
    }
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
