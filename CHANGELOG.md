# Changelog

## 0.2.0 — 2026-09-13

Breaking release for the plugin-based ChatGPT/Codex Computer Use runtime.

- Adds the `intel-sky-computer-use@personal` plugin and exposes one `intel_sky_cua` entry for
  browser and native macOS control.
- Leaves the Codex-reserved `cua_repl` entry untouched and removes only legacy `intel_sky_repl`
  registrations known to be managed by Intel Sky.
- Accepts bounded, signed Bridge ancestry between Codex and ChatGPT without maintaining a Bridge
  product-name allowlist.
- Requires ChatGPT `26.908.40834` / Codex CLI `0.154.0-alpha.6.2` or a compatible plugin-based
  generation. It is not an in-place binary replacement for v0.1.0.
- Requires rerunning `Scripts/install-managed-service.sh`, completely restarting ChatGPT, and
  starting a new Codex session.

## 0.1.0 — 2026-09-12

Initial tagged release for the legacy global `node_repl` and injected Computer Use skill path,
verified against ChatGPT `26.825.41651`.
