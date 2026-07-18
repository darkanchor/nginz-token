import { spawn, spawnSync } from "bun";
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync, openSync, closeSync, unlinkSync } from "fs";
import { join, dirname, isAbsolute, basename } from "path";

let nginzProcess = null;
const NGINZ_BIN = "./zig-out/bin/nginz-token";
export const DEFAULT_PERF_OPTIMIZE = "ReleaseSmall";
const BUILD_LOCK_PATH = join(process.cwd(), ".zig-build.lock");
const LEGACY_PORTS = [
  // nginx listen / internal mock upstreams
  8888, 8889, 8891, 8892, 8895,
  // Bun mock servers
  9001, 9002, 9003, 9004, 9005, 9006, 9007, 9008, 9009,
  19000, 19001, 19002, 19003, 19004, 19005, 19006, 19007, 19008, 19009,
  19010, 19011, 19012, 19013, 19014, 19015, 19016, 19017, 19018, 19019,
  19020, 19021, 19100, 19101,
];
// Must be >= LEGACY_PORTS.length so every legacy port maps uniquely.
const PORT_BLOCK_SIZE = 48;
const PORT_BLOCK_BASE = 10000;
// Deterministic module slots — must cover every tests/<module>/ directory.
// The previous design used only 4 slots, so 7 suites collided inside one
// `bun test` process whenever files ran with overlapping lifetimes.
const MODULE_PORT_SLOTS = [
  "llm-auth",
  "llm-cost",
  "llm-fallback",
  "llm-metrics",
  "llm-proxy",
  "llm-ratelimit",
  "llm-security",
];
const MAX_MODULE_SLOTS = 16;
const MAX_PID_SLOTS = 40; // 40 * 16 * 48 + 10000 < 65535

let currentPortPlan = null;
let currentModuleName = null;
let activeGeneratedConfigPath = null;
export let TEST_PORT_NUM = 8888;
export let TEST_URL = "http://localhost:8888";

function hashString(input) {
  let hash = 0;
  for (let i = 0; i < input.length; i += 1) {
    hash = ((hash * 33) + input.charCodeAt(i)) >>> 0;
  }
  return hash >>> 0;
}

function modulePortSlot(moduleName) {
  const known = MODULE_PORT_SLOTS.indexOf(moduleName);
  if (known >= 0) return known;
  return hashString(moduleName) % MAX_MODULE_SLOTS;
}

function buildPortPlan(moduleName) {
  const moduleSlot = modulePortSlot(moduleName);
  const pidSlot = process.pid % MAX_PID_SLOTS;
  const blockIndex = pidSlot * MAX_MODULE_SLOTS + moduleSlot;
  const start = PORT_BLOCK_BASE + (blockIndex * PORT_BLOCK_SIZE);
  const byLegacy = new Map();

  LEGACY_PORTS.forEach((legacy, index) => {
    byLegacy.set(String(legacy), start + index);
  });

  return { moduleName, byLegacy };
}

function applyPortPlan(plan) {
  currentPortPlan = plan;
  currentModuleName = plan.moduleName;
  TEST_PORT_NUM = plan.byLegacy.get("8888");
  TEST_URL = `http://localhost:${TEST_PORT_NUM}`;
}

export function configureTestPorts(moduleName) {
  if (!currentPortPlan || currentModuleName !== moduleName) {
    applyPortPlan(buildPortPlan(moduleName));
  }
  return currentPortPlan;
}

export function getPort(legacyPort) {
  if (!currentPortPlan) {
    throw new Error("test ports are not configured; call configureTestPorts(moduleName) first");
  }
  const mapped = currentPortPlan.byLegacy.get(String(legacyPort));
  if (!mapped) {
    throw new Error(`no mapped test port for legacy port ${legacyPort}`);
  }
  return mapped;
}

function rewriteConfigPorts(configText) {
  if (!currentPortPlan) return configText;

  const legacyPortsDesc = [...LEGACY_PORTS].sort((a, b) => String(b).length - String(a).length);
  let rewritten = configText;
  for (const legacyPort of legacyPortsDesc) {
    const mapped = getPort(legacyPort);
    const pattern = new RegExp(`(?<!\\d)${legacyPort}(?!\\d)`, "g");
    rewritten = rewritten.replace(pattern, String(mapped));
  }
  return rewritten;
}

