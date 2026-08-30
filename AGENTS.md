# Repository Instructions

## macOS code signing and deployment

- Run code-signing identity checks, signed release builds, and deployment from the logged-in
  user's host environment, not from the Codex filesystem/process sandbox.
- Treat `security find-identity -v -p codesigning` results obtained inside a sandbox as
  non-authoritative. A sandbox can hide an otherwise valid identity in the user's keychain.
- Before a signed build, verify the expected identity in the host environment. For this project the
  expected identity is currently `Apple Development: 510229374@qq.com (YP98F3PUMT)`.
- If the expected identity is unavailable in the host environment, stop and report the problem.
  Do not silently fall back to ad-hoc signing for a build that will be installed or deployed unless
  the user explicitly authorizes that fallback.
- Use a stable signing identity for installed builds. Rebuilding with ad-hoc signing can change the
  app's code identity and cause macOS to revoke or re-request Accessibility, Screen Recording, and
  Input Monitoring permissions.
- Pass the verified identity explicitly when building, for example through `CODESIGN_IDENTITY`, and
  verify the resulting signature before deployment.
