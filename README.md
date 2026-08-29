# intel-sky-service

An experimental, clean-room compatibility service for the local macOS IPC used by the bundled `@oai/sky` client. The immediate goal is to restore a small, auditable subset of Codex Computer Use on Intel Macs.

This is not an OpenAI product. The protocol is undocumented; compatibility is based on observing the locally installed client. The implementation does not use an API key or send requests to an external model service.

## Current milestone

- `CodexComputerUseIPC-5`
- JSON-RPC 2.0 over a Unix domain socket
- 4-byte little-endian length prefix with an 8 MiB limit
- immediate `ping` response
- peer validation after `ping`: same macOS user and the signed OpenAI chain `node_repl → codex → com.openai.codex`
- read-only `ComputerUseIPCListAppsRequest` backed by `NSWorkspace`
- read-only `ComputerUseIPCAppGetSkyshotRequest` with a bounded Accessibility tree and focused-window PNG
- latest-snapshot element cache keyed by bundle ID and PID, with a five-minute TTL and 16-app limit
- `ComputerUseIPCAppPolicyRequest`, preserving the official JavaScript approval flow
- snapshot-bound `ComputerUseIPCAppPerformActionRequest` clicks by element ID or absolute coordinate

Keyboard input, scrolling, persistence, installers, and launch agents are not implemented yet. Screenshot and Accessibility permissions are checked but never requested automatically.

## Build and test

```sh
swift test
swift build -c release
```

The service requires an explicit socket path so development cannot silently replace the official endpoint:

```sh
.build/debug/intel-sky-service --socket /tmp/intel-sky-service/computeruse.sock
```

In another terminal, the smoke client verifies framing and `ping`:

```sh
.build/debug/sky-smoke-client /tmp/intel-sky-service/computeruse.sock
```

The smoke client is unsigned, so the service returns `ping` and then rejects its `listApps` request during peer validation. That is expected.

During protocol development, the unmodified bundled `@oai/sky` client from ChatGPT `26.825.41651` successfully completed the IPC-5 handshake, returned the local app list, and captured Finder state on x86_64. The production peer policy additionally requires the real `node_repl → codex → com.openai.codex` process chain; launching ChatGPT's signed Node binary from a shell is intentionally rejected.

## Permissions

`getAppState` requires Accessibility permission. A screenshot is included only when Screen Recording permission is already available. The service deliberately avoids calling the APIs that trigger permission prompts; grant access manually to the final signed app or executable used to run the service.

Accessibility traversal is bounded to 12 levels and 1,500 elements. Screenshot files are owner-only and stale PNGs older than 24 hours are removed when the next capture runs.

Click actions require a successful `getAppState` for the same bundle ID and process ID within the previous five minutes. Element clicks resolve only IDs from that latest snapshot. Coordinate clicks are also snapshot-bound, and no event is posted unless the target application becomes active.

## Security boundary

New socket directories and the socket itself are owner-only. Existing parent-directory permissions are never modified. An accepted connection receives only the compatibility `ping` before code-signature validation. No app data or action request is served until the direct peer, parent, and grandparent have passed the configured OpenAI signature and executable-identifier checks.

The protocol and signing assumptions can change whenever the Codex app updates. Keep the service opt-in until each supported app build has been tested.