export function materializeTestConfig(configPath, moduleName, outputDir) {
  configureTestPorts(moduleName);
  const absConfig = isAbsolute(configPath)
    ? configPath
    : join(process.cwd(), configPath);
  const rendered = rewriteConfigPorts(readFileSync(absConfig, "utf8"));
  const generatedPath = join(
    dirname(absConfig),
    `.${moduleName}.${process.pid}.${basename(absConfig)}`,
  );
  writeFileSync(generatedPath, rendered, "utf8");
  return generatedPath;
}

// Build nginz before running tests
// For performance-oriented runs, prefer ZIG_OPTIMIZE=ReleaseSmall.
// ReleaseSmall is the project-recommended release-grade mode: it keeps safety
// checks on and avoids the ReleaseSafe LLVM/memory issues documented in the repo.
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function acquireBuildLock(timeoutMs = 120000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const fd = openSync(BUILD_LOCK_PATH, "wx");
      return fd;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      sleepSync(100);
    }
  }
  throw new Error("timed out waiting for zig build lock");
}

export function ensureBuild() {
  const lockFd = acquireBuildLock();
  const optimize = process.env.ZIG_OPTIMIZE;
  const args = ["zig", "build"];

  try {
    if (optimize) {
      args.push(`-Doptimize=${optimize}`);
      console.log(`Building nginz with -Doptimize=${optimize}...`);
    } else {
      console.log("Building nginz...");
    }

    const result = spawnSync(args, {
      stdout: "inherit",
      stderr: "inherit",
    });
    if (result.exitCode !== 0) {
      throw new Error("zig build failed");
    }
    console.log("Build successful");
  } finally {
    closeSync(lockFd);
    try {
      unlinkSync(BUILD_LOCK_PATH);
    } catch {}
  }
}

// Create isolated runtime directory for a module
function createRuntimeDir(moduleName) {
  const runtimeDir = join(process.cwd(), "tests", moduleName, "runtime");
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
  mkdirSync(runtimeDir, { recursive: true });
  mkdirSync(join(runtimeDir, "logs"), { recursive: true });
  return runtimeDir;
}

// Ports nginx itself binds in test configs (not Bun mock servers). Freeing
// mock ports (190xx) here would fuser-kill the test process that already
// started createHTTPMock() in beforeAll.
const NGINX_LISTEN_LEGACY_PORTS = ["8888", "8889", "8891", "8892", "8895"];

// Start nginz with given config
export async function startNginz(configPath, moduleName) {
  configureTestPorts(moduleName);
  for (const legacy of NGINX_LISTEN_LEGACY_PORTS) {
    const port = currentPortPlan?.byLegacy.get(legacy);
    if (port) await ensurePortFree(port);
  }
  const runtimeDir = createRuntimeDir(moduleName);
  const absConfig = materializeTestConfig(configPath, moduleName, runtimeDir);
  activeGeneratedConfigPath = absConfig;

  nginzProcess = spawn([NGINZ_BIN, "-c", absConfig, "-p", runtimeDir], {
    stdout: "inherit",
    stderr: "inherit",
    cwd: process.cwd(),
    env: process.env,
  });

  await waitForPort(TEST_PORT_NUM);
  return runtimeDir;
}

// Stop nginz (fast shutdown so open connections from timed-out tests don't block)
export async function stopNginz() {
  const port = TEST_PORT_NUM;
  if (nginzProcess) {
    const proc = nginzProcess;
    nginzProcess = null;
    try {
      proc.kill("SIGTERM");
    } catch {}
    const killTimer = setTimeout(() => {
      try { proc.kill("SIGKILL"); } catch {}
    }, 2000);
    try {
      await proc.exited;
    } catch {}
    clearTimeout(killTimer);
  }
  if (activeGeneratedConfigPath) {
    try {
      rmSync(activeGeneratedConfigPath, { force: true });
    } catch {}
    activeGeneratedConfigPath = null;
  }
  try {
    await waitForPortFree(port, 5000);
  } catch {}
}

// Gracefully reload the active nginx master while preserving shared zones.
export async function reloadNginz() {
  if (!nginzProcess) throw new Error("nginz is not running");
  nginzProcess.kill("SIGHUP");
  // The listening socket remains available throughout reload. Give the new
  // generation time to start while old workers drain in-flight requests.
  await Bun.sleep(200);
  await waitForPort(TEST_PORT_NUM);
}

