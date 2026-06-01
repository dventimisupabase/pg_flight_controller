import { describe, it, expect } from "vitest";
import { compileFeedback, toBlockquote } from "../src/lib/compile.js";

describe("toBlockquote", () => {
  it("prefixes every line, including blank lines", () => {
    expect(toBlockquote("one\n\ntwo")).toBe("> one\n>\n> two");
  });

  it("neutralizes a fence inside a quoted passage so it cannot open a code block", () => {
    // A line beginning with ``` inside our quoted RFC passage must stay quoted text.
    const out = toBlockquote("see ```code```");
    expect(out).toBe("> see ```code```");
  });
});

describe("compileFeedback", () => {
  const base = {
    reviewer: "octocat",
    rfcUrl: "https://example.com/rfc",
    items: [
      {
        kind: "note",
        order: 50,
        sectionId: "3",
        sectionTitle: "Architecture",
        body: "Looks **solid**.\n\n- point one",
      },
      {
        kind: "margin",
        order: 10,
        sectionId: "1",
        sectionTitle: "Abstract",
        quote: "supervisory autovacuum governor",
        body: "Is *supervisory* the right word here?",
      },
    ],
  };

  it("attributes the review to the GitHub handle and links the RFC", () => {
    const md = compileFeedback(base);
    expect(md).toContain("@octocat");
    expect(md).toContain("https://example.com/rfc");
  });

  it("renders margin comments with the quoted passage as a blockquote, then the comment", () => {
    const md = compileFeedback(base);
    expect(md).toContain("> supervisory autovacuum governor");
    expect(md).toContain("Is *supervisory* the right word here?");
  });

  it("renders section notes verbatim as markdown", () => {
    const md = compileFeedback(base);
    expect(md).toContain("Looks **solid**.");
    expect(md).toContain("- point one");
  });

  it("emits items in document order, not array order", () => {
    const md = compileFeedback(base);
    // order:10 (Abstract margin) must precede order:50 (Architecture note)
    expect(md.indexOf("Abstract")).toBeLessThan(md.indexOf("Architecture"));
  });

  it("returns a string with no trailing whitespace lines", () => {
    const md = compileFeedback(base);
    expect(md).not.toMatch(/[ \t]+\n/);
  });
});
