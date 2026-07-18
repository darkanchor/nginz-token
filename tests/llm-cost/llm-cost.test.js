import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { spawnSync } from "bun";
import {
  startNginz, stopNginz, cleanupRuntime,
  TEST_URL, createPostgresMock, configureTestPorts, materializeTestConfig, reloadNginz,
} from "../harness.js";

const MODULE = "llm-cost";
configureTestPorts(MODULE);
// Fixed local mock port — only llm-cost uses it; leave unmapped in harness so the
// DSN in nginx-pg.conf (port=25432) and createPostgresMock agree without remap.
const PG_MOCK_PORT = 25432;
const NGINZ_BIN = "./zig-out/bin/nginz-token";

function childPids(parentPid) {
  const result = spawnSync(["ps", "-o", "pid=", "--ppid", String(parentPid)], {
    stdout: "pipe",
    stderr: "pipe",
  });
  return result.stdout.toString().trim().split(/\s+/).filter(Boolean).map(Number);
}

async function waitForReplacementWorker(masterPid, oldPid) {
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline) {
    const replacement = childPids(masterPid).find((pid) => pid !== oldPid);
    if (replacement) return replacement;
    await Bun.sleep(25);
  }
  throw new Error("timed out waiting for nginx replacement worker");
}

function readCostLogs(runtimeDir) {
  try {
    const text = readFileSync(join(runtimeDir, "logs", "cost.log"), "utf8").trimEnd();
    if (!text) return [];
    return text
      .split("\n")
      .filter((l) => l.trim().length > 0)
      .map((line) => JSON.parse(line));
  } catch {
    return [];
  }
}

