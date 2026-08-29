# Official Computer Use behavior notes

This document is the compatibility ledger for the clean-room Intel implementation. The
observable behavior of the unmodified `@oai/sky` client and Apple Silicon service is the
specification. Every nontrivial compatibility choice should cite evidence and remain easy to
replace when stronger evidence appears.

## Evidence labels

- `CONFIRMED_CLIENT_SOURCE`: directly encoded by the bundled `@oai/sky` JavaScript or types.
- `CONFIRMED_STATIC_BINARY`: present in the official ARM64 service's symbols, strings, metadata,
  linked frameworks, or disassembly.
- `CONFIRMED_INTEL_RUNTIME`: exercised through the unmodified client against this service.
- `HIGH_CONFIDENCE`: multiple indirect sources agree, but the official behavior was not run.
- `LOW_CONFIDENCE`: provisional implementation chosen for safety and replaceability.
- `NEEDS_ARM_ORACLE`: a prepared differential case still needs an Apple Silicon run.
- `KNOWN_DIFFERENCE`: current Intel behavior is observably or provably different.

## Package baseline

- Client package: `@oai/sky` `0.6.24-premerge-pr-1369830-395ab116910c`.
- Protocol: `CodexComputerUseIPC-5`.
- The x86_64 and ARM64 bundles inspected on 2026-08-30 contain byte-identical macOS
  `client.js` files.
- ARM service bundle: `com.openai.sky.CUAService`, build `26.828.1000919`, arm64.

## Public Window API matrix

| API | Wire action/request | Evidence | Intel state | Remaining work |
| --- | --- | --- | --- | --- |
| `list_apps` | `ComputerUseIPCListAppsRequest` | `CONFIRMED_CLIENT_SOURCE` | implemented | exact ARM filtering/dedup oracle |
| `get_app_state` | `ComputerUseIPCAppGetSkyshotRequest` | `CONFIRMED_CLIENT_SOURCE` | partial | loading settle and exact AX rendering |
| `click` | `click` | `CONFIRMED_CLIENT_SOURCE` | partial | AX/CG fallback and menu semantics |
| `drag` | `drag` | `CONFIRMED_CLIENT_SOURCE` | partial | calibrate timing/path and official cursor animation |
| `paste` | `paste` | `CONFIRMED_CLIENT_SOURCE` | partial | ARM format/error oracle and clipboard edge cases |
| `perform_secondary_action` | `performSecondaryAction` | `CONFIRMED_CLIENT_SOURCE` | partial | exact action validation and errors |
| `press_key` | `pressKey` | `CONFIRMED_CLIENT_SOURCE` | partial | full keysym/layout/secure-input behavior |
| `scroll` | `scroll` | `CONFIRMED_CLIENT_SOURCE` | partial | AX page actions and CG fallback |
| `select_text` | `selectText` | `CONFIRMED_CLIENT_SOURCE` | partial | text-marker fallback |
| `set_value` | `setValue` | `CONFIRMED_CLIENT_SOURCE` | partial | fallback and exact errors |
| `type_text` | `type` | `CONFIRMED_CLIENT_SOURCE` | partial | strategy selection and newline semantics |

## Confirmed wire behavior

- The socket defaults to
  `~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock`.
- Frames use a four-byte little-endian length prefix and an 8 MiB maximum.
- The client pings with API version 5, initially waits 250 ms, asks the Codex host to
  `ensureService("computer-use")` or uses LaunchServices, then retries for five seconds.
- Requests include `deadlineUnixMilliseconds`, `requestType`, request payload, and optional Codex
  turn metadata. The default client timeout is 120 seconds.
- The public wrapper performs `ComputerUseIPCAppPolicyRequest` before every app operation and asks
  the Codex host for app approval.
- Official server error codes are `-10000...-10020`; notable cases include unauthenticated sender,
  permissions, no active session, user stop/intervention, blocked URL, incompatible version,
  ambiguous app, and locked screen.

Evidence: `CONFIRMED_CLIENT_SOURCE`.

## App catalog

