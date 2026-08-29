import ApplicationServices
import CoreGraphics
import Foundation

// String value of kAXTrustedCheckOptionPrompt. Referencing the imported SDK global from a
// @Sendable closure is rejected by Swift 6 because the header exposes it as mutable state.
private let accessibilityPromptOption = "AXTrustedCheckOptionPrompt"

public struct ServicePermissionStatus: Codable, Equatable, Sendable {
  public let accessibility: Bool
  public let screenRecording: Bool

  public var allGranted: Bool {
    accessibility && screenRecording
  }

  public init(accessibility: Bool, screenRecording: Bool) {
    self.accessibility = accessibility
    self.screenRecording = screenRecording
  }
}

public struct ServicePermissionDiagnostics: Sendable {
  private let accessibilityCheck: @Sendable () -> Bool
  private let screenRecordingCheck: @Sendable () -> Bool

  public init() {
    accessibilityCheck = { AXIsProcessTrusted() }
    screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
  }

  init(
    accessibilityCheck: @escaping @Sendable () -> Bool,
    screenRecordingCheck: @escaping @Sendable () -> Bool
  ) {
    self.accessibilityCheck = accessibilityCheck
    self.screenRecordingCheck = screenRecordingCheck
  }

  public func currentStatus() -> ServicePermissionStatus {
    ServicePermissionStatus(
      accessibility: accessibilityCheck(),
      screenRecording: screenRecordingCheck()
    )
  }
}

public struct ServicePermissionRequester: Sendable {
  private let accessibilityCheck: @Sendable () -> Bool
  private let accessibilityRequest: @Sendable () -> Void
  private let screenRecordingCheck: @Sendable () -> Bool
  private let screenRecordingRequest: @Sendable () -> Void

  public init() {
    accessibilityCheck = { AXIsProcessTrusted() }
    accessibilityRequest = {
      _ = AXIsProcessTrustedWithOptions([accessibilityPromptOption: true] as CFDictionary)
    }
    screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
    screenRecordingRequest = { _ = CGRequestScreenCaptureAccess() }
  }

  init(
    accessibilityCheck: @escaping @Sendable () -> Bool,
    accessibilityRequest: @escaping @Sendable () -> Void,
    screenRecordingCheck: @escaping @Sendable () -> Bool,
    screenRecordingRequest: @escaping @Sendable () -> Void
  ) {
    self.accessibilityCheck = accessibilityCheck
    self.accessibilityRequest = accessibilityRequest
    self.screenRecordingCheck = screenRecordingCheck
    self.screenRecordingRequest = screenRecordingRequest
  }

  public func requestMissingPermissions() {
    if !accessibilityCheck() { accessibilityRequest() }
    if !screenRecordingCheck() { screenRecordingRequest() }
  }
}
