// Parse a GitHub owner/repo slug from a git remote URL (SSH or HTTPS).
// Used at build time to point the prefilled issue URLs at the right repo.

/**
 * @param {string} remoteUrl  e.g. git@github.com:owner/repo.git
 * @returns {{owner: string, repo: string} | null}
 */
export function parseRepoSlug(remoteUrl) {
  if (!remoteUrl) return null;
  const m = remoteUrl.match(/github\.com[:/]([^/]+)\/(.+?)(?:\.git)?\/?$/);
  if (!m) return null;
  return { owner: m[1], repo: m[2] };
}
