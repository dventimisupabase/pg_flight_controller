# RFC explainer

A generated, commentable HTML presentation of the
[pg_flight_controller RFC](../README.md). The reading experience is styled
long-form; reviewers leave **margin comments** on any passage and **section
notes** at the end of each section, then submit everything as one prefilled
GitHub issue.

## How it works

- **Generated, never hand-authored.** `npm run build` compiles
  `docs/rfc/README.md` into `dist/index.html`, so the page cannot drift from the
  RFC. Two passes beyond plain Markdown carry the comment layer: a stable,
  section-scoped `data-block-id` on every text block (marginalia anchors), and a
  notes-box mount at the end of each top-level section. A GitHub-matching slugify
  keeps the RFC's own in-page links working.
- **Backendless.** There is no server and no database. Marginalia and section
  notes live in the reviewer's `localStorage` while they work.
- **Submit = a prefilled GitHub issue.** On submit, all of a reviewer's feedback
  is compiled — in document order, each margin comment carrying its quoted
  passage — into one Markdown body, and a `github.com/.../issues/new?...` URL is
  opened. The reviewer submits it under their own GitHub login (that is the
  attribution). No API call, no token, no CORS. If the feedback is long enough
  that the URL would overflow, it is downloaded as a `.md` file to paste instead.

## Commands

```bash
npm install      # once
npm test         # unit + contract tests (Vitest)
npm run build    # generate dist/index.html from the RFC
npm run preview  # serve dist/ at http://localhost:4173
```

## Layout

- `src/lib/` — pure, unit-tested logic shared by the generator and the browser
  app: within-block text anchors, issue-URL building, encoded-overflow detection,
  feedback compilation, repo-slug parsing.
- `src/generate.js` — the Markdown → HTML generator.
- `src/app/` — the page template, styles, and the comment app (`app.js`).
- `test/` — Vitest specs, including a contract test that the generated HTML
  exposes every hook `app.js` mounts onto.

## Deployment

Pushing to `main` builds the site and deploys it to GitHub Pages via
`.github/workflows/rfc-explainer.yml`. This requires Pages to be enabled for the
repo with **Source: GitHub Actions** (Settings → Pages).

## Notes

- The editor and web fonts load from a CDN at view time, so reviewers need to be
  online — fine for a published Pages site.
- The repo the issues target is read from the git remote at build time, or from
  `RFC_REPO_OWNER` / `RFC_REPO_NAME` if set.
- Highlights are confined to a single block by design; the per-section notes box
  is the place for cross-cutting remarks.
