const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const hash = ngx.hash;
const buf = ngx.buf;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_DONE = core.NGX_DONE;
const NGX_HTTP_REQUEST_ENTITY_TOO_LARGE: ngx_int_t = 413;

const log = ngx.log;
const NGX_LOG_EMERG: ngx_uint_t = 1;
const NGX_LOG_WARN: ngx_uint_t = 5;
const NGX_LOG_NOTICE: ngx_uint_t = 6;
const NGX_LOG_DEBUG: ngx_uint_t = 8;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;
const ngx_table_elt_t = hash.ngx_table_elt_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_buf_t = buf.ngx_buf_t;

const ngx_string = ngx.string.ngx_string;
const strlen = ngx.string.strlen;
const NList = ngx.list.NList;
const NArray = ngx.array.NArray;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_llm_auth_module: ngx_module_t;
extern var ngx_http_llm_security_module: ngx_module_t;
extern var ngx_http_llm_fallback_module: ngx_module_t;
extern var ngx_http_proxy_module: ngx_module_t;

// Response headers stamped on every enabled-location response.
const gateway_header_name: ngx_str_t = ngx_string("X-LLM-Proxy");
const gateway_header_value: ngx_str_t = ngx_string("nginz-token");
const provider_header_name: ngx_str_t = ngx_string("X-LLM-Provider");
const provider_header_lowcase: ngx_str_t = ngx_string("x-llm-provider");
const authorization_header_name: ngx_str_t = ngx_string("Authorization");
const authorization_header_lowcase: ngx_str_t = ngx_string("authorization");
const x_api_key_header_name: ngx_str_t = ngx_string("x-api-key");
const x_api_key_header_lowcase: ngx_str_t = ngx_string("x-api-key");
const rl_reset_after_ms_name: ngx_str_t = ngx_string("X-LLM-Reset-After-Ms");
const rl_reset_after_ms_lowcase: ngx_str_t = ngx_string("x-llm-reset-after-ms");
const rl_remaining_tokens_name: ngx_str_t = ngx_string("X-LLM-Remaining-Tokens");
const rl_remaining_tokens_lowcase: ngx_str_t = ngx_string("x-llm-remaining-tokens");
const rl_remaining_requests_name: ngx_str_t = ngx_string("X-LLM-Remaining-Requests");
const rl_remaining_requests_lowcase: ngx_str_t = ngx_string("x-llm-remaining-requests");
const fallback_attempted_name: ngx_str_t = ngx_string("X-Fallback-Attempted");
const fallback_attempted_lowcase: ngx_str_t = ngx_string("x-fallback-attempted");
const fallback_suppressed_name: ngx_str_t = ngx_string("X-Fallback-Suppressed");
const fallback_suppressed_lowcase: ngx_str_t = ngx_string("x-fallback-suppressed");
const fallback_reason_name: ngx_str_t = ngx_string("X-Fallback-Reason");
const fallback_reason_lowcase: ngx_str_t = ngx_string("x-fallback-reason");
const fallback_policy_allowed_name: ngx_str_t = ngx_string("X-Fallback-Policy-Allowed");
const fallback_policy_allowed_lowcase: ngx_str_t = ngx_string("x-fallback-policy-allowed");
const fallback_policy_mismatch_name: ngx_str_t = ngx_string("X-Fallback-Policy-Mismatch");
const fallback_policy_mismatch_lowcase: ngx_str_t = ngx_string("x-fallback-policy-mismatch");
const fallback_suppressed_reason_name: ngx_str_t = ngx_string("X-Fallback-Suppressed-Reason");
const fallback_suppressed_reason_lowcase: ngx_str_t = ngx_string("x-fallback-suppressed-reason");
const fallback_attempt_count_name: ngx_str_t = ngx_string("X-Fallback-Attempt-Count");
const fallback_attempt_count_lowcase: ngx_str_t = ngx_string("x-fallback-attempt-count");
const fallback_primary_name: ngx_str_t = ngx_string("X-Fallback-Primary");
const fallback_primary_lowcase: ngx_str_t = ngx_string("x-fallback-primary");
const fallback_effective_name: ngx_str_t = ngx_string("X-Fallback-Effective");
const fallback_effective_lowcase: ngx_str_t = ngx_string("x-fallback-effective");
const failure_class_name: ngx_str_t = ngx_string("X-LLM-Failure-Class");
const failure_class_lowcase: ngx_str_t = ngx_string("x-llm-failure-class");

const DEFAULT_MAX_BODY_SIZE: usize = 64 * 1024;
const DEFAULT_MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024; // 10 MB safety cap
const RESP_BUF_INIT_CAP: usize = 4 * 1024;
const MAX_ROUTES: usize = 8;
const SSE_LINE_BUF_SIZE: usize = 4096; // initial bytes for any single SSE line; grows on demand
const SSE_DATA_BUF_SIZE: usize = 8192; // initial bytes for any single SSE data: payload; grows on demand
// Hard ceiling for a single SSE line / data payload. Buffers grow from the
// initial sizes above up to this cap; only a single line larger than this (which
// no real provider emits) is rejected by the rewrite paths.
// Bounds per-request memory the same way max_response_size bounds the buffered path.
const SSE_LINE_MAX_SIZE: usize = 1024 * 1024;

const empty_str = ngx_str_t{ .len = 0, .data = @constCast("") };

const llm_auth_loc_conf_view = extern struct {
    enabled: ngx_flag_t,
};

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const AuthResolution = contract.AuthResolution;

extern fn ngx_http_llm_auth_resolve(r: [*c]ngx_http_request_t) AuthResolution;

// ── llm-security cross-module view ───────────────────────────────────────────

const llm_security_loc_conf_view = extern struct {
    enabled: ngx_flag_t,
    mode: ngx_uint_t,
    rules_file: ngx_str_t,
    org_rules_file: ngx_str_t,
    project_rules_file: ngx_str_t,
    fail_closed: ngx_flag_t,
    inspect_response: ngx_flag_t,
    rules: ?*anyopaque,
    rules_count: ngx_uint_t,
    org_var_index: ngx_int_t,
    project_var_index: ngx_int_t,
    policy_source: ngx_str_t,
    reject_oversized_request: ngx_flag_t,
    reject_oversized_response: ngx_flag_t,
};

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const LlmSecurityOutcome = contract.LlmSecurityOutcome;

extern fn ngx_http_llm_security_inspect_request(r: [*c]ngx_http_request_t, body: ngx_str_t) LlmSecurityOutcome;
extern fn ngx_http_llm_security_inspect_response(r: [*c]ngx_http_request_t, body: ngx_str_t, out_body: [*c]ngx_str_t) LlmSecurityOutcome;

// ── llm-fallback cross-module view ───────────────────────────────────────────

const llm_fallback_loc_conf_view = extern struct {
    enabled: ngx_flag_t,
};

const ngx_http_proxy_loc_conf_view = extern struct {
    upstream: http.ngx_http_upstream_conf_t,
};

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const FallbackRouteLookup = contract.FallbackRouteLookup;

extern fn ngx_http_llm_fallback_lookup_route(r: [*c]ngx_http_request_t, primary: ngx_str_t) FallbackRouteLookup;
extern fn ngx_http_llm_fallback_is_retryable(r: [*c]ngx_http_request_t, status: ngx_uint_t, is_streaming: ngx_flag_t) ngx_flag_t;
extern fn ngx_http_llm_fallback_is_reason_retryable(r: [*c]ngx_http_request_t, reason: ngx_uint_t, is_streaming: ngx_flag_t) ngx_flag_t;
// Milestone 2 Target 1: pre-send replacement lookup.
extern fn ngx_http_llm_fallback_lookup_replacement(r: [*c]ngx_http_request_t, provider: ngx_str_t) ngx_str_t;
// Milestone 2 Target 3: translation fallback policy.
extern fn ngx_http_llm_fallback_translation_policy(r: [*c]ngx_http_request_t) ngx_uint_t;
extern fn ngx_http_llm_fallback_max_attempts_limit(r: [*c]ngx_http_request_t) ngx_uint_t;

// Mirror of llm-fallback's translation policy constants (keep in sync).
const TRANSLATION_FALLBACK_ALLOW: ngx_uint_t = 0;
const TRANSLATION_FALLBACK_DISCOURAGE: ngx_uint_t = 1;
const TRANSLATION_FALLBACK_FORBID: ngx_uint_t = 2;

const FALLBACK_REASON_NONE: ngx_uint_t = 0;
const FALLBACK_REASON_CONNECT_ERROR: ngx_uint_t = 1;
const FALLBACK_REASON_TRANSPORT_TIMEOUT: ngx_uint_t = 2;
const FALLBACK_REASON_RATE_LIMITED: ngx_uint_t = 3;
const FALLBACK_REASON_UPSTREAM_5XX: ngx_uint_t = 4;
const FAILURE_CLASS_NONE: ngx_uint_t = 0;
const FAILURE_CLASS_CONNECT_ERROR: ngx_uint_t = 1;
const FAILURE_CLASS_TRANSPORT_TIMEOUT: ngx_uint_t = 2;
const FAILURE_CLASS_RATE_LIMITED: ngx_uint_t = 3;
const FAILURE_CLASS_UPSTREAM_5XX: ngx_uint_t = 4;
const FAILURE_CLASS_SEMANTIC_ERROR: ngx_uint_t = 5;

const auth_mode_none: ngx_uint_t = 0;
const auth_mode_bearer: ngx_uint_t = 1;
const auth_mode_x_api_key: ngx_uint_t = 2;

// Milestone 2 (Phase 12): dialect mode — how the gateway determines request dialect.
const DIALECT_MODE_INFER: ngx_uint_t = 0; // infer from body shape (default)
const DIALECT_MODE_FIXED: ngx_uint_t = 1; // ingress_dialect fixes the dialect
const DIALECT_MODE_EXPLICIT_REQUIRED: ngx_uint_t = 2; // reject if no explicit dialect

// Milestone 2 (Phase 12): how requested_dialect was determined.
const DIALECT_SOURCE_INFERRED_SHAPE: ngx_uint_t = 0; // inferred from request body
const DIALECT_SOURCE_FIXED_INGRESS: ngx_uint_t = 1; // set by ingress_dialect config
const DIALECT_SOURCE_EXPLICIT: ngx_uint_t = 2; // explicitly declared by client

// Milestone 2 (Phase 12): resolution outcome taxonomy.
const RESOLUTION_OUTCOME_AS_REQUESTED: ngx_uint_t = 0;
const RESOLUTION_OUTCOME_REPLACED_BY_POLICY: ngx_uint_t = 1;
const RESOLUTION_OUTCOME_FALLBACK_AFTER_FAILURE: ngx_uint_t = 2;
const RESOLUTION_OUTCOME_REJECTED_OUT_OF_SCOPE: ngx_uint_t = 3;
const RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE: ngx_uint_t = 4;

const MAX_MODEL_PATTERNS: usize = 32;

// A single provider→upstream binding set via `llm_proxy_route`.
// dialect: the API dialect the endpoint speaks ("openai" | "anthropic" | empty=openai default).
const llm_proxy_route_t = extern struct {
    provider: ngx_str_t,
    upstream: ngx_str_t,
    dialect: ngx_str_t,
};

// A provider→API-version mapping set via `llm_proxy_provider_version`.
const llm_proxy_provider_version_t = extern struct {
    provider: ngx_str_t,
    version: ngx_str_t,
};

// Operator-managed model pattern for catalog-based resolution (Phase 12).
// pattern: model name prefix; provider: provider to route to.
const llm_proxy_model_pattern_t = extern struct {
    pattern: ngx_str_t,
    provider: ngx_str_t,
};

const llm_proxy_loc_conf = extern struct {
    enabled: ngx_flag_t,
    max_body_size: usize,
    routes: [MAX_ROUTES]llm_proxy_route_t,
    routes_count: ngx_uint_t,
    default_provider: ngx_str_t,
    // Phase 3: format translation directives
    normalize_response: ngx_flag_t, // NGX_CONF_UNSET → treated as 1 (on)
    inject_usage: ngx_flag_t, // NGX_CONF_UNSET → treated as 1 (on)
    provider_versions: [MAX_ROUTES]llm_proxy_provider_version_t,
    provider_versions_count: ngx_uint_t,
    // Phase 4: response processing limit
    max_response_size: usize, // bytes; responses over this are passed through unmodified
    // Phase 12: dialect and operator catalog
    dialect_mode: ngx_uint_t, // DIALECT_MODE_*; default DIALECT_MODE_INFER
    ingress_dialect: ngx_str_t, // dialect fixed at ingress when mode=fixed
    model_patterns: [MAX_MODEL_PATTERNS]llm_proxy_model_pattern_t,
    model_patterns_count: ngx_uint_t,
    // Phase 15 (Milestone 2 Target 4): disclosure policy.
    // Controls whether X-LLM-Provider is sent to the client.
    // Internal ctx fields are always populated regardless of this setting.
    // NGX_CONF_UNSET → treated as 1 (on).
    disclose_provider: ngx_flag_t,
    translation_fail_closed: ngx_flag_t,
};

// Per-request context. Allocated in ACCESS phase, read by downstream modules.
// Matches the cross-module contract in README.md.
const LlmProxyCtx = extern struct {
    // Set in ACCESS phase
    provider: ngx_str_t,
    provider_host: ngx_str_t, // e.g. "api.openai.com" or "api.anthropic.com"
    model: ngx_str_t,
    upstream: ngx_str_t,
    is_streaming: ngx_flag_t,
    // 1 only when the request body was valid JSON and model/stream were extracted.
    // 0 for non-JSON, oversized, missing body, or parse error — those use default routing.
    body_parsed: ngx_flag_t,
    // Set in request body translation (Phase 3)
    request_rewritten: ngx_flag_t,
    request_translation_skipped: ngx_flag_t,
    // Set in response header filter (Phase 4)
    response_is_streaming: ngx_flag_t, // response Content-Type is text/event-stream
    response_too_large: ngx_flag_t, // response exceeds max_response_size, skip processing
    response_is_error_shape: ngx_flag_t, // response body is an API error, not normalised
    // Set in response body filter (Phase 4/5)
    response_body_done: ngx_flag_t, // body filter has already processed this response
    prompt_tokens: ngx_uint_t,
    completion_tokens: ngx_uint_t,
    total_tokens: ngx_uint_t,
    cache_read_tokens: ngx_uint_t,
    cache_create_tokens: ngx_uint_t,
    usage_extracted: ngx_flag_t,
    // Response accumulation buffer (Phase 4 non-streaming path)
    resp_buf: [*c]u8,
    resp_buf_len: usize,
    resp_buf_cap: usize,
    // Phase 5: SSE streaming state (all zeroed by pool alloc)
    sse_line_buf: [*c]u8, // SSE_LINE_BUF_SIZE bytes initially, grown lazily up to SSE_LINE_MAX_SIZE
    sse_line_len: ngx_uint_t, // bytes accumulated in current line
    sse_line_cap: usize, // current capacity of sse_line_buf (0 until first alloc)
    sse_line_overflow: ngx_flag_t, // current line exceeded SSE_LINE_MAX_SIZE — skip parsing it
    sse_raw_line_buf: [*c]u8, // full physical line bytes for rewrite-capable SSE paths
    sse_raw_line_len: usize,
    sse_raw_line_cap: usize,
    sse_event_type_buf: [*c]u8, // 64 bytes for Anthropic event type label
    sse_event_type_len: ngx_uint_t,
    sse_data_buf: [*c]u8, // SSE_DATA_BUF_SIZE bytes initially, grown lazily up to SSE_LINE_MAX_SIZE
    sse_data_len: ngx_uint_t, // bytes of current data: payload
    sse_data_cap: usize, // current capacity of sse_data_buf (0 until first alloc)
    sse_data_overflow: ngx_flag_t, // data line exceeded SSE_LINE_MAX_SIZE — pass event through
    sse_saw_done: ngx_flag_t, // saw OpenAI [DONE] or Anthropic message_stop
    sse_input_tokens: ngx_uint_t, // accumulated from Anthropic message_start
    sse_cache_read_tokens: ngx_uint_t,
    sse_cache_create_tokens: ngx_uint_t,
    // Phase 6: rate-limit headers from upstream response (parsed in header filter)
    reset_after_ms: ngx_uint_t, // ms until token quota resets
    reset_after_ms_valid: ngx_flag_t, // 1 if reset header was present and parsed
    ratelimit_remaining_tokens: ngx_uint_t,
    ratelimit_remaining_tokens_valid: ngx_flag_t, // 1 if remaining-tokens header was present
    ratelimit_remaining_requests: ngx_uint_t,
    ratelimit_remaining_requests_valid: ngx_flag_t, // 1 if remaining-requests header was present
    // Phase 7: auth/failure/replay substrate
    auth_prepared: ngx_flag_t,
    auth_failed: ngx_flag_t,
    auth_fail_reason: ngx_str_t,
    failure_class: ngx_uint_t,
    replay_safe: ngx_flag_t,
    response_started: ngx_flag_t,
    request_blocked: ngx_flag_t,
    // Fallback outcome (set in header filter when retry detected)
    fallback_attempted: ngx_flag_t,
    fallback_suppressed: ngx_flag_t,
    fallback_suppressed_reason: ngx_str_t,
    fallback_policy_allowed: ngx_flag_t,
    fallback_policy_mismatch: ngx_flag_t,
    fallback_reason: ngx_uint_t, // 0=none 1=connect_error 2=timeout 3=rate_limited 4=upstream_5xx
    fallback_attempt_count: ngx_uint_t,
    fallback_effective_provider: ngx_str_t,
    fallback_primary_provider: ngx_str_t,
    // Phase 12 (Milestone 2 Target 1): request identity and resolution substrate
    // requested_* fields reflect what the client asked for; effective_* fields reflect
    // what the gateway resolved and executed.
    requested_provider: ngx_str_t, // from body "provider" field; empty if absent
    requested_model: ngx_str_t, // raw model from request body (same as ctx.model)
    requested_dialect: ngx_str_t, // "openai" | "anthropic"; from ingress contract or inference
    requested_dialect_source: ngx_uint_t, // DIALECT_SOURCE_*
    effective_model: ngx_str_t, // resolved model (same as requested_model; diverges on replacement)
    effective_provider: ngx_str_t, // resolved provider (same as ctx.provider)
    effective_dialect: ngx_str_t, // dialect of the effective endpoint
    resolution_outcome: ngx_uint_t, // RESOLUTION_OUTCOME_*
    // Phase 13 (Milestone 2 Target 2): translation state
    translation_happened: ngx_flag_t, // 1 when request body was translated across dialects
    // Phase 14 (Milestone 2 Target 3): replacement state
    // replacement_happened is 1 when a pre-send replacement rule changed provider/model
    // from what the client requested before the first upstream send.
    // Currently always 0 — no replacement policy mechanism implemented yet.
    replacement_happened: ngx_flag_t,
    // Phase 21 (Milestone 2 Target 10): OpenAI→Anthropic SSE rewrite state
    sse_sent_message_start: ngx_flag_t, // 1 after message_start+content_block_start emitted
};

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
// Re-exported pub so existing external references to llm-proxy's observable keep resolving.
pub const LlmProxyObservable = contract.LlmProxyObservable;

var ngx_http_llm_proxy_next_header_filter: http.ngx_http_output_header_filter_pt = null;
var ngx_http_llm_proxy_next_body_filter: http.ngx_http_output_body_filter_pt = null;

// ── Provider resolution ───────────────────────────────────────────────────────

fn str_starts_with_ci(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

// Resolve provider from operator-managed catalog patterns.  Returns empty_str when no
// pattern matches — caller must decide whether to use the default or reject.
fn resolve_provider_from_catalog(model: ngx_str_t, lccf: *llm_proxy_loc_conf) ngx_str_t {
    if (model.len == 0) return empty_str;
    if (lccf.model_patterns_count == 0) return empty_str;
    const m = core.slicify(u8, model.data, model.len);
    var i: usize = 0;
    while (i < lccf.model_patterns_count) : (i += 1) {
        const pat = &lccf.model_patterns[i];
        if (pat.pattern.len == 0) continue;
        const p = core.slicify(u8, pat.pattern.data, pat.pattern.len);
        if (str_starts_with_ci(m, p)) return pat.provider;
    }
    return empty_str; // catalog configured but no match → unresolvable
}

// Resolve provider for routing; falls back to default when catalog has no match.
// Use resolve_provider_from_catalog when you need to distinguish "no match" from "defaulted".
fn resolve_provider(model: ngx_str_t, lccf: *llm_proxy_loc_conf) ngx_str_t {
    if (model.len == 0) {
        return if (lccf.default_provider.len > 0) lccf.default_provider else empty_str;
    }
    const from_catalog = resolve_provider_from_catalog(model, lccf);
    if (from_catalog.len > 0) return from_catalog;
    return if (lccf.default_provider.len > 0) lccf.default_provider else empty_str;
}

fn provider_to_host(provider: ngx_str_t) ngx_str_t {
    if (provider.len == 0) return empty_str;
    const p = core.slicify(u8, provider.data, provider.len);
    if (std.mem.eql(u8, p, "openai")) return ngx_string("api.openai.com");
    if (std.mem.eql(u8, p, "anthropic")) return ngx_string("api.anthropic.com");
    return empty_str;
}

fn find_upstream(provider: ngx_str_t, lccf: *llm_proxy_loc_conf) ngx_str_t {
    if (provider.len == 0) return empty_str;
    const p = core.slicify(u8, provider.data, provider.len);
    var i: usize = 0;
    while (i < lccf.routes_count) : (i += 1) {
        const route = &lccf.routes[i];
        const rp = core.slicify(u8, route.provider.data, route.provider.len);
        if (std.mem.eql(u8, p, rp)) return route.upstream;
    }
    return empty_str;
}

fn has_route_for_provider(provider: ngx_str_t, lccf: *llm_proxy_loc_conf) bool {
    return find_upstream(provider, lccf).len > 0;
}

// Return the dialect a route endpoint speaks, as declared by the operator via the
// optional third arg of llm_proxy_route. Returns "openai" when the route exists but
// carries no explicit dialect (the OpenAI wire format is the documented default).
// Returns empty_str only when provider has no configured route at all.
fn find_route_dialect(provider: ngx_str_t, lccf: *llm_proxy_loc_conf) ngx_str_t {
    if (provider.len == 0) return empty_str;
    const p = core.slicify(u8, provider.data, provider.len);
    var i: usize = 0;
    while (i < lccf.routes_count) : (i += 1) {
        const route = &lccf.routes[i];
        if (route.provider.len == 0) continue;
        const rp = core.slicify(u8, route.provider.data, route.provider.len);
        if (std.mem.eql(u8, p, rp)) {
            return if (route.dialect.len > 0) route.dialect else ngx_string("openai");
        }
    }
    return empty_str; // no route configured for this provider
}

fn dialect_is(d: ngx_str_t, name: []const u8) bool {
    if (d.len == 0 or d.len != name.len) return false;
    return std.ascii.eqlIgnoreCase(core.slicify(u8, d.data, d.len), name);
}

fn dialect_is_supported(d: ngx_str_t) bool {
    return dialect_is(d, "openai") or dialect_is(d, "anthropic");
}

fn resolution_outcome_to_str(outcome: ngx_uint_t) ngx_str_t {
    return switch (outcome) {
        RESOLUTION_OUTCOME_AS_REQUESTED => ngx_string("as_requested"),
        RESOLUTION_OUTCOME_REPLACED_BY_POLICY => ngx_string("replaced_by_policy"),
        RESOLUTION_OUTCOME_FALLBACK_AFTER_FAILURE => ngx_string("fallback_after_failure"),
        RESOLUTION_OUTCOME_REJECTED_OUT_OF_SCOPE => ngx_string("rejected_out_of_scope"),
        RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE => ngx_string("rejected_unresolvable"),
        else => ngx_string("as_requested"),
    };
}

fn dialect_source_to_str(source: ngx_uint_t) ngx_str_t {
    return switch (source) {
        DIALECT_SOURCE_FIXED_INGRESS => ngx_string("fixed_ingress"),
        DIALECT_SOURCE_EXPLICIT => ngx_string("explicit"),
        else => ngx_string("inferred_shape"),
    };
}

fn find_provider_version(provider: ngx_str_t, lccf: *llm_proxy_loc_conf) ngx_str_t {
    if (provider.len == 0) return empty_str;
    const p = core.slicify(u8, provider.data, provider.len);
    var i: usize = 0;
    while (i < lccf.provider_versions_count) : (i += 1) {
        const pv = &lccf.provider_versions[i];
        if (pv.provider.len == 0) continue;
        const pvp = core.slicify(u8, pv.provider.data, pv.provider.len);
        if (std.mem.eql(u8, p, pvp)) return pv.version;
    }
    return empty_str;
}

fn header_matches_name(h: [*c]ngx_table_elt_t, key: ngx_str_t) bool {
    if (h.*.key.len != key.len) return false;
    return std.ascii.eqlIgnoreCase(
        core.slicify(u8, h.*.key.data, h.*.key.len),
        core.slicify(u8, key.data, key.len),
    );
}

fn refresh_known_request_header_slots(r: [*c]ngx_http_request_t) void {
    r.*.headers_in.host = null;
    r.*.headers_in.connection = null;
    r.*.headers_in.content_length = null;
    r.*.headers_in.content_type = null;
    r.*.headers_in.transfer_encoding = null;
    r.*.headers_in.authorization = null;

    var part = &r.*.headers_in.headers.part;
    while (true) {
        const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse {
            if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
            part = part.*.next;
            continue;
        };
        var i: usize = 0;
        while (i < part.*.nelts) : (i += 1) {
            const h = &hdrs[i];
            if (r.*.headers_in.host == null and header_matches_name(h, ngx_string("Host"))) {
                r.*.headers_in.host = h;
            } else if (r.*.headers_in.connection == null and header_matches_name(h, ngx_string("Connection"))) {
                r.*.headers_in.connection = h;
            } else if (r.*.headers_in.content_length == null and header_matches_name(h, ngx_string("Content-Length"))) {
                r.*.headers_in.content_length = h;
            } else if (r.*.headers_in.content_type == null and header_matches_name(h, ngx_string("Content-Type"))) {
                r.*.headers_in.content_type = h;
            } else if (r.*.headers_in.transfer_encoding == null and header_matches_name(h, ngx_string("Transfer-Encoding"))) {
                r.*.headers_in.transfer_encoding = h;
            } else if (r.*.headers_in.authorization == null and header_matches_name(h, authorization_header_name)) {
                r.*.headers_in.authorization = h;
            }
        }
        if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
        part = part.*.next;
    }
}

fn clear_request_header_slot(r: [*c]ngx_http_request_t, key_name: ngx_str_t) void {
    var found = false;
    var part = &r.*.headers_in.headers.part;
    while (true) {
        const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse {
            if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
            part = part.*.next;
            continue;
        };
        var dst: usize = 0;
        var src: usize = 0;
        while (src < part.*.nelts) : (src += 1) {
            const h = &hdrs[src];
            if (header_matches_name(h, key_name)) {
                found = true;
                continue;
            }
            if (dst != src) hdrs[dst] = hdrs[src];
            dst += 1;
        }
        part.*.nelts = @intCast(dst);
        if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
        part = part.*.next;
    }

    // Skip the expensive full-list refresh when no header was actually removed.
    if (!found) return;
    refresh_known_request_header_slots(r);
}

fn upsert_request_header(r: [*c]ngx_http_request_t, key_name: ngx_str_t, key_lowcase: ngx_str_t, value: ngx_str_t) bool {
    // Allocate the replacement first. If the pool is exhausted, leave the
    // caller's original header list untouched rather than stripping auth.
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    const new_h = headers.append() catch return false;
    new_h.*.hash = 1;
    new_h.*.key = key_name;
    new_h.*.value = value;
    new_h.*.lowcase_key = key_lowcase.data;

    // Remove any older headers with the same key, keeping the replacement we
    // just appended. Follow with a single refresh_known_request_header_slots.
    var part = &r.*.headers_in.headers.part;
    while (true) {
        const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse {
            if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
            part = part.*.next;
            continue;
        };
        var dst: usize = 0;
        var src: usize = 0;
        while (src < part.*.nelts) : (src += 1) {
            if (&hdrs[src] == new_h) {
                if (dst != src) hdrs[dst] = hdrs[src];
                dst += 1;
                continue;
            }
            if (header_matches_name(&hdrs[src], key_name)) continue;
            if (dst != src) hdrs[dst] = hdrs[src];
            dst += 1;
        }
        part.*.nelts = @intCast(dst);
        if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
        part = part.*.next;
    }

    refresh_known_request_header_slots(r);
    return true;
}

fn build_bearer_value(r: [*c]ngx_http_request_t, secret: ngx_str_t) ngx_str_t {
    const prefix = "Bearer ";
    const total = prefix.len + secret.len;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return empty_str;
    const p = core.castPtr(u8, raw) orelse return empty_str;
    @memcpy(p[0..prefix.len], prefix);
    @memcpy(p[prefix.len..total], core.slicify(u8, secret.data, secret.len));
    return ngx_str_t{ .data = p, .len = total };
}

fn suppress_http_debug_logging(r: [*c]ngx_http_request_t) void {
    const conn = r.*.connection orelse return;
    const lg = conn.*.log orelse return;
    lg.*.log_level &= ~@as(ngx_uint_t, log.NGX_LOG_DEBUG_HTTP);
}

fn apply_llm_auth_policy(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) ngx_int_t {
    const auth_lccf = core.castPtr(
        llm_auth_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_auth_module),
    ) orelse return NGX_OK;

    if (auth_lccf.*.enabled != 1) return NGX_OK;

    // Nginx's core proxy debug path dumps the fully assembled upstream request,
    // which would include provider auth bytes after mutation. Once llm-auth
    // owns upstream auth for the location, suppress HTTP debug logging for this
    // request so debug traces remain redact-safe.
    suppress_http_debug_logging(r);

    ctx.*.auth_failed = 1;
    const resolved = ngx_http_llm_auth_resolve(r);
    ctx.*.auth_fail_reason = resolved.fail_reason;

    // Strip client-supplied auth headers before forwarding to upstream.
    // upsert_request_header already calls clear internally for the header it sets,
    // so only pre-clear the OTHER header to avoid a redundant full-list scan.
    switch (resolved.mode) {
        auth_mode_bearer => {
            clear_request_header_slot(r, x_api_key_header_name);
            if (resolved.credential.len > 0) {
                const bearer = build_bearer_value(r, resolved.credential);
                if (bearer.len == 0) return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
                if (!upsert_request_header(r, authorization_header_name, authorization_header_lowcase, bearer)) {
                    return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
                }
            } else {
                clear_request_header_slot(r, authorization_header_name);
            }
        },
        auth_mode_x_api_key => {
            clear_request_header_slot(r, authorization_header_name);
            if (resolved.credential.len > 0) {
                if (!upsert_request_header(r, x_api_key_header_name, x_api_key_header_lowcase, resolved.credential)) {
                    return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
                }
            } else {
                clear_request_header_slot(r, x_api_key_header_name);
            }
        },
        else => {
            clear_request_header_slot(r, authorization_header_name);
            clear_request_header_slot(r, x_api_key_header_name);
        },
    }

    if (resolved.status.len == 0 or std.mem.eql(u8, core.slicify(u8, resolved.status.data, resolved.status.len), "resolved")) {
        ctx.*.auth_prepared = 1;
        ctx.*.auth_failed = 0;
        return NGX_OK;
    }

    if (resolved.fail_closed == 1) return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    return NGX_OK;
}

