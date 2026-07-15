const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const pq = ngx.pq;
const event = ngx.event;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

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

const ngx_string = ngx.string.ngx_string;
const NArray = ngx.array.NArray;

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const LlmProxyObservable = contract.LlmProxyObservable;

extern fn ngx_http_llm_proxy_observe(r: [*c]ngx_http_request_t) LlmProxyObservable;
extern fn ngx_free_connection(c: [*c]core.ngx_connection_t) void;
extern var ngx_exiting: ngx_uint_t;
extern var ngx_current_msec: core.ngx_msec_t;

extern var ngx_http_core_module: ngx_module_t;

// ── Constants ──────────────────────────────────────────────────────────────────

const MAX_RATE_ENTRIES: usize = 32;
const MAX_RATE_UNIT_ENTRIES: usize = 32;
const BACKEND_OFF: ngx_uint_t = 0;
const BACKEND_LOG: ngx_uint_t = 1;
const BACKEND_POSTGRES: ngx_uint_t = 2;
const NGX_HTTP_LOG_PHASE: usize = 10;
const INSERT_SQL_SIZE: usize = 1024; // increased for M2 extra columns
const DEFAULT_TABLE = "llm_cost_events";
const PG_QUEUE_CAPACITY: usize = 512;
const PG_BATCH_MAX: usize = 64;
const PG_EVENT_PARAM_COUNT: usize = 27;
const PG_BATCH_SQL_SIZE: usize = 12 * 1024;
const PG_DSN_SIZE: usize = 512;
const PG_IO_TIMEOUT_MS: core.ngx_msec_t = 5000;
const PG_RETRY_INITIAL_MS: core.ngx_msec_t = 100;
const PG_RETRY_MAX_MS: core.ngx_msec_t = 5000;

// ── Status strings ─────────────────────────────────────────────────────────────

const status_none = ngx_str_t{ .len = 0, .data = @constCast("") };
const status_recorded = ngx_string("recorded");
const status_usage_missing = ngx_string("usage_missing");
const status_skipped_error = ngx_string("skipped_error");
const status_no_rate = ngx_string("no_rate");
const status_persist_failed = ngx_string("persist_failed");

// M2 Target 3: cohort label for translated traffic.
const cohort_default = ngx_string("default");
const cohort_fallback = ngx_string("fallback");
const cohort_translated = ngx_string("translated"); // M2 Target 3
const cost_unit_default = ngx_string("usd");

// M2 Target 1: resolution outcome label strings (must match llm-proxy constants).
const outcome_as_requested = ngx_string("as_requested");
const outcome_replaced = ngx_string("replaced_by_policy");
const outcome_fallback = ngx_string("fallback_after_failure");
const outcome_rejected_scope = ngx_string("rejected_out_of_scope");
const outcome_rejected_unresolvable = ngx_string("rejected_unresolvable");

// ── Config structs ─────────────────────────────────────────────────────────────

// One entry in the operator-defined rate card: (provider, model-prefix) → price/million tokens.
const CostRateEntry = extern struct {
    provider: ngx_str_t,
    model: ngx_str_t, // prefix match; empty = match all models for this provider
    prompt_per_million: f64, // USD per million prompt tokens
    completion_per_million: f64, // USD per million completion tokens
};

// Optional cached-input rate override: (provider, model-prefix) → cache read/create price/million.
// When present, blended prompt cost uses this instead of prompt_per_million for cache buckets.
const CostCachedRateEntry = extern struct {
    provider: ngx_str_t,
    model: ngx_str_t,
    cache_read_per_million: f64,
    cache_create_per_million: f64,
    has_create_rate: ngx_flag_t, // 1 when cache_create_per_million was explicitly configured
};

const CostRateUnitEntry = extern struct {
    provider: ngx_str_t,
    cost_unit: ngx_str_t,
};

const llm_cost_main_conf = extern struct {
    rates: [MAX_RATE_ENTRIES]CostRateEntry,
    rate_units: [MAX_RATE_UNIT_ENTRIES]CostRateUnitEntry,
    cached_rates: [MAX_RATE_ENTRIES]CostCachedRateEntry,
    rate_count: ngx_uint_t,
    rate_unit_count: ngx_uint_t,
    cached_rate_count: ngx_uint_t,
    backend: ngx_uint_t, // BACKEND_OFF | BACKEND_LOG | BACKEND_POSTGRES
    dsn: ngx_str_t, // postgres connection string (BACKEND_POSTGRES)
    table: ngx_str_t, // target table name
    rate_card_version: ngx_str_t,
    insert_sql: [INSERT_SQL_SIZE]u8, // null-terminated INSERT SQL built at postconfiguration
    llm_provider_idx: ngx_int_t,
    llm_model_idx: ngx_int_t,
    llm_streaming_idx: ngx_int_t,
    llm_prompt_tokens_idx: ngx_int_t,
    llm_completion_tokens_idx: ngx_int_t,
    request_time_idx: ngx_int_t,
    request_id_idx: ngx_int_t,
    llm_fallback_attempted_idx: ngx_int_t,
    // M2 Target 1: requested/effective routing attribution.
    llm_requested_provider_idx: ngx_int_t,
    llm_requested_model_idx: ngx_int_t,
    llm_translation_happened_idx: ngx_int_t,
    llm_resolution_outcome_idx: ngx_int_t,
};

const llm_cost_loc_conf = extern struct {
    enabled: ngx_flag_t,
    identity_var_index: ngx_int_t,
    user_var_index: ngx_int_t,
    team_var_index: ngx_int_t,
    auth_fingerprint_var_index: ngx_int_t,
    traffic_cohort_var_index: ngx_int_t,
    // M2 Target 2: org/project/client billing scope.
    org_var_index: ngx_int_t,
    project_var_index: ngx_int_t,
    client_var_index: ngx_int_t,
};

// ── Per-request context ────────────────────────────────────────────────────────

const LlmCostCtx = extern struct {
    status: ngx_str_t,
    prompt_cost: f64,
    completion_cost: f64,
    total_cost: f64,
    prompt_tokens: ngx_uint_t,
    completion_tokens: ngx_uint_t,
    total_tokens: ngx_uint_t,
    provider: ngx_str_t,
    model: ngx_str_t,
    cost_unit: ngx_str_t,
    traffic_cohort: ngx_str_t,
    is_streaming: ngx_flag_t,
    status_code: ngx_uint_t,
    duration_ms: ngx_uint_t,
    duration_ms_valid: ngx_flag_t,
    persisted: ngx_flag_t, // set after enqueue to avoid duplicate events from variable getters
    // M2 Target 1: routing attribution fields.
    requested_provider: ngx_str_t,
    requested_model: ngx_str_t,
    translation_happened: ngx_flag_t,
    resolution_outcome: ngx_str_t,
    // M2 Target 2: org/project/client billing scope.
    org: ngx_str_t,
    project: ngx_str_t,
    client: ngx_str_t,
};

const CostAttribution = struct {
    identity: ngx_str_t,
    user: ngx_str_t,
    team: ngx_str_t,
    auth_fingerprint: ngx_str_t,
    // M2 Target 2
    org: ngx_str_t,
    project: ngx_str_t,
    client: ngx_str_t,
};

// ── Per-worker asynchronous postgres writer ───────────────────────────────────

