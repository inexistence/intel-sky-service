import { oracleCases } from "./cases.mjs";

function materialize(value, fixtures) {
  if (Array.isArray(value)) return value.map((item) => materialize(item, fixtures));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, materialize(item, fixtures)]),
    );
  }
  if (typeof value !== "string") return value;
  const match = /^\$\{([A-Z0-9_]+)\}$/.exec(value);
  if (!match) return value;
  if (!(match[1] in fixtures)) throw new Error(`missing fixture ${match[1]}`);
  return fixtures[match[1]];
}

function serializeError(error) {
  if (!(error instanceof Error)) return { name: "ThrownValue", message: String(error) };
  const result = { name: error.name, message: error.message };
  for (const key of ["code", "cause", "requestType"]) {
    if (error[key] !== undefined) result[key] = error[key];
  }
  return result;
}

function assertAllowed(testCase, options) {
  if (testCase.risk === "target_authorization" && !options.allowTargetAuthorization) {
    throw new Error(
      `${testCase.id} may display a target-App authorization prompt; ` +
      "pass allowTargetAuthorization: true while present at the Mac",
    );
  }
  if (testCase.risk === "mutating" && !options.allowMutating) {
    throw new Error(`${testCase.id} changes the target App; pass allowMutating: true`);
  }
  if (testCase.risk === "mutating" && !options.allowTargetAuthorization) {
    throw new Error(
      `${testCase.id} may display a target-App authorization prompt; ` +
      "pass allowTargetAuthorization: true while present at the Mac",
    );
  }
}

/**
 * Runs selected cases through the exact `sky` object supplied by node_repl.
 * It performs no filesystem writes and defaults to the non-interactive list_apps case.
 */
export async function runCases({
  sky,
  label,
  caseIds = ["list_apps"],
  fixtures = {},
  allowTargetAuthorization = false,
  allowMutating = false,
  cases = oracleCases,
  now = () => new Date(),
  monotonicNow = () => performance.now(),
} = {}) {
  if (!sky || typeof sky !== "object") throw new TypeError("sky client object is required");
  if (!label) throw new TypeError("label is required (for example arm64-official or intel-local)");

  const byId = new Map(cases.map((testCase) => [testCase.id, testCase]));
  const selected = caseIds.map((id) => {
    const testCase = byId.get(id);
    if (!testCase) throw new Error(`unknown oracle case ${id}`);
    assertAllowed(testCase, { allowTargetAuthorization, allowMutating });
    return testCase;
  });

  const trace = {
    schemaVersion: 1,
    label,
    environment: {
      architecture: typeof process === "undefined" ? "unknown" : process.arch,
      platform: typeof process === "undefined" ? "unknown" : process.platform,
    },
    startedAt: now().toISOString(),
    cases: [],
  };

  for (const testCase of selected) {
    const startedAt = now().toISOString();
    const start = monotonicNow();
    let input;
    try {
      input = materialize(testCase.input, fixtures);
      const method = sky[testCase.operation];
      if (typeof method !== "function") throw new Error(`sky.${testCase.operation} is unavailable`);
      const result = input === null ? await method.call(sky) : await method.call(sky, input);
      trace.cases.push({
        id: testCase.id,
        operation: testCase.operation,
        risk: testCase.risk,
        input,
        startedAt,
        elapsedMilliseconds: monotonicNow() - start,
        outcome: { status: "success", result: result ?? null },
      });
    } catch (error) {
      trace.cases.push({
        id: testCase.id,
        operation: testCase.operation,
        risk: testCase.risk,
        input: input ?? testCase.input,
        startedAt,
        elapsedMilliseconds: monotonicNow() - start,
        outcome: { status: "error", error: serializeError(error) },
      });
    }
  }
  trace.completedAt = now().toISOString();
  return trace;
}

export function traceToJSON(trace) {
  return JSON.stringify(trace, null, 2);
}

