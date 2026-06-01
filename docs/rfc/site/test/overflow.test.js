import { describe, it, expect } from "vitest";
import { isOverflow, MAX_URL_LENGTH } from "../src/lib/overflow.js";
import { buildIssueUrl } from "../src/lib/issue-url.js";

describe("isOverflow", () => {
  it("is false for a short URL", () => {
    const url = buildIssueUrl({ owner: "o", repo: "r", title: "t", body: "short" });
    expect(isOverflow(url)).toBe(false);
  });

  it("is true once the FINAL encoded URL exceeds the limit", () => {
    // A body whose raw length is under the limit but whose encoded length is over it.
    // Newlines encode to %0A (3x), so a body of newlines inflates ~3x when encoded.
    const rawBody = "\n".repeat(Math.floor(MAX_URL_LENGTH / 2));
    expect(rawBody.length).toBeLessThan(MAX_URL_LENGTH);
    const url = buildIssueUrl({ owner: "o", repo: "r", title: "t", body: rawBody });
    expect(url.length).toBeGreaterThan(MAX_URL_LENGTH);
    expect(isOverflow(url)).toBe(true);
  });

  it("honors an explicit max argument", () => {
    const url = buildIssueUrl({ owner: "o", repo: "r", title: "t", body: "x".repeat(50) });
    expect(isOverflow(url, 10)).toBe(true);
    expect(isOverflow(url, 100000)).toBe(false);
  });

  it("uses a conservative default limit", () => {
    expect(MAX_URL_LENGTH).toBeLessThanOrEqual(8000);
    expect(MAX_URL_LENGTH).toBeGreaterThan(1000);
  });
});
