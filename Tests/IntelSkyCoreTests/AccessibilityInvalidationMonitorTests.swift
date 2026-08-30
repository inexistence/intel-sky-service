import ApplicationServices
import Testing

@testable import IntelSkyCore

@Test func invalidationStateTracksOfficialNotificationFamilies() {
  let state = AccessibilityInvalidationState()
  let application = AXUIElementCreateApplication(10)
  let destroyed = AXUIElementCreateApplication(11)

  state.record(notification: kAXSelectedChildrenChangedNotification, element: application)
  state.record(notification: kAXUIElementDestroyedNotification, element: destroyed)
  state.record(notification: kAXFocusedWindowChangedNotification, element: application)

  #expect(state.layoutChanged)
  #expect(state.focusedWindowChanged)
  #expect(state.wasDestroyed(destroyed))
  #expect(!state.wasDestroyed(application))
}

@Test func deactivatedInvalidationStateIgnoresLateCallbacks() {
  let state = AccessibilityInvalidationState()
  let element = AXUIElementCreateApplication(10)
  state.deactivate()

  state.record(notification: kAXLayoutChangedNotification, element: element)
  state.record(notification: kAXUIElementDestroyedNotification, element: element)

  #expect(!state.layoutChanged)
  #expect(!state.wasDestroyed(element))
}
