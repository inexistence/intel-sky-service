# intel-sky-service

An experimental, clean-room compatibility service that restores the public Codex Computer Use
window API on Intel Macs. It implements the local macOS IPC used by the `@oai/sky` client bundled
with ChatGPT, without modifying or re-signing ChatGPT or Codex.

This is not an OpenAI product. The protocol is undocumented and compatibility is based on
observing the locally installed client. The service does not use an API key or send requests to an
external model service.

## Verified compatibility

The following combination was verified on an Intel Mac on 2026-08-31:

| Component | Verified value |
| --- | --- |
| ChatGPT App | `26.825.41651` |
| ChatGPT build | `7345` |
| Codex CLI | `0.151.0-alpha.7.1` |
| Computer Use protocol | `CodexComputerUseIPC-5` |
| CUA runtime | `0.0.9/20260827011019-395ab116910c-pr-1369830` |
| `@oai/sky` | `0.6.24-premerge-pr-1369830-395ab116910c` |
| Bundled Node.js | `24.19.0` |
| Platform | `darwin-x64`, macOS 14 or newer |

This is a tested baseline, not a promise that later ChatGPT builds are compatible. After every
ChatGPT update, rerun the compatibility audit before reinstalling or using native PIP:

```sh
Scripts/audit-pip-host.sh
```

The audit fails closed if the Intel host architecture, OpenAI signing team, or required XPC
selectors change.

## Quick start

### 1. Install

From a source checkout, run:

```sh
Scripts/install-managed-service.sh
```

The installer builds the signed x86_64 App when needed, audits the bundled Intel PIP host, disables
the legacy LaunchAgent if present, and installs the service at ChatGPT's canonical location:

```text
~/.codex/computer-use/Codex Computer Use.app
```

To install a reviewed prebuilt bundle instead:

```sh
Scripts/install-managed-service.sh "/path/to/Intel Sky Service.app"
```

If ChatGPT uses a custom `CODEX_HOME`, run the installer with the same environment value.

### 2. Grant permissions and restart ChatGPT

In System Settings → Privacy & Security, add
`~/.codex/computer-use/Codex Computer Use.app` and enable:

- Accessibility
- Screen & System Audio Recording
- Input Monitoring

Then completely quit ChatGPT and open it again. The installer cannot grant these permissions or
restart ChatGPT for you.

### 3. Verify and start a new session

Check the service-owned health file:

```sh
cat ~/Library/Group\ Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/service-status.json
```

These values should be `true`:

- `permissions.accessibility`
- `permissions.screenRecording`
- `physicalInputMonitoring`
- `focusStealProtection`
- `computerUseCapability.registered`
- `computerUseCapability.skillInjected`

Start a **new Codex session** after restarting ChatGPT. Existing sessions retain the tool set they
had when they were created. In the new session, ask naturally—for example:

> 打开备忘录并新建一条笔记。

You do not need to mention MCP, `node_repl`, `@oai/sky`, or the Unix socket.

## Capability discovery

The installer verifies the ChatGPT-bundled `node_repl`, Node.js, and `@oai/sky` runtime. If the
Codex configuration does not contain `node_repl`, it adds a compatible entry through the bundled
Codex CLI. Existing compatible configuration is preserved; incompatible configuration is reported
and never overwritten.

After the managed service binds its socket, it links the official Computer Use skill into the
cross-client discovery directory:

```text
~/.agents/skills/computer-use -> /Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/docs/skills/oai_sky_lib/macos
```

Registration is idempotent and points directly to the official skill shipped with ChatGPT, so a
later compatible ChatGPT update supplies its updated skill automatically. An existing non-link
`computer-use` skill is treated as a conflict and is not replaced.

Recheck registration without reinstalling:

```sh
~/.codex/computer-use/Codex\ Computer\ Use.app/Contents/MacOS/SkyComputerUseService \
  --register-capability
```

The command prints structured JSON and exits with status 78 if registration is unavailable.

When the service is stopped, the skill and `node_repl` remain discoverable. The official client
then reports a concrete startup or native-pipe error, such as
`Sky Computer Use native pipe startup failed`, instead of making the session conclude that
Computer Use does not exist.

