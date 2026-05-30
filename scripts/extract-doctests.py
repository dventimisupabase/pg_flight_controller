#!/usr/bin/env python3
"""Extract doctest SQL blocks from project markdown.

Convention (opt-in): a fenced ```sql block is a doctest iff the line immediately
before it (ignoring blank lines) is the HTML comment `<!-- doctest -->`. Such blocks
are executed by scripts/run-doctests.sh against a fresh install and must succeed.
Unmarked ```sql blocks (install snippets, illustrative examples) are left alone.

Usage: extract-doctests.py <repo_root> <out_dir>
Writes <out_dir>/0001.sql, 0002.sql, ... (deterministic order) and prints the count.
"""
import os
import re
import sys

root, out_dir = sys.argv[1], sys.argv[2]
SQL_FENCE = re.compile(r"^```sql\s*$")

# Discover markdown deterministically, excluding source inputs and generated docs.
md_files = []
for dirpath, dirs, files in os.walk(root):
    dirs[:] = sorted(d for d in dirs if d not in (".git", "node_modules"))
    for fn in sorted(files):
        if not fn.endswith(".md"):
            continue
        rel = os.path.relpath(os.path.join(dirpath, fn), root)
        parts = rel.split(os.sep)
        if parts[0] == "in":
            continue
        if rel.startswith(os.path.join("docs", "reference") + os.sep):
            continue
        md_files.append((rel, os.path.join(dirpath, fn)))
md_files.sort()

idx = 0
for rel, path in md_files:
    lines = open(path, encoding="utf-8").read().split("\n")
    pending = False
    i, n = 0, len(lines)
    while i < n:
        s = lines[i].strip()
        if s == "<!-- doctest -->":
            pending = True
            i += 1
            continue
        if s.startswith("```"):
            j = i + 1
            while j < n and lines[j].strip() != "```":
                j += 1
            if pending and SQL_FENCE.match(s):
                idx += 1
                sql = "\n".join(lines[i + 1:j])
                with open(os.path.join(out_dir, f"{idx:04d}.sql"), "w", encoding="utf-8") as fh:
                    fh.write(f"-- doctest from {rel}:{i + 2}\n{sql}\n")
            pending = False          # any fence consumes the marker
            i = j + 1
            continue
        if s and pending:            # marker not followed by a sql fence: drop it
            pending = False
        i += 1

print(idx)
