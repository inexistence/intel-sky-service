# Computer Use Runtime protocol catalog

This catalog is the machine-checked protocol index for `CodexComputerUseIPC-5`. The inspected
baseline is Intel ChatGPT 26.825.41651 (build 7345), `@oai/sky`
`0.6.24-premerge-pr-1369830-395ab116910c`, and ARM `SkyComputerUseService` 26.828.1000919. It records
the 34 request types present in that ARM binary's Swift field metadata plus the statically recovered
`ComputerUseIPCAppUsageRequest` type/name. Behavioral evidence and
experiment history remain in `OfficialBehaviorNotes.md`; this file is intentionally organized by
wire surface.

## Evidence and shared rules

- `CONFIRMED_STATIC_BINARY`: request/type names and stored fields came from `__swift5_fieldmd` via
  `Tools/reverse/swift-field-metadata.mjs`.
- `CONFIRMED_CLIENT_SOURCE`: request construction or return shape is present in the installed
  `@oai/sky` JavaScript/declaration output or Intel ChatGPT caller.
- `CONFIRMED_INTEL_RUNTIME`: an unmodified official client exercised the installed Intel service.
- `HIGH_CONFIDENCE`, `PARTIAL`, `NEEDS_ARM_ORACLE`, and `OUT_OF_SCOPE` have the meanings defined in
  `OfficialBehaviorNotes.md`.

Unless a row says otherwise, these common properties apply:

| Property | Protocol rule |
| --- | --- |
| Socket framing | Owner-only Unix socket; four-byte little-endian frame length; 8 MiB maximum. Intel additionally validates directory/socket ownership and mode plus the peer UID. |
| API envelope | JSON-RPC 2.0 `request` with `clientApiVersion: CodexComputerUseIPC-5`, `requestType`, object `request`, optional `codexTurnMetadata`, and optional absolute `deadlineUnixMilliseconds`. Success is `{jsonrpc,id,result}`; failure is `{jsonrpc,id,error:{code,message}}`. |
| Deadline | Checked before dispatch and before reply. Long-poll Capture updates additionally check while waiting. The ARM public code family has no dedicated deadline case; Intel returns `unknownError (-10005)` with `Request deadline exceeded`. Exact ARM deadline mapping is `NEEDS_ARM_ORACLE`. |
| Socket authorization | Owner-only Unix socket and peer-token/process-chain authorization. The official ARM service has generic JSON-RPC socket and XPC sessions; per-request XPC caller coverage is not inferred from the generic dispatcher. |
| Apple Event authorization | Intel native bridge `SkCu/SndR`, bridge version `CodexComputerUseNativeBridge-1`, signed OpenAI ChatGPT host only. Response is UTF-8 JSON in direct-object `tdta`; errors use `errn/errs`. |
| PIP bootstrap | Intel `SkCu/PiPB` Apple Event carries bridge version, sender PID, and a Mach reply port. Its reply-port XPC dictionary transfers an anonymous endpoint under key `endpoint`; both Apple Event and XPC admission authenticate the ChatGPT host. |
| Turn lifecycle | Valid `session_id/thread_id/turn_id` metadata starts or transitions that thread's runtime registry entry. A matching end revokes only that thread's App/Capture/PIP/cursor/focus/cache state; global safety revocation and shutdown revoke all entries. The first scoped start also clears legacy unscoped state. |
| Entitlements | Core socket/AE requests need no private entitlement. Accessibility, Screen Recording, Input Monitoring, Secure Input, organization policy, and App approval are runtime/TCC or policy gates. Intel neither claims nor copies an OpenAI entitlement. Remote Hosted PIP uses dynamically checked private SPI, but the cross-signature CAContext smoke disproves a Team-ID-only render restriction. |

Transport abbreviations: `S` = JSON-RPC socket, `AE` = authenticated native Apple Event, and
`XPC?` = the ARM generic XPC dispatcher exists but a caller for this individual request has not
been proved. `AE` is listed only where the current Intel bridge accepts the request.

