import assert from "node:assert/strict";
import test from "node:test";

import { formatHash, softLinkSymbolHash } from "./softlink-symbol-hash.mjs";

const accessibilitySalt =
  "31bbb19e1e2fbe393d58524a29ece1d16e3cd803b4086f73462cd3c9e8746e0bfa0fb384f10ac81057c44b152d8fd87054a85740d4c2435bc161934af1542895";

test("matches official AccessibilitySPI SoftLink request hashes", () => {
  const expected = new Map([
    ["_AXUIElementGetActualPid", "0x245daf9a4f1ec5dd"],
    ["_AXUIElementGetWindow", "0x8b2a568faf5add83"],
    ["_AXUIElementCopyHierarchy", "0x4f3c01ac88eb92c2"],
    ["AXUIElementCopyHierarchy", "0xfc69eb6d448f4c73"],
  ]);

  for (const [name, hash] of expected) {
    assert.equal(formatHash(softLinkSymbolHash(name, accessibilitySalt)), hash);
  }
});
