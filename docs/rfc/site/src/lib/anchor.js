// Within-block text anchors for marginalia.
//
// A highlight is confined to a single block (paragraph, list item, heading, ...).
// We persist the character offsets plus the quoted text. Offsets give an O(1)
// re-resolve; the quote is the source of truth and the fallback if offsets drift.
// Anchors only need to survive one reading session (localStorage -> submit), so
// this stays deliberately simple.

/**
 * Capture an anchor from a within-block selection.
 * @param {string} blockId  stable id of the block element
 * @param {string} blockText  the block's full text content
 * @param {number} start  selection start offset (inclusive)
 * @param {number} end    selection end offset (exclusive)
 */
export function captureAnchor(blockId, blockText, start, end) {
  if (!Number.isInteger(start) || !Number.isInteger(end)) {
    throw new Error("anchor offsets must be integers");
  }
  if (start >= end) {
    throw new Error("empty or inverted selection");
  }
  if (start < 0 || end > blockText.length) {
    throw new Error("selection out of block bounds");
  }
  return { blockId, start, end, quote: blockText.slice(start, end) };
}

/**
 * Resolve an anchor against a block's current text.
 * Prefers the stored offsets; if the quote no longer sits there, falls back to
 * locating the quote by search. Reports ok=false when the quote is gone.
 */
export function resolveAnchor(blockText, anchor) {
  const { start, end, quote } = anchor;
  if (blockText.slice(start, end) === quote) {
    return { start, end, quote, ok: true };
  }
  const found = blockText.indexOf(quote);
  if (found !== -1) {
    return { start: found, end: found + quote.length, quote, ok: true };
  }
  return { start: -1, end: -1, quote, ok: false };
}