fn request_security_enabled(r: [*c]ngx_http_request_t) bool {
    const sec_lccf = core.castPtr(
        llm_security_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
    ) orelse return false;
    return sec_lccf.*.enabled == 1;
}

fn security_rejects_oversized_request(r: [*c]ngx_http_request_t) bool {
    const sec_lccf = core.castPtr(
        llm_security_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
    ) orelse return false;
    return sec_lccf.*.enabled == 1 and sec_lccf.*.reject_oversized_request == 1;
}

fn security_rejects_oversized_response(r: [*c]ngx_http_request_t) bool {
    const sec_lccf = core.castPtr(
        llm_security_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
    ) orelse return false;
    return sec_lccf.*.enabled == 1 and
        sec_lccf.*.inspect_response == 1 and
        sec_lccf.*.reject_oversized_response == 1;
}

fn is_json_content_type(raw: []const u8) bool {
    const semicolon = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const media_type = std.mem.trim(u8, raw[0..semicolon], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

// ── Phase 6: rate-limit header parsing ───────────────────────────────────────

// Parse OpenAI x-ratelimit-reset-tokens value into milliseconds.
// Accepts: "15ms", "1s", "1.5s", plain integers (assumed ms).
// Returns null on malformed input — caller leaves the variable unset.
fn parse_reset_tokens_ms(s: []const u8) ?ngx_uint_t {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.endsWith(u8, trimmed, "ms")) {
        return std.fmt.parseInt(ngx_uint_t, trimmed[0 .. trimmed.len - 2], 10) catch return null;
    }
    if (std.mem.endsWith(u8, trimmed, "s")) {
        const num_str = trimmed[0 .. trimmed.len - 1];
        if (std.fmt.parseInt(ngx_uint_t, num_str, 10)) |n| {
            return std.math.mul(ngx_uint_t, n, 1000) catch null;
        } else |_| {}
        if (std.fmt.parseFloat(f64, num_str)) |f| {
            const ms = @round(f * 1000.0);
            if (std.math.isFinite(ms) and ms >= 0.0 and ms <= @as(f64, @floatFromInt(std.math.maxInt(ngx_uint_t)))) {
                return @intFromFloat(ms);
            }
        } else |_| {}
        return null;
    }
    // Plain integer — assume ms.
    return std.fmt.parseInt(ngx_uint_t, trimmed, 10) catch return null;
}

// Parse a plain non-negative integer header value.
fn parse_uint_header(s: []const u8) ?ngx_uint_t {
    const trimmed = std.mem.trim(u8, s, " \t");
    return std.fmt.parseInt(ngx_uint_t, trimmed, 10) catch return null;
}

fn upsert_response_header(r: [*c]ngx_http_request_t, key_name: ngx_str_t, key_lowcase: ngx_str_t, value: ngx_str_t) void {
    var found = false;
    var part = &r.*.headers_out.headers.part;
    while (true) {
        const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse break;
        var i: usize = 0;
        while (i < part.*.nelts) : (i += 1) {
            const h = &hdrs[i];
            if (h.*.key.len == key_name.len and
                std.ascii.eqlIgnoreCase(
                    core.slicify(u8, h.*.key.data, h.*.key.len),
                    core.slicify(u8, key_name.data, key_name.len),
                ))
            {
                h.*.hash = 1;
                h.*.key = key_name;
                h.*.value = value;
                h.*.lowcase_key = key_lowcase.data;
                found = true;
            }
        }
        if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
        part = part.*.next;
    }

    if (!found) {
        var out = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
        if (out.append()) |h| {
            h.*.hash = 1;
            h.*.key = key_name;
            h.*.value = value;
            h.*.lowcase_key = key_lowcase.data;
        } else |_| {}
    }
}

// Scan upstream response headers, populate Phase 6 rate-limit ctx fields, and
// inject the parsed values as response headers.  Headers are injected directly
// into headers_out (not via add_header) because headers_filter runs before our
// filter in the runtime chain and would see empty variables.
// OpenAI: x-ratelimit-reset-tokens (ms/s suffix), x-ratelimit-remaining-*
// Anthropic: retry-after (seconds integer)
fn parse_ratelimit_headers(ctx: *LlmProxyCtx, r: [*c]ngx_http_request_t) void {
    // INVARIANT: effective_dialect must be populated before this call.
    // detect_fallback_outcome() updates effective_provider and effective_dialect
    // before the caller reaches this point; do not invoke parse_ratelimit_headers
    // before the effective endpoint is resolved, or rate-limit header dispatch
    // will silently skip provider-specific headers (both dialects will be false).
    const is_openai = dialect_is(ctx.effective_dialect, "openai");
    const is_anthropic = dialect_is(ctx.effective_dialect, "anthropic");

    // Bitmask: bit 0=reset, bit 1=remaining-tokens, bit 2=remaining-requests.
    // All three slots filled → stop scanning early (common case: no RL headers → full walk).
    const FOUND_ALL: u3 = 0b111;
    var found: u3 = 0;
    var part = &r.*.headers_out.headers.part;
    outer: while (true) {
        const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse {
            if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
            part = part.*.next;
            continue;
        };
        var i: usize = 0;
        while (i < part.*.nelts) : (i += 1) {
            if (found == FOUND_ALL) break :outer;
            const h = &hdrs[i];
            if (h.*.key.len == 0) continue;
            const key = core.slicify(u8, h.*.key.data, h.*.key.len);
            const val = core.slicify(u8, h.*.value.data, h.*.value.len);

            if (found & 0b001 == 0) {
                if (is_openai and std.ascii.eqlIgnoreCase(key, "x-ratelimit-reset-tokens")) {
                    if (parse_reset_tokens_ms(val)) |ms| {
                        ctx.reset_after_ms = ms;
                        ctx.reset_after_ms_valid = 1;
                        found |= 0b001;
                    }
                    continue;
                } else if (is_anthropic and std.ascii.eqlIgnoreCase(key, "retry-after")) {
                    if (parse_uint_header(val)) |secs| {
                        if (std.math.mul(ngx_uint_t, secs, 1000)) |ms| {
                            ctx.reset_after_ms = ms;
                            ctx.reset_after_ms_valid = 1;
                            found |= 0b001;
                        } else |_| {}
                    }
                    continue;
                }
            }

            if (found & 0b010 == 0 and std.ascii.eqlIgnoreCase(key, "x-ratelimit-remaining-tokens")) {
                if (parse_uint_header(val)) |n| {
                    ctx.ratelimit_remaining_tokens = n;
                    ctx.ratelimit_remaining_tokens_valid = 1;
                    found |= 0b010;
                }
                continue;
            }
            if (found & 0b100 == 0 and std.ascii.eqlIgnoreCase(key, "x-ratelimit-remaining-requests")) {
                if (parse_uint_header(val)) |n| {
                    ctx.ratelimit_remaining_requests = n;
                    ctx.ratelimit_remaining_requests_valid = 1;
                    found |= 0b100;
                }
            }
        }
        if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
        part = part.*.next;
    }

    // Inject parsed values as canonical response headers so downstream (and
    // tests) can observe them without depending on nginx variables evaluated
    // by add_header.
    if (ctx.reset_after_ms_valid == 1) {
        upsert_response_header(r, rl_reset_after_ms_name, rl_reset_after_ms_lowcase, uint_to_str(ctx.reset_after_ms, r));
    }
    if (ctx.ratelimit_remaining_tokens_valid == 1) {
        upsert_response_header(r, rl_remaining_tokens_name, rl_remaining_tokens_lowcase, uint_to_str(ctx.ratelimit_remaining_tokens, r));
    }
    if (ctx.ratelimit_remaining_requests_valid == 1) {
        upsert_response_header(r, rl_remaining_requests_name, rl_remaining_requests_lowcase, uint_to_str(ctx.ratelimit_remaining_requests, r));
    }
}

// ── Variable getters ──────────────────────────────────────────────────────────

fn set_var(v: [*c]ngx_http_variable_value_t, s: ngx_str_t) void {
    v.*.data = s.data;
    v.*.flags.len = @intCast(s.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = s.len == 0;
}

fn get_ctx(r: [*c]ngx_http_request_t) ?[*c]LlmProxyCtx {
    return core.castPtr(LlmProxyCtx, r.*.ctx[ngx_http_llm_proxy_module.ctx_index]);
}

fn get_observable_ctx(r: [*c]ngx_http_request_t) ?[*c]LlmProxyCtx {
    if (get_ctx(r)) |ctx| return ctx;
    // On the LOG-phase hot path r == r->main always; the subrequest
    // fallback is only needed for truly internal subrequests which
    // should not appear on llm-proxy-enabled locations.  Skip the
    // main-pointer dereference and comparison when there is no ctx.
    return null;
}

export fn ngx_http_llm_proxy_observe(r: [*c]ngx_http_request_t) callconv(.c) LlmProxyObservable {
    if (get_observable_ctx(r)) |ctx| {
        return .{
            .provider = ctx.*.provider,
            .model = ctx.*.model,
            .requested_provider = ctx.*.requested_provider,
            .requested_model = ctx.*.requested_model,
            .requested_dialect = ctx.*.requested_dialect,
            .effective_provider = ctx.*.effective_provider,
            .effective_model = ctx.*.effective_model,
            .effective_dialect = ctx.*.effective_dialect,
            .is_streaming = ctx.*.is_streaming,
            .body_parsed = ctx.*.body_parsed,
            .usage_extracted = ctx.*.usage_extracted,
            .response_is_error_shape = ctx.*.response_is_error_shape,
            .translation_happened = ctx.*.translation_happened,
            .replacement_happened = ctx.*.replacement_happened,
            .fallback_attempted = ctx.*.fallback_attempted,
            .resolution_outcome = ctx.*.resolution_outcome,
            .prompt_tokens = ctx.*.prompt_tokens,
            .completion_tokens = ctx.*.completion_tokens,
            .total_tokens = ctx.*.total_tokens,
            .cache_read_tokens = ctx.*.cache_read_tokens,
            .cache_create_tokens = ctx.*.cache_create_tokens,
        };
    }
    return .{
        .provider = empty_str,
        .model = empty_str,
        .requested_provider = empty_str,
        .requested_model = empty_str,
        .requested_dialect = empty_str,
        .effective_provider = empty_str,
        .effective_model = empty_str,
        .effective_dialect = empty_str,
        .is_streaming = 0,
        .body_parsed = 0,
        .usage_extracted = 0,
        .response_is_error_shape = 0,
        .translation_happened = 0,
        .replacement_happened = 0,
        .fallback_attempted = 0,
        .resolution_outcome = RESOLUTION_OUTCOME_AS_REQUESTED,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .cache_read_tokens = 0,
        .cache_create_tokens = 0,
    };
}

// Lightweight single-field accessors for cross-module LOG-phase use.
// Cheaper than ngx_http_llm_proxy_observe when only one field is needed — avoids
// filling the full ~216-byte LlmProxyObservable struct on every call.

export fn ngx_http_llm_proxy_resolution_outcome(r: [*c]ngx_http_request_t) callconv(.c) ngx_uint_t {
    return if (get_observable_ctx(r)) |ctx| ctx.*.resolution_outcome else 0;
}

export fn ngx_http_llm_proxy_effective_provider(r: [*c]ngx_http_request_t) callconv(.c) ngx_str_t {
    if (get_observable_ctx(r)) |ctx| {
        if (ctx.*.effective_provider.len > 0) return ctx.*.effective_provider;
        return ctx.*.provider;
    }
    return empty_str;
}

export fn ngx_http_llm_proxy_total_tokens(r: [*c]ngx_http_request_t) callconv(.c) ngx_uint_t {
    return if (get_observable_ctx(r)) |ctx| ctx.*.total_tokens else 0;
}

fn uint_to_str(val: ngx_uint_t, r: [*c]ngx_http_request_t) ngx_str_t {
    const SIZE = 20;
    const raw = core.ngx_pnalloc(r.*.pool, SIZE) orelse return empty_str;
    const p = core.castPtr(u8, raw) orelse return empty_str;
    const s = std.fmt.bufPrint(p[0..SIZE], "{d}", .{val}) catch return empty_str;
    return ngx_str_t{ .len = s.len, .data = p };
}

fn fallback_reason_to_str(reason: ngx_uint_t) ngx_str_t {
    return switch (reason) {
        FALLBACK_REASON_CONNECT_ERROR => ngx_string("connect_error"),
        FALLBACK_REASON_TRANSPORT_TIMEOUT => ngx_string("transport_timeout"),
        FALLBACK_REASON_RATE_LIMITED => ngx_string("rate_limited"),
        FALLBACK_REASON_UPSTREAM_5XX => ngx_string("upstream_5xx"),
        else => ngx_string("none"),
    };
}

fn failure_class_to_str(class: ngx_uint_t) ngx_str_t {
    return switch (class) {
        FAILURE_CLASS_CONNECT_ERROR => ngx_string("connect_error"),
        FAILURE_CLASS_TRANSPORT_TIMEOUT => ngx_string("transport_timeout"),
        FAILURE_CLASS_RATE_LIMITED => ngx_string("rate_limited"),
        FAILURE_CLASS_UPSTREAM_5XX => ngx_string("upstream_5xx"),
        FAILURE_CLASS_SEMANTIC_ERROR => ngx_string("semantic_error"),
        else => ngx_string("none"),
    };
}

fn fallback_reason_to_failure_class(reason: ngx_uint_t) ngx_uint_t {
    return switch (reason) {
        FALLBACK_REASON_CONNECT_ERROR => FAILURE_CLASS_CONNECT_ERROR,
        FALLBACK_REASON_TRANSPORT_TIMEOUT => FAILURE_CLASS_TRANSPORT_TIMEOUT,
        FALLBACK_REASON_RATE_LIMITED => FAILURE_CLASS_RATE_LIMITED,
        FALLBACK_REASON_UPSTREAM_5XX => FAILURE_CLASS_UPSTREAM_5XX,
        else => FAILURE_CLASS_NONE,
    };
}

fn infer_failure_reason_from_upstream_states(r: [*c]ngx_http_request_t) ngx_uint_t {
    if (r.*.upstream == null) return FALLBACK_REASON_NONE;
    const us = r.*.upstream_states;
    if (us == null or us.*.nelts == 0) return FALLBACK_REASON_NONE;
    const states = core.castPtr(http.ngx_http_upstream_state_t, us.*.elts) orelse return FALLBACK_REASON_NONE;
    const first = states[0];
    const unset_msec = std.math.maxInt(@TypeOf(first.connect_time));
    const connect_unset = first.connect_time == unset_msec;
    const header_unset = first.header_time == unset_msec;
    const no_bytes = first.bytes_received == 0;

    return if (first.status == 429) FALLBACK_REASON_RATE_LIMITED else if (first.status == 0) (if (connect_unset) FALLBACK_REASON_CONNECT_ERROR else FALLBACK_REASON_TRANSPORT_TIMEOUT) else if (first.status >= 500 and first.status < 600) blk: {
        if (no_bytes and header_unset) {
            if (connect_unset) break :blk FALLBACK_REASON_CONNECT_ERROR;
            if (first.status == 504) break :blk FALLBACK_REASON_TRANSPORT_TIMEOUT;
        }
        break :blk FALLBACK_REASON_UPSTREAM_5XX;
    } else FALLBACK_REASON_NONE;
}

fn classify_upstream_failure(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) void {
    if (ctx.*.failure_class != FAILURE_CLASS_NONE) return;

    const inferred = infer_failure_reason_from_upstream_states(r);
    if (inferred != FALLBACK_REASON_NONE) {
        ctx.*.failure_class = fallback_reason_to_failure_class(inferred);
        return;
    }

    const status = r.*.headers_out.status;
    if (status == 429) {
        ctx.*.failure_class = FAILURE_CLASS_RATE_LIMITED;
    } else if (status >= 500 and status < 600) {
        ctx.*.failure_class = FAILURE_CLASS_UPSTREAM_5XX;
    } else if (status >= 400 and status < 500) {
        ctx.*.failure_class = FAILURE_CLASS_SEMANTIC_ERROR;
    }
}

fn var_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.provider else empty_str);
    return NGX_OK;
}

fn var_model(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.model else empty_str);
    return NGX_OK;
}

fn var_streaming(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.is_streaming == 1) ngx_string("1") else ngx_string("0"))
    else
        ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_upstream(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.upstream else empty_str);
    return NGX_OK;
}

fn var_provider_host(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.provider_host else empty_str);
    return NGX_OK;
}

fn var_provider_version(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse {
        set_var(v, empty_str);
        return NGX_OK;
    };
    const provider = if (get_observable_ctx(r)) |ctx| ctx.*.provider else empty_str;
    set_var(v, find_provider_version(provider, lccf));
    return NGX_OK;
}

fn var_prompt_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.usage_extracted == 1) uint_to_str(ctx.*.prompt_tokens, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

fn var_completion_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.usage_extracted == 1) uint_to_str(ctx.*.completion_tokens, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

fn var_total_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.usage_extracted == 1) uint_to_str(ctx.*.total_tokens, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

// Phase 6: rate-limit variable getters.  Populated in header filter, so they
// are available to add_header (unlike the body-filter token variables).

fn var_reset_after_ms(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.reset_after_ms_valid == 1) uint_to_str(ctx.*.reset_after_ms, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

fn var_ratelimit_remaining_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.ratelimit_remaining_tokens_valid == 1) uint_to_str(ctx.*.ratelimit_remaining_tokens, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

fn var_ratelimit_remaining_requests(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.ratelimit_remaining_requests_valid == 1) uint_to_str(ctx.*.ratelimit_remaining_requests, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

// Metrics-facing binary flag variables.  These expose internal ctx fields that
// are not yet nginx variables but are listed in the llm-metrics cross-module
// contract (body_parsed, usage_extracted, response_is_error_shape).
// Getters are O(1) field reads; they have no hot-path impact.

fn var_body_parsed(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.body_parsed == 1) ngx_string("1") else ngx_string("0"))
    else
        ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_usage_extracted(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.usage_extracted == 1) ngx_string("1") else ngx_string("0"))
    else
        ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_response_is_error(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.response_is_error_shape == 1) ngx_string("1") else ngx_string("0"))
    else
        ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

// Fallback outcome variable getters (Phase 4 llm-fallback integration).

fn var_fallback_attempted(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.fallback_attempted == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_fallback_suppressed(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.fallback_suppressed == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_fallback_effective_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.fallback_effective_provider else empty_str);
    return NGX_OK;
}

fn var_fallback_primary_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.fallback_primary_provider else empty_str);
    return NGX_OK;
}

fn var_fallback_reason(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| fallback_reason_to_str(ctx.*.fallback_reason) else ngx_string("none");
    set_var(v, s);
    return NGX_OK;
}

fn var_fallback_policy_allowed(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.fallback_policy_allowed == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_fallback_policy_mismatch(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.fallback_policy_mismatch == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_fallback_attempt_count(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| uint_to_str(ctx.*.fallback_attempt_count, r) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_fallback_suppressed_reason(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.fallback_suppressed_reason.len > 0) ctx.*.fallback_suppressed_reason else ngx_string("none")) else ngx_string("none");
    set_var(v, s);
    return NGX_OK;
}

fn var_auth_prepared(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.auth_prepared == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_auth_failed(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| blk: {
        const failed = ctx.*.auth_prepared != 1 and (ctx.*.auth_failed == 1 or ctx.*.auth_fail_reason.len > 0);
        break :blk if (failed) ngx_string("1") else ngx_string("0");
    } else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_auth_fail_reason(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.auth_fail_reason.len > 0) ctx.*.auth_fail_reason else ngx_string("none")) else ngx_string("none");
    set_var(v, s);
    return NGX_OK;
}

fn var_failure_class(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| failure_class_to_str(ctx.*.failure_class) else ngx_string("none");
    set_var(v, s);
    return NGX_OK;
}

fn var_replay_safe(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.replay_safe == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

fn var_response_started(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx| (if (ctx.*.response_started == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

// ── Phase 12 variable getters ─────────────────────────────────────────────────

fn var_requested_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.requested_provider else empty_str);
    return NGX_OK;
}

fn var_requested_model(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.requested_model else empty_str);
    return NGX_OK;
}

fn var_requested_dialect(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.requested_dialect else empty_str);
    return NGX_OK;
}

fn var_requested_dialect_source(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| dialect_source_to_str(ctx.*.requested_dialect_source) else empty_str);
    return NGX_OK;
}

fn var_effective_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.effective_provider else empty_str);
    return NGX_OK;
}

fn var_effective_model(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.effective_model else empty_str);
    return NGX_OK;
}

fn var_effective_dialect(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| ctx.*.effective_dialect else empty_str);
    return NGX_OK;
}

fn var_resolution_outcome(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx| resolution_outcome_to_str(ctx.*.resolution_outcome) else empty_str);
    return NGX_OK;
}

fn var_translation_happened(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.translation_happened == 1) ngx_string("1") else ngx_string("0"))
    else
        ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

// Phase 14 (Milestone 2 Target 3): replacement observability.
fn var_replacement_happened(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const s = if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.replacement_happened == 1) ngx_string("1") else ngx_string("0"))
    else
        ngx_string("0");
    set_var(v, s);
    return NGX_OK;
}

// Target 9: cached-token variable getters.
fn var_cache_read_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.usage_extracted == 1) uint_to_str(ctx.*.cache_read_tokens, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

fn var_cache_create_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_observable_ctx(r)) |ctx|
        (if (ctx.*.usage_extracted == 1) uint_to_str(ctx.*.cache_create_tokens, r) else empty_str)
    else
        empty_str);
    return NGX_OK;
}

// ── Body extraction ───────────────────────────────────────────────────────────

