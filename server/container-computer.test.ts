// The pure Local VM contract that stays in node (identities, image recipe,
// argv, spawn spec, readiness predicates). The lifecycle — status parsing,
// lifecycle actions, frames, exec — is tested in
// jac/harness/container_computer.test.jac against fake runners.
import { describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  BASE_IMAGE,
  CONTAINER,
  CUA_DRIVER_VERSION,
  CUA_EXECUTABLE,
  CUA_SOCKET,
  DRIVER_LABEL,
  IMAGE,
  IMAGE_LAYER_LABEL,
  IMAGE_LAYER_VERSION,
  MANAGED_LABEL,
  TARGET_LABEL,
  VM_WORKSPACE_DIR,
  VM_WORKSPACE_GUEST,
  WORKSPACE_LABEL,
  containerComputerMcp,
  containerRunArgs,
  localVmWorkspaceExists,
  managedImageDockerfile,
  perBotLocalVmTarget,
  setupCommands,
  autoLocalVmAttachable,
} from "./container-computer.ts";

it("recognizes only a durable VM workspace directory as prior provisioning evidence", () => {
  const root = mkdtempSync(join(tmpdir(), "omb-vm-workspace-"));
  const target = { ...perBotLocalVmTarget("workspace-fixture"), workspaceDir: join(root, "workspace") };
  try {
    expect(localVmWorkspaceExists(target)).toBe(false);
    writeFileSync(target.workspaceDir, "not a directory");
    expect(localVmWorkspaceExists(target)).toBe(false);
    rmSync(target.workspaceDir);
    mkdirSync(target.workspaceDir);
    expect(localVmWorkspaceExists(target)).toBe(true);
    const link = join(root, "linked-workspace");
    symlinkSync(target.workspaceDir, link, "junction");
    expect(localVmWorkspaceExists({ ...target, workspaceDir: link })).toBe(false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

describe("Cua integration", () => {
  it("mounts the official Cua MCP server for Local VM turns", () => {
    const connection = containerComputerMcp("podman");
    expect(connection.command).toBe(process.execPath);
    expect(connection.args.at(-3)).toBe("podman");
    expect(connection.args.at(-2)).toBe(CONTAINER);
    expect(connection.args.at(-1)).toBe(CUA_SOCKET);
    expect(connection.env).toEqual({ ELECTRON_RUN_AS_NODE: "1" });
  });

  it("builds an exact, checksum-verified Cua Driver 0.20.0 image", () => {
    const dockerfile = managedImageDockerfile();
    expect(BASE_IMAGE).toMatch(/@sha256:[a-f0-9]{64}$/);
    expect(dockerfile).toContain(`FROM ${BASE_IMAGE}`);
    expect(dockerfile).toContain("cua_driver-0.20.0-py3-none-manylinux_2_31_x86_64.whl");
    expect(dockerfile).toContain("cua_driver-0.20.0-py3-none-manylinux_2_31_aarch64.whl");
    expect(dockerfile).not.toContain("/tmp/cua-driver.whl");
    expect(dockerfile).toContain("sha256sum -c -");
    expect(dockerfile).toContain(`install -D -m 0755 "$driver_bin" ${CUA_EXECUTABLE}`);
    expect(dockerfile).toContain(`cua-driver ${CUA_DRIVER_VERSION}`);
    expect(dockerfile).toContain(`serve --socket ${CUA_SOCKET} --permission-mode standard`);
    expect(dockerfile).toContain("CUA_DRIVER_RS_TELEMETRY_ENABLED=0");
    expect(dockerfile).toContain("prepare-openmausbot-workspace.sh");
    expect(dockerfile).toContain('if ! chmod 0700 "$workspace"');
    expect(dockerfile).toContain('test -r "$directory" && test -w "$directory" && test -x "$directory"');
    expect(dockerfile).toContain("migrate_profile google-chrome");
    expect(dockerfile).toContain("migrate_profile chromium");
    expect(dockerfile).toContain("SingletonLock");
    expect(dockerfile).toContain(`${IMAGE_LAYER_LABEL}="${IMAGE_LAYER_VERSION}"`);
    expect(dockerfile).toContain("did not become ready within 45 seconds");
    expect(dockerfile).not.toContain("while ! DISPLAY=:1 xset q");
  });

  it("installs checksum-pinned Japanese fonts and their license before the desktop starts", () => {
    const dockerfile = managedImageDockerfile();
    expect(dockerfile).toContain("NotoSansCJKjp-Regular.otf");
    expect(dockerfile).toContain("68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5");
    expect(dockerfile).toContain("6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2");
    expect(dockerfile).toContain("/usr/local/share/licenses/noto-cjk/OFL.txt");
    expect(dockerfile).toContain("fc-cache -f");
    expect(IMAGE_LAYER_VERSION).toBe("5");
  });

  it("rejects a zero-byte OpenSSL base image before the wheel download needs curl", () => {
    const dockerfile = managedImageDockerfile();
    // both multiarch triplets, both OpenSSL libraries
    expect(dockerfile).toContain('"/lib/$lib_triplet/libssl.so.3"');
    expect(dockerfile).toContain('"/lib/$lib_triplet/libcrypto.so.3"');
    expect(dockerfile).toContain("[ ! -s \"$ssl_lib\" ]");
    expect(dockerfile).toContain("is zero bytes, so curl cannot start");
    // the gate runs in the same RUN as the fetch, ahead of it — a defective
    // layer must be named before curl has any chance to fail confusingly
    const gate = dockerfile.indexOf('[ ! -s "$ssl_lib" ]');
    const fetch = dockerfile.indexOf("curl -fsSL");
    expect(gate).toBeGreaterThan(-1);
    expect(fetch).toBeGreaterThan(gate);
  });

});

describe("setupCommands", () => {
  it("derives opaque, distinct per-bot container and workspace identities", () => {
    const a = perBotLocalVmTarget("bot-a");
    const b = perBotLocalVmTarget("bot-b");

    expect(a).toEqual(perBotLocalVmTarget("bot-a"));
    expect(a.key).not.toBe(b.key);
    expect(a.containerName).not.toBe(b.containerName);
    expect(a.workspaceDir).not.toBe(b.workspaceDir);
    expect(a.containerName).not.toContain("bot-a");
    expect(a.workspaceDir).not.toContain("bot-a");
  });

  it("asks Docker for an ephemeral loopback viewer port for each per-bot VM", () => {
    const target = perBotLocalVmTarget("bot-a");
    const args = containerRunArgs("docker", "secret", target);
    const command = ["docker", ...args].join(" ");

    expect(command).toContain(`--name ${target.containerName}`);
    expect(command).toContain(`--label ${TARGET_LABEL}=${target.label}`);
    expect(command).toContain(`source=${target.workspaceDir},target=${VM_WORKSPACE_GUEST}`);
    expect(command).toContain("-p 127.0.0.1::6901");
    expect(command).not.toContain("127.0.0.1:6080:6901");
    expect(args).not.toContain("--userns");
    expect(args).not.toContain("--user");
    expect(command).not.toContain("relabel=");
  });

  it("does not invent Docker commands when no runtime was detected", () => {
    const commands = setupCommands(null, "darwin");
    expect(commands.pull).toBeNull();
    expect(commands.run).toBeNull();
    expect(commands.start).toBeNull();
    expect(commands.install).toContain("podman");
    expect(commands.install).not.toContain("Docker");
  });

  it("publishes only the password-protected viewer and only on loopback", () => {
    const command = setupCommands("podman", "linux").run!;
    expect(command).toContain("-p 127.0.0.1:6080:6901");
    expect(command).not.toContain(" -p 6080:6901");
    expect(command).not.toContain("5900");
    expect(command).toContain("VNC_PW=CHANGE_ME");
  });

  it("offers a start command for a stopped compatible desktop", () => {
    expect(setupCommands("docker", "linux").start).toBe(`docker start ${CONTAINER}`);
  });

  it("limits resources and retains only the sandbox supervisor's identity-switch caps", () => {
    const command = setupCommands("docker", "linux").run!;
    expect(command).toContain("--memory 4g --memory-swap 4g");
    expect(command).toContain("--cpus 2 --pids-limit 512");
    expect(command).toContain("--ipc private --cgroupns private");
    expect(command).toContain("--cap-drop ALL --cap-add SETUID --cap-add SETGID");
    expect(command).toContain(`--label ${MANAGED_LABEL}=1`);
    expect(command).toContain(`--label ${DRIVER_LABEL}=${CUA_DRIVER_VERSION}`);
    expect(command).toContain(`--label ${WORKSPACE_LABEL}=1`);
    expect(command).toContain(`--hostname ${CONTAINER}`);
    expect(command).toContain(
      `--mount type=bind,source=${VM_WORKSPACE_DIR},target=${VM_WORKSPACE_GUEST}`,
    );
  });

  it("asks rootless Podman to map and privately relabel the durable workspace", () => {
    const command = setupCommands("podman", "linux").run!;
    expect(command).toContain("--cap-add SYS_CHROOT");
    expect(command).not.toContain("--privileged");
    expect(command).not.toContain("unconfined");
    expect(setupCommands("docker", "linux").run).not.toContain("SYS_CHROOT");
    expect(command).toContain(
      `--mount type=bind,source=${VM_WORKSPACE_DIR},target=${VM_WORKSPACE_GUEST},relabel=private`,
    );
    expect(command).toContain("--userns keep-id:uid=1000,gid=1000 --user 0:0");
    expect(command).not.toContain("U=true");
  });

  it("keeps per-bot Podman workspaces separate without recursively changing their owner", () => {
    for (const id of ["podman-a", "podman-b"]) {
      const target = perBotLocalVmTarget(id);
      const args = containerRunArgs("podman", "secret", target);
      expect(args.slice(args.indexOf("--userns"), args.indexOf("--userns") + 4))
        .toEqual(["--userns", "keep-id:uid=1000,gid=1000", "--user", "0:0"]);
      expect(args[args.indexOf("--mount") + 1]).toBe(
        `type=bind,source=${target.workspaceDir},target=${VM_WORKSPACE_GUEST},relabel=private`,
      );
      expect(args).toContain("127.0.0.1::6901");
    }
  });

  it("shows the pinned base pull while creating the managed derivative through the API", () => {
    expect(setupCommands("docker", "linux").pull).toBe(`docker pull ${BASE_IMAGE}`);
    expect(setupCommands("docker", "linux").run).toContain(IMAGE);
  });

  it("uses an explicit local image name so Podman never resolves the managed build on Docker Hub", () => {
    expect(IMAGE).toMatch(/^localhost\/openmausbot\/cua-local-vm:/);
    expect(setupCommands("podman", "darwin").run).toContain(IMAGE);
    expect(setupCommands("podman", "darwin").run).not.toContain("docker.io/openmausbot");
  });

  it("generates Apple container lifecycle commands without Docker-only flags", () => {
    const commands = setupCommands("container", "darwin");
    expect(commands.runtimeStart).toBe("container system start");
    expect(commands.pull).toBe(`container image pull ${BASE_IMAGE}`);
    expect(commands.remove).toBe(`container rm --force ${CONTAINER}`);
    expect(commands.run).toContain("--memory 4g --cpus 2 --cap-drop ALL");
    expect(commands.run).not.toContain("--memory-swap");
  });

  it("offers the supported Podman Desktop installer on Windows", () => {
    expect(setupCommands(null, "win32").install).toBe("winget install -e --id RedHat.Podman-Desktop");
  });
});

describe("Auto's Local VM eligibility", () => {
  const base = { runtime: "podman", daemonUp: true, image: true, container: "missing", create_supported: true, ready: false } as unknown as Parameters<typeof autoLocalVmAttachable>[0];
  it("attaches a ready desktop or one whose prepared image can be recreated, and nothing else", () => {
    expect(autoLocalVmAttachable({ ...base, ready: true, container: "running" })).toBe(true);
    expect(autoLocalVmAttachable(base)).toBe(true);
    // Never a first-time setup, an unverified stopped image, or a dead daemon
    expect(autoLocalVmAttachable({ ...base, image: false })).toBe(false);
    expect(autoLocalVmAttachable({ ...base, daemonUp: false })).toBe(false);
    expect(autoLocalVmAttachable({ ...base, container: "stopped" })).toBe(false);
    expect(autoLocalVmAttachable({ ...base, runtime: null })).toBe(false);
    expect(autoLocalVmAttachable({ ...base, create_supported: false })).toBe(false);
  });
});
