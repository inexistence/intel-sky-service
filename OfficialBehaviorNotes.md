# Official Computer Use behavior notes

This document is the compatibility ledger for the clean-room Intel implementation. The
observable behavior of the unmodified `@oai/sky` client and Apple Silicon service is the
specification. Every nontrivial compatibility choice should cite evidence and remain easy to
replace when stronger evidence appears.

## Evidence labels

- `CONFIRMED_CLIENT_SOURCE`: directly encoded by the bundled `@oai/sky` JavaScript or types.
- `CONFIRMED_STATIC_BINARY`: present in the official ARM64 service's symbols, strings, metadata,
  linked frameworks, or disassembly.
- `CONFIRMED_ARM_RUNTIME`: exercised against the unmodified service on Apple Silicon.
- `CONFIRMED_INTEL_RUNTIME`: exercised through the unmodified client against this service.
- `HIGH_CONFIDENCE`: multiple indirect sources agree, but the official behavior was not run.
- `PARTIAL`: implemented or evidenced incompletely, with material lifecycle/schema differences left.
- `NEEDS_ARM_ORACLE`: a prepared differential case still needs an Apple Silicon run.
- `BLOCKED_BY_ENTITLEMENT`: a reproducible platform authorization or signing requirement prevents
  a compatible implementation without impersonation or weakening security.
- `KNOWN_DIFFERENCE`: current Intel behavior is observably or provably different.
- `OUT_OF_SCOPE`: catalogued for protocol completeness but intentionally excluded from this phase.

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
| `get_app_state` | `ComputerUseIPCAppGetSkyshotRequest` | `CONFIRMED_CLIENT_SOURCE` | partial | exact AX rendering and transient-window oracle |
| `click` | `click` | `CONFIRMED_CLIENT_SOURCE` | partial | AX/CG fallback and menu semantics |
| `drag` | `drag` | `CONFIRMED_CLIENT_SOURCE` | partial | calibrate timing/path and official cursor animation |
| `paste` | `paste` | `CONFIRMED_CLIENT_SOURCE` | partial | ARM format/error oracle and clipboard edge cases |
| `perform_secondary_action` | `performSecondaryAction` | `CONFIRMED_CLIENT_SOURCE` | partial | exact action validation and errors |
| `press_key` | `pressKey` | `CONFIRMED_CLIENT_SOURCE` | partial | full keysym/layout/secure-input behavior |
| `scroll` | `scroll` | `CONFIRMED_CLIENT_SOURCE` | partial | AX page actions and CG fallback |
| `select_text` | `selectText` | `CONFIRMED_CLIENT_SOURCE` | partial | text-marker fallback |
| `set_value` | `setValue` | `CONFIRMED_CLIENT_SOURCE` | partial | fallback and exact errors |
| `type_text` | `type` | `CONFIRMED_CLIENT_SOURCE` | partial | strategy selection and newline semantics |

The differential oracle harness under `Tools/oracle` now has a declarative case matrix covering all
eleven APIs, captures calls through the unmodified high-level `sky` client, and compares normalized
ARM/Intel traces. Target authorization and mutation are separately opt-in so unattended runs cannot
silently open Computer Use approval UI or modify an App. Harness behavior has non-GUI regression
coverage; official ARM traces for the case matrix remain `NEEDS_ARM_ORACLE`.

The public low-level `MacComputerUseClient` additionally exposes `startApp`, which sends
`ComputerUseIPCAppStartRequest` with `app` and returns `MacWindowAppState`. ARM Swift field metadata
contains the matching one-field request and the `ComputerUseIPCSkyshotResult` shape (`app`,
`skyshot`, `appSpecificInstructions`). `CONFIRMED_CLIENT_SOURCE` and `CONFIRMED_STATIC_BINARY`.
Intel now routes this request through the same policy, non-activating launch, window-readiness,
loading-settle, screenshot, and AX capture path as `get_app_state`, forcing a full-tree initial
baseline. The authorization-gated differential harness has a dedicated low-level-client case.
`HIGH_CONFIDENCE`; exact behavior when the target is already running remains `NEEDS_ARM_ORACLE`.

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

## Capture Stream

- ARM field metadata confirms `ComputerUseIPCAppStartCaptureRequest(app, requestID,
  permissionRequestID, animationTarget, version)`, version cases `initial`, `reliableFinalFrame`,
  and `future(Int)`, and a start response with `result`, optional animation/transition fields, and
  optional permission grant state. The start result cases are `started` and
  `appshotPermissionsAbandoned`. `CONFIRMED_STATIC_BINARY`.