fn extract_from_body(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, lccf: *llm_proxy_loc_conf, body: ngx_str_t) void {
    // Target 7/22: fast path for simple requests without a provider override.
    // Scans for "model", "stream", and messages content shape without full cJSON parse.
    // Safe for dialect_mode=fixed (ingress dialect from config) and for dialect_mode=infer
    // (scanner proves body is OpenAI-shaped: no Anthropic-only fields, no content-block arrays).
    if (lccf.dialect_mode == DIALECT_MODE_FIXED or lccf.dialect_mode == DIALECT_MODE_INFER) {
        const body_slice = core.slicify(u8, body.data, body.len);
        var fast_model = empty_str;
        var fast_stream: ngx_flag_t = 0;
        if (body_scan_routing_fields(body_slice, &fast_model, &fast_stream)) {
            ctx.model = fast_model;
            ctx.is_streaming = fast_stream;
            ctx.requested_model = ctx.model;
            ctx.requested_provider = empty_str;
            if (lccf.dialect_mode == DIALECT_MODE_FIXED and lccf.ingress_dialect.len > 0) {
                ctx.requested_dialect = lccf.ingress_dialect;
                ctx.requested_dialect_source = DIALECT_SOURCE_FIXED_INGRESS;
            } else {
                ctx.requested_dialect = ngx_string("openai");
                ctx.requested_dialect_source = DIALECT_SOURCE_INFERRED_SHAPE;
            }
            const catalog_provider = resolve_provider_from_catalog(ctx.model, lccf);
            if (catalog_provider.len > 0 and has_route_for_provider(catalog_provider, lccf)) {
                ctx.provider = catalog_provider;
                ctx.resolution_outcome = RESOLUTION_OUTCOME_AS_REQUESTED;
            } else if (catalog_provider.len > 0) {
                ctx.provider = catalog_provider;
                ctx.resolution_outcome = RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE;
            } else if (lccf.model_patterns_count > 0) {
                ctx.provider = if (lccf.default_provider.len > 0) lccf.default_provider else empty_str;
                ctx.resolution_outcome = RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE;
            } else {
                ctx.provider = if (lccf.default_provider.len > 0) lccf.default_provider else empty_str;
                ctx.resolution_outcome = RESOLUTION_OUTCOME_AS_REQUESTED;
            }
            ctx.upstream = find_upstream(ctx.provider, lccf);
            ctx.provider_host = provider_to_host(ctx.provider);
            ctx.body_parsed = 1;
            ctx.effective_provider = ctx.provider;
            ctx.effective_model = ctx.model;
            ctx.effective_dialect = find_route_dialect(ctx.provider, lccf);
            return;
        }
    }

    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body) catch {
        classify_default(ctx, lccf);
        return;
    };

    if (cjson.cJSON_GetObjectItem(json, "model")) |item| {
        if (CJSON.stringValue(item)) |s| ctx.model = s;
    }
    if (cjson.cJSON_GetObjectItem(json, "stream")) |item| {
        ctx.is_streaming = if (cjson.cJSON_IsTrue(item) == 1) 1 else 0;
    }

    // Phase 12: capture explicit provider field from body if present.
    if (cjson.cJSON_GetObjectItem(json, "provider")) |item| {
        if (CJSON.stringValue(item)) |s| ctx.requested_provider = s;
    }

    // Phase 12: record requested_model before resolution.
    ctx.requested_model = ctx.model;

    // Phase 12 / Target 10: determine requested dialect.
    // Priority: (1) fixed ingress contract, (2) conservative body-shape inference.
    if (lccf.dialect_mode == DIALECT_MODE_FIXED and lccf.ingress_dialect.len > 0) {
        ctx.requested_dialect = lccf.ingress_dialect;
        ctx.requested_dialect_source = DIALECT_SOURCE_FIXED_INGRESS;
    } else {
        if (cjson.cJSON_GetObjectItem(json, "dialect")) |dialect_item| {
            if (CJSON.stringValue(dialect_item)) |dialect_s| {
                if (dialect_is_supported(dialect_s)) {
                    ctx.requested_dialect = dialect_s;
                    ctx.requested_dialect_source = DIALECT_SOURCE_EXPLICIT;
                }
            }
        }
        if (ctx.requested_dialect.len == 0) {
            // Target 10: conservative body-shape inference.
            // Infer Anthropic when the body contains Anthropic-only fields (top-level system,
            // anthropic_version, top_k, or content-block arrays in messages).
            // Ambiguous shapes fall back to OpenAI for backward compatibility.
            const inferred = infer_request_dialect(json);
            ctx.requested_dialect = if (std.mem.eql(u8, inferred, "anthropic"))
                ngx_string("anthropic")
            else
                ngx_string("openai");
            ctx.requested_dialect_source = DIALECT_SOURCE_INFERRED_SHAPE;
        }
    }

    // Phase 12: resolve provider.
    // When the client specified an explicit provider, honour it if we have a route for it.
    // Otherwise fall through to catalog resolution from the model name.
    if (ctx.requested_provider.len > 0) {
        const client_upstream = find_upstream(ctx.requested_provider, lccf);
        if (client_upstream.len > 0) {
            // Client-specified provider is in scope.
            ctx.provider = ctx.requested_provider;
            ctx.upstream = client_upstream;
            ctx.provider_host = provider_to_host(ctx.provider);
            ctx.body_parsed = 1;
            ctx.effective_provider = ctx.provider;
            ctx.effective_model = ctx.model;
            ctx.effective_dialect = find_route_dialect(ctx.provider, lccf);
            ctx.resolution_outcome = RESOLUTION_OUTCOME_AS_REQUESTED;
            return;
        }
        // Requested provider has no route: out-of-scope — do NOT silently default.
        ctx.provider = ctx.requested_provider; // preserve requested for observability
        ctx.upstream = empty_str;
        ctx.provider_host = empty_str;
        ctx.body_parsed = 1;
        ctx.effective_provider = empty_str;
        ctx.effective_model = ctx.model;
        ctx.effective_dialect = empty_str;
        ctx.resolution_outcome = RESOLUTION_OUTCOME_REJECTED_OUT_OF_SCOPE;
        return;
    }

    // Model-only path: resolve provider from catalog.
    const catalog_provider = resolve_provider_from_catalog(ctx.model, lccf);
    if (catalog_provider.len > 0 and has_route_for_provider(catalog_provider, lccf)) {
        ctx.provider = catalog_provider;
        ctx.resolution_outcome = RESOLUTION_OUTCOME_AS_REQUESTED;
    } else if (catalog_provider.len > 0) {
        // Catalog matched, but the matched provider has no route. Treat as
        // operator-unresolvable rather than letting proxy_pass fail later.
        ctx.provider = catalog_provider;
        ctx.resolution_outcome = RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE;
    } else if (lccf.model_patterns_count > 0) {
        // Operator catalog configured but model not found → unresolvable.
        // Route to default provider for transport but mark outcome explicitly.
        ctx.provider = if (lccf.default_provider.len > 0) lccf.default_provider else empty_str;
        ctx.resolution_outcome = RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE;
    } else {
        // No operator catalog: model not recognised → use default (built-in backward-compat behaviour).
        ctx.provider = if (lccf.default_provider.len > 0) lccf.default_provider else empty_str;
        ctx.resolution_outcome = if (ctx.model.len == 0 or catalog_provider.len == 0)
            RESOLUTION_OUTCOME_AS_REQUESTED // model absent or unknown; default is expected
        else
            RESOLUTION_OUTCOME_AS_REQUESTED;
    }

    ctx.upstream = find_upstream(ctx.provider, lccf);
    ctx.provider_host = provider_to_host(ctx.provider);
    ctx.body_parsed = 1;
    ctx.effective_provider = ctx.provider;
    ctx.effective_model = ctx.model;
    ctx.effective_dialect = find_route_dialect(ctx.provider, lccf);
}

fn classify_default(ctx: *LlmProxyCtx, lccf: *llm_proxy_loc_conf) void {
    ctx.provider = lccf.default_provider;
    ctx.upstream = find_upstream(ctx.provider, lccf);
    ctx.provider_host = provider_to_host(ctx.provider);
    // Phase 12: populate requested/effective fields for the default/unparsed path.
    if (lccf.dialect_mode == DIALECT_MODE_FIXED and lccf.ingress_dialect.len > 0) {
        ctx.requested_dialect = lccf.ingress_dialect;
        ctx.requested_dialect_source = DIALECT_SOURCE_FIXED_INGRESS;
    }
    // requested_model stays empty; body_parsed stays 0 — body was not classified from JSON.
    ctx.effective_provider = ctx.provider;
    ctx.effective_model = ctx.model;
    ctx.effective_dialect = find_route_dialect(ctx.provider, lccf);
    ctx.resolution_outcome = RESOLUTION_OUTCOME_AS_REQUESTED;
}

fn request_body_chain_size(cl: [*c]buf.ngx_chain_t) ?usize {
    var total: usize = 0;
    var chain = cl;
    while (chain != core.nullptr(buf.ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(buf.ngx_buf_t) or buf.ngx_buf_special(b)) continue;

        const chunk_len = buf.ngx_buf_size(b);
        if (chunk_len < 0) return null;

        total = std.math.add(usize, total, @intCast(chunk_len)) catch return null;
    }
    return total;
}

fn copy_request_body_chain(r: [*c]ngx_http_request_t, cl: [*c]buf.ngx_chain_t) ?ngx_str_t {
    const total = request_body_chain_size(cl) orelse return null;
    if (total == 0) return empty_str;

    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const out = core.castPtr(u8, raw) orelse return null;

    var chain = cl;
    var offset: usize = 0;
    while (chain != core.nullptr(buf.ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(buf.ngx_buf_t) or buf.ngx_buf_special(b)) continue;

        const chunk_len_off = buf.ngx_buf_size(b);
        if (chunk_len_off < 0) return null;
        const chunk_len: usize = @intCast(chunk_len_off);
        if (chunk_len == 0) continue;

        if (buf.ngx_buf_in_memory_only(b)) {
            @memcpy(out[offset .. offset + chunk_len], core.slicify(u8, b.*.pos, chunk_len));
            offset += chunk_len;
            continue;
        }

        if (b.*.flags.in_file and b.*.file != core.nullptr(ngx.file.ngx_file_t)) {
            const read_len = ngx.file.ngx_read_file(b.*.file, out + offset, chunk_len, b.*.file_pos);
            if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != chunk_len) return null;
            offset += chunk_len;
            continue;
        }

        return null;
    }

    return ngx_str_t{ .len = offset, .data = out };
}

fn request_body_content(r: [*c]ngx_http_request_t) ?ngx_str_t {
    if (r.*.request_body == core.nullptr(http.ngx_http_request_body_t)) return null;
    if (r.*.request_body.*.bufs == core.nullptr(buf.ngx_chain_t)) return null;
    return copy_request_body_chain(r, r.*.request_body.*.bufs);
}

// ── Phase 3: request body translation ────────────────────────────────────────

fn append_text_segment(r: [*c]ngx_http_request_t, current: ngx_str_t, next: ngx_str_t) ?ngx_str_t {
    if (next.len == 0) return current;
    if (current.len == 0) return next;

    const sep = "\n\n";
    const total = current.len + sep.len + next.len;
    // Allocate one extra byte for a NUL terminator. The result is handed to
    // cJSON_AddStringToObject (and other strlen-based consumers) which read up to
    // the first 0 byte; without the terminator strlen runs past the buffer into
    // adjacent pool memory — a heap over-read that leaks bytes into the rewritten
    // payload and can fault at a pool/page boundary. The reported .len excludes it.
    const raw = core.ngx_pnalloc(r.*.pool, total + 1) orelse return null;
    const out = core.castPtr(u8, raw) orelse return null;

    @memcpy(out[0..current.len], core.slicify(u8, current.data, current.len));
    @memcpy(out[current.len .. current.len + sep.len], sep);
    @memcpy(out[current.len + sep.len .. total], core.slicify(u8, next.data, next.len));
    out[total] = 0;
    return ngx_str_t{ .len = total, .data = out };
}

fn extract_content_text(r: [*c]ngx_http_request_t, content_item: [*c]cjson.cJSON) ngx_str_t {
    if (cjson.cJSON_IsString(content_item) == 1) {
        return CJSON.stringValue(content_item) orelse empty_str;
    }
    if (cjson.cJSON_IsArray(content_item) == 1) {
        var text: ngx_str_t = empty_str;
        var pit = CJSON.Iterator.init(content_item);
        while (pit.next()) |part| {
            if (cjson.cJSON_GetObjectItem(part, "type")) |tp| {
                if (CJSON.stringValue(tp)) |tp_str| {
                    if (std.mem.eql(u8, core.slicify(u8, tp_str.data, tp_str.len), "text")) {
                        if (cjson.cJSON_GetObjectItem(part, "text")) |txt| {
                            if (cjson.cJSON_IsString(txt) == 1) {
                                const segment = CJSON.stringValue(txt) orelse empty_str;
                                text = append_text_segment(r, text, segment) orelse return empty_str;
                            }
                        }
                    }
                }
            }
        }
        return text;
    }
    return empty_str;
}

fn content_blocks_are_text_only(content_item: [*c]cjson.cJSON) bool {
    if (cjson.cJSON_IsString(content_item) == 1) return true;
    if (cjson.cJSON_IsArray(content_item) != 1) return false;

    var block = content_item.*.child;
    while (block != core.nullptr(cjson.cJSON)) : (block = block.*.next) {
        if (cjson.cJSON_IsObject(block) != 1) return false;
        const tp = cjson.cJSON_GetObjectItem(block, "type") orelse return false;
        const tp_s = CJSON.stringValue(tp) orelse return false;
        if (!std.mem.eql(u8, core.slicify(u8, tp_s.data, tp_s.len), "text")) return false;
        const txt = cjson.cJSON_GetObjectItem(block, "text") orelse return false;
        if (cjson.cJSON_IsString(txt) != 1) return false;
    }
    return true;
}

fn ensure_provider_request_headers(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, lccf: *llm_proxy_loc_conf) void {
    if (dialect_is(ctx.effective_dialect, "anthropic")) {
        const version = find_provider_version(ctx.provider, lccf);
        if (version.len == 0) return;
        _ = upsert_request_header(r, ngx_string("anthropic-version"), ngx_string("anthropic-version"), version);
    }
}

// Replace r->request_body->bufs with new_body and update content-length fields.
// Returns true on success; ctx.request_rewritten is set to 1.
fn replace_request_body(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, new_body: ngx_str_t) bool {
    // Allocate a zero-initialized sentinel chain link.
    const sentinel = core.ngz_pcalloc_c(buf.ngx_chain_t, r.*.pool) orelse return false;

    // Append the new body as a single chain link after the sentinel.
    var nc = buf.NChain.init(r.*.pool);
    const cl = nc.allocStr(new_body, sentinel) catch return false;

    // Mark as final buffer so downstream filters know the chain is complete.
    cl.*.buf.*.flags.last_buf = true;
    cl.*.buf.*.flags.last_in_chain = true;

    // Replace the request body chain (sentinel.next == cl).
    r.*.request_body.*.bufs = sentinel.*.next;

    // Update the parsed content-length so proxy_pass sends the correct header.
    r.*.headers_in.content_length_n = @intCast(new_body.len);
    // Clear the chunked flag; the body is now fixed-length.
    r.*.headers_in.flags.chunked = false;

    // Also update the Content-Length header string value if the header exists,
    // so proxy_pass_request_headers forwards the correct value.
    if (core.nonNullPtr(ngx_table_elt_t, r.*.headers_in.content_length)) |cl_hdr| {
        const SIZE = 20;
        if (core.ngx_pnalloc(r.*.pool, SIZE)) |raw| {
            if (core.castPtr(u8, raw)) |p| {
                if (std.fmt.bufPrint(p[0..SIZE], "{d}", .{new_body.len}) catch null) |s| {
                    cl_hdr.*.value.data = p;
                    cl_hdr.*.value.len = s.len;
                }
            }
        }
    }

    ctx.request_rewritten = 1;
    return true;
}

// Translate an OpenAI-format request body to Anthropic format in place.
// - Extracts system messages and promotes content to top-level "system" field.
// - Removes system entries from the messages array.
// - Injects "max_tokens" if absent.
// Returns true if the body was rewritten; false means pass-through (body unchanged).
fn rewrite_openai_to_anthropic(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, body: ngx_str_t) bool {
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body) catch {
        ctx.request_translation_skipped = 1;
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: Anthropic translation: failed to parse request body, passing through", .{});
        return false;
    };

    // messages must be a JSON array; malformed bodies pass through unmodified.
    const messages = cjson.cJSON_GetObjectItem(json, "messages") orelse {
        ctx.request_translation_skipped = 1;
        return false;
    };
    if (cjson.cJSON_IsArray(messages) != 1) {
        ctx.request_translation_skipped = 1;
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: Anthropic translation: messages is not an array, passing through", .{});
        return false;
    }

    // Collect any existing top-level system field so translation does not drop it.
    var system_text: ngx_str_t = empty_str;
    if (cjson.cJSON_GetObjectItem(json, "system")) |system_item| {
        if (content_blocks_are_text_only(system_item)) {
            system_text = extract_content_text(r, system_item);
            cjson.cJSON_DeleteItemFromObject(json, "system", &cj.alloc);
        } else {
            ctx.request_translation_skipped = 1;
            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: Anthropic translation: existing system field is not string/array, passing through", .{});
            return false;
        }
    }

    // Walk messages, collect all system message content, detach all system entries.
    var curr: [*c]cjson.cJSON = messages.*.child;
    while (curr != core.nullptr(cjson.cJSON)) {
        const next_node = curr.*.next;
        if (cjson.cJSON_GetObjectItem(curr, "content")) |content_item| {
            if (!content_blocks_are_text_only(content_item)) {
                ctx.request_translation_skipped = 1;
                log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: Anthropic translation: non-text content block, passing through", .{});
                return false;
            }
        }
        const role_item = cjson.cJSON_GetObjectItem(curr, "role");
        if (role_item != core.nullptr(cjson.cJSON)) {
            if (CJSON.stringValue(role_item)) |role_str| {
                if (std.mem.eql(u8, core.slicify(u8, role_str.data, role_str.len), "system")) {
                    if (cjson.cJSON_GetObjectItem(curr, "content")) |content_item| {
                        const extracted = extract_content_text(r, content_item);
                        system_text = append_text_segment(r, system_text, extracted) orelse system_text;
                    }
                    // Detach (no free — pool owns the memory).
                    _ = cjson.cJSON_DetachItemViaPointer(messages, curr);
                }
            }
        }
        curr = next_node;
    }

    // Promote system content to top-level "system" field.
    if (system_text.len > 0) {
        _ = cjson.cJSON_AddStringToObject(json, "system", system_text.data, &cj.alloc);
    }

    // Anthropic requires max_tokens; inject a safe default when absent.
    if (cjson.cJSON_GetObjectItem(json, "max_tokens") == core.nullptr(cjson.cJSON)) {
        _ = cjson.cJSON_AddNumberToObject(json, "max_tokens", 4096, &cj.alloc);
    }

    // Re-encode the modified tree.
    const new_body = cj.encode(json) catch {
        ctx.request_translation_skipped = 1;
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: Anthropic translation: failed to encode rewritten body, passing through", .{});
        return false;
    };

    return replace_request_body(r, ctx, new_body);
}

// Translate an Anthropic-format request body to OpenAI format in place.
// - Promotes top-level "system" to a leading {"role":"system","content":"..."} message.
// - Flattens messages[].content text-block arrays to string content.
// - Drops Anthropic-only fields: anthropic_version, top_k.
// - Non-text content blocks cause pass-through (request_translation_skipped=1).
// Returns true if the body was rewritten; false means pass-through (body unchanged).
fn rewrite_anthropic_to_openai(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, body: ngx_str_t) bool {
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body) catch {
        ctx.request_translation_skipped = 1;
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: failed to parse request body, passing through", .{});
        return false;
    };

    const messages = cjson.cJSON_GetObjectItem(json, "messages") orelse {
        ctx.request_translation_skipped = 1;
        return false;
    };
    if (cjson.cJSON_IsArray(messages) != 1) {
        ctx.request_translation_skipped = 1;
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: messages is not an array, passing through", .{});
        return false;
    }

    // Extract top-level system field.
    var system_text: ngx_str_t = empty_str;
    if (cjson.cJSON_GetObjectItem(json, "system")) |system_item| {
        if (cjson.cJSON_IsString(system_item) == 1) {
            system_text = CJSON.stringValue(system_item) orelse empty_str;
        } else if (cjson.cJSON_IsArray(system_item) == 1) {
            system_text = extract_anthropic_content_text(r, system_item);
        } else {
            ctx.request_translation_skipped = 1;
            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: unsupported system field shape, passing through", .{});
            return false;
        }
    }

    // Walk messages and flatten content text-block arrays to strings.
    // Single validating pass: validate each block and extract the text in one traversal.
    // Bail out on non-text content blocks to avoid lossy translation.
    var curr: [*c]cjson.cJSON = messages.*.child;
    while (curr != core.nullptr(cjson.cJSON)) : (curr = curr.*.next) {
        if (cjson.cJSON_GetObjectItem(curr, "content")) |content| {
            if (cjson.cJSON_IsArray(content) == 1) {
                var combined: ngx_str_t = empty_str;
                var block = content.*.child;
                while (block != core.nullptr(cjson.cJSON)) : (block = block.*.next) {
                    if (cjson.cJSON_IsObject(block) != 1) {
                        ctx.request_translation_skipped = 1;
                        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: malformed content block, passing through", .{});
                        return false;
                    }
                    const tp = cjson.cJSON_GetObjectItem(block, "type") orelse {
                        ctx.request_translation_skipped = 1;
                        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: content block missing type, passing through", .{});
                        return false;
                    };
                    const tp_s = CJSON.stringValue(tp) orelse {
                        ctx.request_translation_skipped = 1;
                        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: content block type is not a string, passing through", .{});
                        return false;
                    };
                    if (!std.mem.eql(u8, core.slicify(u8, tp_s.data, tp_s.len), "text")) {
                        ctx.request_translation_skipped = 1;
                        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: non-text content block, passing through", .{});
                        return false;
                    }
                    const txt = cjson.cJSON_GetObjectItem(block, "text") orelse {
                        ctx.request_translation_skipped = 1;
                        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: text block missing text, passing through", .{});
                        return false;
                    };
                    if (cjson.cJSON_IsString(txt) != 1) {
                        ctx.request_translation_skipped = 1;
                        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: text block text is not a string, passing through", .{});
                        return false;
                    }
                    // Validated: append this text block's content to the combined string.
                    const tv = CJSON.stringValue(txt) orelse empty_str;
                    combined = append_text_segment(r, combined, tv) orelse combined;
                }
                cjson.cJSON_DeleteItemFromObject(curr, "content", &cj.alloc);
                _ = cjson.cJSON_AddStringToObject(curr, "content", combined.data, &cj.alloc);
            }
            // String content is already OpenAI-compatible — leave it.
        }
    }

    // Prepend a system message if a top-level system field was present.
    if (system_text.len > 0) {
        const sys_msg = cjson.cJSON_CreateObject(&cj.alloc) orelse {
            ctx.request_translation_skipped = 1;
            return false;
        };
        _ = cjson.cJSON_AddStringToObject(sys_msg, "role", "system", &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(sys_msg, "content", system_text.data, &cj.alloc);
        _ = cjson.cJSON_InsertItemInArray(messages, 0, sys_msg);
    }

    // Drop Anthropic-only request fields before sending to an OpenAI-compatible endpoint.
    cjson.cJSON_DeleteItemFromObject(json, "system", &cj.alloc);
    cjson.cJSON_DeleteItemFromObject(json, "anthropic_version", &cj.alloc);
    cjson.cJSON_DeleteItemFromObject(json, "top_k", &cj.alloc);

    const new_body = cj.encode(json) catch {
        ctx.request_translation_skipped = 1;
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI translation: failed to encode rewritten body, passing through", .{});
        return false;
    };

    return replace_request_body(r, ctx, new_body);
}

// Inject `stream_options: {"include_usage": true}` into an OpenAI streaming request.
// This is required for OpenAI to emit usage stats in the final SSE chunk.
// Returns true if the body was rewritten; false means pass-through.
fn inject_openai_stream_usage_option(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, body: ngx_str_t) bool {
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body) catch {
        ctx.request_translation_skipped = 1;
        return false;
    };

    if (cjson.cJSON_GetObjectItem(json, "stream_options")) |opts| {
        // stream_options already exists.
        if (cjson.cJSON_IsObject(opts) != 1) {
            ctx.request_translation_skipped = 1;
            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI usage injection: stream_options is not an object, passing through", .{});
            return false;
        }
        if (cjson.cJSON_GetObjectItem(opts, "include_usage") != core.nullptr(cjson.cJSON)) {
            // include_usage already present — body is unchanged, not a rewrite.
            return false;
        }
        _ = cjson.cJSON_AddTrueToObject(opts, "include_usage", &cj.alloc);
    } else {
        // Create stream_options with include_usage: true.
        const opts_obj = cjson.cJSON_AddObjectToObject(json, "stream_options", &cj.alloc);
        if (opts_obj == core.nullptr(cjson.cJSON)) {
            ctx.request_translation_skipped = 1;
            return false;
        }
        _ = cjson.cJSON_AddTrueToObject(opts_obj, "include_usage", &cj.alloc);
    }

    const new_body = cj.encode(json) catch {
        ctx.request_translation_skipped = 1;
        return false;
    };

    return replace_request_body(r, ctx, new_body);
}

// ── Phase 4: response body helpers ───────────────────────────────────────────

fn append_to_resp_buffer(ctx: *LlmProxyCtx, data: []const u8, pool: [*c]core.ngx_pool_t) bool {
    if (data.len == 0) return true;
    const new_len = ctx.resp_buf_len + data.len;
    if (new_len > ctx.resp_buf_cap) {
        const new_cap = @max(if (ctx.resp_buf_cap == 0) RESP_BUF_INIT_CAP else ctx.resp_buf_cap * 2, new_len);
        const raw = core.ngx_pnalloc(pool, new_cap) orelse return false;
        const p = core.castPtr(u8, raw) orelse return false;
        if (ctx.resp_buf_len > 0 and ctx.resp_buf != core.nullptr(u8)) {
            @memcpy(p[0..ctx.resp_buf_len], core.slicify(u8, ctx.resp_buf, ctx.resp_buf_len));
        }
        ctx.resp_buf = p;
        ctx.resp_buf_cap = new_cap;
    }
    @memcpy(core.slicify(u8, ctx.resp_buf + ctx.resp_buf_len, data.len), data);
    ctx.resp_buf_len = new_len;
    return true;
}

fn make_memory_chain(r: [*c]ngx_http_request_t, s: ngx_str_t) ?[*c]ngx_chain_t {
    if (s.len == 0) return null;
    const cl = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return null;
    const b = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return null;
    b.*.pos = s.data;
    b.*.last = s.data + s.len;
    b.*.flags.memory = true;
    cl.*.buf = b;
    cl.*.next = null;
    return cl;
}

fn mark_response_started(ctx: *LlmProxyCtx) void {
    ctx.response_started = 1;
    ctx.replay_safe = 0;
}

