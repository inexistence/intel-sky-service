@preconcurrency import AppKit
import CoreGraphics
import Foundation

public struct AppshotTransitionSnapshot: Sendable, Equatable {
  public let url: URL
  public let height: Double

  public init(url: URL, height: Double) {
    self.url = url
    self.height = height
  }
}

public protocol AppshotTransitionSnapshotRendering: Sendable {
  func render(
    screenshot: [String: Any],
    bundleIdentifier: String,
    animationTarget: [String: Any]
  ) -> AppshotTransitionSnapshot?
}

/// Produces the final Appshot handoff artwork consumed by Codex's compact composer card.
///
/// The primary screenshot remains untouched for the lightbox and model attachment. This renderer
/// creates the separate, presentation-only image used during the native-to-composer transition:
/// a transparent rounded canvas, a faded window preview, the target App's icon, and its localized
/// title. The composer supplies the shared hover material behind this image.
public struct AppshotTransitionSnapshotRenderer: AppshotTransitionSnapshotRendering {
  private static let referenceWidth = 232.0
  private static let referenceHeight = 160.0

  public init() {}

  public func render(
    screenshot: [String: Any],
    bundleIdentifier: String,
    animationTarget: [String: Any]
  ) -> AppshotTransitionSnapshot? {
    guard let rawURL = screenshot["url"] as? String,
      let screenshotURL = URL(string: rawURL),
      screenshotURL.isFileURL,
      let screenshotImage = NSImage(contentsOf: screenshotURL)
    else {
      return nil
    }
    // Resolve LaunchServices/AppKit metadata before installing the bitmap graphics context.
    // NSWorkspace may perform its own image work while loading an icon.
    let identity = Self.applicationIdentity(bundleIdentifier: bundleIdentifier)

    let targetWidth = min(
      1_024,
      Self.positiveDimension(
        (animationTarget["destinationFrame"] as? [String: Any])?["width"]
      ) ?? Self.referenceWidth
    )
    let targetHeight = targetWidth * Self.referenceHeight / Self.referenceWidth
    let displayScale = min(
      3,
      max(
        1,
        Self.positiveDimension(
          (animationTarget["codexDisplay"] as? [String: Any])?["scaleFactor"]
        ) ?? 2
      )
    )
    let pixelWidth = max(1, Int((targetWidth * displayScale).rounded()))
    let pixelHeight = max(1, Int((targetHeight * displayScale).rounded()))
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return nil
    }
    bitmap.size = NSSize(width: targetWidth, height: targetHeight)
    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    let titleColor = Self.color(
      animationTarget["destinationPrimaryTextColor"],
      fallback: NSColor(calibratedWhite: 0.12, alpha: 1)
    )
    let targetCornerRadius =
      Self.nonnegativeDimension(animationTarget["destinationCornerRadius"])
      ?? targetWidth * 0.06
    let scale = targetWidth / Self.referenceWidth

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer {
      graphics.flushGraphics()
      NSGraphicsContext.restoreGraphicsState()
    }

    let canvas = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
    let canvasPath = NSBezierPath(
      roundedRect: canvas,
      xRadius: min(targetCornerRadius, targetHeight / 2),
      yRadius: min(targetCornerRadius, targetHeight / 2)
    )
    canvasPath.addClip()