## In-scope request directory

| Request | Stored request fields | Result fields / envelope | Transport | Approval and lifecycle | Intel implementation / tests | Evidence and remaining difference | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ComputerUseIPCListAppsRequest` | empty | array of `DiscoveredApp {displayName,bundleIdentifier,appPath,lastUsedDate,useCount,isRunning,isFrontmost}` | S, XPC? | Discovery only; no target approval | Workspace catalog; `SkyProtocolTests`, `WorkspaceAppCatalogTests`, official client smoke | Client source + ARM metadata; recent-use provenance is `HIGH_CONFIDENCE` | IMPLEMENTED |
| `ComputerUseIPCAppUsageRequest` | empty | array of `DiscoveredApp {displayName,bundleIdentifier,appPath,lastUsedDate,useCount,isRunning,isFrontmost}` | S, XPC? | Read-only recent App usage | Workspace catalog; `SkyProtocolTests`, `WorkspaceAppCatalogTests` | ARM type/name is static-confirmed outside field metadata; exact result binding and distinction from List Apps remain `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppPolicyRequest` | `app` | `AppPolicyResult {decision,target,allowPersistentApproval}`; target has `bundleIdentifier,displayName,appPath,risk,warningSubtitle` | S, XPC? | Preflight only; policy decides whether later approval/action is possible | Forbidden-target and risk classifier plus initialized app-server organization-policy provider; `MacAppPolicyTests`, `CodexAppServerComputerUsePolicyProviderTests`, `SkyProtocolTests` | Legacy and current config-requirements policy shapes, cache, coalescing, precedence, and failure behavior are covered; exact ARM classifier membership remains `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppStartRequest` | `app` | `SkyshotResult {app,skyshot,appSpecificInstructions?}` | S, XPC? | Policy, user-stop latch, AX and screenshot TCC; starts App session and full baseline | Full initial state; `SkyProtocolTests`, official client | Already-running timing is `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppGetSkyshotRequest` | `app,disableDiff` | `SkyshotResult {app,skyshot,appSpecificInstructions?}` where `skyshot {text,screenshot?}` | S, AE, XPC? | Same gates as Start; refreshes action/intervention baseline | Full/diff AX plus visual-role-gated screenshot; `SkyProtocolTests`, `SkyshotClassifierTests`, AX/tree/screenshot tests, official client | ARM `SkyshotClassifier` and feature metadata are static-confirmed; exact private classifier remains `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppPerformActionRequest` | `app,action` | Public client returns void; Intel `{}`. ARM `ActionResult {app,skyshot}` metadata exists, but binding it to this handler is unproved | S, XPC? | Requires approved active target, fresh state, unlocked screen; text injection also rejects Secure Input | All action cases; `MacAppActionPerformerTests`, official client actions | Exact ignored ARM result payload is `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppStopRequest` | `app` | empty | S, AE, XPC? | User action; turn-scoped stop latch, cancels operations/streams/PIP | Session coordinator; `ComputerUseSessionCoordinatorTests`, bridge/router tests | Exact non-cooperative cancellation timing is `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppModifyRequest` | `app,modification` (`activate\|deactivate`) | `AppState {active,currentApp?}` | S, XPC? | Policy and stop latch on activate; deactivation ends the owning thread's Capture/PIP and clears its AX/diff/intervention/screenshot state without latching user stop | `MacAppLifecycleProvider`; lifecycle/router/cache tests | No installed Intel caller; idempotence timing is `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCFrontmostWindowRequest` | empty | optional `FrontmostWindow {bundleIdentifier,name,windowTitle?}` or `null` | S, XPC? | Read-only | NSWorkspace + focused AX window; lifecycle/router tests | Exact official filtering/title choice is `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCCodexStatusItemMenuStateRequest` | empty | `CodexStatusItemMenuState {computerUse,computerHistory}` and nested active/recent App descriptors | S, AE, XPC? | Read-only status menu | Session registry; status/bridge tests | Installed Intel caller confirmed | IMPLEMENTED |
| `ComputerUseIPCCodexTurnEndedRequest` | `threadID,turnID` | empty | S, XPC? | Ends only the matching thread; revokes its streams/PIP/cursor/session/caches before conservative focus restoration while preserving other threads | Per-thread turn registry and runtime coordinator; lifecycle/router/cache tests | Component ordering `HIGH_CONFIDENCE`; ARM runtime ordering needs oracle | IMPLEMENTED |
| `ComputerUseIPCAppStartCaptureRequest` | `app,requestID,permissionRequestID,animationTarget,version` | `StartCaptureResponse {result,animationDuration?,transitionSnapshotHeight?,transitionSpringResponse?,transitionSpringDampingFraction?,permissionGrantState?}` | S, AE, XPC? | Policy, AX/Screen TCC; owns session by connection/AE sender and turn | AX/ScreenCaptureKit-driven continuous socket producer, finite AE Appshot sequence, and dedicated Retina composer-transition artwork; `AppCaptureSessionTests`, `AppshotTransitionSnapshotRendererTests`, bridge tests | Native change delivery and transition structure are `HIGH_CONFIDENCE`; exact ARM animation timing and reliable-final-frame machinery remain `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCAppNextCaptureUpdateRequest` | `requestID` | `CaptureUpdate {type,app,text?,screenshot?,transitionSnapshotURL?,failureReason?}`; types `metadata\|axText\|screenshot\|completed\|failed` | S, AE, XPC? | Owner-only long poll; deadline, disconnect and lifecycle terminal behavior | Bounded/coalescing queue; `AppCaptureSessionTests`, router/bridge tests | Exact ARM backpressure and disconnect visibility are `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCEventStreamStartRequest` | empty | `EventStreamSessionStatus` | S, XPC? | Requires Input Monitoring; connection/thread owned; 30-minute maximum | Direct event tap + AX sampler + owner-only JSONL; ARM-observed credential-manager suppression; `EventStreamSessionTests`, router tests | Exact debounce/buffering and complete dynamic URL policy database are `PARTIAL` | IMPLEMENTED |
| `ComputerUseIPCEventStreamStatusRequest` | empty | `EventStreamSessionStatus {isRecording,sessionID?,sessionDirectoryPath?,eventsPath?,metadataPath?,suppressedEventsPath?,startedAt?,endedAt?,endReason?,maxDurationSeconds}` | S, XPC? | Read-only; latest session retained | `EventStreamSessionManager`; event/router tests | Cached MCP disconnect behavior remains `NEEDS_ARM_ORACLE` | IMPLEMENTED |
| `ComputerUseIPCEventStreamStopRequest` | `reason` (`toolStopped\|debugUIStopped\|recordingControlsStopped\|recordingControlsCancelled\|maxDuration\|serviceTerminated`) | `EventStreamSessionStatus` | S, XPC? | Explicit terminal transition; drains/writes metadata and closes tap/files | `EventStreamSessionManager`; event/router tests | Exact caller-specific end-reason choice needs oracle | IMPLEMENTED |

### `ComputerUseIPCAction` payload cases

ARM metadata confirms the cases `click`, `performSecondaryAction`, `setValue`, `selectText`,
`scroll`, `drag`, `pressKey`, `type`, and `paste`. Location is either
`coordinate { _0:[x,y] }` or `elementID { _0:String }`; scroll direction is
`up|down|left|right`; paste format is `text|md|html`; selection is
`text|cursorBefore|cursorAfter`. The installed public client confirms its concrete JSON spelling.
Action-specific policy, coordinate, focus, cursor, intervention, deadline, and stale-element behavior
is indexed in `OfficialBehaviorNotes.md` and covered by the action/AX/input test files.

## Explicitly out-of-scope request directory

These 19 types are retained in the protocol inventory but intentionally not implemented. Intel
returns the protocol-compatible `couldNotResolveRequestType (-10003)` envelope before dispatching
any provider, does not prompt, and produces no side effect (`SkyProtocolTests`). This is the safe
behavior required by the goal; the request rows remain `OUT_OF_SCOPE`.

| Request | Stored request fields | Known/expected ARM result fields | Transport / caller | Permission and lifecycle | Intel behavior / test | Evidence gap | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ComputerUseIPCStartAudioRecordingRequest` | `maxDurationMilliseconds` | empty | S, XPC?; public `@oai/sky` | Explicit host audio approval; client accepts integer 100...300000 ms (default 60000); exact TCC domain is out of scope | Safe unsupported; catalog test | Client source + metadata | OUT_OF_SCOPE |
| `ComputerUseIPCStopAudioRecordingRequest` | empty | `Audio {url?}` (24 kHz stereo WAV in client docs) | S, XPC?; public `@oai/sky` | Ends current audio recording | Safe unsupported; catalog test | Client source + metadata | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightStartRequest` | empty | likely `SkysightStatus`; exact handler binding unproved | S, XPC?; ChatGPT history controls | Observation approval/settings; starts segment writer | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` result binding | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightStatusRequest` | empty | `SkysightStatus {state,eventStreamRootPath,currentSegmentEventsPath,currentSegmentMetadataPath,suppressedEventsPath,startedAt,endedAt}` | S, XPC? | Read-only | Safe unsupported; catalog test | Named response metadata; handler binding `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightStopRequest` | empty | likely `SkysightStatus` | S, XPC? | Ends observation/segments | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` exact payload | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightPauseRequest` | `duration` (`thirtyMinutes\|oneHour\|untilTomorrow`) | likely `SkysightStatus` | S, XPC? | Timed pause | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` exact payload | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightResumeRequest` | empty | likely `SkysightStatus` | S, XPC? | Resumes paused observation | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` exact payload | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightClearHistoryRequest` | `scope,interval`; interval is meaningful for scope `interval`; scope cases `applicationSession\|lastTenMinutes\|lastHour\|lastDay\|all\|interval` | exact result not recovered | S, XPC?; history controls | Destructive user-approved history operation | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightGetSettingsRequest` | empty | `SkysightSettings {observation}` with defaults/allowlist/blocklist | S, XPC? | Read-only | Safe unsupported; catalog test | Named response metadata; binding `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightUpdateSettingsRequest` | `settings` | likely `SkysightSettings` or empty | S, XPC? | User settings mutation | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` exact result | OUT_OF_SCOPE |
| `ComputerUseIPCSkysightUpdateObservationPolicyRequest` | `target,observe` | likely `SkysightSettings` or empty | S, XPC? | User observation allow/block mutation | Safe unsupported; catalog test | `NEEDS_ARM_ORACLE` exact result | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesPrepareSendRequest` | `chatGUID,recipients,text,attachments` | `MessagesPreparedSend {planID,chatGUID,displayName,text,attachments}` | S, XPC?; Messages coordinator/MCP | Messages permission; prepares but does not send | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE`; runtime binding needs oracle | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesCommitSendRequest` | `planID,text` | `MessagesSendResult {destinationKind,chatGUID,displayName,participants,service,text,attachments,sentAt}` | S, XPC?; Messages coordinator/MCP | Explicit commit; rate limit and uncertain-outcome errors | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE`; runtime binding needs oracle | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesFindChatsRequest` | `participants,exactParticipants,name,fromDate,toDate,unreadOnly,limit` | `MessagesChatsPage {chats,participants,hasMore}` | S, XPC?; Messages MCP | Messages permission; query timeout | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesSearchChatsRequest` | `query,limit` | `MessagesChatSearchPage {chats,hasMore}` | S, XPC?; Messages MCP | Messages permission; query timeout | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesReadMessagesRequest` | `chatGUID,fromDate,toDate,unreadOnly,limit,cursor` | `MessagesMessagesPage {chats,senders,messages,nextCursor}` | S, XPC?; Messages MCP | Messages permission; query timeout | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesSearchMessagesRequest` | `text,chatGUIDs,participants,exactParticipants,fromDate,toDate,limit,cursor` | `MessagesMessagesPage {chats,senders,messages,nextCursor}` | S, XPC?; Messages MCP | Messages permission; query timeout | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesCountActivityRequest` | `fromDate,toDate,interval,chatType,chatGUIDs,breakdown,rankBy,chatLimit,cursor` | `MessagesActivityResult {breakdown,range,interval,timeZoneIdentifier,buckets,matchingChatCount,overallActivity,chats,participants,nextCursor}` | S, XPC?; Messages MCP | Messages permission; aggregate query | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE` | OUT_OF_SCOPE |
| `ComputerUseIPCMessagesReadImageRequest` | `id` | `MessagesImage {data,mimeType,chatGUID,chatDisplayName}` | S, XPC?; Messages MCP | Messages permission; attachment read | Safe unsupported; catalog test | Named types `HIGH_CONFIDENCE` | OUT_OF_SCOPE |

## Asynchronous records and notifications

| Type | Fields / cases | Transport and lifecycle | Intel status | Evidence |
| --- | --- | --- | --- | --- |
| `ComputerUseIPCCaptureUpdate` | `type,app,text?,screenshot?,transitionSnapshotURL?,failureReason?`; failure `blockedByPolicy\|screenshotCaptureFailed\|unknownCaptureFailed` | Pulled by `AppNextCaptureUpdate`; terminal on completed/failed/cancel/turn/lock/disconnect | Implemented, bounded/coalescing long-poll stream | ARM metadata + Intel tests/runtime |
| `ComputerUseIPCCodexStatusItemStateNotification` | no stored fields; payload delivery schema not recovered | ARM notification publisher; exact socket/XPC subscription is `NEEDS_ARM_ORACLE` | Menu state is queryable; push subscription is `PARTIAL` | ARM metadata/static symbols |
| Distributed managed-service state change | `processIdentifier,computerUseActive,computerHistoryState` | `com.openai.codex.computer-use.status-item-state-changed`; ChatGPT accepts its cached managed PID and refreshes managed-service state | Session registry publishes only inactive→active and active→inactive edges; the authenticated socketless exit watchdog also publishes `false/stopped` after unexpected exit | Intel `sky.node` strings/metadata + production ASAR + notification/session tests + Intel automatic-restart runtime |
| Event Stream JSONL | kinds `session.started`, `session.ended`, `window.changed`, `mouse.click`, `mouse.context_menu`, `mouse.drag`, `keyboard.text_input`, `keyboard.submit`, `keyboard.shortcut`, `terminal.value_changed`, `selection.changed`, `debug.error` | Owner-only files; terminal on explicit stop, turn, disconnect, lock, duration or service exit | Implemented | ARM strings/metadata + Intel tests |

## Remote Hosted PIP XPC protocol

PIP is not a JSON-RPC request type. Intel receives an authenticated `SkCu/PiPB` bootstrap Apple
Event carrying bridge version, sender PID, and Mach reply port, then transfers an anonymous XPC
endpoint. The Intel ChatGPT `sky.node` host is accepted only when it is x86_64, signed by Team ID
`2DC432GLL2`, and exposes all selectors below. Replies are `NSError?` blocks.

| Direction | Selector | Fields / operation | Intel status |
| --- | --- | --- | --- |
| Producer → host | `publishPresentationWithID:threadID:turnID:contextID:width:height:withReply:` | presentation/turn identity, CAContext ID, logical size | Implemented |
| Producer → host | `setSourceProcessIdentifier:forPresentationWithID:withReply:` | target PID and presentation | Implemented |
| Producer → host | `prepareOperationWithPresentationID:operationID:kind:contextID:width:height:fencePayload:withReply:` | resize or context replacement plus XPC Mach-send fence | Implemented |
| Producer → host | `completeOperationWithPresentationID:operationID:withReply:` | operation commit | Implemented |
| Producer → host | `willEndStreamWithPresentationID:withReply:` | graceful end handshake | Implemented |
| Producer → host | `invalidatePresentationWithID:withReply:` | final invalidation | Implemented |
| Producer → host | `noteInteractionWithPresentationID:withReply:` | user interaction notification | Implemented |
| Producer → host | `setComputerUseCursorLocationWithX:y:isActive:withReply:` | global virtual cursor position/active state | Implemented; pressed style is producer-layer state |
| Host → producer | `connectWithReply:` | host connection readiness | Implemented |
| Host → producer | `setMaxDisplaySize:withReply:` | maximum logical display dimension | Implemented |
| Host → producer | `performActionWithPresentationID:kind:withReply:` | currently confirmed `focus-presentation` | Implemented |
| Host → producer | `didEndStreamWithPresentationID:withReply:` | host completed graceful end | Implemented |

The ABI encodings and XPC fence-class configuration are asserted by
`RemoteHostedPIPProtocolsTests`, `RemoteHostedPIPConnectionTests`, and
`Scripts/audit-pip-host.sh`. Continuous first-frame, resize, cursor, window/PID replacement and
stale-presentation visual acceptance still require the attended matrix in `OfficialBehaviorNotes.md`.

## Safety invariants

- Every implemented socket request has a routing/schema/error test; high-risk operations also have
  snapshot, policy, intervention, lock, targeting, cancellation, stream, or presentation tests as
  appropriate.
- All 19 `OUT_OF_SCOPE` names are executable test data and must return before any provider runs,
  permission prompt appears, or side effect occurs.
- Missing CAContext, fence, PIP host, or private SPI state degrades only the optional presentation;
  it cannot change the underlying Computer Use request result.
- No implementation path modifies or resigns `/Applications/ChatGPT.app`, claims Team ID
  `2DC432GLL2`, moves the physical pointer, globally broadcasts target input, accesses Messages,
  records audio, or starts Skysight.

## Error directory

The confirmed service codes are `senderProcessNotAuthenticated -10000`, `couldNotGetRequestData
-10001`, `couldNotGetRequestTypeName -10002`, `couldNotResolveRequestType -10003`, `unhandledEvent
-10004`, `unknownError -10005`, `appNotAllowed -10006`, `runningApplicationNotFound -10007`,
`accessibilityError -10008`, `permissionsNotGranted -10009`, `invalidApp -10010`,
`noActiveSession -10011`, `userStoppedSession -10012`, `incompatibleClientVersion -10013`,
`permissionsPending -10014`, `blockedURL -10015`, `userIntervened -10016`,
`couldNotGetSenderPID -10017`, `ambiguousApp -10018`, `couldNotGetBootstrapPort -10019`, and
`screenLocked -10020`. ARM metadata additionally contains post-baseline Messages/turn-ended cases;
they remain catalogued but are not emitted by the Intel IPC-5 implementation. JSON-RPC parse,
invalid-request and unknown-method errors retain standard `-32700`, `-32600`, and `-32601` codes.

## Catalog verification

Run:

```sh
node --test Tools/reverse/protocol-catalog.test.mjs
ARM_SKY_BINARY=/path/to/SkyComputerUseService \
  node --test Tools/reverse/protocol-catalog.test.mjs
```

The first command proves that the 34 document rows exactly partition the Swift implemented and
OUT_OF_SCOPE sets, match router dispatch, and mark the five Intel Apple Event request types. When
an ARM binary is supplied (or the standard mounted reference exists), the same test extracts its
field metadata and proves that no ARM request is absent or invented.
