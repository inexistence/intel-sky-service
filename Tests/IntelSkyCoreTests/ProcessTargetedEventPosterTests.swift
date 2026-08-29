import AppKit
import Testing

@testable import IntelSkyCore

@Test func syntheticFocusSequenceMatchesOfficialProcessNotifications() throws {
  let target = ComputerUseEventTarget(
    processIdentifier: 42,
    windowID: 77,
    screenFrame: CGRect(x: 100, y: 150, width: 400, height: 300)
  )

  let sequence = ProcessTargetedEventPoster.syntheticFocusSequence(for: target)

  #expect(
    sequence.begin == [
      SyntheticFocusEventDescriptor(type: 21, subtype: 0x8000, windowNumber: 0),
      SyntheticFocusEventDescriptor(type: 13, subtype: 1, windowNumber: 0),
    ]
  )
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
    #expect(UInt16(bitPattern: appKitEvent.subtype.rawValue) == descriptor.subtype)
    #expect(appKitEvent.windowNumber == descriptor.windowNumber)
  }
}