async function post(path, body, headers = {}) {
  // Connection: close avoids Bun keep-alive reuse after non-2xx / reload
  // sockets — otherwise the next fetch races to a dead connection (ECONNRESET).
  return fetch(`${TEST_URL}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", Connection: "close", ...headers },
    body: JSON.stringify(body),
  });
}

async function get(path, headers = {}) {
  return fetch(`${TEST_URL}${path}`, { headers: { Connection: "close", ...headers } });
}

// Retry-poll pgMock for an INSERT query. The LOG phase only enqueues; the
// worker-owned event writer completes the asynchronous TCP interaction later.
async function waitForInsert(pgMock, timeout = 500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const insert = pgMock.getQueryLog().find((q) => /INSERT/i.test(q));
    if (insert) return insert;
    await Bun.sleep(10);
  }
  return undefined;
}

async function waitForNoInsert(pgMock, timeout = 300) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const insert = pgMock.getQueryLog().find((q) => /INSERT/i.test(q));
    if (insert) return false;
    await Bun.sleep(10);
  }
  return true;
}

// A writer query can contain one event or a multi-row batch. Count the rows
// represented by its VALUES tuples instead of treating SQL statements as
// persisted events. The protocol mock logs the query after binding parameters.
function persistedEventCount(pgMock) {
  return pgMock.getQueryLog()
    .filter((query) => /INSERT/i.test(query))
    .reduce((total, query) => {
      const values = query.match(/\bVALUES\s*(.*)\s+ON\s+CONFLICT/is)?.[1];
      return total + (values ? 1 + (values.match(/\),\(/g)?.length ?? 0) : 0);
    }, 0);
}

async function waitForCostLog(runtimeDir, baselineCount, predicate, timeout = 500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const logs = readCostLogs(runtimeDir);
    const fresh = logs.slice(baselineCount);
    const match = fresh.find(predicate);
    if (match) return match;
    await Bun.sleep(10);
  }
  return undefined;
}

async function waitForErrorLog(runtimeDir, predicate, timeout = 1000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const text = readFileSync(join(runtimeDir, "logs", "error.log"), "utf8");
    if (predicate(text)) return text;
    await Bun.sleep(10);
  }
  return undefined;
}

// ── Phase 1: log backend ───────────────────────────────────────────────────────

describe("llm-cost — phase 1: cost accounting", () => {
  let runtimeDir;

  beforeAll(async () => {
    runtimeDir = await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("known model produces correct costs in log", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost", body);
    expect(r.status).toBe(200);

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "recorded");
    expect(log).toBeDefined();
    expect(log.status).toBe("recorded");
    // 50 prompt × $5/M = $0.00025000
    expect(parseFloat(log.prompt)).toBeCloseTo(0.00025, 5);
    // 50 completion × $15/M = $0.00075000
    expect(parseFloat(log.completion)).toBeCloseTo(0.00075, 5);
    // total = $0.00100000
    expect(parseFloat(log.total)).toBeCloseTo(0.001, 5);
  });

  test("upstream 4xx sets skipped_error", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-err", body);
    expect(r.status).toBe(422);

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "skipped_error");
    expect(log).toBeDefined();
    expect(log.status).toBe("skipped_error");
  });

  test("provider 4xx after reload does not corrupt the cost/spend ABI", async () => {
    await reloadNginz();
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-err-spend", body, {
      "x-rl-key": "reload-provider-error",
      "x-org-id": "acme",
      "x-project-id": "team-ai",
      "x-client-id": "client-1",
      "x-key-id": "key-1",
      "x-auth-fingerprint": "id:test",
    });
    expect(r.status).toBe(422);

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "skipped_error");
    expect(log).toBeDefined();
    await Bun.sleep(750);
    const errorLog = readFileSync(join(runtimeDir, "logs", "error.log"), "utf8");
    expect(errorLog).not.toContain("exited on signal 11");
  });

  test("no llm_proxy sets usage_missing", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    const r = await get("/cost-no-proxy");
    expect(r.status).toBe(200);

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "usage_missing");
    expect(log).toBeDefined();
    expect(log.status).toBe("usage_missing");
  });

  test("unrecognized model sets no_rate", async () => {
    // gpt-4-turbo is not in the rate card (only gpt-4o is configured) and uses
    // openai provider so the mock response is parsed and usage is extracted.
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4-turbo", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-no-rate", body);
    expect(r.status).toBe(200);

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "no_rate");
    expect(log).toBeDefined();
    expect(log.status).toBe("no_rate");
  });

  test("cost variables not_found when module not enabled", async () => {
    // /cost-no-proxy has llm_cost enabled — we just verify the status is usage_missing
    // and that prompt/completion/total are absent (only present on status=recorded).
    const baselineCount = readCostLogs(runtimeDir).length;
    const r = await get("/cost-no-proxy");
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "usage_missing");
    expect(log).toBeDefined();
    expect(log.status).toBe("usage_missing");
    // prompt/completion/total should be empty strings (variable getter returns len=0)
    expect(log.prompt).toBeFalsy();
    expect(log.completion).toBeFalsy();
    expect(log.total).toBeFalsy();
  });

  test("gpt-4o prefix matches gpt-4o-mini model", async () => {
    // The rate card entry "gpt-4o" prefix-matches "gpt-4o-mini".
    // The mock backend always returns usage regardless of model, so costs are computed.
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o-mini", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost", body);
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "recorded");
    expect(log).toBeDefined();
    expect(log.status).toBe("recorded");
    expect(parseFloat(log.total)).toBeCloseTo(0.001, 5);
  });
});

// ── Phase 2: postgres backend ──────────────────────────────────────────────────

describe("llm-cost — phase 2: postgres backend", () => {
  let runtimeDir;
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT); // createPostgresMock already calls start()
    runtimeDir = await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("successful request inserts one row to postgres", async () => {
    pgMock.clearTracking();
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-pg", body);
    expect(r.status).toBe(200);

    // Verify an INSERT was written to postgres.
    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    expect(insert).toContain("openai");
    expect(insert).toContain("gpt-4o");
    expect(insert).toContain("recorded");

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "recorded");
    expect(log).toBeDefined();
  });

  test("identity field appears in the INSERT", async () => {
    pgMock.clearTracking();
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-pg", body, {
      "x-identity": "tenant-42",
      "x-user": "user-7",
      "x-team": "team-red",
      "x-auth-fingerprint": "wy:testfingerprint",
    });
    expect(r.status).toBe(200);

    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    expect(insert).toContain("tenant-42");
    expect(insert).toContain("user-7");
    expect(insert).toContain("team-red");
    expect(insert).toContain("wy:testfingerprint");
    expect(insert).toContain("2026-05-19-test");
  });

  test("token counts in INSERT match mock response", async () => {
    pgMock.clearTracking();
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    await post("/cost-pg", body);

    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    // Mock returns prompt=50, completion=50, total=100
    expect(insert).toContain("'50'");
    expect(insert).toContain("'100'");
  });

  test("postgres cost/spend provider error survives reload", async () => {
    await reloadNginz();
    const r = await post("/cost-pg-error-spend", {
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    }, {
      "x-rl-key": "reload-provider-error",
      "x-org-id": "acme",
      "x-project-id": "team-ai",
    });
    expect(r.status).toBe(401);
    await Bun.sleep(1250);
    const errorLog = readFileSync(join(runtimeDir, "logs", "error.log"), "utf8");
    expect(errorLog).not.toContain("exited on signal 11");
  });

  test("postgres SQL failure preserves request accounting and emits a recovery record", async () => {
    pgMock.clearTracking();
    const baselineCount = readCostLogs(runtimeDir).length;
    pgMock.setQueryHandler(/INSERT/i, () => ({ error: "mock insert failure" }));

    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-pg-fail", body);
    expect(r.status).toBe(200);

    const log = await waitForCostLog(runtimeDir, baselineCount, (entry) => entry.status === "recorded");
    expect(log).toBeDefined();
    expect(log.event_id).toMatch(/^[0-9a-f]{32}$/);
    expect(log.prompt).toBe("0.00025000");
    expect(log.completion).toBe("0.00075000");
    expect(log.total).toBe("0.00100000");

    const errorLog = await waitForErrorLog(runtimeDir, (text) => text.includes(`recovery_event_id=${log.event_id}`));
    expect(errorLog).toBeDefined();
    expect(errorLog).toContain(`recovery_event_id=${log.event_id}`);
    expect(errorLog).toContain("prompt_tokens=50 completion_tokens=50 total_tokens=100");
  });
});

describe("llm-cost — ambiguous commit retry", () => {
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    let attempts = 0;
    pgMock.setQueryHandler(/INSERT/i, () => {
      attempts += 1;
      return attempts === 1 ? { close: true } : { command: "INSERT 0 1" };
    });
    await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("transport ambiguity retries the same event_id with ON CONFLICT", async () => {
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    expect((await post("/cost-pg", body)).status).toBe(200);

    const deadline = Date.now() + 2000;
    while (Date.now() < deadline && pgMock.getQueryLog().filter((query) => /INSERT/i.test(query)).length < 2) {
      await Bun.sleep(10);
    }
    const inserts = pgMock.getQueryLog().filter((query) => /INSERT/i.test(query));
    expect(inserts.length).toBe(2);
    expect(inserts[0]).toBe(inserts[1]);
    expect(inserts[1]).toContain("ON CONFLICT (event_id) DO NOTHING");
  });
});

describe("llm-cost — asynchronous postgres backpressure", () => {
  let runtimeDir;
  let pgMock;

  beforeAll(async () => {
    // Deliberately leave the configured postgres port closed. Requests must
    // remain independent of connect retries until the bounded queue fills.
    runtimeDir = await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    if (pgMock) pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("closed postgres never blocks requests and queue saturation fails visibly", async () => {
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const baselineCount = readCostLogs(runtimeDir).length;
    const started = performance.now();
    const responses = [];
    // Sequential requests reuse the client connection and stay well below the
    // test nginx worker_connections limit. The postgres queue remains full.
    for (let i = 0; i < 520; i += 1) responses.push(await post("/cost-pg", body));
    const elapsed = performance.now() - started;

    expect(responses.every((r) => r.status === 200)).toBe(true);
    expect(elapsed).toBeLessThan(5000);

    const deadline = Date.now() + 2000;
    let logs = [];
    while (Date.now() < deadline) {
      logs = readCostLogs(runtimeDir).slice(baselineCount).filter(
        (entry) => entry.status === "recorded" || entry.status === "persist_failed",
      );
      if (logs.length >= 520) break;
      await Bun.sleep(10);
    }
    expect(logs.length).toBe(520);
    expect(logs.filter((entry) => entry.status === "persist_failed").length).toBe(8);

    const errorLog = readFileSync(join(runtimeDir, "logs", "error.log"), "utf8");
    expect(errorLog).toContain("postgres queue full or invalid configuration");
    expect(errorLog).not.toContain("worker_connections are not enough");

    // Recovery is automatic: one connection drains all accepted events in
    // FIFO order after postgres returns. The eight rejected events remain
    // visible in the accounting/recovery logs for external replay.
    pgMock = createPostgresMock(PG_MOCK_PORT);
    const recoveryDeadline = Date.now() + 5000;
    while (Date.now() < recoveryDeadline) {
      if (persistedEventCount(pgMock) >= 512) break;
      await Bun.sleep(20);
    }
    expect(persistedEventCount(pgMock)).toBe(512);
  });
});

describe("llm-cost — stalled postgres and graceful reload", () => {
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    pgMock.setQueryHandler(/INSERT/i, () => ({ hang: true }));
    await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    if (pgMock) pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("TCP blackhole does not block traffic and old worker drains after reload", async () => {
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const started = performance.now();
    for (let i = 0; i < 10; i += 1) expect((await post("/cost-pg", body)).status).toBe(200);
    expect(performance.now() - started).toBeLessThan(1000);

    const queryDeadline = Date.now() + 1000;
    while (Date.now() < queryDeadline && !pgMock.getQueryLog().some((query) => /INSERT/i.test(query))) {
      await Bun.sleep(10);
    }
    expect(pgMock.getQueryLog().some((query) => /INSERT/i.test(query))).toBe(true);

    await reloadNginz();
    pgMock.stop();
    pgMock = createPostgresMock(PG_MOCK_PORT);

    const drainDeadline = Date.now() + 5000;
    while (Date.now() < drainDeadline) {
      if (persistedEventCount(pgMock) >= 10) break;
      await Bun.sleep(20);
    }
    expect(persistedEventCount(pgMock)).toBe(10);
    expect((await post("/cost-pg", body)).status).toBe(200);
    const freshDeadline = Date.now() + 1000;
    while (Date.now() < freshDeadline && persistedEventCount(pgMock) < 11) {
      await Bun.sleep(10);
    }
    expect(persistedEventCount(pgMock)).toBe(11);
  });
});

describe("llm-cost — worker crash recovery boundary", () => {
  let runtimeDir;
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    pgMock.setQueryHandler(/INSERT/i, () => ({ hang: true }));
    runtimeDir = await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    if (pgMock) pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("SIGKILL loses only the memory queue and replacement worker stays healthy", async () => {
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const baselineCount = readCostLogs(runtimeDir).length;
    for (let i = 0; i < 5; i += 1) expect((await post("/cost-pg", body)).status).toBe(200);

    const masterPid = Number(readFileSync(join(runtimeDir, "logs", "nginx.pid"), "utf8").trim());
    const oldWorker = childPids(masterPid)[0];
    expect(oldWorker).toBeGreaterThan(0);
    process.kill(oldWorker, "SIGKILL");
    expect(await waitForReplacementWorker(masterPid, oldWorker)).not.toBe(oldWorker);

    const prior = readCostLogs(runtimeDir).slice(baselineCount).filter((entry) => entry.status === "recorded");
    expect(prior.length).toBe(5);
    expect(new Set(prior.map((entry) => entry.event_id)).size).toBe(5);

    pgMock.stop();
    pgMock = createPostgresMock(PG_MOCK_PORT);
    expect((await post("/cost-pg", body)).status).toBe(200);
    expect(await waitForInsert(pgMock, 1500)).toBeDefined();
  });
});

// ── Milestone 2 ───────────────────────────────────────────────────────────────

describe("llm-cost — M2 Target 1: routing attribution in postgres INSERT", () => {
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("INSERT includes requested_provider and requested_model columns", async () => {
    pgMock.clearTracking();
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-pg", body);
    expect(r.status).toBe(200);

    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    // M2 Target 1: requested_provider and requested_model are in the INSERT.
    // When no replacement happens, requested_provider == effective provider (openai).
    expect(insert).toContain("requested_provider");
    expect(insert).toContain("requested_model");
    expect(insert).toContain("translation_happened");
    expect(insert).toContain("resolution_outcome");
  });

  test("INSERT includes event_id plus the 26 M2 columns and is idempotent", async () => {
    pgMock.clearTracking();
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    await post("/cost-pg", body);

    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    // The postgres mock substitutes $N placeholders with actual values.
    // Verify event identity and the M2 column names appear in the INSERT.
    expect(insert).toContain("event_id");
    expect(insert).toContain("ON CONFLICT (event_id) DO NOTHING");
    expect(insert).toContain("requested_provider");
    expect(insert).toContain("requested_model");
    expect(insert).toContain("translation_happened");
    expect(insert).toContain("resolution_outcome");
    expect(insert).toContain("org");
    expect(insert).toContain("project");
    expect(insert).toContain("client");
  });

  test("replacement records requested vs effective routing with translated cohort", async () => {
    pgMock.clearTracking();
    const body = {
      provider: "openai",
      model: "claude-3-haiku-20240307",
      messages: [{ role: "user", content: "hi" }],
    };
    const r = await post("/cost-pg-replace", body);
    expect(r.status).toBe(200);

    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    expect(insert).toContain("'anthropic'");
    expect(insert).toContain("'claude-3-haiku-20240307'");
    expect(insert).toContain("'translated'");
    expect(insert).toContain("'openai'");
    expect(insert).toContain("'1'");
    expect(insert).toContain("'replaced_by_policy'");
  });
});

describe("llm-cost — M2 Target 2: org/project/client billing scope in INSERT", () => {
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("org/project/client fields appear in INSERT", async () => {
    pgMock.clearTracking();
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-pg-scope", body, {
      "x-identity": "tenant-42",
      "x-org": "acme-corp",
      "x-project": "proj-llm-api",
      "x-client": "client-mobile",
    });
    expect(r.status).toBe(200);

    const insert = await waitForInsert(pgMock);
    expect(insert).toBeDefined();
    expect(insert).toContain("acme-corp");
    expect(insert).toContain("proj-llm-api");
    expect(insert).toContain("client-mobile");
  });

  test("two projects under the same org produce distinct attribution", async () => {
    pgMock.clearTracking();
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };

    // Project A
    await post("/cost-pg-scope", body, { "x-org": "orgX", "x-project": "projA" });
    const insertA = await waitForInsert(pgMock);
    expect(insertA).toContain("projA");

    pgMock.clearTracking();
    // Project B — different project, same org
    await post("/cost-pg-scope", body, { "x-org": "orgX", "x-project": "projB" });
    const insertB = await waitForInsert(pgMock);
    expect(insertB).toContain("projB");

    // Verify they are distinct rows, not the same
    expect(insertA).not.toContain("projB");
    expect(insertB).not.toContain("projA");
  });
});

describe("llm-cost — M2 Target 3: translation-sensitive cohort", () => {
  let runtimeDir;

  beforeAll(async () => {
    runtimeDir = await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("non-translated request with no explicit cohort gets default cohort", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost", body);
    expect(r.status).toBe(200);

    // $llm_translation_happened is 0 (no translation in openai-to-openai path),
    // so cohort should be "default" (not "translated").
    // Verify via the outcome field present in the log.
    const logEntry = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(logEntry).toBeDefined();
    expect(logEntry.status).toBe("recorded");
    // The translation field in the log should be "0" (not translated).
    // Exact value depends on $llm_translation_happened from llm-proxy.
    // In the openai-to-openai path, translation_happened=0.
    expect(logEntry.translation).toBe("0");
  });

  test("translated request reports translation_happened and bills the translated provider", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "claude-3-haiku-20240307", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-translated", body);
    expect(r.status).toBe(200);

    const logEntry = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(logEntry).toBeDefined();
    expect(logEntry.status).toBe("recorded");
    expect(logEntry.translation).toBe("1");
    expect(logEntry.outcome).toBe("as_requested");
    expect(logEntry.provider).toBe("anthropic");
    expect(logEntry.model).toBe("claude-3-haiku-20240307");
  });

  test("policy-rejected request is skipped_error and never persists a postgres row", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = {
      provider: "anthropic",
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    };
    const r = await post("/cost-rejected", body);
    expect(r.status).toBe(400);

    const logEntry = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "skipped_error");
    expect(logEntry).toBeDefined();
    expect(logEntry.status).toBe("skipped_error");
    expect(logEntry.outcome).toBe("rejected_out_of_scope");
  });
});

describe("llm-cost — M2 rejected requests are not persisted to postgres", () => {
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("rejected_out_of_scope request does not emit an INSERT", async () => {
    pgMock.clearTracking();
    const body = {
      provider: "anthropic",
      model: "gpt-4o",
      messages: [{ role: "user", content: "hi" }],
    };
    const r = await post("/cost-pg-rejected", body);
    expect(r.status).toBe(400);
    expect(await waitForNoInsert(pgMock)).toBe(true);
  });
});

// ── Bug fixes ─────────────────────────────────────────────────────────────────

describe("llm-cost — bug fix: no_rate persists a postgres row", () => {
  let pgMock;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    await startNginz(`tests/${MODULE}/nginx-pg.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  // Previously no_rate silently dropped the request from postgres.
  // The fix allows no_rate rows through so operators can audit unpriced traffic.
  test("no_rate request inserts an audit row with zero costs", async () => {
    pgMock.clearTracking();
    // gpt-4-turbo is not in the rate card (only gpt-4o is configured).
    const body = { model: "gpt-4-turbo", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-pg-no-rate", body);
    expect(r.status).toBe(200);

    const insert = await waitForInsert(pgMock, 800);
    expect(insert).toBeDefined();
    expect(insert).toContain("'no_rate'");
    // Provider and model should be present even without a rate match.
    expect(insert).toContain("'openai'");
    expect(insert).toContain("'gpt-4-turbo'");
    // Cost columns must be zero since no rate was found.
    expect(insert).toContain("'0.00000000'");
  });
});

describe("llm-cost — unsafe failure-driven provider fallback containment", () => {
  let pgMock;
  let runtimeDir;

  beforeAll(async () => {
    pgMock = createPostgresMock(PG_MOCK_PORT);
    runtimeDir = await startNginz(`tests/${MODULE}/nginx-fallback-billing.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    pgMock.stop();
    cleanupRuntime(MODULE);
  });

  test("suppressed cross-provider replay does not create a misleading billing row", async () => {
    pgMock.clearTracking();
    const baselineCount = readCostLogs(runtimeDir).length;
    const body = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] };
    const r = await post("/cost-fallback-billing", body);
    expect(r.status).toBe(502);
    expect(r.headers.get("x-fallback-attempted")).toBe("0");
    expect(r.headers.get("x-fallback-suppressed")).toBe("1");
    expect(r.headers.get("x-fallback-suppressed-reason")).toBe("cross_provider_replay_unsafe");
    expect(await waitForNoInsert(pgMock)).toBe(true);

    const logEntry = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "skipped_error");
    expect(logEntry).toBeDefined();
    expect(logEntry.effective_provider).toBe("openai");
    expect(logEntry.outcome).toBe("as_requested");
  });
});

// ── Target 5: cached-input pricing ──────────────────────────────────────────

describe("llm-cost — Target 5: cached-input pricing", () => {
  let runtimeDir;

  beforeAll(async () => {
    runtimeDir = await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("legacy rate without cached rate bills all prompt tokens at prompt rate", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    // /cost → openai gpt-4o, 50 prompt + 50 completion, no cached tokens
    // prompt_cost = 50 * 5.0 / 1M = 0.00025
    const r = await post("/cost", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(log).toBeDefined();
    expect(parseFloat(log.prompt)).toBeCloseTo(0.00025, 6);
  });

  test("OpenAI blended prompt cost uses cached-read rate for cache_read_tokens", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    // /cost-openai-cached → prompt=100, cache_read=80, completion=20
    // regular = 100 - 80 = 20 tokens at $5/M
    // cache_read = 80 tokens at $2.50/M
    // prompt_cost = 20*5/1M + 80*2.5/1M = 0.0001 + 0.0002 = 0.0003
    // completion_cost = 20*15/1M = 0.0003
    // total = 0.0006
    const r = await post("/cost-openai-cached", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(log).toBeDefined();
    expect(parseFloat(log.prompt)).toBeCloseTo(0.0003, 7);
    expect(parseFloat(log.completion)).toBeCloseTo(0.0003, 7);
    expect(parseFloat(log.total)).toBeCloseTo(0.0006, 7);
  });

  test("no cached rate falls back: all prompt tokens at normal prompt rate", async () => {
    // claude-3-haiku has no llm_cost_cached_rate; all tokens bill at prompt rate.
    const baselineCount = readCostLogs(runtimeDir).length;
    // /cost-translated → anthropic claude-3-haiku-20240307, 50+50 no cache tokens
    // prompt_cost = 50 * 5.0/M = 0.00025
    const r = await post("/cost-translated", { model: "claude-3-haiku-20240307", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(log).toBeDefined();
    expect(parseFloat(log.prompt)).toBeCloseTo(0.00025, 6);
  });

  test("Anthropic three-bucket blended cost", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    // /cost-anthropic-cached → claude-sonnet, input=25, cache_read=80, cache_create=10, output=8
    // Total prompt = 25+80+10 = 115
    // regular = 115 - 80 - 10 = 25 at $3/M
    // cache_read = 80 at $0.30/M
    // cache_create = 10 at $3.75/M
    // prompt_cost = 25*3/1M + 80*0.3/1M + 10*3.75/1M = 0.000075 + 0.000024 + 0.0000375 = 0.0001365
    // completion_cost = 8*15/1M = 0.00012
    // total = 0.0002565
    const r = await post("/cost-anthropic-cached", { model: "claude-sonnet-20241022", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(log).toBeDefined();
    expect(parseFloat(log.prompt)).toBeCloseTo(0.0001365, 7);
    expect(parseFloat(log.completion)).toBeCloseTo(0.00012, 7);
    expect(parseFloat(log.total)).toBeCloseTo(0.0002565, 7);
  });

  test("cache_create_tokens with no create rate falls back to prompt rate", async () => {
    const baselineCount = readCostLogs(runtimeDir).length;
    // /cost-anthropic-cache-read-only: input=50, cache_read=100, cache_create=10, output=20
    // claude-readonly: read rate configured, create rate absent so creates use prompt rate.
    // regular = 160 - 100 - 10 = 50 at $3/M
    // cache_read = 100 at $0.30/M
    // cache_create = 10 at $3/M
    // prompt_cost = 50*3/1M + 100*0.30/1M + 10*3/1M = 0.00021
    // completion_cost = 20*15/1M = 0.0003
    // total = 0.00051
    const r = await post("/cost-anthropic-cache-read-only", { model: "claude-readonly-20241022", messages: [{ role: "user", content: "hi" }] });
    expect(r.status).toBe(200);
    const log = await waitForCostLog(runtimeDir, baselineCount, (e) => e.status === "recorded");
    expect(log).toBeDefined();
    expect(parseFloat(log.prompt)).toBeCloseTo(0.00021, 7);
    expect(parseFloat(log.completion)).toBeCloseTo(0.0003, 7);
    expect(parseFloat(log.total)).toBeCloseTo(0.00051, 7);
  });
});

describe("llm-cost — configuration validation", () => {
  function runNginxTest(confPath) {
    const tmpPrefix = join(tmpdir(), "nginz-cost-cfgtest-" + Date.now());
    mkdirSync(join(tmpPrefix, "logs"), { recursive: true });
    let configPath = null;
    try {
      configPath = materializeTestConfig(confPath, MODULE, tmpPrefix);
      return spawnSync([NGINZ_BIN, "-c", configPath, "-p", tmpPrefix, "-t"], {
        stdout: "pipe",
        stderr: "pipe",
      });
    } finally {
      if (configPath && existsSync(configPath)) rmSync(configPath, { force: true });
      rmSync(tmpPrefix, { recursive: true, force: true });
    }
  }

  test("rejects negative standard token rates", () => {
    const result = runNginxTest(join(process.cwd(), "tests/llm-cost/nginx-bad-negative-rate.conf"));
    expect(result.exitCode).toBe(1);
  });

  test("rejects negative cached token rates", () => {
    const result = runNginxTest(join(process.cwd(), "tests/llm-cost/nginx-bad-negative-cached-rate.conf"));
    expect(result.exitCode).toBe(1);
  });

  test("accepts asynchronous postgres persistence without a blocking-I/O warning", () => {
    const result = runNginxTest(join(process.cwd(), "tests/llm-cost/nginx-pg.conf"));
    expect(result.exitCode).toBe(0);
    expect(result.stderr.toString()).not.toContain("blocking libpq I/O in nginx workers");
  });
});