- ARM field metadata confirms that each `ComputerUseIPCCaptureUpdate` carries `type`, `app`, and
  optional `text`, `screenshot`, `transitionSnapshotURL`, or `failureReason`. The update cases are
  exactly `metadata`, `axText`, `screenshot`, `completed`, and `failed`; failure reasons are
  `blockedByPolicy`, `screenshotCaptureFailed`, and `unknownCaptureFailed`.
  `CONFIRMED_STATIC_BINARY`.
- Intel now treats Start as a session start rather than a precomputed four-item response. A bounded
  producer continuously samples full AX/screenshot state, compares content, coalesces queued update
  types under backpressure, and lets Next long-poll until a change, terminal event, or request
  deadline. Capture polls bypass the otherwise conservative serialized AX/action gate, so other
  clients and ordinary RPCs remain responsive. `PARTIAL`: the producer is polling-based rather than
  the official runtime's not-yet-recovered change notification and reliable-final-frame machinery.
- Capture ownership is stable per Unix connection and per native Apple Event sender PID. Socket
  disconnect and service shutdown discard owned streams and wake blocked consumers; turn
  transition/end and App stop/deactivation enqueue `completed`; producer failures enqueue the
  confirmed `failed` shape. A lifecycle generation closes the race where a turn ends during Start's
  initial capture. `HIGH_CONFIDENCE`; exact official disconnect terminal visibility remains
  `NEEDS_ARM_ORACLE`.

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
- ARM Skyshot context metadata contains `overrideScreenshotWindowID`,
  `additionalScreenshotWindowIDs`, `screenshotIncludesWindowShadow`, and plural
  `skyshotImageFiles`; the binary imports `SCScreenshotManager.captureImage` and both
  `SCContentFilter.initWithDesktopIndependentWindow` and `initWithDisplay:includingWindows:`.
  `CONFIRMED_STATIC_BINARY`. Intel now preserves the primary window's screenshot frame and Retina
  dimensions while adding visible, intersecting non-normal-layer windows from the same process via
  `SCScreenshotManager`. Ordinary windows use the official binary's
  `desktopIndependentWindow` filter shape; macOS 13, a five-second local timeout, or any
  ScreenCaptureKit lookup/capture failure falls back to the prior `/usr/sbin/screencapture` path.
  An attended TextEdit secondary-action smoke showed the context menu in both the AX tree and the
  1322×866 screenshot, whereas the previous implementation omitted it; the ScreenCaptureKit
  no-menu screenshot retained the same dimensions and visual content. `CONFIRMED_INTEL_RUNTIME`.

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
- `SynthesizedEvent` exposes process-targeted click, drag, scroll, key, and Unicode typing
  constructors. Every event bundle has `send(to: pid)`, whose disassembly calls
  `CGEventAPI.postToPid`; mouse constructors take the target window ID, bounds, and coordinate
  orientation instead of posting through the global HID tap.
- The exact synthetic-focus envelope is visible in disassembly: AppKit-defined subtype `1` with
  the target window number, process-notification subtype `0x8000` (key focus returned), followed
  on teardown by process-notification subtype `0x4000` (key focus removed) and AppKit-defined
  subtype `2` (application deactivated).
- `SystemFocusStealPreventer` exposes process-scoped start/stop calls plus target-lost/target-gained
  callbacks and menu-dismissal suppression.
- Its lazy singleton owns a session event tap whose mask is exactly `1 << 21` (AppKit process
  notifications) plus a per-target event tap assembled from a CGEventType array. The singleton
  stores each protected PID with lost/gained callbacks, mouse event taps, and a menu-dismissal
  suppression flag.
- The process-notification callback reads raw CGEvent fields `40` (target PID), `64` (CPS subtype),
  `71` (focus-theft ID), and `73` (subject PID). It maps a ViewBridge auxiliary subject back to its
  host App before consulting the protected-PID table. `KeyFocusTaken (0x4000)` and
  `KeyFocusReturned (0x8000)` take a bookkeeping/drop branch, while `NewFront (2)` and
  `KeyFocusChanged (0xF102)` enter the larger focus-transition state machine.
- That state machine calls dynamically resolved `CPSReleaseKeyFocusWithID` with field `71`; its
  helper accepts the full `UInt32` range (including zero) and reports success only for `noErr`.
  This establishes an important fail-safe: a theft event
  must not be hidden when key focus could not first be released. The remaining exact ViewBridge,
  typing-focus, and lost/gained callback transitions are still under analysis.
