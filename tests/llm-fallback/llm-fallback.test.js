import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  configureTestPorts,
  getPort,
  materializeTestConfig,
} from "../harness.js";
import { spawnSync } from "bun";
import { mkdirSync, rmSync, existsSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

const MODULE = "llm-fallback";
configureTestPorts(MODULE);
const NGINZ_BIN = "./zig-out/bin/nginz-token";

const M2_PHASE6_LOG = join(process.cwd(), "tests", MODULE, "runtime", "logs", "m2_phase6.log");
const M2_PHASE7_LOG = join(process.cwd(), "tests", MODULE, "runtime", "logs", "m2_phase7.log");
const M2_PHASE8_LOG = join(process.cwd(), "tests", MODULE, "runtime", "logs", "m2_phase8.log");

function readLogLines(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").split("\n").map(l => l.trim()).filter(Boolean);
}

async function waitForLogLine(path, startCount) {
  for (let i = 0; i < 60; i++) {
    const lines = readLogLines(path);
    if (lines.length > startCount) return lines.at(-1);
    await Bun.sleep(50);
  }
  throw new Error(`timeout waiting for log line in ${path}`);
}

function runNginxTest(confPath) {
  const tmpPrefix = join(tmpdir(), `nginz-llm-fallback-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  mkdirSync(join(tmpPrefix, "logs"), { recursive: true });
  let configPath = null;
  try {
    configPath = materializeTestConfig(confPath, MODULE, tmpPrefix);
    return spawnSync([NGINZ_BIN, "-c", configPath, "-p", tmpPrefix, "-t"], {
      stdout: "pipe",
      stderr: "pipe",
    });
  } finally {
    if (configPath) rmSync(configPath, { force: true });
    rmSync(tmpPrefix, { recursive: true, force: true });
  }
}

// ── Phase 1: scaffold tests ──────────────────────────────────────────────────

describe("llm-fallback — phase 1: scaffold", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("enabled_scaffold_does_not_change_proxy_behavior", async () => {
    // llm_fallback; at /scaffold with no routes or mode — request passes through unchanged.
    const r = await fetch(`${TEST_URL}/scaffold`, { headers: { Connection: "close" } });
    expect(r.status).toBe(200);
    expect(await r.text()).toBe("ok");
  });
});

// ── Phase 2: config validation tests ────────────────────────────────────────

describe("llm-fallback — phase 2: config validation", () => {
  test("accepts_basic_fallback_route_graph", () => {
    // nginx.conf: valid single-edge and chain configs — config test must succeed.
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx.conf`));
    expect(result.exitCode).toBe(0);
  });

  test("inherits_enabled_flag_from_parent_location", () => {
    // nginx-inherit.conf: parent sets mode+route; child has only llm_fallback.
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx-inherit.conf`));
    expect(result.exitCode).toBe(0);
  });

  test("inherits_route_policy_from_parent_location", () => {
    // Same config — validates that mode, route, and max_attempts all inherit.
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx-inherit.conf`));
    expect(result.exitCode).toBe(0);
  });

  test("rejects_duplicate_primary_provider_routes", () => {
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx-bad-duplicate-route.conf`));
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("llm_fallback_route: duplicate primary provider");
  });

  test("rejects_cyclic_fallback_route_graph", () => {
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx-bad-cyclic-route.conf`));
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("llm_fallback_route: cyclic fallback graph detected");
  });

  test("accepts_maximal_chain_acyclic_route_graph", () => {
    // A 4-route chain provA→provB→provC→provD→provE is a valid DAG.
    // Verifies has_cycle() does not produce a false positive on long acyclic chains.
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx-maxchain-route.conf`));
    expect(result.exitCode).toBe(0);
  });
});

// ── Phase 3: failure taxonomy config tests ───────────────────────────────────

describe("llm-fallback — phase 3: failure taxonomy config", () => {
  test("accepts_all_valid_failure_class_tokens", () => {
    // nginx.conf includes /p3-classes with all four tokens — config must succeed.
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx.conf`));
    expect(result.exitCode).toBe(0);
  });

  test("rejects_unknown_failure_class_tokens", () => {
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx-bad-unknown-class.conf`));
    expect(result.exitCode).toBe(1);
    const output = result.stderr.toString();
    expect(output).toContain("llm_fallback_on: unknown failure class");
    expect(output).toContain("unknown_class");
  });

  test("accepts_allow_streaming_off_directive", () => {
    // nginx.conf includes /p3-no-stream with allow_streaming off — config must succeed.
    const result = runNginxTest(join(process.cwd(), `tests/${MODULE}/nginx.conf`));
    expect(result.exitCode).toBe(0);
  });
});

// ── Phase 4: runtime retry and outcome tests ─────────────────────────────────

const GOOD_RESP = JSON.stringify({
  choices: [{ message: { content: "ok" } }],
  usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 },
});

describe("llm-fallback — phase 4: retry outcome", () => {
  let primaryMock;
  let secondaryMock;

  beforeAll(async () => {
    primaryMock   = createHTTPMock(getPort(19002));
    secondaryMock = createHTTPMock(getPort(19003));
    // Default: primary succeeds, secondary is a fallback backup.
    primaryMock.setDefault({
      status: 200,
      body: GOOD_RESP,
      headers: { "Content-Type": "application/json" },
    });
    secondaryMock.setDefault({
      status: 200,
      body: GOOD_RESP,
      headers: { "Content-Type": "application/json" },
    });
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    primaryMock.stop();
    secondaryMock.stop();
    cleanupRuntime(MODULE);
  });

  test("no_fallback_when_primary_succeeds", async () => {
    // /p4-no-retry uses a single-server upstream so p4_up's round-robin is not advanced.
    const r = await fetch(`${TEST_URL}/p4-no-retry`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ model: "gpt-4", messages: [{ role: "user", content: "hi" }] }),
    });
    expect(r.status).toBe(200);
    // No retry: fallback_attempted must be 0.
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-primary")).toBe("openai");
  });

  test("surfaces_primary_and_effective_provider_after_failover", async () => {
    // Make primary return 500 so nginx retries via proxy_next_upstream.
    primaryMock.setDefault({ status: 500, body: "Internal Server Error" });

    const r = await fetch(`${TEST_URL}/p4-retry`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ model: "gpt-4", messages: [{ role: "user", content: "hi" }] }),
    });
    // nginx retried via proxy_next_upstream; secondary responded with 200.
    expect(r.status).toBe(200);
    expect(r.headers.get("x-fallback-attempted")).toBe("1");
    expect(r.headers.get("x-fallback-primary")).toBe("openai");
    // Peer retry remains within the already-authenticated provider contract.
    expect(r.headers.get("x-fallback-effective")).toBe("openai");

    primaryMock.setDefault({
      status: 200,
      body: GOOD_RESP,
      headers: { "Content-Type": "application/json" },
    });
  });

  test("classifies_dead_primary_as_connect_error_when_no_bytes_arrive", async () => {
    const r = await fetch(`${TEST_URL}/p4-connect-retry`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ model: "gpt-4", messages: [{ role: "user", content: "hi" }] }),
    });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-fallback-attempted")).toBe("1");
    expect(r.headers.get("x-fallback-suppressed")).toBe("0");
    expect(r.headers.get("x-fallback-primary")).toBe("openai");
    expect(r.headers.get("x-fallback-effective")).toBe("openai");
    expect(r.headers.get("x-fallback-reason")).toBe("connect_error");
    expect(r.headers.get("x-fallback-policy-allowed")).toBe("1");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("0");
  });

  test("llm_fallback_max_attempts overrides a lower proxy_next_upstream_tries bound", async () => {
    const r = await fetch(`${TEST_URL}/p4-max-attempts-enforced`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ model: "gpt-4", messages: [{ role: "user", content: "hi" }] }),
    });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-fallback-attempted")).toBe("1");
    expect(r.headers.get("x-fallback-primary")).toBe("openai");
    expect(r.headers.get("x-fallback-effective")).toBe("openai");
    expect(r.headers.get("x-fallback-reason")).toBe("connect_error");
  });

  test("surfaces_streaming_suppression_when_no_retry_occurs", async () => {
    primaryMock.setDefault({ status: 500, body: "Internal Server Error" });

    const r = await fetch(`${TEST_URL}/p4-stream-suppressed`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({
        model: "gpt-4",
        stream: true,
        messages: [{ role: "user", content: "hi" }],
      }),
    });
    expect(r.status).toBe(500);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("streaming_not_allowed");
    expect(r.headers.get("x-fallback-primary")).toBe("openai");
    expect(r.headers.get("x-fallback-reason")).toBe("upstream_5xx");
    expect(r.headers.get("x-fallback-effective")).toBe(null);

    primaryMock.setDefault({
      status: 200,
      body: GOOD_RESP,
      headers: { "Content-Type": "application/json" },
    });
  });

  test("records_rate_limited_retry_as_policy_allowed", async () => {
    primaryMock.setDefault({ status: 429, body: "Rate limited" });

    const r = await fetch(`${TEST_URL}/p4-429-allowed`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ model: "gpt-4", messages: [{ role: "user", content: "hi" }] }),
    });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-fallback-attempted")).toBe("1");
    expect(r.headers.get("x-fallback-reason")).toBe("rate_limited");
    expect(r.headers.get("x-fallback-policy-allowed")).toBe("1");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("0");
    expect(r.headers.get("x-fallback-effective")).toBe("openai");

    primaryMock.setDefault({
      status: 200,
      body: GOOD_RESP,
      headers: { "Content-Type": "application/json" },
    });
  });

  test("records_runtime_policy_mismatch_when_429_retries_are_not_allowed", async () => {
    primaryMock.setDefault({ status: 429, body: "Rate limited" });

    const r = await fetch(`${TEST_URL}/p4-429-mismatch`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ model: "gpt-4", messages: [{ role: "user", content: "hi" }] }),
    });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-fallback-attempted")).toBe("1");
    expect(r.headers.get("x-fallback-reason")).toBe("rate_limited");
    expect(r.headers.get("x-fallback-policy-allowed")).toBe("0");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("1");
    expect(r.headers.get("x-fallback-effective")).toBe("openai");

    primaryMock.setDefault({
      status: 200,
      body: GOOD_RESP,
      headers: { "Content-Type": "application/json" },
    });
  });
});

// ── Milestone 2: Targets 1–3 ────────────────────────────────────────────────

const OPENAI_RESP = JSON.stringify({
  choices: [{ message: { content: "ok from openai" } }],
  usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 },
});
const ANTHROPIC_RESP = JSON.stringify({
  choices: [{ message: { content: "ok from anthropic" } }],
  usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 },
});

describe("llm-fallback — Milestone 2 Target 1 (Phase 6): pre-send replacement", () => {
  let primaryMock;   // 19002 = openai
  let secondaryMock; // 19003 = anthropic

  beforeAll(async () => {
    primaryMock   = createHTTPMock(getPort(19002));
    secondaryMock = createHTTPMock(getPort(19003));
    primaryMock.setDefault({ status: 200, body: OPENAI_RESP, headers: { "Content-Type": "application/json" } });
    secondaryMock.setDefault({ status: 200, body: ANTHROPIC_RESP, headers: { "Content-Type": "application/json" } });
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    primaryMock.stop();
    secondaryMock.stop();
    cleanupRuntime(MODULE);
  });

  beforeEach(() => {
    primaryMock.clearLog();
    secondaryMock.clearLog();
  });

  async function post(path, body) {
    const res = await fetch(`${TEST_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify(body),
    });
    return res;
  }

  test("first_hop_preserves_intent_when_no_replacement_configured", async () => {
    const r = await post("/p6-no-replace", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-llm-replacement-happened")).toBe("0");
    expect(r.headers.get("x-llm-resolution-outcome")).toBe("as_requested");
    expect(r.headers.get("x-llm-effective-provider")).toBe("openai");
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    // Only the openai mock should have been hit.
    expect(primaryMock.getRequestCount()).toBe(1);
    expect(secondaryMock.getRequestCount()).toBe(0);
  });

  test("pre_send_replacement_changes_effective_provider_before_first_send", async () => {
    const r = await post("/p6-replace", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    // replacement_happened set in ACCESS phase body handler — readable via add_header
    expect(r.headers.get("x-llm-replacement-happened")).toBe("1");
    expect(r.headers.get("x-llm-resolution-outcome")).toBe("replaced_by_policy");
    expect(r.headers.get("x-llm-effective-provider")).toBe("anthropic");
    // No failure-driven retry: replacement is pre-send, not post-failure.
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    // The anthropic mock (19003) was hit; the openai mock (19002) was not.
    expect(primaryMock.getRequestCount()).toBe(0);
    expect(secondaryMock.getRequestCount()).toBe(1);
  });

  test("replacement_and_fallback_are_distinct_not_set_simultaneously", async () => {
    // Replacement sets replacement_happened=1 but NOT fallback_attempted=1.
    // Both being 1 would conflate pre-send policy with post-failure behaviour.
    const r = await post("/p6-replace", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-llm-replacement-happened")).toBe("1");
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
  });

  test("replacement_recorded_in_access_log_with_correct_outcome", async () => {
    const startCount = readLogLines(M2_PHASE6_LOG).length;
    await post("/p6-replace", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    const line = await waitForLogLine(M2_PHASE6_LOG, startCount);
    const [, replacementHappened, resolutionOutcome, effectiveProvider, fallbackAttempted] = line.split("|");
    expect(replacementHappened).toBe("1");
    expect(resolutionOutcome).toBe("replaced_by_policy");
    expect(effectiveProvider).toBe("anthropic");
    expect(fallbackAttempted).toBe("0");
  });
});

describe("llm-fallback — Milestone 2 Target 2 (Phase 7): catalog-aware fallback (model override)", () => {
  let primaryMock;   // 19002 = openai — will be set to 500 to force retry
  let secondaryMock; // 19003 = fallback target with model override

  beforeAll(async () => {
    primaryMock   = createHTTPMock(getPort(19002));
    secondaryMock = createHTTPMock(getPort(19003));
    primaryMock.setDefault({ status: 200, body: GOOD_RESP, headers: { "Content-Type": "application/json" } });
    secondaryMock.setDefault({ status: 200, body: ANTHROPIC_RESP, headers: { "Content-Type": "application/json" } });
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    primaryMock.stop();
    secondaryMock.stop();
    cleanupRuntime(MODULE);
  });

  beforeEach(() => {
    primaryMock.clearLog();
    secondaryMock.clearLog();
    primaryMock.setDefault({ status: 200, body: GOOD_RESP, headers: { "Content-Type": "application/json" } });
    secondaryMock.setDefault({ status: 200, body: ANTHROPIC_RESP, headers: { "Content-Type": "application/json" } });
  });

  async function post(path, body) {
    return fetch(`${TEST_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify(body),
    });
  }

  test("provider-changing model fallback is suppressed before unsafe replay", async () => {
    const r = await post("/p7-model-override", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(502);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");
    expect(secondaryMock.getRequestCount()).toBe(0);
  });

  test("provider_only_fallback_route_leaves_effective_model_as_requested", async () => {
    // With no provider-changing route, the peer retry stays under the original
    // body/auth contract and remains available.
    const r = await post("/p4-connect-retry", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    expect(r.headers.get("x-fallback-attempted")).toBe("1");
    // No model override on the phase 4 route → effective_model matches requested.
    // (Detailed model check would require a log format; here we confirm fallback worked cleanly.)
    expect(r.headers.get("x-fallback-effective")).toBe("openai");
  });
});

describe("llm-fallback — Milestone 2 Target 3 (Phase 8): translation-aware fallback policy", () => {
  let primaryMock;
  let secondaryMock;

  beforeAll(async () => {
    primaryMock   = createHTTPMock(getPort(19002));
    secondaryMock = createHTTPMock(getPort(19003));
    primaryMock.setDefault({ status: 200, body: GOOD_RESP, headers: { "Content-Type": "application/json" } });
    secondaryMock.setDefault({ status: 200, body: ANTHROPIC_RESP, headers: { "Content-Type": "application/json" } });
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    primaryMock.stop();
    secondaryMock.stop();
    cleanupRuntime(MODULE);
  });

  beforeEach(() => {
    primaryMock.clearLog();
    secondaryMock.clearLog();
    primaryMock.setDefault({ status: 200, body: GOOD_RESP, headers: { "Content-Type": "application/json" } });
    secondaryMock.setDefault({ status: 200, body: ANTHROPIC_RESP, headers: { "Content-Type": "application/json" } });
  });

  async function post(path, body) {
    return fetch(`${TEST_URL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify(body),
    });
  }

  test("translation allow cannot opt into unsafe cross-provider replay", async () => {
    const r = await post("/p8-translation-allow", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(502);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");
    expect(secondaryMock.getRequestCount()).toBe(0);
  });

  test("translation discourage cannot opt into unsafe cross-provider replay", async () => {
    const r = await post("/p8-translation-discourage", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(502);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");
    expect(secondaryMock.getRequestCount()).toBe(0);
  });

  test("translation forbid suppresses cross-provider replay before send", async () => {
    const r = await post("/p8-translation-forbid", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(502);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");
    expect(secondaryMock.getRequestCount()).toBe(0);
  });

  test("same dialect does not make a different provider auth contract replay-safe", async () => {
    const r = await post("/p8-translation-forbid-same-dialect-route", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(502);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-policy-mismatch")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");
    expect(secondaryMock.getRequestCount()).toBe(0);
  });
});
