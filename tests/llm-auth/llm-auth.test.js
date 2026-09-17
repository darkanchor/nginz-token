import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { mkdirSync, rmSync, readFileSync } from "fs";
import { join } from "path";
import { spawnSync } from "bun";
import { createHash } from "node:crypto";
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

const MODULE = "llm-auth";
configureTestPorts(MODULE);

// Phase 3 test values — non-secret fixtures used only in integration tests.
const ENV_OPENAI_VAL = "sk-env-test-openai-placeholder";
const ENV_ANTHROPIC_VAL = "sk-env-test-anthropic-placeholder";
const ENV_TENANT_A_OPENAI_VAL = "sk-tenant-a-openai-placeholder";
const ENV_TENANT_B_OPENAI_VAL = "sk-tenant-b-openai-placeholder";
const ENV_PROJECT_A_VAL = "sk-project-a-openai-placeholder";
const ENV_PROJECT_B_VAL = "sk-project-b-openai-placeholder";
const ENV_ORG_VAL = "sk-org-openai-placeholder";
const identifierFingerprint = (identifier) =>
  `id:${createHash("sha256").update(identifier).digest("hex").slice(0, 24)}`;
describe("llm-auth module", () => {
  let authCaptureMock;

  beforeAll(async () => {
    authCaptureMock = createHTTPMock(getPort(19011));
    authCaptureMock.setDefault({ body: { choices: [{ message: { content: "ok" } }] } });
    // Set env vars before nginx spawns so workers inherit them via the nginx
    // `env` directive listed in nginx.conf.
    process.env.LLMAUTH_TEST_OPENAI_KEY = ENV_OPENAI_VAL;
    process.env.LLMAUTH_TEST_ANTHROPIC_KEY = ENV_ANTHROPIC_VAL;
    process.env.LLMAUTH_TEST_TENANT_A_OPENAI_KEY = ENV_TENANT_A_OPENAI_VAL;
    process.env.LLMAUTH_TEST_TENANT_B_OPENAI_KEY = ENV_TENANT_B_OPENAI_VAL;
    process.env.LLMAUTH_TEST_PROJECT_A_KEY = ENV_PROJECT_A_VAL;
    process.env.LLMAUTH_TEST_PROJECT_B_KEY = ENV_PROJECT_B_VAL;
    process.env.LLMAUTH_TEST_ORG_KEY = ENV_ORG_VAL;
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    authCaptureMock.stop();
    cleanupRuntime(MODULE);
    delete process.env.LLMAUTH_TEST_OPENAI_KEY;
    delete process.env.LLMAUTH_TEST_ANTHROPIC_KEY;
    delete process.env.LLMAUTH_TEST_TENANT_A_OPENAI_KEY;
    delete process.env.LLMAUTH_TEST_TENANT_B_OPENAI_KEY;
    delete process.env.LLMAUTH_TEST_PROJECT_A_KEY;
    delete process.env.LLMAUTH_TEST_PROJECT_B_KEY;
    delete process.env.LLMAUTH_TEST_ORG_KEY;
  });

  beforeEach(() => {
    authCaptureMock.clearLog();
  });

  async function post(path, body = { ok: true }, extraHeaders = {}) {
    return fetch(`${TEST_URL}${path}`, {
      method: "POST",
      // Connection: close prevents Bun from pooling the connection back after
      // nginx closes it on 500 responses (access-phase rejection with unread body).
      // Without this, the next test races to reuse a half-closed socket → ECONNRESET.
      headers: { "Content-Type": "application/json", Connection: "close", ...extraHeaders },
      body: JSON.stringify(body),
    });
  }

  function readErrorLog() {
    return readFileSync(join(process.cwd(), "tests", MODULE, "runtime", "logs", "error.log"), "utf8");
  }

  function testConfig(configName) {
    const runtimeDir = join(process.cwd(), "tests", MODULE, "runtime-configtest");
    rmSync(runtimeDir, { recursive: true, force: true });
    mkdirSync(join(runtimeDir, "logs"), { recursive: true });
    const configPath = materializeTestConfig(
      join(process.cwd(), "tests", MODULE, configName),
      MODULE,
      runtimeDir,
    );
    try {
      const result = spawnSync([
        "./zig-out/bin/nginz-token",
        "-t",
        "-c",
        configPath,
        "-p",
        runtimeDir,
      ], {
        cwd: process.cwd(),
        env: process.env,
        stderr: "pipe",
        stdout: "pipe",
      });
      return {
        exitCode: result.exitCode,
        stderr: result.stderr.toString(),
        stdout: result.stdout.toString(),
      };
    } finally {
      rmSync(configPath, { force: true });
      rmSync(runtimeDir, { recursive: true, force: true });
    }
  }

  test("resolves OpenAI credential identifier from provider hint", async () => {
    const res = await post("/resolved");
    expect(res.status).toBe(200);
    expect(res.headers.get("x-llm-auth-provider")).toBe("openai");
    expect(res.headers.get("x-llm-auth-credential")).toBe("cred-openai");
    expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
  });

  test("resolves Anthropic credential identifier from provider hint", async () => {
    const res = await post("/resolved-anthropic");
    expect(res.status).toBe(200);
    expect(res.headers.get("x-llm-auth-provider")).toBe("anthropic");
    expect(res.headers.get("x-llm-auth-credential")).toBe("cred-anthropic");
    expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
  });

  test("missing provider credential is explicit in fail-open mode", async () => {
    const res = await post("/missing-open");
    expect(res.status).toBe(200);
    expect(res.headers.get("x-llm-auth-provider")).toBe("anthropic");
    expect(res.headers.get("x-llm-auth-credential")).toBeNull();
    expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
  });

  test("missing provider credential returns 500 in fail-closed mode", async () => {
    const res = await post("/missing-closed");
    expect(res.status).toBe(500);
    expect(res.headers.get("x-llm-auth-provider")).toBe("anthropic");
    expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
  });

  test("missing provider is explicit when no hint or llm-proxy provider is available", async () => {
    const res = await post("/missing-provider-open");
    expect(res.status).toBe(200);
    expect(res.headers.get("x-llm-auth-provider")).toBeNull();
    expect(res.headers.get("x-llm-auth-credential")).toBeNull();
    expect(res.headers.get("x-llm-auth-status")).toBe("missing_provider");
  });

  test("missing provider returns 500 in fail-closed mode", async () => {
    const res = await post("/missing-provider-closed");
    expect(res.status).toBe(500);
    expect(res.headers.get("x-llm-auth-status")).toBe("missing_provider");
  });

  describe("subrequest hardening", () => {
    test("ssi subrequests to llm_auth locations are rejected before upstream execution", async () => {
      const res = await fetch(`${TEST_URL}/subrequest-ssi-parent`, { headers: { Connection: "close" } });
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("403 Forbidden");
      expect(authCaptureMock.getRequestCount()).toBe(0);
    });

    test("auth_request subrequests to llm_auth locations fail closed", async () => {
      const res = await fetch(`${TEST_URL}/subrequest-auth-parent`, { headers: { Connection: "close" } });
      expect(res.status).toBe(403);
      expect(authCaptureMock.getRequestCount()).toBe(0);
    });

    test("mirror subrequests to llm_auth locations do not reach upstream", async () => {
      const res = await fetch(`${TEST_URL}/subrequest-mirror-parent`, { headers: { Connection: "close" } });
      expect(res.status).toBe(200);
      expect(await res.text()).toContain('"choices":[{"message":{"content":"ok"}}]');
      await Bun.sleep(100);
      expect(authCaptureMock.getRequestCount()).toBe(0);
    });
  });

  describe("secret sources (Phase 3)", () => {
    test("env source resolves OpenAI credential", async () => {
      const res = await post("/env-openai-resolved");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-provider")).toBe("openai");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
      // $llm_auth_credential must show the non-secret identifier, not the key value.
      expect(res.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_OPENAI_KEY");
      expect(res.headers.get("x-llm-auth-credential")).not.toBe(ENV_OPENAI_VAL);
    });

    test("env source resolves Anthropic credential", async () => {
      const res = await post("/env-anthropic-resolved");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-provider")).toBe("anthropic");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
      expect(res.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_ANTHROPIC_KEY");
      expect(res.headers.get("x-llm-auth-credential")).not.toBe(ENV_ANTHROPIC_VAL);
    });

    test("missing env var yields missing_secret status", async () => {
      const res = await post("/env-missing");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_secret");
      // identifier still shown; no secret value present
      expect(res.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_MISSING_VAR");
    });

    test("file source resolves OpenAI credential", async () => {
      const res = await post("/file-openai-resolved");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-provider")).toBe("openai");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
      // $llm_auth_credential shows the file: identifier, not the file contents.
      expect(res.headers.get("x-llm-auth-credential")).toBe("file:fixtures/openai-test.key");
    });

    test("missing file yields missing_secret status", async () => {
      const res = await post("/file-missing");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_secret");
      expect(res.headers.get("x-llm-auth-credential")).toBe("file:fixtures/nonexistent.key");
    });
  });

  describe("location inheritance and override", () => {
    test("child inherits parent credentials when child defines none", async () => {
      const res = await post("/inherit-parent/inherit-creds");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-provider")).toBe("openai");
      expect(res.headers.get("x-llm-auth-credential")).toBe("cred-parent-openai");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
    });

    test("child credential overrides parent credential", async () => {
      const res = await post("/inherit-parent/override-creds");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-provider")).toBe("openai");
      expect(res.headers.get("x-llm-auth-credential")).toBe("cred-child-openai");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
    });

    test("child inherits fail_closed from parent", async () => {
      const res = await post("/inherit-parent/inherit-fail-closed");
      expect(res.status).toBe(500);
      expect(res.headers.get("x-llm-auth-provider")).toBe("anthropic");
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
    });

    test("child overrides parent fail_closed", async () => {
      const res = await post("/inherit-parent/override-fail-closed");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-provider")).toBe("anthropic");
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
    });
  });

  describe("phase 2 upstream auth mutation", () => {
    test("replaces gateway Authorization with resolved OpenAI bearer auth", async () => {
      const res = await post(
        "/phase2-openai-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello" }] },
        {
          Authorization: "Bearer da-gateway-key",
          "x-api-key": "client-should-not-pass",
        }
      );
      expect(res.status).toBe(200);

      const received = authCaptureMock.getLastRequest();
      expect(received).toBeTruthy();
      expect(received.headers.authorization).toBe(`Bearer ${ENV_OPENAI_VAL}`);
      expect(received.headers["x-api-key"]).toBeUndefined();
    });

    test("replaces gateway Authorization with resolved Anthropic x-api-key", async () => {
      const res = await post(
        "/phase2-anthropic-resolved",
        { model: "claude-3-sonnet-20240229", messages: [{ role: "user", content: "hello" }] },
        {
          Authorization: "Bearer da-gateway-key",
        }
      );
      expect(res.status).toBe(200);

      const received = authCaptureMock.getLastRequest();
      expect(received).toBeTruthy();
      expect(received.headers.authorization).toBeUndefined();
      expect(received.headers["x-api-key"]).toBe(ENV_ANTHROPIC_VAL);
      expect(received.headers["anthropic-version"]).toBe("2023-06-01");
    });

    test("fail-open missing credential strips gateway auth before upstream send", async () => {
      const res = await post(
        "/phase2-openai-missing-open",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello" }] },
        {
          Authorization: "Bearer da-gateway-key",
          "x-api-key": "client-should-not-pass",
        }
      );
      expect(res.status).toBe(200);

      const received = authCaptureMock.getLastRequest();
      expect(received).toBeTruthy();
      expect(received.headers.authorization).toBeUndefined();
      expect(received.headers["x-api-key"]).toBeUndefined();
    });

    test("fail-closed missing credential rejects before proxying upstream", async () => {
      const res = await post(
        "/phase2-openai-missing-closed",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello" }] },
        {
          Authorization: "Bearer da-gateway-key",
        }
      );
      expect(res.status).toBe(500);
      expect(authCaptureMock.getRequestCount()).toBe(0);
    });
  });

  describe("phase 4 tenant routing", () => {
    test("tenant credentials route to different upstream OpenAI bearer keys", async () => {
      const resA = await post(
        "/phase4-tenant-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello a" }] },
        { "x-llm-tenant": "tenant-a" }
      );
      expect(resA.status).toBe(200);
      expect(resA.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_TENANT_A_OPENAI_KEY");
      expect(resA.headers.get("x-llm-auth-status")).toBe("resolved");

      const tenantARequest = authCaptureMock.getLastRequest();
      expect(tenantARequest).toBeTruthy();
      expect(tenantARequest.headers.authorization).toBe(`Bearer ${ENV_TENANT_A_OPENAI_VAL}`);

      const resB = await post(
        "/phase4-tenant-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello b" }] },
        { "x-llm-tenant": "tenant-b" }
      );
      expect(resB.status).toBe(200);
      expect(resB.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_TENANT_B_OPENAI_KEY");
      expect(resB.headers.get("x-llm-auth-status")).toBe("resolved");

      const tenantBRequest = authCaptureMock.getLastRequest();
      expect(tenantBRequest).toBeTruthy();
      expect(tenantBRequest.headers.authorization).toBe(`Bearer ${ENV_TENANT_B_OPENAI_VAL}`);
      expect(tenantBRequest.headers.authorization).not.toBe(`Bearer ${ENV_TENANT_A_OPENAI_VAL}`);
    });

    test("shared fallback is only used when policy enables it", async () => {
      const res = await post(
        "/phase4-tenant-fallback-open",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello fallback" }] },
        { "x-llm-tenant": "tenant-missing" }
      );
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_OPENAI_KEY");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");

      const received = authCaptureMock.getLastRequest();
      expect(received).toBeTruthy();
      expect(received.headers.authorization).toBe(`Bearer ${ENV_OPENAI_VAL}`);
    });

    test("missing tenant key fails closed when shared fallback is not enabled", async () => {
      const res = await post(
        "/phase4-tenant-fallback-closed",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello fail" }] }
      );
      expect(res.status).toBe(500);
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
      expect(authCaptureMock.getRequestCount()).toBe(0);
    });
  });

  describe("phase 5 audit and hardening", () => {
    test("env-backed credentials expose non-secret source and fingerprint", async () => {
      const res = await post("/env-openai-resolved");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-key-source")).toBe("env");
      const fingerprint = res.headers.get("x-llm-auth-key-fingerprint");
      expect(fingerprint).toBe(identifierFingerprint("env:LLMAUTH_TEST_OPENAI_KEY"));
      expect(fingerprint).not.toContain(ENV_OPENAI_VAL);
      expect(res.headers.get("x-llm-auth-fail-reason")).toBeNull();
    });

    test("unresolved file source reports file source and secret_unresolved fail reason", async () => {
      const res = await post("/file-missing");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-key-source")).toBe("file");
      expect(res.headers.get("x-llm-auth-key-fingerprint")).toBeNull();
      expect(res.headers.get("x-llm-auth-fail-reason")).toBe("secret_unresolved");
    });

    test("client-aware auth distinguishes missing client from generic missing credential", async () => {
      const res = await post("/phase5-tenant-missing-open");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
      expect(res.headers.get("x-llm-auth-fail-reason")).toBe("client_missing");
    });

    test("config test fails when tenant credentials are configured without llm_auth_tenant", async () => {
      const result = testConfig("nginx-bad-tenant.conf");
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("tenant credentials require llm_auth_tenant");
    });

    test("config test fails on duplicate shared provider credentials", async () => {
      const result = testConfig("nginx-bad-duplicate.conf");
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("duplicate shared credential");
    });

    test("debug error log does not contain resolved raw provider credentials", async () => {
      const res = await post(
        "/phase2-openai-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "debug log check" }] },
        { Authorization: "Bearer da-gateway-key" }
      );
      expect(res.status).toBe(200);

      const errorLog = readErrorLog();
      expect(errorLog).not.toContain(ENV_OPENAI_VAL);
      expect(errorLog).not.toContain(ENV_ANTHROPIC_VAL);
      expect(errorLog).not.toContain(ENV_TENANT_A_OPENAI_VAL);
      expect(errorLog).not.toContain(ENV_TENANT_B_OPENAI_VAL);
    });

    test("credential fingerprints are derived only from non-secret identifiers", async () => {
      // /resolved uses a literal credential identifier "cred-openai" (not env:/file:).
      const res = await post("/resolved");
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
      expect(res.headers.get("x-llm-auth-key-source")).toBe("literal");
      const literalFingerprint = res.headers.get("x-llm-auth-key-fingerprint");
      expect(literalFingerprint).toBeTruthy();
      expect(literalFingerprint).toBe(identifierFingerprint("literal"));
      expect(literalFingerprint).not.toContain("cred-openai");
      // To observe key_source we need a location that exposes it; use env-openai-resolved for comparison.
      const res2 = await post("/env-openai-resolved");
      expect(res2.headers.get("x-llm-auth-key-source")).toBe("env");
      const res3 = await post("/file-openai-resolved");
      expect(res3.headers.get("x-llm-auth-key-source")).toBe("file");
      const fileFingerprint = res3.headers.get("x-llm-auth-key-fingerprint");
      expect(fileFingerprint).toBeTruthy();
      expect(fileFingerprint).toBe(identifierFingerprint("file:fixtures/openai-test.key"));
      expect(fileFingerprint).not.toContain("openai-test.key");
      expect(literalFingerprint).not.toBe(fileFingerprint);
      // All three adapters produce resolved status when the secret is present.
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
      expect(res2.headers.get("x-llm-auth-status")).toBe("resolved");
      expect(res3.headers.get("x-llm-auth-status")).toBe("resolved");
    });
  });

  // ── Milestone 2: Target 1 — canonical gateway identity contract ──────────

  describe("milestone 2 target 1: identity context variables", () => {
    test("identity variables are empty when not configured", async () => {
      const res = await post("/resolved");
      expect(res.status).toBe(200);
      // /resolved has no llm_auth_tenant/project/org → identity vars absent.
      expect(res.headers.get("x-llm-auth-client")).toBeNull();
    });

    test("client/project/org identity variables populate from configured sources", async () => {
      const res = await post("/m2t1-identity-vars", { ok: true }, {
        "x-llm-client": "client-x",
        "x-llm-project": "proj-beta",
        "x-llm-org": "org-acme",
      });
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-client")).toBe("client-x");
      expect(res.headers.get("x-llm-auth-project")).toBe("proj-beta");
      expect(res.headers.get("x-llm-auth-org")).toBe("org-acme");
      expect(res.headers.get("x-llm-auth-status")).toBe("resolved");
    });

    test("secret-safe literal form exposes only its public id", async () => {
      const secret = "literal-shipping-secret";
      const res = await post(
        "/literal-id-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "hello" }] },
      );
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-credential")).toBe("shipping-key");
      expect(res.headers.get("x-llm-auth-credential")).not.toContain(secret);
      expect(res.headers.get("x-llm-auth-key-source")).toBe("literal");

      const received = authCaptureMock.getLastRequest();
      expect(received).toBeTruthy();
      expect(received.headers.authorization).toBe(`Bearer ${secret}`);
    });

    test("missing org yields explicit org_missing fail reason", async () => {
      // /m2t1-org-missing-closed: org credentials configured, org header absent → org_missing
      const res = await post("/m2t1-org-missing-closed");
      expect(res.status).toBe(500);
      expect(res.headers.get("x-llm-auth-status")).toBe("missing_credential");
      expect(res.headers.get("x-llm-auth-fail-reason")).toBe("org_missing");
    });

    test("present org with no matching credential yields org_credential_missing", async () => {
      const res = await post("/m2t1-org-missing-closed", { ok: true }, {
        "x-llm-org": "org-unknown",
      });
      expect(res.status).toBe(500);
      expect(res.headers.get("x-llm-auth-fail-reason")).toBe("org_credential_missing");
    });
  });

  // ── Milestone 2: Target 2 — org/project/provider credential selection ────

  describe("milestone 2 target 2: org/project credential cascade", () => {
    test("project-A and project-B resolve different credentials for the same provider", async () => {
      const resA = await post(
        "/m2t2-project-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "a" }] },
        { "x-llm-project": "project-a" }
      );
      expect(resA.status).toBe(200);
      expect(resA.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_PROJECT_A_KEY");
      expect(resA.headers.get("x-llm-auth-status")).toBe("resolved");
      const reqA = authCaptureMock.getLastRequest();
      expect(reqA.headers.authorization).toBe(`Bearer ${ENV_PROJECT_A_VAL}`);

      authCaptureMock.clearLog();

      const resB = await post(
        "/m2t2-project-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "b" }] },
        { "x-llm-project": "project-b" }
      );
      expect(resB.status).toBe(200);
      expect(resB.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_PROJECT_B_KEY");
      const reqB = authCaptureMock.getLastRequest();
      expect(reqB.headers.authorization).toBe(`Bearer ${ENV_PROJECT_B_VAL}`);
      expect(reqB.headers.authorization).not.toBe(`Bearer ${ENV_PROJECT_A_VAL}`);
    });

    test("project credential takes precedence over org credential", async () => {
      const res = await post(
        "/m2t2-project-over-org",
        { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
        { "x-llm-project": "project-alpha", "x-llm-org": "org-acme" }
      );
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_PROJECT_A_KEY");
      const req = authCaptureMock.getLastRequest();
      expect(req.headers.authorization).toBe(`Bearer ${ENV_PROJECT_A_VAL}`);
    });

    test("org credential is used when no project credential matches", async () => {
      const res = await post(
        "/m2t2-project-over-org",
        { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
        { "x-llm-project": "project-unknown", "x-llm-org": "org-acme" }
      );
      expect(res.status).toBe(200);
      expect(res.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_ORG_KEY");
      const req = authCaptureMock.getLastRequest();
      expect(req.headers.authorization).toBe(`Bearer ${ENV_ORG_VAL}`);
    });

    test("client BYOK credential is used for the matching client only", async () => {
      // byok-client gets the BYOK credential; other-client falls through to project credential.
      const resByok = await post(
        "/m2t2-client-byok",
        { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
        { "x-llm-client": "byok-client", "x-llm-project": "shared-project" }
      );
      expect(resByok.status).toBe(200);
      expect(resByok.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_TENANT_A_OPENAI_KEY");

      authCaptureMock.clearLog();

      const resOther = await post(
        "/m2t2-client-byok",
        { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
        { "x-llm-client": "other-client", "x-llm-project": "shared-project" }
      );
      expect(resOther.status).toBe(200);
      // other-client has no BYOK credential → falls through to project credential
      expect(resOther.headers.get("x-llm-auth-credential")).toBe("env:LLMAUTH_TEST_PROJECT_A_KEY");
      expect(resOther.headers.get("x-llm-auth-credential")).not.toBe("env:LLMAUTH_TEST_TENANT_A_OPENAI_KEY");
    });

    test("gateway credential stripping is preserved on translated paths", async () => {
      // Verify that even with org/project cascading active, the gateway auth is stripped.
      const res = await post(
        "/m2t2-project-resolved",
        { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
        { "x-llm-project": "project-a", Authorization: "Bearer da-gateway-key" }
      );
      expect(res.status).toBe(200);
      const req = authCaptureMock.getLastRequest();
      expect(req.headers.authorization).toBe(`Bearer ${ENV_PROJECT_A_VAL}`);
      expect(req.headers.authorization).not.toContain("da-gateway-key");
    });
  });
});
