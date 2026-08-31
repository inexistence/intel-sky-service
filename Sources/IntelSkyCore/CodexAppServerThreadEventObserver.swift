import Darwin
import Foundation

/// Mirrors the ARM service's turn-boundary source: the Codex App Server native IPC stream.
/// Computer Use requests do not reliably include a public turn-ended request, while this stream
/// publishes `turn/completed` independently of whether the turn created a PIP presentation.
public final class CodexAppServerThreadEventObserver: @unchecked Sendable {
  static let maximumFrameLength = 8 * 1024 * 1024

  private let lock = NSLock()
  private let queue = DispatchQueue(
    label: "CodexAppServerThreadEventObserver.connection",
    qos: .utility
  )
  private let socketPath: String
  private let reconnectDelay: TimeInterval
  private let turnEnded: @Sendable (String) -> Void
  private let diagnostic: @Sendable (String) -> Void
  private var generation: UInt64 = 0
  private var running = false
  private var connectedDescriptor: Int32 = -1

  public convenience init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    turnEnded: @escaping @Sendable (String) -> Void,
    diagnostic: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.init(
      socketPath: Self.resolveSocketPath(
        environment: environment,
        homeDirectoryURL: homeDirectoryURL
      ),
      reconnectDelay: 1,
      turnEnded: turnEnded,
      diagnostic: diagnostic
    )
  }

  init(
    socketPath: String,
    reconnectDelay: TimeInterval,
    turnEnded: @escaping @Sendable (String) -> Void,
    diagnostic: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.socketPath = socketPath
    self.reconnectDelay = reconnectDelay
    self.turnEnded = turnEnded
    self.diagnostic = diagnostic
  }

  deinit { stop() }

  public func start() {
    let nextGeneration = lock.withLock { () -> UInt64? in
      guard !running else { return nil }
      running = true
      generation &+= 1
      return generation
    }
    guard let nextGeneration else { return }
    queue.async { [weak self] in self?.connectAndRead(generation: nextGeneration) }
  }

  public func stop() {
    let descriptor = lock.withLock { () -> Int32 in
      guard running else { return -1 }
      running = false
      generation &+= 1
      return connectedDescriptor
    }
    if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
  }

  static func resolveSocketPath(
    environment: [String: String],
    homeDirectoryURL: URL
  ) -> String {
    if let override = nonempty(environment["SKY_CUA_SERVICE_NATIVE_PIPE_PATH"]) {
      return override
    }
    let codexHome =
      nonempty(environment["CODEX_HOME"])
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
    return codexHome.appendingPathComponent("ipc/ipc.sock").path
  }

  static func completedThreadID(from data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["method"] as? String == "turn/completed",
      let params = object["params"] as? [String: Any]
    else { return nil }
    return nonempty(params["threadId"] as? String)
  }

  static func initializePayload(identifier: UUID = UUID()) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "type": "request",
        "requestId": identifier.uuidString,
        "method": "initialize",
        "params": ["clientType": "desktop"],
      ],
      options: [.sortedKeys]
    )
  }

  static func clientDiscoveryResponse(from data: Data) -> Data? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["type"] as? String == "client-discovery-request",
      let requestID = nonempty(object["requestId"] as? String)
    else { return nil }
    return try? JSONSerialization.data(
      withJSONObject: [
        "type": "client-discovery-response",
        "requestId": requestID,
        "response": ["canHandle": false],
      ],
      options: [.sortedKeys]
    )
  }

  private func connectAndRead(generation expectedGeneration: UInt64) {
    guard isCurrent(expectedGeneration) else { return }
    var descriptor: Int32 = -1
    do {
      descriptor = try Self.connectUnixSocket(at: socketPath)
      guard install(descriptor, generation: expectedGeneration) else {
        Darwin.close(descriptor)
        return
      }
      try Self.writeFrame(Self.initializePayload(), to: descriptor)
      while isCurrent(expectedGeneration) {
        let payload = try Self.readFrame(from: descriptor)
        if let threadID = Self.completedThreadID(from: payload) {
          turnEnded(threadID)
        }
        if let response = Self.clientDiscoveryResponse(from: payload) {
          try Self.writeFrame(response, to: descriptor)
        }
      }
    } catch {
      if isCurrent(expectedGeneration) {
        diagnostic("Codex App Server event stream disconnected: \(error)")
      }
    }
    clearAndClose(descriptor: descriptor)
    guard isCurrent(expectedGeneration) else { return }
    queue.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
      self?.connectAndRead(generation: expectedGeneration)
    }
  }

  private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
    lock.withLock { running && generation == expectedGeneration }
  }

  private func install(_ descriptor: Int32, generation expectedGeneration: UInt64) -> Bool {
    lock.withLock {
      guard running, generation == expectedGeneration else { return false }
      connectedDescriptor = descriptor
      return true
    }
  }

  private func clearAndClose(descriptor: Int32) {
    guard descriptor >= 0 else { return }
    lock.withLock {
      if connectedDescriptor == descriptor { connectedDescriptor = -1 }
    }
    Darwin.close(descriptor)
  }

  private static func connectUnixSocket(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ObserverError.systemCall("socket", errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(descriptor)
      throw ObserverError.socketPathTooLong
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
      pathPointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
        for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
      }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    address.sun_len = UInt8(length)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, length)
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw ObserverError.systemCall("connect", code)
    }
    do {
      try UnixSocketOptions.suppressSIGPIPE(on: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private static func writeFrame(_ payload: Data, to descriptor: Int32) throws {
    guard payload.count <= maximumFrameLength else { throw ObserverError.frameTooLarge }
    var length = UInt32(payload.count).littleEndian
    try withUnsafeBytes(of: &length) { try writeAll($0, to: descriptor) }
    try payload.withUnsafeBytes { try writeAll($0, to: descriptor) }
  }

  private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(
        descriptor,
        bytes.baseAddress!.advanced(by: offset),
        bytes.count - offset
      )
      if count > 0 {
        offset += count
      } else if count < 0, errno == EINTR {
        continue
      } else {
        throw ObserverError.systemCall("write", errno)
      }
    }
  }

  private static func readFrame(from descriptor: Int32) throws -> Data {
    var length: UInt32 = 0
    try withUnsafeMutableBytes(of: &length) { try readAll(into: $0, from: descriptor) }
    let frameLength = Int(UInt32(littleEndian: length))
    guard frameLength <= maximumFrameLength else { throw ObserverError.frameTooLarge }
    var data = Data(count: frameLength)
    try data.withUnsafeMutableBytes { try readAll(into: $0, from: descriptor) }
    return data
  }

  private static func readAll(
    into bytes: UnsafeMutableRawBufferPointer,
    from descriptor: Int32
  ) throws {
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.read(
        descriptor,
        bytes.baseAddress!.advanced(by: offset),
        bytes.count - offset
      )
      if count > 0 {
        offset += count
      } else if count == 0 {
        throw ObserverError.endOfStream
      } else if errno == EINTR {
        continue
      } else {
        throw ObserverError.systemCall("read", errno)
      }
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private enum ObserverError: Error, CustomStringConvertible {
    case endOfStream
    case frameTooLarge
    case socketPathTooLong
    case systemCall(String, Int32)

    var description: String {
      switch self {
      case .endOfStream: return "end of stream"
      case .frameTooLarge: return "frame exceeds 8 MiB"
      case .socketPathTooLong: return "Unix socket path is too long"
      case .systemCall(let operation, let code):
        return "\(operation) failed: \(String(cString: strerror(code)))"
      }
    }
  }
}
