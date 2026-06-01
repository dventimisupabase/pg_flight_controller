// Detect when a prefilled issue URL is too long to navigate to reliably.
//
// A prefilled new-issue URL is a GET, so it is bounded by browser/server URL
// limits. We measure the FINAL encoded URL length (not the raw body), because
// encodeURIComponent inflates newlines and many punctuation characters ~3x, so
// a body that looks short can still overflow. When it does, the caller falls
// back to downloading a .md file.

// Conservative ceiling. Browsers and GitHub tolerate more, but staying well
// under the historical ~8 KB ceiling keeps us safe across clients.
export const MAX_URL_LENGTH = 6000;

/**
 * @param {string} url   the fully-built (already encoded) issue URL
 * @param {number} [max] override the default ceiling
 * @returns {boolean} true when the URL exceeds the limit
 */
export function isOverflow(url, max = MAX_URL_LENGTH) {
  return url.length > max;
}