const AccountingEvent = extern struct {
    event_id: [256]u8,
    provider: [256]u8,
    model: [256]u8,
    cost_unit: [64]u8,
    cohort: [128]u8,
    streaming: [8]u8,
    prompt_tokens: [24]u8,
    completion_tokens: [24]u8,
    total_tokens: [24]u8,
    prompt_cost: [32]u8,
    completion_cost: [32]u8,
    total_cost: [32]u8,
    status: [32]u8,
    status_code: [16]u8,
    duration_ms: [24]u8,
    duration_valid: bool,
    identity: [256]u8,
    user: [256]u8,
    team: [256]u8,
    auth_fingerprint: [256]u8,
    rate_card_version: [128]u8,
    requested_provider: [256]u8,
    requested_model: [256]u8,
    translation_happened: [8]u8,
    resolution_outcome: [64]u8,
    org: [256]u8,
    project: [256]u8,
    client: [256]u8,
};

const WriterState = enum(u8) { disconnected, connecting, idle, flushing, waiting };

const PgWriter = struct {
    queue: [PG_QUEUE_CAPACITY]AccountingEvent = std.mem.zeroes([PG_QUEUE_CAPACITY]AccountingEvent),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    state: WriterState = .disconnected,
    conn: ?*pq.PGconn = null,
    ngx_conn: ?*core.ngx_connection_t = null,
    kick: core.ngx_event_t = std.mem.zeroes(core.ngx_event_t),
    log: [*c]ngx.log.ngx_log_t = core.nullptr(ngx.log.ngx_log_t),
    dsn: [PG_DSN_SIZE]u8 = std.mem.zeroes([PG_DSN_SIZE]u8),
    insert_sql: [INSERT_SQL_SIZE]u8 = std.mem.zeroes([INSERT_SQL_SIZE]u8),
    batch_sql: [PG_BATCH_SQL_SIZE]u8 = std.mem.zeroes([PG_BATCH_SQL_SIZE]u8),
    active_batch_count: usize = 0,
    single_fallback_remaining: usize = 0,
    configured: bool = false,
    stopping: bool = false,
    retry_ms: core.ngx_msec_t = PG_RETRY_INITIAL_MS,
    exit_deadline: core.ngx_msec_t = 0,
    enqueued: u64 = 0,
    written: u64 = 0,
    dropped_full: u64 = 0,
    dropped_sql: u64 = 0,
    reconnects: u64 = 0,
};

var g_pg_writer = PgWriter{};

comptime {
    // The queue is deliberately bounded to roughly 2 MiB per worker. This is
    // separate from all cacheline-tuned request hot-path record layouts.
    if (@sizeOf(AccountingEvent) > 4096) @compileError("postgres accounting event exceeded 4 KiB");
    if (@sizeOf(AccountingEvent) * PG_QUEUE_CAPACITY > 2 * 1024 * 1024)
        @compileError("postgres accounting queue exceeded 2 MiB per worker");
}

// ── Utility ────────────────────────────────────────────────────────────────────

fn strEql(a: ngx_str_t, b: ngx_str_t) bool {
    if (a.len != b.len) return false;
    return std.ascii.eqlIgnoreCase(
        core.slicify(u8, a.data, a.len),
        core.slicify(u8, b.data, b.len),
    );
}

fn strStartsWith(s: ngx_str_t, prefix: ngx_str_t) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(
        core.slicify(u8, s.data, prefix.len),
        core.slicify(u8, prefix.data, prefix.len),
    );
}

fn resolveStrVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?ngx_str_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    return ngx_str_t{ .data = val.*.data, .len = val.*.flags.len };
}

fn resolveUintVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?ngx_uint_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    const s = core.slicify(u8, val.*.data, val.*.flags.len);
    return std.fmt.parseInt(ngx_uint_t, s, 10) catch null;
}

fn resolveDurationMsVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?u32 {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    const s = core.slicify(u8, val.*.data, val.*.flags.len);
    const seconds = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    const millis = @as(u64, @intFromFloat(@round(seconds * 1000.0)));
    return if (millis > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(millis));
}

fn getVarIndex(cf: [*c]ngx_conf_t, name: []const u8) ngx_int_t {
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    return http.ngx_http_get_variable_index(cf, &n);
}

// M2 Target 1: map llm_resolution_outcome integer to canonical label string.
fn outcomeLabel(outcome: ngx_uint_t) ngx_str_t {
    return switch (outcome) {
        0 => outcome_as_requested,
        1 => outcome_replaced,
        2 => outcome_fallback,
        3 => outcome_rejected_scope,
        4 => outcome_rejected_unresolvable,
        else => ngx_string("other"),
    };
}

// ── Rate card lookup ───────────────────────────────────────────────────────────

// First matching entry wins. Provider is exact (case-insensitive); model is prefix.
fn lookupRate(mcf: *llm_cost_main_conf, provider: ngx_str_t, model: ngx_str_t) ?*const CostRateEntry {
    const m: *llm_cost_main_conf = @ptrCast(@alignCast(mcf));
    var i: usize = 0;
    while (i < m.rate_count) : (i += 1) {
        const e = &m.rates[i];
        if (e.provider.len > 0 and !strEql(provider, e.provider)) continue;
        if (e.model.len > 0 and !strStartsWith(model, e.model)) continue;
        return e;
    }
    return null;
}

fn lookupRateUnit(mcf: *llm_cost_main_conf, provider: ngx_str_t) ngx_str_t {
    const m: *llm_cost_main_conf = @ptrCast(@alignCast(mcf));
    var i: usize = 0;
    while (i < m.rate_unit_count) : (i += 1) {
        const e = &m.rate_units[i];
        if (e.provider.len > 0 and !strEql(provider, e.provider)) continue;
        return e.cost_unit;
    }
    return cost_unit_default;
}

fn lookupCachedRate(mcf: *llm_cost_main_conf, provider: ngx_str_t, model: ngx_str_t) ?*const CostCachedRateEntry {
    const m: *llm_cost_main_conf = @ptrCast(@alignCast(mcf));
    var i: usize = 0;
    while (i < m.cached_rate_count) : (i += 1) {
        const e = &m.cached_rates[i];
        if (e.provider.len > 0 and !strEql(provider, e.provider)) continue;
        if (e.model.len > 0 and !strStartsWith(model, e.model)) continue;
        return e;
    }
    return null;
}

// ── Cost computation (idempotent — cached in per-request ctx) ──────────────────
//
// The nginx LOG phase calls access_log before our LOG handler (forward registration
// order in ngx_http_log_request). To ensure variables are populated when access_log
// evaluates them, cost is computed lazily inside the variable getters, then cached
// in r->ctx. The LOG phase handler calls this too as a fallback for postgres-only
// deployments where no log_format references the variables.

