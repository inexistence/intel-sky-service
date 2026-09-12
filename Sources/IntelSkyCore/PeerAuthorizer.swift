import Darwin
import Foundation
import Security

public struct PeerIdentity: Sendable, Equatable {
  public let pid: pid_t
  public let uid: uid_t
  public let gid: gid_t

  public init(pid: pid_t, uid: uid_t, gid: gid_t) {
    self.pid = pid
    self.uid = uid
    self.gid = gid
  }

  public init(socket: Int32) throws {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(socket, &peerUID, &peerGID) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var peerPID: pid_t = 0
    var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    self.init(pid: peerPID, uid: peerUID, gid: peerGID)
  }
}

public protocol PeerAuthorizing: Sendable {
  func authorize(_ peer: PeerIdentity) throws
}

public enum PeerAuthorizationError: Error, CustomStringConvertible {
  case wrongUser(uid_t)
  case cannotResolveParent(pid_t)
  case cannotResolveCode(pid_t, OSStatus)
  case invalidSignature(pid_t, OSStatus)
  case missingSigningInfo(pid_t, OSStatus)
  case disallowedIdentifier(pid_t, String?, expected: Set<String>)
  case trustedHostNotFound(pid_t, maximumDepth: Int)

  public var description: String {
    switch self {
    case .wrongUser(let uid):
      return "Peer UID \(uid) does not match service UID"
    case .cannotResolveParent(let pid):
      return "Could not resolve parent process for peer PID \(pid)"
    case .cannotResolveCode(let pid, let status):
      return "Could not resolve code identity for PID \(pid) (OSStatus \(status))"
    case .invalidSignature(let pid, let status):
      return "PID \(pid) has an invalid or untrusted signature (OSStatus \(status))"
    case .missingSigningInfo(let pid, let status):
      return "PID \(pid) has no readable signing metadata (OSStatus \(status))"
    case .disallowedIdentifier(let pid, let identifier, let expected):
      return "PID \(pid) identifier \(identifier ?? "<missing>") is not in \(expected.sorted())"
    case .trustedHostNotFound(let pid, let maximumDepth):
      return "No trusted ChatGPT host was found above PID \(pid) within \(maximumDepth) ancestors"
    }
  }
}

struct ValidatedCodeIdentity: Sendable, Equatable {
  let identifier: String
}

public struct OpenAIPeerAuthorizer: PeerAuthorizing {
  public static let teamIdentifier = "2DC432GLL2"
  public static let allowedPeerIdentifiers: Set<String> = ["node_repl"]
  public static let allowedDirectParentIdentifiers: Set<String> = ["codex"]
  public static let allowedUnifiedParentIdentifiers: Set<String> = ["node"]
  public static let allowedHostIdentifiers: Set<String> = ["com.openai.codex"]
  public static let maximumHostChainDepth = 12

  private let effectiveUID: uid_t
  private let identityProvider: @Sendable (pid_t) throws -> ValidatedCodeIdentity
  private let intermediateIdentityProvider: @Sendable (pid_t) throws -> ValidatedCodeIdentity
  private let parentPIDProvider: @Sendable (pid_t) throws -> pid_t
  private let hostChainDepth: Int

  public init() {
    effectiveUID = geteuid()
    identityProvider = Self.readValidatedIdentity
    let localTeamIdentifier = Self.readSelfTeamIdentifier()
    intermediateIdentityProvider = { pid in
      guard let localTeamIdentifier else {
        throw PeerAuthorizationError.missingSigningInfo(getpid(), errSecCSUnsigned)
      }
      return try Self.readValidatedIdentity(
        pid,
        requirementText:
          "anchor apple generic and certificate leaf[subject.OU] = \"\(localTeamIdentifier)\""
      )
    }
    parentPIDProvider = Self.readParentPID
    hostChainDepth = Self.maximumHostChainDepth
  }

  init(
    effectiveUID: uid_t,
    identityProvider: @escaping @Sendable (pid_t) throws -> ValidatedCodeIdentity,
    intermediateIdentityProvider: (@Sendable (pid_t) throws -> ValidatedCodeIdentity)? = nil,
    parentPIDProvider: @escaping @Sendable (pid_t) throws -> pid_t,
    maximumHostChainDepth: Int = maximumHostChainDepth
  ) {
    self.effectiveUID = effectiveUID
    self.identityProvider = identityProvider
    self.intermediateIdentityProvider = intermediateIdentityProvider ?? identityProvider
    self.parentPIDProvider = parentPIDProvider
    self.hostChainDepth = max(0, maximumHostChainDepth)
  }

