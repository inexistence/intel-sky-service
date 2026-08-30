# intel-sky-service

An experimental, clean-room compatibility service for the local macOS IPC used by the bundled `@oai/sky` client. The goal is to restore the complete public Codex Computer Use window API on Intel Macs while keeping the official client and Codex installation unmodified.

This is not an OpenAI product. The protocol is undocumented; compatibility is based on observing the locally installed client. The implementation does not use an API key or send requests to an external model service.

## Current milestone

- `CodexComputerUseIPC-5`
- JSON-RPC 2.0 over a Unix domain socket
- 4-byte little-endian length prefix with an 8 MiB limit
- immediate `ping` response
- peer validation after `ping`: same macOS user and the signed OpenAI chain `node_repl → codex → com.openai.codex`
- `ComputerUseIPCListAppsRequest` backed by running `NSWorkspace` apps plus the official Spotlight recent-usage query (`lastUsedDate` and `useCount`)
- `ComputerUseIPCAppGetSkyshotRequest` with app auto-launch, stable Accessibility element IDs, bounded tree diffs, and focused-window PNG
- latest-snapshot element cache keyed by bundle ID and PID, with a five-minute TTL, 16-app limit,
  active AX invalidation monitoring, and conservative semantic/path refetch after window, layout,
  or element invalidation
- `ComputerUseIPCAppPolicyRequest`, preserving the official JavaScript approval flow
- `ComputerUseIPCFrontmostWindowRequest` and app-instance
  `ComputerUseIPCAppModifyRequest` activate/deactivate transitions
- asynchronous `ComputerUseIPCAppStartCaptureRequest` / `AppNextCaptureUpdateRequest` streams
  with bounded backpressure, long-poll deadlines, client ownership, and lifecycle cleanup
- Record & Replay Event Stream start/status/stop, direct physical event capture, AX full/diff
  context, owner-only JSONL/metadata storage, and sensitive-input suppression
- snapshot-bound `ComputerUseIPCAppPerformActionRequest` clicks by element ID or screenshot coordinate, using `AXPress` before physical fallback
- snapshot-bound, PID/window-targeted `pressKey` chords and bounded Unicode `typeText` input
- snapshot-bound vertical and horizontal scrolling, with AX page actions and bounded pixel fallback
- all eleven public APIs: `list_apps`, `get_app_state`, `click`, `drag`, `paste`, `perform_secondary_action`, `press_key`, `scroll`, `select_text`, `set_value`, and `type_text`
- signed x86_64 App bundle, recommended ChatGPT-managed installer, and legacy standalone
  LaunchAgent installer

The eleven public `@oai/sky` APIs are implemented, including target-scoped physical-input interruption with requery latching, lock/secure-input checks, loading-aware settling, PID/window-targeted synthetic input, release-before-suppress protection against direct background focus theft, an input-transparent software cursor, turn tracking, and conservative focus restoration. The hidden Appshot Apple Event bridge and native Codex PIP path are also implemented: the service can rendezvous with Intel `sky.node`, publish a real CAContext, continuously feed the target window through ScreenCaptureKit and `AVSampleBufferDisplayLayer`, follow target-window resize and process replacement through fenced host operations, republish live presentations after a host reconnect, recover from bounded capture failures, retain state snapshots as a fallback, forward cursor state, and end capture with its turn. Exact ARM ViewBridge focus/capture lifetimes and long-run resilience remain active compatibility work. See [`ProtocolCatalog.md`](ProtocolCatalog.md) for the request-by-request coverage matrix and `OfficialBehaviorNotes.md` for the evidence ledger and known differences.

`Tools/oracle` contains an authorization-safe ARM/Intel differential runner. Its default case does
not target an App; state capture and mutation cases require separate explicit opt-ins so unattended
runs do not leave unnoticed Computer Use approval prompts.

## Build and test

```sh
swift test
swift build -c release
```

With no arguments, the service listens at the path used by the official client:

```text
~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock
```

Use an explicit socket path for isolated development:

```sh
.build/debug/intel-sky-service --socket /tmp/intel-sky-service/computeruse.sock
```

In another terminal, the smoke client verifies framing and `ping`:

```sh
.build/debug/sky-smoke-client /tmp/intel-sky-service/computeruse.sock
```

The smoke client is unsigned, so the service returns `ping` and then rejects its `listApps` request during peer validation. That is expected.

## App bundle and installation

Build an x86_64 background App bundle:

```sh
Scripts/build-app.sh
```

The script prefers `Apple Development: 510229374@qq.com (YP98F3PUMT)` and falls back to ad-hoc
signing only when that identity is unavailable. A certificate without its matching private key is
not a valid signing identity. Set `CODESIGN_IDENTITY` to select another installed identity. For
distribution outside a trusted development environment, use a Developer ID Application signature
and notarization so Gatekeeper can validate the downloaded App.

### Recommended: ChatGPT-managed service with native PIP

For a source checkout, the one-command installer builds the App when needed, audits the installed
Intel ChatGPT PIP host, verifies the App signature and x86_64 architecture, backs up an existing
managed App, disables the legacy LaunchAgent if present, installs to ChatGPT's canonical path, and
prepares the bundled Computer Use runtime for future Codex sessions:

```sh
Scripts/install-managed-service.sh
```

To install a reviewed prebuilt bundle instead:

```sh
Scripts/install-managed-service.sh "/path/to/Intel Sky Service.app"
```

The installed path and executable basename are exact requirements:

```text
~/.codex/computer-use/Codex Computer Use.app
~/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
```

Capability setup uses only files bundled with the installed ChatGPT App. The installer verifies
the bundled `node_repl`, Node.js, and `@oai/sky` runtime. When the current Codex configuration has
no `node_repl` MCP entry, it adds one through the bundled Codex CLI. An existing compatible entry
is retained exactly as-is; an incompatible entry is reported and never overwritten.

After the managed service has bound its socket, it automatically links the official skill
directory into the cross-client discovery location:

```text
~/.agents/skills/computer-use -> /Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/docs/skills/oai_sky_lib/macos
```

An existing non-link `computer-use` skill is reported and never overwritten. The health-gated
registration is idempotent, so later ChatGPT updates are picked up automatically.

Start a **new Codex session** after restarting ChatGPT. The new session discovers the skill and
`node_repl` automatically, so requests such as “打开备忘录并新建一条笔记” work without mentioning
MCP, `node_repl`, `@oai/sky`, or the Unix socket. Existing sessions keep the tool set captured when
they were created and therefore do not gain Computer Use retroactively.

If ChatGPT uses a custom `CODEX_HOME`, run the installer with that same environment value; it then
installs to `$CODEX_HOME/computer-use/Codex Computer Use.app`. The installer never starts or quits
ChatGPT and cannot grant macOS privacy consent. After it completes, grant the final installed App
the permissions listed below, completely quit ChatGPT, and open ChatGPT again. ChatGPT then owns the
service lifecycle, supplies the managed PID to the native host, and enables the authenticated
Remote Hosted PIP path.

The installer retains an existing canonical App as a timestamped sibling named
`Codex Computer Use.app.backup-YYYYMMDD-HHMMSS`. It also preserves a detected legacy LaunchAgent as
a timestamped disabled plist rather than deleting it. Do not run the legacy LaunchAgent and the
ChatGPT-managed service together: both use the same Unix socket, while only the managed PID can
rendezvous with the native PIP host.

After a ChatGPT update, rerun the read-only compatibility audit before reinstalling or using native
PIP:

```sh
Scripts/audit-pip-host.sh
```

It fails closed when the Intel host architecture, OpenAI signing team, or required XPC selectors
change.

### Legacy: standalone socket service

For development or socket-only compatibility without native PIP, install the per-user LaunchAgent:

```sh
Scripts/install-launch-agent.sh
```

This installer copies the App to `~/Applications` and creates the per-user LaunchAgent
`dev.huangjianbin.intel-sky-service`. It is not the recommended full Computer Use installation and
starts the service with `--disable-pip`, so it does not initialize the native status item or Remote
Hosted PIP path. The service uses its own bundle identity; it does not impersonate OpenAI's
`com.openai.sky.CUAService` or request OpenAI's application-group entitlement.

The App bundle intentionally installs its executable as `Contents/MacOS/SkyComputerUseService`.
The current ChatGPT managed-service host requires that exact basename. ChatGPT also supports a
startup-only source override named `CODEX_ELECTRON_COMPUTER_USE_APP_PATH`; when set to this App,
ChatGPT copies it into its canonical Codex-home location, starts that exact executable, validates
the resulting PID, and passes the PID to the native PIP host. This variable belongs to the ChatGPT
main process, not to `node_repl` or the Computer Use MCP environment.

Authenticated PIP rendezvous is enabled for the argument-free managed-service launch. Use
`--disable-pip` as the explicit rollback switch if a future ChatGPT build fails the host audit or
regresses the presentation path; the older `--experimental-pip` spelling remains accepted as a
compatibility alias. The service still treats PIP as an optional presentation layer, so failure to
publish never changes the underlying Computer Use request result. Local static, video-layer, and
controlled cross-signature CAContext smokes render correctly. Managed ChatGPT runtime verification
has confirmed live fitted frames, four-corner clipping, internal IOSurface cursor composition, and
clean parent-owned restart. Extended resize/replacement/reconnect/end stress remains a release gate.

During protocol development, the unmodified bundled `@oai/sky` client from ChatGPT `26.825.41651` successfully completed the IPC-5 handshake, returned the local app list, and captured Finder state on x86_64. The production peer policy additionally requires the real `node_repl → codex → com.openai.codex` process chain; launching ChatGPT's signed Node binary from a shell is intentionally rejected.

## Permissions

`getAppState` requires Accessibility permission. A screenshot is included only when Screen Recording permission is already available. The service deliberately avoids calling the APIs that trigger permission prompts; grant access manually to the final signed app or executable used to run the service.

For the recommended managed installation, add
`~/.codex/computer-use/Codex Computer Use.app` in System Settings → Privacy & Security and enable:

- Accessibility
- Screen & System Audio Recording
- Input Monitoring

Input Monitoring is required for physical-intervention protection and Record & Replay. Completely
quit and reopen ChatGPT after changing permissions. For the legacy LaunchAgent installation, grant
the same permissions to `~/Applications/Intel Sky Service.app`, restart that agent, and use only the
socket-only mode. Rebuilding an ad-hoc-signed App changes its code identity and may require granting
permissions again; a stable signing identity avoids that churn.

When launched as an App, the service asks macOS for either permission if it is missing. Permission prompts are issued by the service process itself so macOS records the correct responsible application identity.

Check permissions for a direct invocation:

```sh
~/.codex/computer-use/Codex\ Computer\ Use.app/Contents/MacOS/SkyComputerUseService --check-permissions
```

The command returns exit status 0 only when Accessibility and Screen Recording are granted;
otherwise it returns 77 and prints the individual states as JSON. Because macOS can attribute TCC
checks to a process's responsible parent, the running status file is authoritative for the managed
launch.

The running service writes its own authoritative startup state to:

```text
~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/service-status.json
```

After restarting ChatGPT, verify that `accessibility`, `screenRecording`,
`physicalInputMonitoring`, and `focusStealProtection` are all `true` in this owner-only file.
`computerUseCapability.registered` must also be `true`. When it is `false`,
`computerUseCapability.diagnostic` identifies the exact missing runtime, conflicting user entry, or
Codex configuration failure. If the service itself is stopped, the already-registered official
skill and `node_repl` remain discoverable; the bundled `@oai/sky` client then reports the concrete
native-pipe/startup failure instead of making the session conclude that Computer Use does not
exist.

Capability registration can be rechecked without reinstalling the App:

```sh
~/.codex/computer-use/Codex\ Computer\ Use.app/Contents/MacOS/SkyComputerUseService \
  --register-capability
```

The command prints structured JSON and exits with status 78 when registration is unavailable.

Accessibility traversal is bounded to 12 levels and 1,500 elements. Screenshot files are owner-only and stale PNGs older than 24 hours are removed when the next capture runs.

Capture Stream sessions continuously poll fresh AX and screenshot state and emit only changed
`metadata`, `axText`, or `screenshot` updates. `completed` is reserved for turn transition/end or an
explicit App stop/deactivation; producer errors use the official `failed` update and reason enum.
Each session belongs to the socket connection or native sender that started it. A disconnected
socket drops its sessions immediately, service shutdown wakes blocked consumers, Next requests
honor their request deadline, and their long polls do not serialize unrelated RPCs. Queues retain
at most 32 updates and coalesce by update type under backpressure.

Event Stream implements the official `ComputerUseIPCEventStreamStartRequest`, status request, and
reasoned stop request. Recording is explicit and requires Input Monitoring; it never prompts or
changes macOS consent. A session lasts at most 30 minutes and writes owner-only `events.jsonl`,
`suppressed.jsonl`, and `metadata.json` files below the socket directory's `EventStreams` folder.
The shared session Event Tap records mouse clicks/context menus/drags and keyboard text, submit, and
shortcut events; periodic AX snapshots add `window.changed` full/diff context, selection changes,
and bounded Terminal value deltas. Turn end, client disconnect, lock screen, explicit stop, timeout,
and service shutdown all close the files with a terminal session record. Secure Input, secure text
fields, security/password apps, ChatGPT/Codex, and this service are excluded from the ordinary log;
their structural records go to the suppressed log only after text/value/URL fields are removed.
Both logs also scrub common password/token/API-key forms before bytes are written.

Turn lifecycle is delivered as one ordered state machine. Start, transition, explicit end, lock,
and user intervention revoke virtual/remote cursor state, stale state-query authorization, App
session state, Capture Stream, Event Stream, and native PIP before any conservative focus restore.
Lock/intervention safety termination never activates a restore target, and delayed cursor callbacks
are generation-cancelled so an old turn cannot redraw after the boundary.

Every action requires a successful `getAppState` for the same bundle ID and process ID within the previous five minutes. Element targets resolve only IDs from that latest snapshot. If the referenced AX object was destroyed by a window/menu rebuild, the service recaptures the tree and accepts only a unique path-and-semantics match; ambiguous, missing, or weak unlabeled matches fail closed. Screenshot coordinates are mapped through the captured window origin and image scale, including Retina screenshots, and fail closed when stale or outside the image. `pressKey` supports common X11 keysym-style chords used by the official client; `typeText` accepts at most 10,000 UTF-16 code units per request. Scroll accepts every finite positive page count; element scrolling prefers AX page actions, while unsupported and fractional movement uses bounded pixel-wheel events.

## Security boundary

New socket directories and the socket itself are owner-only. Existing parent-directory permissions are never modified. An accepted connection receives only the compatibility `ping` before code-signature validation. No app data or action request is served until the direct peer, parent, and grandparent have passed the configured OpenAI signature and executable-identifier checks.

The protocol and signing assumptions can change whenever the Codex app updates. Keep the service opt-in until each supported app build has been tested.
