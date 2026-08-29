import AppKit
import CoreGraphics
import Foundation

struct SyntheticFocusEventDescriptor: Equatable, Sendable {
  let type: UInt
  let subtype: UInt16
  let windowNumber: Int
}

enum ProcessTargetedEventPoster {
  @TaskLocal private static var activeSyntheticFocusTarget: ComputerUseEventTarget?

  static func withSyntheticFocus<T>(
    on target: ComputerUseEventTarget,
    _ body: () throws -> T
  ) throws -> T {
    if activeSyntheticFocusTarget == target { return try body() }
    let sequence = syntheticFocusSequence(for: target)
    for descriptor in sequence.begin { try postOtherEvent(descriptor, to: target) }
    do {
      let result = try $activeSyntheticFocusTarget.withValue(target) { try body() }
      for descriptor in sequence.end { try? postOtherEvent(descriptor, to: target) }
      return result
    } catch {
      for descriptor in sequence.end { try? postOtherEvent(descriptor, to: target) }
      throw error
    }
  }

  static func post(_ event: CGEvent, to target: ComputerUseEventTarget) {
    event.setIntegerValueField(
      .mouseEventWindowUnderMousePointer,
      value: Int64(target.windowID)
    )
    event.setIntegerValueField(
      .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
      value: Int64(target.windowID)
    )
    event.postToPid(target.processIdentifier)
  }

  static func postKeyboard(_ event: CGEvent, to target: ComputerUseEventTarget) {
    event.postToPid(target.processIdentifier)
  }

  static func syntheticFocusSequence(for target: ComputerUseEventTarget) -> (
    begin: [SyntheticFocusEventDescriptor], end: [SyntheticFocusEventDescriptor]
  ) {
    (
      begin: [
        SyntheticFocusEventDescriptor(
          type: 13,
          subtype: 1,
          windowNumber: Int(target.windowID)
        ),
        SyntheticFocusEventDescriptor(type: 21, subtype: 0x8000, windowNumber: 0),
      ],
      end: [
        SyntheticFocusEventDescriptor(type: 21, subtype: 0x4000, windowNumber: 0),
        SyntheticFocusEventDescriptor(type: 13, subtype: 2, windowNumber: 0),
      ]
    )
  }

  static func makeOtherEvent(_ descriptor: SyntheticFocusEventDescriptor) throws -> CGEvent {
    guard let eventType = NSEvent.EventType(rawValue: descriptor.type),
      let event = NSEvent.otherEvent(
        with: eventType,
        location: .zero,
        modifierFlags: [],
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

  private static func postOtherEvent(
    _ descriptor: SyntheticFocusEventDescriptor,
    to target: ComputerUseEventTarget
  ) throws {
    postKeyboard(try makeOtherEvent(descriptor), to: target)
  }
}
