import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  reloadNginz,
  cleanupRuntime,
  TEST_URL,
  configureTestPorts,
  materializeTestConfig,
} from "../harness.js";
import { spawnSync } from "bun";
import { mkdirSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

const MODULE = "llm-metrics";
configureTestPorts(MODULE);
const NGINZ_BIN = "./zig-out/bin/nginz-token";

async function get(path) {
  return fetch(`${TEST_URL}${path}`);
}

async function post(path, bodyObj) {
  return fetch(`${TEST_URL}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(bodyObj),
  });
}

async function postWithHeaders(path, bodyObj, extraHeaders) {
  return fetch(`${TEST_URL}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...extraHeaders },
    body: JSON.stringify(bodyObj),
  });
}

async function scrape() {
  const r = await fetch(`${TEST_URL}/metrics`);
  expect(r.status).toBe(200);
  return r.text();
}

// Parse a specific counter value from prometheus text output.
// Handles lines like: metric_name{provider="openai"} 42
function parseCounter(text, metric, provider) {
  const re = new RegExp(
    String.raw`${metric}\{provider="${provider}"\}\s+(\d+)`,
    "m"
  );
  const m = text.match(re);
  return m ? parseInt(m[1], 10) : null;
}

function parseAuthStatusCounter(text, metric, authStatus) {
  const re = new RegExp(
    String.raw`${metric}\{auth_status="${authStatus}"\}\s+(\d+)`,
    "m"
  );
  const m = text.match(re);
  return m ? parseInt(m[1], 10) : null;
}

function parseModelCounter(text, metric, model) {
  const escaped = model.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(
    String.raw`${metric}\{model="${escaped}"\}\s+(\d+)`,
    "m"
  );
  const m = text.match(re);
  return m ? parseInt(m[1], 10) : null;
}

function parseTenantCounter(text, metric, tenant) {
  const escaped = tenant.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(
    String.raw`${metric}\{tenant="${escaped}"\}\s+(\d+)`,
    "m"
  );
  const m = text.match(re);
  return m ? parseInt(m[1], 10) : null;
}

function parseOutcomeCounter(text, metric, outcome) {
  const re = new RegExp(
    String.raw`${metric}\{resolution_outcome="${outcome}"\}\s+(\d+)`,
    "m"
  );
  const m = text.match(re);
  return m ? parseInt(m[1], 10) : null;
}

