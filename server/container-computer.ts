// The Local VM contract: identities, the pinned image recipe, argv builders,
// the isolation rules and the readiness predicates over a status.
//
// The lifecycle itself — inspecting the runtime and container, probing Cua
// Driver, building the image, run/start/stop/remove, preview frames and
// `exec` — runs in the Jac harness (jac/harness/container_computer.jac) and is
// reached through server/jac-computers.ts. What stays here is pure: the
// deferred BYO-VPS backend (vps-computer.ts), the spawned MCP bridge
// (container-mcp.ts), verification scripts and synchronous node call sites
// all build on it. container_computer.jac carries the same recipe and argv;
// its test annex pins both against this file (Dockerfile sha256, run/exec
// argv), so the two cannot drift silently.
//
// OpenMausBot owns only the sandbox boundary: image preparation, container
// lifecycle, resource limits, loopback viewer, and target-scoped lease in the
// harness. Desktop automation itself is Cua Driver. Agents connect directly to
// `cua-driver mcp` inside the container; nothing here reimplements clicks,
// typing, screenshots, accessibility, or window discovery.
import { createHash } from "node:crypto";
import { lstatSync } from "node:fs";
import { join } from "node:path";

import { DATA_DIR } from "./config.ts";
import { SPAWNED_PROXIES } from "./proxy-paths.ts";

export const CUA_DRIVER_VERSION = "0.20.0";
export const BASE_IMAGE_REPOSITORY = "docker.io/trycua/xfce-cua";
// Official multi-architecture Cua XFCE 0.1.0 manifest (amd64 + arm64).
export const BASE_IMAGE_DIGEST = "sha256:274eb636f5cf3fc58f705916ee72b7a701270b3877369d08533a385c5325be9b";
export const BASE_IMAGE = `${BASE_IMAGE_REPOSITORY}@${BASE_IMAGE_DIGEST}`;
// This tag is built locally from the pinned Cua base. The explicit localhost
// registry is required by Podman: it prepends localhost to unqualified build
// tags, then may otherwise resolve the same name to Docker Hub when running it.
// Image and container labels below remain the authoritative compatibility
// check, not the mutable tag.
export const IMAGE_REPOSITORY = "localhost/openmausbot/cua-local-vm";
export const IMAGE_LAYER_VERSION = "5";
export const IMAGE_LAYER_LABEL = "com.openmausbot.image-layer";
export const IMAGE = `${IMAGE_REPOSITORY}:driver-${CUA_DRIVER_VERSION}-v${IMAGE_LAYER_VERSION}`;
export const CONTAINER = "openmausbot-computer";
export const MANAGED_LABEL = "com.openmausbot.local-vm";
export const DRIVER_LABEL = "com.openmausbot.cua-driver";
export const BASE_IMAGE_LABEL = "com.openmausbot.cua-base";
export const WORKSPACE_LABEL = "com.openmausbot.workspace";
export const TARGET_LABEL = "com.openmausbot.local-vm-target";
export const VM_WORKSPACE_DIR = join(DATA_DIR, "vm-home");
export const VM_WORKSPACE_GUEST = "/home/cua/workspace";
export const DISPLAY = ":1";
export const CUA_SOCKET = "/run/user/1000/openmausbot-cua.sock";
export const CUA_EXECUTABLE = "/usr/local/libexec/openmausbot/cua-driver";

export type Runtime = "docker" | "podman" | "container";
export type LifecycleAction = "pull" | "run" | "start" | "stop" | "remove";

const INTERNAL_VIEWER_PORT = 6901;
const HOST_VIEWER_PORT = 6080;
const PIDS_LIMIT = 512;

export interface LocalVmTarget {
  /** Stable, non-secret identity used for leases and caches. */
  key: string;
  containerName: string;
  workspaceDir: string;
  /** The historical shared target keeps 6080 for compatibility. Per-bot
   * targets let the runtime allocate a distinct ephemeral loopback port. */
  viewerPort: number | null;
  label: string;
}

