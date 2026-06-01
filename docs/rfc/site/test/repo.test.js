import { describe, it, expect } from "vitest";
import { parseRepoSlug } from "../src/lib/repo.js";

describe("parseRepoSlug", () => {
  it("parses an SSH remote", () => {
    expect(parseRepoSlug("git@github.com:dventimisupabase/pg_flight_controller.git")).toEqual({
      owner: "dventimisupabase",
      repo: "pg_flight_controller",
    });
  });

  it("parses an HTTPS remote with and without .git", () => {
    expect(parseRepoSlug("https://github.com/acme/widgets.git")).toEqual({
      owner: "acme",
      repo: "widgets",
    });
    expect(parseRepoSlug("https://github.com/acme/widgets")).toEqual({
      owner: "acme",
      repo: "widgets",
    });
  });

  it("returns null for a non-GitHub or unparseable remote", () => {
    expect(parseRepoSlug("")).toBeNull();
    expect(parseRepoSlug("file:///tmp/repo")).toBeNull();
  });
});