## Installation behavior and rollback

The canonical executable name is required by the current ChatGPT managed-service host:

```text
~/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
```

The installer:

- verifies the App signature and x86_64 architecture;
- preserves an existing managed App as
  `Codex Computer Use.app.backup-YYYYMMDD-HHMMSS`;
- preserves a legacy LaunchAgent as a timestamped disabled plist;
- prepares `node_repl` capability discovery without overwriting an incompatible user entry;
- lets ChatGPT's existing managed-service controller respawn and reconnect PIP after an unexpected
  service exit; the socketless watchdog is active only after ChatGPT authenticates the PIP host;
- never starts or quits ChatGPT.

Do not run the legacy LaunchAgent and ChatGPT-managed service together. Both use the same Unix
socket, while only the ChatGPT-managed PID can rendezvous with the native PIP host.

ChatGPT also supports the startup-only source override
`CODEX_ELECTRON_COMPUTER_USE_APP_PATH`. When set, ChatGPT copies the specified App into the
canonical Codex-home location, starts its `SkyComputerUseService` executable, validates the PID,
and passes it to the native PIP host. This variable belongs to the ChatGPT main process, not to
`node_repl` or the Computer Use MCP environment.

Like the ARM service, the managed service observes Codex App Server `turn/completed` broadcasts
through `${CODEX_HOME:-~/.codex}/ipc/ipc.sock` (or `SKY_CUA_SERVICE_NATIVE_PIPE_PATH` when set).
Runtime state is registered per Codex thread, so completing one thread revokes only its desktop
cursor, PIP, Capture Stream, AX/diff/intervention caches, screenshot files, status-menu ownership,
and focus protection while other active threads continue. The first scoped turn also revokes any
legacy state created without turn metadata. Cleanup does not depend on whether a turn created a PIP
window. The public `ComputerUseIPCCodexTurnEndedRequest` remains supported as a compatible
secondary path.

Skyshots always contain the AX text representation, but attach a screenshot only when the recovered
ARM-style classifier finds visual content such as an image, canvas, map, video, or web area. Since
Remote Hosted PIP is driven by that screenshot attachment, text-only windows do not create an
unnecessary floating preview. Computer Use active/inactive edges also publish ChatGPT's recovered
status-item distributed-notification envelope so the menu does not retain ended Apps.

## Troubleshooting

Check permissions directly:

```sh
~/.codex/computer-use/Codex\ Computer\ Use.app/Contents/MacOS/SkyComputerUseService \
  --check-permissions
```

The command exits with status 0 only when Accessibility and Screen Recording are granted;
otherwise it exits with status 77 and prints each permission state. The running health file is
authoritative because macOS may attribute TCC checks to a process's responsible parent.

Common checks:

| Symptom | Check |
| --- | --- |
| New session has no Computer Use skill | Confirm `computerUseCapability.skillInjected` and the `~/.agents/skills/computer-use` link |
| `node_repl` is unavailable | Run `--register-capability` and inspect its `diagnostic` field |
| Native pipe startup fails | Confirm ChatGPT is running and the health-file PID is current |
| App state has no screenshot | Enable Screen & System Audio Recording for the final installed App |
| Actions are rejected | Fetch fresh app state and confirm Accessibility and Input Monitoring |
| PIP regresses after an update | Run `Scripts/audit-pip-host.sh`; use `--disable-pip` only as a rollback |

Rebuilding an ad-hoc-signed App changes its code identity and may require granting permissions
again. A stable signing identity avoids that churn.

## Development

Run the test suite and build the command-line service:

```sh
swift test
swift build -c release
```

Build a signed x86_64 App bundle:

```sh
Scripts/build-app.sh
```

The build script uses `CODESIGN_IDENTITY` when it is set. For a persistent machine-local default,
put the exact identity name on one line in `.codesign-identity`; that file is ignored by Git. The
environment variable takes precedence over the local file. If neither is configured, or if the
configured identity is unavailable, the script uses ad-hoc signing. Ad-hoc builds can be installed
and deployed, but rebuilding them may cause macOS to request permissions again.

