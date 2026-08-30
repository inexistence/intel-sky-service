#!/usr/bin/env node

const mask64 = (1n << 64n) - 1n;

export function softLinkSymbolHash(name, salt) {
  return sipHash24(Buffer.from(`${name}${salt}`, "utf8"));
}

export function formatHash(value) {
  return `0x${value.toString(16).padStart(16, "0")}`;
}

function rotateLeft(value, count) {
  const bits = BigInt(count);
  return ((value << bits) | (value >> (64n - bits))) & mask64;
}

function round(state) {
  let [v0, v1, v2, v3] = state;
  v0 = (v0 + v1) & mask64;
  v1 = rotateLeft(v1, 13) ^ v0;
  v0 = rotateLeft(v0, 32);
  v2 = (v2 + v3) & mask64;
  v3 = rotateLeft(v3, 16) ^ v2;
  v0 = (v0 + v3) & mask64;
  v3 = rotateLeft(v3, 21) ^ v0;
  v2 = (v2 + v1) & mask64;
  v1 = rotateLeft(v1, 17) ^ v2;
  v2 = rotateLeft(v2, 32);
  return [v0, v1, v2, v3];
}

function sipHash24(bytes) {
  const key0 = 0x0706050403020100n;
  const key1 = 0x0f0e0d0c0b0a0908n;
  let v0 = 0x736f6d6570736575n ^ key0;
  let v1 = 0x646f72616e646f6dn ^ key1;
  let v2 = 0x6c7967656e657261n ^ key0;
  let v3 = 0x7465646279746573n ^ key1;

  let offset = 0;
  while (offset + 8 <= bytes.length) {
    const message = bytes.readBigUInt64LE(offset);
    v3 ^= message;
    [v0, v1, v2, v3] = round([v0, v1, v2, v3]);
    [v0, v1, v2, v3] = round([v0, v1, v2, v3]);
    v0 ^= message;
    offset += 8;
  }

  let tail = BigInt(bytes.length) << 56n;
  for (let index = 0; offset + index < bytes.length; index += 1) {
    tail |= BigInt(bytes[offset + index]) << BigInt(index * 8);
  }
  v3 ^= tail;
  [v0, v1, v2, v3] = round([v0, v1, v2, v3]);
  [v0, v1, v2, v3] = round([v0, v1, v2, v3]);
  v0 ^= tail;
  v2 ^= 0xffn;
  for (let index = 0; index < 4; index += 1) {
    [v0, v1, v2, v3] = round([v0, v1, v2, v3]);
  }
  return (v0 ^ v1 ^ v2 ^ v3) & mask64;
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const [salt, ...names] = process.argv.slice(2);
  if (!salt || names.length === 0) {
    console.error("usage: softlink-symbol-hash.mjs SALT SYMBOL [SYMBOL ...]");
    process.exit(2);
  }
  process.stdout.write(
    `${JSON.stringify(
      names.map((name) => ({ name, hash: formatHash(softLinkSymbolHash(name, salt)) })),
      null,
      2,
    )}\n`,
  );
}
