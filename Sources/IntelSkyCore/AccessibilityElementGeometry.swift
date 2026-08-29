import ApplicationServices
import Foundation

protocol AccessibilityFrameReading: Sendable {
  func frame(of element: AXUIElement) -> CGRect?
}

struct AccessibilityElementGeometry: AccessibilityFrameReading {
  func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = copyAttribute(element, kAXPositionAttribute as CFString),
      let sizeValue = copyAttribute(element, kAXSizeAttribute as CFString),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    let positionAX = unsafeDowncast(positionValue, to: AXValue.self)
    let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionAX, .cgPoint, &position),
      AXValueGetValue(sizeAX, .cgSize, &size),
      position.x.isFinite,
      position.y.isFinite,
      size.width.isFinite,
      size.height.isFinite,
      size.width > 0,
      size.height > 0
    else {
      return nil
    }
    return CGRect(origin: position, size: size)
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
  }
}
