#!/usr/bin/env node

import { execFileSync } from "node:child_process";

ignoreClosedOutputPipe();

const [binary, start, end] = process.argv.slice(2);
if (!binary || !start || !end) {
  console.error("usage: annotate-otool-stubs.mjs <mach-o> <start-address> <end-address>");
  process.exit(2);
}

const run = (args) => execFileSync(args[0], args.slice(1), {
  encoding: "utf8",
  maxBuffer: 256 * 1024 * 1024,
});

const fixups = run(["dyld_info", "-fixups", binary]);
const symbolByPointer = new Map();
for (const line of fixups.split("\n")) {
  const match = line.match(/\b(0x[0-9A-Fa-f]+)\s+bind\s+\S+\/(.+)$/);
  if (match) symbolByPointer.set(BigInt(match[1]), match[2]);
}

const stubs = run(["otool", "-v", "-s", "__TEXT", "__stubs", binary]);
const symbolByStub = new Map();
const lines = stubs.split("\n");
for (let index = 0; index + 1 < lines.length; index += 1) {
  const address = lines[index].match(/^([0-9a-f]{16})\s+adrp\s+x16,.*;\s+(0x[0-9a-f]+)/i);
  const load = lines[index + 1].match(/^([0-9a-f]{16})\s+ldr\s+x16,\s+\[x16,\s+#(0x[0-9a-f]+)\]/i);
  if (!address || !load) continue;
  const stubAddress = BigInt(`0x${address[1]}`);
  const pointerAddress = BigInt(address[2]) + BigInt(load[2]);
  const symbol = symbolByPointer.get(pointerAddress);
  if (symbol) symbolByStub.set(stubAddress, symbol);
}

const disassembly = run(["otool", "-tvV", binary]);
const lower = BigInt(start);
const upper = BigInt(end);
for (const line of disassembly.split("\n")) {
  const address = line.match(/^([0-9a-f]{16})\b/i);
  if (!address) continue;
  const value = BigInt(`0x${address[1]}`);
  if (value < lower || value >= upper) continue;
  const branch = line.match(/\bbl\s+(0x[0-9a-f]+)/i);
  const symbol = branch ? symbolByStub.get(BigInt(branch[1])) : undefined;
  process.stdout.write(symbol ? `${line} ; ${symbol}\n` : `${line}\n`);
}

function ignoreClosedOutputPipe() {
  process.stdout.on("error", (error) => {
    if (error.code === "EPIPE") process.exit(0);
    throw error;
  });
}
