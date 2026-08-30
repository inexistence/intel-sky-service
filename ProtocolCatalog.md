# Intel Computer Use runtime protocol catalog

This catalog is the request-by-request inventory for `CodexComputerUseIPC-5`. It is intentionally
separate from the behavioral narrative in `OfficialBehaviorNotes.md`: this file answers what is on
the wire and whether Intel implements it; the notes explain why each compatibility choice was made.

Catalog baseline: Intel ChatGPT `26.825.41651`, `@oai/sky`
`0.6.24-premerge-pr-1369830-395ab116910c`, and ARM service
`com.openai.sky.CUAService` build `26.828.1000919`, inspected 2026-08-30.

## Common wire contract

| Property | Contract and evidence |
| --- | --- |
| Socket transport | Owner-only Unix socket, 4-byte little-endian frame length, 8 MiB maximum, JSON-RPC 2.0. `CONFIRMED_CLIENT_SOURCE`, `CONFIRMED_INTEL_RUNTIME`. |
| Socket request envelope | `method: "request"`, params `{ clientApiVersion, requestType, request, codexTurnMetadata?, deadlineUnixMilliseconds }`. `ping` uses `{ clientApiVersion }`. `CONFIRMED_CLIENT_SOURCE`. |
| Socket response envelope | `{ jsonrpc: "2.0", id, result }` or `{ jsonrpc: "2.0", id, error: { code, message } }`. `CONFIRMED_CLIENT_SOURCE`. |
| Deadline | Public client default 120 s; every socket request carries an absolute millisecond deadline. Intel checks before dispatch and at cooperative long-running checkpoints. `CONFIRMED_CLIENT_SOURCE`, `HIGH_CONFIDENCE`. |
| Socket authorization | Direct peer plus parent/responsible/ancestor code identities; production accepts only the real signed ChatGPT → Codex → node_repl chain. Intel additionally validates socket directory, socket owner/mode, and peer UID. `CONFIRMED_STATIC_BINARY`, `CONFIRMED_INTEL_RUNTIME`. |
| App approval | The public wrapper calls `ComputerUseIPCAppPolicyRequest` and the Codex host approval UI before target operations. Intel never bypasses this caller-side approval and independently rejects forbidden targets. `CONFIRMED_CLIENT_SOURCE`. |
| Native Apple Event | `SkCu/SndR`, `RspT` request type, `ReqD` JSON data, `ClVn = CodexComputerUseNativeBridge-1`; response is JSON in direct-object `tdta`, errors in `errn/errs`. Sender PID must pass the signed ChatGPT host requirement. `CONFIRMED_CLIENT_SOURCE`, `CONFIRMED_INTEL_RUNTIME` for parsing/routing tests. |
| Remote Hosted PIP bootstrap | `SkCu/PiPB`, version, sender PID, Mach reply port; reply-port XPC dictionary contains `endpoint: xpc_endpoint_t`. Signed ChatGPT is checked at Apple Event and XPC admission. `CONFIRMED_INTEL_STATIC_BINARY`, `CONFIRMED_INTEL_RUNTIME` for real endpoint/XPC tests. |
| Special entitlement | No OpenAI entitlement is claimed or copied. Accessibility, Screen Recording, Input Monitoring, Secure Input, and App approval are ordinary OS/user policy boundaries. The PIP CAContext path uses dynamically checked private SPI but the cross-signature smoke disproves a Team-ID-only rendering restriction. `CONFIRMED_INTEL_RUNTIME`. |

The installed JavaScript maps server codes `-10000...-10020` to: unauthenticated sender, bad data,
missing/unknown request type, unhandled/unknown error, App forbidden/not running, Accessibility,
permissions, invalid/ambiguous App, no active session, user stop, incompatible version, permissions
pending, blocked URL, user intervention, missing sender/bootstrap port, and screen locked. ARM metadata
also contains newer turn-ended and Messages-specific cases; the installed Intel JS does not expose
numeric mappings for those, so they remain `NEEDS_ARM_ORACLE`. Intel safely uses `-10003`
(`couldNotResolveRequestType`) for every catalogued out-of-scope request.

## Visual/runtime requests implemented on Intel

“Socket” below means the common authenticated JSON-RPC transport and common envelope above. Tests
are relative to `Tests/IntelSkyCoreTests`.

