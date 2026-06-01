// Minimal static server for previewing the generated site locally.
// `npm run preview` then open the printed URL. ES modules need a real origin
// (file:// won't load them), which is the whole reason this exists.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const DIST = join(fileURLToPath(new URL(".", import.meta.url)), "dist");
const PORT = process.env.PORT || 4173;
const TYPES = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".map": "application/json",
};

createServer(async (req, res) => {
  try {
    const rel = normalize(decodeURIComponent(req.url.split("?")[0])).replace(/^(\.\.[/\\])+/, "");
    const path = join(DIST, rel === "/" || rel === "\\" ? "index.html" : rel);
    const body = await readFile(path);
    res.writeHead(200, { "content-type": TYPES[extname(path)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end("Not found");
  }
}).listen(PORT, () => console.log(`Preview: http://localhost:${PORT}/  (Ctrl-C to stop)`));