// Wait until nothing is listening on the port (previous nginx fully gone)
export async function waitForPortFree(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      await Bun.connect({
        hostname: "127.0.0.1",
        port,
        socket: { data() {}, open(s) { s.end(); }, close() {}, error() {} },
      });
      // Still accepting connections — wait and retry.
      await Bun.sleep(50);
    } catch {
      return;
    }
  }
  throw new Error(`Timeout waiting for port ${port} to become free`);
}

function killListenersOnPort(port) {
  // Only kill LISTEN-side processes (ss -ltnp). Do NOT use `fuser -k`:
  // fuser also targets clients connected to the port, which would SIGKILL
  // the bun test process itself while it still has sockets open to nginx.
  try {
    const ss = spawnSync(["ss", "-ltnp", `sport = :${port}`], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const raw = ss.stdout;
    const text = raw == null
      ? ""
      : typeof raw === "string"
        ? raw
        : Buffer.from(raw).toString();
    for (const match of text.matchAll(/pid=(\d+)/g)) {
      const pid = Number(match[1]);
      if (pid > 0 && pid !== process.pid) {
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
    }
  } catch {}
}

// Free a TCP port for reuse. Soft-wait first; if something is still bound,
// kill listeners on that port (test-only harness) and wait again.
export async function ensurePortFree(port, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      await waitForPortFree(port, 150);
      return;
    } catch {}
    killListenersOnPort(port);
    await Bun.sleep(50);
  }
  throw new Error(`Timeout waiting for port ${port} to become free`);
}

// Wait for port to be available
async function waitForPort(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 100);
      await fetch(`http://localhost:${port}/`, {
        signal: controller.signal,
        headers: { Connection: "close" },
      });
      clearTimeout(timeoutId);
      return;
    } catch {
      await Bun.sleep(50);
    }
  }
  throw new Error(`Timeout waiting for port ${port}`);
}

// Wait for a TCP port to be listening
export async function waitForTCPPort(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const socket = await Bun.connect({
        hostname: "127.0.0.1",
        port,
        socket: {
          data() {},
          open(socket) {
            socket.end();
          },
          close() {},
          error() {},
        },
      });
      return;
    } catch {
      await Bun.sleep(50);
    }
  }
  throw new Error(`Timeout waiting for TCP port ${port}`);
}

// Clean up runtime directory
// Set KEEP_LOGS=1 to preserve runtime dir for debugging failed tests
export function cleanupRuntime(moduleName) {
  if (process.env.KEEP_LOGS) return;
  const runtimeDir = join(process.cwd(), "tests", moduleName, "runtime");
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
}

// Export mock factories
export { createRedisMock, RedisMock } from "./mocks/redis.js";
export { createPostgresMock, PostgresMock } from "./mocks/postgres.js";
export { createConsulMock, ConsulMock } from "./mocks/consul.js";
export { createOIDCMock, OIDCMock } from "./mocks/oidc.js";
export { createACMEMock, ACMEMock } from "./mocks/acme.js";
export { createOpenAIMock, OpenAIMock } from "./mocks/openai.js";
export { createAnthropicMock, AnthropicMock } from "./mocks/anthropic.js";
export {
  createHTTPMock,
  createStaticMock,
  createProxyMock,
  HTTPMock,
  StaticMock,
  ProxyMock,
} from "./mocks/http.js";

// Default ports for mock servers
export const MOCK_PORTS = {
  REDIS: 16379,
  POSTGRES: 15432,
  CONSUL: 18500,
  ACME: 14000,
  get OIDC() { return getPort(19000); },
  get HTTP() { return getPort(19001); },
  get HTTP_UPSTREAM_1() { return getPort(19002); },
  get HTTP_UPSTREAM_2() { return getPort(19003); },
  get OPENAI() { return getPort(19100); },
  get ANTHROPIC() { return getPort(19101); },
};

// Mock server manager - helps manage multiple mock servers
export class MockManager {
  constructor() {
    this.mocks = new Map();
  }

  add(name, mock) {
    this.mocks.set(name, mock);
    return mock;
  }

  get(name) {
    return this.mocks.get(name);
  }

  async stopAll() {
    for (const [name, mock] of this.mocks) {
      try {
        if (mock.stop) {
          mock.stop();
        }
      } catch (err) {
        console.error(`Error stopping mock ${name}:`, err);
      }
    }
    this.mocks.clear();
  }
}

// Create a new mock manager
export function createMockManager() {
  return new MockManager();
}
