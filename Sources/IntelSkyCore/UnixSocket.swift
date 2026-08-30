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

public final class SkyUnixServer: @unchecked Sendable {
  private let socketPath: String
  private let router: SkyRequestRouter
  private let authorizer: any PeerAuthorizing
  private let connectionQueue = DispatchQueue(
    label: "dev.huangjianbin.intel-sky-service.connections",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let connectionSlots = DispatchSemaphore(value: 8)
  private let stateLock = NSLock()
  private var listener: Int32 = -1
  private var ownedSocketIdentity: UnixSocketFilePreparer.UnixSocketIdentity?
  private var shuttingDown = false

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
    shutdown()
  }

  public var isShuttingDown: Bool {
    stateLock.withLock { shuttingDown }
  }

  public func shutdown() {
    let state: (Int32, UnixSocketFilePreparer.UnixSocketIdentity?) = stateLock.withLock {
      shuttingDown = true
      let state = (listener, ownedSocketIdentity)
      listener = -1
      ownedSocketIdentity = nil
      return state
    }
    if state.0 >= 0 {
      _ = Darwin.shutdown(state.0, SHUT_RDWR)
      close(state.0)
    }
    if let identity = state.1 {
      UnixSocketFilePreparer.removeSocketIfOwned(at: socketPath, identity: identity)
    }
  }

  public func run(onReady: () -> Void = {}) throws {
    try prepareSocketDirectory()
    try UnixSocketFilePreparer.removeStaleSocketIfSafe(at: socketPath)
    var address = try makeUnixSocketAddress(socketPath)

    let listeningSocket = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listeningSocket >= 0 else { throw systemError("socket") }
    let installed = stateLock.withLock {
      guard !shuttingDown else { return false }
      listener = listeningSocket
      return true
    }
    guard installed else {
      close(listeningSocket)
      return
    }
    defer { shutdown() }
    try UnixSocketOptions.suppressSIGPIPE(on: listeningSocket)

    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listeningSocket, $0, unixSocketAddressLength(socketPath))
      }
    }
    guard bindResult == 0 else { throw systemError("bind") }
    guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else { throw systemError("chmod") }
    guard listen(listeningSocket, 8) == 0 else { throw systemError("listen") }
    let identity = try UnixSocketFilePreparer.identity(ofSocketAt: socketPath)
    let stillRunning = stateLock.withLock {
      guard !shuttingDown, listener == listeningSocket else { return false }
      ownedSocketIdentity = identity
      return true
    }
    guard stillRunning else {
      UnixSocketFilePreparer.removeSocketIfOwned(at: socketPath, identity: identity)
      return
    }
    onReady()

    while true {
      let client = accept(listeningSocket, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        if isShuttingDown, errno == EBADF || errno == EINVAL { return }
        throw systemError("accept")
      }
      do {
        try UnixSocketOptions.suppressSIGPIPE(on: client)
      } catch {
        close(client)
        fputs("connection rejected: \(error)\n", stderr)
        continue
      }
      connectionSlots.wait()
      connectionQueue.async { [self] in
        defer {
          close(client)
          connectionSlots.signal()
        }
        do {
          try setReceiveTimeout(milliseconds: 2_000, on: client)
          try serve(client)
        } catch {
          fputs("connection rejected: \(error)\n", stderr)
        }
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
    do {
      try UnixSocketOptions.suppressSIGPIPE(on: descriptor)
    } catch {
      close(descriptor)
      descriptor = -1
      throw error
    }

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

enum UnixSocketOptions {
  static func suppressSIGPIPE(on descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      throw UnixSocketError.systemCall("setsockopt(SO_NOSIGPIPE)", errno)
    }
  }
}

enum UnixSocketFilePreparer {
  struct UnixSocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
  }

  static func identity(ofSocketAt path: String, effectiveUID: uid_t = geteuid()) throws
    -> UnixSocketIdentity
  {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      throw UnixSocketError.systemCall("lstat", errno)
    }
    guard (metadata.st_mode & S_IFMT) == S_IFSOCK, metadata.st_uid == effectiveUID else {
      throw UnixSocketError.unsafeExistingPath(path)
    }
    return UnixSocketIdentity(
      device: metadata.st_dev,
      inode: metadata.st_ino,
      owner: metadata.st_uid
    )
  }

  static func removeSocketIfOwned(at path: String, identity expectedIdentity: UnixSocketIdentity) {
    guard let current = try? identity(ofSocketAt: path, effectiveUID: expectedIdentity.owner),
      current == expectedIdentity
    else { return }
    _ = unlink(path)
  }

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
