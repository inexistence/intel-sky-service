import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IntelSkyCore

@Test func appshotTransitionRendererBuildsRetinaComposerArtwork() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let sourceURL = directory.appendingPathComponent("source.png")
  try writeFixturePNG(to: sourceURL, width: 800, height: 500)

  let result = try #require(
    AppshotTransitionSnapshotRenderer().render(
      screenshot: ["url": sourceURL.absoluteString, "mimeType": "image/png"],
      bundleIdentifier: "dev.huangjianbin.nonexistent-fixture",
      animationTarget: [
        "destinationFrame": ["width": 232.0, "height": 140.0, "x": 0.0, "y": 0.0],
        "destinationCornerRadius": 14.0,
        "destinationBackgroundColor": ["red": 250, "green": 250, "blue": 250],
        "destinationPrimaryTextColor": ["red": 20, "green": 20, "blue": 20],
        "codexDisplay": ["scaleFactor": 2.0],
      ]
    ))
  defer { try? FileManager.default.removeItem(at: result.url) }

  #expect(result.height == 160)
  let source = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  #expect(image.width == 464)
  #expect(image.height == 320)
  let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: result.url)))
  #expect(bitmap.colorAt(x: 20, y: 160)?.alphaComponent == 0)
  let upperPreviewAlpha = try #require(bitmap.colorAt(x: 232, y: 76)?.alphaComponent)
  let lowerPreviewAlpha = try #require(bitmap.colorAt(x: 232, y: 240)?.alphaComponent)
  #expect(lowerPreviewAlpha < upperPreviewAlpha)
  #expect(bitmap.colorAt(x: 100, y: 230)?.alphaComponent == 0)
  let attributes = try FileManager.default.attributesOfItem(atPath: result.url.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func captureStartPublishesComposedTransitionMetadata() throws {
  let transitionURL = URL(fileURLWithPath: "/tmp/finder-transition.png")
  let manager = AppCaptureSessionManager(
    appStateProvider: AppshotTransitionCaptureStateProvider(),
    permissionDiagnostics: ServicePermissionDiagnostics(
      accessibilityCheck: { true },
      screenRecordingCheck: { true }
    ),
    transitionSnapshotRenderer: FixedAppshotTransitionRenderer(
      result: AppshotTransitionSnapshot(url: transitionURL, height: 160)
    )
  )

  let response = try manager.startCapture(request: [
    "app": "com.apple.finder",
    "requestId": "transition-metadata",
    "permissionRequestId": "permission-transition-metadata",
    "animationTarget": ["destinationFrame": ["width": 232.0]],
    "version": 2,
  ])
  #expect(response["result"] as? String == "started")
  #expect(response["transitionSnapshotHeight"] as? Double == 160)
  #expect(response["animationDuration"] as? Double == 0.35)
  #expect(response["transitionSpringResponse"] as? Double == 0.35)
  #expect(response["transitionSpringDampingFraction"] as? Double == 0.73)

  _ = try manager.nextCaptureUpdate(request: ["requestId": "transition-metadata"])
  _ = try manager.nextCaptureUpdate(request: ["requestId": "transition-metadata"])
  let screenshot = try manager.nextCaptureUpdate(request: ["requestId": "transition-metadata"])
  #expect(screenshot["type"] as? String == "screenshot")
  #expect(screenshot["transitionSnapshotURL"] as? String == transitionURL.absoluteString)
  manager.shutdown()
}

private struct FixedAppshotTransitionRenderer: AppshotTransitionSnapshotRendering {
  let result: AppshotTransitionSnapshot?

  func render(
    screenshot: [String: Any],
    bundleIdentifier: String,
    animationTarget: [String: Any]
  ) -> AppshotTransitionSnapshot? {
    result
  }
}

private struct AppshotTransitionCaptureStateProvider: AppStateProviding {
  func getAppPolicy(request: [String: Any]) throws -> [String: Any] { [:] }

  func getAppState(request: [String: Any]) throws -> [String: Any] {
    [
      "app": ["bundleIdentifier": "com.apple.finder", "pid": 123],
      "skyshot": [
        "text": "[0] AXWindow title=\"Finder\"",
        "screenshot": ["url": "file:///tmp/finder.png", "mimeType": "image/png"],
      ],
    ]
  }
}

private func writeFixturePNG(to url: URL, width: Int, height: Int) throws {
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
  context.setFillColor(CGColor(red: 0.18, green: 0.42, blue: 0.72, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
}