- ARM embeds the Spotlight predicate `kMDItemContentType == "com.apple.application-bundle" &&
  kMDItemFSName == "*.app" && kMDItemLastUsedDate_Ranking >= $time.today(-14)` and reads
  `kMDItemLastUsedDate` and `kMDItemUseCount`. `CONFIRMED_STATIC_BINARY`.
- Intel runs that predicate, reads the matching metadata, caches it for five minutes, and merges it
  with current `NSWorkspace` applications by bundle ID. The unmodified client receives
  `lastUsedDate` and `useCount` through its documented mapping. The installed service returned 71
  entries in a real smoke, including non-running recent apps and ChatGPT `useCount: 106`.
  `CONFIRMED_INTEL_RUNTIME`.

## Coordinates and screenshots

- `click` and `scroll` coordinates and both `drag` endpoints are documented as coordinates in the
  app-window screenshot, not global screen coordinates. `CONFIRMED_CLIENT_SOURCE`.
- ARM strings include `pointPixelScale`, `nativeDisplayPixels`, `scaledScreenSize`, and cursor
  layer geometry. Retina-aware conversion is therefore part of the official subsystem.
  `CONFIRMED_STATIC_BINARY`.
- Intel now stores the selected window's global frame and the generated PNG's pixel dimensions,
  then scales screenshot-local coordinates into global points. Missing screenshots and out-of-bounds
  coordinates fail closed. `CONFIRMED_INTEL_RUNTIME` for unit coverage; real multi-display smoke
  coverage remains `NEEDS_ARM_ORACLE` and pending Intel desktop automation.

## Scroll

- The client accepts every finite `pages > 0`; fractional values are explicitly supported.
  `CONFIRMED_CLIENT_SOURCE`.
- ARM strings contain `AXScrollLeftByPage`, `AXScrollRightByPage`, `AXScrollUpByPage`, and
  `AXScrollDownByPage`, plus `UIElementScrollOperation`. This strongly suggests an AX page-action
  path, probably with fallback. `CONFIRMED_STATIC_BINARY` for API use; dispatch rules remain
  `NEEDS_ARM_ORACLE`.
- Intel's former maximum of ten pages was a `KNOWN_DIFFERENCE` and has been removed. Its current
  element path now walks AX parents and performs whole-page AX actions first, then uses bounded
  pixel-wheel events for unsupported pages and fractional remainders. Coordinate scroll remains a
  pixel-wheel operation. The exact official dispatch thresholds remain `NEEDS_ARM_ORACLE`.

## Click dispatch

- ARM contains `feature/computerUseAlwaysSimulateClick`, described as preferring simulated physical
  clicks over Accessibility actions. This establishes an AX-action default path plus an optional
  physical-click override. `CONFIRMED_STATIC_BINARY`.
- ARM also contains `Mouse action not supported for menu items` and `Failed to click menu item`,
  indicating special AX-only menu-item handling. `CONFIRMED_STATIC_BINARY`.
- Intel now tries `AXPress` for a single left element click and falls back to a centered CGEvent
  click. Menu items without `AXPress` fail closed. Coordinate, multi-click, right-click, and middle
  click remain physical. Exact role exceptions remain `NEEDS_ARM_ORACLE`.

## Focus, cursor, and user intervention

The ARM service contains the following relevant types and state:

- `SyntheticAppFocusEnforcer`, `SystemFocusStealPreventer`, `FocusRestoreTarget`
- `ComputerUseCursor`, `VirtualCursor`, `SoftwareCursorStyle`
- `SystemFrontmostApplicationTracker`
- `SystemLockScreenPhysicalInputMonitor`, `UserInterruptedIntervention`
- mouse/keyboard event taps, secure-input PID checks, cursor windows, and focus restoration

This proves that focus arbitration, physical-input monitoring, software cursor feedback, and user
interruption are deliberate runtime subsystems rather than presentation-only details.
`CONFIRMED_STATIC_BINARY`.

Targeted ARM symbol and disassembly analysis adds the following details:

- `SyntheticAppFocusEnforcer` tracks `applicationBelievesItIsActive`,
  `applicationBelievesItHasFocus`, and `applicationIsActive`; its
  `enforceActiveState(for:)` path constructs a private AppKit process-notification event using
  `NSEventType.processNotification` and `kCPSNotifyKeyFocusReturned`.
