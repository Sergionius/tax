import assert from "node:assert/strict";
import test from "node:test";

import { truncatePayloadText } from "./tax-push.ts";

test("keeps text within the payload limit unchanged", () => {
  assert.equal(truncatePayloadText("context", 100), "context");
});

test("preserves the beginning and end when truncating", () => {
  const value = `${"a".repeat(80)}middle${"z".repeat(80)}`;
  const result = truncatePayloadText(value, 100);

  assert.equal(result.length, 100);
  assert.match(result, /^a+/);
  assert.match(result, /z+$/);
  assert.match(result, /\[truncated\]/);
});

test("never exceeds a limit smaller than the truncation marker", () => {
  assert.equal(truncatePayloadText("abcdefghij", 4), "abcd");
});

test("keeps oversized context within the backend limit", () => {
  const result = truncatePayloadText("x".repeat(100_001), 100_000);

  assert.equal(result.length, 100_000);
});
