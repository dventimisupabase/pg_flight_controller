import { describe, it, expect } from "vitest";
import { buildIssueUrl } from "../src/lib/issue-url.js";

describe("buildIssueUrl", () => {
  it("builds a prefilled new-issue URL for the repo", () => {
    const url = buildIssueUrl({
      owner: "acme",
      repo: "pg_flight_controller",
      title: "RFC review",
      body: "hello",
    });
    expect(url.startsWith("https://github.com/acme/pg_flight_controller/issues/new?")).toBe(true);
  });

  it("URL-encodes the title and body", () => {
    const url = buildIssueUrl({
      owner: "acme",
      repo: "r",
      title: "a & b",
      body: "line one\nline two #1",
    });
    expect(url).toContain("title=a%20%26%20b");
    // newline and hash must be percent-encoded, not literal
    expect(url).toContain("body=line%20one%0Aline%20two%20%231");
    expect(url).not.toContain("\n");
  });

  it("requires owner and repo", () => {
    expect(() => buildIssueUrl({ repo: "r", title: "t", body: "b" })).toThrow();
    expect(() => buildIssueUrl({ owner: "o", title: "t", body: "b" })).toThrow();
  });
});