export const SHARED_LOCAL_VM_TARGET: LocalVmTarget = {
  key: "shared",
  containerName: CONTAINER,
  workspaceDir: VM_WORKSPACE_DIR,
  viewerPort: HOST_VIEWER_PORT,
  label: "shared",
};

/** Derive filesystem/container identities from a digest, never from a bot's
 * display name or caller-controlled path fragment. */
export function perBotLocalVmTarget(botId: string): LocalVmTarget {
  const digest = createHash("sha256").update(botId).digest("hex");
  const short = digest.slice(0, 16);
  return {
    key: `bot:${digest}`,
    containerName: `${CONTAINER}-${short}`,
    workspaceDir: join(DATA_DIR, "vm-homes", short),
    viewerPort: null,
    label: digest,
  };
}

/** A pool-mode seat (issue #1654): one of N desktops shared by every
 * conversation, addressed by seat index. Identities stay disjoint from the
 * shared singleton and from per-bot digests, so discovery, labels, and lease
 * lanes never confuse the three modes. */
export function poolLocalVmTarget(seat: number): LocalVmTarget {
  return {
    key: `pool:${seat}`,
    containerName: `${CONTAINER}-p${seat}`,
    workspaceDir: join(DATA_DIR, "vm-homes", `pool-${seat}`),
    viewerPort: null,
    label: `pool-${seat}`,
  };
}

/** Only provisioning creates this durable directory; idle shutdown keeps it. */
export function localVmWorkspaceExists(target: LocalVmTarget): boolean {
  try {
    return lstatSync(target.workspaceDir, { throwIfNoEntry: false })?.isDirectory() === true;
  } catch {
    return false;
  }
}

const LINUX_WHEELS = {
  x86_64: {
    url: "https://files.pythonhosted.org/packages/fa/d7/a43008a328a40c85e7bc706fc20235b9abedc75e28b413817655153157ff/cua_driver-0.20.0-py3-none-manylinux_2_31_x86_64.whl",
    sha256: "f60c35696a37f37ac954935e478ae4754f220856d022036625c9400d72185961",
  },
  aarch64: {
    url: "https://files.pythonhosted.org/packages/94/9d/1c1838b69067e83266c3d2aae02d74eef353a43dc8644884ccf03fe7f933/cua_driver-0.20.0-py3-none-manylinux_2_31_aarch64.whl",
    sha256: "48833bc5e4c60e701fc9eefb57dbac36ec77ef3990f816fbbe85b4e954af2c77",
  },
} as const;

/** Reproducible, multi-architecture derivative of Cua's sandbox desktop.
 * Both Linux wheels are exact-version and SHA-256 verified. Supervisor owns
 * the daemon so it starts, restarts, and stops with the desktop container.
 *
 * The first RUN also rejects a defective base image before anything uses it:
 * some published ARM64 layers of upstream bases have shipped zero-byte
 * OpenSSL libraries, which surfaces later as a baffling "curl: error while
 * loading shared libraries … file too short" that reads as a network fault.
 * The gate names the actual problem at the step that can act on it. */
