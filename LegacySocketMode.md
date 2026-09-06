# Legacy socket-only mode

The socket-only LaunchAgent mode is deprecated. New installations should use the
[ChatGPT-managed service](README.md#quick-start), which supports native PIP and follows ChatGPT's
managed-service lifecycle.

Keep this mode only for isolated socket development or compatibility testing without native PIP.
Do not run it while the ChatGPT-managed service is active: both modes use the same Unix socket,
while only the ChatGPT-managed process can rendezvous with the native PIP host.

## Install

Build the App, then install the legacy LaunchAgent:

```sh
Scripts/build-app.sh
Scripts/install-launch-agent.sh
```

The installer places the App at:

```text
~/Applications/Intel Sky Service.app
```

It also installs the per-user LaunchAgent
`~/Library/LaunchAgents/dev.huangjianbin.intel-sky-service.plist`. The service starts with
`--disable-pip`, uses its own bundle identity, and neither impersonates
`com.openai.sky.CUAService` nor requests OpenAI's application-group entitlement.

Grant Accessibility, Screen & System Audio Recording, and Input Monitoring to the legacy App,
then restart the agent if needed:

```sh
launchctl kickstart -k "gui/$UID/dev.huangjianbin.intel-sky-service"
```

## Return to the recommended mode

Run the managed-service installer:

```sh
Scripts/install-managed-service.sh
```

It stops the legacy LaunchAgent and preserves its plist as a timestamped disabled backup before
installing the recommended service. Follow the permission and restart steps in the
[README](README.md#2-grant-permissions-and-restart-chatgpt).
