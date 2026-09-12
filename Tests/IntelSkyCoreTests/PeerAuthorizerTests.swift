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

@Test func authorizerAcceptsUnifiedCuaReplProcessChain() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "node")
      case 30: return ValidatedCodeIdentity(identifier: "codex")
      case 40: return ValidatedCodeIdentity(identifier: "com.openai.codex")
      default: throw PeerAuthorizationError.cannotResolveCode(pid, -1)
      }
    },
    parentPIDProvider: { pid in
      switch pid {
      case 10: return 20
      case 20: return 30
      default: return 40
      }
    }
  )

  try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
}

@Test func authorizerAcceptsArbitraryLocallySignedWrappersBackedByChatGPT() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "node")
      case 30: return ValidatedCodeIdentity(identifier: "codex")
      case 60: return ValidatedCodeIdentity(identifier: "com.openai.codex")
      default: throw PeerAuthorizationError.invalidSignature(pid, -1)
      }
    },
    intermediateIdentityProvider: { pid in
      switch pid {
      case 40: return ValidatedCodeIdentity(identifier: "first-bridge")
      case 50: return ValidatedCodeIdentity(identifier: "another-wrapper")
      default: throw PeerAuthorizationError.invalidSignature(pid, -1)
      }
    },
    parentPIDProvider: { pid in
      switch pid {
      case 10: return 20
      case 20: return 30
      case 30: return 40
      case 40: return 50
      default: return 60
      }
    }
  )

  try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
}

@Test func authorizerRejectsLocallySignedWrapperChainWithoutChatGPT() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "node")
      case 30: return ValidatedCodeIdentity(identifier: "codex")
      default: return ValidatedCodeIdentity(identifier: "zsh")
      }
    },
    intermediateIdentityProvider: { pid in
      switch pid {
      case 40: return ValidatedCodeIdentity(identifier: "first-bridge")
      case 50: return ValidatedCodeIdentity(identifier: "another-wrapper")
      default: return ValidatedCodeIdentity(identifier: "zsh")
      }
    },
    parentPIDProvider: { pid in
      switch pid {
      case 10: return 20
      case 20: return 30
      case 30: return 40
      case 40: return 50
      default: return 60
      }
    }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerRejectsWrapperOutsideLocalSigningTeam() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "codex")
      case 40: return ValidatedCodeIdentity(identifier: "com.openai.codex")
      default: throw PeerAuthorizationError.invalidSignature(pid, -1)
      }
    },
    intermediateIdentityProvider: { pid in
      throw PeerAuthorizationError.invalidSignature(pid, -1)
    },
    parentPIDProvider: { pid in
      switch pid {
      case 10: return 20
      case 20: return 30
      default: return 40
      }
    }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerRejectsWrapperChainBeyondMaximumDepth() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "codex")
      case 60: return ValidatedCodeIdentity(identifier: "com.openai.codex")
      default: throw PeerAuthorizationError.invalidSignature(pid, -1)
      }
    },
    intermediateIdentityProvider: { pid in
      ValidatedCodeIdentity(identifier: "wrapper-\(pid)")
    },
    parentPIDProvider: { pid in pid + 10 },
    maximumHostChainDepth: 3
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerTreatsNegativeMaximumDepthAsZero() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "codex")
      default: return ValidatedCodeIdentity(identifier: "com.openai.codex")
      }
    },
    parentPIDProvider: { pid in pid + 10 },
    maximumHostChainDepth: -1
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
}

@Test func authorizerRejectsUnifiedCuaReplWithoutCodexParent() throws {
  let authorizer = OpenAIPeerAuthorizer(
    effectiveUID: 501,
    identityProvider: { pid in
      switch pid {
      case 10: return ValidatedCodeIdentity(identifier: "node_repl")
      case 20: return ValidatedCodeIdentity(identifier: "node")
      default: return ValidatedCodeIdentity(identifier: "zsh")
      }
    },
    parentPIDProvider: { pid in pid == 10 ? 20 : 30 }
  )

  #expect(throws: PeerAuthorizationError.self) {
    try authorizer.authorize(PeerIdentity(pid: 10, uid: 501, gid: 20))
  }
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

@Test func pipHostAuthorizerAcceptsOnlySignedChatGPTIdentity() throws {
  let allowed = OpenAIChatGPTHostAuthorizer { _ in
    ValidatedCodeIdentity(identifier: "com.openai.codex")
  }
  let denied = OpenAIChatGPTHostAuthorizer { _ in
    ValidatedCodeIdentity(identifier: "node_repl")
  }

  try allowed.authorize(processIdentifier: 10)
  #expect(throws: PeerAuthorizationError.self) {
    try denied.authorize(processIdentifier: 10)
  }
}