- The general subject mapper returns ordinary App PIDs unchanged. For an
  `NSRunningApplication` with activation policy `.prohibited (2)`, it creates that process's AX
  Application and examines `AXFocusedUIElement`. If that PID is still prohibited, it also probes
  the focused and main windows, resolves their PIDs, and considers a localized-name match among
  running non-prohibited Apps. A final branch reads
  `NSWorkspace.shared.frontmostApplication.processIdentifier`; the exact Boolean gate on that
  branch is not yet named, so Intel must not treat the frontmost App as an unconditional host.
  `CONFIRMED_STATIC_BINARY` / `NEEDS_ARM_ORACLE` for the final gate.
- A separate specialized helper handles the process currently discovered by executable name
  `ViewBridgeAuxiliary`. It captures the helper's focused element and returns two optional PID
  candidates. The first resolver refetches the focused element and retries every 15 ms for at most
  one second before entering the general mapper; the second calls `actualPID` on the captured
  focused element and accepts it only when that PID is itself `.prohibited`. The retry therefore
  belongs to host-resolution state, not to the event-tap release operation itself. The exact
  interpretation and preference order of the two packed candidates remains
  `NEEDS_ARM_ORACLE`. `CONFIRMED_STATIC_BINARY`.
- The specialized `AXUIElementRef.actualPID` getter calls the private C function
  `_AXUIElementGetActualPid(AXUIElementRef, pid_t *)`. This spelling is confirmed by reproducing the
  bundled `SoftLink` SipHash request: with the AccessibilitySPI salt, the candidate hashes to the
  exact stored request `0x245daf9a4f1ec5dd`. The ARM call site initializes the output to `-1`,
  returns it only for `kAXErrorSuccess`, and throws the AX error otherwise. The current Intel
  HIServices image exports this exact leading-underscore spelling; a read-only runtime probe returned
  each `ViewBridgeAuxiliary` application's own PID for its Application AX element, while both had no
  focused AX element (`-25200`) at probe time. This confirms availability and ABI, but not the
  specialized fallback's observable host-mapping result. `CONFIRMED_STATIC_BINARY` /
  `CONFIRMED_INTEL_RUNTIME` / `NEEDS_ARM_ORACLE`.
- The `KeyFocusTaken/Returned` helper passes the original event unless its tracked current-focus
  state is in the expected case and its stored PID equals raw field `40`. Only in that matched state
  does it return nil and set the adjacent `lastViewBridgeFocusStealWasSuppressed` state byte. It
  does not call the focus-release SPI itself. The writers and meaning of every focus-state enum case
  are not all recovered yet, so Intel continues to pass these subtypes through rather than emulate
  a partial state machine. `CONFIRMED_STATIC_BINARY` / `NEEDS_ARM_ORACLE`.
- `RemoteHostedPIPContentStream` stores `threadID`, `turnID`, `focusRestoreTarget`, associated window
  IDs, and a stream-end timeout; its lifecycle exposes `willEndStream`, `noteInteraction`, and
  `invalidate`.

Together these show that official focus restoration is stream/turn-scoped and that the target can
be made to believe it is focused without ordinary foreground activation. `CONFIRMED_STATIC_BINARY`.

The official Mac JS transport includes `codexTurnMetadata` on each IPC request. Live node_repl
metadata contains `session_id`, `thread_id`, and `turn_id`; the ARM binary also exposes
`ComputerUseIPCCodexTurnEndedRequest(threadID:turnID:)`. `CONFIRMED_CLIENT_SOURCE` and
`CONFIRMED_INTEL_RUNTIME` for the observed metadata envelope.

Intel uses background AX operations for single-left element click (`AXPress`), complete AX page
scroll, `setValue`, secondary AX actions, and text selection. Physical fallbacks no longer activate
the target or post through the global HID tap: click, drag, pixel scroll, key chords, Unicode typing,
and paste are bound to the latest snapshot's PID/window ID and use `CGEvent.postToPid`. For an
inactive target, each bundle is bracketed by the official activation/focus-returned and
focus-removed/deactivation sequence.
Snapshot expiry or a missing window ID fails closed before input. The process-notification constants
and event routing are `CONFIRMED_STATIC_BINARY`; Intel schema/event-construction tests are
`HIGH_CONFIDENCE`.

An attended Intel runtime smoke against the unmodified bundled `@oai/sky` confirmed Finder full
state and no-change diff capture, Calculator full state and AX element clicks, and TextEdit
`set_value`, `select_text`, Unicode `type_text`, and control-local `Super_L+Right`. Physical user
input interrupted an in-flight action with `userIntervened`, and a fresh state query cleared the
requery latch. `CONFIRMED_INTEL_RUNTIME`.