export function managedImageDockerfile(): string {
  return `FROM ${BASE_IMAGE}
USER root
RUN set -eux; \\
    arch="$(uname -m)"; \\
    case "$arch" in \\
      x86_64) wheel_url='${LINUX_WHEELS.x86_64.url}'; wheel_sha='${LINUX_WHEELS.x86_64.sha256}'; wheel_path='/tmp/cua_driver-${CUA_DRIVER_VERSION}-py3-none-manylinux_2_31_x86_64.whl'; lib_triplet='x86_64-linux-gnu' ;; \\
      aarch64|arm64) wheel_url='${LINUX_WHEELS.aarch64.url}'; wheel_sha='${LINUX_WHEELS.aarch64.sha256}'; wheel_path='/tmp/cua_driver-${CUA_DRIVER_VERSION}-py3-none-manylinux_2_31_aarch64.whl'; lib_triplet='aarch64-linux-gnu' ;; \\
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \\
    esac; \\
    for ssl_lib in "/lib/$lib_triplet/libssl.so.3" "/lib/$lib_triplet/libcrypto.so.3"; do \\
      if [ -e "$ssl_lib" ] && [ ! -s "$ssl_lib" ]; then \\
        echo "pinned base image is defective on $arch: $ssl_lib is zero bytes, so curl cannot start — re-pull or replace the base image instead of debugging the wheel download" >&2; \\
        exit 1; \\
      fi; \\
    done; \\
    curl -fsSL "$wheel_url" -o "$wheel_path"; \\
    echo "$wheel_sha  $wheel_path" | sha256sum -c -; \\
    /opt/venv/bin/python -m pip install --no-cache-dir --force-reinstall --no-deps "$wheel_path"; \\
    rm -f "$wheel_path"; \\
    driver_bin="$(find /opt/venv/lib -path '*/cua_driver/bin/cua-driver' -type f -print -quit)"; \\
    test -n "$driver_bin"; \\
    install -D -m 0755 "$driver_bin" ${CUA_EXECUTABLE}; \\
    install -d -o cua -g cua -m 0700 ${VM_WORKSPACE_GUEST}; \\
    test "$(${CUA_EXECUTABLE} --version)" = "cua-driver ${CUA_DRIVER_VERSION}"
# Install before XFCE starts so the panel and window manager see the font too.
# Noto Sans CJK JP is distributed under the SIL Open Font License 1.1.
RUN set -eux; \\
    install -d -m 0755 /usr/local/share/fonts; \\
    curl -fsSL 'https://raw.githubusercontent.com/notofonts/noto-cjk/165c01b46ea533872e002e0785ff17e44f6d97d8/Sans/OTF/Japanese/NotoSansCJKjp-Regular.otf' -o /usr/local/share/fonts/NotoSansCJKjp-Regular.otf; \\
    echo '68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5  /usr/local/share/fonts/NotoSansCJKjp-Regular.otf' | sha256sum -c -; \\
    chmod 0644 /usr/local/share/fonts/NotoSansCJKjp-Regular.otf; \\
    install -d -m 0755 /usr/local/share/licenses/noto-cjk; \\
    curl -fsSL 'https://raw.githubusercontent.com/notofonts/noto-cjk/165c01b46ea533872e002e0785ff17e44f6d97d8/LICENSE' -o /usr/local/share/licenses/noto-cjk/OFL.txt; \\
    echo '6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2  /usr/local/share/licenses/noto-cjk/OFL.txt' | sha256sum -c -; \\
    fc-cache -f
RUN printf '%s\\n' \\
      '#!/bin/sh' \\
      'set -eu' \\
      'workspace=${VM_WORKSPACE_GUEST}' \\
      'profiles="$workspace/.browser-profiles"' \\
      'mkdir -p "$profiles/google-chrome" "$profiles/chromium" "$HOME/.config"' \\
      'if ! chmod 0700 "$workspace" "$profiles" "$profiles/google-chrome" "$profiles/chromium" 2>/dev/null; then' \\
      '  for directory in "$workspace" "$profiles" "$profiles/google-chrome" "$profiles/chromium"; do' \\
      '    test -r "$directory" && test -w "$directory" && test -x "$directory"' \\
      '  done' \\
      'fi' \\
      'migrate_profile() {' \\
      '  name="$1"' \\
      '  source="$HOME/.config/$name"' \\
      '  target="$profiles/$name"' \\
      '  if [ -d "$source" ] && [ ! -L "$source" ] && [ -z "$(find "$target" -mindepth 1 -print -quit)" ]; then' \\
      '    cp -a "$source"/. "$target"/' \\
      '  fi' \\
      '  rm -rf "$source"' \\
      '  ln -s "$target" "$source"' \\
      '}' \\
      'migrate_profile google-chrome' \\
      'migrate_profile chromium' \\
      'find "$profiles" \\( -name SingletonLock -o -name SingletonSocket -o -name SingletonCookie -o -name .parentlock \\) -delete' \\
      > /usr/local/bin/prepare-openmausbot-workspace.sh \\
    && chmod 0755 /usr/local/bin/prepare-openmausbot-workspace.sh
RUN printf '%s\\n' \\
      '#!/bin/sh' \\
      '/usr/local/bin/prepare-openmausbot-workspace.sh' \\
      'attempt=0' \\
      'until DISPLAY=:1 xset q >/dev/null 2>&1; do' \\
      '  attempt=$((attempt + 1))' \\
      '  if [ "$attempt" -ge 45 ]; then echo "X display :1 did not become ready within 45 seconds" >&2; exit 1; fi' \\
      '  sleep 1' \\
      'done' \\
      'exec env CUA_DRIVER_INSTALL_CHANNEL=python_package CUA_DRIVER_RS_TELEMETRY_ENABLED=0 ${CUA_EXECUTABLE} serve --socket ${CUA_SOCKET} --permission-mode standard' \\
      > /usr/local/bin/start-openmausbot-cua-driver.sh \\
    && chmod 0755 /usr/local/bin/start-openmausbot-cua-driver.sh
RUN printf '%s\\n' \\
      '' \\
      '[program:openmausbot-cua-driver]' \\
      'command=/usr/local/bin/start-openmausbot-cua-driver.sh' \\
      'user=cua' \\
      'environment=HOME="/home/cua",USER="cua",DISPLAY=":1"' \\
      'autorestart=true' \\
      'startsecs=2' \\
      'stdout_logfile=/var/log/supervisor/cua-driver.log' \\
      'stderr_logfile=/var/log/supervisor/cua-driver.error.log' \\
      'priority=30' \\
      >> /etc/supervisor/supervisord.conf
LABEL ${MANAGED_LABEL}="1" \\
      ${DRIVER_LABEL}="${CUA_DRIVER_VERSION}" \\
      ${BASE_IMAGE_LABEL}="${BASE_IMAGE_DIGEST}" \\
      ${IMAGE_LAYER_LABEL}="${IMAGE_LAYER_VERSION}"
`;
}

