import Darwin
import Foundation

public enum UnixSocketError: Error, CustomStringConvertible {
  case pathTooLong(String)
  case alreadyConnected
  case notConnected
  case socketAlreadyInUse(String)
  case unsafeExistingPath(String)
  case systemCall(String, Int32)
  case disconnected

  public var description: String {
    switch self {
    case .pathTooLong(let path): return "Unix socket path is too long: \(path)"
    case .alreadyConnected: return "Unix socket client is already connected"
    case .notConnected: return "Unix socket client is not connected"
    case .socketAlreadyInUse(let path): return "A service is already listening at: \(path)"
    case .unsafeExistingPath(let path): return "Refusing to replace non-socket path: \(path)"
    case .systemCall(let name, let code):
      return "\(name) failed: \(String(cString: strerror(code)))"
    case .disconnected: return "Peer disconnected"
    }
  }
}

public final class SkyUnixServer {
  private let socketPath: String
  private let router: SkyRequestRouter
  private let authorizer: any PeerAuthorizing
  private var listener: Int32 = -1

  public init(
    socketPath: String,
    router: SkyRequestRouter,
    authorizer: any PeerAuthorizing = OpenAIPeerAuthorizer()
  ) {
    self.socketPath = socketPath
    self.router = router
    self.authorizer = authorizer
  }

  deinit {
    if listener >= 0 { close(listener) }
  }

  public func run() throws -> Never {
    try prepareSocketDirectory()
    try UnixSocketFilePreparer.removeStaleSocketIfSafe(at: socketPath)
    var address = try makeUnixSocketAddress(socketPath)

    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw systemError("socket") }

    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, unixSocketAddressLength(socketPath))
      }
    }
    guard bindResult == 0 else { throw systemError("bind") }
    guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else { throw systemError("chmod") }
    guard listen(listener, 8) == 0 else { throw systemError("listen") }

    while true {
      let client = accept(listener, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        throw systemError("accept")
      }
      defer { close(client) }
      try setReceiveTimeout(milliseconds: 2_000, on: client)
      do {
        try serve(client)
      } catch {
        fputs("connection rejected: \(error)\n", stderr)
      }
    }
  }

  private func serve(_ client: Int32) throws {
    var decoder = SkyFrameDecoder()
    var didReplyToPing = false
    var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
      let count = Darwin.read(client, &readBuffer, readBuffer.count)
      if count == 0 { return }
      if count < 0 {
        if errno == EINTR { continue }
        throw systemError("read")
      }

      for payload in try decoder.append(Data(readBuffer.prefix(count))) {
        if !didReplyToPing, !SkyRequestRouter.isCompatiblePing(payload) {
          throw SkyRPCError.invalidRequest("First request must be ping")
        }
        let response = router.handle(payload)
        try writeFrame(response, to: client)

        if !didReplyToPing {
          didReplyToPing = true
          let peer = try PeerIdentity(socket: client)
          try authorizer.authorize(peer)
          try setReceiveTimeout(milliseconds: 0, on: client)
        }
      }
    }
  }

  private func writeFrame(_ payload: Data, to socket: Int32) throws {
    let frame = try SkyFrameCodec().encode(payload)
    try frame.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = Darwin.write(socket, pointer, remaining)
        if written < 0 {
          if errno == EINTR { continue }
          throw systemError("write")
        }
        if written == 0 { throw UnixSocketError.disconnected }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
    }
  }

  private func prepareSocketDirectory() throws {
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try SecureDirectoryPreparer.prepare(directory)
  }

  private func systemError(_ name: String) -> UnixSocketError {
    .systemCall(name, errno)
  }

  private func setReceiveTimeout(milliseconds: Int, on socket: Int32) throws {
    var timeout = timeval(
      tv_sec: milliseconds / 1_000,
      tv_usec: Int32((milliseconds % 1_000) * 1_000)
    )
    let result = setsockopt(
      socket,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    guard result == 0 else { throw systemError("setsockopt(SO_RCVTIMEO)") }
  }
}

public final class SkyUnixClient {
  private let socketPath: String
  private var descriptor: Int32 = -1
  private var decoder = SkyFrameDecoder()

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
  }

  public func connect() throws {
    guard descriptor < 0 else { throw UnixSocketError.alreadyConnected }
    var address = try makeUnixSocketAddress(socketPath)
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw UnixSocketError.systemCall("socket", errno) }

    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, unixSocketAddressLength(socketPath))
      }
    }
    guard result == 0 else {
      let connectError = errno
      close(descriptor)
      descriptor = -1
      throw UnixSocketError.systemCall("connect", connectError)
    }
  }

  public func request(_ object: [String: Any]) throws -> [String: Any] {
    guard descriptor >= 0 else { throw UnixSocketError.notConnected }
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let frame = try SkyFrameCodec().encode(payload)
    try frame.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        if written < 0 {
          if errno == EINTR { continue }
          throw UnixSocketError.systemCall("write", errno)
        }
        if written == 0 { throw UnixSocketError.disconnected }
        pointer = pointer.advanced(by: written)
        remaining -= written
      }
    }

    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw UnixSocketError.systemCall("read", errno)
      }
      if count == 0 { throw UnixSocketError.disconnected }
      if let response = try decoder.append(Data(buffer.prefix(count))).first {
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
          throw SkyRPCError.invalidRequest("Response was not a JSON object")
        }
        return object
      }
    }
  }
}

enum UnixSocketFilePreparer {
  static func removeStaleSocketIfSafe(at path: String, effectiveUID: uid_t = geteuid()) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      if errno == ENOENT { return }
      throw UnixSocketError.systemCall("lstat", errno)
    }
    guard (metadata.st_mode & S_IFMT) == S_IFSOCK, metadata.st_uid == effectiveUID else {
      throw UnixSocketError.unsafeExistingPath(path)
    }

    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
    defer { close(probe) }
    let currentFlags = fcntl(probe, F_GETFL)
    guard currentFlags >= 0, fcntl(probe, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
      throw UnixSocketError.systemCall("fcntl(O_NONBLOCK)", errno)
    }
    var address = try makeUnixSocketAddress(path)
    let connectResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(probe, $0, unixSocketAddressLength(path))
      }
    }
    if connectResult == 0 {
      throw UnixSocketError.socketAlreadyInUse(path)
    }
    let connectError = errno
    if connectError == EINPROGRESS || connectError == EAGAIN {
      throw UnixSocketError.socketAlreadyInUse(path)
    }
    if connectError == ENOENT { return }
    guard connectError == ECONNREFUSED else {
      throw UnixSocketError.systemCall("connect existing socket", connectError)
    }
    guard unlink(path) == 0 else { throw UnixSocketError.systemCall("unlink", errno) }
  }
}

func makeUnixSocketAddress(_ path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = Array(path.utf8CString)
  guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
    throw UnixSocketError.pathTooLong(path)
  }
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.initializeMemory(as: UInt8.self, repeating: 0)
    pathBytes.withUnsafeBytes { destination.copyBytes(from: $0) }
  }
  return address
}

func unixSocketAddressLength(_ path: String) -> socklen_t {
  socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
}