Targeted ARM vtable recovery and disassembly identified the complete activation path constructed by
`SyntheticAppFocusEnforcer`. The enter path sends `21/0x8000` before AppKit `13/1`; when the target
window exposes `AXActivationPoint`, the activation event carries the target window ID, activation
point, and AppKit flags `0xC0000`, followed by process-targeted AppKit left-mouse-down/up events.
Those mouse events set CoreGraphics fields `3 = 0`, `7 = 3`, and `91/92 = windowID`, and the official
binary calls private `CGEventSetWindowLocation` with `activationPoint - windowFrame.origin`. The
leave path sends AppKit `13/2` before `21/0x4000`. `CONFIRMED_STATIC_BINARY`.

The enforcer constructor creates a `SystemFrontmostApplicationTracker`, registers target-lost and
target-gained handlers with `SystemFocusStealPreventer`, and seeds
`applicationBelievesItIsActive`, `applicationBelievesItHasFocus`, and `applicationIsActive` from
the real process/frontmost state. `enforceActiveState(for:)` is incremental rather than an
unconditional replay. Its explicit `deactivateFocusEnforcer()` path runs only when the target
believes it is active while `applicationIsActive == false`; an actually active target is not sent
the synthetic `13/2` and `21/0x4000` pair. The enforcer's deinitializer unregisters its observer and
focus-steal-preventer entry but does not itself call the explicit deactivate method.
`CONFIRMED_STATIC_BINARY`.

Intel now reads `AXActivationPoint`, reproduces the AppKit mouse construction and window-local SPI,
and omits the activation click when either the point or SPI is unavailable. It now samples
`NSRunningApplication.isActive` before and after a physical action: an already active target receives
no synthetic transition, and a background target that becomes genuinely active during the action
is not synthetically deactivated. Inactive targets retain the balanced envelope, including on a
throwing action, and same-target nesting remains deduplicated. This closes the confirmed
actual-active-state difference while retaining an action-scoped approximation of the official
observer lifetime. Unit coverage is `HIGH_CONFIDENCE`; an attended active-target runtime trace
remains `NEEDS_ARM_ORACLE`. An attended real-client
TextEdit smoke proved that background `Super_L+a` now selects the full document and that both
`type_text` and `paste` replace the selection without taking foreground focus; the fixture was
restored after both probes. `CONFIRMED_INTEL_RUNTIME`. Earlier probes that replayed only the four
notifications are retained as negative evidence: the activation-point mouse pair and private
window-local coordinate are necessary for AppKit menu-key-equivalent dispatch.

Intel now also installs a suppressible session event tap with the official `1 << 21` mask before
serving requests. While a synthetic-focus action is in flight, it protects only that inactive
target PID. A direct protected subject in `NewFront` or `KeyFocusChanged` is passed to dynamically
resolved `CPSReleaseKeyFocusWithID`; the notification is suppressed only after `noErr`. Missing or
invalid fields, unavailable input monitoring/SPI, release failure, unrelated Apps, unsupported CPS
subtypes, and any physical user input all pass through. Intel resolves prohibited subjects from the
focused element, focused window, and main window, trying both the public PID and the dynamically
resolved `_AXUIElementGetActualPid` ABI. It follows at most three nested prohibited candidates,
rejects cycles and unknown processes, and accepts only a final non-prohibited App. Missing private
SPI and all unresolved cases preserve the original subject. It deliberately omits the official
one-second retry, the not-yet-understood frontmost-App gate, and the separate
`KeyFocusTaken/Returned` bookkeeping branch. Raw-field decoding, subtype classification, scoped
registration, user-intervention fail-open behavior, and release-before-drop semantics have
deterministic Intel coverage. A real probe of both currently running ViewBridge helpers safely
returned their own PIDs because neither exposed focused AX state at that instant.
`HIGH_CONFIDENCE` for the bounded direct/actual-PID path; exact ViewBridge fallback and
stream-scoped lifetime remain `NEEDS_ARM_ORACLE` / `KNOWN_DIFFERENCE`.

An attended negative fixture showed that explicit `NSRunningApplication.activate()` performs an
ordinary Workspace foreground switch and emits no type-21 process notification to this tap. That
operation is intentionally outside the guard's scope; Intel action paths do not call it. A separate
session-tap fixture injects the official raw event shape and verifies live callback delivery,
field decoding, protected-subject matching, and release-before-drop routing without changing the
desktop focus. CoreGraphics rewrites field `40` to the current session event target during delivery
while preserving fields `64`, `71`, and `73`, independently confirming that suppression must key on
the subject rather than the notification target. `CONFIRMED_INTEL_RUNTIME` for tap plumbing; a
naturally generated CPS theft with a real focus-theft ID remains `NEEDS_ARM_ORACLE`.

