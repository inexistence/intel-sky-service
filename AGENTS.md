# Repository Instructions

## macOS code signing and deployment

- Run code-signing identity checks, signed release builds, and deployment from the logged-in
  user's host environment, not from the Codex filesystem/process sandbox.
- Treat `security find-identity -v -p codesigning` results obtained inside a sandbox as
  non-authoritative. A sandbox can hide an otherwise valid identity in the user's keychain.
- Read the preferred identity from `CODESIGN_IDENTITY`, or from the Git-ignored
  `.codesign-identity` file when the environment variable is unset. Do not put a personal signing
  identity in tracked files.
- If an identity is configured, verify it in the host environment before building. If no identity
  is configured, or the configured identity is unavailable, `Scripts/build-app.sh` uses ad-hoc
  signing. Ad-hoc builds are valid installation and deployment inputs for this project.
- Use a stable signing identity for installed builds. Rebuilding with ad-hoc signing can change the
  app's code identity and cause macOS to revoke or re-request Accessibility, Screen Recording, and
  Input Monitoring permissions.
- Pass a verified identity through `CODESIGN_IDENTITY` or the local identity file when stable code
  identity is required, and verify the resulting signature before deployment.
