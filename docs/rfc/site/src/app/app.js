// RFC explainer comment layer.
//
// Backendless: marginalia and per-section notes live in localStorage while the
// reviewer works, then compile into one prefilled GitHub issue on submit (with a
// .md download fallback when the URL would be too long). The pure logic
// (anchoring, URL building, overflow, compilation) is shared with — and unit
// tested in — ../lib.

import { captureAnchor } from "../lib/anchor.js";
import { buildIssueUrl } from "../lib/issue-url.js";
import { isOverflow } from "../lib/overflow.js";
import { compileFeedback } from "../lib/compile.js";
import {
  offsetWithin,
  highlightRange,
  buildOrderIndex,
  buildSectionMap,
  gatherItems,
  repaintHighlight,
  cssEscape,
} from "./dom.js";

const OWNER = document.body.dataset.repoOwner;
const REPO = document.body.dataset.repoName;
const STORE_KEY = `pgfc-rfc::${OWNER}/${REPO}`;

const contentEl = document.getElementById("rfc-content");
const railEl = document.getElementById("comment-rail");
const popEl = document.getElementById("selection-pop");
const handleEl = document.getElementById("reviewer-handle");
const countEl = document.getElementById("feedback-count");
const submitEl = document.getElementById("submit-feedback");

// ---- State ------------------------------------------------------------

const state = load();
const editors = new Map(); // sectionId -> EasyMDE
let pending = null; // { blockId, start, end, quote } captured on selection

function load() {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY)) || blank();
  } catch {
    return blank();
  }
}
function blank() {
  return { reviewer: "", comments: [], notes: {} };
}
function save() {
  localStorage.setItem(STORE_KEY, JSON.stringify(state));
  updateCount();
}

// ---- Document-order + section metadata --------------------------------

const orderIndex = buildOrderIndex(contentEl);
const sectionOf = buildSectionMap(contentEl);

// ---- Marginalia: selection -> highlight -> card -----------------------

function blockOf(node) {
  const el = node.nodeType === 1 ? node : node.parentElement;
  const block = el && el.closest("[data-block-id]");
  if (!block) return null;
  if (block.closest(".notes-box")) return null; // notes boxes own their editor
  if (!contentEl.contains(block)) return null;
  return block;
}

document.addEventListener("mouseup", () => {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return hidePop();
  const range = sel.getRangeAt(0);
  const startBlock = blockOf(range.startContainer);
  const endBlock = blockOf(range.endContainer);
  if (!startBlock || startBlock !== endBlock) return hidePop(); // within-block only

  let start = offsetWithin(startBlock, range.startContainer, range.startOffset);
  let end = offsetWithin(startBlock, range.endContainer, range.endOffset);
  if (start > end) [start, end] = [end, start];
  if (start === end) return hidePop();

  try {
    pending = captureAnchor(startBlock.dataset.blockId, startBlock.textContent, start, end);
  } catch {
    return hidePop();
  }
  const rect = range.getBoundingClientRect();
  popEl.style.left = `${rect.left + rect.width / 2 + window.scrollX}px`;
  popEl.style.top = `${rect.top + window.scrollY}px`;
  popEl.hidden = false;
});

popEl.addEventListener("mousedown", (e) => e.preventDefault()); // keep selection
popEl.addEventListener("click", () => {
  if (!pending) return;
  const comment = { id: cryptoId(), ...pending, body: "" };
  state.comments.push(comment);
  save();
  paintComment(comment);
  layoutCards();
  hidePop();
  window.getSelection().removeAllRanges();
  focusCard(comment.id);
});

function hidePop() {
  popEl.hidden = true;
  pending = null;
}

function paintComment(comment) {
  const { block } = repaintHighlight(contentEl, comment);
  renderCard(comment, block);
}

function renderCard(comment, block) {
  const card = document.createElement("div");
  card.className = "comment-card";
  card.dataset.commentId = comment.id;
  card.dataset.blockId = comment.blockId;

  const quote = document.createElement("div");
  quote.className = "comment-card__quote";
  quote.textContent = comment.quote;

  const ta = document.createElement("textarea");
  ta.placeholder = "Your comment…";
  ta.value = comment.body;
  ta.addEventListener("input", () => {
    comment.body = ta.value;
    save();
  });

  const actions = document.createElement("div");
  actions.className = "comment-card__actions";
  const del = document.createElement("button");
  del.className = "comment-card__delete";
  del.textContent = "Delete";
  del.addEventListener("click", () => deleteComment(comment.id));
  actions.appendChild(del);

  card.append(quote, ta, actions);
  card.addEventListener("mouseenter", () => activate(comment.id, false));
  railEl.appendChild(card);
}

function deleteComment(id) {
  state.comments = state.comments.filter((c) => c.id !== id);
  save();
  document
    .querySelectorAll(`mark.hl[data-comment-id="${cssEscape(id)}"]`)
    .forEach((m) => m.replaceWith(...m.childNodes));
  railEl.querySelector(`.comment-card[data-comment-id="${cssEscape(id)}"]`)?.remove();
  layoutCards();
}

function activate(id, scroll) {
  document.querySelectorAll(".comment-card.is-active, mark.hl.is-active").forEach((el) =>
    el.classList.remove("is-active")
  );
  document
    .querySelectorAll(`mark.hl[data-comment-id="${cssEscape(id)}"]`)
    .forEach((m) => m.classList.add("is-active"));
  const card = railEl.querySelector(`.comment-card[data-comment-id="${cssEscape(id)}"]`);
  card?.classList.add("is-active");
  if (scroll) card?.scrollIntoView({ block: "center", behavior: "smooth" });
}
function focusCard(id) {
  railEl
    .querySelector(`.comment-card[data-comment-id="${cssEscape(id)}"] textarea`)
    ?.focus();
}

