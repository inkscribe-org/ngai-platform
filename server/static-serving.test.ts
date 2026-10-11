// Unit tests for the static file server's traversal defenses. These call
// serveStatic directly (a recording stub stands in for ServerResponse), so
// every escape shape is asserted at the exact seam where index.ts hands it
// the raw url.pathname — no server boot needed.
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { serveStatic } from "./static-serving.ts";

const UI_PAGE = "<!doctype html>omb-static-fixture";
const SECRET = "TOP SECRET — must never be served";

/** Records writeHead/end the way serveStatic drives them. */
function recorder() {
  const calls: { status?: number; headers?: Record<string, string>; body?: unknown } = {};
  const res = {
    writeHead(status: number, headers?: Record<string, string>) {
      calls.status = status;
      calls.headers = headers ?? {};
    },
    end(data?: unknown) {
      // Production passes readFileSync Buffers; assertions compare content.
      calls.body = Buffer.isBuffer(data) ? data.toString() : data;
    },
  };
  return { calls, res: res as unknown as ServerResponse };
}

describe("serveStatic", () => {
  let root: string;
  let outside: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "omb-static-root-"));
    outside = mkdtempSync(join(tmpdir(), "omb-static-out-"));
    writeFileSync(join(root, "index.html"), UI_PAGE);
    mkdirSync(join(root, "assets"));
    writeFileSync(join(root, "assets", "app-H4SH.js"), "console.log(1);\n");
    writeFileSync(join(root, "real.txt"), "hello\n");
    writeFileSync(join(root, "blob.dat"), "x");
    // The escape targets: real files outside the root, plus a symlink inside
    // the root pointing at one and another staying inside it.
    writeFileSync(join(outside, "secret.txt"), SECRET);
    symlinkSync(join(outside, "secret.txt"), join(root, "sneaky.js"));
    symlinkSync(join(root, "real.txt"), join(root, "alias.txt"));
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  });

  it("serves the SPA page at /", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/", root)).toBe(true);
    expect(calls.status).toBe(200);
    expect(calls.body).toBe(UI_PAGE);
    expect(calls.headers?.["content-type"]).toBe("text/html");
    expect(calls.headers?.["cache-control"]).toBe("no-cache");
    expect(calls.headers?.["x-frame-options"]).toBe("DENY");
    expect(calls.headers?.["content-security-policy"]).toBe("frame-ancestors 'none'");
  });

  it("serves hashed assets as immutable", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/assets/app-H4SH.js", root)).toBe(true);
    expect(calls.status).toBe(200);
    expect(calls.body).toBe("console.log(1);\n");
    expect(calls.headers?.["content-type"]).toBe("text/javascript");
    expect(calls.headers?.["cache-control"]).toBe("public, max-age=31536000, immutable");
  });

  it("serves plain files with the table's type and no cache header", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/real.txt", root)).toBe(true);
    expect(calls.headers?.["content-type"]).toBe("text/plain; charset=utf-8");
    expect(calls.headers?.["cache-control"]).toBeUndefined();
  });

  it("serves unknown extensions as octet-stream", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/blob.dat", root)).toBe(true);
    expect(calls.headers?.["content-type"]).toBe("application/octet-stream");
  });

  it("falls back to the SPA page for missing paths", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/threads/abc", root)).toBe(true);
    expect(calls.status).toBe(200);
    expect(calls.body).toBe(UI_PAGE);
    expect(calls.headers?.["content-type"]).toBe("text/html");
    expect(calls.headers?.["cache-control"]).toBe("no-cache");
  });

  it("falls back for directory paths", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/assets/", root)).toBe(true);
    expect(calls.body).toBe(UI_PAGE);
  });

  it("serves a symlink that stays inside the root", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/alias.txt", root)).toBe(true);
    expect(calls.body).toBe("hello\n");
    expect(calls.headers?.["content-type"]).toBe("text/plain; charset=utf-8");
  });

  it("answers nothing when no static dir is configured", () => {
    const { calls, res } = recorder();
    expect(serveStatic(res, "/", null)).toBe(false);
    expect(calls.status).toBeUndefined();
  });

  it("answers nothing when the root has no index.html to fall back to", () => {
    const empty = mkdtempSync(join(tmpdir(), "omb-static-empty-"));
    try {
      const { calls, res } = recorder();
      expect(serveStatic(res, "/threads/abc", empty)).toBe(false);
      expect(calls.status).toBeUndefined();
    } finally {
      rmSync(empty, { recursive: true, force: true });
    }
  });

  // Every case here names a file that exists OUTSIDE the root; a refusal is
  // the only acceptable outcome, and the recorder must stay untouched (the
  // caller answers 404 when serveStatic returns false).
  describe("traversal attempts are refused, never served", () => {
    const escapes = [
      ["percent-encoded separators", "/..%2f..%2f..%2fsecret.txt"],
      ["percent-encoded dots", "/%2e%2e/%2e%2e/secret.txt"],
      ["nested climb through a real dir", "/assets/x/../../../secret.txt"],
      ["climb through the cached-assets prefix", "/assets/../../secret.txt"],
      ["encoded backslashes", "/..%5c..%5csecret.txt"],
      ["raw backslashes", "/..\\..\\secret.txt"],
      ["null byte mid-path", "/secret.txt%00.js"],
      ["null byte alone", "/%00"],
      ["malformed escape", "/%zz"],
      ["overlong UTF-8 dots", "/%c0%ae%c0%ae/secret.txt"],
      ["symlink pointing outside the root", "/sneaky.js"],
    ] as const;
    for (const [name, requestPath] of escapes) {
      it(`refuses ${name}`, () => {
        const { calls, res } = recorder();
        expect(serveStatic(res, requestPath, root)).toBe(false);
        expect(calls.status).toBeUndefined();
        expect(calls.body).toBeUndefined();
      });
    }
  });

  // Not escapes: after one decode and a root-pinned resolve these name
  // missing paths inside the root, so they keep the SPA-fallback semantics —
  // the assertions prove that by demanding the fixture page, not the secrets.
  describe("lookalike paths resolve inside the root and fall back", () => {
    const fallbacks = [
      ["an absolute-looking path is pinned to the root", "/etc/passwd"],
      ["dot-dot-dot names are plain segments", "/....//....//secret.txt"],
      ["fullwidth dots are not separators", "/%ef%bc%8e%ef%bc%8e/secret.txt"],
      ["double-encoded dots decode once", "/%252e%252e%252fsecret.txt"],
    ] as const;
    for (const [name, requestPath] of fallbacks) {
      it(`serves the SPA page for ${name}`, () => {
        const { calls, res } = recorder();
        expect(serveStatic(res, requestPath, root)).toBe(true);
        expect(calls.body).toBe(UI_PAGE);
        expect(calls.headers?.["content-type"]).toBe("text/html");
      });
    }
  });
});
