import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const catalogPath = resolve(repositoryRoot, "ProtocolCatalog.md");
const protocolSourcePath = resolve(repositoryRoot, "Sources/IntelSkyCore/SkyProtocol.swift");
const nativeBridgePath = resolve(
  repositoryRoot,
  "Sources/IntelSkyCore/ComputerUseNativeBridge.swift",
);
const metadataToolPath = resolve(repositoryRoot, "Tools/reverse/swift-field-metadata.mjs");
const defaultARMBinary =
  "/Volumes/ChatGPT Installer/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/" +
  "@oai/sky/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService";

const catalog = readFileSync(catalogPath, "utf8");
const protocolSource = readFileSync(protocolSourcePath, "utf8");
const nativeBridgeSource = readFileSync(nativeBridgePath, "utf8");
const staticOnlyRequests = new Set(["ComputerUseIPCAppUsageRequest"]);

function requestRows() {
  return catalog
    .split("\n")
    .flatMap((line) => {
      const match = line.match(
        /^\| `(ComputerUseIPC[A-Za-z0-9]+Request)` \|.*\| (IMPLEMENTED|OUT_OF_SCOPE) \|$/,
      );
      if (!match) return [];
      const fieldMatch = line.match(
        /^\| `ComputerUseIPC[A-Za-z0-9]+Request` \| (empty|`([^`]*)`)/,
      );
      assert.ok(fieldMatch, `request row has no machine-readable field cell: ${line}`);
      return [{
        name: match[1],
        status: match[2],
        fields: fieldMatch[1] === "empty" ? [] : fieldMatch[2].split(","),
        line,
      }];
    });
}

function swiftSet(name) {
  const match = protocolSource.match(
    new RegExp(`public static let ${name}: Set<String> = \\[([\\s\\S]*?)\\n  \\]`),
  );
  assert.ok(match, `missing Swift request set ${name}`);
  return new Set([...match[1].matchAll(/"(ComputerUseIPC[A-Za-z0-9]+Request)"/g)].map((item) => item[1]));
}

function switchRequestCases(source) {
  return new Set(
    [...source.matchAll(/case "(ComputerUseIPC[A-Za-z0-9]+Request)"/g)].map(
      (match) => match[1],
    ),
  );
}

function sorted(values) {
  return [...values].sort();
}

test("protocol catalog exactly partitions implemented and out-of-scope requests", () => {
  const rows = requestRows();
  const implemented = swiftSet("implementedRequestTypes");
  const outOfScope = swiftSet("outOfScopeRequestTypes");
  const documented = new Set(rows.map((row) => row.name));

  assert.equal(rows.length, 35);
  assert.equal(documented.size, 35, "protocol catalog contains duplicate request rows");
  assert.deepEqual(
    sorted(new Set([...implemented, ...outOfScope])),
    sorted(documented),
    "Swift request sets and protocol catalog differ",
  );
  assert.deepEqual(
    sorted(rows.filter((row) => row.status === "IMPLEMENTED").map((row) => row.name)),
    sorted(implemented),
  );
  assert.deepEqual(
    sorted(rows.filter((row) => row.status === "OUT_OF_SCOPE").map((row) => row.name)),
    sorted(outOfScope),
  );
});

test("implemented request set matches router dispatch", () => {
  assert.deepEqual(
    sorted(swiftSet("implementedRequestTypes")),
    sorted(switchRequestCases(protocolSource)),
  );
});

test("catalog marks exactly the authenticated Intel Apple Event request surface", () => {
  const documentedAppleEvents = new Set(
    requestRows()
      .filter((row) => /\| S, AE(?:,| \|)/.test(row.line))
      .map((row) => row.name),
  );
  assert.deepEqual(sorted(documentedAppleEvents), sorted(switchRequestCases(nativeBridgeSource)));
});

test("catalog matches ARM field metadata when the reference binary is available", (context) => {
  const binaryPath = process.env.ARM_SKY_BINARY || defaultARMBinary;
  if (!existsSync(binaryPath)) {
    context.skip(`ARM reference binary is unavailable at ${binaryPath}`);
    return;
  }
  const extraction = spawnSync(process.execPath, [metadataToolPath, binaryPath, "ComputerUseIPC"], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  assert.equal(extraction.status, 0, extraction.stderr);
  const armRequests = new Map(
    JSON.parse(extraction.stdout)
      .map((descriptor) => [
        descriptor.typeName?.split(".").at(-1),
        descriptor.fields.map((field) => field.name),
      ])
      .filter(([name]) => name?.startsWith("ComputerUseIPC") && name.endsWith("Request")),
  );
  const rows = requestRows();
  const metadataRequests = rows.filter((row) => !staticOnlyRequests.has(row.name));
  assert.deepEqual(
    sorted(armRequests.keys()),
    sorted(new Set(metadataRequests.map((row) => row.name))),
  );
  const binary = readFileSync(binaryPath);
  for (const request of staticOnlyRequests) {
    assert.ok(binary.includes(Buffer.from(request)), `${request} is absent from ARM binary strings`);
  }
  for (const row of metadataRequests) {
    assert.deepEqual(row.fields, armRequests.get(row.name), `${row.name} field metadata differs`);
  }
});
