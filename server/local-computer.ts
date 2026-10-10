// "Works on: This computer". Reading and validating the CUA Driver
// descriptor Electron publishes (legacy darwin/win32 and supervised Linux,
// with its file-identity, ownership and liveness checks) runs in the Jac
// harness (jac/harness/local_computer.jac, reached through
// readCuaConnection / readCuaUnavailableReason in server/jac-computers.ts).
// What stays here is the connection type and the node-only spawn contract:
// the gate is a node process (process.execPath), so node builds its argv.
import { SPAWNED_PROXIES } from "./proxy-paths.ts";

export type LocalComputerConnection = {
  command: string;
  args: string[];
  env: Record<string, string>;
  platform: "darwin" | "linux" | "win32";
  generation?: string;
  scope: "local-computer";
};

/** Keep the platform descriptor intact, but acquire computer authority only
 * when the first actual tool call reaches the shared stdio gate. */
export function gatedLocalComputer(
  connection: LocalComputerConnection,
  control: { url: string; token: string },
): LocalComputerConnection {
  return {
    ...connection,
    command: process.execPath,
    args: ["--experimental-strip-types", SPAWNED_PROXIES.localComputer],
    env: {
      ...connection.env,
      // In a packaged desktop process execPath is Electron, not node. Without
      // this the MCP client relaunches OMB, whose single-instance handler
      // focuses the user's window, instead of starting the headless gate.
      ELECTRON_RUN_AS_NODE: "1",
      OMB_CUA_COMMAND: connection.command,
      OMB_CUA_ARGS: JSON.stringify(connection.args),
      OMB_CONTROL_URL: control.url,
      OMB_CONTROL_TOKEN: control.token,
    },
  };
}