The signed x86_64 build was deployed through the standard Codex service path and restarted without
restarting ChatGPT. Its owner-only status file reported Accessibility, Screen Recording, physical
input monitoring, and `focusStealProtection` all available. The official high-level
`sky.js -> nodeRepl.rpc("sky")` path then returned 71 Apps and captured Finder with a screenshot and
a 26,278-character AX tree in 2.3 seconds; the service remained the sole socket owner.
`CONFIRMED_INTEL_RUNTIME`.

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

The bundled client removes a cached transport whenever it observes `isClosed`, rejects all pending
requests on pipe error/close, and creates a replacement transport on the next call. Its startup
sequence is an initial 250 ms connection attempt, host `ensureService("computer-use")` (or
LaunchServices), then 100 ms connection retries within a five-second budget.
`CONFIRMED_CLIENT_SOURCE`.

Intel now sets macOS `SO_NOSIGPIPE` on the listener, every accepted peer, and its diagnostic client;
a peer that closes before a response therefore produces `EPIPE` inside that connection task rather
than terminating the service. `SIGTERM` and `SIGINT` stop the listener, and shutdown removes only
the socket device/inode that this instance bound and only a same-PID, owner-only regular runtime
status file. A replacement instance's files, PID-mismatched status, and symbolic links are
preserved. A deployed runtime smoke terminated the service while the same unmodified `@oai/sky`
module retained its cached transport: the next `list_apps` triggered host startup, reconnected in
773 ms, and returned 71 Apps. Two hundred framed ping connections that closed immediately before
reading a reply left the service available, after which the same client again returned 71 Apps.
Direct TERM verification removed both socket and status before an immediate same-path restart.
`CONFIRMED_INTEL_RUNTIME`.

Intel now renders an independently drawn, non-activating software cursor for click, drag, and
scroll operations. It is an input-transparent status-level panel that joins all Spaces, does not
move the physical pointer, animates between positions, shows pressed feedback, and hides after an
idle interval. A real Calculator click changed the target value while AppKit recorded the same
overlay window being ordered in and out five seconds later. The earlier cross-process
`CGWindowList` probe was a false negative because that diagnostic process lacked Screen Recording
access. `CONFIRMED_INTEL_RUNTIME`.

The official cursor's exact artwork, path/spring constants, visibility state machine, menu handling,
and turn-scoped lifetime remain `NEEDS_ARM_ORACLE`. Intel now has the synthetic-focus envelope and
native PIP-host integration, but its focus illusion is action-scoped rather than maintained by the
official observer/event-tap state machine across the whole stream. That lifetime distinction remains
a `KNOWN_DIFFERENCE` pending runtime calibration.

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
and completes them at turn boundaries. `CONFIRMED_CLIENT_SOURCE` (installed Intel caller).

The same installed Intel ChatGPT status-item path requests
`ComputerUseIPCCodexStatusItemMenuStateRequest`. Its validated response contains
`computerUse.activeApplications` descriptors (`id`, `name`, nullable `bundleIdentifier` and
`bundleURL`) plus Computer History state. Selecting `computer-use/stop-application` sends an
authenticated `SkCu`/`SndR` Apple Event with `ComputerUseIPCAppStopRequest { app }` and expects an
empty response. `CONFIRMED_CLIENT_SOURCE` (installed Intel caller). No current ChatGPT caller was found for the ARM
`FrontmostWindow` or `AppModify` requests, but both hidden socket surfaces are now implemented
because the complete runtime requires them.

ARM field metadata confirms that `ComputerUseIPCFrontmostWindowRequest` is empty and returns an
optional `ComputerUseIPCFrontmostWindow { bundleIdentifier, name, windowTitle? }`. Its exported
handler signature independently confirms the optional response. Intel queries the actual
frontmost `NSRunningApplication`, reads the AX focused-window title when available, and returns
JSON `null` when no bundle-backed frontmost App is available. `CONFIRMED_STATIC_BINARY` /
`HIGH_CONFIDENCE`; exact filtering and title selection remain `NEEDS_ARM_ORACLE`.

ARM field metadata confirms `ComputerUseIPCAppModifyRequest { app, modification }`, where
`modification` is exactly `activate | deactivate`, and the exported handler returns
`ComputerUseIPCAppState { active, currentApp? }`. Disassembly confirms that the handler resolves
an `ApplicationTarget`, rejects forbidden Computer Use targets, obtains a
`ComputerUseAppInstance`, and calls its `ComputerUseAppController.activate()` or `deactivate()`;
this is a Computer Use session transition, not an attempt to deactivate another macOS foreground
process. Intel now performs the same policy gate, preserves the user-stop latch, activates or
deactivates the app-session registry, returns the confirmed app-state envelope, and invalidates
app-scoped presentation state on deactivation without setting the user-stop latch.
`CONFIRMED_STATIC_BINARY` / `HIGH_CONFIDENCE`; launch timing and idempotence remain
`NEEDS_ARM_ORACLE`.