- `SystemFocusStealPreventer` exposes process-scoped start/stop calls plus target-lost/target-gained
  callbacks and menu-dismissal suppression.
- `RemoteHostedPIPContentStream` stores `threadID`, `turnID`, `focusRestoreTarget`, associated window
  IDs, and a stream-end timeout; its lifecycle exposes `willEndStream`, `noteInteraction`, and
  `invalidate`.

Together these show that official focus restoration is stream/turn-scoped and that the target can
be made to believe it is focused without ordinary foreground activation. `CONFIRMED_STATIC_BINARY`.

The official Mac JS transport includes `codexTurnMetadata` on each IPC request. Live node_repl
metadata contains `session_id`, `thread_id`, and `turn_id`; the ARM binary also exposes
`ComputerUseIPCCodexTurnEndedRequest(threadID:turnID:)`. `CONFIRMED_CLIENT_SOURCE` and
`CONFIRMED_INTEL_RUNTIME` for the observed metadata envelope.

Intel now attempts background AX-only operations before activating the target: single-left
element click uses `AXPress`; complete AX page scroll, `setValue`, secondary AX actions, and text
selection do not foreground the app. Activation is deferred until a CGEvent/keyboard fallback is
actually required. In a real smoke, Finder remained frontmost while an AXPress changed Calculator
from `112222222` to `1122222222`. `CONFIRMED_INTEL_RUNTIME`.

Intel now tracks scoped turns, handles explicit turn-ended requests, and treats an observed turn-ID
change as an implicit boundary. Before the first operation that truly foregrounds a target, it
captures the user's frontmost app and focused AX window. It restores only at the turn boundary and
only if the current frontmost process is one controlled during that turn; restoration is suppressed
after physical input or an independent user focus change. The state machine, routing, and safety
conditions have regression coverage. A host-style dynamic turn-ended smoke is still
`NEEDS_ARM_ORACLE`: node_repl's seatbelt correctly denied a direct JavaScript socket connection,
and the public high-level `sky` surface does not expose the lifecycle request.

The socket server now accepts up to eight clients concurrently while serializing Computer Use
request execution. This prevents a persistent node_repl transport from blocking a separate trusted
lifecycle connection without allowing overlapping desktop actions. The identity of the Intel
turn-ended caller is not yet dynamically confirmed, so the peer allowlist has not been broadened.
`HIGH_CONFIDENCE` for server concurrency; caller integration remains `NEEDS_ARM_ORACLE`.

Intel now renders an independently drawn, non-activating software cursor for click, drag, and
scroll operations. It is an input-transparent status-level panel that joins all Spaces, does not
move the physical pointer, animates between positions, shows pressed feedback, and hides after an
idle interval. A real Calculator click changed the target value while AppKit recorded the same
overlay window being ordered in and out five seconds later. The earlier cross-process
`CGWindowList` probe was a false negative because that diagnostic process lacked Screen Recording
access. `CONFIRMED_INTEL_RUNTIME`.

The official cursor's exact artwork, path/spring constants, PIP/container integration, visibility
state machine, menu handling, and turn-scoped lifetime remain `NEEDS_ARM_ORACLE`. Intel still lacks
the private process-notification-based synthetic-focus illusion and the PIP-host integration, so
those portions remain `KNOWN_DIFFERENCE`.

## Native host capture and PIP boundary

The eleven public `@oai/sky` actions are not the whole native-host surface. ARM protocol metadata
also declares `ComputerUseIPCAppStartCaptureRequest`, `ComputerUseIPCAppNextCaptureUpdateRequest`,
capture update/result types, and event-stream start/status/stop requests. The official service owns
a `CUAServiceRemoteHostedPIPController`; the shared ComputerUse framework publishes
`RemoteHostedPIPContentStream` instances through a private remote-hosted-PIP XPC protocol and
renders separate window and cursor capture streams. `CONFIRMED_STATIC_BINARY`.

Intel ChatGPT's main-process bundle independently contains a `computer-use-start-capture` bridge.
It sends a worker `start` request with an animation target, bundle identifier, permission request
ID, and request ID, then forwards asynchronous `computer-use-capture-updated` events to the
renderer. Its remote-hosted-PIP task manager associates presentations with task/thread visibility
and completes them at turn boundaries. `CONFIRMED_INTEL_CLIENT_SOURCE`.

