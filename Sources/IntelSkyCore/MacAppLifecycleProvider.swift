import AppKit
import ApplicationServices
import Foundation

public protocol AppLifecycleProviding: Sendable {
  func frontmostWindow(request: [String: Any]) throws -> Any
  func modifyApp(request: [String: Any]) throws -> [String: Any]
}

enum MacAppLifecycleError: Error, CustomStringConvertible {
  case invalidModification

  var description: String {
    switch self {
    case .invalidModification:
      return "App modification must be either 'activate' or 'deactivate'"
    }
  }
}

public struct MacAppLifecycleProvider: AppLifecycleProviding {
  private let resolver: any MacAppResolving
  private let policyEvaluator: any MacAppPolicyEvaluating
  private let sessionCoordinator: any ComputerUseSessionCoordinating

  public init(resolver: any MacAppResolving = MacAppResolver()) {
    self.init(
      resolver: resolver,
      policyEvaluator: CodexAppServerMacAppPolicyEvaluator.shared,
      sessionCoordinator: ComputerUseSessionCoordinator.shared
    )
  }

  init(
    resolver: any MacAppResolving,
    policyEvaluator: any MacAppPolicyEvaluating,
    sessionCoordinator: any ComputerUseSessionCoordinating
  ) {
    self.resolver = resolver
    self.policyEvaluator = policyEvaluator
    self.sessionCoordinator = sessionCoordinator
  }

  public func frontmostWindow(request: [String: Any]) throws -> Any {
    guard let application = NSWorkspace.shared.frontmostApplication else {
      return NSNull()
    }
    let name = application.localizedName ?? application.bundleIdentifier ?? "Unknown"
    guard let bundleIdentifier = application.bundleIdentifier else { return NSNull() }

    var result: [String: Any] = [
      "bundleIdentifier": bundleIdentifier,
      "name": name,
    ]
    if let title = focusedWindowTitle(processIdentifier: application.processIdentifier) {
      result["windowTitle"] = title
    }
    return result
  }

  public func modifyApp(request: [String: Any]) throws -> [String: Any] {
    guard let modification = request["modification"] as? String,
      request["app"] != nil
    else {
      throw MacAppLifecycleError.invalidModification
    }
    switch modification {
    case "activate":
      let target = try resolver.resolveApplication(request["app"])
      try sessionCoordinator.requireNotStopped(target)
      try policyEvaluator.requireAllowed(target)
      let app = try resolver.resolveOrLaunch(request["app"])
      return try sessionCoordinator.activateApplication(app)
    case "deactivate":
      let app = try resolver.resolve(request["app"])
      return try sessionCoordinator.deactivateApplication(app)
    default:
      throw MacAppLifecycleError.invalidModification
    }
  }

  private func focusedWindowTitle(processIdentifier: pid_t) -> String? {
    let application = AXUIElementCreateApplication(processIdentifier)
    var windowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      application,
      kAXFocusedWindowAttribute as CFString,
      &windowValue
    ) == .success,
      let windowValue,
      CFGetTypeID(windowValue) == AXUIElementGetTypeID()
    else {
      return nil
    }
    let window = unsafeDowncast(windowValue, to: AXUIElement.self)
    var titleValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      window,
      kAXTitleAttribute as CFString,
      &titleValue
    ) == .success
    else {
      return nil
    }
    let title = titleValue as? String
    return title?.isEmpty == false ? title : nil
  }
}