// Returns true when the JSON looks like a provider error response (not a
// successful completion).  Error shapes are passed through unmodified.
fn detect_error_shape(json: [*c]cjson.cJSON) bool {
    // OpenAI error: {"error": {...}}
    if (cjson.cJSON_GetObjectItem(json, "error") != core.nullptr(cjson.cJSON)) return true;
    // Anthropic error: {"type": "error", ...}
    if (cjson.cJSON_GetObjectItem(json, "type")) |type_item| {
        if (CJSON.stringValue(type_item)) |t| {
            if (std.mem.eql(u8, core.slicify(u8, t.data, t.len), "error")) return true;
        }
    }
    return false;
}

// Extract and concatenate text from an Anthropic content array.
fn extract_anthropic_content_text(r: [*c]ngx_http_request_t, content: [*c]cjson.cJSON) ngx_str_t {
    if (cjson.cJSON_IsString(content) == 1) {
        return CJSON.stringValue(content) orelse empty_str;
    }
    if (cjson.cJSON_IsArray(content) != 1) return empty_str;
    var combined: ngx_str_t = empty_str;
    var it = CJSON.Iterator.init(content);
    while (it.next()) |block| {
        if (cjson.cJSON_GetObjectItem(block, "type")) |tp| {
            if (CJSON.stringValue(tp)) |tp_s| {
                if (std.mem.eql(u8, core.slicify(u8, tp_s.data, tp_s.len), "text")) {
                    if (cjson.cJSON_GetObjectItem(block, "text")) |text_item| {
                        if (CJSON.stringValue(text_item)) |tv| {
                            combined = append_text_segment(r, combined, tv) orelse combined;
                        }
                    }
                }
            }
        }
    }
    return combined;
}

// Map Anthropic stop_reason values to OpenAI finish_reason values.
fn map_stop_reason(reason: ngx_str_t) ngx_str_t {
    if (reason.len == 0) return ngx_string("stop");
    const s = core.slicify(u8, reason.data, reason.len);
    if (std.mem.eql(u8, s, "end_turn")) return ngx_string("stop");
    if (std.mem.eql(u8, s, "max_tokens")) return ngx_string("length");
    if (std.mem.eql(u8, s, "tool_use")) return ngx_string("tool_calls");
    return reason;
}

// Map OpenAI finish_reason values to Anthropic stop_reason values (inverse of map_stop_reason).
fn map_finish_reason_to_anthropic(reason: ngx_str_t) ngx_str_t {
    if (reason.len == 0) return ngx_string("end_turn");
    const s = core.slicify(u8, reason.data, reason.len);
    if (std.mem.eql(u8, s, "stop")) return ngx_string("end_turn");
    if (std.mem.eql(u8, s, "length")) return ngx_string("max_tokens");
    if (std.mem.eql(u8, s, "tool_calls")) return ngx_string("tool_use");
    return reason;
}

// Infer the client request dialect from the JSON body shape.
// Returns "anthropic" for bodies with Anthropic-only indicators; "openai" otherwise.
// Ambiguous shapes default to "openai" for backward compatibility.
// Single pass through messages: collect role:system, array content, and string content
// signals before deciding. role:system is the strongest OpenAI indicator and overrides
// top-level system and content-block arrays seen in the same request.
fn infer_request_dialect(json: [*c]cjson.cJSON) []const u8 {
    if (cjson.cJSON_GetObjectItem(json, "anthropic_version") != core.nullptr(cjson.cJSON)) return "anthropic";
    if (cjson.cJSON_GetObjectItem(json, "top_k") != core.nullptr(cjson.cJSON)) return "anthropic";

    var saw_role_system = false;
    var saw_array_content = false;
    var saw_openai_content_block = false;
    var saw_string_content = false;
    if (cjson.cJSON_GetObjectItem(json, "messages")) |msgs| {
        if (cjson.cJSON_IsArray(msgs) == 1) {
            var msg = msgs.*.child;
            while (msg != core.nullptr(cjson.cJSON)) : (msg = msg.*.next) {
                if (cjson.cJSON_GetObjectItem(msg, "role")) |role| {
                    if (CJSON.stringValue(role)) |role_s| {
                        if (std.mem.eql(u8, core.slicify(u8, role_s.data, role_s.len), "system")) saw_role_system = true;
                    }
                }
                if (cjson.cJSON_GetObjectItem(msg, "content")) |content| {
                    if (cjson.cJSON_IsArray(content) == 1) {
                        saw_array_content = true;
                        var block = content.*.child;
                        while (block != core.nullptr(cjson.cJSON)) : (block = block.*.next) {
                            const tp = cjson.cJSON_GetObjectItem(block, "type") orelse continue;
                            const tp_s = CJSON.stringValue(tp) orelse continue;
                            const tp_slice = core.slicify(u8, tp_s.data, tp_s.len);
                            if (std.mem.eql(u8, tp_slice, "image_url") or
                                std.mem.eql(u8, tp_slice, "input_audio") or
                                std.mem.eql(u8, tp_slice, "input_text"))
                            {
                                saw_openai_content_block = true;
                            }
                        }
                    }
                    if (cjson.cJSON_IsString(content) == 1) saw_string_content = true;
                }
            }
        }
    }
    // role:system overrides top-level system and content-block arrays.
    if (saw_role_system) return "openai";
    if (saw_openai_content_block) return "openai";
    if (cjson.cJSON_GetObjectItem(json, "system") != core.nullptr(cjson.cJSON)) return "anthropic";
    if (saw_array_content) return "anthropic";
    if (saw_string_content) return "openai";
    if (cjson.cJSON_GetObjectItem(json, "stream_options") != core.nullptr(cjson.cJSON)) return "openai";
    return "openai";
}

// ── Shared usage helpers ──────────────────────────────────────────────────────

// Apply OpenAI wire-format usage fields to ctx.
// prompt_tokens is total input; cache reads are under prompt_tokens_details.
fn apply_openai_usage(usage: [*c]cjson.cJSON, ctx: *LlmProxyCtx) void {
    const pt_raw = if (cjson.cJSON_GetObjectItem(usage, "prompt_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const ct_raw = if (cjson.cJSON_GetObjectItem(usage, "completion_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const tt_raw = if (cjson.cJSON_GetObjectItem(usage, "total_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const pt: ngx_uint_t = if (pt_raw > 0) @intCast(pt_raw) else 0;
    const ct: ngx_uint_t = if (ct_raw > 0) @intCast(ct_raw) else 0;
    const tt: ngx_uint_t = if (tt_raw > 0) @intCast(tt_raw) else pt +| ct;
    ctx.prompt_tokens = pt;
    ctx.completion_tokens = ct;
    ctx.total_tokens = tt;
    ctx.cache_read_tokens = 0;
    ctx.cache_create_tokens = 0;
    if (cjson.cJSON_GetObjectItem(usage, "prompt_tokens_details")) |details| {
        const cr_raw = if (cjson.cJSON_GetObjectItem(details, "cached_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        if (cr_raw > 0 and @as(ngx_uint_t, @intCast(cr_raw)) <= pt) ctx.cache_read_tokens = @intCast(cr_raw);
    }
    ctx.usage_extracted = 1;
}

// Apply Anthropic wire-format usage fields to ctx.
// input_tokens excludes cache tokens; total prompt is the sum of all three.
fn apply_anthropic_usage(usage: [*c]cjson.cJSON, ctx: *LlmProxyCtx) void {
    const in_raw = if (cjson.cJSON_GetObjectItem(usage, "input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const out_raw = if (cjson.cJSON_GetObjectItem(usage, "output_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const cr_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_read_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const cc_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_creation_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
    const base: ngx_uint_t = if (in_raw > 0) @intCast(in_raw) else 0;
    const cr: ngx_uint_t = if (cr_raw > 0) @intCast(cr_raw) else 0;
    const cc: ngx_uint_t = if (cc_raw > 0) @intCast(cc_raw) else 0;
    const ct: ngx_uint_t = if (out_raw > 0) @intCast(out_raw) else 0;
    const pt = (base +| cr) +| cc;
    ctx.prompt_tokens = pt;
    ctx.completion_tokens = ct;
    ctx.total_tokens = pt +| ct;
    ctx.cache_read_tokens = cr;
    ctx.cache_create_tokens = cc;
    ctx.usage_extracted = 1;
}

// Parse body and extract usage tokens.  Works for both OpenAI and Anthropic
// wire formats based on ctx.provider.  Sets usage_extracted = 1 on success.
fn extract_usage_from_response(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, body: ngx_str_t) void {
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body) catch return;
    if (detect_error_shape(json)) {
        ctx.response_is_error_shape = 1;
        ctx.failure_class = FAILURE_CLASS_SEMANTIC_ERROR;
        return;
    }
    const usage = cjson.cJSON_GetObjectItem(json, "usage") orelse {
        log.ngz_log_error(NGX_LOG_DEBUG, r.*.connection.*.log, 0, "llm_proxy: response has no usage field", .{});
        return;
    };
    // Use effective_dialect: by the time this is called (body filter), detect_fallback_outcome
    // has already updated effective_dialect to match the backend that actually served the response.
    if (dialect_is(ctx.effective_dialect, "anthropic")) {
        apply_anthropic_usage(usage, ctx);
    } else {
        apply_openai_usage(usage, ctx);
    }
}

// Translate an Anthropic non-streaming response body to OpenAI schema.
// Returns the new body on success or null on parse failure / error shape.
// Populates usage fields in ctx when a usage block is present.
fn normalize_anthropic_to_openai(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, body: ngx_str_t) ?ngx_str_t {
    var cj = CJSON.init(r.*.pool);
    const src = cj.decode(body) catch {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: failed to parse Anthropic response for normalization, passing through", .{});
        return null;
    };

    if (detect_error_shape(src)) {
        ctx.response_is_error_shape = 1;
        ctx.failure_class = FAILURE_CLASS_SEMANTIC_ERROR;
        return null; // pass through error bodies unmodified
    }

    const out = cjson.cJSON_CreateObject(&cj.alloc) orelse {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OOM creating output object for Anthropic normalisation", .{});
        return null;
    };

    // Copy all unknown / pass-through fields first; then add mapped fields.
    // Anthropic-specific fields that are explicitly mapped are skipped here.
    var it = CJSON.Iterator.init(src);
    while (it.next()) |field| {
        if (field.*.string) |key_ptr| {
            const key_s = core.slicify(u8, key_ptr, strlen(key_ptr));
            if (std.mem.eql(u8, key_s, "content")) continue;
            if (std.mem.eql(u8, key_s, "stop_reason")) continue;
            if (std.mem.eql(u8, key_s, "stop_sequence")) continue;
            if (std.mem.eql(u8, key_s, "usage")) continue;
            if (std.mem.eql(u8, key_s, "type")) continue;
            if (std.mem.eql(u8, key_s, "role")) continue;
            const copy = cjson.cJSON_Duplicate(field, 1, &cj.alloc) orelse continue;
            _ = cjson.cJSON_AddItemToObject(out, key_ptr, copy, &cj.alloc);
        }
    }

    // "object": "chat.completion" replaces Anthropic "type": "message".
    _ = cjson.cJSON_AddStringToObject(out, "object", "chat.completion", &cj.alloc);

    // Build choices[0] from content + stop_reason.
    const choices = cjson.cJSON_AddArrayToObject(out, "choices", &cj.alloc) orelse return null;
    const choice = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
    _ = cjson.cJSON_AddNumberToObject(choice, "index", 0, &cj.alloc);

    const msg_obj = cjson.cJSON_AddObjectToObject(choice, "message", &cj.alloc) orelse return null;
    _ = cjson.cJSON_AddStringToObject(msg_obj, "role", "assistant", &cj.alloc);

    const content_text = if (cjson.cJSON_GetObjectItem(src, "content")) |content_arr|
        extract_anthropic_content_text(r, content_arr)
    else
        empty_str;
    _ = cjson.cJSON_AddStringToObject(msg_obj, "content", content_text.data, &cj.alloc);

    const stop_reason_raw = if (cjson.cJSON_GetObjectItem(src, "stop_reason")) |sr|
        (CJSON.stringValue(sr) orelse empty_str)
    else
        empty_str;
    const finish_reason = map_stop_reason(stop_reason_raw);
    _ = cjson.cJSON_AddStringToObject(choice, "finish_reason", finish_reason.data, &cj.alloc);

    _ = cjson.cJSON_AddItemToArray(choices, choice);

    // Map usage block and populate ctx.
    // Anthropic input_tokens does NOT include cache tokens; total prompt = sum of all three.
    if (cjson.cJSON_GetObjectItem(src, "usage")) |usage| {
        const in_raw = if (cjson.cJSON_GetObjectItem(usage, "input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const out_raw = if (cjson.cJSON_GetObjectItem(usage, "output_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const cr_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_read_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const cc_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_creation_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const base: ngx_uint_t = if (in_raw > 0) @intCast(in_raw) else 0;
        const cr: ngx_uint_t = if (cr_raw > 0) @intCast(cr_raw) else 0;
        const cc: ngx_uint_t = if (cc_raw > 0) @intCast(cc_raw) else 0;
        const ct: ngx_uint_t = if (out_raw > 0) @intCast(out_raw) else 0;
        const pt = (base +| cr) +| cc;

        if (cjson.cJSON_AddObjectToObject(out, "usage", &cj.alloc)) |usage_out| {
            _ = cjson.cJSON_AddNumberToObject(usage_out, "prompt_tokens", @floatFromInt(pt), &cj.alloc);
            _ = cjson.cJSON_AddNumberToObject(usage_out, "completion_tokens", @floatFromInt(ct), &cj.alloc);
            _ = cjson.cJSON_AddNumberToObject(usage_out, "total_tokens", @floatFromInt(pt +| ct), &cj.alloc);
        } else {
            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OOM creating usage object during Anthropic normalisation", .{});
        }

        ctx.prompt_tokens = pt;
        ctx.completion_tokens = ct;
        ctx.total_tokens = pt +| ct;
        ctx.cache_read_tokens = cr;
        ctx.cache_create_tokens = cc;
        ctx.usage_extracted = 1;
    } else {
        log.ngz_log_error(NGX_LOG_DEBUG, r.*.connection.*.log, 0, "llm_proxy: Anthropic response has no usage field, usage_extracted stays 0", .{});
    }

    return cj.encode(out) catch {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: failed to encode normalised Anthropic response, passing through", .{});
        return null;
    };
}

// Translate an OpenAI non-streaming response body to Anthropic schema.
// Returns the new body on success or null on parse failure / error shape.
// Populates usage fields in ctx when a usage block is present.
fn normalize_openai_to_anthropic(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, body: ngx_str_t) ?ngx_str_t {
    var cj = CJSON.init(r.*.pool);
    const src = cj.decode(body) catch {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: failed to parse OpenAI response for Anthropic normalization, passing through", .{});
        return null;
    };

    if (detect_error_shape(src)) {
        ctx.response_is_error_shape = 1;
        ctx.failure_class = FAILURE_CLASS_SEMANTIC_ERROR;
        return null; // pass through error bodies unmodified
    }

    const out = cjson.cJSON_CreateObject(&cj.alloc) orelse {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OOM creating output object for OpenAI→Anthropic normalization", .{});
        return null;
    };

    // Pass through id, model, and other unknown fields; skip explicitly mapped ones.
    var it = CJSON.Iterator.init(src);
    while (it.next()) |field| {
        if (field.*.string) |key_ptr| {
            const key_s = core.slicify(u8, key_ptr, strlen(key_ptr));
            if (std.mem.eql(u8, key_s, "choices")) continue;
            if (std.mem.eql(u8, key_s, "usage")) continue;
            if (std.mem.eql(u8, key_s, "object")) continue;
            const copy = cjson.cJSON_Duplicate(field, 1, &cj.alloc) orelse continue;
            _ = cjson.cJSON_AddItemToObject(out, key_ptr, copy, &cj.alloc);
        }
    }

    // Add Anthropic response shape fields.
    _ = cjson.cJSON_AddStringToObject(out, "type", "message", &cj.alloc);
    _ = cjson.cJSON_AddStringToObject(out, "role", "assistant", &cj.alloc);

    // Extract content and finish_reason from choices[0].
    var content_text: ngx_str_t = empty_str;
    var finish_reason: ngx_str_t = empty_str;
    const choices = cjson.cJSON_GetObjectItem(src, "choices") orelse {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI response missing choices for Anthropic normalization, passing through", .{});
        return null;
    };
    if (cjson.cJSON_IsArray(choices) != 1 or choices.*.child == core.nullptr(cjson.cJSON)) {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI response choices is empty or not an array, passing through", .{});
        return null;
    }
    const choice = choices.*.child;
    const msg = cjson.cJSON_GetObjectItem(choice, "message") orelse {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI response choice missing message for Anthropic normalization, passing through", .{});
        return null;
    };
    if (cjson.cJSON_GetObjectItem(msg, "content")) |c| {
        if (cjson.cJSON_IsString(c) == 1) {
            content_text = CJSON.stringValue(c) orelse empty_str;
        } else if (cjson.cJSON_IsNull(c) == 1) {
            if (cjson.cJSON_GetObjectItem(msg, "tool_calls") != core.nullptr(cjson.cJSON)) {
                log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI tool_calls response normalization is unsupported, passing through", .{});
                return null;
            }
            // null content with no tool_calls → emit empty content array
        } else {
            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI response content is not a string, passing through", .{});
            return null;
        }
    } else if (cjson.cJSON_GetObjectItem(msg, "tool_calls") != core.nullptr(cjson.cJSON)) {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OpenAI tool_calls response normalization is unsupported, passing through", .{});
        return null;
    }
    if (cjson.cJSON_GetObjectItem(choice, "finish_reason")) |fr| {
        if (cjson.cJSON_IsNull(fr) != 1) {
            finish_reason = CJSON.stringValue(fr) orelse empty_str;
        }
    }

    // Build content array: [{"type":"text","text":"..."}].
    const content_arr = cjson.cJSON_AddArrayToObject(out, "content", &cj.alloc) orelse return null;
    if (content_text.len > 0) {
        const text_block = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(text_block, "type", "text", &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(text_block, "text", content_text.data, &cj.alloc);
        _ = cjson.cJSON_AddItemToArray(content_arr, text_block);
    }

    // Map finish_reason → stop_reason.
    const stop_reason = map_finish_reason_to_anthropic(finish_reason);
    _ = cjson.cJSON_AddStringToObject(out, "stop_reason", stop_reason.data, &cj.alloc);
    _ = cjson.cJSON_AddNullToObject(out, "stop_sequence", &cj.alloc);

    // Map usage: prompt_tokens → input_tokens, completion_tokens → output_tokens.
    // Cache reads come from prompt_tokens_details.cached_tokens.
    if (cjson.cJSON_GetObjectItem(src, "usage")) |usage| {
        apply_openai_usage(usage, ctx);
        if (cjson.cJSON_AddObjectToObject(out, "usage", &cj.alloc)) |usage_out| {
            _ = cjson.cJSON_AddNumberToObject(usage_out, "input_tokens", @floatFromInt(ctx.prompt_tokens), &cj.alloc);
            _ = cjson.cJSON_AddNumberToObject(usage_out, "output_tokens", @floatFromInt(ctx.completion_tokens), &cj.alloc);
        } else {
            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OOM creating usage object during OpenAI→Anthropic normalization", .{});
        }
    } else {
        log.ngz_log_error(NGX_LOG_DEBUG, r.*.connection.*.log, 0, "llm_proxy: OpenAI response has no usage field, usage_extracted stays 0", .{});
    }

    return cj.encode(out) catch {
        log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: failed to encode Anthropic-normalized OpenAI response, passing through", .{});
        return null;
    };
}

// ── Phase 5: SSE streaming helpers ───────────────────────────────────────────

// Ensure the line buffer and event-type buffer are allocated from the pool.
// Returns false on OOM; SSE scanning is skipped when buffers are unavailable.
fn sse_ensure_buffers(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) bool {
    if (ctx.sse_line_buf == core.nullptr(u8)) {
        const raw = core.ngx_pnalloc(r.*.pool, SSE_LINE_BUF_SIZE) orelse return false;
        ctx.sse_line_buf = core.castPtr(u8, raw) orelse return false;
        ctx.sse_line_cap = SSE_LINE_BUF_SIZE;
        const raw2 = core.ngx_pnalloc(r.*.pool, 64) orelse return false;
        ctx.sse_event_type_buf = core.castPtr(u8, raw2) orelse return false;
    }
    return true;
}

// Ensure the data buffer is allocated from the pool.
fn sse_ensure_data_buf(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) bool {
    if (ctx.sse_data_buf == core.nullptr(u8)) {
        const raw = core.ngx_pnalloc(r.*.pool, SSE_DATA_BUF_SIZE) orelse return false;
        ctx.sse_data_buf = core.castPtr(u8, raw) orelse return false;
        ctx.sse_data_cap = SSE_DATA_BUF_SIZE;
    }
    return true;
}

// Append a segment to the current SSE line buffer, growing it (copy into a larger
// pool allocation) when the fast-path capacity is exceeded. Returns false when the
// line would exceed SSE_LINE_MAX_SIZE or on OOM — the caller marks the line as
// overflowed and drops it. The common case (line within current capacity) takes
// the bulk-memcpy path with no allocation, identical to the previous fixed buffer.
fn sse_line_append(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, data: []const u8) bool {
    if (data.len == 0) return true;
    const cur: usize = ctx.sse_line_len;
    const new_len = cur + data.len;
    if (new_len > ctx.sse_line_cap) {
        if (new_len > SSE_LINE_MAX_SIZE) return false;
        var new_cap = if (ctx.sse_line_cap == 0) SSE_LINE_BUF_SIZE else ctx.sse_line_cap;
        while (new_cap < new_len) new_cap *|= 2;
        if (new_cap > SSE_LINE_MAX_SIZE) new_cap = SSE_LINE_MAX_SIZE;
        const raw = core.ngx_pnalloc(r.*.pool, new_cap) orelse return false;
        const p = core.castPtr(u8, raw) orelse return false;
        if (cur > 0 and ctx.sse_line_buf != core.nullptr(u8)) {
            @memcpy(p[0..cur], core.slicify(u8, ctx.sse_line_buf, cur));
        }
        ctx.sse_line_buf = p;
        ctx.sse_line_cap = new_cap;
    }
    @memcpy(core.slicify(u8, ctx.sse_line_buf + cur, data.len), data);
    ctx.sse_line_len = new_len;
    return true;
}

// Store a complete data: payload into the SSE data buffer, growing it as needed.
// Returns false when the payload exceeds SSE_LINE_MAX_SIZE or on OOM — the caller
// marks the data line as overflowed.
fn sse_data_store(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, data: []const u8) bool {
    if (data.len > SSE_LINE_MAX_SIZE) return false;
    if (data.len > ctx.sse_data_cap) {
        var new_cap = if (ctx.sse_data_cap == 0) SSE_DATA_BUF_SIZE else ctx.sse_data_cap;
        while (new_cap < data.len) new_cap *|= 2;
        if (new_cap > SSE_LINE_MAX_SIZE) new_cap = SSE_LINE_MAX_SIZE;
        const raw = core.ngx_pnalloc(r.*.pool, new_cap) orelse return false;
        ctx.sse_data_buf = core.castPtr(u8, raw) orelse return false;
        ctx.sse_data_cap = new_cap;
    }
    if (data.len > 0) @memcpy(core.slicify(u8, ctx.sse_data_buf, data.len), data);
    ctx.sse_data_len = data.len;
    return true;
}

fn append_to_sse_raw_line(ctx: *LlmProxyCtx, data: []const u8, pool: [*c]core.ngx_pool_t) bool {
    if (data.len == 0) return true;
    const new_len = ctx.sse_raw_line_len + data.len;
    if (new_len < ctx.sse_raw_line_len or new_len > SSE_LINE_MAX_SIZE) return false;
    if (new_len > ctx.sse_raw_line_cap) {
        var new_cap = @max(if (ctx.sse_raw_line_cap == 0) 256 else ctx.sse_raw_line_cap * 2, new_len);
        if (new_cap > SSE_LINE_MAX_SIZE) new_cap = SSE_LINE_MAX_SIZE;
        const raw = core.ngx_pnalloc(pool, new_cap) orelse return false;
        const p = core.castPtr(u8, raw) orelse return false;
        if (ctx.sse_raw_line_len > 0 and ctx.sse_raw_line_buf != core.nullptr(u8)) {
            @memcpy(p[0..ctx.sse_raw_line_len], core.slicify(u8, ctx.sse_raw_line_buf, ctx.sse_raw_line_len));
        }
        ctx.sse_raw_line_buf = p;
        ctx.sse_raw_line_cap = new_cap;
    }
    @memcpy(core.slicify(u8, ctx.sse_raw_line_buf + ctx.sse_raw_line_len, data.len), data);
    ctx.sse_raw_line_len = new_len;
    return true;
}

// Reset per-event SSE state (called at each blank-line event boundary).
fn sse_reset_event(ctx: *LlmProxyCtx) void {
    ctx.sse_event_type_len = 0;
    ctx.sse_data_len = 0;
    ctx.sse_data_overflow = 0;
}

fn sse_trimmed_line_len(ctx: *LlmProxyCtx) usize {
    var line_len = ctx.sse_line_len;
    if (line_len > 0) {
        const lb: [*]u8 = @ptrCast(ctx.sse_line_buf);
        if (lb[line_len - 1] == '\r') line_len -= 1;
    }
    return line_len;
}

fn sse_trimmed_raw_line_len(ctx: *LlmProxyCtx) usize {
    var line_len = ctx.sse_raw_line_len;
    if (line_len > 0 and ctx.sse_raw_line_buf[line_len - 1] == '\n') line_len -= 1;
    if (line_len > 0 and ctx.sse_raw_line_buf[line_len - 1] == '\r') line_len -= 1;
    return line_len;
}

fn sse_reset_physical_line(ctx: *LlmProxyCtx) void {
    ctx.sse_line_len = 0;
    ctx.sse_line_overflow = 0;
    ctx.sse_raw_line_len = 0;
}

// Build a pool-allocated SSE data line: "data: <json>\n\n"
fn sse_build_data_event(r: [*c]ngx_http_request_t, json: ngx_str_t) ?ngx_str_t {
    const prefix = "data: ";
    const suffix = "\n\n";
    const total = prefix.len + json.len + suffix.len;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    @memcpy(p[0..prefix.len], prefix);
    if (json.len > 0) @memcpy(p[prefix.len .. prefix.len + json.len], core.slicify(u8, json.data, json.len));
    @memcpy(p[prefix.len + json.len .. total], suffix);
    return ngx_str_t{ .data = p, .len = total };
}

// Build pool-allocated "data: [DONE]\n\n"
fn sse_build_done_event(r: [*c]ngx_http_request_t) ?ngx_str_t {
    const s = "data: [DONE]\n\n";
    const raw = core.ngx_pnalloc(r.*.pool, s.len) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    @memcpy(p[0..s.len], s);
    return ngx_str_t{ .data = p, .len = s.len };
}

fn sse_build_line(r: [*c]ngx_http_request_t, line: []const u8) ?ngx_str_t {
    const total = line.len + 1;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    if (line.len > 0) @memcpy(p[0..line.len], line);
    p[line.len] = '\n';
    return ngx_str_t{ .data = p, .len = total };
}

fn sse_rewrite_data_line(r: [*c]ngx_http_request_t, payload: ngx_str_t) ?ngx_str_t {
    const prefix = "data: ";
    const total = prefix.len + payload.len + 1;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    @memcpy(p[0..prefix.len], prefix);
    if (payload.len > 0) @memcpy(p[prefix.len .. prefix.len + payload.len], core.slicify(u8, payload.data, payload.len));
    p[total - 1] = '\n';
    return ngx_str_t{ .data = p, .len = total };
}

fn sse_rewrite_blank_line(r: [*c]ngx_http_request_t) ?ngx_str_t {
    return sse_build_line(r, "");
}

// ── Target 6: content_block_delta fast-path helpers ──────────────────────────

// Scan a content_block_delta data payload for a text_delta event without cJSON.
// Returns the raw JSON-escaped text content (slice into data between outer quotes).
// Returns null when the event is not a simple text_delta or scanning fails.
fn sse_fast_text_delta(data: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, data, "\"text_delta\"") == null) return null;
    const key = "\"text\":\"";
    const off = std.mem.indexOf(u8, data, key) orelse return null;
    const val_start = off + key.len;
    var i = val_start;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\\') {
            i += 1;
            if (i >= data.len) return null;
        } else if (data[i] == '"') {
            return data[val_start..i];
        }
    }
    return null;
}

// Build the OpenAI streaming token chunk JSON for a text_delta event.
// text_raw is the raw JSON-escaped content (without surrounding quotes).
fn sse_build_token_chunk(r: [*c]ngx_http_request_t, text_raw: []const u8) ?ngx_str_t {
    const prefix = "{\"choices\":[{\"delta\":{\"content\":\"";
    const suffix = "\"},\"index\":0,\"finish_reason\":null}],\"object\":\"chat.completion.chunk\"}";
    const total = prefix.len + text_raw.len + suffix.len;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    @memcpy(p[0..prefix.len], prefix);
    if (text_raw.len > 0) @memcpy(p[prefix.len .. prefix.len + text_raw.len], text_raw);
    @memcpy(p[prefix.len + text_raw.len .. total], suffix);
    return ngx_str_t{ .data = p, .len = total };
}

// ── Target 12: reverse streaming fast-path helpers ───────────────────────────

fn json_skip_ws(data: []const u8, pos: *usize) void {
    while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t' or data[pos.*] == '\n' or data[pos.*] == '\r')) pos.* += 1;
}

fn json_object_end(data: []const u8, start: usize) ?usize {
    if (start >= data.len or data[start] != '{') return null;
    var pos = start + 1;
    var depth: usize = 1;
    var in_str = false;
    var esc = false;
    while (pos < data.len) : (pos += 1) {
        const c = data[pos];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return pos + 1;
        }
    }
    return null;
}

fn json_object_value_after_key(data: []const u8, key: []const u8) ?[]const u8 {
    const off = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = off + key.len;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != ':') return null;
    pos += 1;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != '{') return null;
    const end = json_object_end(data, pos) orelse return null;
    return data[pos..end];
}

fn json_first_array_object_after_key(data: []const u8, key: []const u8) ?[]const u8 {
    const off = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = off + key.len;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != ':') return null;
    pos += 1;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != '[') return null;
    pos += 1;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != '{') return null;
    const end = json_object_end(data, pos) orelse return null;
    return data[pos..end];
}

