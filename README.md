# intel-sky-service

An experimental, clean-room compatibility service that restores the public Codex Computer Use
window API on Intel Macs. It implements the local macOS IPC used by the `@oai/sky` client bundled
with ChatGPT, without modifying or re-signing ChatGPT or Codex.

This is not an OpenAI product. The protocol is undocumented and compatibility is based on
observing the locally installed client. The service does not use an API key or send requests to an
external model service.

## Compatibility

Version 0.2.0 is a breaking release. It replaces the legacy global `node_repl` and injected-skill
discovery path with a Codex plugin that exposes the collision-free `intel_sky_cua` tool. Service
and ChatGPT/Codex generations must not be mixed:

| Intel Sky | ChatGPT/Codex generation | Status |
| --- | --- | --- |
| `v0.1.0` | Legacy baseline (`26.825.41651`) | Supported baseline |
| `v0.1.0` | Plugin-based builds (`26.908.40834` and later) | Unsupported |
| `v0.2.0` | Legacy baseline (`26.825.41651`) | Unsupported |
| `v0.2.0` | Plugin-based baseline (`26.908.40834`) | Supported baseline |

“Unsupported” means the installation and capability-discovery contracts are incompatible, even
where the underlying IPC request format overlaps. Do not copy only the service executable between
these releases.

Version 0.2.0 was verified on an Intel Mac on 2026-09-13:

| Component | Verified value |
| --- | --- |
| Intel Sky Service | `0.2.0` (build `2`) |
| ChatGPT App | `26.908.40834` |
| ChatGPT build | `8881` |
| Codex CLI | `0.154.0-alpha.6.2` |
| Computer Use protocol | `CodexComputerUseIPC-5` |
| `@oai/cua-repl` | `0.1.0` |
| `@oai/sky` | `0.6.32` |
| Bundled Node.js | `24.20.0` |
| Platform | `darwin-x64`, macOS 14 or newer |

This is a tested baseline, not a promise that later ChatGPT builds are compatible. After every
ChatGPT update, rerun the compatibility audit before reinstalling or using native PIP:

```sh
Scripts/audit-pip-host.sh
```

The audit fails closed if the Intel host architecture, OpenAI signing team, or required XPC
selectors change.

### Upgrading from v0.1.0

Do not replace the App bundle manually. From the v0.2.0 checkout, run the installer again:

```sh
Scripts/install-managed-service.sh
```

The installer builds and signs the new App, installs `intel-sky-computer-use@personal`, removes a
managed legacy `intel_sky_repl` registration, disables the old LaunchAgent when present, and keeps
timestamped rollback copies. Completely quit and reopen ChatGPT afterward, then start a new Codex
session; existing sessions keep their original tool set.

If the installed ChatGPT App does not provide the `codex plugin` command, remain on the `v0.1.0`
tag. Version 0.2.0 does not automatically fall back to the v0.1.0 installation contract.

## Quick start

### 1. Install

From a source checkout, run:

```sh
Scripts/install-managed-service.sh
```

With no explicit App argument, the installer always rebuilds the signed x86_64 App from the current
source so an older `dist` bundle cannot be installed accidentally. It then audits the bundled Intel
PIP host, disables the legacy LaunchAgent if present, and installs the service at ChatGPT's
canonical location:

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
- `computerUseCapability.unifiedComputerUseEnabled`

Start a **new Codex session** after restarting ChatGPT. Existing sessions retain the tool set they
had when they were created. In the new session, ask naturally—for example:

> 打开备忘录并新建一条笔记。

You do not need to mention MCP, `node_repl`, `@oai/sky`, or the Unix socket.

## Capability discovery

The installer verifies the ChatGPT-bundled `node_repl`, Node.js, and `@oai/sky` runtime. Current
ChatGPT builds may create and rewrite a reserved global `cua_repl` placeholder. Intel Sky leaves
that entry under ChatGPT's control and exposes the collision-free `intel_sky_cua` plugin server,
using the bundled runtime with the `browser,computer` surfaces and both browser and `sky` trusted
services. The service accepts
both the legacy `node_repl → codex → ChatGPT` process chain and the current
`node_repl → cua-repl node → codex → … → ChatGPT` chain. The bundled runtime and Codex processes
must carry OpenAI's signature; any intervening Bridge processes may have arbitrary names but must
be signed by either OpenAI or the same Apple Developer Team as the installed Intel Sky service.
Every accepted chain must terminate at the OpenAI-signed ChatGPT host within a bounded depth.

Registration is idempotent. The installer installs the local
`intel-sky-computer-use@personal` plugin, disables the bundled browser-only
`unified-computer-use` plugin, and removes the obsolete `intel_sky_repl` MCP registration. The local
plugin supplies native macOS routing instructions and exposes one enabled `intel_sky_cua` server
with both browser and native macOS surfaces. The reserved `cua_repl` may remain disabled. A custom
legacy `computer-use` skill is preserved.

Recheck registration without reinstalling:

```sh
~/.codex/computer-use/Codex\ Computer\ Use.app/Contents/MacOS/SkyComputerUseService \
  --register-capability
```

The command prints structured JSON and exits with status 78 if registration is unavailable.

When the service is stopped, the unified tool remains discoverable. The official client then
reports a concrete startup or native-pipe error, such as
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
- installs and verifies the `intel_sky_cua` Codex plugin without rewriting the reserved
  `cua_repl` configuration;
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

Like the ARM service, the managed service follows Codex desktop thread-state streams through
`${CODEX_HOME:-~/.codex}/ipc/ipc.sock` (or `SKY_CUA_SERVICE_NATIVE_PIPE_PATH` when set). It
initializes as `Codex AppServer Thread Events`, publishes `thread-stream-following-changed` for each
thread seen in Computer Use metadata, answers following-status requests, and recognizes both ARM
turn-status patch paths. Active follows are repeated after an initialized reconnect. Runtime state
is registered per Codex thread, so completing one
thread revokes only its desktop cursor, PIP, Capture Stream, AX/diff/intervention caches, screenshot
files, status-menu ownership, and focus protection while other active threads continue. The first
scoped turn also revokes any legacy state created without turn metadata. Cleanup does not depend on
whether a turn created a PIP window. The public `ComputerUseIPCCodexTurnEndedRequest` remains
supported as a compatible secondary path; native-host presentation retirement is an additional
authoritative fallback for screenshot-backed turns.

Skyshots always contain the AX text representation, but attach a screenshot only when the recovered
ARM-style classifier finds visual content such as an image, canvas, map, video, web area, or a
custom-drawn window whose sparse unlabeled AX shell cannot represent its visible UI. Since
Remote Hosted PIP is driven by that screenshot attachment, text-only windows do not create an
unnecessary floating preview. Computer Use application-list changes also publish ChatGPT's recovered
status-item distributed-notification envelope so the menu does not retain ended Apps.

Physical user input is attributed per target App using the event target PID, pointer window owner,
or keyboard frontmost App. Input in Codex therefore does not invalidate a different controlled App;
input resolved to the controlled App still cancels the action and requires a fresh state query.

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

The socket-only LaunchAgent mode is deprecated and is not recommended for normal use. It remains
available only for compatibility and isolated development; see
[LegacySocketMode.md](LegacySocketMode.md). Do not run it alongside the ChatGPT-managed service.

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