The exact Intel Appshot transport is now confirmed. ChatGPT sends synchronous Apple Events with
class/ID `SkCu`/`SndR`, parameters `RspT` (request type), `ReqD` (UTF-8 JSON data), and `ClVn`
(`CodexComputerUseNativeBridge-1`) directly to the managed service PID. The current start request
uses `app`, `requestId`, `permissionRequestId`, `animationTarget`, and numeric `version: 2`.
Responses return JSON in the direct-object `tdta` descriptor; errors use `errn`/`errs`. The update
union is `metadata`, `axText`, `screenshot`, `completed`, or `failed`. ChatGPT accepts screenshot
files only beneath the real path of `$TMPDIR/com.openai.sky.CUAService`, limits them to 25 MiB, and
allows PNG/JPEG. `CONFIRMED_CLIENT_SOURCE` (installed Intel caller).

Intel implements this bridge with OpenAI-host signature validation, exact event constants, version
and schema checks, and a capture queue that emits metadata, AX text, screenshot, and completion
updates. It never launches the ARM service. `HIGH_CONFIDENCE`; a real Appshot run against an already
approved target remains pending.

Intel now also tracks successfully captured Apps as turn-scoped sessions, returns the current
ChatGPT status-menu schema (with Computer History truthfully reported unavailable/stopped), and
handles the authenticated App-stop request. A stop immediately removes the App from status state,
cancels in-flight work at cooperative action/deadline checkpoints, blocks subsequent state and
action requests with `userStoppedSession` (`-10012`), and invalidates its experimental native PIP.
The latch clears only at a turn start/transition/end; the per-turn active registry is cleared at the
same boundary, so actions in a new turn require a fresh state capture even if an old AX snapshot is
still cached. Both Apple Event and socket request paths are supported. Schema, routing,
cancellation, PIP cleanup, and turn-boundary behavior have non-GUI regression coverage.
`HIGH_CONFIDENCE`; the real native status-item click path remains `NEEDS_ARM_ORACLE` and pending an
attended Intel smoke, as do exact official `id` and `bundleURL` value conventions.

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
`CONFIRMED_CLIENT_SOURCE` (installed Intel caller).

An attended Intel smoke while the compatibility service was running solely through its per-user
LaunchAgent showed no native Computer Use status item in the macOS menu bar. After ChatGPT was
restarted with the compatibility App on its managed-service path, the native Computer Use status
item appeared, confirming that socket discovery alone is insufficient and that the host requires
the managed service PID. `CONFIRMED_INTEL_RUNTIME`.

The same managed-host smoke reached remote PIP presentation but rendered only an opaque gray
surface (occasionally showing the service-supplied Finder placeholder) rather than live window
frames. Multiple CAContext, ordinary CALayer, and AVSampleBufferDisplayLayer variants did not cross
the ChatGPT/service signing-team boundary reliably. PIP is therefore a documented
`KNOWN_DIFFERENCE` and is disabled for managed launches; the core Computer Use IPC/action path does
not depend on it. `CONFIRMED_INTEL_RUNTIME`.

The supplied ARM service is not protocol-identical to the installed Intel host: its producer
protocol metadata has five methods rather than four, and its strings include the newer
`setPetLocationWithX:y:available:withReply:` selector. Any native PIP implementation must therefore
target the installed Intel `sky.node` contract and treat ARM behavior as an oracle, rather than
copying the ARM protocol surface verbatim. `CONFIRMED_STATIC_BINARY`.

Intel `sky.node` validates monotonically sequential operation IDs and recognizes exactly three
two-phase presentation operation kinds: `resize`, `resize-in-progress`, and `replace-context`.
Stable source-size changes use `resize`; the request carries the current context ID, source size,
and an XPC dictionary containing a Mach send right named `fence`, followed by
`completeOperationWithPresentationID:operationID:withReply:`. Its own attachment path constructs
CAContext with `contextWithCGSConnection:options:`. On this Intel system that factory, unlike
`localContextWithOptions:`, produces a context implementing `createFencePort`.
`CONFIRMED_STATIC_BINARY` / `CONFIRMED_INTEL_RUNTIME`.

ARM imports ScreenCaptureKit and AVFoundation, and its `RemoteHostedPIPWindowRenderer` metadata
contains `SCStream`, `SCContentFilter`, `SCShareableContent`, `AVSampleBufferDisplayLayer`, separate
window/cursor display layers, and separate capture-stream fields. `CONFIRMED_STATIC_BINARY`.