    let previewBounds = NSSize(width: 182 * scale, height: 106 * scale)
    let previewSize = Self.aspectFit(screenshotImage.size, inside: previewBounds)
    let previewRect = NSRect(
      x: (targetWidth - previewSize.width) / 2,
      y: targetHeight - 18 * scale - previewSize.height,
      width: previewSize.width,
      height: previewSize.height
    )
    let shadowRect = previewRect.insetBy(dx: -2 * scale, dy: -2 * scale)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 12 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -5 * scale)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.set()
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: shadowRect, xRadius: 4 * scale, yRadius: 4 * scale).fill()
    NSGraphicsContext.restoreGraphicsState()

    screenshotImage.draw(
      in: previewRect,
      from: .zero,
      operation: .sourceOver,
      fraction: 0.52,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )

    // Fade the lower half of the window out before it reaches the icon. Extending the final
    // gradient color is important: it removes the window's bottom edge and its shadow completely,
    // instead of leaving a faint horizontal seam on the composer's hover material.
    let fadeStartY = previewRect.minY + 72 * scale
    let fadeEndY = previewRect.minY + 20 * scale
    let context = graphics.cgContext
    context.saveGState()
    context.setBlendMode(.destinationOut)
    if let fade = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceGray(),
      colors: [
        CGColor(gray: 0, alpha: 0),
        CGColor(gray: 0, alpha: 1),
      ] as CFArray,
      locations: [0, 1]
    ) {
      context.drawLinearGradient(
        fade,
        start: CGPoint(x: previewRect.midX, y: fadeStartY),
        end: CGPoint(x: previewRect.midX, y: fadeEndY),
        options: [.drawsAfterEndLocation]
      )
    }
    // Core Graphics can leave a sub-pixel fringe at a gradient's 100% stop. Clear a one-point
    // overlap explicitly so no residual window border survives on light hover backgrounds.
    context.setBlendMode(.clear)
    context.fill(
      CGRect(x: 0, y: 0, width: targetWidth, height: fadeEndY + 1 * scale)
    )
    context.restoreGState()

    let iconSize = 24 * scale
    if let icon = identity.icon {
      icon.draw(
        in: NSRect(
          x: (targetWidth - iconSize) / 2,
          y: 38 * scale,
          width: iconSize,
          height: iconSize
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    let title = NSAttributedString(
      string: identity.title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 14 * scale, weight: .semibold),
        .foregroundColor: titleColor,
        .paragraphStyle: paragraph,
      ]
    )
    title.draw(
      in: NSRect(
        x: 12 * scale,
        y: 10 * scale,
        width: targetWidth - 24 * scale,
        height: 20 * scale
      )
    )

    guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    let output = screenshotURL.deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("png")
    do {
      try png.write(to: output, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      return AppshotTransitionSnapshot(url: output, height: targetHeight)
    } catch {
      try? FileManager.default.removeItem(at: output)
      return nil
    }
  }

  private static func applicationIdentity(bundleIdentifier: String) -> (
    title: String, icon: NSImage?
  ) {
    if let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).first {
      return (running.localizedName ?? fallbackTitle(bundleIdentifier), running.icon)
    }
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
      let values = try? appURL.resourceValues(forKeys: [.localizedNameKey])
      let title = values?.localizedName ?? appURL.deletingPathExtension().lastPathComponent
      return (title, NSWorkspace.shared.icon(forFile: appURL.path))
    }
    return (fallbackTitle(bundleIdentifier), nil)
  }

  private static func fallbackTitle(_ bundleIdentifier: String) -> String {
    bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
  }

  private static func aspectFit(_ source: NSSize, inside bounds: NSSize) -> NSSize {
    guard source.width > 0, source.height > 0 else { return bounds }
    let ratio = min(bounds.width / source.width, bounds.height / source.height)
    return NSSize(width: source.width * ratio, height: source.height * ratio)
  }

  private static func color(_ raw: Any?, fallback: NSColor) -> NSColor {
    guard let channels = raw as? [String: Any],
      let red = finiteNumber(channels["red"]),
      let green = finiteNumber(channels["green"]),
      let blue = finiteNumber(channels["blue"])
    else {
      return fallback
    }
    let divisor = max(red, green, blue) > 1 ? 255.0 : 1.0
    return NSColor(
      calibratedRed: min(1, max(0, red / divisor)),
      green: min(1, max(0, green / divisor)),
      blue: min(1, max(0, blue / divisor)),
      alpha: 1
    )
  }

  private static func positiveDimension(_ raw: Any?) -> Double? {
    guard let value = finiteNumber(raw), value > 0 else { return nil }
    return value
  }

  private static func nonnegativeDimension(_ raw: Any?) -> Double? {
    guard let value = finiteNumber(raw), value >= 0 else { return nil }
    return value
  }

  private static func finiteNumber(_ raw: Any?) -> Double? {
    guard !(raw is Bool), let number = raw as? NSNumber else { return nil }
    let value = number.doubleValue
    guard value.isFinite else { return nil }
    return value
  }
}
