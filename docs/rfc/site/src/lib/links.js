// Rewrite the RFC's repo-relative links to absolute GitHub blob URLs.
//
// The RFC links *down* to other repo docs and source (../guide/concepts.md,
// ../../pgfc_observe/install.sql, ...). Those paths were relative to the RFC's
// location in the repo (docs/rfc/), but the explainer is served from the Pages
// site root, where they 404. We point them at the rendered Markdown / source in
// the GitHub repo instead. In-page anchors (#...) and already-absolute URLs are
// left exactly as-is, so the explainer's own navigation is untouched.

import path from "node:path";

/**
 * @param {string} href
 * @param {object} o
 * @param {string} o.owner
 * @param {string} o.repo
 * @param {string} [o.branch="main"]
 * @param {string} [o.baseDir="docs/rfc"]  the RFC's directory, relative to repo root
 * @returns {string}
 */
export function rewriteHref(href, { owner, repo, branch = "main", baseDir = "docs/rfc" }) {
  if (!href) return href;
  if (href.startsWith("#")) return href; // in-page anchor — leave alone
  if (href.startsWith("//")) return href; // protocol-relative
  if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return href; // has a scheme (http:, mailto:, ...)

  const hash = href.indexOf("#");
  const filePart = hash === -1 ? href : href.slice(0, hash);
  const frag = hash === -1 ? "" : href.slice(hash);
  const resolved = path.posix.normalize(path.posix.join(baseDir, filePart));
  return `https://github.com/${owner}/${repo}/blob/${branch}/${resolved}${frag}`;
}
