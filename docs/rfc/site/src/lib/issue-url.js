// Build a GitHub "new issue" URL with the title and body prefilled.
//
// This is the whole persistence mechanism: no API call, no token, no CORS.
// We construct a URL and the reviewer navigates to it, landing on GitHub's
// normal new-issue form already filled in, which they submit under their own
// login. encodeURIComponent escapes everything, so reviewer content cannot
// break out of the query string.

/**
 * @param {object} o
 * @param {string} o.owner  repository owner
 * @param {string} o.repo   repository name
 * @param {string} o.title  prefilled issue title
 * @param {string} o.body   prefilled issue body (Markdown)
 * @returns {string} a github.com/.../issues/new?title=&body= URL
 */
export function buildIssueUrl({ owner, repo, title = "", body = "" }) {
  if (!owner || !repo) {
    throw new Error("owner and repo are required");
  }
  const qs = `title=${encodeURIComponent(title)}&body=${encodeURIComponent(body)}`;
  return `https://github.com/${owner}/${repo}/issues/new?${qs}`;
}