fn computeCostIfNeeded(r: [*c]ngx_http_request_t) ?*LlmCostCtx {
    // Return cached result if already computed.
    if (core.castPtr(LlmCostCtx, r.*.ctx[ngx_http_llm_cost_module.ctx_index])) |ctx| return ctx;

    const lccf = core.castPtr(
        llm_cost_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_cost_module),
    ) orelse return null;
    if (lccf.*.enabled != 1) return null;

    const mcf = core.castPtr(
        llm_cost_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_cost_module),
    ) orelse return null;

    const ctx = core.ngz_pcalloc_c(LlmCostCtx, r.*.pool) orelse return null;
    r.*.ctx[ngx_http_llm_cost_module.ctx_index] = ctx;

    const obs = ngx_http_llm_proxy_observe(r);
    // Use effective_* fields: they reflect the backend that actually served the request.
    // In failure-driven fallback, effective_provider diverges from the legacy provider field
    // (which stays at the first-hop value). Fall back to legacy fields only when absent.
    const provider = if (obs.effective_provider.len > 0) obs.effective_provider else if (obs.provider.len > 0) obs.provider else status_none;
    const model = if (obs.effective_model.len > 0) obs.effective_model else if (obs.model.len > 0) obs.model else status_none;
    const prompt_tokens = obs.prompt_tokens;
    const completion_tokens = obs.completion_tokens;
    const cache_read_tokens = obs.cache_read_tokens;
    const cache_create_tokens = obs.cache_create_tokens;

    ctx.*.provider = provider;
    ctx.*.model = model;
    ctx.*.cost_unit = lookupRateUnit(mcf, provider);

    // M2 Target 1: populate requested/effective routing attribution.
    ctx.*.requested_provider = if (obs.requested_provider.len > 0) obs.requested_provider else status_none;
    ctx.*.requested_model = if (obs.requested_model.len > 0) obs.requested_model else status_none;
    ctx.*.translation_happened = obs.translation_happened;
    ctx.*.resolution_outcome = outcomeLabel(obs.resolution_outcome);

    // M2 Target 2: populate org/project/client billing scope.
    ctx.*.org = if (lccf.*.org_var_index >= 0) (resolveStrVar(r, lccf.*.org_var_index) orelse status_none) else status_none;
    ctx.*.project = if (lccf.*.project_var_index >= 0) (resolveStrVar(r, lccf.*.project_var_index) orelse status_none) else status_none;
    ctx.*.client = if (lccf.*.client_var_index >= 0) (resolveStrVar(r, lccf.*.client_var_index) orelse status_none) else status_none;

    // Cohort: explicit variable > translated auto-label (M2 Target 3) > fallback > default.
    ctx.*.traffic_cohort = if (lccf.*.traffic_cohort_var_index >= 0)
        (resolveStrVar(r, lccf.*.traffic_cohort_var_index) orelse status_none)
    else
        status_none;
    if (ctx.*.traffic_cohort.len == 0) {
        if (ctx.*.translation_happened == 1) {
            // M2 Target 3: auto-stamp translated cohort when no explicit cohort configured.
            ctx.*.traffic_cohort = cohort_translated;
        } else {
            const fallback_attempted = obs.fallback_attempted;
            ctx.*.traffic_cohort = if (fallback_attempted > 0) cohort_fallback else cohort_default;
        }
    }

    ctx.*.is_streaming = obs.is_streaming;
    ctx.*.status_code = if (r.*.headers_out.status > 0) r.*.headers_out.status else @as(ngx_uint_t, 200);
    if (resolveDurationMsVar(r, mcf.*.request_time_idx)) |duration_ms| {
        ctx.*.duration_ms = duration_ms;
        ctx.*.duration_ms_valid = 1;
    }
    ctx.*.prompt_tokens = prompt_tokens;
    ctx.*.completion_tokens = completion_tokens;
    ctx.*.total_tokens = prompt_tokens +| completion_tokens;

    if (ctx.*.total_tokens == 0) {
        ctx.*.status = if (r.*.headers_out.status >= 400) status_skipped_error else status_usage_missing;
        return ctx;
    }

    const rate = lookupRate(mcf, provider, model) orelse {
        ctx.*.status = status_no_rate;
        return ctx;
    };

    // Blended prompt cost: if a cached-rate entry matches, split cache buckets from regular tokens.
    // Defensive clamp: cached tokens must not exceed total prompt to keep regular tokens non-negative.
    const total_cache = @min(cache_read_tokens +| cache_create_tokens, prompt_tokens);
    const regular_tokens = prompt_tokens - total_cache;
    // Use min() to clamp individual buckets in case their sum overflows (shouldn't happen in practice).
    const cr_clamped = @min(cache_read_tokens, total_cache);
    const cc_clamped = @min(cache_create_tokens, total_cache - cr_clamped);

    if (lookupCachedRate(mcf, provider, model)) |cr| {
        const create_rate = if (cr.has_create_rate == 1) cr.cache_create_per_million else rate.prompt_per_million;
        ctx.*.prompt_cost =
            @as(f64, @floatFromInt(regular_tokens)) * rate.prompt_per_million / 1_000_000.0 +
            @as(f64, @floatFromInt(cr_clamped)) * cr.cache_read_per_million / 1_000_000.0 +
            @as(f64, @floatFromInt(cc_clamped)) * create_rate / 1_000_000.0;
    } else {
        ctx.*.prompt_cost = @as(f64, @floatFromInt(prompt_tokens)) * rate.prompt_per_million / 1_000_000.0;
    }
    ctx.*.completion_cost = @as(f64, @floatFromInt(completion_tokens)) * rate.completion_per_million / 1_000_000.0;
    ctx.*.total_cost = ctx.*.prompt_cost + ctx.*.completion_cost;
    ctx.*.status = status_recorded;
    return ctx;
}

fn collectAttribution(r: [*c]ngx_http_request_t, lccf: *llm_cost_loc_conf, ctx: *LlmCostCtx) CostAttribution {
    return .{
        .identity = if (lccf.*.identity_var_index >= 0) (resolveStrVar(r, lccf.*.identity_var_index) orelse status_none) else status_none,
        .user = if (lccf.*.user_var_index >= 0) (resolveStrVar(r, lccf.*.user_var_index) orelse status_none) else status_none,
        .team = if (lccf.*.team_var_index >= 0) (resolveStrVar(r, lccf.*.team_var_index) orelse status_none) else status_none,
        .auth_fingerprint = if (lccf.*.auth_fingerprint_var_index >= 0) (resolveStrVar(r, lccf.*.auth_fingerprint_var_index) orelse status_none) else status_none,
        // M2 Target 2: reuse already-resolved values from ctx to avoid duplicate variable lookups.
        .org = ctx.*.org,
        .project = ctx.*.project,
        .client = ctx.*.client,
    };
}

fn persistIfNeeded(r: [*c]ngx_http_request_t, ctx: *LlmCostCtx) void {
    if (ctx.*.persisted == 1 or ctx.*.status.len == 0) return;
    // Persist both recorded (cost computed) and no_rate (tokens present but no rate card entry)
    // so operators can audit unpriced traffic. Other terminal statuses (skipped_error,
    // usage_missing, persist_failed) are not persisted: errors have no tokens, usage_missing
    // has nothing to price, and persist_failed would re-enter this function recursively.
    if (!strEql(ctx.*.status, status_recorded) and !strEql(ctx.*.status, status_no_rate)) return;

    const lccf = core.castPtr(
        llm_cost_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_cost_module),
    ) orelse return;
    if (lccf.*.enabled != 1) return;

    const mcf = core.castPtr(
        llm_cost_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_cost_module),
    ) orelse return;
    if (mcf.*.backend != BACKEND_POSTGRES) return;

    const attribution = collectAttribution(r, lccf, ctx);
    const event_id = if (mcf.*.request_id_idx >= 0)
        (resolveStrVar(r, mcf.*.request_id_idx) orelse status_none)
    else
        status_none;
    const item = makeAccountingEvent(mcf, ctx, attribution, event_id) orelse {
        ctx.*.status = status_persist_failed;
        return;
    };

    if (!writerEnqueue(mcf, item)) {
        ngx.log.ngz_log_error(
            ngx.log.NGX_LOG_ERR,
            r.*.connection.*.log,
            0,
            "llm-cost: postgres queue full or invalid configuration; recovery_event_id=%V provider=%V model=%V prompt_tokens=%ui completion_tokens=%ui total_tokens=%ui",
            .{ &event_id, &ctx.*.provider, &ctx.*.model, ctx.*.prompt_tokens, ctx.*.completion_tokens, ctx.*.total_tokens },
        );
        ctx.*.status = status_persist_failed;
    } else {
        ctx.*.persisted = 1;
    }
}

// ── Variable getters ───────────────────────────────────────────────────────────

