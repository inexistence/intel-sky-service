import Darwin
import Testing

@testable import IntelSkyCore

@Test func authorizerAcceptsTrustedChatGPTProcessChain() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "codex")
      case 30: return ValidatedCodeIdentity(identifier: "com.openai.codex")
      default: throw PeerAuthorizationError.cannotResolveCode(pid, -1)
      }
    },
    parentPIDProvider: { pid in pid == 10 ? 20 : 30 }
  )

  try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
}

@Test func authorizerRejectsSignedNodeLaunchedDirectly() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { _ in ValidatedCodeIdentity(identifier: "node") },
    parentPIDProvider: { _ in 20 }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerRejectsCodexWithoutChatGPTGrandparent() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "codex")
      default: return ValidatedCodeIdentity(identifier: "zsh")
      }
    },
    parentPIDProvider: { pid in pid == 10 ? 20 : 30 }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerRejectsNodeReplWithoutCodexParent() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      ValidatedCodeIdentity(identifier: pid == 10 ? "node_repl" : "zsh")
    },
    parentPIDProvider: { _ in 20 }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerRejectsDifferentUserBeforeInspectingCode() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in throw PeerAuthorizationError.cannotResolveCode(pid, -1) },
    parentPIDProvider: { _ in 20 }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 502, gid: 20))
  }
}
