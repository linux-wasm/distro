#!/usr/bin/env node
// Serve the built site (work/site/) on http://127.0.0.1:8080/.
//
//   scripts/serve.mjs [--port 8080] [--plain]
//
// By default the server sends the two headers that make the page
// cross-origin isolated (needed for SharedArrayBuffer). --plain leaves them
// out, like GitHub Pages, so that site/sw.js has to supply them.
import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
  options: {
    port: { type: "string", default: "8080" },
    plain: { type: "boolean", default: false },
  },
});

const root = fileURLToPath(new URL("../work/site/", import.meta.url));
if (!existsSync(root)) {
  console.error(`${root} does not exist; run scripts/build.sh first`);
  process.exit(1);
}

const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".json": "application/json",
  ".wasm": "application/wasm",
};

createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
  let file = join(root, path);
  if (!file.startsWith(root)) file = root;
  if (existsSync(file) && statSync(file).isDirectory()) file = join(file, "index.html");
  if (!existsSync(file)) {
    res.writeHead(404).end("not found\n");
    return;
  }
  const headers = {
    "Content-Type": types[extname(file)] ?? "application/octet-stream",
    "Cache-Control": "no-store",
  };
  if (!args.plain) {
    headers["Cross-Origin-Opener-Policy"] = "same-origin";
    headers["Cross-Origin-Embedder-Policy"] = "require-corp";
  }
  res.writeHead(200, headers);
  createReadStream(file).pipe(res);
}).listen(Number(args.port), "127.0.0.1", () =>
  console.log(`http://127.0.0.1:${args.port}/${args.plain ? " (plain, no COOP/COEP)" : ""}`),
);
