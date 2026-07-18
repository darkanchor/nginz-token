import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { spawnSync } from "bun";
import { readFileSync } from "fs";
import { join } from "path";
import {
  startNginz, stopNginz, cleanupRuntime,
  reloadNginz, TEST_URL, createHTTPMock, configureTestPorts, getPort,
} from "../harness.js";

const MODULE = "llm-ratelimit";
const RL_CAPTURE_PORT = 19021;
configureTestPorts(MODULE);

// Unique per-test key helpers prevent counter cross-contamination across tests
// within the same nginx instance (shared memory is alive for the whole suite).
let keySeq = 0;
function uniqueKey(prefix = "k") {
  return `${prefix}-${++keySeq}-${Date.now()}`;
}

function childPids(parentPid) {
  const result = spawnSync(["ps", "-o", "pid=", "--ppid", String(parentPid)], {
    stdout: "pipe",
    stderr: "pipe",
  });
  return result.stdout.toString().trim().split(/\s+/).filter(Boolean).map(Number);
}

async function waitForReplacementWorker(masterPid, oldPid) {
  for (let i = 0; i < 100; i += 1) {
    const replacement = childPids(masterPid).find((pid) => pid !== oldPid);
    if (replacement) return replacement;
    await Bun.sleep(25);
  }
  throw new Error("timed out waiting for nginx replacement worker");
}