| Request type | Request fields | Response | Transport / observed caller | Lifecycle, approval, entitlement | Intel state and tests | Remaining difference / evidence |
| --- | --- | --- | --- | --- | --- | --- |
| `ComputerUseIPCListAppsRequest` | empty | `[ComputerUseIPCDiscoveredApp]`: `displayName, bundleIdentifier, appPath, lastUsedDate, useCount, isRunning, isFrontmost` | Socket; public `MacComputerUseClient.listApps` | No target approval; deadline only | Implemented; `WorkspaceAppCatalogTests`, `SkyProtocolTests` | Exact ARM filtering/dedup remains `NEEDS_ARM_ORACLE`; schema `CONFIRMED_CLIENT_SOURCE` / `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCAppPolicyRequest` | `app` | `ComputerUseIPCAppPolicyResult { decision, target, allowPersistentApproval }` | Socket; public wrapper before App operations | No mutation; local forbidden-target policy; organization approval remains caller-owned | Implemented; `MacAppPolicyTests`, `SkyProtocolTests` | Dynamic organization allow/deny ingestion is `KNOWN_DIFFERENCE`; schema `CONFIRMED_CLIENT_SOURCE`. |
| `ComputerUseIPCAppStartRequest` | `app` | `ComputerUseIPCSkyshotResult { app, skyshot?, appSpecificInstructions? }` | Socket; public low-level client | App approval, policy, Accessibility/Screen Recording; starts a fresh full snapshot | Implemented; `SkyProtocolTests`, `MacAppStateProviderTests` coverage is in state/action suites | Already-running timing is `NEEDS_ARM_ORACLE`; fields `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCAppGetSkyshotRequest` | `app, disableDiff?` | `ComputerUseIPCSkyshotResult`; Skyshot is `text, screenshot? { url, mimeType }` | Socket and native Apple Event; public `get_app_state` and Appshot | App approval; policy; user-stop/intervention/requery; lock; turn-scoped session | Implemented; `SkyProtocolTests`, `ElementSnapshotCacheTests`, AX/diff/screenshot tests | Exact AX text/transient-window serialization is `PARTIAL` / `NEEDS_ARM_ORACLE`; public schema `CONFIRMED_CLIENT_SOURCE`. |
| `ComputerUseIPCAppPerformActionRequest` | `app, action`; action cases `click, performSecondaryAction, setValue, selectText, scroll, drag, pressKey, type, paste` | empty | Socket; all 11 public window APIs | App approval/policy; current snapshot; target-scoped input; deadline/cancel; Secure Input/lock/intervention | Implemented; `MacAppActionPerformerTests`, keyboard/scroll/AX/paste/policy tests | Exact role fallbacks, timing, text markers, and layout semantics are `PARTIAL`; cases `CONFIRMED_CLIENT_SOURCE` / `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCAppStopRequest` | `app` | empty | Socket and native Apple Event; ChatGPT status item | Human stop latches App for current turn; cancels work/capture/PIP | Implemented; `ComputerUseSessionCoordinatorTests`, native bridge/PIP tests | Real status-item click remains `NEEDS_ARM_ORACLE`; caller `CONFIRMED_CLIENT_SOURCE`. |
| `ComputerUseIPCAppModifyRequest` | `app, modification: activate \| deactivate` | `ComputerUseIPCAppState { active, currentApp? }` | Socket; no installed Intel caller located | Policy; session activation/deactivation; deactivation ends App presentation without macOS focus theft | Implemented; `SkyProtocolTests`, session tests | Exact idempotence/launch timing `NEEDS_ARM_ORACLE`; schema/handler `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCFrontmostWindowRequest` | empty | optional `ComputerUseIPCFrontmostWindow { bundleIdentifier, name, windowTitle? }` | Socket; no installed Intel caller located | Read-only; Accessibility title is optional; deadline | Implemented; `SkyProtocolTests` | Exact filtering/title selection `NEEDS_ARM_ORACLE`; schema `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCCodexStatusItemMenuStateRequest` | empty | `ComputerUseIPCCodexStatusItemMenuState { computerUse, computerHistory }` | Socket and native Apple Event; ChatGPT status item | Read-only current App/History state | Implemented; `ComputerUseSessionCoordinatorTests`, native bridge tests | Computer History intentionally reports stopped/unavailable; Skysight history is `OUT_OF_SCOPE`. Caller `CONFIRMED_CLIENT_SOURCE`. |
| `ComputerUseIPCCodexTurnEndedRequest` | `threadID, turnID` | empty | Socket; host lifecycle caller | Ends matching capture/event/PIP/cursor/session/focus; ordered cleanup before safe focus restore | Implemented; `ComputerUseTurnLifecycleTests`, focus/capture/event/PIP tests | Dynamic host caller identity/timing `NEEDS_ARM_ORACLE`; fields `CONFIRMED_CLIENT_SOURCE` / `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCAppStartCaptureRequest` | `app, requestID, permissionRequestID, animationTarget, version` | `ComputerUseIPCAppStartCaptureResponse { result, animationDuration?, transitionSnapshotHeight?, transitionSpringResponse?, transitionSpringDampingFraction?, permissionGrantState? }` | Socket and native Apple Event; Intel ChatGPT Appshot worker | Per-client ownership; unique ID; policy/approval/TCC; lifecycle generation; async producer | Implemented as true async stream; `AppCaptureSessionTests`, native bridge tests | Polling instead of recovered official change notification/reliable-final-frame mechanism is `PARTIAL`; fields `CONFIRMED_STATIC_BINARY`, caller `CONFIRMED_CLIENT_SOURCE`. |
| `ComputerUseIPCAppNextCaptureUpdateRequest` | `requestID` | `ComputerUseIPCCaptureUpdate { type, app, text?, screenshot?, transitionSnapshotURL?, failureReason? }` | Socket and native Apple Event; Appshot worker | Owner-only long poll; deadline; bounded/coalescing queue; disconnect/turn/stop/lock/shutdown cleanup | Implemented; `AppCaptureSessionTests`, `SkyProtocolTests` | Official disconnect terminal visibility and exact notification cadence `NEEDS_ARM_ORACLE`; union `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCEventStreamStartRequest` | empty | `ComputerUseIPCEventStreamSessionStatus` (10 fields) | Socket; Record & Replay controls | Explicit recording; Input Monitoring required; owner/thread scoped; 30-minute max | Implemented; `EventStreamSessionTests`, `SkyProtocolTests` | Exact official debounce, URL policy, and buffers `PARTIAL`; schema/lifecycle `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCEventStreamStatusRequest` | empty | same 10-field status | Socket; Record & Replay controls | Read-only latest/active session status | Implemented; Event Stream tests | Caller runtime remains `NEEDS_ARM_ORACLE`; fields `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCEventStreamStopRequest` | `reason` | same 10-field status | Socket; Record & Replay controls | Valid reason; drains records and atomically closes owner-only files | Implemented; Event Stream tests | Exact controls reason selection `NEEDS_ARM_ORACLE`; reason enum `CONFIRMED_STATIC_BINARY`. |

