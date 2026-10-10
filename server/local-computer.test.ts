// The node-only half of "this computer": the gate's spawn contract. The
// descriptor reader's invariants live in jac/harness/local_computer.test.jac.
import { describe, expect, it } from "vitest";

import { gatedLocalComputer } from "./local-computer.ts";
import { SPAWNED_PROXIES } from "./proxy-paths.ts";

describe("local computer descriptor contract", () => {
  it("wraps only the transport while preserving descriptor identity and original driver environment", () => {
    const connection = {
      command: "/trusted/cua-driver", args: ["mcp", "--socket", "/trusted/driver.sock"],
      env: { CUA_DRIVER_EMBEDDED: "1", DISPLAY: ":4" },
      platform: "linux" as const, scope: "local-computer" as const, generation: "fixture-generation",
    };
    const gated = gatedLocalComputer(connection, { url: "http://127.0.0.1:1234/control", token: "fixture-token" });
    expect(gated).toMatchObject({ command: process.execPath, args: ["--experimental-strip-types", SPAWNED_PROXIES.localComputer], platform: "linux", scope: "local-computer", generation: connection.generation });
    expect(gated.env).toEqual({ ...connection.env, ELECTRON_RUN_AS_NODE: "1", OMB_CUA_COMMAND: connection.command, OMB_CUA_ARGS: JSON.stringify(connection.args), OMB_CONTROL_URL: "http://127.0.0.1:1234/control", OMB_CONTROL_TOKEN: "fixture-token" });
    expect(gated.args.join(" ")).not.toContain("fixture-token");
    expect(connection.env).not.toHaveProperty("OMB_CONTROL_TOKEN");
  });
  it("owns the helper's Node mode even when the daemon environment disagrees", () => {
    const gated = gatedLocalComputer({ command: "/trusted/cua-driver", args: ["mcp"], env: { ELECTRON_RUN_AS_NODE: "0" }, platform: "darwin", scope: "local-computer" }, { url: "http://127.0.0.1:1234/control", token: "fixture-token" });
    expect(gated.env.ELECTRON_RUN_AS_NODE).toBe("1");
  });
});
