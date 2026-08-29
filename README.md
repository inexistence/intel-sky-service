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
- latest-snapshot element cache keyed by bundle ID and PID, with a five-minute TTL and 16-app limit
- `ComputerUseIPCAppPolicyRequest`, preserving the official JavaScript approval flow
- snapshot-bound `ComputerUseIPCAppPerformActionRequest` clicks by element ID or screenshot coordinate, using `AXPress` before physical fallback
- snapshot-bound, PID/window-targeted `pressKey` chords and bounded Unicode `typeText` input
- snapshot-bound vertical and horizontal scrolling, with AX page actions and bounded pixel fallback
- all eleven public APIs: `list_apps`, `get_app_state`, `click`, `drag`, `paste`, `perform_secondary_action`, `press_key`, `scroll`, `select_text`, `set_value`, and `type_text`
- signed x86_64 App bundle and per-user LaunchAgent installer

The eleven public `@oai/sky` APIs are implemented, including physical-input interruption, lock/secure-input checks, loading-aware settling, PID/window-targeted synthetic input that does not foreground the target, an input-transparent software cursor, turn tracking, and conservative focus restoration. The hidden Appshot Apple Event bridge and an experimental native Codex PIP path are also implemented: the service can rendezvous with Intel `sky.node`, publish a real CAContext, continuously feed the target window through ScreenCaptureKit and `AVSampleBufferDisplayLayer`, follow target-window replacement and resize through fenced host operations, recover from bounded capture failures, retain state snapshots as a fallback, forward cursor state, and end capture with its turn. Exact ARM focus/capture lifetimes and long-run resilience remain active compatibility work. See `OfficialBehaviorNotes.md` for the evidence ledger and known differences.

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

## App bundle and launch agent

Build an x86_64 background App bundle:

```sh
Scripts/build-app.sh
```

The script prefers `Apple Development: 510229374@qq.com (YP98F3PUMT)` and falls back to ad-hoc signing only when that identity is unavailable. A certificate without its matching private key is not a valid signing identity. Set `CODESIGN_IDENTITY` to select another installed identity.

After reviewing the generated App at `dist/Intel Sky Service.app`, install it for the current GUI user:

```sh
Scripts/install-launch-agent.sh
```

The installer copies the App to `~/Applications` and creates the per-user LaunchAgent `dev.huangjianbin.intel-sky-service`. The service uses its own bundle identity; it does not impersonate OpenAI's `com.openai.sky.CUAService` or request OpenAI's application-group entitlement.

After a ChatGPT update, run the read-only native-host compatibility audit before enabling any
future experimental PIP integration:

```sh
Scripts/audit-pip-host.sh
```

It fails closed when the Intel host architecture, OpenAI signing team, or required XPC selectors
change.

The App bundle intentionally installs its executable as `Contents/MacOS/SkyComputerUseService`.
The current ChatGPT managed-service host requires that exact basename. ChatGPT also supports a
startup-only source override named `CODEX_ELECTRON_COMPUTER_USE_APP_PATH`; when set to this App,
ChatGPT copies it into its canonical Codex-home location, starts that exact executable, validates
the resulting PID, and passes the PID to the native PIP host. This variable belongs to the ChatGPT
main process, not to `node_repl` or the Computer Use MCP environment.

Experimental PIP rendezvous remains off by default. A managed service process can inherit
`INTEL_SKY_EXPERIMENTAL_PIP=1` from ChatGPT while compatibility is being tested. Do not enable it
until `Scripts/audit-pip-host.sh` passes for the installed ChatGPT build.

During protocol development, the unmodified bundled `@oai/sky` client from ChatGPT `26.825.41651` successfully completed the IPC-5 handshake, returned the local app list, and captured Finder state on x86_64. The production peer policy additionally requires the real `node_repl → codex → com.openai.codex` process chain; launching ChatGPT's signed Node binary from a shell is intentionally rejected.

## Permissions

`getAppState` requires Accessibility permission. A screenshot is included only when Screen Recording permission is already available. The service deliberately avoids calling the APIs that trigger permission prompts; grant access manually to the final signed app or executable used to run the service.

For the LaunchAgent installation, add `~/Applications/Intel Sky Service.app` in System Settings → Privacy & Security → Accessibility and Screen & System Audio Recording. Restart the agent after changing permissions, then open a new Codex task so Computer Use is discovered against the running socket. Rebuilding an ad-hoc-signed App changes its code identity and may require granting permissions again; a stable Apple Development signature avoids that churn.

When launched as an App, the service asks macOS for either permission if it is missing. Permission prompts are issued by the service process itself so macOS records the correct responsible application identity.

Check permissions for a direct invocation:

```sh
~/Applications/Intel\ Sky\ Service.app/Contents/MacOS/SkyComputerUseService --check-permissions
```

The command returns exit status 0 only when both permissions are granted; otherwise it returns 77 and prints the individual states as JSON. Because macOS can attribute TCC checks to a process's responsible parent, this direct check is not authoritative for a LaunchAgent.

The running service writes its own authoritative startup state to:

```text
~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/service-status.json
```

Restart the LaunchAgent after changing privacy settings, then verify that both permission fields in this owner-only file are `true`.

Accessibility traversal is bounded to 12 levels and 1,500 elements. Screenshot files are owner-only and stale PNGs older than 24 hours are removed when the next capture runs.

Every action requires a successful `getAppState` for the same bundle ID and process ID within the previous five minutes. Element targets resolve only IDs from that latest snapshot. Screenshot coordinates are mapped through the captured window origin and image scale, including Retina screenshots, and fail closed when stale or outside the image. `pressKey` supports common X11 keysym-style chords used by the official client; `typeText` accepts at most 10,000 UTF-16 code units per request. Scroll accepts every finite positive page count; element scrolling prefers AX page actions, while unsupported and fractional movement uses bounded pixel-wheel events.

## Security boundary

New socket directories and the socket itself are owner-only. Existing parent-directory permissions are never modified. An accepted connection receives only the compatibility `ping` before code-signature validation. No app data or action request is served until the direct peer, parent, and grandparent have passed the configured OpenAI signature and executable-identifier checks.

The protocol and signing assumptions can change whenever the Codex app updates. Keep the service opt-in until each supported app build has been tested.