export interface ContainerRuntimeStatus {
  runtime: Runtime | null;
  available: Runtime[];
  daemonUp: boolean;
}

export interface ContainerComputerStatus {
  platform: NodeJS.Platform;
  runtime: Runtime | null;
  available: Runtime[];
  daemonUp: boolean;
  image: boolean;
  imageMatches: boolean;
  managed: boolean;
  container: "running" | "stopped" | "missing";
  network: "loopback" | "unsafe" | "unknown";
  security: "hardened" | "unsafe" | "unknown";
  persistence: "durable" | "unsafe" | "unknown";
  desktopReady: boolean;
  desktop_error: string | null;
  /** Runtime timestamp used to match an idle-stop record, never an inferred cause. */
  stopped_at?: string | null;
  /** A stopped desktop whose only problem is that it is stopped. */
  resumable: boolean;
  create_supported: boolean;
  ready: boolean;
  problem: string | null;
  image_ref: string;
  image_id: string | null;
  base_image_ref: string;
  driver_version: string;
  container_name: string;
  target_key: string;
  workspace_path: string;
  workspace_guest_path: string;
  viewer_port: number | null;
  viewer_url: string;
}

/** Recreate a missing desktop when its image and runtime are already prepared.
 * This also recovers desktops deleted by older versions' idle cleanup. */
export function localVmRecreatableOnDemand(
  status: ContainerComputerStatus,
): status is ContainerComputerStatus & { runtime: Runtime } {
  return Boolean(status.runtime)
    && status.daemonUp
    && status.image
    && status.container === "missing"
    && status.create_supported;
}

/** Start only an existing, compatible desktop with the managed safety boundary.
 * Fails closed on fields left "unknown" by a partial inspect, which
 * `statusProblem` alone would let through. */
export function localVmResumable(
  status: ContainerComputerStatus,
): status is ContainerComputerStatus & { runtime: Runtime } {
  return Boolean(status.runtime) && status.daemonUp && status.image && status.container === "stopped"
    && existingContainerProblem(status) === null
    && status.network === "loopback" && status.security === "hardened" && status.persistence === "durable";
}

/** What a turn may do on its own to bring this Local VM up, if anything. */
export function localVmWakeAction(status: ContainerComputerStatus): "run" | "start" | null {
  if (localVmRecreatableOnDemand(status)) return "run";
  if (localVmResumable(status)) return "start";
  return null;
}

