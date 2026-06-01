import { describe, it, expect, beforeAll } from "vitest";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { JSDOM } from "jsdom";

const SITE_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");

// Contract test: the generated HTML must expose every hook app.js depends on.
// Guards against the generator and the comment app drifting apart.
let document;

beforeAll(() => {
  execSync("node src/generate.js", {
    cwd: SITE_DIR,
    env: { ...process.env, RFC_REPO_OWNER: "testowner", RFC_REPO_NAME: "testrepo" },
  });
  const html = readFileSync(join(SITE_DIR, "dist", "index.html"), "utf8");
  document = new JSDOM(html).window.document;
});

describe("generated page contract", () => {
  it("carries the repo slug app.js reads for issue URLs", () => {
    expect(document.body.dataset.repoOwner).toBe("testowner");
    expect(document.body.dataset.repoName).toBe("testrepo");
  });

  it("has the structural hooks the comment layer mounts onto", () => {
    for (const id of [
      "rfc-content",
      "comment-rail",
      "selection-pop",
      "reviewer-handle",
      "submit-feedback",
    ]) {
      expect(document.getElementById(id), `#${id}`).toBeTruthy();
    }
  });

  it("stamps a stable data-block-id on text blocks (anchor targets)", () => {
    expect(document.querySelectorAll("#rfc-content [data-block-id]").length).toBeGreaterThan(100);
  });

  it("injects a notes box with section metadata and a mount per section", () => {
    const boxes = [...document.querySelectorAll(".notes-box")];
    expect(boxes.length).toBeGreaterThanOrEqual(9);
    for (const b of boxes) {
      expect(b.dataset.sectionId).toBeTruthy();
      expect(b.dataset.sectionTitle).toBeTruthy();
      expect(b.querySelector(".notes-box__mount")).toBeTruthy();
    }
  });

  it("keeps the RFC's in-page links working (TOC anchors resolve to headings)", () => {
    const links = [...document.querySelectorAll(".toc__item a")];
    expect(links.length).toBeGreaterThan(0);
    for (const a of links) {
      const id = a.getAttribute("href").slice(1);
      expect(document.getElementById(id), `#${id}`).toBeTruthy();
    }
  });
});
