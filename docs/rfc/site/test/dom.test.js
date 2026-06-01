// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import {
  offsetWithin,
  highlightRange,
  buildOrderIndex,
  buildSectionMap,
  gatherItems,
  repaintHighlight,
} from "../src/app/dom.js";

function content(html) {
  document.body.innerHTML = `<article id="c">${html}</article>`;
  return document.getElementById("c");
}

describe("offsetWithin", () => {
  it("measures text offset across inline markup", () => {
    const c = content('<p data-block-id="b1">PostgreSQL <strong>knobs</strong> are static.</p>');
    const strong = c.querySelector("strong").firstChild; // "knobs"
    // offset to the start of "knobs" == length of "PostgreSQL "
    expect(offsetWithin(c.querySelector("p"), strong, 0)).toBe("PostgreSQL ".length);
  });
});

describe("highlightRange", () => {
  it("wraps the exact slice in a mark, even spanning inline elements", () => {
    const c = content('<p data-block-id="b1">alpha <em>beta</em> gamma</p>');
    const p = c.querySelector("p");
    const text = p.textContent; // "alpha beta gamma"
    const start = text.indexOf("beta");
    const end = text.indexOf("gamma") + "gamma".length; // "beta gamma"
    const marks = highlightRange(p, start, end, "cid-1");
    expect(marks.length).toBeGreaterThan(0);
    const marked = [...p.querySelectorAll('mark.hl[data-comment-id="cid-1"]')]
      .map((m) => m.textContent)
      .join("");
    expect(marked).toBe("beta gamma");
    expect(p.textContent).toBe("alpha beta gamma"); // text content preserved
  });
});

describe("repaintHighlight", () => {
  it("re-anchors a stored comment by its quote and highlights it", () => {
    const c = content('<p data-block-id="b1">keep the database self-stabilizing</p>');
    const { block, marks } = repaintHighlight(c, {
      id: "x",
      blockId: "b1",
      start: 0,
      end: 4,
      quote: "self-stabilizing",
    });
    expect(block).toBeTruthy();
    expect(marks.map((m) => m.textContent).join("")).toBe("self-stabilizing");
  });
});

describe("gatherItems", () => {
  it("returns margin comments and notes in document order with section labels", () => {
    const c = content(`
      <h2 id="1-abstract">1. Abstract</h2>
      <p data-block-id="1-abstract-b1">first block</p>
      <aside class="notes-box" data-section-id="1-abstract" data-section-title="Abstract"></aside>
      <h2 id="3-architecture">3. Architecture</h2>
      <p data-block-id="3-architecture-b1">later block</p>
    `);
    const orderIndex = buildOrderIndex(c);
    const sectionOf = buildSectionMap(c);
    const state = {
      // intentionally out of document order to prove sorting in compile
      comments: [
        { id: "a", blockId: "3-architecture-b1", start: 2, quote: "later", body: "second" },
        { id: "b", blockId: "1-abstract-b1", start: 0, quote: "first", body: "FIRST" },
        { id: "c", blockId: "1-abstract-b1", start: 0, quote: "first", body: "   " }, // empty -> dropped
      ],
      notes: { "1-abstract": "a section note" },
    };
    const items = gatherItems(state, c, orderIndex, sectionOf);

    // empty-bodied comment dropped
    expect(items.filter((i) => i.kind === "margin")).toHaveLength(2);
    // section labels resolved from nearest heading
    const abstractMargin = items.find((i) => i.body === "FIRST");
    expect(abstractMargin.sectionId).toBe("1-abstract");
    expect(abstractMargin.sectionTitle).toBe("1. Abstract");
    // the note belongs after its section's blocks but before the next section
    const sorted = [...items].sort((a, b) => a.order - b.order);
    expect(sorted.map((i) => i.body)).toEqual(["FIRST", "a section note", "second"]);
  });
});