/** Whether Auto may attach this Local VM without a person choosing it: the
 * desktop is ready, a compatible stopped desktop can be started, or its image
 * is prepared and a missing container can be recreated. Anything else — no runtime, daemon down, image
 * never prepared, an unmanaged or unsafe container — stays the person's call. */
export function autoLocalVmAttachable(status: ContainerComputerStatus): boolean {
  return status.ready === true || localVmWakeAction(status) !== null;
}

/** Problems with an existing container that only a recreate fixes. */
function existingContainerProblem(status: ContainerComputerStatus): string | null {
  if (!status.imageMatches) return "The existing Local VM uses an older desktop or Cua Driver; recreate it";
  if (!status.managed) return "The existing container was not created by OpenMausBot; recreate it";
  if (status.network === "unsafe") return "The existing Local VM exposes its viewer publicly; recreate it";
  if (status.security === "unsafe") return "The existing Local VM is missing safety limits; recreate it";
  if (status.persistence === "unsafe") return "The existing Local VM is missing its durable folder; recreate it";
  return null;
}

/** Shared with the BYO-VPS backend (vps-computer.ts): both containers are
 * built from the same pinned derivative, so image compatibility is one rule. */
export function imageLabelsMatch(labels: Record<string, string> | undefined): boolean {
  return (
    labels?.[MANAGED_LABEL] === "1" &&
    labels?.[DRIVER_LABEL] === CUA_DRIVER_VERSION &&
    labels?.[BASE_IMAGE_LABEL] === BASE_IMAGE_DIGEST &&
    labels?.[IMAGE_LAYER_LABEL] === IMAGE_LAYER_VERSION
  );
}

/** The one authoritative `exec … cua-driver` argv. Shared with the BYO-VPS
 * backend and both MCP bridge entry points so the identity, env, and
 * telemetry knobs can never drift between the Local VM and a VPS container. */
export function cuaExecArgs(
  args: string[],
  options: { container?: string; interactive?: boolean } = {},
): string[] {
  return [
    "exec",
    ...(options.interactive ? ["-i"] : []),
    "-u",
    "cua",
    "-e",
    "HOME=/home/cua",
    "-e",
    `DISPLAY=${DISPLAY}`,
    "-e",
    "CUA_DRIVER_INSTALL_CHANNEL=python_package",
    "-e",
    "CUA_DRIVER_RS_TELEMETRY_ENABLED=0",
    options.container ?? CONTAINER,
    CUA_EXECUTABLE,
    ...args,
  ];
}

/** The Docker/Podman HostConfig surface the hardening check reads. */
export interface DockerHardeningConfig {
  Memory?: number;
  MemorySwap?: number;
  NanoCpus?: number;
  PidsLimit?: number | null;
  CapDrop?: string[] | null;
  CapAdd?: string[] | null;
  Privileged?: boolean;
  PidMode?: string;
  IpcMode?: string;
  UTSMode?: string;
  ShmSize?: number;
  Devices?: unknown[] | null;
  DeviceRequests?: unknown[] | null;
  SecurityOpt?: string[] | null;
  UsernsMode?: string;
  CgroupnsMode?: string;
  OomKillDisable?: boolean | null;
  AutoRemove?: boolean;
  RestartPolicy?: { Name?: string; MaximumRetryCount?: number };
}

/** Shared isolation contract for Local VM and BYO-VPS containers. Resource
 * budgets are creation defaults, not an isolation requirement. Podman alone
 * needs chroot for Firefox's sandbox. Local VM starts stay controlled by
 * OMB's idle policy; VPS restart policy belongs to the server operator. */
