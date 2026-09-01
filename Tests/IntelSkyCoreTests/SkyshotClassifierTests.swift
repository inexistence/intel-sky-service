import ApplicationServices
import Testing

@testable import IntelSkyCore

@Test func skyshotClassifierSuppressesTextOnlyWindows() {
  let snapshot = classifierSnapshot(role: kAXStaticTextRole as String)
  #expect(!SkyshotClassifier().containsImage(snapshot))
}

@Test func skyshotClassifierIncludesVisualAndWebContent() {
  #expect(SkyshotClassifier().containsImage(classifierSnapshot(role: kAXImageRole as String)))
  #expect(SkyshotClassifier().containsImage(classifierSnapshot(role: "AXCanvas")))
  #expect(SkyshotClassifier().containsImage(classifierSnapshot(role: "AXWebArea")))
}

private func classifierSnapshot(role: String) -> CapturedAccessibilitySnapshot {
  CapturedAccessibilitySnapshot(
    text: "[0] \(role)",
    elementsByID: [:],
    locatorsByID: [
      "0": AccessibilityElementLocator(
        path: [0],
        rolePath: [role],
        role: role,
        subrole: nil,
        identifier: nil,
        title: nil,
        description: nil,
        frame: nil
      )
    ]
  )
}