fn json_raw_string_value_after_key(data: []const u8, key: []const u8) ?[]const u8 {
    const off = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = off + key.len;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != ':') return null;
    pos += 1;
    json_skip_ws(data, &pos);
    if (pos >= data.len or data[pos] != '"') return null;
    pos += 1;
    const val_start = pos;
    while (pos < data.len) : (pos += 1) {
        if (data[pos] == '\\') {
            pos += 1;
            if (pos >= data.len) return null;
        } else if (data[pos] == '"') {
            return data[val_start..pos];
        }
    }
    return null;
}

// Scan an OpenAI SSE data line for a plain in-progress text delta without cJSON.
// Returns the raw JSON-escaped content string (slice into data, no surrounding
// quotes) when the chunk is a choices[0].delta.content token with finish_reason:null.
// Returns null for terminal chunks, tool_calls, empty content, or any ambiguous shape;
// the caller falls back to cJSON.
fn sse_fast_openai_content_delta(data: []const u8) ?[]const u8 {
    const choice = json_first_array_object_after_key(data, "\"choices\"") orelse return null;
    if (std.mem.indexOf(u8, choice, "\"index\":0") == null) return null;
    // Reject terminal chunks: finish_reason present with a non-null quoted string.
    // Absent field or explicit :null both mean in-progress — fast-path safe.
    if (std.mem.indexOf(u8, choice, "\"finish_reason\":\"") != null) return null;
    if (std.mem.indexOf(u8, choice, "\"tool_calls\"") != null) return null;

    const delta = json_object_value_after_key(choice, "\"delta\"") orelse return null;
    if (std.mem.indexOf(u8, delta, "\"tool_calls\"") != null) return null;
    const raw = json_raw_string_value_after_key(delta, "\"content\"") orelse return null;
    return if (raw.len > 0) raw else null;
}

// Build the Anthropic content_block_delta JSON for a text token.
// text_raw is the raw JSON-escaped content (without surrounding quotes).
fn sse_build_content_block_delta(r: [*c]ngx_http_request_t, text_raw: []const u8) ?ngx_str_t {
    const prefix = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"";
    const suffix = "\"}}";
    const total = prefix.len + text_raw.len + suffix.len;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    @memcpy(p[0..prefix.len], prefix);
    if (text_raw.len > 0) @memcpy(p[prefix.len .. prefix.len + text_raw.len], text_raw);
    @memcpy(p[prefix.len + text_raw.len .. total], suffix);
    return ngx_str_t{ .data = p, .len = total };
}

// ── Target 7: request body routing fast-path scanner ─────────────────────────

// Skip a JSON value at pos in body, advancing pos past the value.
// Returns false when the value is malformed or unrecognised.
fn brs_skip_value(body: []const u8, pos: *usize) bool {
    if (pos.* >= body.len) return false;
    switch (body[pos.*]) {
        '"' => {
            pos.* += 1;
            while (pos.* < body.len) : (pos.* += 1) {
                if (body[pos.*] == '\\') return false;
                if (body[pos.*] == '"') {
                    pos.* += 1;
                    return true;
                }
            }
            return false;
        },
        '{', '[' => {
            const open = body[pos.*];
            const close: u8 = if (open == '{') '}' else ']';
            var depth: usize = 1;
            pos.* += 1;
            var in_str = false;
            var esc = false;
            while (pos.* < body.len and depth > 0) : (pos.* += 1) {
                const c = body[pos.*];
                if (esc) {
                    esc = false;
                    continue;
                }
                if (in_str) {
                    if (c == '\\') esc = true else if (c == '"') in_str = false;
                    continue;
                }
                if (c == '"') in_str = true else if (c == open) depth += 1 else if (c == close) depth -= 1;
            }
            return depth == 0;
        },
        't' => {
            if (pos.* + 4 <= body.len and std.mem.eql(u8, body[pos.* .. pos.* + 4], "true")) {
                pos.* += 4;
                return true;
            }
            return false;
        },
        'f' => {
            if (pos.* + 5 <= body.len and std.mem.eql(u8, body[pos.* .. pos.* + 5], "false")) {
                pos.* += 5;
                return true;
            }
            return false;
        },
        'n' => {
            if (pos.* + 4 <= body.len and std.mem.eql(u8, body[pos.* .. pos.* + 4], "null")) {
                pos.* += 4;
                return true;
            }
            return false;
        },
        '-', '0'...'9' => {
            while (pos.* < body.len) : (pos.* += 1) {
                const c = body[pos.*];
                if (c != '-' and c != '+' and c != '.' and c != 'e' and c != 'E' and (c < '0' or c > '9')) break;
            }
            return true;
        },
        else => return false,
    }
}

// Skip ASCII whitespace in body starting at *pos.
fn brs_skip_ws(body: []const u8, pos: *usize) void {
    while (pos.* < body.len and (body[pos.*] == ' ' or body[pos.*] == '\t' or body[pos.*] == '\n' or body[pos.*] == '\r')) pos.* += 1;
}

// Scan one message object {..} for a "content" key whose value is an array.
// pos must point to '{' on entry. Advances pos past '}' on success.
// Returns false (bail to full parse) if content is an array or the object cannot be parsed.
fn brs_scan_message_obj(body: []const u8, pos: *usize) bool {
    if (pos.* >= body.len or body[pos.*] != '{') return false;
    pos.* += 1;
    while (true) {
        brs_skip_ws(body, pos);
        if (pos.* >= body.len) return false;
        if (body[pos.*] == '}') {
            pos.* += 1;
            return true;
        }
        if (body[pos.*] != '"') return false;
        pos.* += 1;
        const ks = pos.*;
        while (pos.* < body.len) : (pos.* += 1) {
            if (body[pos.*] == '\\') {
                pos.* += 1;
                continue;
            }
            if (body[pos.*] == '"') break;
        }
        if (pos.* >= body.len) return false;
        const key = body[ks..pos.*];
        pos.* += 1;
        brs_skip_ws(body, pos);
        if (pos.* >= body.len or body[pos.*] != ':') return false;
        pos.* += 1;
        brs_skip_ws(body, pos);
        if (pos.* >= body.len) return false;
        // Bail if content is an array — that is Anthropic block-content format.
        if (std.mem.eql(u8, key, "content") and body[pos.*] == '[') return false;
        if (!brs_skip_value(body, pos)) return false;
        brs_skip_ws(body, pos);
        if (pos.* >= body.len) return false;
        if (body[pos.*] == '}') {
            pos.* += 1;
            return true;
        }
        if (body[pos.*] != ',') return false;
        pos.* += 1;
    }
}

// Scan a messages array value at *pos.
// Returns false if any message has array content (Anthropic block format) or on parse error.
// On success advances pos past ']'.
fn brs_scan_messages_array(body: []const u8, pos: *usize) bool {
    if (pos.* >= body.len or body[pos.*] != '[') return false;
    pos.* += 1;
    while (true) {
        brs_skip_ws(body, pos);
        if (pos.* >= body.len) return false;
        if (body[pos.*] == ']') {
            pos.* += 1;
            return true;
        }
        if (!brs_scan_message_obj(body, pos)) return false;
        brs_skip_ws(body, pos);
        if (pos.* >= body.len) return false;
        if (body[pos.*] == ']') {
            pos.* += 1;
            return true;
        }
        if (body[pos.*] != ',') return false;
        pos.* += 1;
    }
}

// Scan the top-level fields of a JSON object for routing classification.
// Populates out_model (pointing into body bytes) and out_stream (0/1).
// Returns false when "provider" is present, Anthropic-only fields are found,
// or the scan is inconclusive. Also scans messages for Anthropic content-block
// arrays so the fast path is safe for dialect_mode=infer.
fn body_scan_routing_fields(body: []const u8, out_model: *ngx_str_t, out_stream: *ngx_flag_t) bool {
    var pos: usize = 0;
    // skip whitespace + opening '{'
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) pos += 1;
    if (pos >= body.len or body[pos] != '{') return false;
    pos += 1;

    while (pos < body.len) {
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) pos += 1;
        if (pos >= body.len) return false;
        if (body[pos] == '}') {
            pos += 1;
            brs_skip_ws(body, &pos);
            return pos == body.len;
        }

        // Read key string.
        if (body[pos] != '"') return false;
        pos += 1;
        const key_start = pos;
        while (pos < body.len) : (pos += 1) {
            if (body[pos] == '\\') return false;
            if (body[pos] == '"') break;
        }
        if (pos >= body.len) return false;
        const key = body[key_start..pos];
        pos += 1;

        // Skip ':'.
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) pos += 1;
        if (pos >= body.len or body[pos] != ':') return false;
        pos += 1;
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) pos += 1;
        if (pos >= body.len) return false;

        // Read value based on key.
        if (std.mem.eql(u8, key, "model")) {
            if (body[pos] != '"') return false;
            pos += 1;
            const val_start = pos;
            while (pos < body.len) : (pos += 1) {
                if (body[pos] == '\\') return false;
                if (body[pos] == '"') break;
            }
            if (pos >= body.len) return false;
            out_model.* = ngx_str_t{ .data = @constCast(body.ptr + val_start), .len = pos - val_start };
            pos += 1;
        } else if (std.mem.eql(u8, key, "stream")) {
            if (pos + 4 <= body.len and std.mem.eql(u8, body[pos .. pos + 4], "true")) {
                out_stream.* = 1;
                pos += 4;
            } else if (pos + 5 <= body.len and std.mem.eql(u8, body[pos .. pos + 5], "false")) {
                out_stream.* = 0;
                pos += 5;
            } else {
                return false;
            }
        } else if (std.mem.eql(u8, key, "provider")) {
            return false; // provider field requires full cJSON routing
        } else if (std.mem.eql(u8, key, "anthropic_version") or
            std.mem.eql(u8, key, "top_k") or
            std.mem.eql(u8, key, "system"))
        {
            return false; // Anthropic-native fields: full parse required
        } else if (std.mem.eql(u8, key, "messages")) {
            // Scan messages for Anthropic content-block arrays; bail to full parse if found.
            if (!brs_scan_messages_array(body, &pos)) return false;
        } else {
            if (!brs_skip_value(body, &pos)) return false;
        }

        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) pos += 1;
        if (pos >= body.len) return false;
        if (body[pos] == ',') {
            pos += 1;
        } else if (body[pos] != '}') {
            return false;
        }
    }
    return true;
}

fn sse_apply_stream_security(r: [*c]ngx_http_request_t, payload: ngx_str_t) ngx_str_t {
    if (payload.len == 0) return payload;
    const sec_lccf = core.castPtr(
        llm_security_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
    ) orelse return payload;
    if (sec_lccf.*.enabled != 1 or sec_lccf.*.inspect_response != 1) return payload;

    var out = payload;
    const outcome = ngx_http_llm_security_inspect_response(r, payload, &out);
    if (outcome.response_action == 3) return out; // redact
    return payload;
}

// Append a string as a new link at the tail of an output chain.
fn sse_chain_append(r: [*c]ngx_http_request_t, head: *?[*c]ngx_chain_t, tail: *?[*c]ngx_chain_t, s: ngx_str_t) bool {
    if (s.len == 0) return true;
    const cl = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return false;
    const b = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return false;
    b.*.pos = s.data;
    b.*.last = s.data + s.len;
    b.*.flags.memory = true;
    cl.*.buf = b;
    cl.*.next = null;
    if (tail.* == null) {
        head.* = cl;
        tail.* = cl;
    } else {
        tail.*.?.*.next = cl;
        tail.* = cl;
    }
    return true;
}

fn sse_chain_append_last_marker(r: [*c]ngx_http_request_t, head: *?[*c]ngx_chain_t, tail: *?[*c]ngx_chain_t) bool {
    const cl = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return false;
    const b = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return false;
    b.*.flags.sync = true;
    b.*.flags.last_buf = r == r.*.main;
    b.*.flags.last_in_chain = true;
    cl.*.buf = b;
    cl.*.next = null;
    if (tail.* == null) {
        head.* = cl;
        tail.* = cl;
    } else {
        tail.*.?.*.next = cl;
        tail.* = cl;
    }
    return true;
}

// Build a pool-allocated Anthropic-style named SSE event: "event: <name>\ndata: <json>\n\n"
fn sse_build_named_event(r: [*c]ngx_http_request_t, ename: []const u8, data: ngx_str_t) ?ngx_str_t {
    const e_prefix = "event: ";
    const d_prefix = "\ndata: ";
    const terminator = "\n\n";
    const total = e_prefix.len + ename.len + d_prefix.len + data.len + terminator.len;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    var off: usize = 0;
    @memcpy(p[off .. off + e_prefix.len], e_prefix);
    off += e_prefix.len;
    @memcpy(p[off .. off + ename.len], ename);
    off += ename.len;
    @memcpy(p[off .. off + d_prefix.len], d_prefix);
    off += d_prefix.len;
    if (data.len > 0) {
        @memcpy(p[off .. off + data.len], core.slicify(u8, data.data, data.len));
        off += data.len;
    }
    @memcpy(p[off .. off + terminator.len], terminator);
    return ngx_str_t{ .data = p, .len = total };
}

// Byte size of a named SSE event: "event: <name>\ndata: <data>\n\n"
fn sse_event_byte_size(name_len: usize, data_len: usize) usize {
    return 7 + name_len + 7 + data_len + 2;
}

// Write a named SSE event into pre-allocated out at *off; advances *off by the event size.
fn sse_write_event(out: [*]u8, off: *usize, name: []const u8, data: ngx_str_t) void {
    @memcpy(out[off.*..][0..7], "event: ");
    off.* += 7;
    @memcpy(out[off.*..][0..name.len], name);
    off.* += name.len;
    @memcpy(out[off.*..][0..7], "\ndata: ");
    off.* += 7;
    if (data.len > 0) {
        @memcpy(out[off.*..][0..data.len], core.slicify(u8, data.data, data.len));
        off.* += data.len;
    }
    @memcpy(out[off.*..][0..2], "\n\n");
    off.* += 2;
}

// Concatenate multiple ngx_str_t values into a single pool-allocated string.
fn sse_concat_ngxstr(r: [*c]ngx_http_request_t, parts: []const ngx_str_t) ?ngx_str_t {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    if (total == 0) return null;
    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    var off: usize = 0;
    for (parts) |part| {
        if (part.len > 0) {
            @memcpy(p[off .. off + part.len], core.slicify(u8, part.data, part.len));
            off += part.len;
        }
    }
    return ngx_str_t{ .data = p, .len = total };
}

