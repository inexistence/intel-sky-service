import AppKit
import CoreGraphics
import Darwin
import Foundation

struct SyntheticFocusEventDescriptor: Equatable, Sendable {
  let type: UInt
  let subtype: UInt16
  let windowNumber: Int
  let location: CGPoint
  let modifierFlags: NSEvent.ModifierFlags
  let targetWindowID: CGWindowID?
  let mouseType: CGEventType?
  let windowLocation: CGPoint?

  init(
    type: UInt,
    subtype: UInt16,
    windowNumber: Int,
    location: CGPoint = .zero,
    modifierFlags: NSEvent.ModifierFlags = [],
    targetWindowID: CGWindowID? = nil,
    mouseType: CGEventType? = nil,
    windowLocation: CGPoint? = nil
  ) {
    self.type = type
    self.subtype = subtype
    self.windowNumber = windowNumber
    self.location = location
    self.modifierFlags = modifierFlags
    self.targetWindowID = targetWindowID
    self.mouseType = mouseType
    self.windowLocation = windowLocation
  }
}

enum ProcessTargetedEventPoster {
  private typealias SetWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void

  private static let setWindowLocationFunction: SetWindowLocationFunction? = {
    // Swift does not import Darwin's RTLD_DEFAULT macro. Looking up the symbol
    // through the main program handle has equivalent visibility for the already
    // loaded CoreGraphics image, and the retained handle keeps the pointer valid.
    guard let handle = dlopen(nil, RTLD_LAZY),
      let symbol = dlsym(handle, "CGEventSetWindowLocation")
    else { return nil }
    return unsafeBitCast(symbol, to: SetWindowLocationFunction.self)
  }()

  static var isWindowLocationSPIAvailable: Bool { setWindowLocationFunction != nil }

  @TaskLocal private static var activeSyntheticFocusTarget: ComputerUseEventTarget?

  static func withSyntheticFocus<T>(
    on target: ComputerUseEventTarget,
    _ body: () throws -> T
  ) throws -> T {
    if activeSyntheticFocusTarget != target {
      switch try ComputerUseFocusCoordinator.shared.withTurnScopedSyntheticFocus(
        on: target,
        body
      ) {
      case .executed(let result): return result
      case .unavailable: break
      }
    }
    return try withSyntheticFocus(
      on: target,
      isApplicationActive: {
        NSRunningApplication(processIdentifier: target.processIdentifier)?.isActive == true
      },
      postDescriptor: { descriptor in
        try postOtherEvent(descriptor, to: target)
      },
      body
    )
  }

  static func withSyntheticFocus<T>(
    on target: ComputerUseEventTarget,
    isApplicationActive: () -> Bool,
    postDescriptor: (SyntheticFocusEventDescriptor) throws -> Void,
    _ body: () throws -> T
  ) throws -> T {
    if activeSyntheticFocusTarget == target { return try body() }

    // The official enforcer seeds its belief and actual-state bits from the
    // running application and emits only missing transitions. An actually
    // active application receives no synthetic activation or deactivation.
    if isApplicationActive() {
      return try $activeSyntheticFocusTarget.withValue(target) { try body() }
    }

    return try SystemFocusStealGuard.shared.withProtection(
      processIdentifier: target.processIdentifier
    ) {
      let sequence = syntheticFocusSequence(for: target)
      for descriptor in sequence.begin { try postDescriptor(descriptor) }

      func deactivateIfStillSynthetic() {
        // The official deactivate path runs only while the application is still
        // actually inactive. Preserve a genuine user/system focus change.
        guard !isApplicationActive() else { return }
        for descriptor in sequence.end { try? postDescriptor(descriptor) }
      }

      do {
        let result = try $activeSyntheticFocusTarget.withValue(target) { try body() }
        deactivateIfStillSynthetic()
        return result
      } catch {
        deactivateIfStillSynthetic()
        throw error
      }
    }
  }