export function dockerSecurityIsHardened(
  config: DockerHardeningConfig | undefined,
  options: { restartPolicy?: "no" | "unless-stopped" | "any"; podmanBrowserSandbox?: boolean } = {},
): boolean {
  if (!config) return false;
  const capDrop = (config.CapDrop ?? []).map((cap) => cap.toLowerCase());
  const capAdd = (config.CapAdd ?? [])
    .map((cap) => cap.toLowerCase().replace(/^cap_/, ""))
    .sort();
  const unsafeSecurityOption = (config.SecurityOpt ?? []).some((option) => /(?:^|=)(?:unconfined|disable)$/i.test(option));
  const restartPolicy = config.RestartPolicy?.Name;
  const restartPolicyOk =
    options.restartPolicy === "any" || (options.restartPolicy === "unless-stopped"
      ? restartPolicy === "unless-stopped"
      : restartPolicy === undefined || restartPolicy === "" || restartPolicy === "no");
  return (
    capDrop.includes("all") &&
    capAdd.join(",") === (options.podmanBrowserSandbox ? "setgid,setuid,sys_chroot" : "setgid,setuid") &&
    config.Privileged === false &&
    !config.PidMode &&
    config.IpcMode === "private" &&
    !config.UTSMode &&
    (!config.Devices || config.Devices.length === 0) &&
    (!config.DeviceRequests || config.DeviceRequests.length === 0) &&
    !unsafeSecurityOption &&
    !config.UsernsMode &&
    config.CgroupnsMode === "private" &&
    config.AutoRemove !== true &&
    restartPolicyOk
  );
}

export function containerRunArgs(
  runtime: Runtime,
  password = "CHANGE_ME",
  target: LocalVmTarget = SHARED_LOCAL_VM_TARGET,
): string[] {
  if (runtime === "container" && target.key !== SHARED_LOCAL_VM_TARGET.key) {
    throw new Error("Per-bot Local VMs require Docker or Podman because Apple container requires a fixed host port");
  }
  const common = ["run", "-d", "--name", target.containerName];
  if (runtime === "podman") {
    // The supervisor starts as namespace-root then drops to cua (1000).
    // Preserve the host workspace owner instead of :U chowning it to root.
    common.push("--userns", "keep-id:uid=1000,gid=1000", "--user", "0:0");
  }
  common.push(
    "--label",
    `${MANAGED_LABEL}=1`,
    "--label",
    `${DRIVER_LABEL}=${CUA_DRIVER_VERSION}`,
    "--label",
    `${BASE_IMAGE_LABEL}=${BASE_IMAGE_DIGEST}`,
    "--label",
    `${IMAGE_LAYER_LABEL}=${IMAGE_LAYER_VERSION}`,
    "--label",
    `${WORKSPACE_LABEL}=1`,
    "--label",
    `${TARGET_LABEL}=${target.label}`,
  );
  if (runtime === "container") {
    // Apple container already places each Linux container in a lightweight VM.
    common.push(
      "--memory",
      "4g",
      "--cpus",
      "2",
      "--cap-drop",
      "ALL",
      "--cap-add",
      "SETUID",
      "--cap-add",
      "SETGID",
      "--shm-size",
      "512m",
    );
  } else {
    common.push(
      "--hostname",
      target.containerName,
      "--memory",
      "4g",
      "--memory-swap",
      "4g",
      "--cpus",
      "2",
      "--pids-limit",
      String(PIDS_LIMIT),
      // Pinned explicitly rather than trusting daemon defaults: the shared
      // hardening check requires private IPC and cgroup namespaces, and a
      // daemon configured with host-mode defaults would otherwise create a
      // container its own acceptance check then rejects.
      "--ipc",
      "private",
      "--cgroupns",
      "private",
      "--cap-drop",
      "ALL",
      "--cap-add",
      "SETUID",
      "--cap-add",
      "SETGID",
      "--shm-size",
      "512m",
    );
  }
  // Podman's default seccomp profile gates chroot on this capability.
  // Firefox uses chroot inside its own namespace to establish its sandbox.
  if (runtime === "podman") common.push("--cap-add", "SYS_CHROOT");
  common.push(
    "--mount",
    runtime === "podman"
      ? `type=bind,source=${target.workspaceDir},target=${VM_WORKSPACE_GUEST},relabel=private`
      : `type=bind,source=${target.workspaceDir},target=${VM_WORKSPACE_GUEST}`,
    "-e",
    `VNC_PW=${password}`,
    "-p",
    target.viewerPort
      ? `127.0.0.1:${target.viewerPort}:${INTERNAL_VIEWER_PORT}`
      : `127.0.0.1::${INTERNAL_VIEWER_PORT}`,
    IMAGE,
  );
  return common;
}

