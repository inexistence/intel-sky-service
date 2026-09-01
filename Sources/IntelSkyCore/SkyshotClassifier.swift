import ApplicationServices
import Foundation

/// Mirrors the ARM service's feature-gated Skyshot classifier: screenshots are attached only
/// when the accessibility tree indicates visual content that cannot be represented faithfully
/// by text alone. PIP is driven by the presence of that attachment, so text-only windows do not
/// create an unnecessary floating preview.
public struct SkyshotClassifier: Sendable {
  private static let visualRoles: Set<String> = [
    kAXImageRole as String,
    "AXCanvas",
    "AXMap",
    "AXVideo",
    "AXWebArea",
  ]

  private static let structuralRoles: Set<String> = [
    kAXWindowRole as String,
    kAXGroupRole as String,
  ]

  private static let textRoles: Set<String> = [
    kAXStaticTextRole as String,
    kAXTextFieldRole as String,
    kAXTextAreaRole as String,
  ]

  public init() {}

  func containsImage(_ snapshot: CapturedAccessibilitySnapshot) -> Bool {
    let locators = snapshot.locatorsByID.values
    if locators.contains(where: { Self.visualRoles.contains($0.role) }) {
      return true
    }

    // Custom-drawn Apps can expose only an unlabeled window/group shell and traffic-light
    // buttons. That tree cannot represent the visible UI or provide usable click targets, so a
    // screenshot is required even though the App omitted AXCanvas/AXImage roles.
    let contentLocators = locators.filter { !Self.structuralRoles.contains($0.role) }
    return !contentLocators.contains(where: Self.isTextRepresentable)
  }

  private static func isTextRepresentable(_ locator: AccessibilityElementLocator) -> Bool {
    if textRoles.contains(locator.role) { return true }
    return [locator.identifier, locator.title, locator.description]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .contains { !$0.isEmpty }
  }
}