  static func post(_ event: CGEvent, to target: ComputerUseEventTarget) {
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
      .rightMouseDown, .rightMouseUp, .rightMouseDragged,
      .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved:
      // ARM SynthesizedEvent marks process-targeted mouse events as window
      // events. Without this subtype AppKit can route the event to a control
      // belonging to the physical pointer's window instead of the target.
      event.setIntegerValueField(.mouseEventSubtype, value: 3)
    default:
      break
    }
    event.setIntegerValueField(
      .mouseEventWindowUnderMousePointer,
      value: Int64(target.windowID)
    )
    event.setIntegerValueField(
      .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
      value: Int64(target.windowID)
    )
    // Process-targeted CoreGraphics events need both the global event location and
    // the private window-local location. AppKit controls (notably Notes tables)
    // can accept the PID-targeted event while discarding it during hit testing if
    // this field is absent. The ARM SynthesizedEvent path always supplies it.
    if let setWindowLocationFunction {
      setWindowLocationFunction(event, windowLocation(for: event.location, in: target))
    }
    event.postToPid(target.processIdentifier)
  }

  static func windowLocation(
    for screenPoint: CGPoint,
    in target: ComputerUseEventTarget
  ) -> CGPoint {
    // The ARM constructor exposes a windowUsesFlippedCoordinates branch.
    // CGWindow/AX external application frames require its false path, so keep
    // the top-origin Y offset here; Notes hit-testing verifies this mapping.
    CGPoint(
      x: screenPoint.x - target.screenFrame.minX,
      y: screenPoint.y - target.screenFrame.minY
    )
  }

  static func postKeyboard(_ event: CGEvent, to target: ComputerUseEventTarget) {
    event.postToPid(target.processIdentifier)
  }

  static func makeWindowMouseEvent(
    type: CGEventType,
    location: CGPoint,
    button: CGMouseButton,
    target: ComputerUseEventTarget,
    eventNumber: Int = 1,
    clickCount: Int = 1
  ) throws -> CGEvent {
    guard
      let eventType = NSEvent.EventType(rawValue: UInt(type.rawValue)),
      let appKitEvent = NSEvent.mouseEvent(
        with: eventType,
        location: windowLocation(for: location, in: target),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: Int(target.windowID),
        context: nil,
        eventNumber: eventNumber,
        clickCount: clickCount,
        pressure: 1
      ),
      let event = appKitEvent.cgEvent
    else { throw MacAppActionError.eventCreationFailed }
    event.flags = []
    event.location = location
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
    event.setIntegerValueField(.mouseEventSubtype, value: 3)
    return event
  }

  static func syntheticFocusSequence(for target: ComputerUseEventTarget) -> (
    begin: [SyntheticFocusEventDescriptor], end: [SyntheticFocusEventDescriptor]
  ) {
    let activationPoint = target.activationPoint ?? .zero
    let windowLocation = target.activationPoint.map { Self.windowLocation(for: $0, in: target) }
    var begin = [
      SyntheticFocusEventDescriptor(type: 21, subtype: 0x8000, windowNumber: 0),
      SyntheticFocusEventDescriptor(
        type: 13,
        subtype: 1,
        windowNumber: target.activationPoint == nil ? 0 : Int(target.windowID),
        location: activationPoint,
        modifierFlags: target.activationPoint == nil
          ? [] : NSEvent.ModifierFlags(rawValue: 0xC0000)
      ),
    ]
    if target.activationPoint != nil, isWindowLocationSPIAvailable {
      begin.append(
        SyntheticFocusEventDescriptor(
          type: UInt(CGEventType.leftMouseDown.rawValue),
          subtype: 0,
          windowNumber: Int(target.windowID),
          location: activationPoint,
          targetWindowID: target.windowID,
          mouseType: .leftMouseDown,
          windowLocation: windowLocation
        )
      )
      begin.append(
        SyntheticFocusEventDescriptor(
          type: UInt(CGEventType.leftMouseUp.rawValue),
          subtype: 0,
          windowNumber: Int(target.windowID),
          location: activationPoint,
          targetWindowID: target.windowID,
          mouseType: .leftMouseUp,
          windowLocation: windowLocation
        )
      )
    }
    return (
      begin: begin,
      end: [
        SyntheticFocusEventDescriptor(type: 13, subtype: 2, windowNumber: 0),
        SyntheticFocusEventDescriptor(type: 21, subtype: 0x4000, windowNumber: 0),
      ]
    )
  }

  static func makeOtherEvent(_ descriptor: SyntheticFocusEventDescriptor) throws -> CGEvent {
    if let mouseType = descriptor.mouseType {
      guard let eventType = NSEvent.EventType(rawValue: UInt(mouseType.rawValue)),
        let appKitEvent = NSEvent.mouseEvent(
          with: eventType,
          location: descriptor.location,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: descriptor.windowNumber,
          context: nil,
          eventNumber: 1,
          clickCount: 1,
          pressure: 1
        ),
        let event = appKitEvent.cgEvent
      else {
        throw MacAppActionError.eventCreationFailed
      }
      event.flags = []
      event.setIntegerValueField(.mouseEventClickState, value: 1)
      event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
      event.setIntegerValueField(.mouseEventSubtype, value: 3)
      if let targetWindowID = descriptor.targetWindowID {
        event.setIntegerValueField(
          .mouseEventWindowUnderMousePointer,
          value: Int64(targetWindowID)
        )
        event.setIntegerValueField(
          .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
          value: Int64(targetWindowID)
        )
      }
      event.location = descriptor.location
      if let windowLocation = descriptor.windowLocation {
        guard let setWindowLocationFunction else {
          throw MacAppActionError.eventCreationFailed
        }
        setWindowLocationFunction(event, windowLocation)
      }
      return event
    }
    guard let eventType = NSEvent.EventType(rawValue: descriptor.type),
      let event = NSEvent.otherEvent(
        with: eventType,
        location: descriptor.location,
        modifierFlags: descriptor.modifierFlags,
        timestamp: 0,
        windowNumber: descriptor.windowNumber,
        context: nil,
        subtype: Int16(bitPattern: descriptor.subtype),
        data1: 0,
        data2: 0
      ),
      let cgEvent = event.cgEvent
    else {
      throw MacAppActionError.eventCreationFailed
    }
    return cgEvent
  }

  static func postOtherEvent(
    _ descriptor: SyntheticFocusEventDescriptor,
    to target: ComputerUseEventTarget
  ) throws {
    postKeyboard(try makeOtherEvent(descriptor), to: target)
  }
}