fn get_cost_status(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    persistIfNeeded(r, ctx);
    v.*.data = ctx.*.status.data;
    v.*.flags.len = @intCast(ctx.*.status.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = ctx.*.status.len == 0;
    return NGX_OK;
}

fn renderF64Var(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, val: f64) ngx_int_t {
    var scratch: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&scratch, "{d:.8}", .{val}) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const s = ngx.string.ngx_string_from_pool(@constCast(rendered.ptr), rendered.len, r.*.pool) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = s.data;
    v.*.flags.len = @intCast(s.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn setEmptyVar(v: [*c]ngx_http_variable_value_t) void {
    v.*.data = @constCast("");
    v.*.flags.len = 0;
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
}

fn setStrVar(v: [*c]ngx_http_variable_value_t, s: ngx_str_t) void {
    v.*.data = s.data;
    v.*.flags.len = @intCast(s.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = s.len == 0;
}

fn get_cost_prompt(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        setEmptyVar(v);
        return NGX_OK;
    };
    persistIfNeeded(r, ctx);
    if (!strEql(ctx.*.status, status_recorded) and !strEql(ctx.*.status, status_persist_failed)) {
        setEmptyVar(v);
        return NGX_OK;
    }
    return renderF64Var(r, v, ctx.*.prompt_cost);
}

fn get_cost_completion(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        setEmptyVar(v);
        return NGX_OK;
    };
    persistIfNeeded(r, ctx);
    if (!strEql(ctx.*.status, status_recorded) and !strEql(ctx.*.status, status_persist_failed)) {
        setEmptyVar(v);
        return NGX_OK;
    }
    return renderF64Var(r, v, ctx.*.completion_cost);
}

fn get_cost_total(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        setEmptyVar(v);
        return NGX_OK;
    };
    persistIfNeeded(r, ctx);
    if (!strEql(ctx.*.status, status_recorded) and !strEql(ctx.*.status, status_persist_failed)) {
        setEmptyVar(v);
        return NGX_OK;
    }
    return renderF64Var(r, v, ctx.*.total_cost);
}

// M2 Target 1 variable getters.
fn get_cost_requested_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    setStrVar(v, ctx.*.requested_provider);
    return NGX_OK;
}

fn get_cost_requested_model(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    setStrVar(v, ctx.*.requested_model);
    return NGX_OK;
}

fn get_cost_translation_happened(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const s = if (ctx.*.translation_happened == 1) ngx_string("1") else ngx_string("0");
    setStrVar(v, s);
    return NGX_OK;
}

fn get_cost_resolution_outcome(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    setStrVar(v, ctx.*.resolution_outcome);
    return NGX_OK;
}

fn get_cost_event_id(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const mcf = core.castPtr(
        llm_cost_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_cost_module),
    ) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const event_id = if (mcf.*.request_id_idx >= 0) resolveStrVar(r, mcf.*.request_id_idx) else null;
    if (event_id) |id| setStrVar(v, id) else v.*.flags.not_found = true;
    return NGX_OK;
}

// M2 Target 2 variable getters.
fn get_cost_org(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    setStrVar(v, ctx.*.org);
    return NGX_OK;
}

fn get_cost_project(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    setStrVar(v, ctx.*.project);
    return NGX_OK;
}

fn get_cost_client(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = computeCostIfNeeded(r) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    setStrVar(v, ctx.*.client);
    return NGX_OK;
}

// ── Postgres persistence ───────────────────────────────────────────────────────

fn copyZ(dest: anytype, src: ngx_str_t) void {
    const n = @min(src.len, dest.len - 1);
    if (n > 0) core.ngz_memcpy(dest, src.data, @intCast(n));
    dest[n] = 0;
}

fn formatZ(dest: anytype, comptime fmt: []const u8, args: anytype) bool {
    const rendered = std.fmt.bufPrint(dest[0 .. dest.len - 1], fmt, args) catch return false;
    dest[rendered.len] = 0;
    return true;
}

fn makeAccountingEvent(mcf: *llm_cost_main_conf, ctx: *LlmCostCtx, attribution: CostAttribution, event_id: ngx_str_t) ?AccountingEvent {
    var item = std.mem.zeroes(AccountingEvent);
    copyZ(&item.event_id, event_id);
    copyZ(&item.provider, ctx.*.provider);
    copyZ(&item.model, ctx.*.model);
    copyZ(&item.cost_unit, ctx.*.cost_unit);
    copyZ(&item.cohort, ctx.*.traffic_cohort);
    if (!formatZ(&item.streaming, "{d}", .{@as(u8, if (ctx.*.is_streaming == 1) 1 else 0)})) return null;
    if (!formatZ(&item.prompt_tokens, "{d}", .{ctx.*.prompt_tokens})) return null;
    if (!formatZ(&item.completion_tokens, "{d}", .{ctx.*.completion_tokens})) return null;
    if (!formatZ(&item.total_tokens, "{d}", .{ctx.*.total_tokens})) return null;
    if (!formatZ(&item.prompt_cost, "{d:.8}", .{ctx.*.prompt_cost})) return null;
    if (!formatZ(&item.completion_cost, "{d:.8}", .{ctx.*.completion_cost})) return null;
    if (!formatZ(&item.total_cost, "{d:.8}", .{ctx.*.total_cost})) return null;
    copyZ(&item.status, ctx.*.status);
    if (!formatZ(&item.status_code, "{d}", .{ctx.*.status_code})) return null;
    item.duration_valid = ctx.*.duration_ms_valid == 1;
    if (item.duration_valid and !formatZ(&item.duration_ms, "{d}", .{ctx.*.duration_ms})) return null;
    copyZ(&item.identity, attribution.identity);
    copyZ(&item.user, attribution.user);
    copyZ(&item.team, attribution.team);
    copyZ(&item.auth_fingerprint, attribution.auth_fingerprint);
    copyZ(&item.rate_card_version, mcf.*.rate_card_version);
    copyZ(&item.requested_provider, ctx.*.requested_provider);
    copyZ(&item.requested_model, ctx.*.requested_model);
    if (!formatZ(&item.translation_happened, "{d}", .{@as(u8, if (ctx.*.translation_happened == 1) 1 else 0)})) return null;
    copyZ(&item.resolution_outcome, ctx.*.resolution_outcome);
    copyZ(&item.org, attribution.org);
    copyZ(&item.project, attribution.project);
    copyZ(&item.client, attribution.client);
    return item;
}

fn writerPop() void {
    if (g_pg_writer.count == 0) return;
    g_pg_writer.head = (g_pg_writer.head + 1) % PG_QUEUE_CAPACITY;
    g_pg_writer.count -= 1;
}

fn writerPopCount(count: usize) void {
    var remaining = @min(count, g_pg_writer.count);
    while (remaining > 0) : (remaining -= 1) writerPop();
}