Intel now implements the version-gated bootstrap and endpoint wire format, the exact Intel host and
producer selector ABI, a real local CAContext surface, presentation publication/source-PID binding,
`focus-presentation`, cursor forwarding, and turn-scoped end/invalidation. Each presentation starts
a desktop-independent ScreenCaptureKit stream for the target's front normal window and feeds BGRA
frames at up to 30 fps into an `AVSampleBufferDisplayLayer`; the latest `get_app_state` image remains
visible until the first frame and returns if capture stops. Capture excludes the physical cursor
because cursor state is sent separately to the native host. Every subsequent `get_app_state`
reconciles the capture against the target process's current front normal window and updates the
existing `SCStream` filter when the window ID changes. Stream creation, filter-update, and delegate
failures fall back to the retained state image and use finite 0.25/0.5/1-second recovery attempts;
late callbacks from replaced streams are ignored by identity. Unit tests replace capture with a
fake, so routine tests cannot request Screen Recording or per-target Computer Use approval.
For stable source-size changes, Intel resizes the CAContext layers, creates a transaction fence,
sends the host's `resize` prepare/complete sequence, and updates the live `SCStream` configuration.
The Mach-send fence envelope is covered by a real bidirectional XPC test. `HIGH_CONFIDENCE`.
Dynamic managed-host verification and long-running resize/recovery stress remain pending, so the
feature is fail-closed for managed launches. ChatGPT's inherited
`INTEL_SKY_EXPERIMENTAL_PIP=1` is deliberately ignored; direct developer launches may opt in with
`--experimental-pip` only.

ARM static error cases include `noTextToType`, `pasteboardWriteFailed`,
`pasteboardReadTimedOut`, `pasteboardChangedDuringPaste`, `invalidSecondaryActionForElement`,
`cannotSetValueForNonSettableElement`, `cannotSelectTextForElement`, and
`textToSelectNotFound`. `CONFIRMED_STATIC_BINARY`. Intel now covers these semantic failure classes,
although exact messages and service-code mapping remain `NEEDS_ARM_ORACLE`.

## App and state lifecycle

- The official plugin says `get_app_state` transparently launches a non-running app.
  `CONFIRMED_CLIENT_SOURCE`.
- The official low-level Mac client also has an explicit `startApp` request returning the same
  window-state result family. Intel supports it and forces a fresh full-tree baseline after launch.
  `HIGH_CONFIDENCE`; already-running and launch-failure timing remain `NEEDS_ARM_ORACLE`.
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
- Direct parsing of the ARM Mach-O Swift metadata recovered `RefetchableSkyshotAXTree` with
  `systemSelection` and `isAXTreeDiffingEnabled`; `SystemSelection` retains a window revision and
  `UIElementTreeInvalidationMonitor`. The monitor distinguishes `layoutChanged` from a set of
  destroyed elements, while the tree revision stores IDs, elements, paths, prior revision, and
  changes. The official refetch error enum distinguishes invalid ID, missing monitor, ambiguity
  before/after refetch, and no-longer-valid before/after refetch. Exact matching control flow is
  still `NEEDS_ARM_ORACLE`, but blind title-only rebinding is ruled out. `CONFIRMED_STATIC_BINARY`.
- Intel snapshots now retain each element's child-index path, ancestor role path, role/subrole,
  identifier, title, description, and frame. An action normally probes the original AX reference;
  confirmed destruction, layout invalidation, ephemeral roles, or an explicit
  `kAXErrorInvalidUIElement` trigger a refetch. Same-path candidates
  must preserve the semantic identity; moved elements require one uniquely labeled semantic match;
  unlabeled elements additionally require unchanged path, role ancestry, and geometry. Missing or
  ambiguous candidates fail closed with the official error text and `accessibilityError`. A real
  unmodified-client smoke closed a Finder window, opened a replacement, then used the old Search
  element ID: the service uniquely rebound it and the rebuilt window exposed a focused search text
  field. `CONFIRMED_INTEL_RUNTIME`.
- Targeted ARM disassembly shows the Accessibility observer subsystem calling
  `AXObserverCreateWithInfoCallback`, adding its run-loop source, and dynamically adding/removing
  notifications. The binary embeds `AXUIElementDestroyed`, `AXFocusedWindowChanged`, and
  `AXSelectedChildrenChanged`; these agree with the recovered `destroyedElements/layoutChanged`
  state. `CONFIRMED_STATIC_BINARY`.
