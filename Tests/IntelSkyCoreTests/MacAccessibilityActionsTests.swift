import Foundation
import Testing

@testable import IntelSkyCore

@Test func textSelectionUsesUTF16Offsets() throws {
  let value = "A👋 before needle after"

  let range = try TextSelectionResolver.resolve(
    text: "needle",
    in: value,
    prefix: "before ",
    suffix: " after"
  )

  #expect(range.location == 11)
  #expect(range.length == 6)
}

@Test func textSelectionRequiresDisambiguationForRepeatedText() throws {
  #expect(throws: MacAccessibilityActionError.self) {
    try TextSelectionResolver.resolve(
      text: "same",
      in: "first same then same end",
      prefix: nil,
      suffix: nil
    )
  }

  let range = try TextSelectionResolver.resolve(
    text: "same",
    in: "first same then same end",
    prefix: "then ",
    suffix: " end"
  )
  #expect(range.location == 16)
  #expect(range.length == 4)
}
