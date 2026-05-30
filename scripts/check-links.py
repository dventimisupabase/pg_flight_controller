#!/usr/bin/env python3
"""Verify internal markdown links resolve (files exist; #fragments match an anchor).

Anchors recognized per file: GitHub-style heading slugs AND explicit HTML anchors
(`<a id="...">` / `<a name="...">`). External links (http/https/mailto) are skipped;
this checker only guards *internal* references, which is where silent rot happens.

Usage: check-links.py <repo_root>   (exit 1 on any dangling internal link)
"""
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."

LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
EXPLICIT = re.compile(r"""<a\s+(?:id|name)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)


def gh_slug(text):
    t = text.strip().lower().replace("`", "")
    t = re.sub(r"<[^>]+>", "", t)            # drop any inline HTML
    t = re.sub(r"[^\w\s-]", "", t, flags=re.UNICODE)  # keep word chars, spaces, hyphens
    return t.replace(" ", "-")


def parse(path):
    """Return (anchors:set, links:list[(target,lineno)]) skipping fenced code."""
    anchors, links, slug_counts = set(), [], {}
    fenced = False
    for lineno, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        for m in EXPLICIT.finditer(line):
            anchors.add(m.group(1))
        h = HEADING.match(line)
        if h:
            base = gh_slug(h.group(2))
            n = slug_counts.get(base, 0)
            slug_counts[base] = n + 1
            anchors.add(base if n == 0 else f"{base}-{n}")
        for m in LINK.finditer(line):
            target = m.group(1).split()[0].strip("<>")  # drop "title", angle brackets
            links.append((target, lineno))
    return anchors, links


def main():
    md = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules")]
        for fn in files:
            if not fn.endswith(".md"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root)
            if rel.split(os.sep)[0] == "in":
                continue
            md.append(os.path.join(dirpath, fn))

    cache = {p: parse(p) for p in md}
    problems = []
    for path in md:
        anchors, links = cache[path]
        for target, lineno in links:
            if re.match(r"^(https?:|mailto:|tel:)", target):
                continue
            filepart, _, frag = target.partition("#")
            if filepart == "":
                tgt_anchors = anchors            # same-file fragment
            else:
                tgt = os.path.normpath(os.path.join(os.path.dirname(path), filepart))
                if not os.path.exists(tgt):
                    problems.append(f"{path}:{lineno}: missing file: {target}")
                    continue
                tgt_anchors = cache[tgt][0] if tgt in cache else None
            if frag and tgt_anchors is not None and frag not in tgt_anchors:
                problems.append(f"{path}:{lineno}: missing anchor: {target}")

    if problems:
        print("Dangling internal links:")
        for p in sorted(problems):
            print("  " + p)
        sys.exit(1)
    print(f"All internal links resolve ({len(md)} files checked).")


if __name__ == "__main__":
    main()
