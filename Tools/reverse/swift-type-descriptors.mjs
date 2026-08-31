#!/usr/bin/env node

import { readFileSync } from "node:fs";

ignoreClosedOutputPipe();

const [binaryPath, query = ""] = process.argv.slice(2);
if (!binaryPath) {
  console.error("usage: swift-type-descriptors.mjs MACH_O [case-insensitive-query]");
  process.exit(2);
}

const bytes = readFileSync(binaryPath);
if (bytes.readUInt32LE(0) !== 0xfeedfacf) {
  throw new Error("only little-endian 64-bit Mach-O files are supported");
}

const segments = [];
let typeMetadata;
let commandOffset = 32;
const commandCount = bytes.readUInt32LE(16);
for (let commandIndex = 0; commandIndex < commandCount; commandIndex += 1) {
  const command = bytes.readUInt32LE(commandOffset);
  const commandSize = bytes.readUInt32LE(commandOffset + 4);
  if (command === 0x19) {
    const segment = {
      address: number64(commandOffset + 24),
      fileOffset: number64(commandOffset + 40),
      fileSize: number64(commandOffset + 48),
    };
    segments.push(segment);
    const sectionCount = bytes.readUInt32LE(commandOffset + 64);
    let sectionOffset = commandOffset + 72;
    for (let sectionIndex = 0; sectionIndex < sectionCount; sectionIndex += 1) {
      if (fixedString(sectionOffset, 16) === "__swift5_types") {
        typeMetadata = {
          size: number64(sectionOffset + 40),
          fileOffset: bytes.readUInt32LE(sectionOffset + 48),
        };
      }
      sectionOffset += 80;
    }
  }
  if (commandSize < 8) throw new Error(`invalid load command size ${commandSize}`);
  commandOffset += commandSize;
}
if (!typeMetadata) throw new Error("Mach-O has no __swift5_types section");

const normalizedQuery = query.toLocaleLowerCase("en-US");
const results = [];
for (
  let entryOffset = typeMetadata.fileOffset;
  entryOffset + 4 <= typeMetadata.fileOffset + typeMetadata.size;
  entryOffset += 4
) {
  const descriptorOffset = resolveRelativeFileOffset(entryOffset);
  if (descriptorOffset === null || descriptorOffset + 44 > bytes.length) continue;
  const name = contextName(descriptorOffset);
  if (!name || !name.toLocaleLowerCase("en-US").includes(normalizedQuery)) continue;
  const flags = bytes.readUInt32LE(descriptorOffset);
  const words = [];
  for (let wordOffset = 0; wordOffset < 128; wordOffset += 4) {
    const fieldOffset = descriptorOffset + wordOffset;
    if (fieldOffset + 4 > bytes.length) break;
    const signed = bytes.readInt32LE(fieldOffset);
    const targetOffset = signed === 0 ? null : resolveRelativeFileOffset(fieldOffset);
    words.push({
      offset: wordOffset,
      hex: `0x${bytes.readUInt32LE(fieldOffset).toString(16).padStart(8, "0")}`,
      signed,
      relativeTargetFileOffset:
        targetOffset === null ? null : `0x${targetOffset.toString(16)}`,
      relativeTargetAddress:
        targetOffset === null ? null : `0x${fileOffsetToAddress(targetOffset).toString(16)}`,
    });
  }
  results.push({
    entryFileOffset: `0x${entryOffset.toString(16)}`,
    descriptorFileOffset: `0x${descriptorOffset.toString(16)}`,
    descriptorAddress: `0x${fileOffsetToAddress(descriptorOffset).toString(16)}`,
    name,
    flags: `0x${flags.toString(16).padStart(8, "0")}`,
    kind: flags & 0x1f,
    isGeneric: (flags & 0x80) !== 0,
    kindSpecificFlags: `0x${(flags >>> 16).toString(16).padStart(4, "0")}`,
    words,
  });
}

process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);

function fixedString(offset, length) {
  const end = bytes.indexOf(0, offset);
  return bytes.toString("utf8", offset, Math.min(offset + length, end < 0 ? offset + length : end));
}

function number64(offset) {
  const value = bytes.readBigUInt64LE(offset);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("Mach-O address exceeds JS range");
  return Number(value);
}

function relativeString(pointerFileOffset) {
  const target = resolveRelativeFileOffset(pointerFileOffset);
  if (target === null || target < 0 || target >= bytes.length) return null;
  const end = bytes.indexOf(0, target);
  return end < 0 ? null : bytes.toString("utf8", target, end);
}

function resolveRelativeFileOffset(pointerFileOffset) {
  const relative = bytes.readInt32LE(pointerFileOffset);
  if (relative === 0) return null;
  return addressToFileOffset(fileOffsetToAddress(pointerFileOffset) + relative);
}

function contextName(descriptorOffset, visited = new Set()) {
  if (visited.has(descriptorOffset) || descriptorOffset + 12 > bytes.length) return null;
  visited.add(descriptorOffset);
  const name = relativeString(descriptorOffset + 8);
  if (typeof name !== "string" || !/^[A-Za-z_$][A-Za-z0-9_$-]*$/.test(name)) return null;
  const parentOffset = resolveRelativeFileOffset(descriptorOffset + 4);
  if (parentOffset === null) return name;
  const parentName = contextName(parentOffset, visited);
  return parentName ? `${parentName}.${name}` : name;
}

function fileOffsetToAddress(fileOffset) {
  const segment = segments.find(
    (candidate) =>
      fileOffset >= candidate.fileOffset && fileOffset < candidate.fileOffset + candidate.fileSize,
  );
  if (!segment) throw new Error(`file offset 0x${fileOffset.toString(16)} is outside segments`);
  return segment.address + fileOffset - segment.fileOffset;
}

function addressToFileOffset(address) {
  const segment = segments.find(
    (candidate) => address >= candidate.address && address < candidate.address + candidate.fileSize,
  );
  return segment ? segment.fileOffset + address - segment.address : null;
}

function ignoreClosedOutputPipe() {
  process.stdout.on("error", (error) => {
    if (error.code === "EPIPE") process.exit(0);
    throw error;
  });
}