// Translate a complete Anthropic SSE event (event_type + data) to OpenAI SSE format.
// Returns the new SSE event string (e.g. "data: {...}\n\n") or null to skip the event.
fn sse_translate_anthropic_event(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) ?ngx_str_t {
    const etype_len = ctx.sse_event_type_len;
    const data_len = ctx.sse_data_len;

    if (data_len == 0 or ctx.sse_data_overflow == 1) return null;

    const data = core.slicify(u8, ctx.sse_data_buf, data_len);
    const data_str = ngx_str_t{ .data = @constCast(data.ptr), .len = data_len };

    // No event: line — pass data: line through as-is (handles OpenAI-format SSE
    // sent through an Anthropic-normalized endpoint, or malformed Anthropic events).
    if (etype_len == 0) {
        if (std.mem.eql(u8, data, "[DONE]")) {
            ctx.sse_saw_done = 1;
            return sse_build_done_event(r);
        }
        return sse_build_data_event(r, sse_apply_stream_security(r, data_str));
    }

    const etype = core.slicify(u8, ctx.sse_event_type_buf, etype_len);

    var cj = CJSON.init(r.*.pool);

    if (std.mem.eql(u8, etype, "message_start")) {
        const src = cj.decode(data_str) catch return null;
        const msg = cjson.cJSON_GetObjectItem(src, "message") orelse return null;

        var id: ngx_str_t = empty_str;
        if (cjson.cJSON_GetObjectItem(msg, "id")) |id_item| {
            id = CJSON.stringValue(id_item) orelse empty_str;
        }
        var model_s: ngx_str_t = empty_str;
        if (cjson.cJSON_GetObjectItem(msg, "model")) |m| {
            model_s = CJSON.stringValue(m) orelse empty_str;
        }
        if (cjson.cJSON_GetObjectItem(msg, "usage")) |usage| {
            const in_raw = if (cjson.cJSON_GetObjectItem(usage, "input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            const cr_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_read_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            const cc_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_creation_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            const base: ngx_uint_t = if (in_raw > 0) @intCast(in_raw) else 0;
            const cr: ngx_uint_t = if (cr_raw > 0) @intCast(cr_raw) else 0;
            const cc: ngx_uint_t = if (cc_raw > 0) @intCast(cc_raw) else 0;
            const total_in = (base +| cr) +| cc;
            if (total_in > 0) ctx.sse_input_tokens = total_in;
            ctx.sse_cache_read_tokens = cr;
            ctx.sse_cache_create_tokens = cc;
        }

        const out = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(out, "id", id.data, &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(out, "object", "chat.completion.chunk", &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(out, "model", model_s.data, &cj.alloc);
        _ = cjson.cJSON_AddArrayToObject(out, "choices", &cj.alloc);
        const json = cj.encode(out) catch return null;
        return sse_build_data_event(r, sse_apply_stream_security(r, json));
    }

    if (std.mem.eql(u8, etype, "content_block_delta")) {
        // Target 6: fast path for text_delta — skip cJSON entirely.
        if (sse_fast_text_delta(data)) |text_raw| {
            if (sse_build_token_chunk(r, text_raw)) |chunk| {
                return sse_build_data_event(r, sse_apply_stream_security(r, chunk));
            }
            // OOM on chunk build — fall through to cJSON.
        }
        // Fall back: non-text_delta types or fast scan inconclusive.
        const src = cj.decode(data_str) catch return null;
        const delta_obj = cjson.cJSON_GetObjectItem(src, "delta") orelse return null;
        const dtype_item = cjson.cJSON_GetObjectItem(delta_obj, "type") orelse return null;
        const dtype = CJSON.stringValue(dtype_item) orelse return null;
        if (!std.mem.eql(u8, core.slicify(u8, dtype.data, dtype.len), "text_delta")) return null;

        const text_item = cjson.cJSON_GetObjectItem(delta_obj, "text") orelse return null;
        const text = CJSON.stringValue(text_item) orelse empty_str;

        const out = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        const choices = cjson.cJSON_AddArrayToObject(out, "choices", &cj.alloc) orelse return null;
        const choice = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        const delta_out = cjson.cJSON_AddObjectToObject(choice, "delta", &cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(delta_out, "content", text.data, &cj.alloc);
        _ = cjson.cJSON_AddNumberToObject(choice, "index", 0, &cj.alloc);
        _ = cjson.cJSON_AddNullToObject(choice, "finish_reason", &cj.alloc);
        _ = cjson.cJSON_AddItemToArray(choices, choice);
        _ = cjson.cJSON_AddStringToObject(out, "object", "chat.completion.chunk", &cj.alloc);
        const json = cj.encode(out) catch return null;
        return sse_build_data_event(r, sse_apply_stream_security(r, json));
    }

    if (std.mem.eql(u8, etype, "message_delta")) {
        const src = cj.decode(data_str) catch return null;

        var stop_reason: ngx_str_t = ngx_string("stop");
        if (cjson.cJSON_GetObjectItem(src, "delta")) |delta| {
            if (cjson.cJSON_GetObjectItem(delta, "stop_reason")) |sr| {
                if (CJSON.stringValue(sr)) |sv| stop_reason = map_stop_reason(sv);
            }
        }

        var output_tokens: ngx_uint_t = 0;
        if (cjson.cJSON_GetObjectItem(src, "usage")) |usage| {
            const out_raw = if (cjson.cJSON_GetObjectItem(usage, "output_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            if (out_raw > 0) output_tokens = @intCast(out_raw);
        }

        const pt = ctx.sse_input_tokens;
        const ct = output_tokens;
        const tt = pt +| ct;

        ctx.prompt_tokens = pt;
        ctx.completion_tokens = ct;
        ctx.total_tokens = tt;
        ctx.cache_read_tokens = ctx.sse_cache_read_tokens;
        ctx.cache_create_tokens = ctx.sse_cache_create_tokens;
        ctx.usage_extracted = 1;

        const out = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        const choices = cjson.cJSON_AddArrayToObject(out, "choices", &cj.alloc) orelse return null;
        const choice = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        _ = cjson.cJSON_AddObjectToObject(choice, "delta", &cj.alloc);
        _ = cjson.cJSON_AddNumberToObject(choice, "index", 0, &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(choice, "finish_reason", stop_reason.data, &cj.alloc);
        _ = cjson.cJSON_AddItemToArray(choices, choice);
        _ = cjson.cJSON_AddStringToObject(out, "object", "chat.completion.chunk", &cj.alloc);
        if (cjson.cJSON_AddObjectToObject(out, "usage", &cj.alloc)) |u| {
            _ = cjson.cJSON_AddNumberToObject(u, "prompt_tokens", @floatFromInt(pt), &cj.alloc);
            _ = cjson.cJSON_AddNumberToObject(u, "completion_tokens", @floatFromInt(ct), &cj.alloc);
            _ = cjson.cJSON_AddNumberToObject(u, "total_tokens", @floatFromInt(tt), &cj.alloc);
        }
        const json = cj.encode(out) catch return null;
        return sse_build_data_event(r, sse_apply_stream_security(r, json));
    }

    if (std.mem.eql(u8, etype, "message_stop")) {
        ctx.sse_saw_done = 1;
        return sse_build_done_event(r);
    }

    // content_block_start, content_block_stop, ping, unknown → skip
    return null;
}

// Translate a complete OpenAI SSE data line to one or more Anthropic SSE events.
// Reads data from ctx.sse_data_buf (populated by sse_process_line with is_anthropic_rewrite=true).
// Returns a concatenation of all emitted Anthropic events, or null to skip.
fn sse_translate_openai_event(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) ?ngx_str_t {
    const data_len = ctx.sse_data_len;
    if (data_len == 0 or ctx.sse_data_overflow == 1) return null;

    const data = core.slicify(u8, ctx.sse_data_buf, data_len);

    // [DONE] → message_stop
    if (std.mem.eql(u8, data, "[DONE]")) {
        ctx.sse_saw_done = 1;
        const json = ngx_string("{\"type\":\"message_stop\"}");
        return sse_build_named_event(r, "message_stop", json);
    }

    // Target 12: reverse fast path — common in-progress text token without cJSON.
    // Only valid after message_start / content_block_start have already been emitted.
    if (ctx.sse_sent_message_start == 1) {
        if (sse_fast_openai_content_delta(data)) |text_raw| {
            if (sse_build_content_block_delta(r, text_raw)) |cbd| {
                return sse_build_named_event(r, "content_block_delta", cbd);
            }
            return null; // OOM — skip chunk
        }
    }

    const data_str = ngx_str_t{ .data = @constCast(data.ptr), .len = data_len };
    var cj = CJSON.init(r.*.pool);
    const src = cj.decode(data_str) catch return null;

    if (detect_error_shape(src)) {
        ctx.response_is_error_shape = 1;
        ctx.failure_class = FAILURE_CLASS_SEMANTIC_ERROR;
        return null;
    }

    const choices = cjson.cJSON_GetObjectItem(src, "choices") orelse return null;
    if (cjson.cJSON_IsArray(choices) != 1 or choices.*.child == core.nullptr(cjson.cJSON)) return null;
    const choice = choices.*.child;
    if (cjson.cJSON_GetObjectItem(choice, "index")) |idx| {
        const idx_raw = CJSON.intValue(idx) orelse return null;
        if (idx_raw != 0) return null;
    }

    // Extract delta.content string (null JSON value is not content).
    var delta_content: ngx_str_t = empty_str;
    if (cjson.cJSON_GetObjectItem(choice, "delta")) |delta| {
        if (cjson.cJSON_GetObjectItem(delta, "content")) |content| {
            if (cjson.cJSON_IsString(content) == 1) {
                delta_content = CJSON.stringValue(content) orelse empty_str;
            }
        }
    }

    // Extract finish_reason (null JSON value means in-progress).
    var finish_reason: ngx_str_t = empty_str;
    var has_finish: bool = false;
    if (cjson.cJSON_GetObjectItem(choice, "finish_reason")) |fr| {
        if (cjson.cJSON_IsNull(fr) != 1) {
            finish_reason = CJSON.stringValue(fr) orelse empty_str;
            has_finish = true;
        }
    }

    // id and model from this chunk (present in first chunk).
    var chunk_id: ngx_str_t = empty_str;
    var chunk_model: ngx_str_t = empty_str;
    if (cjson.cJSON_GetObjectItem(src, "id")) |id_item| {
        chunk_id = CJSON.stringValue(id_item) orelse empty_str;
    }
    if (cjson.cJSON_GetObjectItem(src, "model")) |m_item| {
        chunk_model = CJSON.stringValue(m_item) orelse empty_str;
    }

    const emit_start = ctx.sse_sent_message_start == 0 and (delta_content.len > 0 or has_finish);

    // Static data for events that do not need cJSON encoding.
    const CBS_START_DATA = ngx_string("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
    const CBS_STOP_DATA = ngx_string("{\"type\":\"content_block_stop\",\"index\":0}");

    // Build cJSON-encoded payloads for events that need them.
    var start_json: ngx_str_t = empty_str;
    if (emit_start) {
        const start_out = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(start_out, "type", "message_start", &cj.alloc);
        const msg_out = cjson.cJSON_AddObjectToObject(start_out, "message", &cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(msg_out, "id", chunk_id.data, &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(msg_out, "type", "message", &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(msg_out, "role", "assistant", &cj.alloc);
        _ = cjson.cJSON_AddArrayToObject(msg_out, "content", &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(msg_out, "model", chunk_model.data, &cj.alloc);
        _ = cjson.cJSON_AddNullToObject(msg_out, "stop_reason", &cj.alloc);
        _ = cjson.cJSON_AddNullToObject(msg_out, "stop_sequence", &cj.alloc);
        if (cjson.cJSON_AddObjectToObject(msg_out, "usage", &cj.alloc)) |u| {
            _ = cjson.cJSON_AddNumberToObject(u, "input_tokens", 0, &cj.alloc);
            _ = cjson.cJSON_AddNumberToObject(u, "output_tokens", 0, &cj.alloc);
        }
        start_json = cj.encode(start_out) catch return null;
    }

    var cbd_json: ngx_str_t = empty_str;
    if (delta_content.len > 0) {
        const cbd_out = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(cbd_out, "type", "content_block_delta", &cj.alloc);
        _ = cjson.cJSON_AddNumberToObject(cbd_out, "index", 0, &cj.alloc);
        const delta_out = cjson.cJSON_AddObjectToObject(cbd_out, "delta", &cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(delta_out, "type", "text_delta", &cj.alloc);
        _ = cjson.cJSON_AddStringToObject(delta_out, "text", delta_content.data, &cj.alloc);
        cbd_json = cj.encode(cbd_out) catch return null;
    }

    var md_json: ngx_str_t = empty_str;
    var output_tokens: ngx_uint_t = 0;
    if (has_finish) {
        // Extract usage from OpenAI final chunk and populate ctx.
        if (cjson.cJSON_GetObjectItem(src, "usage")) |usage| {
            apply_openai_usage(usage, ctx);
            output_tokens = ctx.completion_tokens;
        }
        const md_out = cjson.cJSON_CreateObject(&cj.alloc) orelse return null;
        _ = cjson.cJSON_AddStringToObject(md_out, "type", "message_delta", &cj.alloc);
        const delta_obj = cjson.cJSON_AddObjectToObject(md_out, "delta", &cj.alloc) orelse return null;
        const stop_reason = map_finish_reason_to_anthropic(finish_reason);
        _ = cjson.cJSON_AddStringToObject(delta_obj, "stop_reason", stop_reason.data, &cj.alloc);
        _ = cjson.cJSON_AddNullToObject(delta_obj, "stop_sequence", &cj.alloc);
        if (cjson.cJSON_AddObjectToObject(md_out, "usage", &cj.alloc)) |u| {
            _ = cjson.cJSON_AddNumberToObject(u, "output_tokens", @floatFromInt(output_tokens), &cj.alloc);
        }
        md_json = cj.encode(md_out) catch return null;
    }

    // Pre-compute total output size, then allocate once and write all events.
    // Maximum single-chunk event burst: message_start + content_block_start +
    // content_block_delta + content_block_stop + message_delta = 5 events.
    var total: usize = 0;
    if (emit_start) {
        total += sse_event_byte_size("message_start".len, start_json.len);
        total += sse_event_byte_size("content_block_start".len, CBS_START_DATA.len);
    }
    if (cbd_json.len > 0) total += sse_event_byte_size("content_block_delta".len, cbd_json.len);
    if (has_finish) {
        total += sse_event_byte_size("content_block_stop".len, CBS_STOP_DATA.len);
        total += sse_event_byte_size("message_delta".len, md_json.len);
    }
    if (total == 0) return null;

    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const p = core.castPtr(u8, raw) orelse return null;
    var off: usize = 0;
    if (emit_start) {
        sse_write_event(p, &off, "message_start", start_json);
        sse_write_event(p, &off, "content_block_start", CBS_START_DATA);
        ctx.sse_sent_message_start = 1;
    }
    if (cbd_json.len > 0) sse_write_event(p, &off, "content_block_delta", cbd_json);
    if (has_finish) {
        sse_write_event(p, &off, "content_block_stop", CBS_STOP_DATA);
        sse_write_event(p, &off, "message_delta", md_json);
    }
    return ngx_str_t{ .data = p, .len = total };
}

// Process a complete Anthropic SSE event without rewriting it.
// Used by raw pass-through mode to keep token accounting correct.
fn sse_scan_anthropic_event(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) void {
    const etype_len = ctx.sse_event_type_len;
    const data_len = ctx.sse_data_len;

    if (data_len == 0 or ctx.sse_data_overflow == 1) return;

    const data = core.slicify(u8, ctx.sse_data_buf, data_len);
    const data_str = ngx_str_t{ .data = @constCast(data.ptr), .len = data_len };

    if (etype_len == 0) {
        if (std.mem.eql(u8, data, "[DONE]")) ctx.sse_saw_done = 1;
        return;
    }

    const etype = core.slicify(u8, ctx.sse_event_type_buf, etype_len);
    var cj = CJSON.init(r.*.pool);

    if (std.mem.eql(u8, etype, "message_start")) {
        const src = cj.decode(data_str) catch return;
        const msg = cjson.cJSON_GetObjectItem(src, "message") orelse return;
        const usage = cjson.cJSON_GetObjectItem(msg, "usage") orelse return;
        const in_raw = if (cjson.cJSON_GetObjectItem(usage, "input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const cr_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_read_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const cc_raw = if (cjson.cJSON_GetObjectItem(usage, "cache_creation_input_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const base: ngx_uint_t = if (in_raw > 0) @intCast(in_raw) else 0;
        const cr: ngx_uint_t = if (cr_raw > 0) @intCast(cr_raw) else 0;
        const cc: ngx_uint_t = if (cc_raw > 0) @intCast(cc_raw) else 0;
        const total_in = (base +| cr) +| cc;
        if (total_in > 0) ctx.sse_input_tokens = total_in;
        ctx.sse_cache_read_tokens = cr;
        ctx.sse_cache_create_tokens = cc;
        return;
    }

    if (std.mem.eql(u8, etype, "message_delta")) {
        const src = cj.decode(data_str) catch return;
        const usage = cjson.cJSON_GetObjectItem(src, "usage") orelse return;
        const out_raw = if (cjson.cJSON_GetObjectItem(usage, "output_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
        const pt = ctx.sse_input_tokens;
        const ct: ngx_uint_t = if (out_raw > 0) @intCast(out_raw) else 0;
        if (pt > 0 or ct > 0) {
            ctx.prompt_tokens = pt;
            ctx.completion_tokens = ct;
            ctx.total_tokens = pt +| ct;
            ctx.cache_read_tokens = ctx.sse_cache_read_tokens;
            ctx.cache_create_tokens = ctx.sse_cache_create_tokens;
            ctx.usage_extracted = 1;
        }
        return;
    }

    if (std.mem.eql(u8, etype, "message_stop")) {
        ctx.sse_saw_done = 1;
    }
}

// Process a complete SSE line (content between line-start and '\n', excluding '\n').
// For Anthropic: saves event type or data into ctx buffers.
// For OpenAI: scans data: lines for [DONE] and usage JSON.
fn sse_process_line(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, is_anthropic_rewrite: bool, line: []const u8) void {
    if (line.len == 0) return; // blank line — caller handles event boundary

    if (is_anthropic_rewrite) {
        const event_prefix = "event: ";
        if (std.mem.startsWith(u8, line, event_prefix)) {
            const val = line[event_prefix.len..];
            const copy_len = @min(val.len, 63);
            @memcpy(core.slicify(u8, ctx.sse_event_type_buf, copy_len), val[0..copy_len]);
            ctx.sse_event_type_len = copy_len;
            return;
        }
    }

    const data_prefix = "data: ";
    if (std.mem.startsWith(u8, line, data_prefix)) {
        const val = line[data_prefix.len..];
        if (!is_anthropic_rewrite) {
            // OpenAI pass-through: check for [DONE] and usage extraction.
            if (std.mem.eql(u8, val, "[DONE]")) {
                ctx.sse_saw_done = 1;
                return;
            }
            if (ctx.usage_extracted == 1) return; // already done
            // Try to parse JSON for a usage block (final chunk has usage).
            const val_str = ngx_str_t{ .data = @constCast(val.ptr), .len = val.len };
            var cj = CJSON.init(r.*.pool);
            const json = cj.decode(val_str) catch return;
            if (detect_error_shape(json)) return;
            const usage = cjson.cJSON_GetObjectItem(json, "usage") orelse return;
            // OpenAI format: prompt_tokens is total input; cache reads in prompt_tokens_details.
            const pt_raw = if (cjson.cJSON_GetObjectItem(usage, "prompt_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            const ct_raw = if (cjson.cJSON_GetObjectItem(usage, "completion_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            const tt_raw = if (cjson.cJSON_GetObjectItem(usage, "total_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
            const pt: ngx_uint_t = if (pt_raw > 0) @intCast(pt_raw) else 0;
            const ct: ngx_uint_t = if (ct_raw > 0) @intCast(ct_raw) else 0;
            const tt: ngx_uint_t = if (tt_raw > 0) @intCast(tt_raw) else pt +| ct;
            if (pt > 0 or ct > 0) {
                ctx.prompt_tokens = pt;
                ctx.completion_tokens = ct;
                ctx.total_tokens = tt;
                if (cjson.cJSON_GetObjectItem(usage, "prompt_tokens_details")) |details| {
                    const cr_raw = if (cjson.cJSON_GetObjectItem(details, "cached_tokens")) |v| CJSON.intValue(v) orelse 0 else @as(i64, 0);
                    if (cr_raw > 0 and @as(ngx_uint_t, @intCast(cr_raw)) <= pt) ctx.cache_read_tokens = @intCast(cr_raw);
                }
                ctx.usage_extracted = 1;
            }
            return;
        }
        // Anthropic rewrite: store data payload (buffer grows up to SSE_LINE_MAX_SIZE).
        if (!sse_ensure_data_buf(r, ctx)) return;
        if (!sse_data_store(r, ctx, val)) {
            ctx.sse_data_overflow = 1;
            return;
        }
    }
}

// SSE body filter for OpenAI responses (or Anthropic with normalize_response=off).
// Scans bytes for usage without modifying the output chain.
fn sse_scan_passthrough(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, in: [*c]ngx_chain_t) ngx_int_t {
    if (!sse_ensure_buffers(r, ctx)) {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    const is_anthropic_passthrough = dialect_is(ctx.*.effective_dialect, "anthropic");
    const sec_lccf = core.castPtr(
        llm_security_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
    );
    const rewrite_for_security = sec_lccf != null and sec_lccf.?.*.enabled == 1 and sec_lccf.?.*.inspect_response == 1;
    var out_head: ?[*c]ngx_chain_t = null;
    var out_tail: ?[*c]ngx_chain_t = null;
    var is_last = false;
    var chain = in;
    while (chain != core.nullptr(ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(ngx_buf_t)) continue;
        if (b.*.flags.last_buf or b.*.flags.last_in_chain) is_last = true;
        const chunk_size = buf.ngx_buf_size(b);
        if (chunk_size <= 0) continue;

        // Target 6: line-oriented scan — bulk memcpy + batch raw-line append.
        var remaining = core.slicify(u8, b.*.pos, @intCast(chunk_size));
        while (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_off| {
                const segment = remaining[0..nl_off];
                // Security path: batch-append segment then newline to raw_line_buf.
                if (rewrite_for_security) {
                    if (segment.len > 0 and !append_to_sse_raw_line(ctx, segment, r.*.pool)) return NGX_ERROR;
                    if (!append_to_sse_raw_line(ctx, "\n"[0..1], r.*.pool)) return NGX_ERROR;
                }
                // Bulk-copy segment into sse_line_buf.
                if (segment.len > 0 and (ctx.sse_line_overflow == 1 or !sse_line_append(r, ctx, segment))) {
                    ctx.sse_line_overflow = 1;
                }

                const line_len = sse_trimmed_line_len(ctx);
                const line: []const u8 = if (rewrite_for_security and ctx.sse_raw_line_len > 0) blk: {
                    const trimmed_len = sse_trimmed_raw_line_len(ctx);
                    break :blk core.slicify(u8, ctx.sse_raw_line_buf, trimmed_len);
                } else if (!rewrite_for_security and ctx.sse_line_overflow == 0 and line_len > 0) blk: {
                    break :blk core.slicify(u8, ctx.sse_line_buf, line_len);
                } else blk: {
                    break :blk ""[0..0];
                };

                if (ctx.sse_line_overflow == 0 and line.len > 0) {
                    sse_process_line(r, ctx, is_anthropic_passthrough, line);
                    if (rewrite_for_security) {
                        const data_prefix = "data: ";
                        const out_line = if (std.mem.startsWith(u8, line, data_prefix)) blk: {
                            const payload = line[data_prefix.len..];
                            if (std.mem.eql(u8, payload, "[DONE]")) break :blk sse_build_line(r, line);
                            const payload_str = ngx_str_t{ .data = @constCast(payload.ptr), .len = payload.len };
                            break :blk sse_rewrite_data_line(r, sse_apply_stream_security(r, payload_str));
                        } else sse_build_line(r, line);
                        if (out_line) |s| {
                            if (!sse_chain_append(r, &out_head, &out_tail, s)) return NGX_ERROR;
                        } else return NGX_ERROR;
                    }
                } else if (ctx.sse_line_overflow == 0) {
                    if (is_anthropic_passthrough) {
                        sse_scan_anthropic_event(r, ctx);
                        sse_reset_event(ctx);
                    }
                    if (rewrite_for_security) {
                        const blank = sse_rewrite_blank_line(r) orelse return NGX_ERROR;
                        if (!sse_chain_append(r, &out_head, &out_tail, blank)) return NGX_ERROR;
                    }
                } else if (rewrite_for_security) {
                    const trimmed = core.slicify(u8, ctx.sse_raw_line_buf, sse_trimmed_raw_line_len(ctx));
                    const out_line = sse_build_line(r, trimmed) orelse return NGX_ERROR;
                    if (!sse_chain_append(r, &out_head, &out_tail, out_line)) return NGX_ERROR;
                }
                sse_reset_physical_line(ctx);
                remaining = remaining[nl_off + 1 ..];
            } else {
                // No newline: accumulate remaining bytes into buffers.
                if (rewrite_for_security and !append_to_sse_raw_line(ctx, remaining, r.*.pool)) return NGX_ERROR;
                if (remaining.len > 0 and (ctx.sse_line_overflow == 1 or !sse_line_append(r, ctx, remaining))) {
                    ctx.sse_line_overflow = 1;
                }
                break;
            }
        }
    }

    if (rewrite_for_security) {
        var consume = in;
        while (consume != core.nullptr(ngx_chain_t)) : (consume = consume.*.next) {
            const cb = consume.*.buf;
            if (cb == core.nullptr(ngx_buf_t)) continue;
            if (buf.ngx_buf_in_memory(cb)) {
                cb.*.pos = cb.*.last;
            }
        }

        if (is_last) {
            if (!sse_chain_append_last_marker(r, &out_head, &out_tail)) {
                return if (ngx_http_llm_proxy_next_body_filter) |next| next(r, null) else NGX_OK;
            }
        }
        if (out_head) |head| {
            mark_response_started(ctx);
            if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, head);
            return NGX_OK;
        }
        if (!is_last) return NGX_OK;
    }

    mark_response_started(ctx);
    if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
    return NGX_OK;
}

// SSE body filter for Anthropic responses with normalize_response=on.
// Consumes input, emits translated OpenAI-format SSE events.
fn sse_rewrite_anthropic(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, in: [*c]ngx_chain_t) ngx_int_t {
    if (!sse_ensure_buffers(r, ctx)) {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    var out_head: ?[*c]ngx_chain_t = null;
    var out_tail: ?[*c]ngx_chain_t = null;
    var is_last = false;

    var chain = in;
    while (chain != core.nullptr(ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(ngx_buf_t)) continue;

        if (b.*.flags.last_buf or b.*.flags.last_in_chain) is_last = true;

        const chunk_size = buf.ngx_buf_size(b);
        if (chunk_size <= 0) continue;

        // Target 6: line-oriented scan — bulk memcpy instead of byte-at-a-time.
        var remaining = core.slicify(u8, b.*.pos, @intCast(chunk_size));
        while (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_off| {
                const segment = remaining[0..nl_off];
                if (segment.len > 0 and (ctx.sse_line_overflow == 1 or !sse_line_append(r, ctx, segment))) {
                    ctx.sse_line_overflow = 1;
                }
                const line_len = sse_trimmed_line_len(ctx);
                if (ctx.sse_line_overflow == 0 and line_len > 0) {
                    const line = core.slicify(u8, ctx.sse_line_buf, line_len);
                    sse_process_line(r, ctx, true, line);
                } else if (ctx.sse_line_overflow == 0) {
                    if (sse_translate_anthropic_event(r, ctx)) |event_str| {
                        if (!sse_chain_append(r, &out_head, &out_tail, event_str)) {
                            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OOM appending translated Anthropic SSE event", .{});
                            return NGX_ERROR;
                        }
                    }
                    sse_reset_event(ctx);
                }
                ctx.sse_line_len = 0;
                ctx.sse_line_overflow = 0;
                remaining = remaining[nl_off + 1 ..];
            } else {
                if (remaining.len > 0 and (ctx.sse_line_overflow == 1 or !sse_line_append(r, ctx, remaining))) {
                    ctx.sse_line_overflow = 1;
                }
                break;
            }
        }
    }

    // Consume all input buffers so nginx sees them as done and can finalize the
    // upstream. Without this, u->busy_bufs stays non-null after
    // ngx_chain_update_chains and nginx never calls finalize_request.
    var consume = in;
    while (consume != core.nullptr(ngx_chain_t)) : (consume = consume.*.next) {
        const cb = consume.*.buf;
        if (cb == core.nullptr(ngx_buf_t)) continue;
        if (buf.ngx_buf_in_memory(cb)) {
            cb.*.pos = cb.*.last;
        }
    }

    if (is_last) {
        if (ctx.sse_saw_done == 0) {
            log.ngz_log_error(NGX_LOG_DEBUG, r.*.connection.*.log, 0, "llm_proxy: Anthropic SSE stream ended without message_stop", .{});
        }
        if (!sse_chain_append_last_marker(r, &out_head, &out_tail)) {
            return if (ngx_http_llm_proxy_next_body_filter) |next| next(r, null) else NGX_OK;
        }
    }

    if (out_head) |head| {
        mark_response_started(ctx);
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, head);
    } else if (!is_last) {
        // Nothing to emit this call — OK, more data coming.
        return NGX_OK;
    }
    return NGX_OK;
}

// SSE body filter for OpenAI responses when the client requested Anthropic dialect.
// Consumes input, emits translated Anthropic-format SSE events.
fn sse_rewrite_openai_to_anthropic(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx, in: [*c]ngx_chain_t) ngx_int_t {
    if (!sse_ensure_buffers(r, ctx)) {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    var out_head: ?[*c]ngx_chain_t = null;
    var out_tail: ?[*c]ngx_chain_t = null;
    var is_last = false;

    var chain = in;
    while (chain != core.nullptr(ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(ngx_buf_t)) continue;

        if (b.*.flags.last_buf or b.*.flags.last_in_chain) is_last = true;

        const chunk_size = buf.ngx_buf_size(b);
        if (chunk_size <= 0) continue;

        var remaining = core.slicify(u8, b.*.pos, @intCast(chunk_size));
        while (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_off| {
                const segment = remaining[0..nl_off];
                if (segment.len > 0 and (ctx.sse_line_overflow == 1 or !sse_line_append(r, ctx, segment))) {
                    ctx.sse_line_overflow = 1;
                }
                const line_len = sse_trimmed_line_len(ctx);
                if (ctx.sse_line_overflow == 0 and line_len > 0) {
                    // Store data: lines in sse_data_buf for event translation.
                    const line = core.slicify(u8, ctx.sse_line_buf, line_len);
                    sse_process_line(r, ctx, true, line);
                } else if (ctx.sse_line_overflow == 0) {
                    // Blank line: event boundary — translate and emit.
                    if (sse_translate_openai_event(r, ctx)) |event_str| {
                        _ = sse_chain_append(r, &out_head, &out_tail, event_str);
                    }
                    sse_reset_event(ctx);
                }
                ctx.sse_line_len = 0;
                ctx.sse_line_overflow = 0;
                remaining = remaining[nl_off + 1 ..];
            } else {
                if (remaining.len > 0 and (ctx.sse_line_overflow == 1 or !sse_line_append(r, ctx, remaining))) {
                    ctx.sse_line_overflow = 1;
                }
                break;
            }
        }
    }

    // Consume all input buffers so nginx sees them as done and can finalize the upstream.
    var consume = in;
    while (consume != core.nullptr(ngx_chain_t)) : (consume = consume.*.next) {
        const cb = consume.*.buf;
        if (cb == core.nullptr(ngx_buf_t)) continue;
        if (buf.ngx_buf_in_memory(cb)) {
            cb.*.pos = cb.*.last;
        }
    }

    if (is_last) {
        if (ctx.sse_saw_done == 0) {
            log.ngz_log_error(NGX_LOG_DEBUG, r.*.connection.*.log, 0, "llm_proxy: OpenAI SSE stream ended without [DONE]", .{});
        }
        if (!sse_chain_append_last_marker(r, &out_head, &out_tail)) {
            return if (ngx_http_llm_proxy_next_body_filter) |next| next(r, null) else NGX_OK;
        }
    }

    if (out_head) |head| {
        mark_response_started(ctx);
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, head);
    } else if (!is_last) {
        return NGX_OK;
    }
    return NGX_OK;
}

// ── Phase 4: response body filter ────────────────────────────────────────────

export fn ngx_http_llm_proxy_body_filter(r: [*c]ngx_http_request_t, in: [*c]ngx_chain_t) callconv(.c) ngx_int_t {
    if (r != r.*.main) {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    const lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    };

    if (lccf.*.enabled != 1) {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    const ctx = get_ctx(r) orelse {
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    };

    // Already processed or too large: pass through unmodified.
    if (ctx.*.response_body_done == 1 or ctx.*.response_too_large == 1) {
        mark_response_started(ctx);
        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    // Streaming path (Phase 5 / Target 10): SSE state machine.
    // Use effective_provider/dialect: by body-filter time, detect_fallback_outcome has updated them.
    if (ctx.*.response_is_streaming == 1) {
        const normalize_on = lccf.*.normalize_response != 0;
        const req_d = ctx.*.requested_dialect;
        const eff_d = ctx.*.effective_dialect;
        if (normalize_on) {
            if (dialect_is(eff_d, "anthropic") and
                (req_d.len == 0 or dialect_is(req_d, "openai")))
            {
                // Anthropic upstream → OpenAI client: rewrite Anthropic SSE to OpenAI SSE.
                return sse_rewrite_anthropic(r, ctx, in);
            } else if (dialect_is(eff_d, "openai") and dialect_is(req_d, "anthropic")) {
                // OpenAI upstream → Anthropic client: synthesize Anthropic SSE from OpenAI SSE.
                return sse_rewrite_openai_to_anthropic(r, ctx, in);
            }
        }
        return sse_scan_passthrough(r, ctx, in);
    }

    // Target 7: pre-size the response buffer from Content-Length to avoid realloc churn.
    if (ctx.*.resp_buf == core.nullptr(u8) and r.*.headers_out.content_length_n > 0) {
        const cl: usize = @intCast(r.*.headers_out.content_length_n);
        if (cl <= lccf.*.max_response_size) {
            if (core.ngx_pnalloc(r.*.pool, cl)) |raw| {
                if (core.castPtr(u8, raw)) |p| {
                    ctx.*.resp_buf = p;
                    ctx.*.resp_buf_cap = cl;
                }
            }
        }
    }

    // Accumulate body chunks into the per-request buffer.
    var chain = in;
    var is_last = false;
    while (chain != core.nullptr(ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(ngx_buf_t)) continue;

        const chunk_size = buf.ngx_buf_size(b);
        if (chunk_size > 0) {
            const data = core.slicify(u8, b.*.pos, @intCast(chunk_size));
            if (ctx.*.resp_buf_len + data.len > lccf.*.max_response_size) {
                if (security_rejects_oversized_response(r)) {
                    ctx.*.response_body_done = 1;
                    log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: response exceeded max_response_size, rejecting by security policy", .{});
                    return http.ngx_http_filter_finalize_request(r, &ngx_http_llm_proxy_module, http.NGX_HTTP_FORBIDDEN);
                }
                ctx.*.response_too_large = 1;
                log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: response grew beyond max_response_size while buffering, passing through", .{});

                if (ctx.*.resp_buf_len > 0) {
                    const prefix = make_memory_chain(r, ngx_str_t{
                        .data = ctx.*.resp_buf,
                        .len = ctx.*.resp_buf_len,
                    }) orelse return NGX_ERROR;
                    prefix.*.next = chain;
                    mark_response_started(ctx);
                    if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, prefix);
                    return NGX_OK;
                }

                mark_response_started(ctx);
                if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, chain);
                return NGX_OK;
            }
            if (!append_to_resp_buffer(ctx, data, r.*.pool)) {
                log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: OOM accumulating response body, aborting", .{});
                return NGX_ERROR;
            }
        }

        if (b.*.flags.last_buf or b.*.flags.last_in_chain) is_last = true;
    }

    // Consume input buffers so nginx's busy_bufs drains when proxy_buffering off.
    var consume = in;
    while (consume != core.nullptr(ngx_chain_t)) : (consume = consume.*.next) {
        const cb = consume.*.buf;
        if (cb == core.nullptr(ngx_buf_t)) continue;
        if (buf.ngx_buf_in_memory(cb)) cb.*.pos = cb.*.last;
    }

    if (!is_last) return NGX_OK; // more chunks coming

    ctx.*.response_body_done = 1;

    const body = ngx_str_t{ .data = ctx.*.resp_buf, .len = ctx.*.resp_buf_len };
    const normalize_on = lccf.*.normalize_response != 0;

    // Determine the bytes to emit and extract usage.
    // Use effective_provider/dialect: by body-filter time, detect_fallback_outcome has updated them
    // to the backend that actually served the response (e.g. anthropic after fallback).
    const req_d = ctx.*.requested_dialect;
    const eff_d = ctx.*.effective_dialect;
    var emit_body: ngx_str_t = blk: {
        if (dialect_is(eff_d, "anthropic") and normalize_on and
            (req_d.len == 0 or dialect_is(req_d, "openai")))
        {
            // Anthropic upstream → OpenAI client: normalize response to OpenAI schema.
            if (normalize_anthropic_to_openai(r, ctx, body)) |new_body| {
                break :blk new_body;
            }
            // Normalization failed (error shape, parse error, OOM): pass original.
        } else if (dialect_is(eff_d, "openai") and dialect_is(req_d, "anthropic") and normalize_on) {
            // OpenAI upstream → Anthropic client: normalize response to Anthropic schema.
            if (normalize_openai_to_anthropic(r, ctx, body)) |new_body| {
                break :blk new_body;
            }
            // Normalization failed: pass original bytes, extract usage from OpenAI format.
            extract_usage_from_response(r, ctx, body);
        } else {
            // Native path or normalize_off: extract usage from the effective provider's wire format.
            extract_usage_from_response(r, ctx, body);
        }
        break :blk body;
    };

    // Security Phase 4: response inspection on the normalized body.
    // Runs after normalization so rules see canonical OpenAI-shaped content.
    {
        const sec_lccf = core.castPtr(
            llm_security_loc_conf_view,
            conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
        );
        if (sec_lccf != null and sec_lccf.?.*.enabled == 1 and sec_lccf.?.*.inspect_response == 1) {
            var out = emit_body;
            const sec_outcome = ngx_http_llm_security_inspect_response(r, emit_body, &out);
            if (sec_outcome.response_blocked == 1) {
                // Swap the upstream response for a clean 403 before any body bytes are emitted.
                return http.ngx_http_filter_finalize_request(r, &ngx_http_llm_proxy_module, http.NGX_HTTP_FORBIDDEN);
            }
            // For redact mode, out was updated in-place by inspect_response.
            if (sec_outcome.response_action == 3) { // SECURITY_ACTION_REDACT
                emit_body = out;
            }
        }
    }

    // Phase 6: log error bodies at notice level for 401/403 responses to
    // aid debugging of auth configuration issues in production.
    if (ctx.*.response_is_error_shape == 1) {
        const status = r.*.headers_out.status;
        if (status == 401 or status == 403) {
            log.ngz_log_error(NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_proxy: upstream returned HTTP %ui with error body", .{status});
        }
    }

    // Emit as a single last_buf buffer.
    // Guard: if emit_body is empty (upstream returned nothing, normalization fell through),
    // skip the data buffer and pass null to signal end-of-body.  A zero-size memory buf
    // with pos==last crashes nginx's write filter with a "zero size buf in writer" alert.
    mark_response_started(ctx);
    if (emit_body.len == 0) {
        const out_b = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return NGX_ERROR;
        out_b.*.flags.sync = true;
        out_b.*.flags.last_buf = r == r.*.main;
        out_b.*.flags.last_in_chain = true;

        var out_cl: ngx_chain_t = undefined;
        out_cl.buf = out_b;
        out_cl.next = null;

        if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, &out_cl);
        return NGX_OK;
    }

    const out_b = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return NGX_ERROR;
    out_b.*.pos = emit_body.data;
    out_b.*.last = emit_body.data + emit_body.len;
    out_b.*.flags.memory = true;
    out_b.*.flags.last_buf = r == r.*.main;
    out_b.*.flags.last_in_chain = true;

    var out_cl: ngx_chain_t = undefined;
    out_cl.buf = out_b;
    out_cl.next = null;

    if (ngx_http_llm_proxy_next_body_filter) |next| return next(r, &out_cl);
    return NGX_OK;
}

// ── ACCESS phase body handler ─────────────────────────────────────────────────

export fn ngx_http_llm_proxy_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };

    const ctx = get_ctx(r) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };

    // Phase 2: classify the request.
    const buffered_body_size = if (r.*.request_body != core.nullptr(http.ngx_http_request_body_t) and
        r.*.request_body.*.bufs != core.nullptr(buf.ngx_chain_t))
        request_body_chain_size(r.*.request_body.*.bufs)
    else
        null;
    const is_oversized = if (buffered_body_size) |body_size|
        body_size > lccf.*.max_body_size
    else
        r.*.request_body != core.nullptr(http.ngx_http_request_body_t) and
            r.*.request_body.*.received > 0 and
            @as(usize, @intCast(r.*.request_body.*.received)) > lccf.*.max_body_size;

    if (is_oversized and security_rejects_oversized_request(r)) {
        http.ngx_http_finalize_request(r, NGX_HTTP_REQUEST_ENTITY_TOO_LARGE);
        return;
    }

    // Read the body once; reuse the flat copy for both classification and translation.
    const body_opt: ?ngx_str_t = if (!is_oversized) request_body_content(r) else null;

    if (body_opt) |body| {
        extract_from_body(r, ctx, lccf, body);
    } else {
        classify_default(ctx, lccf);
    }

    // Milestone 2 Target 1 (Phase 6): apply pre-send replacement policy from llm-fallback.
    // Runs after classification (effective_provider is resolved) but before auth and translation.
    // A replacement rule changes the effective routing target BEFORE the first upstream send.
    // Unlike post-failure fallback, this fires on every request that matches the rule.
    {
        const fb_lccf = core.castPtr(
            llm_fallback_loc_conf_view,
            conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module),
        );
        if (fb_lccf != null and fb_lccf.?.*.enabled == 1 and ctx.*.effective_provider.len > 0) {
            const replacement = ngx_http_llm_fallback_lookup_replacement(r, ctx.*.effective_provider);
            if (replacement.len > 0) {
                ctx.*.effective_provider = replacement;
                ctx.*.provider = replacement; // backward-compat field
                ctx.*.upstream = find_upstream(replacement, lccf);
                ctx.*.provider_host = provider_to_host(replacement);
                ctx.*.effective_dialect = find_route_dialect(replacement, lccf);
                if (ctx.*.upstream.len == 0) {
                    log.ngz_log_error(NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_proxy: llm_fallback replacement target has no matching llm_proxy_route", .{});
                }
                ctx.*.replacement_happened = 1;
                ctx.*.resolution_outcome = RESOLUTION_OUTCOME_REPLACED_BY_POLICY;
            }
        }
    }

    // Keep nginx's concrete retry executor aligned with llm-fallback policy.
    // nginx retries the exact request body and headers; it cannot re-run our
    // provider translation/auth phases for another provider. Refuse that unsafe
    // replay before the first upstream send. Same-provider peer retries remain
    // available and do not require a hot-path context/layout change.
    {
        const max_attempts = ngx_http_llm_fallback_max_attempts_limit(r);
        if (max_attempts > 0) {
            if (core.castPtr(
                ngx_http_proxy_loc_conf_view,
                conf.ngx_http_get_module_loc_conf(r, &ngx_http_proxy_module),
            )) |plcf| {
                const fallback_route = ngx_http_llm_fallback_lookup_route(r, ctx.*.effective_provider);
                const cross_provider = fallback_route.secondary.len > 0 and
                    !std.ascii.eqlIgnoreCase(
                        core.slicify(u8, fallback_route.secondary.data, fallback_route.secondary.len),
                        core.slicify(u8, ctx.*.effective_provider.data, ctx.*.effective_provider.len),
                    );
                plcf.*.upstream.next_upstream_tries = if (cross_provider) 1 else max_attempts;
            }
        }
    }

    const auth_rc = apply_llm_auth_policy(r, ctx);
    if (auth_rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        http.ngx_http_finalize_request(r, auth_rc);
        return;
    }

    // Phase 12: reject requests that cannot be served as requested.
    // REJECTED_OUT_OF_SCOPE: client specified an explicit provider that has no route —
    //   always rejected regardless of catalog configuration (explicit intent must be honoured or denied).
    // REJECTED_UNRESOLVABLE: operator catalog is active but the model matched nothing —
    //   rejected only when model_patterns_count > 0 (without a catalog, silent default is backward-compat).
    if (ctx.*.body_parsed == 1) {
        const is_oos = ctx.*.resolution_outcome == RESOLUTION_OUTCOME_REJECTED_OUT_OF_SCOPE;
        const is_unresolvable = ctx.*.resolution_outcome == RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE and
            lccf.*.model_patterns_count > 0;
        if (is_oos or is_unresolvable) {
            http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
            return;
        }
    }

    // Phase 12: enforce dialect_mode=explicit_required.
    // When the operator requires an explicit dialect and inference was the only source, reject.
    if (lccf.*.dialect_mode == DIALECT_MODE_EXPLICIT_REQUIRED and ctx.*.body_parsed == 1) {
        if (ctx.*.requested_dialect_source == DIALECT_SOURCE_INFERRED_SHAPE) {
            http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
            return;
        }
    }

    ensure_provider_request_headers(r, ctx, lccf);

    // Phase 3 / Phase 13: request body translation.
    // Target 2: translation need is determined by dialect mismatch (requested vs effective),
    // not by provider/model names.
    if (ctx.*.body_parsed == 1) {
        if (body_opt) |body| {
            // normalize_response != 0 means "on" (NGX_CONF_UNSET = -1 also means on).
            const normalize_on = lccf.*.normalize_response != 0;
            // inject_usage != 0 means "on".
            const inject_on = lccf.*.inject_usage != 0;

            // Determine whether cross-dialect translation is needed.
            // Dialects are available when body_parsed == 1 and Phase 12 fields are populated.
            const req_dialect = ctx.*.requested_dialect;
            const eff_dialect = ctx.*.effective_dialect;
            const needs_translation = normalize_on and
                req_dialect.len > 0 and eff_dialect.len > 0 and
                !dialect_is(req_dialect, core.slicify(u8, eff_dialect.data, eff_dialect.len));

            if (needs_translation and dialect_is(req_dialect, "openai") and dialect_is(eff_dialect, "anthropic")) {
                // OpenAI client → Anthropic endpoint: translate request body.
                if (rewrite_openai_to_anthropic(r, ctx, body)) {
                    ctx.*.translation_happened = 1;
                } else if (lccf.*.translation_fail_closed == 1) {
                    ctx.*.request_translation_skipped = 1;
                    http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                    return;
                }
            } else if (needs_translation and dialect_is(req_dialect, "anthropic") and dialect_is(eff_dialect, "openai")) {
                // Anthropic client → OpenAI endpoint: translate request body.
                if (rewrite_anthropic_to_openai(r, ctx, body)) {
                    ctx.*.translation_happened = 1;
                    // Inject stream_options into the rewritten body for streaming requests.
                    if (inject_on and ctx.*.is_streaming == 1) {
                        if (request_body_content(r)) |new_body| {
                            _ = inject_openai_stream_usage_option(r, ctx, new_body);
                        }
                    }
                } else if (lccf.*.translation_fail_closed == 1) {
                    ctx.*.request_translation_skipped = 1;
                    http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                    return;
                }
            } else if (!needs_translation and inject_on and ctx.*.is_streaming == 1) {
                // Native path: inject stream_options for OpenAI-compatible endpoints.
                if (dialect_is(eff_dialect, "openai") or eff_dialect.len == 0) {
                    _ = inject_openai_stream_usage_option(r, ctx, body);
                }
            }
        }
    }

    // Security inspection (Phase 3 llm-security): runs on the canonical request body
    // after classification and translation. When llm-proxy rewrites the payload,
    // re-read the active request body so security sees the exact upstream bytes.
    const security_body_opt: ?ngx_str_t = if (ctx.*.request_rewritten == 1)
        request_body_content(r) orelse body_opt
    else
        body_opt;

    // Must happen before phases resume so a block decision prevents the upstream send entirely.
    if (security_body_opt) |body| {
        const sec_lccf = core.castPtr(
            llm_security_loc_conf_view,
            conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
        );
        if (sec_lccf != null and sec_lccf.?.*.enabled == 1) {
            const outcome = ngx_http_llm_security_inspect_request(r, body);
            if (outcome.blocked == 1) {
                ctx.*.request_blocked = 1;
                r.*.write_event_handler = http.ngx_http_core_run_phases;
                http.ngx_http_core_run_phases(r);
                return;
            }
        }
    }

    r.*.write_event_handler = http.ngx_http_core_run_phases;
    http.ngx_http_core_run_phases(r);
}

// ── ACCESS phase ──────────────────────────────────────────────────────────────

export fn ngx_http_llm_proxy_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;

    if (get_ctx(r)) |existing_ctx| {
        if (existing_ctx.*.request_blocked == 1) return http.NGX_HTTP_FORBIDDEN;
    }

    // Re-entry guard: a non-null ctx means the body callback already ran and
    // resumed phases. The handler must not read the body or set variables again.
    if (r.*.ctx[ngx_http_llm_proxy_module.ctx_index] != null) return NGX_DECLINED;

    const ctx = http.ngz_http_get_module_ctx(LlmProxyCtx, r, &ngx_http_llm_proxy_module) catch return NGX_ERROR;
    // ctx is zero-initialized by ngz_pcalloc_c: all fields are 0/empty.
    ctx.*.replay_safe = 1;

    const is_json = if (r.*.headers_in.content_type) |ct_hdr| blk: {
        const ct = core.slicify(u8, ct_hdr.*.value.data, ct_hdr.*.value.len);
        break :blk is_json_content_type(ct);
    } else false;

    if (r.*.headers_in.content_length_n > 0 and
        @as(usize, @intCast(r.*.headers_in.content_length_n)) > lccf.*.max_body_size and
        security_rejects_oversized_request(r))
    {
        return NGX_HTTP_REQUEST_ENTITY_TOO_LARGE;
    }

    if (!is_json) {
        if (request_security_enabled(r) and
            (r.*.headers_in.content_length_n < 0 or
                @as(usize, @intCast(r.*.headers_in.content_length_n)) <= lccf.*.max_body_size))
        {
            const rc = http.ngx_http_read_client_request_body(r, ngx_http_llm_proxy_body_handler);
            if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
            http.ngx_http_finalize_request(r, NGX_DONE);
            return NGX_DONE;
        }
        classify_default(ctx, lccf);
        const auth_rc = apply_llm_auth_policy(r, ctx);
        if (auth_rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return auth_rc;
        return NGX_DECLINED;
    }

    if (r.*.headers_in.content_length_n > 0 and
        @as(usize, @intCast(r.*.headers_in.content_length_n)) > lccf.*.max_body_size)
    {
        classify_default(ctx, lccf);
        const auth_rc = apply_llm_auth_policy(r, ctx);
        if (auth_rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return auth_rc;
        return NGX_DECLINED;
    }

    const rc = http.ngx_http_read_client_request_body(r, ngx_http_llm_proxy_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
    http.ngx_http_finalize_request(r, NGX_DONE);
    return NGX_DONE;
}

export fn ngx_http_llm_proxy_preaccess_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;
    if (r == r.*.main) return NGX_DECLINED;

    log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: subrequests are not supported on llm_proxy-enabled locations", .{});
    return http.NGX_HTTP_FORBIDDEN;
}

// ── Header filter ─────────────────────────────────────────────────────────────

export fn ngx_http_llm_proxy_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    if (r != r.*.main) {
        if (ngx_http_llm_proxy_next_header_filter) |next| return next(r);
        return NGX_OK;
    }

    const lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse {
        if (ngx_http_llm_proxy_next_header_filter) |next| return next(r);
        return NGX_OK;
    };

    if (lccf.*.enabled == 1) {
        var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);

        // Stamp X-LLM-Proxy on every response from an enabled location.
        if (headers.append()) |h| {
            h.*.hash = 1;
            h.*.key = gateway_header_name;
            h.*.value = gateway_header_value;
            h.*.lowcase_key = gateway_header_name.data;
        } else |_| {}

        // Phase 4: per-request context-driven actions.
        if (get_ctx(r)) |ctx| {
            // Stamp X-LLM-Provider when the provider is known and disclosure is enabled.
            // Phase 15: disclose_provider=off suppresses this header from the client response.
            // Internal ctx fields (effective_provider, etc.) are always populated regardless.
            const do_disclose_provider = lccf.*.disclose_provider != 0; // UNSET(-1) and 1 both != 0
            if (do_disclose_provider and ctx.*.provider.len > 0) {
                var provider_set = false;
                var part = &r.*.headers_out.headers.part;
                while (true) {
                    const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse break;
                    var i: usize = 0;
                    while (i < part.*.nelts) : (i += 1) {
                        const h = &hdrs[i];
                        if (h.*.key.len == provider_header_name.len and
                            std.ascii.eqlIgnoreCase(
                                core.slicify(u8, h.*.key.data, h.*.key.len),
                                core.slicify(u8, provider_header_name.data, provider_header_name.len),
                            ))
                        {
                            h.*.hash = 1;
                            h.*.value = ctx.*.provider;
                            h.*.lowcase_key = provider_header_lowcase.data;
                            provider_set = true;
                        }
                    }
                    if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
                    part = part.*.next;
                }

                if (!provider_set) {
                    if (headers.append()) |h| {
                        h.*.hash = 1;
                        h.*.key = provider_header_name;
                        h.*.value = ctx.*.provider;
                        h.*.lowcase_key = provider_header_lowcase.data;
                    } else |_| {}
                }
            } else if (!do_disclose_provider and ctx.*.provider.len > 0) {
                // Disclosure off: remove any upstream-supplied X-LLM-Provider header so
                // the gateway's provider identity is not leaked to the caller.
                var part = &r.*.headers_out.headers.part;
                while (true) {
                    const hdrs = core.castPtr(ngx_table_elt_t, part.*.elts) orelse break;
                    var dst: usize = 0;
                    var src: usize = 0;
                    while (src < part.*.nelts) : (src += 1) {
                        const h = &hdrs[src];
                        if (h.*.key.len == provider_header_name.len and
                            std.ascii.eqlIgnoreCase(
                                core.slicify(u8, h.*.key.data, h.*.key.len),
                                core.slicify(u8, provider_header_name.data, provider_header_name.len),
                            ))
                        {
                            continue; // drop
                        }
                        if (dst != src) hdrs[dst] = hdrs[src];
                        dst += 1;
                    }
                    part.*.nelts = @intCast(dst);
                    if (part.*.next == core.nullptr(@TypeOf(part.*))) break;
                    part = part.*.next;
                }
            }

            const sec_lccf2 = core.castPtr(
                llm_security_loc_conf_view,
                conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module),
            );
            const security_rewrites_response =
                sec_lccf2 != null and
                sec_lccf2.?.*.enabled == 1 and
                sec_lccf2.?.*.inspect_response == 1 and
                (sec_lccf2.?.*.mode == 2 or sec_lccf2.?.*.mode == 3); // block or redact
            const reject_oversized_response =
                sec_lccf2 != null and
                sec_lccf2.?.*.enabled == 1 and
                sec_lccf2.?.*.inspect_response == 1 and
                sec_lccf2.?.*.reject_oversized_response == 1;

            classify_upstream_failure(r, ctx);

            // Detect retries before provider-specific response handling so the
            // effective_* fields reflect the backend that actually served the
            // current response.
            detect_fallback_outcome(r, ctx);

            // Detect SSE response. When the upstream already supplied a bounded
            // Content-Length and response inspection may rewrite bytes, prefer
            // the buffered response path over in-place stream editing.
            const ct = r.*.headers_out.content_type;
            if (ct.len > 0) {
                const ct_s = core.slicify(u8, ct.data, ct.len);
                if (std.mem.indexOf(u8, ct_s, "text/event-stream") != null) {
                    const cl_n = r.*.headers_out.content_length_n;
                    const bounded_sse_for_security =
                        security_rewrites_response and cl_n >= 0;
                    ctx.*.response_is_streaming = if (bounded_sse_for_security) 0 else 1;
                }
            }

            // For responses that will be normalised across dialects, clear
            // Content-Length now (before headers are sent) because the body
            // filter may rewrite the body to a different length.
            const normalize_on = lccf.*.normalize_response != 0;
            const req_d = ctx.*.requested_dialect;
            const eff_d = ctx.*.effective_dialect;
            const will_normalize_response = normalize_on and (
                // Anthropic effective → OpenAI requested
                (dialect_is(eff_d, "anthropic") and (req_d.len == 0 or dialect_is(req_d, "openai"))) or
                    // OpenAI effective → Anthropic requested
                    (dialect_is(eff_d, "openai") and dialect_is(req_d, "anthropic")));
            if (will_normalize_response) {
                if (ctx.*.response_is_streaming == 0) {
                    const cl_n = r.*.headers_out.content_length_n;
                    const max_resp: usize = lccf.*.max_response_size;
                    if (cl_n > 0 and @as(usize, @intCast(cl_n)) > max_resp) {
                        if (reject_oversized_response) {
                            http.ngx_http_clear_content_length(r);
                        } else {
                            ctx.*.response_too_large = 1;
                            log.ngz_log_error(NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_proxy: upstream response exceeds max_response_size, passing through", .{});
                        }
                    } else {
                        http.ngx_http_clear_content_length(r);
                    }
                } else {
                    http.ngx_http_clear_content_length(r);
                }
            }

            // Security Phase 4: if inspect_response may replace the upstream
            // response with a block page or a redacted body, clear
            // Content-Length now so the body filter can safely swap bytes later.
            {
                if (security_rewrites_response or reject_oversized_response) {
                    http.ngx_http_clear_content_length(r);
                }
            }

            // Phase 6: parse provider rate-limit headers into per-request ctx fields.
            parse_ratelimit_headers(ctx, r);

            if (ctx.*.failure_class != FAILURE_CLASS_NONE) {
                if (headers.append()) |h| {
                    h.*.hash = 1;
                    h.*.key = failure_class_name;
                    h.*.value = failure_class_to_str(ctx.*.failure_class);
                    h.*.lowcase_key = failure_class_lowcase.data;
                } else |_| {}
            }
        }
    }

    if (ngx_http_llm_proxy_next_header_filter) |next| return next(r);
    return NGX_OK;
}

// Inspect r->upstream_states to determine if a retry happened, populate
// the fallback outcome fields in ctx, and stamp X-Fallback-* response headers.
// Headers are stamped directly (not via add_header) because ngx_http_headers_filter_module
// runs before llm-proxy in the filter chain and would capture empty variable values.
fn detect_fallback_outcome(r: [*c]ngx_http_request_t, ctx: *LlmProxyCtx) void {
    const fb_lccf = core.castPtr(
        llm_fallback_loc_conf_view,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module),
    ) orelse return;
    if (fb_lccf.*.enabled != 1) return;
    const proxy_lccf = core.castPtr(
        llm_proxy_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_proxy_module),
    ) orelse return;

    // Phase 14: use effective_provider (Phase 12 field) as the authoritative primary.
    // This is what we actually tried to send to on the first hop, as recorded in ACCESS phase.
    ctx.*.fallback_primary_provider = if (ctx.*.effective_provider.len > 0)
        ctx.*.effective_provider
    else
        ctx.*.provider;

    const us = r.*.upstream_states;
    const first_reason = infer_failure_reason_from_upstream_states(r);
    ctx.*.fallback_attempt_count = if (us != null) us.*.nelts else 0;

    ctx.*.fallback_reason = first_reason;
    if (ctx.*.failure_class == FAILURE_CLASS_NONE and first_reason != FALLBACK_REASON_NONE) {
        ctx.*.failure_class = fallback_reason_to_failure_class(first_reason);
    }
    if (first_reason != FALLBACK_REASON_NONE and ngx_http_llm_fallback_is_reason_retryable(r, first_reason, ctx.*.is_streaming) == 1) {
        ctx.*.fallback_policy_allowed = 1;
    }

    const retried = us != null and us.*.nelts > 1;
    if (retried) {
        ctx.*.fallback_attempted = 1;
        if (ctx.*.fallback_policy_allowed != 1) {
            ctx.*.fallback_policy_mismatch = 1;
        }
        // Phase 14: a retry always means the resolution outcome was fallback_after_failure,
        // overriding whatever was recorded in ACCESS phase (as_requested for first hop).
        ctx.*.resolution_outcome = RESOLUTION_OUTCOME_FALLBACK_AFTER_FAILURE;

        // Resolve fallback route metadata in one scan so secondary/model stay in sync.
        const fallback_route = ngx_http_llm_fallback_lookup_route(r, ctx.*.provider);
        ctx.*.fallback_effective_provider = if (fallback_route.secondary.len > 0)
            fallback_route.secondary
        else
            ctx.*.provider;
        ctx.*.effective_provider = ctx.*.fallback_effective_provider;
        ctx.*.upstream = find_upstream(ctx.*.fallback_effective_provider, proxy_lccf);
        ctx.*.provider_host = provider_to_host(ctx.*.fallback_effective_provider);
        if (ctx.*.upstream.len == 0) {
            log.ngz_log_error(NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_proxy: llm_fallback retry target has no matching llm_proxy_route", .{});
        }

        // Milestone 2 Target 2 (Phase 7): if the matched fallback route has a model override,
        // update effective_model so downstream modules see the correct target model.
        if (fallback_route.target_model.len > 0) {
            ctx.*.effective_model = fallback_route.target_model;
        }

        // Milestone 2 Target 3 (Phase 8): check translation fallback policy.
        // Compare the client's requested_dialect against the FALLBACK TARGET's dialect,
        // using the route-declared dialect when present. Provider-name inference is only
        // the fallback. Replay policy must follow endpoint capability, not branding.
        const req_d = ctx.*.requested_dialect;
        const fallback_target_dialect = find_route_dialect(ctx.*.fallback_effective_provider, proxy_lccf);
        if (fallback_target_dialect.len > 0) {
            ctx.*.effective_dialect = fallback_target_dialect;
        }
        const cross_dialect = req_d.len > 0 and fallback_target_dialect.len > 0 and
            !std.ascii.eqlIgnoreCase(
                core.slicify(u8, req_d.data, req_d.len),
                core.slicify(u8, fallback_target_dialect.data, fallback_target_dialect.len),
            );
        if (cross_dialect) {
            const trans_policy = ngx_http_llm_fallback_translation_policy(r);
            if (trans_policy == TRANSLATION_FALLBACK_DISCOURAGE or trans_policy == TRANSLATION_FALLBACK_FORBID) {
                // Policy does not allow translation fallback — the retry was against policy.
                ctx.*.fallback_policy_mismatch = 1;
            }
            if (trans_policy == TRANSLATION_FALLBACK_FORBID) {
                // Mark as explicitly forbidden; suppressed_reason signals the cause.
                ctx.*.fallback_suppressed_reason = ngx_string("translation_forbidden");
            }
        }
    } else if (ctx.*.fallback_reason != FALLBACK_REASON_NONE) {
        const fallback_route = ngx_http_llm_fallback_lookup_route(r, ctx.*.fallback_primary_provider);
        const cross_provider = fallback_route.secondary.len > 0 and
            !std.ascii.eqlIgnoreCase(
                core.slicify(u8, fallback_route.secondary.data, fallback_route.secondary.len),
                core.slicify(u8, ctx.*.fallback_primary_provider.data, ctx.*.fallback_primary_provider.len),
            );
        if (cross_provider and ctx.*.fallback_policy_allowed == 1) {
            ctx.*.fallback_suppressed = 1;
            ctx.*.fallback_suppressed_reason = ngx_string("cross_provider_replay_unsafe");
        } else if (ctx.*.is_streaming == 1) {
            const retryable_nonstream = ngx_http_llm_fallback_is_reason_retryable(r, first_reason, 0);
            const retryable_stream = ngx_http_llm_fallback_is_reason_retryable(r, first_reason, 1);
            if (retryable_nonstream == 1 and retryable_stream == 0) {
                ctx.*.fallback_suppressed = 1;
                ctx.*.fallback_suppressed_reason = ngx_string("streaming_not_allowed");
            }
        }
    }

    // Stamp X-Fallback-* headers directly so they survive the filter chain regardless
    // of where ngx_http_headers_filter_module sits in the execution order.
    var hdrs = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    if (ctx.*.fallback_primary_provider.len > 0) {
        if (hdrs.append()) |h| {
            h.*.hash = 1;
            h.*.key = fallback_primary_name;
            h.*.value = ctx.*.fallback_primary_provider;
            h.*.lowcase_key = fallback_primary_lowcase.data;
        } else |_| {}
    }
    if (hdrs.append()) |h| {
        h.*.hash = 1;
        h.*.key = fallback_attempted_name;
        h.*.value = if (ctx.*.fallback_attempted == 1) ngx_string("1") else ngx_string("0");
        h.*.lowcase_key = fallback_attempted_lowcase.data;
    } else |_| {}
    if (hdrs.append()) |h| {
        h.*.hash = 1;
        h.*.key = fallback_suppressed_name;
        h.*.value = if (ctx.*.fallback_suppressed == 1) ngx_string("1") else ngx_string("0");
        h.*.lowcase_key = fallback_suppressed_lowcase.data;
    } else |_| {}
    if (hdrs.append()) |h| {
        h.*.hash = 1;
        h.*.key = fallback_attempt_count_name;
        h.*.value = uint_to_str(ctx.*.fallback_attempt_count, r);
        h.*.lowcase_key = fallback_attempt_count_lowcase.data;
    } else |_| {}
    if (ctx.*.fallback_suppressed_reason.len > 0) {
        if (hdrs.append()) |h| {
            h.*.hash = 1;
            h.*.key = fallback_suppressed_reason_name;
            h.*.value = ctx.*.fallback_suppressed_reason;
            h.*.lowcase_key = fallback_suppressed_reason_lowcase.data;
        } else |_| {}
    }
    if (ctx.*.fallback_reason != 0) {
        if (hdrs.append()) |h| {
            h.*.hash = 1;
            h.*.key = fallback_reason_name;
            h.*.value = fallback_reason_to_str(ctx.*.fallback_reason);
            h.*.lowcase_key = fallback_reason_lowcase.data;
        } else |_| {}
    }
    if (hdrs.append()) |h| {
        h.*.hash = 1;
        h.*.key = fallback_policy_allowed_name;
        h.*.value = if (ctx.*.fallback_policy_allowed == 1) ngx_string("1") else ngx_string("0");
        h.*.lowcase_key = fallback_policy_allowed_lowcase.data;
    } else |_| {}
    if (hdrs.append()) |h| {
        h.*.hash = 1;
        h.*.key = fallback_policy_mismatch_name;
        h.*.value = if (ctx.*.fallback_policy_mismatch == 1) ngx_string("1") else ngx_string("0");
        h.*.lowcase_key = fallback_policy_mismatch_lowcase.data;
    } else |_| {}
    if (ctx.*.fallback_attempted == 1 and ctx.*.fallback_effective_provider.len > 0) {
        if (hdrs.append()) |h| {
            h.*.hash = 1;
            h.*.key = fallback_effective_name;
            h.*.value = ctx.*.fallback_effective_provider;
            h.*.lowcase_key = fallback_effective_lowcase.data;
        } else |_| {}
    }
}

// ── Configuration callbacks ───────────────────────────────────────────────────

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Insert into header filter chain.
    ngx_http_llm_proxy_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_llm_proxy_header_filter;

    // Insert into body filter chain.
    ngx_http_llm_proxy_next_body_filter = http.ngx_http_top_body_filter;
    http.ngx_http_top_body_filter = ngx_http_llm_proxy_body_filter;

    // Register $llm_* nginx variables.
    const var_defs = [_]struct {
        name: []const u8,
        getter: *const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, core.uintptr_t) callconv(.c) ngx_int_t,
    }{
        .{ .name = "llm_provider", .getter = &var_provider },
        .{ .name = "llm_provider_host", .getter = &var_provider_host },
        .{ .name = "llm_provider_version", .getter = &var_provider_version },
        .{ .name = "llm_model", .getter = &var_model },
        .{ .name = "llm_streaming", .getter = &var_streaming },
        .{ .name = "llm_provider_upstream", .getter = &var_upstream },
        .{ .name = "llm_prompt_tokens", .getter = &var_prompt_tokens },
        .{ .name = "llm_completion_tokens", .getter = &var_completion_tokens },
        .{ .name = "llm_total_tokens", .getter = &var_total_tokens },
        // Phase 6: rate-limit variables (set in header filter, usable with add_header)
        .{ .name = "llm_reset_after_ms", .getter = &var_reset_after_ms },
        .{ .name = "llm_ratelimit_remaining_tokens", .getter = &var_ratelimit_remaining_tokens },
        .{ .name = "llm_ratelimit_remaining_requests", .getter = &var_ratelimit_remaining_requests },
        // llm-metrics cross-module contract: binary flags for observability
        .{ .name = "llm_body_parsed", .getter = &var_body_parsed },
        .{ .name = "llm_usage_extracted", .getter = &var_usage_extracted },
        .{ .name = "llm_response_is_error", .getter = &var_response_is_error },
        // Phase 7 auth/failure/replay substrate
        .{ .name = "llm_auth_prepared", .getter = &var_auth_prepared },
        .{ .name = "llm_auth_failed", .getter = &var_auth_failed },
        .{ .name = "llm_proxy_auth_fail_reason", .getter = &var_auth_fail_reason },
        .{ .name = "llm_failure_class", .getter = &var_failure_class },
        .{ .name = "llm_replay_safe", .getter = &var_replay_safe },
        .{ .name = "llm_response_started", .getter = &var_response_started },
        // llm-fallback Phase 4 outcome variables
        .{ .name = "llm_fallback_attempted", .getter = &var_fallback_attempted },
        .{ .name = "llm_fallback_suppressed", .getter = &var_fallback_suppressed },
        .{ .name = "llm_fallback_suppressed_reason", .getter = &var_fallback_suppressed_reason },
        .{ .name = "llm_fallback_effective_provider", .getter = &var_fallback_effective_provider },
        .{ .name = "llm_fallback_primary_provider", .getter = &var_fallback_primary_provider },
        .{ .name = "llm_fallback_reason", .getter = &var_fallback_reason },
        .{ .name = "llm_fallback_policy_allowed", .getter = &var_fallback_policy_allowed },
        .{ .name = "llm_fallback_policy_mismatch", .getter = &var_fallback_policy_mismatch },
        .{ .name = "llm_fallback_attempt_count", .getter = &var_fallback_attempt_count },
        // Phase 12 (Milestone 2 Target 1): request identity and resolution substrate
        .{ .name = "llm_requested_provider", .getter = &var_requested_provider },
        .{ .name = "llm_requested_model", .getter = &var_requested_model },
        .{ .name = "llm_requested_dialect", .getter = &var_requested_dialect },
        .{ .name = "llm_requested_dialect_source", .getter = &var_requested_dialect_source },
        .{ .name = "llm_effective_provider", .getter = &var_effective_provider },
        .{ .name = "llm_effective_model", .getter = &var_effective_model },
        .{ .name = "llm_effective_dialect", .getter = &var_effective_dialect },
        .{ .name = "llm_resolution_outcome", .getter = &var_resolution_outcome },
        // Phase 13 (Milestone 2 Target 2): translation observability
        .{ .name = "llm_translation_happened", .getter = &var_translation_happened },
        // Phase 14 (Milestone 2 Target 3): replacement observability
        .{ .name = "llm_replacement_happened", .getter = &var_replacement_happened },
        // Target 9: cached-token usage variables
        .{ .name = "llm_cache_read_tokens", .getter = &var_cache_read_tokens },
        .{ .name = "llm_cache_create_tokens", .getter = &var_cache_create_tokens },
    };
    for (&var_defs) |*vd| {
        var vn = ngx_str_t{ .len = vd.name.len, .data = @constCast(vd.name.ptr) };
        if (http.ngx_http_add_variable(cf, &vn, http.NGX_HTTP_VAR_NOCACHEABLE)) |v| {
            v.*.get_handler = vd.getter;
            v.*.data = 0;
        }
    }

    // Register PREACCESS and ACCESS phase handlers.
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var preaccess_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_PREACCESS_PHASE].handlers,
    );
    const preaccess = preaccess_handlers.append() catch return NGX_ERROR;
    preaccess.* = ngx_http_llm_proxy_preaccess_handler;

    var access_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const access = access_handlers.append() catch return NGX_ERROR;
    access.* = ngx_http_llm_proxy_access_handler;

    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(llm_proxy_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.max_body_size = DEFAULT_MAX_BODY_SIZE;
        p.*.routes_count = 0;
        p.*.default_provider = empty_str;
        p.*.normalize_response = conf.NGX_CONF_UNSET;
        p.*.inject_usage = conf.NGX_CONF_UNSET;
        p.*.provider_versions_count = 0;
        p.*.max_response_size = DEFAULT_MAX_RESPONSE_SIZE;
        // Phase 12: dialect defaults
        p.*.dialect_mode = DIALECT_MODE_INFER;
        p.*.ingress_dialect = empty_str;
        p.*.model_patterns_count = 0;
        // Phase 15: disclosure defaults (unset = on)
        p.*.disclose_provider = conf.NGX_CONF_UNSET;
        p.*.translation_fail_closed = conf.NGX_CONF_UNSET;
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev: *llm_proxy_loc_conf = @ptrCast(core.castPtr(llm_proxy_loc_conf, parent) orelse return conf.NGX_CONF_OK);
    const c: *llm_proxy_loc_conf = @ptrCast(core.castPtr(llm_proxy_loc_conf, child) orelse return conf.NGX_CONF_OK);

    if (c.enabled == conf.NGX_CONF_UNSET) {
        c.enabled = if (prev.enabled == conf.NGX_CONF_UNSET) 0 else prev.enabled;
    }
    if (c.max_body_size == DEFAULT_MAX_BODY_SIZE and prev.max_body_size != DEFAULT_MAX_BODY_SIZE) {
        c.max_body_size = prev.max_body_size;
    }
    if (c.routes_count == 0 and prev.routes_count > 0) {
        var i: usize = 0;
        while (i < prev.routes_count) : (i += 1) {
            c.routes[i] = prev.routes[i];
        }
        c.routes_count = prev.routes_count;
    }
    if (c.default_provider.len == 0 and prev.default_provider.len > 0) {
        c.default_provider = prev.default_provider;
    }
    // Phase 3: merge normalize_response and inject_usage (default: on).
    if (c.normalize_response == conf.NGX_CONF_UNSET) {
        c.normalize_response = if (prev.normalize_response == conf.NGX_CONF_UNSET) 1 else prev.normalize_response;
    }
    if (c.inject_usage == conf.NGX_CONF_UNSET) {
        c.inject_usage = if (prev.inject_usage == conf.NGX_CONF_UNSET) 1 else prev.inject_usage;
    }
    if (c.provider_versions_count == 0 and prev.provider_versions_count > 0) {
        var i: usize = 0;
        while (i < prev.provider_versions_count) : (i += 1) {
            c.provider_versions[i] = prev.provider_versions[i];
        }
        c.provider_versions_count = prev.provider_versions_count;
    }
    if (c.max_response_size == DEFAULT_MAX_RESPONSE_SIZE and prev.max_response_size != DEFAULT_MAX_RESPONSE_SIZE) {
        c.max_response_size = prev.max_response_size;
    }
    // Phase 12: merge dialect and model catalog settings.
    if (c.dialect_mode == DIALECT_MODE_INFER and prev.dialect_mode != DIALECT_MODE_INFER) {
        c.dialect_mode = prev.dialect_mode;
    }
    if (c.ingress_dialect.len == 0 and prev.ingress_dialect.len > 0) {
        c.ingress_dialect = prev.ingress_dialect;
    }
    if (c.model_patterns_count == 0 and prev.model_patterns_count > 0) {
        var i: usize = 0;
        while (i < prev.model_patterns_count) : (i += 1) {
            c.model_patterns[i] = prev.model_patterns[i];
        }
        c.model_patterns_count = prev.model_patterns_count;
    }

    // Phase 15: merge disclose_provider (default: on).
    if (c.disclose_provider == conf.NGX_CONF_UNSET) {
        c.disclose_provider = if (prev.disclose_provider == conf.NGX_CONF_UNSET) 1 else prev.disclose_provider;
    }
    if (c.translation_fail_closed == conf.NGX_CONF_UNSET) {
        c.translation_fail_closed = if (prev.translation_fail_closed == conf.NGX_CONF_UNSET) 1 else prev.translation_fail_closed;
    }

    // Validate: routes without a default means unknown models have no destination.
    if (c.enabled == 1 and c.routes_count > 0 and c.default_provider.len == 0 and c.model_patterns_count == 0) {
        log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: llm_proxy_route is set but llm_proxy_default_provider is missing", .{});
        return conf.NGX_CONF_ERROR;
    }
    // Validate: dialect_mode=fixed requires ingress_dialect.
    if (c.enabled == 1 and c.dialect_mode == DIALECT_MODE_FIXED and c.ingress_dialect.len == 0) {
        log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: llm_proxy_dialect_mode fixed requires llm_proxy_ingress_dialect to be set", .{});
        return conf.NGX_CONF_ERROR;
    }
    if (c.enabled == 1 and c.model_patterns_count > 0) {
        var i: usize = 0;
        while (i < c.model_patterns_count) : (i += 1) {
            const pattern = &c.model_patterns[i];
            if (!has_route_for_provider(pattern.provider, c)) {
                log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: llm_proxy_model_pattern provider has no matching llm_proxy_route", .{});
                return conf.NGX_CONF_ERROR;
            }
        }
    }

    return conf.NGX_CONF_OK;
}

// ── Directive handlers ────────────────────────────────────────────────────────

// `llm_proxy;` — enable the module for this location.
fn ngx_conf_set_llm_proxy(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(llm_proxy_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_route <provider> <upstream>;`
fn ngx_conf_set_llm_proxy_route(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_proxy_loc_conf = @ptrCast(core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK);
    if (lccf.routes_count >= MAX_ROUTES) {
        log.ngz_log_error(NGX_LOG_WARN, cf.*.log, 0, "llm_proxy: route limit reached (max 8), this route is ignored", .{});
        return conf.NGX_CONF_OK;
    }

    var i: ngx_uint_t = 1;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const upstream = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    // Optional 3rd arg: endpoint dialect ("openai" | "anthropic").
    const dialect_opt = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    if (dialect_opt) |d| {
        if (!dialect_is_supported(d.*)) {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: invalid llm_proxy_route dialect: must be openai or anthropic", .{});
            return conf.NGX_CONF_ERROR;
        }
    }

    var existing: usize = 0;
    while (existing < lccf.routes_count) : (existing += 1) {
        const route = &lccf.routes[existing];
        if (route.provider.len == provider.*.len and
            std.mem.eql(u8, core.slicify(u8, route.provider.data, route.provider.len), core.slicify(u8, provider.*.data, provider.*.len)))
        {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: duplicate llm_proxy_route provider", .{});
            return conf.NGX_CONF_ERROR;
        }
    }

    const slot = lccf.routes_count;
    lccf.routes[slot].provider = provider.*;
    lccf.routes[slot].upstream = upstream.*;
    lccf.routes[slot].dialect = if (dialect_opt) |d| d.* else empty_str;
    lccf.routes_count += 1;
    return conf.NGX_CONF_OK;
}

// `llm_proxy_default_provider <provider>;`
fn ngx_conf_set_llm_proxy_default_provider(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        lccf.*.default_provider = arg.*;
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_max_body_size <size>;`
fn ngx_conf_set_llm_proxy_max_body_size(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        // Accept plain integers (bytes) or values ending in k/K/m/M.
        if (s.len > 0) {
            const last = s[s.len - 1];
            if (last == 'k' or last == 'K') {
                lccf.*.max_body_size = (std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch DEFAULT_MAX_BODY_SIZE) * 1024;
            } else if (last == 'm' or last == 'M') {
                lccf.*.max_body_size = (std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch DEFAULT_MAX_BODY_SIZE) * 1024 * 1024;
            } else {
                lccf.*.max_body_size = std.fmt.parseInt(usize, s, 10) catch DEFAULT_MAX_BODY_SIZE;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_normalize_response on|off;`
fn ngx_conf_set_llm_proxy_normalize_response(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.eql(u8, s, "on")) {
            lccf.*.normalize_response = 1;
        } else if (std.mem.eql(u8, s, "off")) {
            lccf.*.normalize_response = 0;
        } else {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: invalid value for llm_proxy_normalize_response: must be on or off", .{});
            return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_translation_fail_closed on|off;`
fn ngx_conf_set_llm_proxy_translation_fail_closed(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.eql(u8, s, "on")) {
            lccf.*.translation_fail_closed = 1;
        } else if (std.mem.eql(u8, s, "off")) {
            lccf.*.translation_fail_closed = 0;
        } else {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: invalid value for llm_proxy_translation_fail_closed: must be on or off", .{});
            return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_inject_usage on|off;`
fn ngx_conf_set_llm_proxy_inject_usage(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.eql(u8, s, "on")) {
            lccf.*.inject_usage = 1;
        } else if (std.mem.eql(u8, s, "off")) {
            lccf.*.inject_usage = 0;
        } else {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: invalid value for llm_proxy_inject_usage: must be on or off", .{});
            return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_provider_version <provider> <version>;`
fn ngx_conf_set_llm_proxy_provider_version(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_proxy_loc_conf = @ptrCast(core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK);
    if (lccf.provider_versions_count >= MAX_ROUTES) {
        log.ngz_log_error(NGX_LOG_WARN, cf.*.log, 0, "llm_proxy: provider_version limit reached (max 8), this entry is ignored", .{});
        return conf.NGX_CONF_OK;
    }

    var i: ngx_uint_t = 1;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const version = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;

    const slot = lccf.provider_versions_count;
    lccf.provider_versions[slot].provider = provider.*;
    lccf.provider_versions[slot].version = version.*;
    lccf.provider_versions_count += 1;
    return conf.NGX_CONF_OK;
}

// `llm_proxy_max_response_size <size>;`
fn ngx_conf_set_llm_proxy_max_response_size(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        if (s.len > 0) {
            const last = s[s.len - 1];
            if (last == 'k' or last == 'K') {
                lccf.*.max_response_size = (std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch DEFAULT_MAX_RESPONSE_SIZE) * 1024;
            } else if (last == 'm' or last == 'M') {
                lccf.*.max_response_size = (std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch DEFAULT_MAX_RESPONSE_SIZE) * 1024 * 1024;
            } else {
                lccf.*.max_response_size = std.fmt.parseInt(usize, s, 10) catch DEFAULT_MAX_RESPONSE_SIZE;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Phase 15 directive handlers ───────────────────────────────────────────────

// `llm_proxy_disclose_provider on|off;`
// When off: X-LLM-Provider header is not sent to the client.
// Internal ctx fields ($llm_effective_provider, etc.) are always populated.
fn ngx_conf_set_llm_proxy_disclose_provider(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.eql(u8, s, "on")) {
            lccf.*.disclose_provider = 1;
        } else if (std.mem.eql(u8, s, "off")) {
            lccf.*.disclose_provider = 0;
        } else {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: invalid value for llm_proxy_disclose_provider: must be on or off", .{});
            return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Phase 12 directive handlers ───────────────────────────────────────────────

// `llm_proxy_dialect_mode fixed|infer|explicit_required;`
fn ngx_conf_set_llm_proxy_dialect_mode(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const s = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.eql(u8, s, "fixed")) {
            lccf.*.dialect_mode = DIALECT_MODE_FIXED;
        } else if (std.mem.eql(u8, s, "infer")) {
            lccf.*.dialect_mode = DIALECT_MODE_INFER;
        } else if (std.mem.eql(u8, s, "explicit_required")) {
            lccf.*.dialect_mode = DIALECT_MODE_EXPLICIT_REQUIRED;
        } else {
            log.ngz_log_error(NGX_LOG_EMERG, cf.*.log, 0, "llm_proxy: invalid value for llm_proxy_dialect_mode: must be fixed, infer, or explicit_required", .{});
            return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_ingress_dialect <dialect>;`
fn ngx_conf_set_llm_proxy_ingress_dialect(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        lccf.*.ingress_dialect = arg.*;
    }
    return conf.NGX_CONF_OK;
}

// `llm_proxy_model_pattern <pattern> <provider>;` — operator-managed model catalog entry.
// Repeatable; evaluated in definition order; max MAX_MODEL_PATTERNS entries.
fn ngx_conf_set_llm_proxy_model_pattern(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_proxy_loc_conf = @ptrCast(core.castPtr(llm_proxy_loc_conf, loc) orelse return conf.NGX_CONF_OK);
    if (lccf.model_patterns_count >= MAX_MODEL_PATTERNS) {
        log.ngz_log_error(NGX_LOG_WARN, cf.*.log, 0, "llm_proxy: model_pattern limit reached (max %uz), this pattern is ignored", .{MAX_MODEL_PATTERNS});
        return conf.NGX_CONF_OK;
    }
    var i: ngx_uint_t = 1;
    const pattern = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const slot = lccf.model_patterns_count;
    lccf.model_patterns[slot].pattern = pattern.*;
    lccf.model_patterns[slot].provider = provider.*;
    lccf.model_patterns_count += 1;
    return conf.NGX_CONF_OK;
}

// ── Module wiring ─────────────────────────────────────────────────────────────

export const ngx_http_llm_proxy_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_proxy_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_proxy"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_proxy,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_route"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE23,
        .set = ngx_conf_set_llm_proxy_route,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_default_provider"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_default_provider,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_max_body_size"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_max_body_size,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_normalize_response"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_normalize_response,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_translation_fail_closed"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_translation_fail_closed,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_inject_usage"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_inject_usage,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_provider_version"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_llm_proxy_provider_version,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_max_response_size"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_max_response_size,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Phase 15 (Milestone 2 Target 4): disclosure policy directives
    ngx_command_t{
        .name = ngx_string("llm_proxy_disclose_provider"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_disclose_provider,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Phase 12 (Milestone 2 Target 1): dialect and operator catalog directives
    ngx_command_t{
        .name = ngx_string("llm_proxy_dialect_mode"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_dialect_mode,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_ingress_dialect"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_proxy_ingress_dialect,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_proxy_model_pattern"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_llm_proxy_model_pattern,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_llm_proxy_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_proxy_commands),
    @constCast(&ngx_http_llm_proxy_module_ctx),
);

test "rate-limit header parsers reject overflow" {
    const too_large = "999999999999999999999999999999999999999999999999999999";
    try std.testing.expectEqual(@as(?ngx_uint_t, null), parse_uint_header(too_large));
    try std.testing.expectEqual(@as(?ngx_uint_t, null), parse_reset_tokens_ms(too_large));
    try std.testing.expectEqual(@as(?ngx_uint_t, null), parse_reset_tokens_ms(too_large ++ "ms"));
    try std.testing.expectEqual(@as(?ngx_uint_t, null), parse_reset_tokens_ms(too_large ++ "s"));
    try std.testing.expectEqual(@as(?ngx_uint_t, null), parse_reset_tokens_ms("1e999s"));
}

test "JSON content type matching is exact and case insensitive" {
    try std.testing.expect(is_json_content_type("application/json"));
    try std.testing.expect(is_json_content_type("Application/JSON; Charset=UTF-8"));
    try std.testing.expect(is_json_content_type("  application/json \t; charset=utf-8"));
    try std.testing.expect(!is_json_content_type("text/application/json"));
    try std.testing.expect(!is_json_content_type("application/json-seq"));
}

test "routing scanner requires complete unescaped routing JSON" {
    var model = empty_str;
    var streaming: ngx_flag_t = 0;
    const valid = "{\"model\":\"gpt-4o\",\"messages\":[],\"stream\":true}";
    try std.testing.expect(body_scan_routing_fields(valid, &model, &streaming));
    try std.testing.expectEqualStrings("gpt-4o", core.slicify(u8, model.data, model.len));
    try std.testing.expectEqual(@as(ngx_flag_t, 1), streaming);

    model = empty_str;
    streaming = 0;
    try std.testing.expect(!body_scan_routing_fields(
        "{\"model\":\"gpt-4o\",\"messages\":[]} trailing",
        &model,
        &streaming,
    ));
    try std.testing.expect(!body_scan_routing_fields(
        "{\"model\":\"gpt\\u002d4o\",\"messages\":[]}",
        &model,
        &streaming,
    ));
}

test "llm_proxy module" {}