The exact Intel Appshot transport is now confirmed. ChatGPT sends synchronous Apple Events with
class/ID `SkCu`/`SndR`, parameters `RspT` (request type), `ReqD` (UTF-8 JSON data), and `ClVn`
(`CodexComputerUseNativeBridge-1`) directly to the managed service PID. The current start request
uses `app`, `requestId`, `permissionRequestId`, `animationTarget`, and numeric `version: 2`.
Responses return JSON in the direct-object `tdta` descriptor; errors use `errn`/`errs`. The update
union is `metadata`, `axText`, `screenshot`, `completed`, or `failed`. ChatGPT accepts screenshot
files only beneath the real path of `$TMPDIR/com.openai.sky.CUAService`, limits them to 25 MiB, and
allows PNG/JPEG. `CONFIRMED_INTEL_CLIENT_SOURCE`.

Intel implements this bridge with OpenAI-host signature validation, exact event constants, version
and schema checks, and a capture queue that emits metadata, AX text, screenshot, and completion
updates. It never launches the ARM service. `HIGH_CONFIDENCE`; a real Appshot run against an already
approved target remains pending.

The current Intel app also ships a signed, pure-x86_64 `Resources/native/sky.node` containing the
host implementation. Its Objective-C metadata exposes eight host XPC methods: publish presentation,
set source PID, prepare/complete operation, will-end, invalidate, note interaction, and set cursor
location. Its producer callback protocol exposes connect, max-display-size, perform-action, and
did-end-stream. The host bootstraps the service with an Apple Event whose class/ID are `SkCu` and
`PiPB`, carrying a Mach reply port used to rendezvous two private XPC endpoints.
`CONFIRMED_INTEL_STATIC_BINARY`.

Targeted host disassembly confirms the endpoint wire format. The host calls `xpc_pipe_receive` on
the Apple Event's reply Mach port, requires an XPC dictionary value named `endpoint` whose type is
`xpc_endpoint_t`, wraps it in `NSXPCListenerEndpoint` through private `_setEndpoint:`, sends an XPC
routine reply, and creates a bidirectional `NSXPCConnection`. The connection exports the eight host
methods, imports the producer protocol, and begins with `connectWithReply:`. The ARM service imports
the matching `xpc_pipe_create_from_port` and `xpc_pipe_routine` symbols, confirming the opposite
side of this rendezvous. `CONFIRMED_STATIC_BINARY`.

Intel ChatGPT discovers the service PID through its managed-service controller, rather than by
looking up the public Unix socket. At startup it resolves an optional
`CODEX_ELECTRON_COMPUTER_USE_APP_PATH`, copies that source App with `ditto` to
`$CODEX_HOME/computer-use/Codex Computer Use.app`, and later spawns the hard-coded executable
`Contents/MacOS/SkyComputerUseService`. The PID is accepted only while it is running and the native
addon confirms that its executable path matches the canonical path; the accepted PID is then sent
to `connectRemoteHostedPIPContentHost`. The internal node_repl host-services pipe merely asks this
same controller to ensure the service and does not carry the App path itself.
`CONFIRMED_INTEL_CLIENT_SOURCE`.

The supplied ARM service is not protocol-identical to the installed Intel host: its producer
protocol metadata has five methods rather than four, and its strings include the newer
`setPetLocationWithX:y:available:withReply:` selector. Any native PIP implementation must therefore
target the installed Intel `sky.node` contract and treat ARM behavior as an oracle, rather than
copying the ARM protocol surface verbatim. `CONFIRMED_STATIC_BINARY`.

Intel now implements the version-gated bootstrap and endpoint wire format, the exact Intel host and
producer selector ABI, a real local CAContext surface, presentation publication/source-PID binding,
`focus-presentation`, cursor forwarding, and turn-scoped end/invalidation. The presentation surface
is refreshed from each successful `get_app_state` screenshot. This should provide the native Codex
container and host-rendered cursor without moving the user's physical pointer, but it is not yet the
official continuously updating ScreenCaptureKit window/cursor stream. Dynamic managed-host
verification remains pending, so the feature stays behind `INTEL_SKY_EXPERIMENTAL_PIP=1` and is a
`KNOWN_DIFFERENCE` until that run succeeds.

