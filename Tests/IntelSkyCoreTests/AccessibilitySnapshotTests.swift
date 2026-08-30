import ApplicationServices
import Foundation
import Testing

@testable import IntelSkyCore

@Test func accessibilitySnapshotPrefersVisibleChildrenIncludingAnEmptyList() {
  let all = [AXUIElementCreateApplication(101), AXUIElementCreateApplication(102)]
  let visible = [all[1]]

  #expect(
    AccessibilitySnapshotter.preferredChildren(
      allChildren: all,
      visibleChildren: visible
    ).count == 1
  )
  #expect(
    AccessibilitySnapshotter.preferredChildren(
      allChildren: all,
      visibleChildren: [AXUIElement]()
    ).isEmpty
  )
  #expect(
    AccessibilitySnapshotter.preferredChildren(
      allChildren: all,
      visibleChildren: "unsupported"
    ).count == 2
  )
}

@Test func accessibilitySnapshotSkipsOnlyKnownPassiveActionQueries() {
  #expect(
    !AccessibilitySnapshotter.shouldQueryActions(
      role: kAXStaticTextRole as String,
      identifier: nil,
      title: nil,
      description: nil,
      frame: CGRect(x: 0, y: 0, width: 100, height: 20)
    )
  )
  #expect(
    !AccessibilitySnapshotter.shouldQueryActions(
      role: kAXImageRole as String,
      identifier: nil,
      title: nil,
      description: nil,
      frame: CGRect(x: 0, y: 0, width: 16, height: 16)
    )
  )
  #expect(
    AccessibilitySnapshotter.shouldQueryActions(
      role: kAXImageRole as String,
      identifier: nil,
      title: "Open",
      description: nil,
      frame: CGRect(x: 0, y: 0, width: 16, height: 16)
    )
  )
  #expect(
    AccessibilitySnapshotter.shouldQueryActions(
      role: kAXButtonRole as String,
      identifier: nil,
      title: nil,
      description: nil,
      frame: nil
    )
  )
}

@Test func accessibilitySnapshotTracksPotentialValueRolesWithoutAXRoundTrips() {
  #expect(AccessibilitySnapshotter.isPotentiallyValueSettable(role: kAXTextFieldRole as String))
  #expect(AccessibilitySnapshotter.isPotentiallyValueSettable(role: kAXTextAreaRole as String))
  #expect(!AccessibilitySnapshotter.isPotentiallyValueSettable(role: kAXStaticTextRole as String))
}