fn writerBuildBatchSql(batch_count: usize) ?[*c]const u8 {
    if (batch_count == 0 or batch_count > PG_BATCH_MAX) return null;
    const single = std.mem.sliceTo(&g_pg_writer.insert_sql, 0);
    const values_marker = "VALUES ";
    const conflict_marker = " ON CONFLICT";
    const values_at = std.mem.indexOf(u8, single, values_marker) orelse return null;
    const conflict_at = std.mem.indexOf(u8, single, conflict_marker) orelse return null;
    if (conflict_at <= values_at) return null;

    var pos: usize = 0;
    const prefix = single[0 .. values_at + values_marker.len];
    if (prefix.len >= g_pg_writer.batch_sql.len) return null;
    @memcpy(g_pg_writer.batch_sql[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    var param: usize = 1;
    for (0..batch_count) |row| {
        if (row > 0) {
            if (pos >= g_pg_writer.batch_sql.len) return null;
            g_pg_writer.batch_sql[pos] = ',';
            pos += 1;
        }
        if (pos >= g_pg_writer.batch_sql.len) return null;
        g_pg_writer.batch_sql[pos] = '(';
        pos += 1;
        for (0..PG_EVENT_PARAM_COUNT) |column| {
            if (column > 0) {
                if (pos >= g_pg_writer.batch_sql.len) return null;
                g_pg_writer.batch_sql[pos] = ',';
                pos += 1;
            }
            const rendered = std.fmt.bufPrint(g_pg_writer.batch_sql[pos..], "${d}", .{param}) catch return null;
            pos += rendered.len;
            param += 1;
        }
        if (pos >= g_pg_writer.batch_sql.len) return null;
        g_pg_writer.batch_sql[pos] = ')';
        pos += 1;
    }
    const suffix = single[conflict_at..];
    if (pos + suffix.len >= g_pg_writer.batch_sql.len) return null;
    @memcpy(g_pg_writer.batch_sql[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    g_pg_writer.batch_sql[pos] = 0;
    return @ptrCast(&g_pg_writer.batch_sql);
}

fn writerSchedule(delay: core.ngx_msec_t) void {
    if (g_pg_writer.stopping or g_pg_writer.kick.flags.timer_set) return;
    event.ngx_event_add_timer(&g_pg_writer.kick, delay);
}

fn writerConfigure(mcf: *llm_cost_main_conf) bool {
    if (g_pg_writer.configured) return true;
    if (mcf.*.dsn.len == 0 or mcf.*.dsn.len >= g_pg_writer.dsn.len) return false;
    copyZ(&g_pg_writer.dsn, mcf.*.dsn);
    const sql_len = std.mem.indexOfScalar(u8, &mcf.*.insert_sql, 0) orelse return false;
    if (sql_len >= g_pg_writer.insert_sql.len) return false;
    @memcpy(g_pg_writer.insert_sql[0..sql_len], mcf.*.insert_sql[0..sql_len]);
    g_pg_writer.insert_sql[sql_len] = 0;
    g_pg_writer.configured = true;
    return true;
}

fn writerEnqueue(mcf: *llm_cost_main_conf, item: AccountingEvent) bool {
    if (!writerConfigure(mcf) or g_pg_writer.count == PG_QUEUE_CAPACITY) {
        g_pg_writer.dropped_full +%= 1;
        return false;
    }
    g_pg_writer.queue[g_pg_writer.tail] = item;
    g_pg_writer.tail = (g_pg_writer.tail + 1) % PG_QUEUE_CAPACITY;
    g_pg_writer.count += 1;
    g_pg_writer.enqueued +%= 1;
    writerSchedule(0);
    return true;
}

fn writerClearWatchTimers() void {
    const c = g_pg_writer.ngx_conn orelse return;
    if (c.*.read != core.nullptr(core.ngx_event_t)) {
        if (c.*.read.*.flags.timer_set) event.ngx_event_del_timer(c.*.read);
        event.ngz_delete_posted_event(c.*.read);
    }
    if (c.*.write != core.nullptr(core.ngx_event_t)) {
        if (c.*.write.*.flags.timer_set) event.ngx_event_del_timer(c.*.write);
        event.ngz_delete_posted_event(c.*.write);
    }
}

fn writerDisconnect() void {
    writerClearWatchTimers();
    if (g_pg_writer.ngx_conn) |c| {
        c.*.data = null;
        ngx_free_connection(c);
        c.*.fd = -1;
        g_pg_writer.ngx_conn = null;
    }
    if (g_pg_writer.conn) |conn| pq.pgFinish(conn);
    g_pg_writer.conn = null;
    g_pg_writer.state = .disconnected;
}

fn writerRetry() void {
    writerDisconnect();
    if (g_pg_writer.stopping or g_pg_writer.count == 0) return;
    if (ngx_exiting != 0 and g_pg_writer.exit_deadline == 0)
        g_pg_writer.exit_deadline = ngx_current_msec + PG_IO_TIMEOUT_MS;
    if (g_pg_writer.exit_deadline != 0 and ngx_current_msec >= g_pg_writer.exit_deadline) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, g_pg_writer.log, 0,
            "llm-cost: postgres graceful-drain deadline expired; %uz queued events remain recoverable from accounting logs", .{g_pg_writer.count});
        g_pg_writer.count = 0;
        g_pg_writer.stopping = true;
        return;
    }
    g_pg_writer.reconnects +%= 1;
    const delay = if (g_pg_writer.exit_deadline != 0)
        @min(g_pg_writer.retry_ms, g_pg_writer.exit_deadline - ngx_current_msec)
    else
        g_pg_writer.retry_ms;
    writerSchedule(delay);
    g_pg_writer.retry_ms = @min(g_pg_writer.retry_ms * 2, PG_RETRY_MAX_MS);
}

fn writerWatch(want_read: bool, want_write: bool) bool {
    const c = g_pg_writer.ngx_conn orelse return false;
    writerClearWatchTimers();
    if (want_read) {
        if (http.ngx_handle_read_event(c.*.read, 0) != NGX_OK) return false;
        event.ngx_event_add_timer(c.*.read, PG_IO_TIMEOUT_MS);
    }
    if (want_write) {
        if (http.ngx_handle_write_event(c.*.write, 0) != NGX_OK) return false;
        event.ngx_event_add_timer(c.*.write, PG_IO_TIMEOUT_MS);
    }
    return true;
}

fn writerStartQuery() void {
    if (g_pg_writer.count == 0) return;
    const conn = g_pg_writer.conn orelse return writerRetry();
    const batch_count = if (g_pg_writer.single_fallback_remaining > 0)
        1
    else
        @min(g_pg_writer.count, PG_BATCH_MAX);
    const sql = writerBuildBatchSql(batch_count) orelse return writerRetry();
    var values: [PG_BATCH_MAX * PG_EVENT_PARAM_COUNT][*c]const u8 = undefined;
    var value_index: usize = 0;
    for (0..batch_count) |offset| {
        const queue_index = (g_pg_writer.head + offset) % PG_QUEUE_CAPACITY;
        const item = &g_pg_writer.queue[queue_index];
        const item_values = [PG_EVENT_PARAM_COUNT][*c]const u8{
            if (item.event_id[0] != 0) @ptrCast(&item.event_id) else null,
            @ptrCast(&item.provider), @ptrCast(&item.model),
            @ptrCast(&item.cost_unit), @ptrCast(&item.cohort), @ptrCast(&item.streaming),
            @ptrCast(&item.prompt_tokens), @ptrCast(&item.completion_tokens), @ptrCast(&item.total_tokens),
            @ptrCast(&item.prompt_cost), @ptrCast(&item.completion_cost), @ptrCast(&item.total_cost),
            @ptrCast(&item.status), @ptrCast(&item.status_code),
            if (item.duration_valid) @ptrCast(&item.duration_ms) else null,
            @ptrCast(&item.identity), @ptrCast(&item.user), @ptrCast(&item.team),
            @ptrCast(&item.auth_fingerprint), @ptrCast(&item.rate_card_version),
            @ptrCast(&item.requested_provider), @ptrCast(&item.requested_model),
            @ptrCast(&item.translation_happened), @ptrCast(&item.resolution_outcome),
            @ptrCast(&item.org), @ptrCast(&item.project), @ptrCast(&item.client),
        };
        @memcpy(values[value_index .. value_index + PG_EVENT_PARAM_COUNT], &item_values);
        value_index += PG_EVENT_PARAM_COUNT;
    }
    g_pg_writer.active_batch_count = batch_count;
    if (pq.pgSendQueryParams(conn, sql, @intCast(value_index), null, @ptrCast(&values), null, null, 0) == 0) {
        return writerRetry();
    }
    g_pg_writer.state = .flushing;
    const flushed = pq.pgFlush(conn);
    if (flushed < 0) return writerRetry();
    if (flushed == 0) {
        g_pg_writer.state = .waiting;
        if (!writerWatch(true, false)) writerRetry();
    } else if (!writerWatch(false, true)) writerRetry();
}

fn writerFinishQuery() void {
    const conn = g_pg_writer.conn orelse return writerRetry();
    if (pq.pgConsumeInput(conn) == 0) return writerRetry();
    if (pq.pgIsBusy(conn) != 0) {
        if (!writerWatch(true, false)) writerRetry();
        return;
    }
    var sql_failed = false;
    while (pq.pgGetResult(conn)) |result| {
        if (pq.pgResultStatus(result) != pq.PGRES_COMMAND_OK) sql_failed = true;
        pq.pgClear(result);
    }
    if (sql_failed and g_pg_writer.active_batch_count > 1) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_WARN, g_pg_writer.log, 0,
            "llm-cost: postgres batch of %uz events failed; retrying individually to isolate poison event", .{g_pg_writer.active_batch_count});
        g_pg_writer.single_fallback_remaining = g_pg_writer.active_batch_count;
    } else if (sql_failed) {
        const item = &g_pg_writer.queue[g_pg_writer.head];
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, g_pg_writer.log, 0,
            "llm-cost: async postgres SQL failure; recovery_event_id=%s prompt_tokens=%s completion_tokens=%s total_tokens=%s prompt_cost=%s completion_cost=%s total_cost=%s", .{
                @as([*c]u8, @ptrCast(&item.event_id)), @as([*c]u8, @ptrCast(&item.prompt_tokens)),
                @as([*c]u8, @ptrCast(&item.completion_tokens)), @as([*c]u8, @ptrCast(&item.total_tokens)),
                @as([*c]u8, @ptrCast(&item.prompt_cost)), @as([*c]u8, @ptrCast(&item.completion_cost)),
                @as([*c]u8, @ptrCast(&item.total_cost)),
            });
        g_pg_writer.dropped_sql +%= 1;
        writerPop();
        if (g_pg_writer.single_fallback_remaining > 0) g_pg_writer.single_fallback_remaining -= 1;
    } else {
        g_pg_writer.written +%= g_pg_writer.active_batch_count;
        writerPopCount(g_pg_writer.active_batch_count);
        if (g_pg_writer.single_fallback_remaining > 0) g_pg_writer.single_fallback_remaining -= 1;
    }
    g_pg_writer.active_batch_count = 0;
    g_pg_writer.retry_ms = PG_RETRY_INITIAL_MS;
    g_pg_writer.state = .idle;
    writerClearWatchTimers();
    // We are already outside request teardown in the writer's socket callback.
    // Start the next nonblocking send directly; routing every row through a
    // zero-delay nginx timer adds roughly one event-loop tick per INSERT.
    if (g_pg_writer.count > 0) writerStartQuery();
}

