import Foundation

public final class AccessibilityTreeDiffer: @unchecked Sendable {
  private struct Key: Hashable {
    let threadID: String?
    let bundleIdentifier: String
  }

  private struct Baseline {
    let processIdentifier: pid_t
    let records: [String: String]
  }

  private let lock = NSLock()
  private var baselines: [Key: Baseline] = [:]

  public init() {}

  func output(
    for snapshot: CapturedAccessibilitySnapshot,
    app: ResolvedMacApp,
    disableDiff: Bool
  ) -> String {
    let current = records(in: snapshot.text)
    lock.lock()
    defer { lock.unlock() }

    let key = Key(
      threadID: ComputerUseTurnContext.threadID,
      bundleIdentifier: app.bundleIdentifier
    )
    let previous = baselines[key]
    baselines[key] = Baseline(
      processIdentifier: app.processIdentifier,
      records: current
    )
    guard !disableDiff, let previous, previous.processIdentifier == app.processIdentifier else {
      return snapshot.text
    }

    var changes: [(Int, String)] = []
    for (id, line) in current {
      guard let numericID = Int(id) else { continue }
      if let oldLine = previous.records[id] {
        if oldLine != line { changes.append((numericID, "~ " + line)) }
      } else {
        changes.append((numericID, "+ " + line))
      }
    }
    for (id, line) in previous.records where current[id] == nil {
      guard let numericID = Int(id) else { continue }
      changes.append((numericID, "- " + line))
    }
    changes.sort { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
    }

    guard !changes.isEmpty else {
      return "There has been no change in the accessibility tree for \(app.displayName)"
    }
    return
      ([
        "The following is a diff from the previous accessibility tree",
        "with ~, +, and - representing changed, added, and removed elements, respectively.",
      ] + changes.map(\.1)).joined(separator: "\n")
  }

  func clear(threadID: String?) {
    lock.withLock {
      if let threadID {
        baselines = baselines.filter { $0.key.threadID != nil && $0.key.threadID != threadID }
      } else {
        baselines.removeAll()
      }
    }
  }

  func clearUnscoped() {
    lock.withLock {
      baselines = baselines.filter { $0.key.threadID != nil }
    }
  }

  func clear(bundleIdentifier: String, threadID: String?) {
    lock.withLock {
      baselines = baselines.filter {
        $0.key.bundleIdentifier != bundleIdentifier
          || (threadID != nil && $0.key.threadID != threadID)
      }
    }
  }

  private func records(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
      guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { continue }
      let id = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      guard Int(id) != nil else { continue }
      result[id] = line
    }
    return result
  }
}