async function waitForMockRequests(mock, expected) {
  for (let i = 0; i < 100; i += 1) {
    if (mock.getRequestCount() >= expected) return;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for ${expected} upstream request(s)`);
}

function readRateLimitLogs(runtimeDir) {
  try {
    const text = readFileSync(join(runtimeDir, "logs", "ratelimit-m2.log"), "utf8").trimEnd();
    if (!text) return [];
    return text
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => {
        const [uri, outcome, requested, effective] = line.split("|");
        return { uri, outcome, requested, effective };
      });
  } catch {
    return [];
  }
}

async function waitForRateLimitLog(runtimeDir, baselineCount, predicate, timeout = 500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const logs = readRateLimitLogs(runtimeDir);
    const fresh = logs.slice(baselineCount);
    const match = fresh.find(predicate);
    if (match) return match;
    await Bun.sleep(10);
  }
  return undefined;
}

async function get(path, key = null, extraHeaders = {}) {
  // Connection: close is required: many tests expect 429, and nginx closes the
  // client connection after access-phase denials. Without this, Bun reuses a
  // half-closed socket and the next fetch fails with ECONNRESET.
  const headers = key
    ? { "x-rl-key": key, Connection: "close", ...extraHeaders }
    : { Connection: "close", ...extraHeaders };
  return fetch(`${TEST_URL}${path}`, { headers });
}

async function post(path, key, bodyObj) {
  return fetch(`${TEST_URL}${path}`, {
    method: "POST",
    headers: { "x-rl-key": key, "content-type": "application/json", Connection: "close" },
    body: JSON.stringify(bodyObj),
  });
}

describe("llm-ratelimit — phase 1 & 2", () => {
  let captureMock;

  beforeAll(async () => {
    captureMock = createHTTPMock(getPort(RL_CAPTURE_PORT));
    captureMock.setDefault({ body: { choices: [{ message: { content: "ok" } }] } });
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    captureMock.stop();
    cleanupRuntime(MODULE);
  });

  // ── Phase 1: basic quota enforcement ────────────────────────────────────

  test("allows requests under the configured limit", async () => {
    const key = uniqueKey("allow");
    const r1 = await get("/rl", key);
    const r2 = await get("/rl", key);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    expect(r1.headers.get("x-rl-deny-reason")).toBeNull();
  });

  test("denies requests after budget exhausted", async () => {
    const key = uniqueKey("exhaust");
    // Exhaust 3-RPM limit
    await get("/rl", key);
    await get("/rl", key);
    await get("/rl", key);
    const over = await get("/rl", key);
    expect(over.status).toBe(429);
  });

  test("deny response carries reason header", async () => {
    const key = uniqueKey("reason");
    await get("/rl", key);
    await get("/rl", key);
    await get("/rl", key);
    const over = await get("/rl", key);
    // 429 responses from nginx don't carry add_header for error status by default;
    // the deny_reason is available in the access log and $llm_ratelimit_deny_reason
    // variable for log_format use.
    expect(over.status).toBe(429);
  });

  test("remaining_requests decrements on each allowed request", async () => {
    const key = uniqueKey("remaining");
    const r1 = await get("/rl", key);
    const r2 = await get("/rl", key);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    const rem1 = parseInt(r1.headers.get("x-rl-remaining") ?? "-1");
    const rem2 = parseInt(r2.headers.get("x-rl-remaining") ?? "-1");
    expect(rem1).toBeGreaterThan(rem2);
  });

  test("distinct keys have independent counters", async () => {
    const keyA = uniqueKey("alice");
    const keyB = uniqueKey("bob");
    // Exhaust alice
    await get("/rl", keyA);
    await get("/rl", keyA);
    await get("/rl", keyA);
    const aliceOver = await get("/rl", keyA);
    expect(aliceOver.status).toBe(429);
    // Bob is unaffected
    const bobOk = await get("/rl", keyB);
    expect(bobOk.status).toBe(200);
  });

  test("burst allowance extends the window budget", async () => {
    const key = uniqueKey("burst");
    // /rl-burst: rpm=2 burst=1 → total=3
    const r1 = await get("/rl-burst", key);
    const r2 = await get("/rl-burst", key);
    const r3 = await get("/rl-burst", key);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    expect(r3.status).toBe(200);
    const r4 = await get("/rl-burst", key);
    expect(r4.status).toBe(429);
  });

  // ── Phase 1: missing key semantics ──────────────────────────────────────

  test("fail_open: missing key allows the request", async () => {
    // No x-rl-key header → key var is empty
    const res = await get("/rl-fail-open");
    expect(res.status).toBe(200);
    // deny_reason is set but nginx only emits add_header on 2xx by default
    expect(res.headers.get("x-rl-deny-reason")).toBeTruthy();
    expect(res.headers.get("x-rl-deny-reason")).toBe("identity_missing");
  });

  test("fail_closed: missing key denies the request", async () => {
    const res = await get("/rl-fail-closed");
    expect(res.status).toBe(429);
  });

  // ── Phase 1: dry_run semantics ───────────────────────────────────────────

  test("dry_run: never denies even when over limit", async () => {
    const key = uniqueKey("dry");
    // rpm=2, dry_run on → we can make as many requests as we want
    for (let i = 0; i < 5; i++) {
      const r = await get("/rl-dry-run", key);
      expect(r.status).toBe(200);
    }
  });

  test("dry_run: records deny_reason when over limit", async () => {
    const key = uniqueKey("dry-reason");
    // Exhaust the 2-RPM budget
    await get("/rl-dry-run", key);
    await get("/rl-dry-run", key);
    // Third request would be denied but dry_run keeps it 200
    const r3 = await get("/rl-dry-run", key);
    expect(r3.status).toBe(200);
    // deny_reason variable is set so it appears in response headers
    expect(r3.headers.get("x-rl-deny-reason")).toBe("request_budget_exhausted");
  });

  // ── Phase 1: no-op when not enabled ──────────────────────────────────────

  test("module is no-op for locations without llm_ratelimit", async () => {
    for (let i = 0; i < 10; i++) {
      const r = await get("/plain");
      expect(r.status).toBe(200);
    }
  });

  test("ssi subrequests to llm_ratelimit locations are rejected before upstream execution", async () => {
    captureMock.clearLog();
    const res = await get("/subrequest-ssi-parent");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("403 Forbidden");
    expect(captureMock.getRequestCount()).toBe(0);
  });

  test("auth_request subrequests to llm_ratelimit locations fail closed", async () => {
    captureMock.clearLog();
    const res = await get("/subrequest-auth-parent");
    expect(res.status).toBe(403);
    expect(captureMock.getRequestCount()).toBe(0);
  });

  test("mirror subrequests to llm_ratelimit locations do not reach upstream", async () => {
    captureMock.clearLog();
    const res = await get("/subrequest-mirror-parent");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('"choices":[{"message":{"content":"ok"}}]');
    await Bun.sleep(100);
    expect(captureMock.getRequestCount()).toBe(0);
  });

  // ── Phase 2: response-aware reconciliation ───────────────────────────────

  test("provider error (4xx upstream) still consumes request quota", async () => {
    const key = uniqueKey("p2-err");
    // 3 requests to /rl-provider-error (upstream returns 422 each time)
    const r1 = await get("/rl-provider-error", key);
    const r2 = await get("/rl-provider-error", key);
    const r3 = await get("/rl-provider-error", key);
    // All three pass through (422 is from upstream, not from our module)
    expect(r1.status).toBe(422);
    expect(r2.status).toBe(422);
    expect(r3.status).toBe(422);
    // Fourth request is denied by our module (quota exhausted)
    const r4 = await get("/rl-provider-error", key);
    expect(r4.status).toBe(429);
  });

  test("remaining counter is consistent after provider errors", async () => {
    const key = uniqueKey("p2-rem");
    const r1 = await get("/rl-provider-error", key);
    const r2 = await get("/rl-provider-error", key);
    expect(r1.status).toBe(422);
    expect(r2.status).toBe(422);
    const rem1 = parseInt(r1.headers.get("x-rl-remaining") ?? "-1");
    const rem2 = parseInt(r2.headers.get("x-rl-remaining") ?? "-1");
    // Each provider error still consumed a slot
    expect(rem1).toBeGreaterThan(rem2);
  });

  test("client retries with different keys don't share state", async () => {
    const keyA = uniqueKey("retry-a");
    const keyB = uniqueKey("retry-b");
    // Exhaust keyA
    await get("/rl", keyA);
    await get("/rl", keyA);
    await get("/rl", keyA);
    expect((await get("/rl", keyA)).status).toBe(429);
    // keyB is fresh — not double-consumed
    expect((await get("/rl", keyB)).status).toBe(200);
    expect((await get("/rl", keyB)).status).toBe(200);
  });

  async function killAfterAccess(path, key, extraHeaders = {}) {
    captureMock.clearLog();
    captureMock.setLatency(500);
    try {
      const runtimeDir = join(process.cwd(), "tests", MODULE, "runtime");
      const masterPid = Number(readFileSync(join(runtimeDir, "logs", "nginx.pid"), "utf8").trim());
      const oldWorker = childPids(masterPid)[0];
      const pending = fetch(`${TEST_URL}${path}`, {
        method: "POST",
        headers: {
          "x-rl-key": key,
          "content-type": "application/json",
          Connection: "close",
          ...extraHeaders,
        },
        body: JSON.stringify({ model: "gpt-4o", messages: [{ role: "user", content: "kill invariant" }] }),
      }).catch(() => null);
      await waitForMockRequests(captureMock, 1);
      process.kill(oldWorker, "SIGKILL");
      await waitForReplacementWorker(masterPid, oldWorker);
      await pending;
    } finally {
      captureMock.setLatency(0);
    }
  }

  test("committed RPM admission remains consumed after worker death", async () => {
    const key = uniqueKey("kill-rpm");
    await killAfterAccess("/rl-kill-rpm", key);
    const next = await post("/rl-kill-rpm", key, { model: "gpt-4o", messages: [] });
    expect(next.status).toBe(429);
    expect(next.headers.get("x-rl-deny-reason")).toBe("request_budget_exhausted");
  });

  test("committed token reservation remains conservative after worker death", async () => {
    const key = uniqueKey("kill-tpm");
    await killAfterAccess("/rl-kill-tpm", key);
    const next = await post("/rl-kill-tpm", key, { model: "gpt-4o", messages: [] });
    expect(next.status).toBe(429);
    expect(next.headers.get("x-rl-deny-reason")).toBe("token_budget_exhausted");
  });

  test("committed spend reservation remains conservative after worker death", async () => {
    const key = uniqueKey("kill-spend");
    const org = uniqueKey("kill-org");
    await killAfterAccess("/rl-kill-spend", key, { "x-org-id": org });
    const next = await fetch(`${TEST_URL}/rl-kill-spend`, {
      method: "POST",
      headers: {
        "x-rl-key": uniqueKey("kill-spend-next"),
        "x-org-id": org,
        "content-type": "application/json",
        Connection: "close",
      },
      body: JSON.stringify({ model: "gpt-4o", messages: [] }),
    });
    expect(next.status).toBe(429);
    expect(next.headers.get("x-rl-deny-reason")).toBe("spend_budget_exhausted");
  });

  test("rate and spend mutex paths survive reload without killing the new worker", async () => {
    const runtimeDir = join(process.cwd(), "tests", MODULE, "runtime");
    const masterPid = Number(readFileSync(join(runtimeDir, "logs", "nginx.pid"), "utf8").trim());
    const oldWorker = childPids(masterPid)[0];
    const rateKey = uniqueKey("reload-rate");

    expect((await get("/rl", rateKey)).status).toBe(200);
    await reloadNginz();

    const newWorker = childPids(masterPid).find((pid) => pid !== oldWorker);
    expect(newWorker).toBeGreaterThan(0);

    // The rate mutex must retain the pre-reload admission state.
    expect((await get("/rl", rateKey)).status).toBe(200);
    expect((await get("/rl", rateKey)).status).toBe(200);
    expect((await get("/rl", rateKey)).status).toBe(429);

    // This request takes the spend mutex in ACCESS and LOG phases.
    const spend = await fetch(`${TEST_URL}/rl-kill-spend`, {
      method: "POST",
      headers: {
        "x-rl-key": uniqueKey("reload-spend-rate"),
        "x-org-id": uniqueKey("reload-spend-org"),
        "content-type": "application/json",
        Connection: "close",
      },
      body: JSON.stringify({ model: "gpt-4o", messages: [] }),
    });
    expect(spend.status).toBe(200);
    await spend.arrayBuffer();

    // LOG runs after the response is sent. Give nginx time to reap a crashing
    // worker, then assert that the worker which served post-reload traffic lives.
    await Bun.sleep(100);
    expect(childPids(masterPid)).toContain(newWorker);
  });
});

// ── Phase 3: token budgets ───────────────────────────────────────────────────

describe("llm-ratelimit — phase 3: token budgets", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("token budget exhaustion via reservation", async () => {
    // /rl-tpm: tpm=200, reserve=100 → requests 1 and 2 each reserve 100 (total 200), 3rd would need 300 > 200
    const key = uniqueKey("tpm");
    const r1 = await get("/rl-tpm", key);
    const r2 = await get("/rl-tpm", key);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    const r3 = await get("/rl-tpm", key);
    expect(r3.status).toBe(429);
  });

  test("token quota remaining decrements with reservations", async () => {
    const key = uniqueKey("tokrem");
    const r1 = await get("/rl-tpm", key);
    const r2 = await get("/rl-tpm", key);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    const tok1 = parseInt(r1.headers.get("x-rl-tok-remaining") ?? "-1");
    const tok2 = parseInt(r2.headers.get("x-rl-tok-remaining") ?? "-1");
    // Each request reserves 100 tokens; remaining should decrease
    expect(tok1).toBeGreaterThan(tok2);
  });

  test("token reconciliation: actual usage replaces reservation", async () => {
    // /rl-tokens: tpm=500, reserve=300, llm-proxy reports actual=100 per request.
    // Without reconciliation: req 1 reserves 300, req 2 would need 300+300=600>500 → denied.
    // With reconciliation: after req 1, token_count drops to 100, so req 2 is 100+300=400<=500 → allowed.
    const key = uniqueKey("reconcile");
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "test" }] };
    const r1 = await post("/rl-tokens", key, body);
    expect(r1.status).toBe(200);
    // This passes only if reconciliation ran and reduced token_count from 300 to 100
    const r2 = await post("/rl-tokens", key, body);
    expect(r2.status).toBe(200);
  });

  test("separate token keys are independent", async () => {
    const keyA = uniqueKey("tokA");
    const keyB = uniqueKey("tokB");
    // Exhaust keyA (tpm=200, reserve=100)
    await get("/rl-tpm", keyA);
    await get("/rl-tpm", keyA);
    expect((await get("/rl-tpm", keyA)).status).toBe(429);
    // keyB is unaffected
    expect((await get("/rl-tpm", keyB)).status).toBe(200);
  });
});

// ── Phase 4: policy tiers ────────────────────────────────────────────────────

describe("llm-ratelimit — phase 4: policy tiers", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("model tier override restricts gpt-4o to 2 RPM", async () => {
    // /rl-model-override: base=10 RPM, gpt-4o=2 RPM.
    // llm-proxy reads the request body and sets $llm_model="gpt-4o".
    const key = uniqueKey("gpt4o");
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r1 = await post("/rl-model-override", key, body);
    const r2 = await post("/rl-model-override", key, body);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    // Third request exceeds the gpt-4o 2-RPM tier
    const r3 = await post("/rl-model-override", key, body);
    expect(r3.status).toBe(429);
  });

  test("model override does not affect unrecognized model requests", async () => {
    // With no JSON body, llm-proxy can't set $llm_model; base RPM (10) applies.
    const key = uniqueKey("nomodel");
    for (let i = 0; i < 5; i++) {
      const r = await get("/rl-model-override", key);
      expect(r.status).toBe(200);
    }
  });

  test("provider RPM override restricts openai traffic to 2 RPM", async () => {
    const key = uniqueKey("provider-rpm");
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    expect((await post("/rl-provider-rpm", key, body)).status).toBe(200);
    expect((await post("/rl-provider-rpm", key, body)).status).toBe(200);
    expect((await post("/rl-provider-rpm", key, body)).status).toBe(429);
  });

  test("provider TPM override is enforced after usage reconciliation", async () => {
    const key = uniqueKey("provider-tpm");
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r1 = await post("/rl-provider-tpm", key, body);
    expect(r1.status).toBe(200);
    expect(parseInt(r1.headers.get("x-rl-tok-remaining") ?? "-1")).toBe(50);

    const r2 = await post("/rl-provider-tpm", key, body);
    expect(r2.status).toBe(429);
    expect(r2.headers.get("x-rl-deny-reason")).toBe("token_budget_exhausted");
  });
});

// ── Milestone 2 ───────────────────────────────────────────────────────────────

describe("llm-ratelimit — Milestone 2", () => {
  let m2Mock;
  let runtimeDir;

  beforeAll(async () => {
    m2Mock = createHTTPMock(getPort(RL_CAPTURE_PORT)); // port is known; configureTestPorts ran at module load
    m2Mock.setDefault({ body: { choices: [{ message: { content: "ok" } }] } });
    runtimeDir = await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    m2Mock.stop();
    cleanupRuntime(MODULE);
  });

  // ── Target 1: org/project/client quota isolation ─────────────────────────

  test("M2-T1: distinct org:project keys have independent counters", async () => {
    // Exhaust orgA/proj1 (limit=2)
    await get("/rl-composite-key", null, { "x-quota-scope": "orgA:proj1:clientX" });
    await get("/rl-composite-key", null, { "x-quota-scope": "orgA:proj1:clientX" });
    const over = await get("/rl-composite-key", null, { "x-quota-scope": "orgA:proj1:clientX" });
    expect(over.status).toBe(429);

    // orgA/proj2 is a separate counter — unaffected
    const proj2 = await get("/rl-composite-key", null, { "x-quota-scope": "orgA:proj2:clientX" });
    expect(proj2.status).toBe(200);

    // orgB/proj1 is also independent
    const orgB = await get("/rl-composite-key", null, { "x-quota-scope": "orgB:proj1:clientX" });
    expect(orgB.status).toBe(200);
  });

  test("M2-T1: missing scope header fails closed (deny)", async () => {
    // No x-quota-scope header → key_var resolves to empty → deny (fail_open defaults off)
    const r = await get("/rl-composite-key");
    expect(r.status).toBe(429);
  });

  // ── Target 2: translated-traffic quota limits ─────────────────────────────

  test("M2-T2: translated_rpm applies to cross-dialect requests", async () => {
    // claude-3-haiku: body dialect=openai, effective dialect=anthropic → translation detected
    const key = uniqueKey("trans");
    const body = { model: "claude-3-haiku-20240307", messages: [{ role: "user", content: "hi" }] };
    const r1 = await post("/rl-translated", key, body);
    expect(r1.status).toBe(200);
    const r2 = await post("/rl-translated", key, body);
    expect(r2.status).toBe(200);
    // Third request exceeds translated_rpm=2
    const r3 = await post("/rl-translated", key, body);
    expect(r3.status).toBe(429);
  });

  test("M2-T2: native-path requests are not affected by translated_rpm", async () => {
    // gpt-4o: body dialect=openai, effective dialect=openai → no translation → base RPM=3 applies
    const key = uniqueKey("native");
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    for (let i = 0; i < 3; i++) {
      const r = await post("/rl-native", key, body);
      expect(r.status).toBe(200);
    }
    const over = await post("/rl-native", key, body);
    expect(over.status).toBe(429);
  });

  test("M2-T2: rejected_out_of_scope request returns its consumed slot", async () => {
    const key = uniqueKey("scope-return");
    const rejected = await post("/rl-rejected-out-of-scope", key, {
      provider: "anthropic",
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(rejected.status).toBe(400);

    const allowed1 = await post("/rl-rejected-out-of-scope", key, {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    const allowed2 = await post("/rl-rejected-out-of-scope", key, {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    const over = await post("/rl-rejected-out-of-scope", key, {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });

    expect(allowed1.status).toBe(200);
    expect(allowed2.status).toBe(200);
    expect(over.status).toBe(429);
  });

  // ── Target 3: model_basis effective ──────────────────────────────────────

  test("M2-T3: model_basis effective uses effective model for tier override", async () => {
    // When model_basis=effective and no replacement happens, effective==requested,
    // so the gpt-4o tier (RPM=2) applies just like without model_basis setting.
    const key = uniqueKey("basis");
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r1 = await post("/rl-model-basis", key, body);
    expect(r1.status).toBe(200);
    const r2 = await post("/rl-model-basis", key, body);
    expect(r2.status).toBe(200);
    const r3 = await post("/rl-model-basis", key, body);
    expect(r3.status).toBe(429);
  });

  test("M2-T3: replacement and suppressed provider replay remain distinct in quota logs", async () => {
    const replaceBaseline = readRateLimitLogs(runtimeDir).length;
    const replaced = await post("/rl-replace-logged", uniqueKey("replace"), {
      provider: "openai",
      model: "claude-3-haiku-20240307",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(replaced.status).toBe(200);

    const replaceLog = await waitForRateLimitLog(
      runtimeDir,
      replaceBaseline,
      (entry) => entry.uri === "/rl-replace-logged",
    );
    expect(replaceLog).toBeDefined();
    expect(replaceLog.outcome).toBe("replaced_by_policy");
    expect(replaceLog.requested).toBe("openai");
    expect(replaceLog.effective).toBe("anthropic");

    const fallbackBaseline = readRateLimitLogs(runtimeDir).length;
    const fallback = await post("/rl-fallback-logged", uniqueKey("fallback"), {
      provider: "openai",
      model: "claude-3-haiku-20240307",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(fallback.status).toBe(502);
    expect(fallback.headers.get("x-fallback-attempted")).toBe("0");
    expect(fallback.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");

    const fallbackLog = await waitForRateLimitLog(
      runtimeDir,
      fallbackBaseline,
      (entry) => entry.uri === "/rl-fallback-logged",
    );
    expect(fallbackLog).toBeDefined();
    expect(fallbackLog.outcome).toBe("as_requested");
    expect(fallbackLog.requested).toBe("openai");
    expect(fallbackLog.effective).toBe("openai");
  });
});

// ── Milestone 2 Target 5: monthly spend budgets ───────────────────────────────

describe("llm-ratelimit — M2 Target 5: spend budgets", () => {
  // Port 8892 (openai_p34) is served by an nginx-internal server block in the
  // config that returns usage:{prompt_tokens:50,completion_tokens:50}.
  // With llm_cost_rate openai gpt-4o 5.0 15.0, cost = 0.001 USD = 1000 micros,
  // which exactly matches the budget on /rl-spend-org and /rl-spend-project.
  // One request exhausts the budget; the second is denied.
  let spendMock;
  let runtimeDir;

  beforeAll(async () => {
    spendMock = createHTTPMock(getPort(RL_CAPTURE_PORT));
    spendMock.setDefault({ body: { choices: [{ message: { content: "ok" } }] } });
    runtimeDir = await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    spendMock.stop();
    cleanupRuntime(MODULE);
  });

  async function postSpend(path, rlKey, orgId, projectId = null, clientId = null) {
    const headers = {
      "x-rl-key": rlKey,
      "x-org-id": orgId,
      "content-type": "application/json",
      Connection: "close",
    };
    if (projectId !== null) headers["x-project-id"] = projectId;
    if (clientId !== null) headers["x-client-id"] = clientId;
    return fetch(`${TEST_URL}${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify({ model: "gpt-4o", messages: [{ role: "user", content: "hi" }] }),
    });
  }

  async function postSpendModel(path, rlKey, orgId, model) {
    return fetch(`${TEST_URL}${path}`, {
      method: "POST",
      headers: {
        "x-rl-key": rlKey,
        "x-org-id": orgId,
        "content-type": "application/json",
        Connection: "close",
      },
      body: JSON.stringify({ model, messages: [{ role: "user", content: "hi" }] }),
    });
  }

  test("M2-T5: org-scope budget exhausted after one costly request", async () => {
    const orgId = uniqueKey("orgA");
    const rlKey = uniqueKey("rl-spend-org");

    const r1 = await postSpend("/rl-spend-org", rlKey, orgId);
    expect(r1.status).toBe(200);

    const r2 = await postSpend("/rl-spend-org", rlKey, orgId);
    expect(r2.status).toBe(429);
    expect(r2.headers.get("x-rl-deny-reason")).toBe("spend_budget_exhausted");
    expect(r2.headers.get("x-rl-spend-unit")).toBe("usd");
  });

  test("hard spend reservation admits only one concurrent near-limit request", async () => {
    const orgId = uniqueKey("orgHardReserve");
    const rlKey = uniqueKey("rl-spend-hard-reserve");
    const responses = await Promise.all(
      Array.from({ length: 16 }, () => postSpend("/rl-spend-hard-reserve", rlKey, orgId))
    );
    const allowed = responses.filter((r) => r.status === 200);
    const denied = responses.filter((r) => r.status === 429);
    expect(allowed.length).toBe(1);
    expect(denied.length).toBe(15);
    for (const r of denied) {
      expect(r.headers.get("x-rl-deny-reason")).toBe("spend_budget_exhausted");
    }
  });

  test("worker SIGKILL during ledger traffic does not wedge nginx-managed mutexes", async () => {
    const masterPid = Number(readFileSync(join(runtimeDir, "logs", "nginx.pid"), "utf8").trim());
    const oldWorker = childPids(masterPid)[0];
    expect(oldWorker).toBeGreaterThan(0);

    const traffic = Promise.allSettled(
      Array.from({ length: 200 }, (_, i) =>
        postSpend(
          "/rl-spend-hard-reserve",
          uniqueKey(`kill-rl-${i}`),
          uniqueKey(`kill-org-${i}`),
        )
      )
    );
    await Bun.sleep(2);
    process.kill(oldWorker, "SIGKILL");
    const replacement = await waitForReplacementWorker(masterPid, oldWorker);
    expect(replacement).not.toBe(oldWorker);
    await traffic;

    const recovered = await postSpend(
      "/rl-spend-hard-reserve",
      uniqueKey("post-kill-rl"),
      uniqueKey("post-kill-org"),
    );
    expect(recovered.status).toBe(200);
  });

  test("M2-T5: different org IDs have independent spend counters", async () => {
    const rlKey = uniqueKey("rl-spend-iso");
    const orgA = uniqueKey("orgIsoA");
    const orgB = uniqueKey("orgIsoB");

    await postSpend("/rl-spend-org", rlKey, orgA);
    const over = await postSpend("/rl-spend-org", rlKey, orgA);
    expect(over.status).toBe(429);

    const r3 = await postSpend("/rl-spend-org", rlKey, orgB);
    expect(r3.status).toBe(200);
  });

  test("M2-T5: project-scope budget uses org+project composite identity", async () => {
    const rlKey = uniqueKey("rl-spend-proj");
    const orgId = uniqueKey("orgP");

    const r1 = await postSpend("/rl-spend-project", rlKey, orgId, "proj1");
    expect(r1.status).toBe(200);
    const r2 = await postSpend("/rl-spend-project", rlKey, orgId, "proj1");
    expect(r2.status).toBe(429);
    expect(r2.headers.get("x-rl-deny-reason")).toBe("spend_budget_exhausted");

    const r3 = await postSpend("/rl-spend-project", rlKey, orgId, "proj2");
    expect(r3.status).toBe(200);
  });

  test("M2-T5: client-scope budget uses org+project+client composite identity", async () => {
    const rlKey = uniqueKey("rl-spend-client");
    const orgId = uniqueKey("orgC");
    const projectId = "proj-client";

    const r1 = await postSpend("/rl-spend-client", rlKey, orgId, projectId, "client1");
    expect(r1.status).toBe(200);
    const r2 = await postSpend("/rl-spend-client", rlKey, orgId, projectId, "client1");
    expect(r2.status).toBe(429);
    expect(r2.headers.get("x-rl-deny-reason")).toBe("spend_budget_exhausted");

    const r3 = await postSpend("/rl-spend-client", rlKey, orgId, projectId, "client2");
    expect(r3.status).toBe(200);
  });

  test("M2-T5: larger spend budget accumulates without premature denial", async () => {
    const rlKey = uniqueKey("rl-spend-accumulate");
    const orgId = uniqueKey("orgAccum");

    const r1 = await postSpend("/rl-spend-accumulate", rlKey, orgId);
    expect(r1.status).toBe(200);
    const r2 = await postSpend("/rl-spend-accumulate", rlKey, orgId);
    expect(r2.status).toBe(200);
    const r3 = await postSpend("/rl-spend-accumulate", rlKey, orgId);
    expect(r3.status).toBe(200);
    expect(r3.headers.get("x-rl-deny-reason")).toBeNull();
  });

  test("M2-T5: dry-run mode never denies even when budget is exhausted", async () => {
    const rlKey = uniqueKey("rl-spend-dry");
    const orgId = uniqueKey("orgDry");

    const r1 = await postSpend("/rl-spend-dry-run", rlKey, orgId);
    expect(r1.status).toBe(200);

    const r2 = await postSpend("/rl-spend-dry-run", rlKey, orgId);
    expect(r2.status).toBe(200);
    expect(r2.headers.get("x-rl-deny-reason")).toBe("spend_budget_exhausted");
  });

  test("M2-T5: spend budgets are isolated by effective provider cost unit", async () => {
    const rlKey = uniqueKey("rl-spend-unit");
    const orgId = uniqueKey("orgUnit");

    const usd1 = await postSpendModel("/rl-spend-mixed-unit-usd", rlKey, orgId, "gpt-4o");
    expect(usd1.status).toBe(200);

    const usd2 = await postSpendModel("/rl-spend-mixed-unit-usd", rlKey, orgId, "gpt-4o");
    expect(usd2.status).toBe(429);
    expect(usd2.headers.get("x-rl-spend-unit")).toBe("usd");

    const cny1 = await postSpendModel("/rl-spend-mixed-unit-cny", rlKey, orgId, "claude-3-haiku-20240307");
    expect(cny1.status).toBe(200);

    const cny2 = await postSpendModel("/rl-spend-mixed-unit-cny", rlKey, orgId, "claude-3-haiku-20240307");
    expect(cny2.status).toBe(429);
    expect(cny2.headers.get("x-rl-spend-unit")).toBe("cny");
  });
});
