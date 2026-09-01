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

@Test func skyshotClassifierIncludesSparseUnlabeledCustomDrawnWindows() {
  let roles = [
    kAXWindowRole as String,
    kAXGroupRole as String,
    kAXButtonRole as String,
  ]
  let snapshot = CapturedAccessibilitySnapshot(
    text: "[0] AXWindow\n  [1] AXGroup\n  [2] AXButton",
    elementsByID: [:],
    locatorsByID: Dictionary(
      uniqueKeysWithValues: roles.enumerated().map { index, role in
        (
          String(index),
          AccessibilityElementLocator(
            path: [index],
            rolePath: [role],
            role: role,
            subrole: nil,
            identifier: nil,
            title: nil,
            description: nil,
            frame: nil
          )
        )
      })
  )

  #expect(SkyshotClassifier().containsImage(snapshot))
}

@Test func skyshotClassifierSuppressesSemanticallyLabeledControls() {
  let snapshot = CapturedAccessibilitySnapshot(
    text: "[0] AXButton title=Save",
    elementsByID: [:],
    locatorsByID: [
      "0": AccessibilityElementLocator(
        path: [0],
        rolePath: [kAXButtonRole as String],
        role: kAXButtonRole as String,
        subrole: nil,
        identifier: nil,
        title: "Save",
        description: nil,
        frame: nil
      )
    ]
  )

  #expect(!SkyshotClassifier().containsImage(snapshot))
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