For example:

```sh
security find-identity -v -p codesigning
printf '%s\n' 'Apple Development: Your Name (TEAMID)' > .codesign-identity
```

Set `CODESIGN_IDENTITY_FILE` to use a different local identity file. External distribution should
use a Developer ID Application signature and notarization.

For isolated socket development:

```sh
.build/debug/intel-sky-service --socket /tmp/intel-sky-service/computeruse.sock
```

In another terminal:

```sh
.build/debug/sky-smoke-client /tmp/intel-sky-service/computeruse.sock
```

The smoke client is unsigned. It receives the compatibility `ping` and is then rejected before
`listApps`; that is the expected security result.

The authorization-safe ARM/Intel differential runner is in `Tools/oracle`. Its default case does
not target an App. State capture and mutation cases require separate explicit opt-ins so unattended
runs do not leave unnoticed Computer Use approval prompts.

## Legacy socket-only mode

For development or socket-only compatibility without native PIP:

```sh
Scripts/install-launch-agent.sh
```

This installs `~/Applications/Intel Sky Service.app` and the per-user LaunchAgent
`dev.huangjianbin.intel-sky-service`. It starts with `--disable-pip`, uses its own bundle identity,
and does not impersonate `com.openai.sky.CUAService` or request OpenAI's application-group
entitlement.

Grant the same three permissions to the legacy App and restart the agent. Do not enable this mode
while the recommended ChatGPT-managed service is running.

## Implemented surface

The service implements all eleven public `@oai/sky` APIs:

- `list_apps`
- `get_app_state`
- `click`
- `drag`
- `paste`
- `perform_secondary_action`
- `press_key`
- `scroll`
- `select_text`
- `set_value`
- `type_text`

The implementation includes:

- JSON-RPC 2.0 over an owner-only Unix socket with the `CodexComputerUseIPC-5` framing;
- signed OpenAI process-chain authorization after the compatibility `ping`;
- app discovery, auto-launch, focused-window screenshots, bounded Accessibility trees and diffs;
- snapshot-bound actions, keyboard input, scrolling, text selection, and stale-target rejection;
- Codex app-server organization policy for persistent approval and macOS app allow/deny rules,
  with the same 15-minute successful-result cache and 30-second deadline as the ARM64 service;
- physical-input interruption, screen-lock checks, secure-input handling, and conservative focus
  restoration;
- Capture Stream and Record & Replay Event Stream lifecycle, ownership, bounded backpressure, and
  sensitive-data filtering;
- native remote-hosted PIP with CAContext/IOSurface presentation, live window capture, resize,
  process replacement, reconnect handling, cursor state, and turn-scoped teardown.

For request-by-request coverage, see [ProtocolCatalog.md](ProtocolCatalog.md). For observed official
behavior, evidence, and known differences, see
[OfficialBehaviorNotes.md](OfficialBehaviorNotes.md).

Exact ARM ViewBridge focus/capture callback timing and longer-duration recovery stress remain
active compatibility work. PIP is optional: a PIP failure must not change the underlying Computer
Use request result. Use `--disable-pip` as an explicit rollback switch; `--experimental-pip`
remains accepted as a compatibility alias.

## Runtime and data safety

The service creates its socket directory and socket with owner-only permissions. Existing parent
directory permissions are never modified. An accepted connection receives only `ping` before the
direct peer, parent, and grandparent pass the configured OpenAI signature and executable-identifier
checks.

Every action requires a successful, recent `getAppState` for the same bundle ID and PID. Element
targets must resolve from the latest snapshot; ambiguous, stale, missing, or weak unlabeled targets
fail closed. Screenshot coordinates are mapped through the captured window origin and image scale
and are rejected when stale or outside the image.

Capture and Event Stream files are owner-only. Secure Input, secure text fields,
security/password apps, ChatGPT/Codex, and this service are excluded from ordinary event logs.
Sensitive text/value/URL fields and common password, token, and API-key forms are removed before
bytes are written.

The protocol and signing assumptions can change whenever ChatGPT or Codex updates. Keep the service
opt-in until each target build has passed the compatibility audit and runtime verification.
