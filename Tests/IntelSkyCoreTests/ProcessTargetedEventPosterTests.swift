import AppKit
import Testing

@testable import IntelSkyCore

@Test func syntheticFocusSequenceMatchesOfficialProcessNotifications() throws {
  let target = ComputerUseEventTarget(
    processIdentifier: 42,
    windowID: 77,
    screenFrame: CGRect(x: 100, y: 150, width: 400, height: 300),
    activationPoint: CGPoint(x: 240, y: 172)
  )

  let sequence = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)

  #expect(
    sequence.begin == [
      SyntheticFocusEventDescriptor(type: 21, subtype: 0x8000, windowNumber: 0),
      SyntheticFocusEventDescriptor(
        type: 13,
        subtype: 1,
        windowNumber: 77,
        location: CGPoint(x: 240, y: 172),
        modifierFlags: NSEvent.ModifierFlags(rawValue: 0xC0000)
      ),
      SyntheticFocusEventDescriptor(
        type: UInt(CGEventType.leftMouseDown.rawValue),
        subtype: 0,
        windowNumber: 77,
        location: CGPoint(x: 240, y: 172),
        targetWindowID: 77,
        mouseType: .leftMouseDown,
        windowLocation: CGPoint(x: 140, y: 22)
      ),
      SyntheticFocusEventDescriptor(
        type: UInt(CGEventType.leftMouseUp.rawValue),
        subtype: 0,
        windowNumber: 77,
        location: CGPoint(x: 240, y: 172),
        targetWindowID: 77,
        mouseType: .leftMouseUp,
        windowLocation: CGPoint(x: 140, y: 22)
      ),
    ]
  )
  #expect(ProcessTargetedEventPoster.isWindowLocationSPIAvailable)
  #expect(
    sequence.end == [
      SyntheticFocusEventDescriptor(type: 13, subtype: 2, windowNumber: 0),
      SyntheticFocusEventDescriptor(type: 21, subtype: 0x4000, windowNumber: 0),
    ]
  )

  for descriptor in sequence.begin + sequence.end {
    let event = try ProcessTargetedEventPoster.makeOtherEvent(descriptor)
    let appKitEvent = try #require(NSEvent(cgEvent: event))
    #expect(appKitEvent.type.rawValue == descriptor.type)
    if descriptor.mouseType == nil {
      #expect(UInt16(bitPattern: appKitEvent.subtype.rawValue) == descriptor.subtype)
      #expect(appKitEvent.windowNumber == descriptor.windowNumber)
      #expect(appKitEvent.locationInWindow == descriptor.location)
      #expect(appKitEvent.modifierFlags == descriptor.modifierFlags)
    } else {
      #expect(event.location == descriptor.location)
      #expect(event.getIntegerValueField(.mouseEventClickState) == 1)
      #expect(event.getIntegerValueField(.mouseEventButtonNumber) == 0)
      #expect(event.getIntegerValueField(.mouseEventSubtype) == 3)
    }
    if let targetWindowID = descriptor.targetWindowID {
      #expect(
        event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
          == Int64(targetWindowID)
      )
      #expect(
        event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
          == Int64(targetWindowID)
      )
    }
  }
}
