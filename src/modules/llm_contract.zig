// Shared cross-module ABI contracts for the llm-* modules.
//
// These extern structs are passed BY VALUE across module boundaries through the
// exported `ngx_http_llm_*` functions. A struct larger than 16 bytes is returned
// via the SysV sret ABI: the CALLER allocates the return slot sized to ITS view
// of the struct and passes a hidden pointer; the CALLEE (the owning module)
// writes the FULL struct it knows about. If any module's view disagrees on size
// or layout, the callee writes past the caller's stack slot — silent stack
// corruption that integration tests only catch when the clobbered bytes happen
// to be padding.
//
// To make that class of bug impossible, every module imports these definitions
// from here instead of hand-copying them. Do NOT re-declare any of these structs
// in a module (or a *_test_support.zig mock); alias them:
//
//     const contract = @import("llm_contract");
//     const LlmProxyObservable = contract.LlmProxyObservable;
//
// Each struct names its owner (the module with the `export fn`) and consumers.
// When changing a field here, every importer recompiles against the new layout,
// so the owner and all consumers stay in lockstep automatically.

const ngx = @import("ngx");
const core = ngx.core;

const ngx_str_t = core.ngx_str_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;

// Owner: llm-proxy (ngx_http_llm_proxy_observe). Consumers: llm-cost, llm-ratelimit, llm-metrics.
pub const LlmProxyObservable = extern struct {
    provider: ngx_str_t,
    model: ngx_str_t,
    requested_provider: ngx_str_t,
    requested_model: ngx_str_t,
    requested_dialect: ngx_str_t,
    effective_provider: ngx_str_t,
    effective_model: ngx_str_t,
    effective_dialect: ngx_str_t,
    is_streaming: ngx_flag_t,
    body_parsed: ngx_flag_t,
    usage_extracted: ngx_flag_t,
    response_is_error_shape: ngx_flag_t,
    translation_happened: ngx_flag_t,
    replacement_happened: ngx_flag_t,
    fallback_attempted: ngx_flag_t,
    resolution_outcome: ngx_uint_t,
    prompt_tokens: ngx_uint_t,
    completion_tokens: ngx_uint_t,
    total_tokens: ngx_uint_t,
    cache_read_tokens: ngx_uint_t,
    cache_create_tokens: ngx_uint_t,
};

// Owner: llm-auth (ngx_http_llm_auth_resolve). Consumer: llm-proxy.
pub const AuthResolution = extern struct {
    provider: ngx_str_t,
    mode: ngx_uint_t, // auth_mode_* constant
    credential: ngx_str_t, // resolved secret value; empty means resolution failed
    fail_closed: ngx_flag_t,
    status: ngx_str_t, // resolved | missing_provider | missing_credential | missing_secret
    fail_reason: ngx_str_t,
};

// Owner: llm-security (ngx_http_llm_security_inspect_request/response). Consumer: llm-proxy.
pub const LlmSecurityOutcome = extern struct {
    detected: ngx_flag_t,
    blocked: ngx_flag_t,
    inspection_failed: ngx_flag_t,
    rule_id: ngx_str_t,
    action: ngx_uint_t,
    // Phase 4: response outcome fields
    response_detected: ngx_flag_t,
    response_blocked: ngx_flag_t,
    response_rule_id: ngx_str_t,
    response_action: ngx_uint_t,
    // Phase 4: modified response body (for redact mode)
    redacted_body: ngx_str_t,
    // M2 Target 1: inspection path observability
    translation_happened: ngx_flag_t,
};

// Owner: llm-fallback (ngx_http_llm_fallback_lookup_route). Consumer: llm-proxy.
pub const FallbackRouteLookup = extern struct {
    secondary: ngx_str_t,
    target_model: ngx_str_t,
};

// Owner: llm-cost (ngx_http_llm_cost_observe). Consumer: llm-ratelimit.
pub const LlmCostObservable = extern struct {
    total_cost_micros: u64, // total_cost * 1_000_000 rounded; 0 when not eligible
    cost_unit: ngx_str_t, // effective provider's cost unit (defaults to "usd")
    eligible: ngx_flag_t, // 1 = status is "recorded"; spend increment is eligible
};
