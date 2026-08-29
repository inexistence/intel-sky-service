import ApplicationServices
import Testing

@testable import IntelSkyCore

@Test func elementRegistryReusesIDForEqualAXElement() {
  let registry = AccessibilityElementIDRegistry()
  let first = AXUIElementCreateApplication(123)
  let equalReference = AXUIElementCreateApplication(123)

  registry.beginCapture(processIdentifier: 123)
  let firstID = registry.id(for: first, processIdentifier: 123)
  registry.endCapture(processIdentifier: 123)
  registry.beginCapture(processIdentifier: 123)
  let secondID = registry.id(for: equalReference, processIdentifier: 123)
  registry.endCapture(processIdentifier: 123)

  #expect(firstID == secondID)
}

@Test func treeDifferReturnsFullTreeInitiallyAndWhenDisabled() {
  let differ = AccessibilityTreeDiffer()
  let app = diffTestApp()
  let initial = diffSnapshot("[0] AXWindow\n  [1] AXButton title=\"A\"")

  #expect(differ.output(for: initial, app: app, disableDiff: false) == initial.text)
  #expect(differ.output(for: initial, app: app, disableDiff: true) == initial.text)
}

@Test func treeDifferDescribesChangedAddedAndRemovedElements() {
  let differ = AccessibilityTreeDiffer()
  let app = diffTestApp()
  _ = differ.output(
    for: diffSnapshot("[0] AXWindow\n  [1] AXButton title=\"Old\"\n  [2] AXTextField"),
    app: app,
    disableDiff: false
  )

  let output = differ.output(
    for: diffSnapshot("[0] AXWindow\n  [1] AXButton title=\"New\"\n  [3] AXStaticText"),
    app: app,
    disableDiff: false
  )

  #expect(output.contains("~   [1] AXButton title=\"New\""))
  #expect(output.contains("-   [2] AXTextField"))
  #expect(output.contains("+   [3] AXStaticText"))
}

@Test func treeDifferReportsNoChangeAndResetsAfterRelaunch() {
  let differ = AccessibilityTreeDiffer()
  let app = diffTestApp(pid: 123)
  let snapshot = diffSnapshot("[0] AXWindow")
  _ = differ.output(for: snapshot, app: app, disableDiff: false)

  #expect(
    differ.output(for: snapshot, app: app, disableDiff: false)
      == "There has been no change in the accessibility tree for Test"
  )

  let relaunched = diffTestApp(pid: 124)
  #expect(differ.output(for: snapshot, app: relaunched, disableDiff: false) == snapshot.text)
}

private func diffSnapshot(_ text: String) -> CapturedAccessibilitySnapshot {
  CapturedAccessibilitySnapshot(text: text, elementsByID: [:])
}

private func diffTestApp(pid: pid_t = 123) -> ResolvedMacApp {
  ResolvedMacApp(
    processIdentifier: pid,
    bundleIdentifier: "example.test",
    displayName: "Test",
    appPath: "/Applications/Test.app"
  )
}