fn writerPollConnect() void {
    const conn = g_pg_writer.conn orelse return writerRetry();
    switch (pq.pgConnectPoll(conn)) {
        pq.PGRES_POLLING_READING => if (!writerWatch(true, false)) writerRetry(),
        pq.PGRES_POLLING_WRITING => if (!writerWatch(false, true)) writerRetry(),
        pq.PGRES_POLLING_OK => {
            g_pg_writer.state = .idle;
            g_pg_writer.retry_ms = PG_RETRY_INITIAL_MS;
            writerClearWatchTimers();
            writerStartQuery();
        },
        else => writerRetry(),
    }
}

fn writerSocketHandler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    if (ev.*.flags.timedout) {
        ev.*.flags.timedout = false;
        return writerRetry();
    }
    switch (g_pg_writer.state) {
        .connecting => writerPollConnect(),
        .flushing => {
            const conn = g_pg_writer.conn orelse return writerRetry();
            const flushed = pq.pgFlush(conn);
            if (flushed < 0) return writerRetry();
            if (flushed == 0) {
                g_pg_writer.state = .waiting;
                if (!writerWatch(true, false)) writerRetry();
            } else if (!writerWatch(false, true)) writerRetry();
        },
        .waiting => writerFinishQuery(),
        else => {},
    }
}

fn writerConnect() void {
    if (!g_pg_writer.configured or g_pg_writer.count == 0) return;
    const conn = pq.pgConnectStart(@ptrCast(&g_pg_writer.dsn)) orelse return writerRetry();
    g_pg_writer.conn = conn;
    if (pq.pgStatus(conn) == pq.CONNECTION_BAD or pq.pgSetnonblocking(conn, 1) != 0) return writerRetry();
    const fd = pq.pgSocket(conn);
    if (fd < 0) return writerRetry();
    const c = http.ngx_get_connection(fd, g_pg_writer.log);
    if (c == core.nullptr(core.ngx_connection_t)) return writerRetry();
    g_pg_writer.ngx_conn = c;
    c.*.data = &g_pg_writer;
    c.*.log = g_pg_writer.log;
    c.*.read.*.log = g_pg_writer.log;
    c.*.write.*.log = g_pg_writer.log;
    c.*.read.*.handler = writerSocketHandler;
    c.*.write.*.handler = writerSocketHandler;
    g_pg_writer.state = .connecting;
    writerPollConnect();
}

fn writerKickHandler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    ev.*.flags.timedout = false;
    if (g_pg_writer.stopping or g_pg_writer.count == 0) return;
    switch (g_pg_writer.state) {
        .disconnected => writerConnect(),
        .idle => writerStartQuery(),
        else => {},
    }
}

// ── LOG phase handler ──────────────────────────────────────────────────────────
//
// ngx_http_log_request() calls LOG phase handlers in forward registration order
// (not reversed like ACCESS phase). Access_log runs before this handler, which
// is fine because computeCostIfNeeded() is called lazily from variable getters
// triggered by access_log's log_format evaluation. By the time this handler
// runs, ctx is already populated. This handler is only needed for postgres
// persistence — in log-backend deployments it is a no-op.

fn log_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        llm_cost_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_cost_module),
    ) orelse return NGX_OK;
    if (lccf.*.enabled != 1) return NGX_OK;

    const mcf = core.castPtr(
        llm_cost_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_cost_module),
    ) orelse return NGX_OK;

    if (mcf.*.backend != BACKEND_POSTGRES) return NGX_OK;

    // Compute cost if the getter hasn't been called yet (no $llm_cost_* in log_format).
    const ctx = computeCostIfNeeded(r) orelse return NGX_OK;
    if (ctx.*.persisted == 1) return NGX_OK;
    if (!strEql(ctx.*.status, status_recorded) and !strEql(ctx.*.status, status_no_rate)) return NGX_OK;

    persistIfNeeded(r, ctx);
    return NGX_OK;
}

// ── Config parsing ─────────────────────────────────────────────────────────────

fn ngx_conf_set_llm_cost(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(llm_cost_loc_conf, loc)) |lccf| lccf.*.enabled = 1;
    return conf.NGX_CONF_OK;
}

fn validCostRate(rate: f64) bool {
    return std.math.isFinite(rate) and rate >= 0.0;
}

// llm_cost_rate <provider> <model> <prompt_$/M> <completion_$/M>
fn ngx_conf_set_rate(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf: *llm_cost_main_conf = @ptrCast(@alignCast(core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR));
    if (mcf.rate_count >= MAX_RATE_ENTRIES) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const provider_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const model_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const prompt_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const comp_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    const prompt_rate = std.fmt.parseFloat(f64, core.slicify(u8, prompt_arg.*.data, prompt_arg.*.len)) catch return conf.NGX_CONF_ERROR;
    const comp_rate = std.fmt.parseFloat(f64, core.slicify(u8, comp_arg.*.data, comp_arg.*.len)) catch return conf.NGX_CONF_ERROR;
    if (!validCostRate(prompt_rate) or !validCostRate(comp_rate)) return conf.NGX_CONF_ERROR;

    mcf.rates[mcf.rate_count] = .{
        .provider = provider_arg.*,
        .model = model_arg.*,
        .prompt_per_million = prompt_rate,
        .completion_per_million = comp_rate,
    };
    mcf.rate_count += 1;
    return conf.NGX_CONF_OK;
}

