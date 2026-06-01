import { describe, it, expect } from "vitest";
import { captureAnchor, resolveAnchor } from "../src/lib/anchor.js";

const BLOCK = "PostgreSQL exposes per-table autovacuum knobs as static configuration.";

describe("captureAnchor", () => {
  it("captures the selected substring as the quote", () => {
    const start = BLOCK.indexOf("autovacuum knobs");
    const end = start + "autovacuum knobs".length;
    const a = captureAnchor("b-3", BLOCK, start, end);
    expect(a).toEqual({ blockId: "b-3", start, end, quote: "autovacuum knobs" });
  });

  it("rejects a zero-length or inverted selection", () => {
    expect(() => captureAnchor("b-3", BLOCK, 5, 5)).toThrow();
    expect(() => captureAnchor("b-3", BLOCK, 9, 4)).toThrow();
  });

  it("rejects a selection outside the block bounds", () => {
    expect(() => captureAnchor("b-3", BLOCK, -1, 4)).toThrow();
    expect(() => captureAnchor("b-3", BLOCK, 0, BLOCK.length + 1)).toThrow();
  });
});

describe("resolveAnchor", () => {
  it("round-trips: capture then resolve yields the same offsets and quote", () => {
    const start = BLOCK.indexOf("static");
    const end = start + "static".length;
    const a = captureAnchor("b-3", BLOCK, start, end);
    const r = resolveAnchor(BLOCK, a);
    expect(r.ok).toBe(true);
    expect(r.start).toBe(start);
    expect(r.end).toBe(end);
    expect(r.quote).toBe("static");
  });

  it("falls back to locating the quote when offsets drift but text is unchanged", () => {
    const a = { blockId: "b-3", start: 0, end: 6, quote: "static" };
    const r = resolveAnchor(BLOCK, a);
    expect(r.ok).toBe(true);
    expect(r.start).toBe(BLOCK.indexOf("static"));
    expect(r.quote).toBe("static");
  });

  it("reports not-ok when the quoted text is gone", () => {
    const a = { blockId: "b-3", start: 0, end: 6, quote: "absent phrase" };
    const r = resolveAnchor(BLOCK, a);
    expect(r.ok).toBe(false);
  });
});
