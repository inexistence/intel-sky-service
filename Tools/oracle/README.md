# Sky differential oracle harness

This directory records the same high-level `@oai/sky` calls on an official Apple Silicon service
and this Intel service, then compares stable observable results. It deliberately runs through the
unmodified `sky` object inside Codex `node_repl`, preserving the official client, policy checks,
turn metadata, and authenticated process chain.

## Authorization-safe defaults

`runCases()` defaults to `list_apps` only. It cannot target an App unless
`allowTargetAuthorization: true` is passed, and it cannot click, type, scroll, paste, or otherwise
change an App unless `allowMutating: true` is also passed. Only enable those switches while someone
is present to answer the Computer Use authorization UI.

## Capture a trace

In `node_repl`, import the runner by absolute file URL and pass the existing `sky` object:

```js
const oracle = await import("file:///Users/huangjianbin/Desktop/myproject/intel-sky-service/Tools/oracle/run-cases.mjs");
const trace = await oracle.runCases({ sky, label: "intel-local" });
oracle.traceToJSON(trace)
```

Run the same call on Apple Silicon with label `arm64-official`. For an explicitly approved target,
select case IDs and fixtures:

```js
const trace = await oracle.runCases({
  sky,
  label: "arm64-official",
  caseIds: ["get_app_state.full"],
  fixtures: { APP: "com.apple.calculator" },
  allowTargetAuthorization: true,
});
```

Mutation cases additionally require `allowMutating: true`. Their coordinates and element indices
must come from a fresh state capture on the same target and should use a disposable fixture
document or deterministic test App.

`get_app_state.forbidden_target` records the policy-wrapper behavior for a known forbidden target.
It still requires `allowTargetAuthorization: true`: if a future runtime classifies the fixture
differently, the harness must not surprise an unattended user with an approval prompt.

Save the returned JSON on each machine and compare it:

```sh
node Tools/oracle/compare-traces.mjs arm64-official.json intel-local.json
```

The command exits 0 for a match and 1 for any missing or different case. It normalizes timestamps,
durations, screenshot data, PIDs, and App-list ordering while retaining operation results and error
codes. Raw traces remain the source evidence when a normalized result differs.

Run the harness's non-GUI regression tests with:

```sh
node --test Tools/oracle/oracle.test.mjs
```