// llm_cost_cached_rate <provider> <model> <cache-read-rate-per-million> [<cache-create-rate-per-million>]
fn ngx_conf_set_cached_rate(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf: *llm_cost_main_conf = @ptrCast(@alignCast(core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR));
    if (mcf.cached_rate_count >= MAX_RATE_ENTRIES) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const provider_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const model_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const read_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    const read_rate = std.fmt.parseFloat(f64, core.slicify(u8, read_arg.*.data, read_arg.*.len)) catch return conf.NGX_CONF_ERROR;
    if (!validCostRate(read_rate)) return conf.NGX_CONF_ERROR;

    var create_rate: f64 = 0.0;
    var has_create: ngx_flag_t = 0;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |create_arg| {
        create_rate = std.fmt.parseFloat(f64, core.slicify(u8, create_arg.*.data, create_arg.*.len)) catch return conf.NGX_CONF_ERROR;
        if (!validCostRate(create_rate)) return conf.NGX_CONF_ERROR;
        has_create = 1;
    }

    mcf.cached_rates[mcf.cached_rate_count] = .{
        .provider = provider_arg.*,
        .model = model_arg.*,
        .cache_read_per_million = read_rate,
        .cache_create_per_million = create_rate,
        .has_create_rate = has_create,
    };
    mcf.cached_rate_count += 1;
    return conf.NGX_CONF_OK;
}

// llm_cost_rate_unit <provider> <unit>
fn ngx_conf_set_rate_unit(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf: *llm_cost_main_conf = @ptrCast(@alignCast(core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR));
    if (mcf.rate_unit_count >= MAX_RATE_UNIT_ENTRIES) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const provider_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const unit_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    mcf.rate_units[mcf.rate_unit_count] = .{
        .provider = provider_arg.*,
        .cost_unit = unit_arg.*,
    };
    mcf.rate_unit_count += 1;
    return conf.NGX_CONF_OK;
}

// llm_cost_backend off|log|postgres
fn ngx_conf_set_backend(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf = core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "off")) {
        mcf.*.backend = BACKEND_OFF;
    } else if (std.mem.eql(u8, s, "log")) {
        mcf.*.backend = BACKEND_LOG;
    } else if (std.mem.eql(u8, s, "postgres")) {
        mcf.*.backend = BACKEND_POSTGRES;
    } else return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// llm_cost_dsn <connection-string>
fn ngx_conf_set_dsn(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf = core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    mcf.*.dsn = arg.*;
    return conf.NGX_CONF_OK;
}

// llm_cost_table <schema.table>
fn ngx_conf_set_table(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf = core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    mcf.*.table = arg.*;
    return conf.NGX_CONF_OK;
}

