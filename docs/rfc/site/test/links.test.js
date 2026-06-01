import { describe, it, expect } from "vitest";
import { rewriteHref } from "../src/lib/links.js";

const opts = { owner: "o", repo: "r", branch: "main", baseDir: "docs/rfc" };
const blob = "https://github.com/o/r/blob/main";

describe("rewriteHref", () => {
  it("leaves in-page anchors untouched (explainer's own navigation)", () => {
    expect(rewriteHref("#3-architecture", opts)).toBe("#3-architecture");
    expect(rewriteHref("#o1-collection", opts)).toBe("#o1-collection");
  });

  it("leaves already-absolute and scheme URLs untouched", () => {
    expect(rewriteHref("https://example.com/x", opts)).toBe("https://example.com/x");
    expect(rewriteHref("http://example.com", opts)).toBe("http://example.com");
    expect(rewriteHref("mailto:a@b.com", opts)).toBe("mailto:a@b.com");
    expect(rewriteHref("//cdn.example.com/x", opts)).toBe("//cdn.example.com/x");
  });

  it("rewrites a sibling-dir doc link, resolved against docs/rfc, preserving the fragment", () => {
    expect(rewriteHref("../guide/concepts.md#workload-classes", opts)).toBe(
      `${blob}/docs/guide/concepts.md#workload-classes`
    );
    expect(rewriteHref("../reference/pgfc_observe.md", opts)).toBe(
      `${blob}/docs/reference/pgfc_observe.md`
    );
  });

  it("rewrites a link that climbs to the repo root (source files)", () => {
    expect(rewriteHref("../../pgfc_observe/install.sql", opts)).toBe(
      `${blob}/pgfc_observe/install.sql`
    );
  });

  it("rewrites a same-directory doc link", () => {
    expect(rewriteHref("navigation-tooling-plan.md", opts)).toBe(
      `${blob}/docs/rfc/navigation-tooling-plan.md`
    );
    expect(rewriteHref("./navigation-tooling-plan.md", opts)).toBe(
      `${blob}/docs/rfc/navigation-tooling-plan.md`
    );
  });

  it("defaults the branch to main", () => {
    expect(rewriteHref("../guide/concepts.md", { owner: "o", repo: "r", baseDir: "docs/rfc" })).toBe(
      `${blob}/docs/guide/concepts.md`
    );
  });

  it("is a no-op for empty/missing hrefs", () => {
    expect(rewriteHref("", opts)).toBe("");
  });
});