function baseImagePullArgs(runtime: Runtime): string[] {
  return runtime === "container" ? ["image", "pull", BASE_IMAGE] : ["pull", BASE_IMAGE];
}

export type ScreenshotCheck = { ok: boolean; mime: "image/png" | "image/jpeg" };


/** Shared with the BYO-VPS backend: a truncated base64 transfer must never
 * become a "successful" preview frame on either transport. */
export function wholeScreenshot(bytes: Buffer): ScreenshotCheck {
  if (bytes.length < 512) return { ok: false, mime: "image/png" };
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (png) {
    return {
      ok: bytes.subarray(Math.max(0, bytes.length - 12)).includes(Buffer.from("IEND", "ascii")),
      mime: "image/png",
    };
  }
  const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8;
  return {
    ok: jpeg && bytes.subarray(Math.max(0, bytes.length - 32)).includes(Buffer.from([0xff, 0xd9])),
    mime: "image/jpeg",
  };
}

export interface ContainerExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

/** Spawn contract handed directly to agent runtimes. The tiny host wrapper
 * only preserves stdio through the container CLI; Cua Driver owns the MCP
 * protocol and every computer tool. */
type ContainerMcpLaunch = {
  command: string;
  args: string[];
  env: Record<string, string>;
};

export function containerComputerMcp(
  runtime: Runtime,
  control?: { url: string; token: string },
  target: LocalVmTarget = SHARED_LOCAL_VM_TARGET,
): ContainerMcpLaunch {
  return {
    command: process.execPath,
    args: [SPAWNED_PROXIES.containerMcp, runtime, target.containerName, CUA_SOCKET],
    // The control pair rides in env, not argv — argv is world-readable
    // through `ps` for the life of the bridge.
    env: {
      ELECTRON_RUN_AS_NODE: "1",
      ...(control ? { OMB_CONTROL_URL: control.url, OMB_CONTROL_TOKEN: control.token } : {}),
    },
  };
}

/** Commands shown as a transparent fallback. Normal setup builds the pinned
 * derivative through the API, so users do not need to author a Dockerfile. */
export function setupCommands(
  runtime: Runtime | null,
  platform: NodeJS.Platform = process.platform,
  target: LocalVmTarget = SHARED_LOCAL_VM_TARGET,
) {
  const install =
    platform === "darwin"
      ? "brew install podman; podman machine init; podman machine start"
      : platform === "win32"
        ? "winget install -e --id RedHat.Podman-Desktop"
        : null;
  const runtimeStart =
    runtime === "container"
      ? "container system start"
      : runtime === "podman" && platform !== "linux"
        ? "podman machine init; podman machine start"
        : runtime === "docker" && platform === "darwin"
          ? "colima start || open -a Docker"
          : runtime === "docker" && platform === "linux"
            ? "sudo systemctl start docker"
            : null;

  if (!runtime) {
    return {
      install,
      runtimeStart: null,
      pull: null,
      run: null,
      start: null,
      stop: null,
      remove: null,
      view: target.viewerPort ? `http://127.0.0.1:${target.viewerPort}/vnc.html` : "",
    };
  }
  const command = (args: string[]) => [runtime, ...args].join(" ");
  return {
    install,
    runtimeStart,
    // This is the inspectable base download. The normal Prepare button also
    // builds the checksum-pinned 0.20.0 derivative automatically.
    pull: command(baseImagePullArgs(runtime)),
    run:
      runtime === "container" && target.key !== SHARED_LOCAL_VM_TARGET.key
        ? null
        : command(containerRunArgs(runtime, "CHANGE_ME", target)),
    start: command(["start", target.containerName]),
    stop: command(["stop", target.containerName]),
    remove: command(["rm", runtime === "container" ? "--force" : "-f", target.containerName]),
    view: target.viewerPort ? `http://127.0.0.1:${target.viewerPort}/vnc.html` : "",
  };
}