ARM static error cases include `noTextToType`, `pasteboardWriteFailed`,
`pasteboardReadTimedOut`, `pasteboardChangedDuringPaste`, `invalidSecondaryActionForElement`,
`cannotSetValueForNonSettableElement`, `cannotSelectTextForElement`, and
`textToSelectNotFound`. `CONFIRMED_STATIC_BINARY`. Intel now covers these semantic failure classes,
although exact messages and service-code mapping remain `NEEDS_ARM_ORACLE`.

## App and state lifecycle

- The official plugin says `get_app_state` transparently launches a non-running app.
  `CONFIRMED_CLIENT_SOURCE`.
- It normally waits about one second after an action and up to five additional seconds when loading
  indicators or other state changes are detected. `CONFIRMED_CLIENT_SOURCE`.
- ARM request types include app start/stop/modify, frontmost window, capture updates, turn-ended,
  event streams, and Skysight lifecycle. `CONFIRMED_STATIC_BINARY`.
- Intel launches installed apps without activating them, retries window discovery for five seconds,
  and enforces a base one-second post-action settle before the next state capture.
  `CONFIRMED_INTEL_RUNTIME` through Calculator launch/relaunch and action-state tests.
- Element IDs are stable across equal AX objects for a process. The service returns a full tree on
  the first state or when `disableDiff` is true, then service-side `~ / + / -` diffs or the official
  no-change prefix. The unmodified client received full then no-change Finder state successfully.
  `CONFIRMED_INTEL_RUNTIME`; removed-range compaction and exact ARM identity rules remain
  `NEEDS_ARM_ORACLE`.

## Safety and lifecycle

- ARM includes `CUALockScreenGuardian.app`, lock-state monitoring, physical-input callbacks,
  secure-input checks, blocked URL state, user-stop/intervention errors, idle timeout, and hardened
  socket ownership checks. `CONFIRMED_STATIC_BINARY`.
- Intel validates its peer chain and socket ownership, but currently reports every resolvable app as
  allowed and still lacks exact official policy/error mapping and turn-scoped focus restoration.
  `KNOWN_DIFFERENCE`.
- Intel now fails `get_app_state` and actions with `screenLocked` (`-10020`) when the GUI session is
  locked or not on console. It also blocks `type_text` and `paste` while Secure Event Input is
  enabled. The secure-input error mapping remains `LOW_CONFIDENCE`; physical interruption and
  per-turn cancellation remain `KNOWN_DIFFERENCE`.
- Intel preflights Input Monitoring without requesting it. When already granted, a listen-only
  event tap ignores events emitted by the service itself and cancels in-flight keyboard, mouse,
  drag, scroll, AX, and paste work with `userIntervened` (`-10016`) after physical input. When not
  granted, monitoring remains disabled without a permission prompt and `service-status.json`
  reports the degraded capability. Cross-request/whole-turn interruption remains
  `NEEDS_ARM_ORACLE`.

## Oracle backlog

Each case should capture request, response/error, elapsed time, frontmost app before/after, real
cursor before/after, target state, clipboard before/after, and whether physical input cancels it.

1. Element click on button, menu item, checkbox, disclosure triangle, offscreen element, and an
   element with no frame.
2. Coordinate click/drag on 1x and Retina displays, a secondary display, and negative display origin.
3. Scroll integer/fractional/large pages on AX scroll areas and custom canvas views.
4. Every documented keysym family under US and non-US keyboard layouts.
5. `type_text` with emoji, combining marks, newline, secure input, and a WebKit editor.
6. Paste text/Markdown/HTML, delayed pasteboard consumption, failure, and clipboard restoration.
7. Text selection with repeated text, prefix/suffix, text-marker controls, and cursor placement.
8. App launch, PID replacement, window rebuild, sheet/menu/popover, loading settle, and stale IDs.
9. Deadline expiry during activation, settle, paste consumption, and drag.
10. Physical mouse/keyboard input, screen lock/unlock, secure input, service restart, and reconnect.