// Stack cards near their anchors without overlapping. Anchor positions are read
// LIVE from each card's block on every layout (not cached at paint time), so the
// stack stays aligned across font reflow, resize, and content shifts.
function layoutCards() {
  railEl.style.height = `${contentEl.offsetHeight}px`;
  const contentTop = contentEl.getBoundingClientRect().top + window.scrollY;
  const cards = [...railEl.querySelectorAll(".comment-card")]
    .map((card) => {
      const block = contentEl.querySelector(`[data-block-id="${cssEscape(card.dataset.blockId)}"]`);
      const want = block ? block.getBoundingClientRect().top + window.scrollY - contentTop : 0;
      return { card, want };
    })
    .sort((a, b) => a.want - b.want);
  let cursor = 0;
  for (const { card, want } of cards) {
    const top = Math.max(want, cursor);
    card.style.top = `${top}px`;
    cursor = top + card.offsetHeight + 12;
  }
}

contentEl.addEventListener("click", (e) => {
  const mark = e.target.closest("mark.hl");
  if (mark) activate(mark.dataset.commentId, true);
});

// ---- Section notes (EasyMDE) ------------------------------------------

function mountNotes() {
  if (typeof EasyMDE === "undefined") return; // editor CDN unavailable
  document.querySelectorAll(".notes-box").forEach((box) => {
    const sectionId = box.dataset.sectionId;
    const ta = document.createElement("textarea");
    box.querySelector(".notes-box__mount").appendChild(ta);
    const editor = new EasyMDE({
      element: ta,
      autoDownloadFontAwesome: true,
      spellChecker: false,
      status: false,
      placeholder: "General notes on this section…",
      initialValue: state.notes[sectionId] || "",
      toolbar: [
        "bold",
        "italic",
        "heading",
        "|",
        "quote",
        "unordered-list",
        "ordered-list",
        "code",
        "|",
        "preview",
        "guide",
      ],
    });
    editor.codemirror.on("change", () => {
      const v = editor.value();
      if (v.trim()) state.notes[sectionId] = v;
      else delete state.notes[sectionId];
      save();
    });
    editors.set(sectionId, editor);
  });
}

// ---- Submit -----------------------------------------------------------

function submit() {
  const reviewer = handleEl.value.trim().replace(/^@/, "");
  if (!reviewer) {
    handleEl.focus();
    flash(handleEl);
    return;
  }
  state.reviewer = reviewer;
  save();

  const items = gatherItems(state, contentEl, orderIndex, sectionOf);
  if (!items.length) {
    countEl.textContent = "Nothing to submit yet — add a comment or note.";
    return;
  }
  const body = compileFeedback({ reviewer, rfcUrl: location.href, items });
  const title = `RFC review by @${reviewer}`;
  const url = buildIssueUrl({ owner: OWNER, repo: REPO, title, body });

  if (isOverflow(url)) {
    downloadMarkdown(`rfc-review-${reviewer}.md`, body);
    alert(
      "Your feedback is long enough that GitHub may truncate a prefilled issue, " +
        "so it has been downloaded as a Markdown file. Open a new issue and paste it in."
    );
  } else {
    window.open(url, "_blank", "noopener");
  }
}

function downloadMarkdown(filename, text) {
  const blob = new Blob([text], { type: "text/markdown" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  URL.revokeObjectURL(a.href);
}

// ---- Misc helpers -----------------------------------------------------

function updateCount() {
  const c = state.comments.filter((x) => x.body.trim()).length;
  const n = Object.values(state.notes).filter((v) => v.trim()).length;
  countEl.textContent =
    c + n === 0
      ? "No feedback yet"
      : `${c} comment${c === 1 ? "" : "s"}, ${n} section note${n === 1 ? "" : "s"}`;
}

function flash(el) {
  el.style.transition = "box-shadow .15s";
  el.style.boxShadow = "0 0 0 3px rgba(182,113,29,.6)";
  setTimeout(() => (el.style.boxShadow = ""), 600);
}

function cryptoId() {
  return (crypto.randomUUID?.() || String(Date.now() + Math.random())).slice(0, 12);
}

// ---- Scroll-spy TOC ---------------------------------------------------

function scrollSpy() {
  const links = [...document.querySelectorAll(".toc__item a")];
  const byId = new Map(links.map((a) => [a.getAttribute("href").slice(1), a]));
  const heads = [...contentEl.querySelectorAll("h2, h3")].filter((h) => byId.has(h.id));
  const obs = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          links.forEach((a) => a.classList.remove("is-active"));
          byId.get(e.target.id)?.classList.add("is-active");
        }
      }
    },
    { rootMargin: "0px 0px -75% 0px", threshold: 0 }
  );
  heads.forEach((h) => obs.observe(h));
}

// ---- Init -------------------------------------------------------------

handleEl.value = state.reviewer || "";
handleEl.addEventListener("change", () => {
  state.reviewer = handleEl.value.trim().replace(/^@/, "");
  save();
});
submitEl.addEventListener("click", submit);

mountNotes();
state.comments.forEach(paintComment);
layoutCards();
updateCount();
scrollSpy();

window.addEventListener("resize", layoutCards);
window.addEventListener("load", layoutCards); // re-run once fonts settle
