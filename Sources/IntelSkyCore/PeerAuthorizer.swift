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
    }
  }
}

struct ValidatedCodeIdentity: Sendable, Equatable {
  let identifier: String
}

public struct OpenAIPeerAuthorizer: PeerAuthorizing {
  public static let teamIdentifier = "2DC432GLL2"
  public static let allowedPeerIdentifiers: Set<String> = ["node_repl"]
  public static let allowedParentIdentifiers: Set<String> = ["codex"]
  public static let allowedGrandparentIdentifiers: Set<String> = ["com.openai.codex"]

  private let effectiveUID: uid_t
  private let identityProvider: @Sendable (pid_t) throws -> ValidatedCodeIdentity
  private let parentPIDProvider: @Sendable (pid_t) throws -> pid_t

  public init() {
    effectiveUID = geteuid()
    identityProvider = Self.readValidatedIdentity
    parentPIDProvider = Self.readParentPID
  }

  init(
    effectiveUID: uid_t,
    identityProvider: @escaping @Sendable (pid_t) throws -> ValidatedCodeIdentity,
    parentPIDProvider: @escaping @Sendable (pid_t) throws -> pid_t
  ) {
    self.effectiveUID = effectiveUID
    self.identityProvider = identityProvider
    self.parentPIDProvider = parentPIDProvider
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
    guard Self.allowedParentIdentifiers.contains(parentIdentity.identifier) else {
      throw PeerAuthorizationError.disallowedIdentifier(
        parentPID,
        parentIdentity.identifier,
        expected: Self.allowedParentIdentifiers
      )
    }

    let grandparentPID = try parentPIDProvider(parentPID)
    let grandparentIdentity = try identityProvider(grandparentPID)
    guard Self.allowedGrandparentIdentifiers.contains(grandparentIdentity.identifier) else {
      throw PeerAuthorizationError.disallowedIdentifier(
        grandparentPID,
        grandparentIdentity.identifier,
        expected: Self.allowedGrandparentIdentifiers
      )
    }
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
    let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    var code: SecCode?
    let lookupStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard lookupStatus == errSecSuccess, let code else {
      throw PeerAuthorizationError.cannotResolveCode(pid, lookupStatus)
    }

    let requirementText =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
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
