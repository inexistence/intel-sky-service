#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

export function parseAsar(bytes) {
  if (bytes.length < 16 || bytes.readUInt32LE(0) !== 4) {
    throw new Error("unsupported ASAR header");
  }
  const headerSize = bytes.readUInt32LE(4);
  const jsonSize = bytes.readUInt32LE(12);
  const jsonEnd = 16 + jsonSize;
  if (jsonEnd > bytes.length || 8 + headerSize > bytes.length) {
    throw new Error("truncated ASAR header");
  }
  const header = JSON.parse(bytes.toString("utf8", 16, jsonEnd));
  return { bytes, contentOffset: 8 + headerSize, header };
}

export function filesInAsar(asar) {
  const files = [];
  visit(asar.header.files, "", files);
  return files;
}

export function fileBytes(asar, entry) {
  if (entry.unpacked) return null;
  const offset = Number(entry.offset);
  const size = Number(entry.size);
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size) || offset < 0 || size < 0) {
    throw new Error(`invalid ASAR file range for ${entry.path}`);
  }
  const start = asar.contentOffset + offset;
  const end = start + size;
  if (end > asar.bytes.length) throw new Error(`truncated ASAR file ${entry.path}`);
  return asar.bytes.subarray(start, end);
}

function visit(entries, parent, output) {
  for (const [name, entry] of Object.entries(entries ?? {})) {
    const path = parent ? `${parent}/${name}` : name;
    if (entry.files) visit(entry.files, path, output);
    if (entry.size !== undefined) output.push({ ...entry, path });
  }
}

function main() {
  const [asarPath, query, rawContext = "320", fileQuery = "", rawMaximumMatches = "200"] =
    process.argv.slice(2);
  if (!asarPath || !query) {
    console.error(
      "usage: asar-search.mjs APP.ASAR REGULAR_EXPRESSION [CONTEXT_CHARACTERS] " +
        "[FILE_REGULAR_EXPRESSION] [MAXIMUM_MATCHES]",
    );
    process.exit(2);
  }
  const context = Number(rawContext);
  if (!Number.isSafeInteger(context) || context < 0 || context > 20_000) {
    throw new Error("context must be an integer from 0 through 20000");
  }
  const maximumMatches = Number(rawMaximumMatches);
  if (!Number.isSafeInteger(maximumMatches) || maximumMatches < 1 || maximumMatches > 10_000) {
    throw new Error("maximum matches must be an integer from 1 through 10000");
  }
  const expression = new RegExp(query, "gi");
  const fileExpression = fileQuery === "" ? null : new RegExp(fileQuery, "i");
  const asar = parseAsar(readFileSync(asarPath));
  let count = 0;
  for (const entry of filesInAsar(asar)) {
    if (fileExpression != null && !fileExpression.test(entry.path)) continue;
    const content = fileBytes(asar, entry);
    if (!content) continue;
    const text = content.toString("utf8");
    expression.lastIndex = 0;
    for (let match; (match = expression.exec(text)) && count < maximumMatches; ) {
      const start = Math.max(0, match.index - context);
      const end = Math.min(text.length, match.index + match[0].length + context);
      process.stdout.write(
        `\n=== ${entry.path}:${match.index} ===\n${text.slice(start, end)}\n`,
      );
      count += 1;
      if (match[0].length === 0) expression.lastIndex += 1;
    }
    if (count >= maximumMatches) break;
  }
  if (count === 0) {
    console.error(`no matches for ${JSON.stringify(query)} in ${basename(asarPath)}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();
