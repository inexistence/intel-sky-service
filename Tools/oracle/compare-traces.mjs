import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:/;
const DATA_IMAGE = /^data:image\/(?:png|jpeg);base64,/;

function normalized(value, key = "") {
  if (Array.isArray(value)) {
    const items = value.map((item) => normalized(item));
    if (items.every((item) => item && typeof item === "object" && typeof item.id === "string")) {
      return items.sort((left, right) => left.id.localeCompare(right.id));
    }
    return items;
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([itemKey]) => !["startedAt", "completedAt", "elapsedMilliseconds"].includes(itemKey))
        .map(([itemKey, item]) => [itemKey, normalized(item, itemKey)]),
    );
  }
  if (typeof value === "string" && DATA_IMAGE.test(value)) return "<image-data-url>";
  if (typeof value === "string" && ISO_DATE.test(value)) return "<iso-date>";
  if (key === "lastUsedDate") return value == null ? value : "<iso-date>";
  if (["pid", "processId", "processID"].includes(key) && typeof value === "number") return "<pid>";
  return value;
}

export function normalizeTrace(trace) {
  return normalized({ schemaVersion: trace.schemaVersion, cases: trace.cases });
}

export function compareTraces(reference, candidate) {
  const left = normalizeTrace(reference);
  const right = normalizeTrace(candidate);
  const referenceCases = new Map(left.cases.map((item) => [item.id, item]));
  const candidateCases = new Map(right.cases.map((item) => [item.id, item]));
  const ids = [...new Set([...referenceCases.keys(), ...candidateCases.keys()])].sort();
  const cases = ids.map((id) => {
    const referenceCase = referenceCases.get(id);
    const candidateCase = candidateCases.get(id);
    if (!referenceCase) return { id, status: "candidate_only", candidate: candidateCase };
    if (!candidateCase) return { id, status: "reference_only", reference: referenceCase };
    if (JSON.stringify(referenceCase) === JSON.stringify(candidateCase)) return { id, status: "match" };
    return { id, status: "different", reference: referenceCase, candidate: candidateCase };
  });
  return {
    schemaVersion: 1,
    referenceLabel: reference.label,
    candidateLabel: candidate.label,
    summary: {
      total: cases.length,
      matches: cases.filter((item) => item.status === "match").length,
      differences: cases.filter((item) => item.status !== "match").length,
    },
    cases,
  };
}

function main(argv) {
  if (argv.length !== 2) {
    console.error("usage: node compare-traces.mjs REFERENCE.json CANDIDATE.json");
    return 2;
  }
  const [referencePath, candidatePath] = argv;
  const reference = JSON.parse(fs.readFileSync(referencePath, "utf8"));
  const candidate = JSON.parse(fs.readFileSync(candidatePath, "utf8"));
  const report = compareTraces(reference, candidate);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return report.summary.differences === 0 ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}

