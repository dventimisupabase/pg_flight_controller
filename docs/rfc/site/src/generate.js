// Generate the commentable HTML explainer from the RFC markdown.
//
// The page is ALWAYS generated from docs/rfc/README.md — never hand-authored —
// so it cannot drift from the RFC. Two passes beyond vanilla markdown->HTML
// carry the comment layer:
//   1. every text-bearing block gets a stable, section-scoped data-block-id
//      (marginalia anchors hang off these);
//   2. a notes-box mount is injected at the end of each top-level (h2) section.
// A GitHub-matching slugify keeps the RFC's own in-page links (#3-architecture,
// #o1-collection, ...) working.

import { readFileSync, writeFileSync, copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import MarkdownIt from "markdown-it";
import anchor from "markdown-it-anchor";
import { parseRepoSlug } from "./lib/repo.js";
import { rewriteHref } from "./lib/links.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SITE_DIR = join(__dirname, "..");
const RFC_PATH = join(SITE_DIR, "..", "README.md"); // docs/rfc/README.md
const APP_DIR = join(__dirname, "app");
const LIB_DIR = join(__dirname, "lib");
const DIST = join(SITE_DIR, "dist");

// h2 == a top-level section that gets a notes box. Bump to 3 to also give every
// subsystem (### O1..G7) its own box.
const NOTES_HEADING_LEVEL = 2;

/** GitHub-style heading slug (matches the anchors used inside the RFC). */
function ghSlug(s) {
  return s
    .trim()
    .toLowerCase()
    .replace(/[^\w\- ]/g, "")
    .replace(/ /g, "-");
}

function resolveRepo() {
  const owner = process.env.RFC_REPO_OWNER;
  const repo = process.env.RFC_REPO_NAME;
  if (owner && repo) return { owner, repo };
  try {
    const url = execSync("git config --get remote.origin.url", {
      cwd: SITE_DIR,
      encoding: "utf8",
    }).trim();
    const slug = parseRepoSlug(url);
    if (slug) return slug;
  } catch {
    /* fall through */
  }
  throw new Error(
    "Could not determine repo owner/name. Set RFC_REPO_OWNER and RFC_REPO_NAME."
  );
}

function buildMarkdown(repo) {
  const md = new MarkdownIt({ html: false, linkify: true, typographer: false });
  md.use(anchor, { slugify: ghSlug });

  // Pass: rewrite repo-relative links to absolute GitHub blob URLs (in-page
  // anchors and absolute URLs are left alone). link_open lives in inline children.
  md.core.ruler.push("pgfc_links", (state) => {
    for (const tok of state.tokens) {
      if (!tok.children) continue;
      for (const child of tok.children) {
        if (child.type !== "link_open") continue;
        const href = child.attrGet("href");
        if (href != null) child.attrSet("href", rewriteHref(href, repo));
      }
    }
  });

  // Pass 1: section-scoped stable block ids.
  const TAGGED = new Set([
    "paragraph_open",
    "heading_open",
    "blockquote_open",
    "list_item_open",
    "fence",
    "code_block",
  ]);
  md.core.ruler.push("pgfc_block_ids", (state) => {
    let section = "head";
    let n = 0;
    for (const tok of state.tokens) {
      if (tok.type === "heading_open" && tok.tag === "h2") {
        section = tok.attrGet("id") || "section";
        n = 0;
      }
      if (TAGGED.has(tok.type)) {
        tok.attrSet("data-block-id", `${section}-b${++n}`);
      }
    }
  });
  return md;
}

/** Collect h2/h3 headings for the table of contents and section list. */
function outline(md, src) {
  const tokens = md.parse(src, {});
  const headings = [];
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type === "heading_open" && (t.tag === "h2" || t.tag === "h3")) {
      const inline = tokens[i + 1];
      headings.push({
        level: Number(t.tag.slice(1)),
        id: t.attrGet("id"),
        title: inline.content.replace(/\s+·.*$/, ""), // drop trailing "· links" runs
      });
    }
  }
  return headings;
}

function notesBox({ id, title }) {
  const safeTitle = title.replace(/"/g, "&quot;");
  return `
<aside class="notes-box" data-section-id="${id}" data-section-title="${safeTitle}">
  <div class="notes-box__label">Notes on this section</div>
  <div class="notes-box__mount"></div>
</aside>`;
}

/** Inject a notes box at the end of each notable section's content. */
function injectNotesBoxes(html, sectionsById) {
  // Each part (after the first) begins with an <h2 id="...">; that part is one
  // section's content. Append a notes box only for sections we want reviewed
  // (the numbered ones) — not front matter like "Contents" or "How to read this".
  const parts = html.split(/(?=<h2\b)/);
  if (parts.length <= 1) return html;
  return parts
    .map((part, i) => {
      if (i === 0) return part;
      const id = part.match(/^<h2\s+id="([^"]+)"/)?.[1];
      const sec = id && sectionsById.get(id);
      return sec ? part + notesBox(sec) : part;
    })
    .join("");
}

function renderToc(headings) {
  const items = headings
    .map(
      (h) =>
        `<li class="toc__item toc__item--h${h.level}"><a href="#${h.id}">${h.title}</a></li>`
    )
    .join("\n");
  return `<nav class="toc" aria-label="Table of contents">
  <div class="toc__title">Contents</div>
  <ul class="toc__list">\n${items}\n</ul>
</nav>`;
}

function copyDir(srcDir, destDir) {
  mkdirSync(destDir, { recursive: true });
  for (const name of readdirSync(srcDir)) {
    copyFileSync(join(srcDir, name), join(destDir, name));
  }
}

function main() {
  const { owner, repo } = resolveRepo();
  const branch = process.env.RFC_REPO_BRANCH || "main";
  const src = readFileSync(RFC_PATH, "utf8");
  // RFC lives at docs/rfc/README.md, so its relative links resolve against docs/rfc.
  const md = buildMarkdown({ owner, repo, branch, baseDir: "docs/rfc" });

  const headings = outline(md, src);
  // Notes boxes only on the numbered sections — not front matter (Contents,
  // How to read this), whose ids don't start with a digit.
  const sections = headings.filter(
    (h) => h.level === NOTES_HEADING_LEVEL && /^\d/.test(h.id)
  );
  const sectionsById = new Map(sections.map((h) => [h.id, h]));

  const body = injectNotesBoxes(md.render(src), sectionsById);
  const toc = renderToc(headings);

  const template = readFileSync(join(APP_DIR, "template.html"), "utf8");
  const out = template
    .replaceAll("{{OWNER}}", owner)
    .replaceAll("{{REPO}}", repo)
    .replace("{{TOC}}", toc)
    .replace("{{BODY}}", body);

  mkdirSync(DIST, { recursive: true });
  writeFileSync(join(DIST, "index.html"), out);
  copyFileSync(join(APP_DIR, "styles.css"), join(DIST, "styles.css"));
  // App scripts keep their src/app layout under dist/app so their "../lib/..."
  // imports resolve identically in source and in the build.
  const distApp = join(DIST, "app");
  mkdirSync(distApp, { recursive: true });
  for (const name of readdirSync(APP_DIR)) {
    if (name.endsWith(".js")) copyFileSync(join(APP_DIR, name), join(distApp, name));
  }
  copyDir(LIB_DIR, join(DIST, "lib"));

  console.log(`Generated dist/index.html for ${owner}/${repo} (${sections.length} sections).`);
}

main();