Capture update types are exactly `metadata, axText, screenshot, completed, failed`; failure reasons
are `blockedByPolicy, screenshotCaptureFailed, unknownCaptureFailed`. Event Stream end reasons are
`toolStopped, debugUIStopped, recordingControlsStopped, recordingControlsCancelled, maxDuration,
serviceTerminated`. These are `CONFIRMED_STATIC_BINARY`.

## Catalogued requests intentionally out of scope

These types are present in ARM field metadata and are not inferred from names alone: their fields
below come from the emitted Swift field records. Intel explicitly keeps the exact 19 names in
`SkyProtocol.outOfScopeRequestTypes`; socket tests send every one and require immediate `-10003`
without invoking an App/state/action provider. They do not block the visual-runtime goal.

| Request type | Request fields | Static response type / caller evidence | Transport, approval, entitlement | Intel state and test | Evidence / remaining work |
| --- | --- | --- | --- | --- | --- |
| `ComputerUseIPCStartAudioRecordingRequest` | `maxDurationMilliseconds` | empty; public JS validates 100...300000 ms and asks host audio approval | Socket; microphone/TCC and explicit audio approval | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_CLIENT_SOURCE`, `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCStopAudioRecordingRequest` | empty | `ComputerUseIPCAudio { url? }`; public JS requires local WAV URL | Socket; same audio approval domain | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_CLIENT_SOURCE`, `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightStartRequest` | empty | `ComputerUseIPCSkysightStatus` | Socket/XPC service dispatch; Skysight UI | Observation policy and history consent; exact entitlement `NEEDS_ARM_ORACLE` | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightStatusRequest` | empty | `ComputerUseIPCSkysightStatus` | same | read-only | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightStopRequest` | empty | `ComputerUseIPCSkysightStatus` | same | ends observation/history streams | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightPauseRequest` | `duration: thirtyMinutes \| oneHour \| untilTomorrow` | `ComputerUseIPCSkysightStatus` | same | observation lifecycle | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightResumeRequest` | empty | `ComputerUseIPCSkysightStatus` | same | observation lifecycle | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightClearHistoryRequest` | `scope, interval` | empty/status not uniquely recovered | same | destructive history operation would require explicit user intent | `OUT_OF_SCOPE`; safe unsupported test | Response is `NEEDS_ARM_ORACLE`; fields `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightGetSettingsRequest` | empty | `ComputerUseIPCSkysightSettings` | same | read-only settings | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightUpdateSettingsRequest` | `settings` | `ComputerUseIPCSkysightSettings`/empty not uniquely recovered | same | mutates observation settings | `OUT_OF_SCOPE`; safe unsupported test | Response `NEEDS_ARM_ORACLE`; fields `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCSkysightUpdateObservationPolicyRequest` | `target, observe` | status/empty not uniquely recovered | same | mutates target observation policy | `OUT_OF_SCOPE`; safe unsupported test | Response `NEEDS_ARM_ORACLE`; fields `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesPrepareSendRequest` | `chatGUID, recipients, text, attachments` | `ComputerUseIPCMessagesPreparedSend { planID, chatGUID, displayName, text, attachments }` | Socket/XPC service dispatch; Messages MCP approval path | Messages permission plus explicit send-plan approval; entitlement/database requirements `NEEDS_ARM_ORACLE` | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesCommitSendRequest` | `planID, text` | `ComputerUseIPCMessagesSendResult` | same | consumes approved plan; send side effect | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesFindChatsRequest` | `participants, exactParticipants, name, fromDate, toDate, unreadOnly, limit` | `ComputerUseIPCMessagesChatsPage` | same | Messages read permission | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesSearchChatsRequest` | `query, limit` | `ComputerUseIPCMessagesChatSearchPage` | same | Messages read permission | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesReadMessagesRequest` | `chatGUID, fromDate, toDate, unreadOnly, limit, cursor` | `ComputerUseIPCMessagesMessagesPage` | same | Messages read permission | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesSearchMessagesRequest` | `text, chatGUIDs, participants, exactParticipants, fromDate, toDate, limit, cursor` | `ComputerUseIPCMessagesMessagesPage` | same | Messages read permission | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesCountActivityRequest` | `fromDate, toDate, interval, chatType, chatGUIDs, breakdown, rankBy, chatLimit, cursor` | `ComputerUseIPCMessagesActivityResult` | same | Messages read permission | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`. |
| `ComputerUseIPCMessagesReadImageRequest` | `id` | `ComputerUseIPCMessagesImage { data, mimeType, chatGUID, chatDisplayName }` | same | Messages attachment permission; bounded data policy not recovered | `OUT_OF_SCOPE`; safe unsupported test | `CONFIRMED_STATIC_BINARY`; bounds `NEEDS_ARM_ORACLE`. |

## Non-request lifecycle and presentation protocols

| Surface | Wire members | Authorization / lifecycle | Intel state | Evidence / difference |
| --- | --- | --- | --- | --- |
| Capture update union | types and failures listed above; owner uses `requestID` | Start/Next ownership, backpressure, deadline, disconnect, App stop/deactivate, turn, lock, intervention, shutdown | Implemented | `PARTIAL` polling producer. |
| Status notification | `ComputerUseIPCCodexStatusItemStateNotification` | ChatGPT status item; observer lifecycle | Status is query-compatible; unsolicited notification transport is not implemented | `PARTIAL`, `NEEDS_ARM_ORACLE`. |
| Intel Remote Hosted PIP host XPC | `publishPresentation`, `setSourceProcessIdentifier`, `prepareOperation`, `completeOperation`, `willEndStream`, `invalidatePresentation`, `noteInteraction`, `setComputerUseCursorLocation` | Bidirectional anonymous XPC endpoint; signed ChatGPT only; presentation keyed by thread/turn/App | Implemented, including fenced `resize` and `replace-context` | Selector ABI `CONFIRMED_INTEL_STATIC_BINARY`; managed live-frame verification pending. |
| Intel PIP producer XPC | `connect`, `setMaxDisplaySize`, `performAction`, `didEndStream` | Host connection/reconnection; action is `focus-presentation` | Implemented; reconnect republishes live contexts | `HIGH_CONFIDENCE`; full host restart smoke pending. |
| ChatGPT Appshot worker events | `computer-use-start-capture`, asynchronous `computer-use-capture-updated` | Renderer/worker bridge; permission request and turn-scoped task | Native Apple Event Start/Next path implemented | Caller `CONFIRMED_CLIENT_SOURCE`; attended run pending. |
| Lock Screen Guardian | ARM XPC client/helper callbacks include physical input and connection loss | Independent helper, unlock task, fail-closed connection semantics | Intel uses direct session/console checks and Event Tap; no helper App | Necessity is `NEEDS_ARM_ORACLE`; helper is not required by current proven Intel behavior. |

## Coverage invariants

- Every implemented socket request has a routing/schema/error test; high-risk actions additionally
  have snapshot, policy, intervention, lock, targeting, and cancellation tests.
- All 19 `OUT_OF_SCOPE` request names are executable test data and must remain safe unsupported.
- Private PIP SPI is dynamically checked. Missing CAContext/fence/host state degrades the optional
  presentation and never changes the underlying Computer Use request result.
- No code path modifies or resigns `/Applications/ChatGPT.app`, claims Team `2DC432GLL2`, moves the
  physical pointer, globally broadcasts target input, accesses Messages, records audio, or starts
  Skysight.
