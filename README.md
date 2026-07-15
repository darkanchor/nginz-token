# nginz-token

`nginz-token` is the source-available AI gateway module library for the
darkanchor stack. It
builds on the same nginx/Zig substrate used by `nginz`, but focuses on the
`llm-*` gateway layer: provider routing, normalization, usage extraction,
gateway auth integration, and the operational control plane required by AI
traffic.

The standalone binary `nginz-token` exists for evaluation, development, and
testing. Commercial production access is delivered as private `linux/amd64`
images through [checkout.darkanchor.com](https://checkout.darkanchor.com/).

## Positioning

The design split is deliberate:

- `nginz` provides general-purpose nginx infrastructure primitives.
- `nginz-token` provides the AI gateway layer.
- `llm-proxy` is the foundational request/response normalization substrate.
- later `llm-*` modules consume the context and variables established by `llm-proxy`.

The core thesis is that AI gateway value is not just reverse proxying. The
defensible layer is consistent provider routing, usage extraction, cost/rate
control integration, and provider-agnostic normalization that downstream policy
modules can trust.

## Current status

Version 1.30 is the current source-available release. Its eight gateway modules
and four Pro/Enterprise gateway images have passed the published stability gate.

Implemented today:

- standalone `nginz-token` binary build
- nginx/Zig bindings and build substrate synced from `nginz`
- `llm-proxy` request routing, dialect-aware translation, upstream auth
  execution, response normalization, SSE handling, and requested/effective
  routing observability
- `llm-auth` policy layer with client/project/org credential cascade,
  env/file/literal secret sources, and fingerprint-safe auth variables
- `llm-fallback` replacement, retry taxonomy, model override, and
  translation-aware replay policy
- `llm-security` request/response inspection, native/translated path
  observability, and first-release org/project layered policy inheritance
- `llm-metrics` module with Prometheus export, provider counters, latency
  histogram, usage accounting, bounded auth-status/model families,
  requested/effective routing counters, and opt-in tenant aggregation
- `llm-ratelimit` request/token budgets, translated-traffic quotas,
  requested/effective routing basis, and rejected-before-send reconciliation
- `llm-cost` rate-card accounting, translated traffic cohorting, requested vs
  effective routing attribution, Postgres persistence, and cached-input blended
  pricing (`llm_cost_cached_rate`) for provider prompt-cache discounts and write
  premiums
- bidirectional OpenAI/Anthropic dialect translation: Anthropic-native client to
  OpenAI-compatible endpoints (request rewrite + non-streaming and SSE response
  normalization), conservative body-shape dialect inference, and unified
  `llm_proxy_normalize_response` gate for both translation directions
- reusable project-level provider mocks for OpenAI and Anthropic
- shared test harness with per-suite dynamic ports and serialized `zig build`
- standalone perf runners for `llm-proxy`, `llm-metrics`, `llm-ratelimit`,
  `llm-cost`, and the combined `llm-stack`

Current scope limits:

- productized control-plane/runtime wiring for all current module knobs
- semantic cache and any external secret-manager adapters
- live-provider soak coverage and broader perf studies for fallback/security
  heavy-path traffic
- external secret-manager adapters and live secret rotation without reload

## Repository layout

```text
  src/
  ngx/                                   nginx Zig bindings and wrappers
  modules/
    llm_contract.zig                     shared cross-module ABI struct definitions
    llm-proxy-nginx-module/              foundational AI gateway module
    llm-auth-nginx-module/               provider credential policy and source layer
    llm-fallback-nginx-module/           retry, replacement, and replay policy
    llm-security-nginx-module/           request/response policy inspection layer
    llm-metrics-nginx-module/            observability and Prometheus export layer
    llm-ratelimit-nginx-module/          quota and cooldown policy layer
    llm-cost-nginx-module/               accounting and persistence layer
    llm-cache-nginx-module/              future semantic cache work

tests/
  harness.js                             shared nginx build/runtime harness
  mocks/
    openai.js                            OpenAI-shaped HTTP/SSE provider mock
    anthropic.js                         Anthropic-shaped HTTP/SSE provider mock
    http.js                              generic upstream mock
  llm-proxy/                             integration tests for current module work
  llm-auth/                              integration tests for auth policy/source work
  llm-fallback/                          integration tests for fallback/replay behavior
  llm-security/                          integration tests for security inspection/policy
  llm-metrics/                           integration tests for metrics/export behavior
  llm-ratelimit/                         integration tests for quota/cooldown behavior
  llm-cost/                              integration tests for accounting/persistence

project/                                 build helper files copied from nginz
submodules/                              pinned nginx / njs sources
```

## Module focus

### llm-proxy

`llm-proxy` is the most important module in the repo right now. It is the
substrate that later modules depend on for:

- canonical provider selection
- canonical model identification
- canonical streaming classification
- canonical usage extraction
- canonical provider-neutral wire contract

### llm-auth

`llm-auth` still has a strong rationale, but mainly as an ownership and policy
surface: credential sources, client/project/org policy, fail-open/closed
rules, and redaction/audit constraints.

The important correction is that runtime provider-auth mutation now belongs
inside `llm-proxy`’s ingress path, not as a fully separate nginx ACCESS module
boundary. The current implementation preserves the auth-specific design surface
without pretending that byte-level provider auth rewriting is a separate hook.

### llm-fallback

`llm-fallback` owns the distinction between three different behaviors that
should stay separate in the product contract:

- first-hop routing as requested
- explicit policy replacement before the first send
- failure-driven replay after a classified upstream failure

It also carries the translation-aware replay policy that now respects route
dialect, not just provider naming.

### llm-metrics

`llm-metrics` is the observability layer for the gateway. It consumes bounded,
non-secret request metadata already established by `llm-proxy` and `llm-auth`
and turns that into scrapeable Prometheus metrics.

The important constraint is that it observes rather than controls. Today it
exports provider-bucket request/error counters, a request-duration histogram,
usage extracted/missing counters, token totals when enabled, conservative
auth-status counter families behind `llm_metrics_label_auth_status on;`, and
bounded model counter families behind `llm_metrics_label_model on;`.

### llm-ratelimit

`llm-ratelimit` is the first hot-path policy layer that actively controls
traffic. It applies request/token budgets, translated-traffic pressure, and
requested-vs-effective routing basis without guessing outside the canonical
facts established by `llm-proxy`.

### llm-cost

`llm-cost` is the accounting layer. It consumes usage authority from
`llm-proxy`, adds requested/effective routing attribution and tenant fields,
and optionally persists billable rows to Postgres.

### llm-security

`llm-security` is the policy inspection layer. It owns request/response
inspection semantics, coarse client-visible outcomes, and audit-safe rule
observability. The current first-release inheritance model is org baseline plus
optional project tightening.

## Build

Initial setup:

```bash
git submodule update --init --recursive
```

Build the binary:

```bash
zig build
```

Run Zig unit tests:

```bash
zig build test
```

Run integration tests:

```bash
bun test tests/llm-proxy/
```

Module-specific examples:

```bash
bun test tests/llm-auth/
bun test tests/llm-fallback/
bun test tests/llm-metrics/
bun test tests/llm-ratelimit/
bun test tests/llm-cost/
bun test tests/llm-security/
```

For release-grade local verification, prefer `ReleaseSmall`:

```bash
ZIG_OPTIMIZE=ReleaseSmall bun test tests/llm-proxy/
```

## Testing

The project test strategy is intentionally wire-focused. These modules are
about nginx phase behavior, request/response rewriting, and streaming
correctness, so deterministic HTTP/SSE fixtures matter more than SDK-level
abstractions.

Current test infrastructure includes:

- shared runtime harness in [tests/harness.js](tests/harness.js)
- generic upstream mocks in [tests/mocks/http.js](tests/mocks/http.js)
- provider-specific mocks in:
  - [tests/mocks/openai.js](tests/mocks/openai.js)
  - [tests/mocks/anthropic.js](tests/mocks/anthropic.js)

Those provider mocks are designed to support:

- exact JSON request/response capture
- provider-shaped error bodies
- SSE streaming responses
- deliberate chunk splitting for streaming edge cases

That fixture style is the intended foundation for the whole project, not just
for `llm-proxy`.

## Licensing

This repository is currently licensed under the
[Business Source License 1.1](LICENSE) at the repository level unless a
specific subcomponent states otherwise.

BSL 1.1 is source-available, not an Open Source license. It permits copying,
modification, redistribution, and non-production use. Production use requires
a commercial license from darkanchor until the Change Date. On January 1,
2030—or the fourth anniversary of the first public distribution of this
version, if earlier—the licensed work changes to Apache License 2.0.

Third-party components remain under their own license terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the bundled components
and pinned submodule revisions.

## Commercial access

See [live pricing](https://checkout.darkanchor.com/) for Pro and Enterprise
subscriptions, or read the [commercial terms and refund policy](https://checkout.darkanchor.com/subscribe).
