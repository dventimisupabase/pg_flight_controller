// Compile a reviewer's in-page feedback into a single Markdown issue body.
//
// Items (margin comments and section notes) are emitted in DOCUMENT order, not
// the order they were created, so the author reads them in context. Margin
// comments carry the highlighted RFC passage as a blockquote (we control that
// text, so blockquoting keeps a stray ``` from opening a code block); section
// notes are the reviewer's own Markdown, included verbatim.

/** Quote text as a Markdown blockquote, prefixing every line (blank lines -> ">"). */
export function toBlockquote(text) {
  return text
    .split("\n")
    .map((line) => (line.length ? `> ${line}` : ">"))
    .join("\n");
}

/**
 * @param {object} o
 * @param {string} o.rfcUrl    URL of the published explainer page
 * @param {Array<object>} o.items  { kind: "margin"|"note", order, sectionId, sectionTitle, quote?, body }
 * @returns {string} Markdown body for a prefilled GitHub issue
 *
 * No author field: GitHub attributes the issue to whoever submits it (their
 * logged-in session), so the submitter's identity is captured automatically.
 */
export function compileFeedback({ rfcUrl, items }) {
  const ordered = [...items].sort((a, b) => a.order - b.order);

  const blocks = [
    `# RFC review`,
    `_Submitted via the [RFC explainer](${rfcUrl})._`,
  ];

  for (const item of ordered) {
    const label = item.kind === "margin" ? "margin comment" : "section notes";
    blocks.push(`## §${item.sectionId} — ${item.sectionTitle} _(${label})_`);
    if (item.kind === "margin") {
      blocks.push(toBlockquote(item.quote));
    }
    blocks.push(item.body.replace(/[ \t]+$/gm, ""));
  }

  return blocks.join("\n\n");
}
