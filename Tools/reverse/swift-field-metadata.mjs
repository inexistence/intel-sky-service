#!/usr/bin/env node

import { readFileSync } from "node:fs";

const [binaryPath, query = ""] = process.argv.slice(2);
if (!binaryPath) {
  console.error("usage: swift-field-metadata.mjs MACH_O [case-insensitive-query]");
  process.exit(2);
}

const bytes = readFileSync(binaryPath);
if (bytes.readUInt32LE(0) !== 0xfeedfacf) {
  throw new Error("only little-endian 64-bit Mach-O files are supported");
}

const segments = [];
let fieldMetadata;
let typeMetadata;
let commandOffset = 32;
const commandCount = bytes.readUInt32LE(16);
for (let commandIndex = 0; commandIndex < commandCount; commandIndex += 1) {
  const command = bytes.readUInt32LE(commandOffset);
  const commandSize = bytes.readUInt32LE(commandOffset + 4);
  if (command === 0x19) {
    const segment = {
      name: fixedString(commandOffset + 8, 16),
      address: number64(commandOffset + 24),
      size: number64(commandOffset + 32),
      fileOffset: number64(commandOffset + 40),
      fileSize: number64(commandOffset + 48),
    };
    segments.push(segment);
    const sectionCount = bytes.readUInt32LE(commandOffset + 64);
    let sectionOffset = commandOffset + 72;
    for (let sectionIndex = 0; sectionIndex < sectionCount; sectionIndex += 1) {
      const sectionName = fixedString(sectionOffset, 16);
      const segmentName = fixedString(sectionOffset + 16, 16);
      if (sectionName === "__swift5_fieldmd") {
        fieldMetadata = {
          segmentName,
          address: number64(sectionOffset + 32),
          size: number64(sectionOffset + 40),
          fileOffset: bytes.readUInt32LE(sectionOffset + 48),
        };
      }
      if (sectionName === "__swift5_types") {
        typeMetadata = {
          address: number64(sectionOffset + 32),
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

if (!fieldMetadata) throw new Error("Mach-O has no __swift5_fieldmd section");

const contextNameByFieldDescriptorOffset = new Map();
if (typeMetadata) {
  for (
    let entryOffset = typeMetadata.fileOffset;
    entryOffset + 4 <= typeMetadata.fileOffset + typeMetadata.size;
    entryOffset += 4
  ) {
    const descriptorOffset = resolveRelativeFileOffset(entryOffset);
    if (descriptorOffset === null || descriptorOffset + 20 > bytes.length) continue;
    const name = contextName(descriptorOffset);
    const fieldDescriptorOffset = resolveRelativeFileOffset(descriptorOffset + 16);
    if (name && fieldDescriptorOffset !== null) {
      contextNameByFieldDescriptorOffset.set(fieldDescriptorOffset, name);
    }
  }
}

const descriptors = [];
let offset = fieldMetadata.fileOffset;
const sectionEnd = offset + fieldMetadata.size;
while (offset + 16 <= sectionEnd) {
  const recordSize = bytes.readUInt16LE(offset + 10);
  const fieldCount = bytes.readUInt32LE(offset + 12);
  if (recordSize < 12 || offset + 16 + recordSize * fieldCount > sectionEnd) break;

  const typeName = contextNameByFieldDescriptorOffset.get(offset) ?? relativeString(offset, 0);
  const fields = [];
  let recordOffset = offset + 16;
  for (let fieldIndex = 0; fieldIndex < fieldCount; fieldIndex += 1) {
    fields.push({
      flags: bytes.readUInt32LE(recordOffset),
      type: relativeString(recordOffset, 4),
      name: relativeString(recordOffset, 8),
    });
    recordOffset += recordSize;
  }
  descriptors.push({
    offset: `0x${offset.toString(16)}`,
    kind: bytes.readUInt16LE(offset + 8),
    typeName,
    fields,
  });
  offset = recordOffset;
}

const normalizedQuery = query.toLocaleLowerCase("en-US");
const matches = descriptors.filter((descriptor) => {
  if (!normalizedQuery) return true;
  return JSON.stringify(descriptor).toLocaleLowerCase("en-US").includes(normalizedQuery);
});
process.stdout.write(`${JSON.stringify(matches, null, 2)}\n`);

function fixedString(offset, length) {
  const end = bytes.indexOf(0, offset);
  return bytes.toString("utf8", offset, Math.min(offset + length, end < 0 ? offset + length : end));
}

function number64(offset) {
  const value = bytes.readBigUInt64LE(offset);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("Mach-O address exceeds JS range");
  return Number(value);
}

function relativeString(baseFileOffset, fieldOffset) {
  const pointerFileOffset = baseFileOffset + fieldOffset;
  const targetFileOffset = resolveRelativeFileOffset(pointerFileOffset);
  if (targetFileOffset === null) return null;
  if (targetFileOffset < 0 || targetFileOffset >= bytes.length) {
    return "<invalid-relative-pointer>";
  }
  const symbolicName = decodeDirectContextReference(targetFileOffset);
  if (symbolicName) return symbolicName;
  const end = bytes.indexOf(0, targetFileOffset);
  if (end < 0) return `<unterminated-string:0x${targetFileOffset.toString(16)}>`;
  return bytes.toString("utf8", targetFileOffset, end);
}

function resolveRelativeFileOffset(pointerFileOffset) {
  const relative = bytes.readInt32LE(pointerFileOffset);
  if (relative === 0) return null;
  const pointerAddress = fileOffsetToAddress(pointerFileOffset);
  return addressToFileOffset(pointerAddress + relative);
}

function decodeDirectContextReference(targetFileOffset) {
  const control = bytes[targetFileOffset];
  if (control !== 0x01 || targetFileOffset + 5 > bytes.length) return null;
  const relative = bytes.readInt32LE(targetFileOffset + 1);
  for (const relativeBase of [targetFileOffset + 1, targetFileOffset + 5]) {
    const referenceAddress = fileOffsetToAddress(relativeBase) + relative;
    const descriptorOffset = addressToFileOffset(referenceAddress);
    if (descriptorOffset === null || descriptorOffset + 12 > bytes.length) continue;
    const name = contextName(descriptorOffset);
    if (typeof name === "string" && /^[A-Za-z_][A-Za-z0-9_.$-]*$/.test(name)) {
      return `<context:${name}@0x${descriptorOffset.toString(16)}>`;
    }
  }
  return `<symbolic-context-reference@0x${targetFileOffset.toString(16)}>`;
}

function contextName(descriptorOffset, visited = new Set()) {
  if (visited.has(descriptorOffset) || descriptorOffset + 12 > bytes.length) return null;
  visited.add(descriptorOffset);
  const name = relativeString(descriptorOffset, 8);
  if (typeof name !== "string" || !/^[A-Za-z_][A-Za-z0-9_-]*$/.test(name)) return null;
  const parentRelative = bytes.readInt32LE(descriptorOffset + 4);
  if (parentRelative === 0) return name;
  const parentAddress = fileOffsetToAddress(descriptorOffset + 4) + parentRelative;
  const parentOffset = addressToFileOffset(parentAddress);
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