  public func authorize(_ peer: PeerIdentity) throws {
    guard peer.uid == effectiveUID else {
      throw PeerAuthorizationError.wrongUser(peer.uid)
    }

    let peerIdentity = try identityProvider(peer.pid)
    guard Self.allowedPeerIdentifiers.contains(peerIdentity.identifier) else {
      throw PeerAuthorizationError.disallowedIdentifier(
        peer.pid,
        peerIdentity.identifier,
        expected: Self.allowedPeerIdentifiers
      )
    }

    let parentPID = try parentPIDProvider(peer.pid)
    let parentIdentity = try identityProvider(parentPID)
    let codexPID: pid_t
    if Self.allowedDirectParentIdentifiers.contains(parentIdentity.identifier) {
      codexPID = parentPID
    } else if Self.allowedUnifiedParentIdentifiers.contains(parentIdentity.identifier) {
      let unifiedParentPID = try parentPIDProvider(parentPID)
      let unifiedParentIdentity = try identityProvider(unifiedParentPID)
      guard Self.allowedDirectParentIdentifiers.contains(unifiedParentIdentity.identifier) else {
        throw PeerAuthorizationError.disallowedIdentifier(
          unifiedParentPID,
          unifiedParentIdentity.identifier,
          expected: Self.allowedDirectParentIdentifiers
        )
      }
      codexPID = unifiedParentPID
    } else {
      throw PeerAuthorizationError.disallowedIdentifier(
        parentPID,
        parentIdentity.identifier,
        expected: Self.allowedDirectParentIdentifiers.union(Self.allowedUnifiedParentIdentifiers)
      )
    }

    var ancestorPID = try parentPIDProvider(codexPID)
    var visited: Set<pid_t> = [peer.pid, parentPID, codexPID]
    for _ in 0..<hostChainDepth {
      guard visited.insert(ancestorPID).inserted else {
        throw PeerAuthorizationError.cannotResolveParent(ancestorPID)
      }
      if let openAIIdentity = try? identityProvider(ancestorPID) {
        if Self.allowedHostIdentifiers.contains(openAIIdentity.identifier) {
          return
        }
      } else {
        // Wrapper names are intentionally unrestricted. Each ancestor must be
        // signed by OpenAI or by the service's own signing Team ID, and the
        // chain must still terminate at an OpenAI-signed ChatGPT process.
        _ = try intermediateIdentityProvider(ancestorPID)
      }
      ancestorPID = try parentPIDProvider(ancestorPID)
    }
    throw PeerAuthorizationError.trustedHostNotFound(
      codexPID,
      maximumDepth: hostChainDepth
    )
  }

  private static func readParentPID(_ pid: pid_t) throws -> pid_t {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
    guard result == expectedSize, info.pbi_ppid > 0 else {
      throw PeerAuthorizationError.cannotResolveParent(pid)
    }
    return pid_t(info.pbi_ppid)
  }

  static func readValidatedIdentity(_ pid: pid_t) throws -> ValidatedCodeIdentity {
    try readValidatedIdentity(
      pid,
      requirementText:
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    )
  }

  private static func readValidatedIdentity(
    _ pid: pid_t,
    requirementText: String
  ) throws -> ValidatedCodeIdentity {
    let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    var code: SecCode?
    let lookupStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard lookupStatus == errSecSuccess, let code else {
      throw PeerAuthorizationError.cannotResolveCode(pid, lookupStatus)
    }

    var requirement: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
      requirementText as CFString, [], &requirement)
    guard requirementStatus == errSecSuccess, let requirement else {
      throw PeerAuthorizationError.invalidSignature(pid, requirementStatus)
    }

    let validityStatus = SecCodeCheckValidity(code, [], requirement)
    guard validityStatus == errSecSuccess else {
      throw PeerAuthorizationError.invalidSignature(pid, validityStatus)
    }

    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
    guard staticStatus == errSecSuccess, let staticCode else {
      throw PeerAuthorizationError.missingSigningInfo(pid, staticStatus)
    }

    var signingInfo: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInfo
    )
    guard infoStatus == errSecSuccess,
      let info = signingInfo as? [CFString: Any],
      let identifier = info[kSecCodeInfoIdentifier] as? String
    else {
      throw PeerAuthorizationError.missingSigningInfo(pid, infoStatus)
    }
    return ValidatedCodeIdentity(identifier: identifier)
  }

  private static func readSelfTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }
    var signingInfo: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &signingInfo
      ) == errSecSuccess,
      let info = signingInfo as? [CFString: Any],
      let teamIdentifier = info[kSecCodeInfoTeamIdentifier] as? String,
      !teamIdentifier.isEmpty
    else { return nil }
    return teamIdentifier
  }
}

protocol ProcessAuthorizing: Sendable {
  func authorize(processIdentifier: pid_t) throws
}

struct OpenAIChatGPTHostAuthorizer: ProcessAuthorizing {
  static let allowedIdentifiers: Set<String> = ["com.openai.codex"]

  private let identityProvider: @Sendable (pid_t) throws -> ValidatedCodeIdentity

  init(
    identityProvider: @escaping @Sendable (pid_t) throws -> ValidatedCodeIdentity =
      OpenAIPeerAuthorizer.readValidatedIdentity
  ) {
    self.identityProvider = identityProvider
  }

  func authorize(processIdentifier: pid_t) throws {
    let identity = try identityProvider(processIdentifier)
    guard Self.allowedIdentifiers.contains(identity.identifier) else {
      throw PeerAuthorizationError.disallowedIdentifier(
        processIdentifier,
        identity.identifier,
        expected: Self.allowedIdentifiers
      )
    }
  }
}
