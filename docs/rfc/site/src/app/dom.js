// DOM glue for the comment layer, kept separate from app.js so it can be
// exercised in jsdom (app.js itself runs on load and touches globals/CDN).
// The pure, environment-free logic lives in ../lib; this layer is the bridge
// between the live document and that logic.

import { resolveAnchor } from "../lib/anchor.js";

/** Character offset of (node, nodeOffset) within a block's text content. */
export function offsetWithin(block, node, nodeOffset) {
  const r = block.ownerDocument.createRange();
  r.setStart(block, 0);
  r.setEnd(node, nodeOffset);
  return r.toString().length;
}

/**
 * Wrap [start, end) of a block's text in <mark> spans — one per intersected
 * text-node segment, so inline markup (links, bold) inside the range survives.
 * Returns the marks created.
 */
export function highlightRange(block, start, end, commentId) {
  const doc = block.ownerDocument;
  const walker = doc.createTreeWalker(block, 4 /* SHOW_TEXT */);
  let pos = 0;
  const ops = [];
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const nodeStart = pos;
    const nodeEnd = pos + node.nodeValue.length;
    pos = nodeEnd;
    const from = Math.max(start, nodeStart);
    const to = Math.min(end, nodeEnd);
    if (from < to) ops.push({ node, from: from - nodeStart, to: to - nodeStart });
  }
  const marks = [];
  for (const op of ops.reverse()) {
    const r = doc.createRange();
    r.setStart(op.node, op.from);
    r.setEnd(op.node, op.to);
    const mark = doc.createElement("mark");
    mark.className = "hl";
    mark.dataset.commentId = commentId;
    try {
      r.surroundContents(mark);
      marks.push(mark);
    } catch {
      /* segment straddles an element boundary; skip it */
    }
  }
  return marks;
}

/** Heading text with any trailing nav/cross-link run trimmed off. */
export function headingTitle(el) {
  return el.textContent.replace(/\s*[·↑↳→].*$/u, "").trim();
}

/** Map every orderable element (text block or notes box) to its document index. */
export function buildOrderIndex(contentEl) {
  const map = new Map();
  contentEl
    .querySelectorAll("[data-block-id], .notes-box")
    .forEach((el, i) => map.set(el, i));
  return map;
}

/** Map each block id to its nearest preceding heading (the section label). */
export function buildSectionMap(contentEl) {
  const map = new Map();
  let current = { id: "preamble", title: "Preamble" };
  contentEl.querySelectorAll("h2, h3, [data-block-id]").forEach((el) => {
    if (el.tagName === "H2" || el.tagName === "H3") {
      current = { id: el.id || "section", title: headingTitle(el) };
    }
    const bid = el.getAttribute("data-block-id");
    if (bid) map.set(bid, current);
  });
  return map;
}

/**
 * Collect a reviewer's non-empty feedback into compile-ready items, each tagged
 * with a document-order key (block/box index, then intra-block offset).
 */
export function gatherItems(state, contentEl, orderIndex, sectionOf) {
  const items = [];
  for (const c of state.comments) {
    if (!c.body || !c.body.trim()) continue;
    const block = contentEl.querySelector(`[data-block-id="${cssEscape(c.blockId)}"]`);
    const sec = sectionOf.get(c.blockId) || { id: "?", title: "Unanchored" };
    const idx = block ? orderIndex.get(block) ?? 1e6 : 1e6;
    items.push({
      kind: "margin",
      order: idx * 1e4 + (c.start || 0),
      sectionId: sec.id,
      sectionTitle: sec.title,
      quote: c.quote,
      body: c.body.trim(),
    });
  }
  contentEl.querySelectorAll(".notes-box").forEach((box) => {
    const sectionId = box.dataset.sectionId;
    const body = ((state.notes && state.notes[sectionId]) || "").trim();
    if (!body) return;
    items.push({
      kind: "note",
      order: (orderIndex.get(box) ?? 1e6) * 1e4,
      sectionId,
      sectionTitle: box.dataset.sectionTitle,
      body,
    });
  });
  return items;
}

/** Re-highlight a stored comment against the live block, returning its marks. */
export function repaintHighlight(contentEl, comment) {
  const block = contentEl.querySelector(`[data-block-id="${cssEscape(comment.blockId)}"]`);
  if (!block) return { block: null, marks: [] };
  const r = resolveAnchor(block.textContent, comment);
  return { block, marks: r.ok ? highlightRange(block, r.start, r.end, comment.id) : [] };
}

export function cssEscape(s) {
  return typeof CSS !== "undefined" && CSS.escape ? CSS.escape(s) : String(s).replace(/["\\]/g, "\\$&");
}
