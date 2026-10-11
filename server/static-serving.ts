// Static file serving for the built UI: index.ts calls serveStatic for every
// non-API GET before route dispatch. Split out of index.ts so the traversal
// defenses have colocated unit tests instead of needing a full server boot.
import { readFileSync, realpathSync } from "node:fs";
import { type ServerResponse } from "node:http";
import { extname, isAbsolute, join, relative, resolve, sep } from "node:path";

/** The web UI's pages: never framed by another page (a hidden frame could
 * otherwise act on a pair or sign-in page unseen), and they send no Referer.
 * Nothing frames the web UI: the desktop app shows it in its own window. */
export const PAGE_HEADERS = { "content-security-policy": "frame-ancestors 'none'", "x-frame-options": "DENY", "referrer-policy": "no-referrer" } as const;

const MIME: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".json": "application/json",
  ".woff2": "font/woff2",
};

/** The built UI, when this process serves it (staticDir: OMB_STATIC_DIR, set
 * by the desktop app and by the container image). Public by design: it is the
 * same bundle anyone can download, holds no secrets, and a remote browser
 * must be able to load /pair before it has a session. Returns false when
 * there is nothing to serve so the caller can answer 404.
 *
 * `path` is the raw, still percent-encoded url.pathname. Resolution policy:
 * decode once, refuse hostile shapes (bad escapes, NUL, backslashes, any ".."
 * segment), then resolve inside the root and require the resolved path — and
 * for files that exist, their symlink target — to stay inside it. Stripping
 * ".." from the raw string is not a defense: it never sees encoded dots, and
 * join/resolve would happily climb out of the root. Escape attempts return
 * false (the caller 404s); they never fall back to the SPA page.
 *
 * Symlink policy: the bundle is a build artifact, so a symlink inside it is
 * either a packaging mistake or an attack. A file that exists on disk is
 * checked at its realpath, so nothing inside the root can serve a target
 * outside it; symlinks that stay inside the root keep working. */
export function serveStatic(res: ServerResponse, path: string, staticDir: string | null): boolean {
  if (!staticDir) return false;
  // Browsers may hand us any byte sequence; a malformed escape ("%zz", or
  // overlong UTF-8 like "%c0%ae" posing as ".") names no UI asset.
  let decoded: string;
  try {
    decoded = decodeURIComponent(path);
  } catch {
    return false;
  }
  // NUL truncates paths in some syscalls, and a backslash is a segment
  // separator on Windows — in a URL it is only ever an evasion attempt,
  // never a Vite asset name. Refuse both outright.
  if (decoded.includes("\0") || decoded.includes("\\")) return false;
  const safe = decoded.startsWith("/") ? decoded : `/${decoded}`;
  const root = resolve(staticDir);
  // The leading "." pins absolute-looking requests ("/etc/passwd") to the
  // root: resolve() would otherwise adopt them as new absolute paths.
  const file = resolve(root, `.${safe}`);
  // Containment is checked on resolved path segments, not a string prefix of
  // the raw request: relative() yields leading ".." segments only for real
  // climbs out of the root, while "..hidden" stays a legal file name, and an
  // absolute relative() result covers cross-drive paths on Windows.
  const rel = relative(root, file);
  if (isAbsolute(rel) || rel.split(sep).includes("..")) return false;
  try {
    // Root is realpathed too: on macOS (/var → /private/var) and anywhere
    // else the root itself sits under a symlink, only real-to-real comparison
    // can tell an internal symlink from an escaping one.
    const realRel = relative(realpathSync(root), realpathSync(file));
    if (isAbsolute(realRel) || realRel.split(sep).includes("..")) return false;
  } catch {
    // Missing file — the normal SPA-fallback case; the lexical check above
    // already bounded it. Any other stat error surfaces from readFileSync
    // below.
  }
  try {
    const data = readFileSync(file);
    const type = MIME[extname(file)] ?? "application/octet-stream";
    // Vite puts a content hash in the name of every file it writes under
    // /assets/, so a URL there never changes: the browser keeps it instead of
    // downloading the bundle on every load. That only holds while public/ has
    // no assets/ dir (index.test.ts checks). Pages are revalidated, so a new
    // build shows up on the next load.
    const cache = type === "text/html" ? "no-cache" : safe.startsWith("/assets/") ? "public, max-age=31536000, immutable" : null;
    res.writeHead(200, { "content-type": type, ...(type === "text/html" ? PAGE_HEADERS : {}), ...(cache ? { "cache-control": cache } : {}) });
    res.end(data);
    return true;
  } catch {
    // SPA fallback. Never immutable: a missing chunk answered with the page
    // must not stay cached under the chunk's URL.
    try {
      const data = readFileSync(join(staticDir, "index.html"));
      res.writeHead(200, { "content-type": "text/html", "cache-control": "no-cache", ...PAGE_HEADERS });
      res.end(data);
      return true;
    } catch {
      return false;
    }
  }
}
