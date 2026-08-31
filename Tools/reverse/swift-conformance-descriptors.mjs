#!/usr/bin/env node

import { readFileSync } from "node:fs";

ignoreClosedOutputPipe();

const [binaryPath, query = ""] = process.argv.slice(2);
if (!binaryPath) {
  console.error("usage: swift-conformance-descriptors.mjs MACH_O [type-query]");
  process.exit(2);
}

const bytes = readFileSync(binaryPath);
if (bytes.readUInt32LE(0) !== 0xfeedfacf) throw new Error("expected a 64-bit Mach-O");

const segments = [];
const sections = new Map();
let commandOffset = 32;
for (let index = 0; index < bytes.readUInt32LE(16); index += 1) {
  const command = bytes.readUInt32LE(commandOffset);
  const commandSize = bytes.readUInt32LE(commandOffset + 4);
  if (command === 0x19) {
    const segment = {
      address: number64(commandOffset + 24),
      fileOffset: number64(commandOffset + 40),
      fileSize: number64(commandOffset + 48),
    };
    segments.push(segment);
    let sectionOffset = commandOffset + 72;
    for (let sectionIndex = 0; sectionIndex < bytes.readUInt32LE(commandOffset + 64); sectionIndex += 1) {
      const name = fixedString(sectionOffset, 16);
      sections.set(name, {
        size: number64(sectionOffset + 40),
        fileOffset: bytes.readUInt32LE(sectionOffset + 48),
      });
      sectionOffset += 80;
    }
  }
  if (commandSize < 8) throw new Error(`invalid load command size ${commandSize}`);
  commandOffset += commandSize;
}

const proto = sections.get("__swift5_proto");
if (!proto) throw new Error("Mach-O has no __swift5_proto section");
const normalizedQuery = query.toLocaleLowerCase("en-US");
const results = [];
for (let entry = proto.fileOffset; entry + 4 <= proto.fileOffset + proto.size; entry += 4) {
  const descriptor = relativeTarget(entry, 0);
  if (descriptor === null || descriptor + 16 > bytes.length) continue;
  const flags = bytes.readUInt32LE(descriptor + 12);
  const typeReferenceKind = (flags >>> 3) & 0x7;
  let typeDescriptor = relativeTarget(descriptor + 4, 0x3);
  if (typeReferenceKind === 1 && typeDescriptor !== null && typeDescriptor + 8 <= bytes.length) {
    const indirectAddress = bytes.readBigUInt64LE(typeDescriptor);
    typeDescriptor =
      indirectAddress <= BigInt(Number.MAX_SAFE_INTEGER)
        ? addressToFileOffset(Number(indirectAddress))
        : null;
  }
  const typeName = typeDescriptor === null ? null : contextName(typeDescriptor);
  if (!typeName || !typeName.toLocaleLowerCase("en-US").includes(normalizedQuery)) continue;
  const protocolDescriptor = relativeTarget(descriptor, 0x1);
  const witnessPattern = relativeTarget(descriptor + 8, 0x1);
  results.push({
    entryFileOffset: hex(entry),
    descriptorFileOffset: hex(descriptor),
    descriptorAddress: hex(fileOffsetToAddress(descriptor)),
    flags: `0x${flags.toString(16).padStart(8, "0")}`,
    typeReferenceKind,
    typeName,
    protocolName: protocolDescriptor === null ? null : contextName(protocolDescriptor),
    witnessPatternFileOffset: witnessPattern === null ? null : hex(witnessPattern),
    witnessPatternAddress:
      witnessPattern === null ? null : hex(fileOffsetToAddress(witnessPattern)),
    conformanceWords: words(descriptor, 96),
    witnessWords: witnessPattern === null ? [] : words(witnessPattern, 96),
  });
}

process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);

function words(start, length) {
  const result = [];
  for (let offset = 0; offset < length && start + offset + 4 <= bytes.length; offset += 4) {
    const field = start + offset;
    const target = relativeTarget(field, 0x3);
    result.push({
      offset,
      hex: `0x${bytes.readUInt32LE(field).toString(16).padStart(8, "0")}`,
      relativeTargetFileOffset: target === null ? null : hex(target),
      relativeTargetAddress: target === null ? null : hex(fileOffsetToAddress(target)),
    });
  }
  return result;
}

function relativeTarget(pointerFileOffset, tagMask) {
  let relative = bytes.readInt32LE(pointerFileOffset);
  if (relative === 0) return null;
  relative &= ~tagMask;
  return addressToFileOffset(fileOffsetToAddress(pointerFileOffset) + relative);
}

function contextName(descriptorOffset, visited = new Set()) {
  if (visited.has(descriptorOffset) || descriptorOffset + 12 > bytes.length) return null;
  visited.add(descriptorOffset);
  const nameOffset = relativeTarget(descriptorOffset + 8, 0);
  if (nameOffset === null) return null;
  const end = bytes.indexOf(0, nameOffset);
  if (end < 0) return null;
  const name = bytes.toString("utf8", nameOffset, end);
  if (!/^[A-Za-z_$][A-Za-z0-9_$-]*$/.test(name)) return null;
  const parent = relativeTarget(descriptorOffset + 4, 0);
  if (parent === null) return name;
  const parentName = contextName(parent, visited);
  return parentName ? `${parentName}.${name}` : name;
}

function fixedString(offset, length) {
  const end = bytes.indexOf(0, offset);
  return bytes.toString("utf8", offset, Math.min(offset + length, end < 0 ? offset + length : end));
}

function number64(offset) {
  const value = bytes.readBigUInt64LE(offset);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("address exceeds JS range");
  return Number(value);
}

function fileOffsetToAddress(fileOffset) {
  const segment = segments.find(
    (candidate) =>
      fileOffset >= candidate.fileOffset && fileOffset < candidate.fileOffset + candidate.fileSize,
  );
  if (!segment) throw new Error(`file offset ${hex(fileOffset)} is outside segments`);
  return segment.address + fileOffset - segment.fileOffset;
}

function addressToFileOffset(address) {
  const segment = segments.find(
    (candidate) => address >= candidate.address && address < candidate.address + candidate.fileSize,
  );
  return segment ? segment.fileOffset + address - segment.address : null;
}

function hex(value) {
  return `0x${value.toString(16)}`;
}

function ignoreClosedOutputPipe() {
  process.stdout.on("error", (error) => {
    if (error.code === "EPIPE") process.exit(0);
    throw error;
  });
}
