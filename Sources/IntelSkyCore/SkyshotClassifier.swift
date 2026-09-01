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

  public init() {}

  func containsImage(_ snapshot: CapturedAccessibilitySnapshot) -> Bool {
    snapshot.locatorsByID.values.contains { Self.visualRoles.contains($0.role) }
  }
}
