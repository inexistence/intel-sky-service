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

@Test func rejectsEmptyUnknownAndAmbiguousKeyChords() {
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("Ctrl+") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("not-a-key") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("a+b") }
  #expect(throws: MacAppActionError.self) { try MacKeyChordParser().parse("Ctrl+Shift") }
}
