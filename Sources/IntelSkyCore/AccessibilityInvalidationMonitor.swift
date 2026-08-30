import ApplicationServices
import CoreFoundation
import Foundation

enum AccessibilityInvalidationMonitorError: Error {
  case observerCreationFailed(AXError)
}

protocol AccessibilitySnapshotInvalidationMonitoring: Sendable {
  var focusedWindowChanged: Bool { get }
  var layoutChanged: Bool { get }
  func wasDestroyed(_ element: AXUIElement) -> Bool
}

final class AccessibilityInvalidationState: @unchecked Sendable,
  AccessibilitySnapshotInvalidationMonitoring
{
  private let lock = NSLock()
  private var didChangeFocusedWindow = false
  private var didChangeLayout = false
  private var destroyedElements: [AXUIElement] = []
  private var active = true

  var focusedWindowChanged: Bool {
    lock.withLock { didChangeFocusedWindow }
  }

  var layoutChanged: Bool {
    lock.withLock { didChangeLayout }
  }

  func wasDestroyed(_ element: AXUIElement) -> Bool {
    lock.withLock { destroyedElements.contains { CFEqual($0, element) } }
  }

  func record(notification: String, element: AXUIElement) {
    lock.withLock {
      guard active else { return }
      switch notification {
      case kAXFocusedWindowChangedNotification:
        didChangeFocusedWindow = true
      case kAXUIElementDestroyedNotification:
        if !destroyedElements.contains(where: { CFEqual($0, element) }) {
          destroyedElements.append(element)
        }
      case kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification:
        didChangeLayout = true
      default:
        break
      }
    }
  }

  func deactivate() {
    lock.withLock { active = false }
  }
}

final class NativeAccessibilityInvalidationMonitor: @unchecked Sendable,
  AccessibilitySnapshotInvalidationMonitoring
{
  private struct Registration {
    let element: AXUIElement
    let notification: CFString
  }

  private let observer: AXObserver
  private let source: CFRunLoopSource
  private let state = AccessibilityInvalidationState()
  private var registrations: [Registration] = []

  var focusedWindowChanged: Bool { state.focusedWindowChanged }
  var layoutChanged: Bool { state.layoutChanged }
  func wasDestroyed(_ element: AXUIElement) -> Bool { state.wasDestroyed(element) }

  init(
    processIdentifier: pid_t,
    application: AXUIElement,
    window: AXUIElement,
    actionableElements: [AXUIElement]
  ) throws {
    var createdObserver: AXObserver?
    let result = AXObserverCreateWithInfoCallback(
      processIdentifier,
      { _, element, notification, _, refcon in
        guard let refcon else { return }
        let state = Unmanaged<AccessibilityInvalidationState>.fromOpaque(refcon)
          .takeUnretainedValue()
        state.record(notification: notification as String, element: element)
      },
      &createdObserver
    )
    guard result == .success, let createdObserver else {
      throw AccessibilityInvalidationMonitorError.observerCreationFailed(result)
    }
    observer = createdObserver
    source = AXObserverGetRunLoopSource(createdObserver)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

    register(application, notification: kAXFocusedWindowChangedNotification as CFString)
    register(window, notification: kAXLayoutChangedNotification as CFString)
    register(window, notification: kAXSelectedChildrenChangedNotification as CFString)
    register(window, notification: kAXUIElementDestroyedNotification as CFString)
    for element in actionableElements where !CFEqual(element, window) {
      register(element, notification: kAXUIElementDestroyedNotification as CFString)
      register(element, notification: kAXLayoutChangedNotification as CFString)
      register(element, notification: kAXSelectedChildrenChangedNotification as CFString)
    }
  }

  deinit {
    state.deactivate()
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
  }

  private func register(_ element: AXUIElement, notification: CFString) {
    let refcon = Unmanaged.passUnretained(state).toOpaque()
    let result = AXObserverAddNotification(observer, element, notification, refcon)
    if result == .success {
      registrations.append(Registration(element: element, notification: notification))
    }
  }
}