- Intel now creates one observer per cached snapshot, tracks focused-window changes, layout/selection
  changes, and destroyed actionable elements, and removes the run-loop source with the snapshot.
  A focused-window change invalidates every old target; a layout change refetches element targets
  but rejects screenshot-coordinate and untargeted keyboard/text operations until requery.
  Ephemeral `AXMenu`, `AXMenuItem`, `AXPopover`, and `AXSheet` targets always prove live tree
  membership before acting because Finder can keep a dismissed menu item's AX reference callable
  without emitting destruction on that item. Real unmodified-client tests confirmed a new Finder
  window rejects an old-window element and that a dismissed “显示简介” menu item now fails with the
  official no-longer-valid message instead of reporting false success. Five repeated Finder captures
  with node-level notification registration took 173–197 ms. Seven monitor/refetch regressions and
  the later socket, lifecycle, PIP, focus, and ViewBridge coverage bring the suite to 173 tests.
  `CONFIRMED_INTEL_RUNTIME`.
  The official pre-refetch ambiguity criterion remains `NEEDS_ARM_ORACLE`.

## Safety and lifecycle

- ARM includes `CUALockScreenGuardian.app`, lock-state monitoring, physical-input callbacks,
  secure-input checks, blocked URL state, user-stop/intervention errors, idle timeout, and hardened
  socket ownership checks. `CONFIRMED_STATIC_BINARY`.
- ARM exposes `appStoppedByUser`, the public `userStoppedSession` code (`-10012`), and the exact
  instruction that an explicitly stopped App remains unavailable for the current turn and becomes
  available on the next assistant turn. Intel reproduces that turn-scoped latch and exact message,
  including cooperative cancellation of an operation already in progress. `HIGH_CONFIDENCE`;
  exact stop timing in non-cooperative macOS calls remains `NEEDS_ARM_ORACLE`.
- The ARM service contains `CodexAppServerComputerUsePolicyProvider`, a cached organization policy
  with `allow_persistent_approval`, `allowed_bundle_ids`, and `denied_bundle_ids`, and a separate
  service-local forbidden-target classifier guarded by the internal
  `ComputerUseAllowForbiddenTargets` feature. The classifier's static data includes credential
  managers, terminal emulators, OpenAI controller Apps, web browsers, and system authentication UI;
  browser detection also checks for an `http` entry in `CFBundleURLTypes` / `CFBundleURLSchemes`
  and the `AppleApplication` or `BrowserCrApplication` principal class. Finder is the sole statically
  observed low-risk target. Other targets are high risk and carry the exact warning subtitle about
  prompt injection, data theft, and loss. `CONFIRMED_STATIC_BINARY`.
- Intel now returns the complete documented policy target schema, reproduces those local forbidden
  categories and browser bundle-metadata checks, marks Finder low risk, emits the official warning
  for high-risk Apps, and maps direct attempts to bypass the policy preflight to `appNotAllowed`
  (`-10006`). State capture checks policy before automatic launch, and action execution checks it
  before any target mutation. `HIGH_CONFIDENCE` with regression coverage. Dynamic organization
  `allowed_bundle_ids` / `denied_bundle_ids` ingestion is still absent and remains a
  `KNOWN_DIFFERENCE`; exact classifier membership remains `NEEDS_ARM_ORACLE`.
- Intel now fails `get_app_state` and actions with `screenLocked` (`-10020`) when the GUI session is
  locked or not on console. It also blocks `type_text` and `paste` while Secure Event Input is
  enabled. The secure-input error mapping remains `PARTIAL`.
- ARM metadata for `ComputerUseAppInstanceManager` includes `userInteractionMonitor`,
  `userInterruptedControlledApp`, `interventionReasonByTargetIdentifier`, per-target debounce tasks,
  and a `requiresRequery` state. This shows that interruption is associated with a controlled target
  and can invalidate the model's prior state across requests rather than merely cancelling one event
  loop. `CONFIRMED_STATIC_BINARY`; exact debounce duration and clearing transitions remain
  `NEEDS_ARM_ORACLE`.
- Intel preflights Input Monitoring without requesting it. When already granted, a listen-only
  event tap ignores events emitted by the service itself, attributes known events by target PID,
  and conservatively treats unresolved targets as affecting every controlled app. It cancels
  in-flight keyboard, mouse, drag, scroll, AX, and paste work with `userIntervened` (`-10016`). A
  successful `get_app_state` records a per-app/PID checkpoint at capture start; physical input after
  that point, including during capture, latches subsequent actions to `userIntervened` until another
  clean state query. Other known target processes are unaffected. When Input Monitoring is not
  granted, monitoring remains disabled without a permission prompt and `service-status.json`
  reports the degraded capability. If its event tap becomes available after an earlier snapshot,
  that uncheckpointed snapshot fails closed until requery. `HIGH_CONFIDENCE`; exact official target
  resolution, debounce, and whether some intervention reasons persist for the entire turn remain
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
