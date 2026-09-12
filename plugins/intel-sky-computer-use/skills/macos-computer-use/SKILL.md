---
name: macos-computer-use
description: Control websites, browsers, and native macOS applications through Computer Use. Use for Notes or 备忘录, Finder, System Settings, Mail, Calendar, and other visible desktop or browser UI tasks on this Intel Mac.
---

# macOS Computer Use

Use the single `intel_sky_cua` MCP entry for both browser and native macOS UI work. Codex reserves
the separate `cua_repl` name and may keep it disabled; do not use or enable that reserved entry.
The bundled runtime may refer to itself as `cua_repl` in its generated documentation. Treat that
wording only as the internal JavaScript runtime name; invoke tools only from the `intel_sky_cua`
MCP namespace.

- Call `cua.getState()` first, unless continuing an initialized Computer Use session.
- For a native app, select it with `cua.getApp(...)`; for browser work, use the matching browser or tab API.
- Do not search for another Computer Use MCP when the requested native app is absent. Report the missing app or service state because `intel_sky_cua` is the authoritative local entry.
- Preserve the requested application. Do not substitute browser automation for a native-app request unless the user asks for that fallback.
- Follow the confirmation and privacy rules returned by the Computer Use runtime.
