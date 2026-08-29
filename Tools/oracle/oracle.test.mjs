import assert from "node:assert/strict";
import test from "node:test";
import { compareTraces } from "./compare-traces.mjs";
import { oracleCases } from "./cases.mjs";
import { runCases } from "./run-cases.mjs";

test("manifest covers every public window operation", () => {
  const operations = new Set(oracleCases.map((item) => item.operation));
  assert.deepEqual(
    [...operations].sort(),
    [
      "click", "drag", "get_app_state", "list_apps", "paste",
      "perform_secondary_action", "press_key", "scroll", "select_text",
      "set_value", "type_text",
    ],
  );
});

test("safe default invokes only list_apps", async () => {
  const calls = [];
  const trace = await runCases({
    sky: { async list_apps() { calls.push("list_apps"); return [{ id: "B" }, { id: "A" }]; } },
    label: "fake",
  });
  assert.deepEqual(calls, ["list_apps"]);
  assert.equal(trace.cases[0].outcome.status, "success");
});

test("authorization and mutation gates fail before invoking sky", async () => {
  await assert.rejects(
    runCases({ sky: {}, label: "fake", caseIds: ["get_app_state.full"], fixtures: { APP: "X" } }),
    /authorization prompt/,
  );
  await assert.rejects(
    runCases({
      sky: {}, label: "fake", caseIds: ["click.coordinate"],
      fixtures: { APP: "X", X: 1, Y: 2 }, allowTargetAuthorization: true,
    }),
    /allowMutating/,
  );
});

test("comparator ignores volatile metadata and app order", () => {
  const reference = {
    schemaVersion: 1, label: "arm", startedAt: "2026-01-01T00:00:00Z",
    cases: [{
      id: "list_apps", operation: "list_apps", elapsedMilliseconds: 2,
      outcome: { status: "success", result: [{ id: "B" }, { id: "A" }] },
    }],
  };
  const candidate = {
    schemaVersion: 1, label: "intel", startedAt: "2026-02-02T00:00:00Z",
    cases: [{
      id: "list_apps", operation: "list_apps", elapsedMilliseconds: 900,
      outcome: { status: "success", result: [{ id: "A" }, { id: "B" }] },
    }],
  };
  assert.equal(compareTraces(reference, candidate).summary.differences, 0);
});

test("comparator preserves semantic differences", () => {
  const base = { schemaVersion: 1, label: "arm", cases: [] };
  const reference = {
    ...base,
    cases: [{ id: "press_key.chord", outcome: { status: "error", error: { code: -10014 } } }],
  };
  const candidate = {
    ...base, label: "intel",
    cases: [{ id: "press_key.chord", outcome: { status: "error", error: { code: -10015 } } }],
  };
  const report = compareTraces(reference, candidate);
  assert.equal(report.summary.differences, 1);
  assert.equal(report.cases[0].status, "different");
});