fn parseVariableIndexDirective(cf: [*c]ngx_conf_t, arg: ngx_str_t) ngx_int_t {
    const raw = core.slicify(u8, arg.data, arg.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    return http.ngx_http_get_variable_index(cf, &n);
}

// llm_cost_identity <$var>
fn ngx_conf_set_identity(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    const idx = http.ngx_http_get_variable_index(cf, &n);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.identity_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_user(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.user_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_team(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.team_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_auth_fingerprint(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.auth_fingerprint_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_traffic_cohort(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.traffic_cohort_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_rate_card_version(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf = core.castPtr(llm_cost_main_conf, main) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    mcf.*.rate_card_version = arg.*;
    return conf.NGX_CONF_OK;
}

// M2 Target 2: llm_cost_org <$var>
fn ngx_conf_set_org(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.org_var_index = idx;
    return conf.NGX_CONF_OK;
}

// M2 Target 2: llm_cost_project <$var>
fn ngx_conf_set_project(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.project_var_index = idx;
    return conf.NGX_CONF_OK;
}

// M2 Target 2: llm_cost_client <$var>
fn ngx_conf_set_client(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_cost_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.client_var_index = idx;
    return conf.NGX_CONF_OK;
}

// ── Module lifecycle ───────────────────────────────────────────────────────────

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_cost_main_conf, cf.*.pool) orelse return null;
    p.*.rate_count = 0;
    p.*.rate_unit_count = 0;
    p.*.cached_rate_count = 0;
    p.*.backend = BACKEND_LOG;
    p.*.rate_card_version = status_none;
    p.*.llm_provider_idx = -1;
    p.*.llm_model_idx = -1;
    p.*.llm_streaming_idx = -1;
    p.*.llm_prompt_tokens_idx = -1;
    p.*.llm_completion_tokens_idx = -1;
    p.*.request_time_idx = -1;
    p.*.request_id_idx = -1;
    p.*.llm_fallback_attempted_idx = -1;
    p.*.llm_requested_provider_idx = -1;
    p.*.llm_requested_model_idx = -1;
    p.*.llm_translation_happened_idx = -1;
    p.*.llm_resolution_outcome_idx = -1;
    return p;
}

fn init_main_conf(cf: [*c]ngx_conf_t, mcf_ptr: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = mcf_ptr;
    return conf.NGX_CONF_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_cost_loc_conf, cf.*.pool) orelse return null;
    p.*.enabled = conf.NGX_CONF_UNSET;
    p.*.identity_var_index = -1;
    p.*.user_var_index = -1;
    p.*.team_var_index = -1;
    p.*.auth_fingerprint_var_index = -1;
    p.*.traffic_cohort_var_index = -1;
    p.*.org_var_index = -1;
    p.*.project_var_index = -1;
    p.*.client_var_index = -1;
    return p;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(llm_cost_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(llm_cost_loc_conf, child) orelse return conf.NGX_CONF_OK;
    if (c.*.enabled == conf.NGX_CONF_UNSET)
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    if (c.*.identity_var_index < 0 and prev.*.identity_var_index >= 0)
        c.*.identity_var_index = prev.*.identity_var_index;
    if (c.*.user_var_index < 0 and prev.*.user_var_index >= 0)
        c.*.user_var_index = prev.*.user_var_index;
    if (c.*.team_var_index < 0 and prev.*.team_var_index >= 0)
        c.*.team_var_index = prev.*.team_var_index;
    if (c.*.auth_fingerprint_var_index < 0 and prev.*.auth_fingerprint_var_index >= 0)
        c.*.auth_fingerprint_var_index = prev.*.auth_fingerprint_var_index;
    if (c.*.traffic_cohort_var_index < 0 and prev.*.traffic_cohort_var_index >= 0)
        c.*.traffic_cohort_var_index = prev.*.traffic_cohort_var_index;
    // M2 Target 2
    if (c.*.org_var_index < 0 and prev.*.org_var_index >= 0)
        c.*.org_var_index = prev.*.org_var_index;
    if (c.*.project_var_index < 0 and prev.*.project_var_index >= 0)
        c.*.project_var_index = prev.*.project_var_index;
    if (c.*.client_var_index < 0 and prev.*.client_var_index >= 0)
        c.*.client_var_index = prev.*.client_var_index;
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const mcf: *llm_cost_main_conf = @ptrCast(@alignCast(
        core.castPtr(llm_cost_main_conf, conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_llm_cost_module)) orelse return NGX_ERROR,
    ));

    // Pre-index llm-proxy variables still consumed via nginx variable resolution.
    mcf.request_time_idx = getVarIndex(cf, "request_time");
    mcf.request_id_idx = getVarIndex(cf, "request_id");

    // Build the idempotent INSERT SQL once at configuration time. event_id is
    // nullable for compatibility with legacy/manual rows; nginx always supplies
    // $request_id for new accounting events.
    const table = if (mcf.table.len > 0)
        core.slicify(u8, mcf.table.data, mcf.table.len)
    else
        DEFAULT_TABLE;
    const sql = std.fmt.bufPrint(&mcf.insert_sql, "INSERT INTO {s} (event_id,provider,model,cost_unit,traffic_cohort,is_streaming," ++
        "prompt_tokens,completion_tokens,total_tokens,prompt_cost,completion_cost," ++
        "total_cost,status,status_code,duration_ms,identity,user_id,team_id," ++
        "auth_key_fingerprint,rate_card_version," ++
        "requested_provider,requested_model,translation_happened,resolution_outcome," ++
        "org,project,client) " ++
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19," ++
        "$20,$21,$22,$23,$24,$25,$26,$27) ON CONFLICT (event_id) DO NOTHING", .{table}) catch return NGX_ERROR;
    mcf.insert_sql[sql.len] = 0;

    // Register cost variables.
    const var_defs = [_]struct {
        name: []const u8,
        getter: *const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, core.uintptr_t) callconv(.c) ngx_int_t,
    }{
        .{ .name = "llm_cost_status", .getter = &get_cost_status },
        .{ .name = "llm_cost_prompt", .getter = &get_cost_prompt },
        .{ .name = "llm_cost_completion", .getter = &get_cost_completion },
        .{ .name = "llm_cost_total", .getter = &get_cost_total },
        // M2 Target 1
        .{ .name = "llm_cost_requested_provider", .getter = &get_cost_requested_provider },
        .{ .name = "llm_cost_requested_model", .getter = &get_cost_requested_model },
        .{ .name = "llm_cost_translation_happened", .getter = &get_cost_translation_happened },
        .{ .name = "llm_cost_resolution_outcome", .getter = &get_cost_resolution_outcome },
        .{ .name = "llm_cost_event_id", .getter = &get_cost_event_id },
        // M2 Target 2
        .{ .name = "llm_cost_org", .getter = &get_cost_org },
        .{ .name = "llm_cost_project", .getter = &get_cost_project },
        .{ .name = "llm_cost_client", .getter = &get_cost_client },
    };
    for (&var_defs) |*vd| {
        var vn = ngx_str_t{ .len = vd.name.len, .data = @constCast(vd.name.ptr) };
        if (http.ngx_http_add_variable(cf, &vn, http.NGX_HTTP_VAR_NOCACHEABLE)) |v| {
            v.*.get_handler = vd.getter;
            v.*.data = 0;
        }
    }

    // Register LOG phase handler (postgres persistence fallback).
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var log_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[NGX_HTTP_LOG_PHASE].handlers);
    const lh = log_handlers.append() catch return NGX_ERROR;
    lh.* = log_handler;

    return NGX_OK;
}

// ── Commands ───────────────────────────────────────────────────────────────────

export const ngx_http_llm_cost_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = init_main_conf,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_cost_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_cost"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_cost,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_rate"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE4,
        .set = ngx_conf_set_rate,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_rate_unit"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_rate_unit,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_cached_rate"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE3 | conf.NGX_CONF_TAKE4,
        .set = ngx_conf_set_cached_rate,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_backend"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_backend,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_dsn"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_dsn,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_table"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_table,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_identity"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_identity,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_user"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_user,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_team"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_team,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_auth_fingerprint"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_auth_fingerprint,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_traffic_cohort"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_traffic_cohort,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_rate_card_version"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_rate_card_version,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // M2 Target 2: org/project/client billing scope.
    ngx_command_t{
        .name = ngx_string("llm_cost_org"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_org,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_project"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_project,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_cost_client"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_client,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

fn writerInitProcess(cycle: [*c]core.ngx_cycle_t) callconv(.c) ngx_int_t {
    g_pg_writer.log = cycle.*.log;
    g_pg_writer.kick.data = &g_pg_writer;
    g_pg_writer.kick.handler = writerKickHandler;
    g_pg_writer.kick.log = cycle.*.log;
    // Keep a graceful old worker alive long enough to flush queued accounting.
    // A failed connect/query observes ngx_exiting and abandons the in-memory
    // queue to the structured recovery log instead of hanging reload forever.
    g_pg_writer.kick.flags.cancelable = false;
    return NGX_OK;
}

fn writerExitProcess(cycle: [*c]core.ngx_cycle_t) callconv(.c) void {
    _ = cycle;
    g_pg_writer.stopping = true;
    if (g_pg_writer.kick.flags.timer_set) event.ngx_event_del_timer(&g_pg_writer.kick);
    event.ngz_delete_posted_event(&g_pg_writer.kick);
    if (g_pg_writer.count > 0) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, g_pg_writer.log, 0,
            "llm-cost: worker exiting with %uz unwritten postgres events; enqueued=%uL written=%uL dropped_full=%uL dropped_sql=%uL", .{
                g_pg_writer.count, g_pg_writer.enqueued, g_pg_writer.written,
                g_pg_writer.dropped_full, g_pg_writer.dropped_sql,
            });
    }
    writerDisconnect();
}

fn makeCostModule() ngx_module_t {
    var module = ngx.module.make_module(
        @constCast(&ngx_http_llm_cost_commands),
        @constCast(&ngx_http_llm_cost_module_ctx),
    );
    module.init_process = writerInitProcess;
    module.exit_process = writerExitProcess;
    return module;
}

export var ngx_http_llm_cost_module = makeCostModule();

// ── M2 Target 7: cross-module producer contract ────────────────────────────────
//
// llm-ratelimit consumes this in its LOG phase to increment monthly spend
// counters without duplicating pricing or unit-resolution logic.
//
// Eligibility: only "recorded" status — authoritative cost with known rate.
// "no_rate", "usage_missing", "skipped_error", "persist_failed" must not
// create spend because the total is either zero or incomplete.

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
pub const LlmCostObservable = contract.LlmCostObservable;

fn costToMicros(cost: f64) u64 {
    const raw = cost * 1_000_000.0;
    if (raw <= 0.0 or !std.math.isFinite(raw)) return 0;
    return @intFromFloat(@ceil(@min(raw, @as(f64, @floatFromInt(std.math.maxInt(u64) / 2)))));
}

export fn ngx_http_llm_cost_observe(r: [*c]ngx_http_request_t) callconv(.c) LlmCostObservable {
    const ctx = computeCostIfNeeded(r) orelse return .{
        .total_cost_micros = 0,
        .cost_unit = cost_unit_default,
        .eligible = 0,
    };
    if (!strEql(ctx.*.status, status_recorded)) return .{
        .total_cost_micros = 0,
        .cost_unit = ctx.*.cost_unit,
        .eligible = 0,
    };
    const micros = costToMicros(ctx.*.total_cost);
    return .{
        .total_cost_micros = micros,
        .cost_unit = ctx.*.cost_unit,
        .eligible = 1,
    };
}

export fn ngx_http_llm_cost_unit_for_provider(r: [*c]ngx_http_request_t, provider: ngx_str_t) callconv(.c) ngx_str_t {
    if (provider.len == 0) return status_none;
    const mcf = core.castPtr(
        llm_cost_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_cost_module),
    ) orelse return cost_unit_default;
    return lookupRateUnit(mcf, provider);
}

test "cost micros round conservatively and never discard positive sub-micro cost" {
    try std.testing.expectEqual(@as(u64, 0), costToMicros(0.0));
    try std.testing.expectEqual(@as(u64, 1), costToMicros(0.0000001));
    try std.testing.expectEqual(@as(u64, 1), costToMicros(0.000001));
    try std.testing.expectEqual(@as(u64, 1001), costToMicros(0.0010001));
}
