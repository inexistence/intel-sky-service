import AppKit
import Foundation

enum PasteContentFormat: String, Sendable {
  case text
  case markdown = "md"
  case html
}

enum MacPasteError: Error, CustomStringConvertible {
  case clipboardWriteFailed
  case applicationDidNotReadClipboard
  case clipboardChangedDuringPaste

  var description: String {
    switch self {
    case .clipboardWriteFailed:
      return "Could not write generated content to the clipboard"
    case .applicationDidNotReadClipboard:
      return "Timed out waiting for the application to read the clipboard"
    case .clipboardChangedDuringPaste:
      return "The clipboard changed while paste was in progress"
    }
  }
}

protocol PastePerforming: Sendable {
  func paste(
    text: String,
    format: PasteContentFormat,
    keyboard: any KeyboardInputPosting,
    target: ComputerUseEventTarget
  ) throws
}

struct MacPasteOperation: PastePerforming {
  func paste(
    text: String,
    format: PasteContentFormat,
    keyboard: any KeyboardInputPosting,
    target: ComputerUseEventTarget
  ) throws {
    try ProcessTargetedEventPoster.withSyntheticFocus(on: target) {
      try performPaste(text: text, format: format, keyboard: keyboard, target: target)
    }
  }

  private func performPaste(
    text: String,
    format: PasteContentFormat,
    keyboard: any KeyboardInputPosting,
    target: ComputerUseEventTarget
  ) throws {
    let pasteboard = NSPasteboard.general
    let previous = PasteboardSnapshot(pasteboard: pasteboard)
    let provider = PasteboardDataProvider(contents: contents(text: text, format: format))
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: Array(provider.contents.keys))
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      previous.restore(to: pasteboard)
      throw MacPasteError.clipboardWriteFailed
    }
    let operationChangeCount = pasteboard.changeCount
    defer {
      // Never overwrite clipboard content the user changed while the paste was in flight.
      if pasteboard.changeCount == operationChangeCount {
        previous.restore(to: pasteboard)
      }
    }

    let chord = try MacKeyChordParser().parse("Super_L+v")
    try keyboard.press(chord, target: target)
    guard try provider.waitForRead(timeout: 2) else {
      if pasteboard.changeCount != operationChangeCount {
        throw MacPasteError.clipboardChangedDuringPaste
      }
      throw MacPasteError.applicationDidNotReadClipboard
    }
    guard pasteboard.changeCount == operationChangeCount else {
      throw MacPasteError.clipboardChangedDuringPaste
    }
  }

  private func contents(
    text: String,
    format: PasteContentFormat
  ) -> [NSPasteboard.PasteboardType: Data] {
    let data = Data(text.utf8)
    switch format {
    case .text:
      return [.string: data]
    case .markdown:
      return [
        NSPasteboard.PasteboardType("net.daringfireball.markdown"): data,
        .string: data,
      ]
    case .html:
      return [.html: data, .string: data]
    }
  }
}

private final class PasteboardDataProvider: NSObject, NSPasteboardItemDataProvider,
  @unchecked Sendable
{
  let contents: [NSPasteboard.PasteboardType: Data]
  private let lock = NSLock()
  private var wasRead = false

  init(contents: [NSPasteboard.PasteboardType: Data]) {
    self.contents = contents
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    guard let data = contents[type] else { return }
    item.setData(data, forType: type)
    lock.lock()
    wasRead = true
    lock.unlock()
  }

  func waitForRead(timeout: TimeInterval) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      try RequestDeadlineContext.check()
      try UserInterventionContext.check()
      lock.lock()
      let result = wasRead
      lock.unlock()
      if result { return true }
      // Pasteboard providers are commonly called through the AppKit run loop on the
      // thread that owns the pasteboard item. Keep that loop responsive while the
      // target application resolves the promised data.
      _ = RunLoop.current.run(
        mode: .default,
        before: min(deadline, Date().addingTimeInterval(0.01))
      )
    } while Date() < deadline
    lock.lock()
    defer { lock.unlock() }
    return wasRead
  }
}

private struct PasteboardSnapshot {
  struct Item {
    let values: [(NSPasteboard.PasteboardType, Data)]
  }

  let items: [Item]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Item(
        values: item.types.compactMap { type in
          item.data(forType: type).map { (type, $0) }
        })
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    guard !items.isEmpty else { return }
    let restored = items.map { stored -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in stored.values { item.setData(data, forType: type) }
      return item
    }
    _ = pasteboard.writeObjects(restored)
  }
}