function runNginxTest(confPath) {
  const tmpPrefix = join(tmpdir(), `nginz-llm-metrics-${Date.now()}-${Math.random().toString(16).slice(2)}`);
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

describe("llm-metrics — phase 1: shared metadata counters", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("export endpoint returns 200 with prometheus content-type", async () => {
    const r = await fetch(`${TEST_URL}/metrics`);
    expect(r.status).toBe(200);
    const ct = r.headers.get("content-type") ?? "";
    expect(ct).toContain("text/plain");
  });

  test("export endpoint returns all expected metric families", async () => {
    const text = await scrape();
    expect(text).toContain("llm_requests_total");
    expect(text).toContain("llm_requests_parsed_total");
    expect(text).toContain("llm_requests_fallback_total");
    expect(text).toContain("llm_requests_streaming_total");
    expect(text).toContain("llm_requests_error_provider_total");
    expect(text).toContain("llm_requests_error_gateway_total");
    expect(text).toContain("# TYPE llm_requests_total counter");
    expect(text).toContain("# TYPE llm_request_duration_milliseconds histogram");
    expect(text).not.toContain("# TYPE llm_request_duration_milliseconds_sum counter");
    expect(text).not.toContain("# TYPE llm_request_duration_milliseconds_count counter");
  });

  test("all four provider labels are present in output", async () => {
    const text = await scrape();
    for (const prov of ["openai", "anthropic", "other", "total"]) {
      expect(text).toContain(`provider="${prov}"`);
    }
  });

  test("OpenAI parsed request increments openai total and parsed counters", async () => {
    const before = await scrape();
    const beforeTotal = parseCounter(before, "llm_requests_total", "openai") ?? 0;
    const beforeParsed = parseCounter(before, "llm_requests_parsed_total", "openai") ?? 0;

    await post("/openai", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    const afterTotal = parseCounter(after, "llm_requests_total", "openai") ?? 0;
    const afterParsed = parseCounter(after, "llm_requests_parsed_total", "openai") ?? 0;

    expect(afterTotal).toBe(beforeTotal + 1);
    expect(afterParsed).toBe(beforeParsed + 1);
  });

  test("Anthropic parsed request increments anthropic counter, not openai", async () => {
    const before = await scrape();
    const beforeAnthropic = parseCounter(before, "llm_requests_total", "anthropic") ?? 0;
    const beforeOpenai = parseCounter(before, "llm_requests_total", "openai") ?? 0;

    await post("/anthropic", { model: "claude-3-5-sonnet-20241022", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    expect(parseCounter(after, "llm_requests_total", "anthropic")).toBe(beforeAnthropic + 1);
    expect(parseCounter(after, "llm_requests_total", "openai")).toBe(beforeOpenai);
  });

  test("plain (no llm-proxy) request increments other+total counters with fallback", async () => {
    const before = await scrape();
    const beforeOther = parseCounter(before, "llm_requests_total", "other") ?? 0;
    const beforeTotal = parseCounter(before, "llm_requests_total", "total") ?? 0;
    const beforeFallback = parseCounter(before, "llm_requests_fallback_total", "other") ?? 0;

    await get("/plain");

    const after = await scrape();
    expect(parseCounter(after, "llm_requests_total", "other")).toBe(beforeOther + 1);
    expect(parseCounter(after, "llm_requests_total", "total")).toBe(beforeTotal + 1);
    expect(parseCounter(after, "llm_requests_fallback_total", "other")).toBe(beforeFallback + 1);
  });

  test("provider error increments error_provider counter", async () => {
    const before = await scrape();
    const beforeErrProv = parseCounter(before, "llm_requests_error_provider_total", "openai") ?? 0;

    await post("/provider-error", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    expect(parseCounter(after, "llm_requests_error_provider_total", "openai")).toBe(beforeErrProv + 1);
  });

  test("gateway error (502) increments error_gateway counter, not error_provider", async () => {
    const before = await scrape();
    const beforeErrGw = parseCounter(before, "llm_requests_error_gateway_total", "other") ?? 0;
    const beforeErrProv = parseCounter(before, "llm_requests_error_provider_total", "other") ?? 0;

    await get("/gateway-error");

    const after = await scrape();
    expect(parseCounter(after, "llm_requests_error_gateway_total", "other")).toBe(beforeErrGw + 1);
    expect(parseCounter(after, "llm_requests_error_provider_total", "other")).toBe(beforeErrProv);
  });

  test("total counter is sum of all providers", async () => {
    const text = await scrape();
    const openai = parseCounter(text, "llm_requests_total", "openai") ?? 0;
    const anthropic = parseCounter(text, "llm_requests_total", "anthropic") ?? 0;
    const other = parseCounter(text, "llm_requests_total", "other") ?? 0;
    const total = parseCounter(text, "llm_requests_total", "total") ?? 0;
    expect(total).toBe(openai + anthropic + other);
  });

  test("graceful reload preserves every request during worker-generation overlap", async () => {
    const before = parseCounter(await scrape(), "llm_requests_total", "total");
    const requestCount = 160;
    const requests = Array.from({ length: requestCount }, async (_, i) => {
      if (i % 8 === 0) await Bun.sleep(5);
      const r = await get("/plain");
      expect(r.status).toBe(200);
      await r.arrayBuffer();
    });

    await Bun.sleep(10);
    await reloadNginz();
    await Promise.all(requests);

    const after = parseCounter(await scrape(), "llm_requests_total", "total");
    expect(after - before).toBe(requestCount);
  });

  test("first mutex-taking LOG request and scrape survive graceful reload", async () => {
    const tenant = `reload-${Date.now()}`;
    await reloadNginz();

    // Tenant accounting takes the slab mutex in LOG phase, matching the
    // crashing first-request path from the reload regression.
    const response = await postWithHeaders(
      "/with-tenant",
      { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
      { "x-tenant": tenant },
    );
    expect(response.status).toBe(200);
    await response.arrayBuffer();

    const text = await scrape();
    expect(parseTenantCounter(text, "llm_requests_tenant_total", tenant)).toBe(1);
  });
});

describe("llm-metrics — phase 2: latency and usage accounting", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("duration_count increments per request", async () => {
    const before = await scrape();
    const beforeCount = parseCounter(before, "llm_request_duration_milliseconds_count", "openai") ?? 0;

    await post("/openai", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    expect(parseCounter(after, "llm_request_duration_milliseconds_count", "openai")).toBe(beforeCount + 1);
  });

  test("duration_sum increases after request", async () => {
    const before = await scrape();
    const beforeSum = parseCounter(before, "llm_request_duration_milliseconds_sum", "openai") ?? 0;

    await post("/openai", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    const afterSum = parseCounter(after, "llm_request_duration_milliseconds_sum", "openai") ?? 0;
    expect(afterSum).toBeGreaterThanOrEqual(beforeSum);
  });

  test("latency histogram +Inf bucket equals duration_count", async () => {
    const text = await scrape();
    const count = parseCounter(text, "llm_request_duration_milliseconds_count", "openai") ?? 0;

    // Parse +Inf bucket
    const re = /llm_request_duration_milliseconds_bucket\{le="\+Inf",provider="openai"\}\s+(\d+)/;
    const m = text.match(re);
    const infBucket = m ? parseInt(m[1], 10) : null;
    expect(infBucket).toBe(count);
  });

  test("usage_extracted increments when llm-proxy extracts usage", async () => {
    const before = await scrape();
    const beforeExtracted = parseCounter(before, "llm_usage_extracted_total", "openai") ?? 0;

    await post("/openai", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    expect(parseCounter(after, "llm_usage_extracted_total", "openai")).toBe(beforeExtracted + 1);
  });

  test("token counters accumulate with emit_usage on", async () => {
    const before = await scrape();
    const beforeTotal = parseCounter(before, "llm_total_tokens_total", "openai") ?? 0;

    // Mock returns total_tokens=15 per request.
    await post("/openai", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    const afterTotal = parseCounter(after, "llm_total_tokens_total", "openai") ?? 0;
    expect(afterTotal).toBeGreaterThan(beforeTotal);
  });

  test("error responses do not increment usage_extracted", async () => {
    const before = await scrape();
    const beforeExtracted = parseCounter(before, "llm_usage_extracted_total", "openai") ?? 0;
    const beforeMissing = parseCounter(before, "llm_usage_missing_total", "openai") ?? 0;

    await post("/provider-error", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });

    const after = await scrape();
    // Provider error response has no usage field, so usage_missing should increment.
    const afterExtracted = parseCounter(after, "llm_usage_extracted_total", "openai") ?? 0;
    const afterMissing = parseCounter(after, "llm_usage_missing_total", "openai") ?? 0;
    expect(afterExtracted).toBe(beforeExtracted); // no usage extracted from error
    expect(afterMissing).toBe(beforeMissing + 1); // counted as missing
  });

  test("prometheus histogram buckets are cumulative and monotone", async () => {
    const text = await scrape();
    const bounds = ["100", "500", "2000", "10000", "+Inf"];
    let prev = -1;
    for (const le of bounds) {
      const re = new RegExp(
        String.raw`llm_request_duration_milliseconds_bucket\{le="${le.replace("+", "\\+")}",provider="total"\}\s+(\d+)`,
        "m"
      );
      const m = text.match(re);
      expect(m).not.toBeNull();
      const val = parseInt(m[1], 10);
      if (prev >= 0) expect(val).toBeGreaterThanOrEqual(prev);
      prev = val;
    }
  });
});

describe("llm-metrics hardening and config validation", () => {
  test("metrics export rejects SSI subrequests: embedded content is empty", async () => {
    // The export handler rejects all subrequests (r != r.main) to prevent
    // the handler from acting as an allow-gate in any subrequest context.
    // SSI includes /metrics as a subrequest → handler returns 403 → SSI
    // embeds the (empty) 403 body, not the metrics text. The parent page
    // still succeeds (SSI ignores subrequest errors in default mode).
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
    try {
      const res = await get("/metrics-ssi-parent");
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).not.toContain("llm_requests_total");
    } finally {
      await stopNginz();
      cleanupRuntime(MODULE);
    }
  });

  test("metrics export rejects auth_request subrequest to prevent allow-gate bypass", async () => {
    // auth_request uses an in-memory subrequest. The export handler detects
    // subrequest_in_memory and returns 403 so nginx denies the main request,
    // preventing the metrics endpoint from silently acting as an access allow-gate.
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
    try {
      const res = await get("/metrics-auth-parent");
      expect(res.status).toBe(403);
    } finally {
      await stopNginz();
      cleanupRuntime(MODULE);
    }
  });

  test("metrics export can serve as a mirror target without breaking the parent response", async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
    try {
      const res = await get("/metrics-mirror-parent");
      expect(res.status).toBe(200);
      expect(await res.text()).toContain('"id":"chatcmpl-1"');
    } finally {
      await stopNginz();
      cleanupRuntime(MODULE);
    }
  });

  test("child location can explicitly disable emit_usage inherited from parent", async () => {
    await startNginz(`tests/${MODULE}/nginx-inherit-off.conf`, MODULE);
    try {
      const before = await scrape();
      const beforeUsage = parseCounter(before, "llm_usage_extracted_total", "openai") ?? 0;
      const beforeTokens = parseCounter(before, "llm_total_tokens_total", "openai") ?? 0;

      const res = await post("/child", {
        model: "gpt-4o",
        messages: [{ role: "user", content: "hi" }],
      });
      expect(res.status).toBe(200);

      const after = await scrape();
      expect(parseCounter(after, "llm_usage_extracted_total", "openai")).toBe(beforeUsage + 1);
      expect(parseCounter(after, "llm_total_tokens_total", "openai")).toBe(beforeTokens);
    } finally {
      await stopNginz();
      cleanupRuntime(MODULE);
    }
  });

  test("duplicate llm_metrics_zone directives are rejected", () => {
    const result = runNginxTest(join(process.cwd(), "tests/llm-metrics/nginx-duplicate-zone.conf"));
    expect(result.exitCode).toBe(1);
    const output = (result.stdout?.toString() ?? "") + (result.stderr?.toString() ?? "");
    expect(output).toContain("llm_metrics_zone is duplicate");
  });

  test("invalid llm_metrics_zone sizes are rejected", () => {
    const result = runNginxTest(join(process.cwd(), "tests/llm-metrics/nginx-bad-zone-size.conf"));
    expect(result.exitCode).toBe(1);
    const output = (result.stdout?.toString() ?? "") + (result.stderr?.toString() ?? "");
    expect(output).toContain("llm_metrics_zone: invalid size");
  });
});

describe("llm-metrics auth status labels", () => {
  beforeAll(async () => {
    process.env.LLMMETRICS_TEST_OPENAI_KEY = "sk-llm-metrics-openai-test";
    await startNginz(`tests/${MODULE}/nginx-auth-status.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    delete process.env.LLMMETRICS_TEST_OPENAI_KEY;
  });

  test("exports auth-status metric families", async () => {
    const text = await scrape();
    expect(text).toContain("llm_requests_auth_status_total");
    expect(text).toContain("llm_requests_error_provider_auth_status_total");
    expect(text).toContain("llm_requests_error_gateway_auth_status_total");
  });

  test("counts resolved auth outcomes", async () => {
    const before = await scrape();
    const beforeResolved = parseAuthStatusCounter(before, "llm_requests_auth_status_total", "resolved") ?? 0;

    const res = await post("/auth-resolved", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseAuthStatusCounter(after, "llm_requests_auth_status_total", "resolved")).toBe(beforeResolved + 1);
  });

  test("counts missing_provider auth outcomes", async () => {
    const before = await scrape();
    const beforeVal = parseAuthStatusCounter(before, "llm_requests_auth_status_total", "missing_provider") ?? 0;

    const res = await post("/auth-missing-provider", { ok: true });
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseAuthStatusCounter(after, "llm_requests_auth_status_total", "missing_provider")).toBe(beforeVal + 1);
  });

  test("counts missing_credential auth outcomes", async () => {
    const before = await scrape();
    const beforeVal = parseAuthStatusCounter(before, "llm_requests_auth_status_total", "missing_credential") ?? 0;

    const res = await post("/auth-missing-credential", { ok: true });
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseAuthStatusCounter(after, "llm_requests_auth_status_total", "missing_credential")).toBe(beforeVal + 1);
  });

  test("counts missing_secret auth outcomes", async () => {
    const before = await scrape();
    const beforeVal = parseAuthStatusCounter(before, "llm_requests_auth_status_total", "missing_secret") ?? 0;

    const res = await post("/auth-missing-secret", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseAuthStatusCounter(after, "llm_requests_auth_status_total", "missing_secret")).toBe(beforeVal + 1);
  });

  test("provider error is attributed to the resolved auth status bucket", async () => {
    const before = await scrape();
    const beforeVal = parseAuthStatusCounter(before, "llm_requests_error_provider_auth_status_total", "resolved") ?? 0;

    const res = await post("/auth-provider-error", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(res.status).toBe(422);

    const after = await scrape();
    expect(parseAuthStatusCounter(after, "llm_requests_error_provider_auth_status_total", "resolved")).toBe(beforeVal + 1);
  });

  test("requests from locations without auth-status labeling do not populate auth-status counters", async () => {
    const before = await scrape();
    const beforeOther = parseCounter(before, "llm_requests_total", "other") ?? 0;
    const beforeResolved = parseAuthStatusCounter(before, "llm_requests_auth_status_total", "resolved") ?? 0;
    const beforeMissingProvider = parseAuthStatusCounter(before, "llm_requests_auth_status_total", "missing_provider") ?? 0;

    const res = await get("/no-auth");
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseCounter(after, "llm_requests_total", "other")).toBe(beforeOther + 1);
    expect(parseAuthStatusCounter(after, "llm_requests_auth_status_total", "resolved")).toBe(beforeResolved);
    expect(parseAuthStatusCounter(after, "llm_requests_auth_status_total", "missing_provider")).toBe(beforeMissingProvider);
  });
});

describe("llm-metrics model labels", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-model-label.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("exports model-labeled metric families", async () => {
    const text = await scrape();
    expect(text).toContain("llm_requests_model_total");
    expect(text).toContain("llm_requests_error_provider_model_total");
    expect(text).toContain("llm_requests_error_gateway_model_total");
  });

  test("counts requests under the normalized model label", async () => {
    const before = await scrape();
    const beforeVal = parseModelCounter(before, "llm_requests_model_total", "gpt-4o") ?? 0;

    const res = await post("/model-on", {
      model: "GPT-4O",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseModelCounter(after, "llm_requests_model_total", "gpt-4o")).toBe(beforeVal + 1);
  });

  test("provider error is attributed to the matching model label", async () => {
    const before = await scrape();
    const beforeVal = parseModelCounter(before, "llm_requests_error_provider_model_total", "gpt-4o") ?? 0;

    const res = await post("/model-error", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(res.status).toBe(422);

    const after = await scrape();
    expect(parseModelCounter(after, "llm_requests_error_provider_model_total", "gpt-4o")).toBe(beforeVal + 1);
  });

  test("locations without model labeling do not populate model-labeled counters", async () => {
    const before = await scrape();
    const beforeProvider = parseCounter(before, "llm_requests_total", "openai") ?? 0;
    const beforeModel = parseModelCounter(before, "llm_requests_model_total", "gpt-4o") ?? 0;

    const res = await post("/model-off", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(res.status).toBe(200);

    const after = await scrape();
    expect(parseCounter(after, "llm_requests_total", "openai")).toBe(beforeProvider + 1);
    expect(parseModelCounter(after, "llm_requests_model_total", "gpt-4o")).toBe(beforeModel);
  });

  test("table overflow is deterministic and counted in the overflow bucket", async () => {
    const before = await scrape();
    const beforeOverflow = parseModelCounter(before, "llm_requests_model_total", "_overflow") ?? 0;

    for (let i = 0; i < 40; i++) {
      const res = await post("/model-on", {
        model: `test-model-${i}`,
        messages: [{ role: "user", content: "hi" }],
      });
      expect(res.status).toBe(200);
    }

    const after = await scrape();
    const afterOverflow = parseModelCounter(after, "llm_requests_model_total", "_overflow") ?? 0;
    expect(afterOverflow).toBeGreaterThan(beforeOverflow);
  });
});

// ── Milestone 2: Target 1 — requested/effective routing and translation visibility ─

describe("llm-metrics — Milestone 2 Target 1: translation/replacement/outcome counters", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("translation_total counter increments when cross-dialect translation occurs", async () => {
    const before = await scrape();
    const beforeTotal = parseCounter(before, "llm_requests_translation_total", "total") ?? 0;

    // /openai-to-anthropic: model "claude-3-sonnet" → anthropic endpoint.
    // requested_dialect=openai, effective_dialect=anthropic → translation_happened=1.
    const r = await post("/openai-to-anthropic", {
      model: "claude-3-sonnet-20240229",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterTotal = parseCounter(after, "llm_requests_translation_total", "total") ?? 0;
    expect(afterTotal).toBe(beforeTotal + 1);
  });

  test("native_path_request_does_not_increment_translation_counter", async () => {
    const before = await scrape();
    const beforeTotal = parseCounter(before, "llm_requests_translation_total", "total") ?? 0;

    // /openai: model "gpt-4o" → openai endpoint. requested=openai, effective=openai → no translation.
    const r = await post("/openai", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterTotal = parseCounter(after, "llm_requests_translation_total", "total") ?? 0;
    expect(afterTotal).toBe(beforeTotal); // unchanged
  });

  test("replacement_total counter increments when pre-send replacement occurs", async () => {
    const before = await scrape();
    const beforeTotal = parseCounter(before, "llm_requests_replacement_total", "total") ?? 0;

    // /with-replacement: llm_fallback_replace openai anthropic → replacement_happened=1.
    const r = await post("/with-replacement", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterTotal = parseCounter(after, "llm_requests_replacement_total", "total") ?? 0;
    expect(afterTotal).toBe(beforeTotal + 1);
  });

  test("non_replacement_request_does_not_increment_replacement_counter", async () => {
    const before = await scrape();
    const beforeTotal = parseCounter(before, "llm_requests_replacement_total", "total") ?? 0;

    const r = await post("/openai", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterTotal = parseCounter(after, "llm_requests_replacement_total", "total") ?? 0;
    expect(afterTotal).toBe(beforeTotal); // unchanged
  });

  test("resolution_outcome_total counter tracks as_requested for normal requests", async () => {
    const before = await scrape();
    const beforeCount = parseOutcomeCounter(before, "llm_requests_resolution_outcome_total", "as_requested") ?? 0;

    // /openai-to-anthropic has label_resolution_outcome on; successful parse → as_requested.
    const r = await post("/openai-to-anthropic", {
      model: "claude-3-sonnet-20240229",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterCount = parseOutcomeCounter(after, "llm_requests_resolution_outcome_total", "as_requested") ?? 0;
    expect(afterCount).toBe(beforeCount + 1);
  });

  test("resolution_outcome_total counter tracks replaced_by_policy for replacement requests", async () => {
    const before = await scrape();
    const beforeCount = parseOutcomeCounter(before, "llm_requests_resolution_outcome_total", "replaced_by_policy") ?? 0;

    // /with-replacement: replacement fires → resolution_outcome=replaced_by_policy.
    const r = await post("/with-replacement", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterCount = parseOutcomeCounter(after, "llm_requests_resolution_outcome_total", "replaced_by_policy") ?? 0;
    expect(afterCount).toBe(beforeCount + 1);
  });

  test("translation_and_replacement_counters_are_present_in_prometheus_export", async () => {
    const text = await scrape();
    // New metric families must appear in the export.
    expect(text).toContain("llm_requests_translation_total");
    expect(text).toContain("llm_requests_replacement_total");
    expect(text).toContain("llm_requests_resolution_outcome_total");
    // Cardinality: one line per provider (4 values).
    expect(text).toContain('llm_requests_translation_total{provider="total"}');
    // Resolution outcome: one line per outcome (6 values).
    expect(text).toContain('llm_requests_resolution_outcome_total{resolution_outcome="as_requested"}');
    expect(text).toContain('llm_requests_resolution_outcome_total{resolution_outcome="replaced_by_policy"}');
    expect(text).toContain('llm_requests_resolution_outcome_total{resolution_outcome="rejected_out_of_scope"}');
  });
});

// ── Milestone 2: Target 2 — org/project/client observability surfaces ──────

describe("llm-metrics — Milestone 2 Target 2: per-tenant counters", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("tenant counter increments for labeled requests", async () => {
    const before = await scrape();
    const beforeCount = parseTenantCounter(before, "llm_requests_tenant_total", "acme-corp") ?? 0;

    const r = await postWithHeaders("/with-tenant", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    }, { "X-Tenant": "acme-corp" });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterCount = parseTenantCounter(after, "llm_requests_tenant_total", "acme-corp") ?? 0;
    expect(afterCount).toBe(beforeCount + 1);
  });

  test("multiple tenant keys are tracked separately", async () => {
    const before = await scrape();
    const beforeA = parseTenantCounter(before, "llm_requests_tenant_total", "tenant-a") ?? 0;
    const beforeB = parseTenantCounter(before, "llm_requests_tenant_total", "tenant-b") ?? 0;

    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    await postWithHeaders("/with-tenant", body, { "X-Tenant": "tenant-a" });
    await postWithHeaders("/with-tenant", body, { "X-Tenant": "tenant-b" });
    await postWithHeaders("/with-tenant", body, { "X-Tenant": "tenant-a" });

    const after = await scrape();
    const afterA = parseTenantCounter(after, "llm_requests_tenant_total", "tenant-a") ?? 0;
    const afterB = parseTenantCounter(after, "llm_requests_tenant_total", "tenant-b") ?? 0;
    expect(afterA).toBe(beforeA + 2);
    expect(afterB).toBe(beforeB + 1);
  });

  test("tenant label is disabled by default for non-labeled locations", async () => {
    const before = await scrape();
    // /openai has no llm_metrics_label_tenant — sending to it must not create new tenant entries.
    const r = await post("/openai", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    const after = await scrape();
    // The unlabeled location must not introduce a tenant entry.
    expect(after).not.toContain('llm_requests_tenant_total{tenant="unlabeled-sentinel"}');
    // Total tenant entry count must be unchanged (same set of keys).
    const countBefore = (before.match(/llm_requests_tenant_total\{tenant=/g) || []).length;
    const countAfter = (after.match(/llm_requests_tenant_total\{tenant=/g) || []).length;
    expect(countAfter).toBe(countBefore);
  });

  test("oversized tenant key goes to overflow bucket", async () => {
    const before = await scrape();
    const beforeOverflow = parseTenantCounter(before, "llm_requests_tenant_total", "_overflow") ?? 0;

    const longTenant = "x".repeat(100); // > TENANT_LABEL_MAX_LEN (63)
    const r = await postWithHeaders("/with-tenant", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    }, { "X-Tenant": longTenant });
    expect(r.status).toBe(200);

    const after = await scrape();
    const afterOverflow = parseTenantCounter(after, "llm_requests_tenant_total", "_overflow") ?? 0;
    expect(afterOverflow).toBe(beforeOverflow + 1);
  });

  test("tenant metric families are present in prometheus export", async () => {
    const text = await scrape();
    expect(text).toContain("llm_requests_tenant_total");
    expect(text).toContain("llm_requests_error_provider_tenant_total");
    expect(text).toContain("llm_requests_error_gateway_tenant_total");
  });
});
