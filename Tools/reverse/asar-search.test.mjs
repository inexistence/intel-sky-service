import assert from "node:assert/strict";
import test from "node:test";

import { fileBytes, filesInAsar, parseAsar } from "./asar-search.mjs";

function makeAsar(header, content) {
  const json = Buffer.from(JSON.stringify(header));
  const headerSize = 8 + json.length;
  const bytes = Buffer.alloc(8 + headerSize + content.length);
  bytes.writeUInt32LE(4, 0);
  bytes.writeUInt32LE(headerSize, 4);
  bytes.writeUInt32LE(headerSize - 4, 8);
  bytes.writeUInt32LE(json.length, 12);
  json.copy(bytes, 16);
  content.copy(bytes, 8 + headerSize);
  return bytes;
}

test("parses packed ASAR files and preserves nested paths", () => {
  const bytes = makeAsar(
    {
      files: {
        "main.js": { offset: "0", size: 5 },
        nested: { files: { "worker.js": { offset: "5", size: 6 } } },
        "native.node": { offset: "11", size: 7, unpacked: true },
      },
    },
    Buffer.from("hello world"),
  );
  const asar = parseAsar(bytes);
  const files = filesInAsar(asar);

  assert.deepEqual(files.map((entry) => entry.path), [
    "main.js",
    "nested/worker.js",
    "native.node",
  ]);
  assert.equal(fileBytes(asar, files[0]).toString(), "hello");
  assert.equal(fileBytes(asar, files[1]).toString(), " world");
  assert.equal(fileBytes(asar, files[2]), null);
});

test("rejects malformed and truncated ASAR ranges", () => {
  assert.throws(() => parseAsar(Buffer.alloc(15)), /unsupported ASAR header/);

  const invalidRange = parseAsar(
    makeAsar({ files: { "bad.js": { offset: "not-a-number", size: 1 } } }, Buffer.alloc(1)),
  );
  assert.throws(() => fileBytes(invalidRange, filesInAsar(invalidRange)[0]), /invalid ASAR/);

  const truncatedRange = parseAsar(
    makeAsar({ files: { "bad.js": { offset: "1", size: 2 } } }, Buffer.alloc(1)),
  );
  assert.throws(() => fileBytes(truncatedRange, filesInAsar(truncatedRange)[0]), /truncated ASAR/);
});
