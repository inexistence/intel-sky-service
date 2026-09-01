import Testing

@testable import IntelSkyCore

@Test func parsesDocumentedX11StyleKeyChord() throws {
  let chord = try MacKeyChordParser().parse("Control_L + Shift_L + period")

  #expect(chord.keyCode == 47)
  #expect(chord.modifiers == [.control, .shift])
}

@Test func parsesCommandAliasAndUppercaseCharacter() throws {
  let commandChord = try MacKeyChordParser().parse("Super_L+d")
  let uppercaseChord = try MacKeyChordParser().parse("A")

  #expect(commandChord == ParsedKeyChord(keyCode: 2, modifiers: [.command]))
  #expect(uppercaseChord == ParsedKeyChord(keyCode: 0, modifiers: [.shift]))
}

@Test func parsesDocumentedKeypadAliases() throws {
  #expect(try MacKeyChordParser().parse("KP_0").keyCode == 82)
  #expect(try MacKeyChordParser().parse("Numpad_0").keyCode == 82)
}

@Test func distinguishesRightHandedModifiers() throws {
  let parser = MacKeyChordParser()
  let chord = try parser.parse("Control_R+Alt_R+Shift_R+Super_R+a")

  #expect(
    chord.modifiers
      == [.controlRight, .optionRight, .shiftRight, .commandRight]
  )
  #expect(chord.keyCode == 0)
}

@Test func parsesOfficialExtendedXKeysymNames() throws {
  let parser = MacKeyChordParser()

  #expect(try parser.parse("KP_Page_Up").keyCode == 92)
  #expect(try parser.parse("KP_Delete").keyCode == 65)
  #expect(try parser.parse("KP_Equal").keyCode == 81)
  #expect(try parser.parse("Prior").keyCode == 116)
  #expect(try parser.parse("Next").keyCode == 121)
  #expect(try parser.parse("Help").keyCode == 114)
}

@Test func distinguishesX11BackspaceAndDelete() throws {
  #expect(try MacKeyChordParser().parse("BackSpace").keyCode == 51)
  #expect(try MacKeyChordParser().parse("Delete").keyCode == 117)
}

@Test func unicodeChunksPreserveSurrogatePairsAtBoundary() {
  let text = String(repeating: "a", count: 19) + "👋" + String(repeating: "b", count: 20)
  let chunks = CGKeyboardInputPoster.utf16Chunks(for: text)
  let reconstructed = String(decoding: chunks.flatMap { $0 }, as: UTF16.self)

  #expect(chunks.map(\.count) == [19, 20, 2])
  #expect(reconstructed == text)
  #expect(chunks.allSatisfy { $0.count <= 20 })
}

@Test func keyboardEventsMatchARMVirtualKeyPressEnvelope() throws {
  let chord = try MacKeyChordParser().parse("Control_L+Shift_L+period")
  let events = try CGKeyboardInputPoster.events(for: chord)

  #expect(CGKeyboardInputPoster.eventSourceStateID == .hidSystemState)
  #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
  #expect(events[0].flags == [.maskControl, .maskShift])
  #expect(events[1].flags == [.maskControl, .maskShift])
  #expect(events[2].flags == [.maskControl, .maskShift])
  #expect(events[1].getIntegerValueField(.keyboardEventKeycode) == 47)
  #expect(events[2].getIntegerValueField(.keyboardEventKeycode) == 47)
}

@Test func typedCharactersUseARMKeyCodesAndUnicodeFallback() throws {
  let groups = try CGKeyboardInputPoster.eventsForTyping("A\n👋")

  #expect(groups.count == 3)
  #expect(groups.allSatisfy { $0.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged] })
  #expect(groups[0][1].getIntegerValueField(.keyboardEventKeycode) == 0)
  #expect(groups[0][1].flags.contains(.maskShift))
  #expect(groups[1][1].getIntegerValueField(.keyboardEventKeycode) == 36)
  #expect(groups[2][1].getIntegerValueField(.keyboardEventKeycode) == 0)
}

@Test func rejectsEmptyUnknownAndAmbiguousKeyChords() {
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("Ctrl+") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("not-a-key") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("a+b") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("Ctrl+Shift") }
}
