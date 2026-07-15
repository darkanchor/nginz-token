const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;
const buf = ngx.buf;
const log = ngx.log;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;

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

extern var ngx_http_core_module: ngx_module_t;

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const LlmProxyObservable = contract.LlmProxyObservable;

extern fn ngx_http_llm_proxy_observe(r: [*c]ngx_http_request_t) LlmProxyObservable;

// ── Constants ─────────────────────────────────────────────────────────────────

const NGX_HTTP_LOG_PHASE: usize = 10; // not exported by bindings

// Provider label buckets.  Cardinality is fixed: no unbounded per-model labels.
const PROV_OPENAI: usize = 0;
const PROV_ANTHROPIC: usize = 1;
const PROV_OTHER: usize = 2;
const PROV_TOTAL: usize = 3; // aggregate across all providers
const PROV_COUNT: usize = 4;

const prov_names = [PROV_COUNT][]const u8{ "openai", "anthropic", "other", "total" };

// Latency histogram raw bucket indices (non-cumulative storage).
// Bounds (ms): <100, <500, <2000, <10000, >=10000.
const LAT_BUCKET_COUNT: usize = 5;
const lat_bounds_ms = [LAT_BUCKET_COUNT - 1]u64{ 100, 500, 2000, 10000 };
const lat_bound_strs = [LAT_BUCKET_COUNT - 1][]const u8{ "100", "500", "2000", "10000" };

const MODEL_LABEL_CAPACITY: usize = 32;
const MODEL_LABEL_MAX_LEN: usize = 63;
const MODEL_OVERFLOW_LABEL = "_overflow";

// Milestone 2 Target 2: per-tenant label (bounded, opt-in).
const TENANT_LABEL_CAPACITY: usize = 32;
const TENANT_LABEL_MAX_LEN: usize = 63;
const TENANT_OVERFLOW_LABEL = "_overflow";

// Milestone 2 Target 1: resolution outcome label buckets (bounded, matching llm-proxy taxonomy).
const OUTCOME_AS_REQUESTED: usize = 0;
const OUTCOME_REPLACED_BY_POLICY: usize = 1;
const OUTCOME_FALLBACK_AFTER_FAILURE: usize = 2;
const OUTCOME_REJECTED_OUT_OF_SCOPE: usize = 3;
const OUTCOME_REJECTED_UNRESOLVABLE: usize = 4;
const OUTCOME_OTHER: usize = 5; // unknown / future values
const OUTCOME_COUNT: usize = 6;

const outcome_names = [OUTCOME_COUNT][]const u8{
    "as_requested",
    "replaced_by_policy",
    "fallback_after_failure",
    "rejected_out_of_scope",
    "rejected_unresolvable",
    "other",
};

const AUTH_RESOLVED: usize = 0;
const AUTH_MISSING_PROVIDER: usize = 1;
const AUTH_MISSING_CREDENTIAL: usize = 2;
const AUTH_MISSING_SECRET: usize = 3;
const AUTH_OTHER: usize = 4;
const AUTH_STATUS_COUNT: usize = 5;

const auth_status_names = [AUTH_STATUS_COUNT][]const u8{
    "resolved",
    "missing_provider",
    "missing_credential",
    "missing_secret",
    "other",
};

const EXPORT_NONE: ngx_uint_t = 0;
const EXPORT_PROMETHEUS: ngx_uint_t = 1;

const DEFAULT_ZONE_SIZE: usize = 1 * 1024 * 1024;
const EXPORT_BUF_SIZE: usize = 32 * 1024;
const CACHE_LINE_SIZE: usize = 64;
const MAX_WORKERS: usize = 64;

extern var ngx_worker: ngx_uint_t;
const EMIT_USAGE_UNSET: ngx_flag_t = conf.NGX_CONF_UNSET;

// ── Shared memory structures ──────────────────────────────────────────────────

// Per-provider counter slice.  All counters are u64; slab alloc guarantees
// 8-byte alignment on 64-bit.  No implicit padding needed (ngx_flag_t = c_long).
const MetricSlice = extern struct {
    requests_total: u64,
    requests_parsed: u64, // body_parsed=1
    requests_fallback: u64, // body_parsed=0 (default routing)
    requests_streaming: u64, // is_streaming=1
    requests_error_provider: u64, // response_is_error=1
    requests_error_gateway: u64, // status>=500 && !provider_error
    duration_sum_ms: u64,
    duration_count: u64,
    latency_buckets: [LAT_BUCKET_COUNT]u64, // raw (non-cumulative) counts
    usage_extracted_count: u64,
    usage_missing_count: u64,
    prompt_tokens_total: u64,
    completion_tokens_total: u64,
    total_tokens_total: u64,
    // Milestone 2 Target 1: routing/translation observability.
    requests_translation_total: u64, // translation_happened=1 (cross-dialect rewrite occurred)
    requests_replacement_total: u64, // replacement_happened=1 (pre-send policy replacement)
};

const AuthMetricSlice = extern struct {
    requests_total: u64,
    requests_error_provider: u64,
    requests_error_gateway: u64,
};

const ModelMetricSlice = extern struct {
    requests_total: u64,
    requests_error_provider: u64,
    requests_error_gateway: u64,
};

const ModelMetricEntry = extern struct {
    used: ngx_flag_t,
    key_len: u16,
    key: [MODEL_LABEL_MAX_LEN]u8,
    metrics: ModelMetricSlice,
};

// Milestone 2 Target 2: per-tenant counter slice and table entry.
const TenantMetricSlice = extern struct {
    requests_total: u64,
    requests_error_provider: u64,
    requests_error_gateway: u64,
};

const TenantMetricEntry = extern struct {
    used: ngx_flag_t,
    key_len: u16,
    key: [TENANT_LABEL_MAX_LEN]u8,
    metrics: TenantMetricSlice,
};

// Milestone 2 Target 1: per-resolution-outcome counter slice.
const OutcomeMetricSlice = extern struct {
    requests_total: u64,
};

// Per-worker hot counter slice. Counters use atomic RMW/load operations so old
// and new worker generations may safely overlap on the same nginx worker slot
// during graceful reload. The exact layout remains cache-line padded.
const WorkerSlice = extern struct {
    by_provider: [PROV_COUNT]MetricSlice,
    by_auth_status: [AUTH_STATUS_COUNT]AuthMetricSlice,
    by_outcome: [OUTCOME_COUNT]OutcomeMetricSlice,
    _pad: [24]u8, // pad to a 64-byte multiple so adjacent workers never share a line boundary
};

comptime {
    std.debug.assert(@sizeOf(WorkerSlice) % CACHE_LINE_SIZE == 0);
}

// Aggregated view produced by the export handler (not stored in shared mem).
const AggregatedView = struct {
    by_provider: [PROV_COUNT]MetricSlice,
    by_auth_status: [AUTH_STATUS_COUNT]AuthMetricSlice,
    by_outcome: [OUTCOME_COUNT]OutcomeMetricSlice,
    model_overflow: ModelMetricSlice,
    by_model: [MODEL_LABEL_CAPACITY]ModelMetricEntry,
    tenant_overflow: TenantMetricSlice,
    by_tenant: [TENANT_LABEL_CAPACITY]TenantMetricEntry,
};

const LlmMetricsStore = extern struct {
    initialized: ngx_flag_t,
    store_size: usize, // sentinel: must match @sizeOf(LlmMetricsStore) on hot-reload
    _header_pad: [48]u8, // align worker[0] to its own cache line
    // Per-worker counter slices — updated atomically without the slab mutex.
    workers: [MAX_WORKERS]WorkerSlice,
    // Global model/tenant tables — all workers may insert; slab mutex required.
    model_overflow: ModelMetricSlice,
    by_model: [MODEL_LABEL_CAPACITY]ModelMetricEntry,
    tenant_overflow: TenantMetricSlice,
    by_tenant: [TENANT_LABEL_CAPACITY]TenantMetricEntry,
};

comptime {
    std.debug.assert(@offsetOf(LlmMetricsStore, "workers") == CACHE_LINE_SIZE);
}

// ── Config structs ────────────────────────────────────────────────────────────

const llm_metrics_main_conf = extern struct {
    zone_name: ngx_str_t,
    zone_size: usize,
    zone_set: ngx_flag_t,
    // ngx_shm_zone_t belongs to this nginx configuration cycle.
    zone: [*c]core.ngx_shm_zone_t,
    // LOG-path hot data comes from ngx_http_llm_proxy_observe() directly.
    // Only auth status is still resolved via variable index (no observe() field for it).
    llm_auth_status_idx: ngx_int_t,
};

const llm_metrics_loc_conf = extern struct {
    enabled: ngx_flag_t, // llm_metrics; — enable accounting on this location
    emit_usage: ngx_flag_t, // llm_metrics_emit_usage on|off
    label_model: ngx_flag_t, // llm_metrics_label_model on|off
    label_auth_status: ngx_flag_t, // llm_metrics_label_auth_status on|off
    export_mode: ngx_uint_t, // llm_metrics_export prometheus
    // Milestone 2 Target 1: resolution-outcome label (bounded; opt-in).
    label_resolution_outcome: ngx_flag_t, // llm_metrics_label_resolution_outcome on|off
    // Milestone 2 Target 2: tenant label (bounded; opt-in).
    label_tenant: ngx_flag_t, // llm_metrics_label_tenant on|off
    tenant_var_idx: ngx_int_t, // variable index set by llm_metrics_tenant_source; -1 = not configured
};

// ── Global state ──────────────────────────────────────────────────────────────

// The zone descriptor is stored in llm_metrics_main_conf, never globally.

// ── Shmem helpers ─────────────────────────────────────────────────────────────

fn getStoreAndPool(mcf: [*c]llm_metrics_main_conf) struct { shpool: [*c]core.ngx_slab_pool_t, store: [*c]LlmMetricsStore } {
    const zone = mcf.*.zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(LlmMetricsStore) };
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(LlmMetricsStore) };
    const store = core.castPtr(LlmMetricsStore, zone.*.data) orelse return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(LlmMetricsStore) };
    return .{ .shpool = shpool, .store = store };
}

fn zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        const prev = core.castPtr(LlmMetricsStore, data) orelse return NGX_ERROR;
        if (prev.*.initialized == 1 and prev.*.store_size == @sizeOf(LlmMetricsStore)) {
            zone.*.data = data;
            return NGX_OK;
        }
        return NGX_ERROR; // store layout changed — full restart required
    }
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        const prev = core.castPtr(LlmMetricsStore, shpool.*.data) orelse return NGX_ERROR;
        if (prev.*.initialized == 1 and prev.*.store_size == @sizeOf(LlmMetricsStore)) {
            zone.*.data = shpool.*.data;
            return NGX_OK;
        }
        return NGX_ERROR;
    }
    const mem = shm.ngx_slab_calloc(shpool, @sizeOf(LlmMetricsStore)) orelse return NGX_ERROR;
    const store = core.castPtr(LlmMetricsStore, mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(LlmMetricsStore);
    store.*.initialized = 1;
    store.*.store_size = @sizeOf(LlmMetricsStore);
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

// ── Variable resolution helpers ───────────────────────────────────────────────

fn resolveUintVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?ngx_uint_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    const s = core.slicify(u8, val.*.data, val.*.flags.len);
    return std.fmt.parseInt(ngx_uint_t, s, 10) catch null;
}

fn resolveStrVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?ngx_str_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    return ngx_str_t{ .data = val.*.data, .len = val.*.flags.len };
}

fn getVarIndex(cf: [*c]ngx_conf_t, name: []const u8) ngx_int_t {
    var n = ngx_str_t{ .len = name.len, .data = @constCast(name.ptr) };
    return http.ngx_http_get_variable_index(cf, &n);
}

// ── Provider label mapping ────────────────────────────────────────────────────

fn providerIndex(provider: ?ngx_str_t) usize {
    const p = provider orelse return PROV_OTHER;
    if (p.len == 0) return PROV_OTHER;
    const s = core.slicify(u8, p.data, p.len);
    if (std.ascii.eqlIgnoreCase(s, "openai")) return PROV_OPENAI;
    if (std.ascii.eqlIgnoreCase(s, "anthropic")) return PROV_ANTHROPIC;
    return PROV_OTHER;
}

// Milestone 2 Target 1: map resolution_outcome integer directly to index.
// obs.resolution_outcome is already an integer matching OUTCOME_* constants —
// the old approach of converting to a string then parsing back is unnecessary.
fn outcomeIndexFromUint(outcome: ngx_uint_t, has_proxy: bool) ?usize {
    if (!has_proxy) return null;
    return switch (outcome) {
        0 => OUTCOME_AS_REQUESTED,
        1 => OUTCOME_REPLACED_BY_POLICY,
        2 => OUTCOME_FALLBACK_AFTER_FAILURE,
        3 => OUTCOME_REJECTED_OUT_OF_SCOPE,
        4 => OUTCOME_REJECTED_UNRESOLVABLE,
        else => OUTCOME_OTHER,
    };
}

fn authStatusIndex(status: ?ngx_str_t) ?usize {
    const s = status orelse return null;
    if (s.len == 0) return null;
    const name = core.slicify(u8, s.data, s.len);
    if (std.mem.eql(u8, name, "resolved")) return AUTH_RESOLVED;
    if (std.mem.eql(u8, name, "missing_provider")) return AUTH_MISSING_PROVIDER;
    if (std.mem.eql(u8, name, "missing_credential")) return AUTH_MISSING_CREDENTIAL;
    if (std.mem.eql(u8, name, "missing_secret")) return AUTH_MISSING_SECRET;
    return AUTH_OTHER;
}

const NormalizedModel = struct {
    len: usize,
    buf: [MODEL_LABEL_MAX_LEN]u8,
};

const ModelResolution = union(enum) {
    none,
    normalized: NormalizedModel,
    overflow,
};

fn normalizeModelLabel(model: ?ngx_str_t) ModelResolution {
    const m = model orelse return .none;
    if (m.len == 0) return .none;
    if (m.len > MODEL_LABEL_MAX_LEN) return .overflow;

    var out: [MODEL_LABEL_MAX_LEN]u8 = undefined;
    const s = core.slicify(u8, m.data, m.len);
    for (s, 0..) |c, i| {
        if (c == 0 or c == '\n' or c == '\r') return .overflow;
        out[i] = std.ascii.toLower(c);
    }
    return .{ .normalized = .{ .len = s.len, .buf = out } };
}

fn modelEntryMatches(entry: *const ModelMetricEntry, model: *const NormalizedModel) bool {
    if (entry.used != 1) return false;
    if (entry.key_len != model.len) return false;
    return std.mem.eql(u8, entry.key[0..entry.key_len], model.buf[0..model.len]);
}

fn findOrInsertModelEntry(store: *LlmMetricsStore, model: *const NormalizedModel) ?*ModelMetricEntry {
    var first_empty: ?*ModelMetricEntry = null;
    for (&store.by_model) |*entry| {
        if (entry.used == 1) {
            if (modelEntryMatches(entry, model)) return entry;
            continue;
        }
        if (first_empty == null) first_empty = entry;
    }

    const entry = first_empty orelse return null;
    entry.* = std.mem.zeroes(ModelMetricEntry);
    entry.used = 1;
    entry.key_len = @intCast(model.len);
    @memcpy(entry.key[0..model.len], model.buf[0..model.len]);
    return entry;
}

// Milestone 2 Target 2: tenant label helpers (same bounded-table pattern as model labels).
fn tenantEntryMatches(entry: *const TenantMetricEntry, tenant: *const NormalizedModel) bool {
    if (entry.used != 1) return false;
    if (entry.key_len != tenant.len) return false;
    return std.mem.eql(u8, entry.key[0..entry.key_len], tenant.buf[0..tenant.len]);
}

fn findOrInsertTenantEntry(store: *LlmMetricsStore, tenant: *const NormalizedModel) ?*TenantMetricEntry {
    var first_empty: ?*TenantMetricEntry = null;
    for (&store.by_tenant) |*entry| {
        if (entry.used == 1) {
            if (tenantEntryMatches(entry, tenant)) return entry;
            continue;
        }
        if (first_empty == null) first_empty = entry;
    }

    const entry = first_empty orelse return null;
    entry.* = std.mem.zeroes(TenantMetricEntry);
    entry.used = 1;
    entry.key_len = @intCast(tenant.len);
    @memcpy(entry.key[0..tenant.len], tenant.buf[0..tenant.len]);
    return entry;
}

// ── Duration helper ───────────────────────────────────────────────────────────

fn requestDurationMs(r: [*c]ngx_http_request_t) u64 {
    const now = core.ngx_timeofday();
    if (now == null) return 0;
    const now_ms = @as(u64, @intCast(now.*.sec)) * 1000 + @as(u64, now.*.msec);
    const start_ms = @as(u64, @intCast(r.*.start_sec)) * 1000 + @as(u64, r.*.start_msec);
    return if (now_ms >= start_ms) now_ms - start_ms else 0;
}

fn latencyBucket(ms: u64) usize {
    for (lat_bounds_ms, 0..) |bound, i| {
        if (ms < bound) return i;
    }
    return LAT_BUCKET_COUNT - 1;
}

fn workerSlotForId(worker_id: ngx_uint_t) usize {
    if (worker_id < MAX_WORKERS) return @intCast(worker_id);
    return @intCast(worker_id % MAX_WORKERS);
}

inline fn atomicAdd(counter: *u64, value: u64) void {
    if (value == 0) return;
    _ = @atomicRmw(u64, counter, .Add, value, .monotonic);
}

inline fn atomicCounterLoad(counter: *const u64) u64 {
    return @atomicLoad(u64, counter, .monotonic);
}

// ── LOG phase handler (Phase 1 + Phase 2) ────────────────────────────────────

fn log_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        llm_metrics_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_metrics_module),
    ) orelse return NGX_OK;
    if (lccf.*.enabled != 1) return NGX_OK;

    const mcf = core.castPtr(
        llm_metrics_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_metrics_module),
    ) orelse return NGX_OK;

    const sp = getStoreAndPool(mcf);
    const shpool = sp.shpool orelse return NGX_OK;
    const store = sp.store orelse return NGX_OK;
    if (store.*.initialized != 1) return NGX_OK;

    // Gather core per-request facts directly from llm-proxy ctx to avoid
    // repeated nginx variable lookup/parsing in the LOG phase.
    const obs = ngx_http_llm_proxy_observe(r);
    const provider: ?ngx_str_t = if (obs.provider.len > 0) obs.provider else null;
    const is_streaming = obs.is_streaming;
    const body_parsed = obs.body_parsed;
    const usage_extracted = obs.usage_extracted;
    const response_is_error = obs.response_is_error_shape;
    const model_resolution = if (lccf.*.label_model == 1)
        normalizeModelLabel(if (obs.model.len > 0) obs.model else null)
    else
        .none;
    const auth_status_idx = if (lccf.*.label_auth_status == 1)
        authStatusIndex(resolveStrVar(r, mcf.*.llm_auth_status_idx))
    else
        null;

    // Milestone 2 Target 1: read Phase 12/13 routing/translation facts.
    const translation_happened = obs.translation_happened;
    const replacement_happened = obs.replacement_happened;
    const outcome_idx = if (lccf.*.label_resolution_outcome == 1)
        outcomeIndexFromUint(obs.resolution_outcome, obs.provider.len > 0)
    else
        null;

    // Milestone 2 Target 2: resolve tenant label (opt-in; variable source is per-location).
    const tenant_resolution = if (lccf.*.label_tenant == 1 and lccf.*.tenant_var_idx >= 0)
        normalizeModelLabel(resolveStrVar(r, lccf.*.tenant_var_idx))
    else
        ModelResolution.none;

    const pidx = providerIndex(provider);
    const status = r.*.headers_out.status;

    // Phase 2: duration and usage.
    const dur_ms = requestDurationMs(r);
    const lat_bucket = latencyBucket(dur_ms);

    // Token counters only when usage was extracted and emit_usage is on.
    var prompt: u64 = 0;
    var completion: u64 = 0;
    var total: u64 = 0;
    if (lccf.*.emit_usage == 1 and usage_extracted == 1) {
        prompt = obs.prompt_tokens;
        completion = obs.completion_tokens;
        total = obs.total_tokens;
    }

    const is_provider_error = response_is_error == 1;
    const is_gateway_error = !is_provider_error and status >= 500;
    const emit_tokens = lccf.*.emit_usage == 1 and usage_extracted == 1;

    // Write per-worker counters without the slab mutex. Atomic RMW keeps slots
    // correct when old and new worker generations overlap during reload or a
    // worker id wraps onto an existing slot.
    const worker_id = workerSlotForId(ngx_worker);
    const workers_ptr: [*]WorkerSlice = @ptrCast(&store.*.workers);
    const ws: *WorkerSlice = &workers_ptr[worker_id];

    const provider_slice: *MetricSlice = &ws.by_provider[pidx];
    const total_slice: *MetricSlice = &ws.by_provider[PROV_TOTAL];

    // @intFromBool compiles to cmov/setz — branchless on the steady-state path.
    inline for ([_]*MetricSlice{ provider_slice, total_slice }) |s| {
        atomicAdd(&s.requests_total, 1);
        atomicAdd(&s.requests_parsed, @intFromBool(body_parsed == 1));
        atomicAdd(&s.requests_fallback, @intFromBool(body_parsed == 0));
        atomicAdd(&s.requests_streaming, @intFromBool(is_streaming == 1));
        atomicAdd(&s.requests_error_provider, @intFromBool(is_provider_error));
        atomicAdd(&s.requests_error_gateway, @intFromBool(is_gateway_error));
        atomicAdd(&s.duration_sum_ms, dur_ms);
        atomicAdd(&s.duration_count, 1);
        atomicAdd(&s.latency_buckets[lat_bucket], 1);
        atomicAdd(&s.usage_extracted_count, @intFromBool(usage_extracted == 1));
        atomicAdd(&s.usage_missing_count, @intFromBool(usage_extracted == 0));
        if (emit_tokens) {
            atomicAdd(&s.prompt_tokens_total, prompt);
            atomicAdd(&s.completion_tokens_total, completion);
            atomicAdd(&s.total_tokens_total, total);
        }
        atomicAdd(&s.requests_translation_total, @intFromBool(translation_happened == 1));
        atomicAdd(&s.requests_replacement_total, @intFromBool(replacement_happened == 1));
    }

    if (outcome_idx) |idx| {
        atomicAdd(&ws.by_outcome[idx].requests_total, 1);
    }

    if (auth_status_idx) |idx| {
        const s: *AuthMetricSlice = &ws.by_auth_status[idx];
        atomicAdd(&s.requests_total, 1);
        atomicAdd(&s.requests_error_provider, @intFromBool(is_provider_error));
        atomicAdd(&s.requests_error_gateway, @intFromBool(is_gateway_error));
    }

    // Model and tenant tables are shared across workers — inserts require the
    // slab mutex.  Skip the lock entirely when neither is enabled.
    const needs_model = switch (model_resolution) {
        .none => false,
        else => true,
    };
    const needs_tenant = switch (tenant_resolution) {
        .none => false,
        else => true,
    };

    if (needs_model or needs_tenant) {
        shm.ngx_shmtx_lock(&shpool.*.mutex);

        switch (tenant_resolution) {
            .none => {},
            .overflow => {
                store.*.tenant_overflow.requests_total += 1;
                store.*.tenant_overflow.requests_error_provider += @intFromBool(is_provider_error);
                store.*.tenant_overflow.requests_error_gateway += @intFromBool(is_gateway_error);
            },
            .normalized => |tenant| {
                if (findOrInsertTenantEntry(&store.*, &tenant)) |entry| {
                    entry.metrics.requests_total += 1;
                    entry.metrics.requests_error_provider += @intFromBool(is_provider_error);
                    entry.metrics.requests_error_gateway += @intFromBool(is_gateway_error);
                } else {
                    store.*.tenant_overflow.requests_total += 1;
                    store.*.tenant_overflow.requests_error_provider += @intFromBool(is_provider_error);
                    store.*.tenant_overflow.requests_error_gateway += @intFromBool(is_gateway_error);
                }
            },
        }

        switch (model_resolution) {
            .none => {},
            .overflow => {
                store.*.model_overflow.requests_total += 1;
                store.*.model_overflow.requests_error_provider += @intFromBool(is_provider_error);
                store.*.model_overflow.requests_error_gateway += @intFromBool(is_gateway_error);
            },
            .normalized => |model| {
                if (findOrInsertModelEntry(&store.*, &model)) |entry| {
                    entry.metrics.requests_total += 1;
                    entry.metrics.requests_error_provider += @intFromBool(is_provider_error);
                    entry.metrics.requests_error_gateway += @intFromBool(is_gateway_error);
                } else {
                    store.*.model_overflow.requests_total += 1;
                    store.*.model_overflow.requests_error_provider += @intFromBool(is_provider_error);
                    store.*.model_overflow.requests_error_gateway += @intFromBool(is_gateway_error);
                }
            },
        }

        shm.ngx_shmtx_unlock(&shpool.*.mutex);
    }

    return NGX_OK;
}

// ── Worker aggregation ────────────────────────────────────────────────────────

fn addMetricSlice(dst: *MetricSlice, src: *const MetricSlice) void {
    dst.requests_total += atomicCounterLoad(&src.requests_total);
    dst.requests_parsed += atomicCounterLoad(&src.requests_parsed);
    dst.requests_fallback += atomicCounterLoad(&src.requests_fallback);
    dst.requests_streaming += atomicCounterLoad(&src.requests_streaming);
    dst.requests_error_provider += atomicCounterLoad(&src.requests_error_provider);
    dst.requests_error_gateway += atomicCounterLoad(&src.requests_error_gateway);
    dst.duration_sum_ms += atomicCounterLoad(&src.duration_sum_ms);
    dst.duration_count += atomicCounterLoad(&src.duration_count);
    for (&dst.latency_buckets, &src.latency_buckets) |*d, *s| d.* += atomicCounterLoad(s);
    dst.usage_extracted_count += atomicCounterLoad(&src.usage_extracted_count);
    dst.usage_missing_count += atomicCounterLoad(&src.usage_missing_count);
    dst.prompt_tokens_total += atomicCounterLoad(&src.prompt_tokens_total);
    dst.completion_tokens_total += atomicCounterLoad(&src.completion_tokens_total);
    dst.total_tokens_total += atomicCounterLoad(&src.total_tokens_total);
    dst.requests_translation_total += atomicCounterLoad(&src.requests_translation_total);
    dst.requests_replacement_total += atomicCounterLoad(&src.requests_replacement_total);
}

fn aggregateWorkers(store: *const LlmMetricsStore) AggregatedView {
    var view = AggregatedView{
        .by_provider = std.mem.zeroes([PROV_COUNT]MetricSlice),
        .by_auth_status = std.mem.zeroes([AUTH_STATUS_COUNT]AuthMetricSlice),
        .by_outcome = std.mem.zeroes([OUTCOME_COUNT]OutcomeMetricSlice),
        .model_overflow = std.mem.zeroes(ModelMetricSlice),
        .by_model = std.mem.zeroes([MODEL_LABEL_CAPACITY]ModelMetricEntry),
        .tenant_overflow = std.mem.zeroes(TenantMetricSlice),
        .by_tenant = std.mem.zeroes([TENANT_LABEL_CAPACITY]TenantMetricEntry),
    };
    for (&store.workers) |*ws| {
        for (&view.by_provider, &ws.by_provider) |*dst, *src| addMetricSlice(dst, src);
        for (&view.by_auth_status, &ws.by_auth_status) |*dst, *src| {
            dst.requests_total += atomicCounterLoad(&src.requests_total);
            dst.requests_error_provider += atomicCounterLoad(&src.requests_error_provider);
            dst.requests_error_gateway += atomicCounterLoad(&src.requests_error_gateway);
        }
        for (&view.by_outcome, &ws.by_outcome) |*dst, *src| {
            dst.requests_total += atomicCounterLoad(&src.requests_total);
        }
    }
    return view;
}

// ── Export handler (Phase 3 — Prometheus text format) ────────────────────────

// write helpers: advance cursor pointer, silently truncate if buf is full

fn writeStr(cursor: *[*c]u8, end: [*c]u8, s: []const u8) void {
    const avail = @intFromPtr(end) - @intFromPtr(cursor.*);
    const n = @min(s.len, avail);
    if (n == 0) return;
    @memcpy(cursor.*[0..n], s[0..n]);
    cursor.* += n;
}

fn writeU64(cursor: *[*c]u8, end: [*c]u8, val: u64) void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return;
    writeStr(cursor, end, s);
}

fn writeMeta(cursor: *[*c]u8, end: [*c]u8, name: []const u8, help: []const u8, kind: []const u8) void {
    writeStr(cursor, end, "# HELP ");
    writeStr(cursor, end, name);
    writeStr(cursor, end, " ");
    writeStr(cursor, end, help);
    writeStr(cursor, end, "\n# TYPE ");
    writeStr(cursor, end, name);
    writeStr(cursor, end, " ");
    writeStr(cursor, end, kind);
    writeStr(cursor, end, "\n");
}

// Emit one Prometheus counter line:  name{provider="..."} value\n
fn writeCounterLine(cursor: *[*c]u8, end: [*c]u8, name: []const u8, prov: []const u8, val: u64) void {
    writeStr(cursor, end, name);
    writeStr(cursor, end, "{provider=\"");
    writeStr(cursor, end, prov);
    writeStr(cursor, end, "\"} ");
    writeU64(cursor, end, val);
    writeStr(cursor, end, "\n");
}

fn writeAuthStatusCounterLine(cursor: *[*c]u8, end: [*c]u8, name: []const u8, auth_status: []const u8, val: u64) void {
    writeStr(cursor, end, name);
    writeStr(cursor, end, "{auth_status=\"");
    writeStr(cursor, end, auth_status);
    writeStr(cursor, end, "\"} ");
    writeU64(cursor, end, val);
    writeStr(cursor, end, "\n");
}

fn writePrometheusLabelValue(cursor: *[*c]u8, end: [*c]u8, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '\\' => writeStr(cursor, end, "\\\\"),
            '"' => writeStr(cursor, end, "\\\""),
            '\n' => writeStr(cursor, end, "\\n"),
            else => writeStr(cursor, end, &[_]u8{c}),
        }
    }
}

fn writeModelCounterLine(cursor: *[*c]u8, end: [*c]u8, name: []const u8, model: []const u8, val: u64) void {
    writeStr(cursor, end, name);
    writeStr(cursor, end, "{model=\"");
    writePrometheusLabelValue(cursor, end, model);
    writeStr(cursor, end, "\"} ");
    writeU64(cursor, end, val);
    writeStr(cursor, end, "\n");
}

// Emit all four provider rows for a simple counter metric.
fn writeCounter(cursor: *[*c]u8, end: [*c]u8, name: []const u8, help: []const u8, slices: *const [PROV_COUNT]MetricSlice, field_fn: fn (*const MetricSlice) u64) void {
    writeMeta(cursor, end, name, help, "counter");
    for (slices, prov_names) |*s, pname| {
        writeCounterLine(cursor, end, name, pname, field_fn(s));
    }
}

fn field_requests_total(s: *const MetricSlice) u64 {
    return s.requests_total;
}
fn field_requests_parsed(s: *const MetricSlice) u64 {
    return s.requests_parsed;
}
fn field_requests_fallback(s: *const MetricSlice) u64 {
    return s.requests_fallback;
}
fn field_requests_streaming(s: *const MetricSlice) u64 {
    return s.requests_streaming;
}
fn field_error_provider(s: *const MetricSlice) u64 {
    return s.requests_error_provider;
}
fn field_error_gateway(s: *const MetricSlice) u64 {
    return s.requests_error_gateway;
}
fn field_duration_sum(s: *const MetricSlice) u64 {
    return s.duration_sum_ms;
}
fn field_duration_count(s: *const MetricSlice) u64 {
    return s.duration_count;
}
fn field_usage_extracted(s: *const MetricSlice) u64 {
    return s.usage_extracted_count;
}
fn field_usage_missing(s: *const MetricSlice) u64 {
    return s.usage_missing_count;
}
fn field_prompt_tokens(s: *const MetricSlice) u64 {
    return s.prompt_tokens_total;
}
fn field_completion_tokens(s: *const MetricSlice) u64 {
    return s.completion_tokens_total;
}
fn field_total_tokens(s: *const MetricSlice) u64 {
    return s.total_tokens_total;
}
fn field_auth_requests_total(s: *const AuthMetricSlice) u64 {
    return s.requests_total;
}
fn field_auth_error_provider(s: *const AuthMetricSlice) u64 {
    return s.requests_error_provider;
}
fn field_auth_error_gateway(s: *const AuthMetricSlice) u64 {
    return s.requests_error_gateway;
}
fn field_model_requests_total(s: *const ModelMetricSlice) u64 {
    return s.requests_total;
}
fn field_model_error_provider(s: *const ModelMetricSlice) u64 {
    return s.requests_error_provider;
}
fn field_model_error_gateway(s: *const ModelMetricSlice) u64 {
    return s.requests_error_gateway;
}
// Milestone 2 Target 1 field accessors.
fn field_translation_total(s: *const MetricSlice) u64 {
    return s.requests_translation_total;
}
fn field_replacement_total(s: *const MetricSlice) u64 {
    return s.requests_replacement_total;
}
fn field_outcome_total(s: *const OutcomeMetricSlice) u64 {
    return s.requests_total;
}
// Milestone 2 Target 2 field accessors.
fn field_tenant_requests_total(s: *const TenantMetricSlice) u64 {
    return s.requests_total;
}
fn field_tenant_error_provider(s: *const TenantMetricSlice) u64 {
    return s.requests_error_provider;
}
fn field_tenant_error_gateway(s: *const TenantMetricSlice) u64 {
    return s.requests_error_gateway;
}

fn writeAuthStatusCounter(
    cursor: *[*c]u8,
    end: [*c]u8,
    name: []const u8,
    help: []const u8,
    slices: *const [AUTH_STATUS_COUNT]AuthMetricSlice,
    field_fn: fn (*const AuthMetricSlice) u64,
) void {
    writeMeta(cursor, end, name, help, "counter");
    for (slices, auth_status_names) |*s, status_name| {
        writeAuthStatusCounterLine(cursor, end, name, status_name, field_fn(s));
    }
}

fn writeOutcomeCounterLine(cursor: *[*c]u8, end: [*c]u8, name: []const u8, outcome: []const u8, val: u64) void {
    writeStr(cursor, end, name);
    writeStr(cursor, end, "{resolution_outcome=\"");
    writeStr(cursor, end, outcome);
    writeStr(cursor, end, "\"} ");
    writeU64(cursor, end, val);
    writeStr(cursor, end, "\n");
}

fn writeOutcomeCounter(
    cursor: *[*c]u8,
    end: [*c]u8,
    name: []const u8,
    help: []const u8,
    slices: *const [OUTCOME_COUNT]OutcomeMetricSlice,
    field_fn: fn (*const OutcomeMetricSlice) u64,
) void {
    writeMeta(cursor, end, name, help, "counter");
    for (slices, outcome_names) |*s, oname| {
        writeOutcomeCounterLine(cursor, end, name, oname, field_fn(s));
    }
}

fn writeTenantCounterLine(cursor: *[*c]u8, end: [*c]u8, name: []const u8, tenant: []const u8, val: u64) void {
    writeStr(cursor, end, name);
    writeStr(cursor, end, "{tenant=\"");
    writePrometheusLabelValue(cursor, end, tenant);
    writeStr(cursor, end, "\"} ");
    writeU64(cursor, end, val);
    writeStr(cursor, end, "\n");
}

fn writeTenantCounter(
    cursor: *[*c]u8,
    end: [*c]u8,
    name: []const u8,
    help: []const u8,
    view: *const AggregatedView,
    field_fn: fn (*const TenantMetricSlice) u64,
) void {
    writeMeta(cursor, end, name, help, "counter");
    for (view.*.by_tenant) |entry| {
        if (entry.used != 1) continue;
        writeTenantCounterLine(cursor, end, name, entry.key[0..entry.key_len], field_fn(&entry.metrics));
    }
    if (field_fn(&view.*.tenant_overflow) > 0) {
        writeTenantCounterLine(cursor, end, name, TENANT_OVERFLOW_LABEL, field_fn(&view.*.tenant_overflow));
    }
}

fn writeModelCounter(
    cursor: *[*c]u8,
    end: [*c]u8,
    name: []const u8,
    help: []const u8,
    view: *const AggregatedView,
    field_fn: fn (*const ModelMetricSlice) u64,
) void {
    writeMeta(cursor, end, name, help, "counter");
    for (view.*.by_model) |entry| {
        if (entry.used != 1) continue;
        writeModelCounterLine(cursor, end, name, entry.key[0..entry.key_len], field_fn(&entry.metrics));
    }
    if (field_fn(&view.*.model_overflow) > 0) {
        writeModelCounterLine(cursor, end, name, MODEL_OVERFLOW_LABEL, field_fn(&view.*.model_overflow));
    }
}

fn formatMetrics(cursor: *[*c]u8, end: [*c]u8, view: *const AggregatedView) void {
    const slices = &view.by_provider;
    const auth_slices = &view.by_auth_status;

    writeCounter(cursor, end, "llm_requests_total", "Total LLM requests observed by llm-metrics", slices, field_requests_total);
    writeCounter(cursor, end, "llm_requests_parsed_total", "Requests with successfully JSON-parsed request body (body_parsed=1)", slices, field_requests_parsed);
    writeCounter(cursor, end, "llm_requests_fallback_total", "Requests using default routing because body was not parsed (body_parsed=0)", slices, field_requests_fallback);
    writeCounter(cursor, end, "llm_requests_streaming_total", "Streaming LLM requests (is_streaming=1)", slices, field_requests_streaming);
    writeCounter(cursor, end, "llm_requests_error_provider_total", "Requests where provider returned an API error response (response_is_error=1)", slices, field_error_provider);
    writeCounter(cursor, end, "llm_requests_error_gateway_total", "Requests that failed at the gateway layer (status>=500 and not a provider error)", slices, field_error_gateway);

    // Prometheus histogram format: cumulative buckets plus per-provider
    // _sum/_count within the histogram family itself.
    writeMeta(cursor, end, "llm_request_duration_milliseconds", "LLM request duration distribution in milliseconds", "histogram");
    for (slices, prov_names) |*s, pname| {
        var cumulative: u64 = 0;
        for (lat_bound_strs, 0..) |le_str, i| {
            cumulative += s.latency_buckets[i];
            writeStr(cursor, end, "llm_request_duration_milliseconds_bucket{le=\"");
            writeStr(cursor, end, le_str);
            writeStr(cursor, end, "\",provider=\"");
            writeStr(cursor, end, pname);
            writeStr(cursor, end, "\"} ");
            writeU64(cursor, end, cumulative);
            writeStr(cursor, end, "\n");
        }
        // +Inf bucket = requests_total for this provider
        cumulative += s.latency_buckets[LAT_BUCKET_COUNT - 1];
        writeStr(cursor, end, "llm_request_duration_milliseconds_bucket{le=\"+Inf\",provider=\"");
        writeStr(cursor, end, pname);
        writeStr(cursor, end, "\"} ");
        writeU64(cursor, end, cumulative);
        writeStr(cursor, end, "\n");
        // sum and count per provider within histogram family
        writeStr(cursor, end, "llm_request_duration_milliseconds_sum{provider=\"");
        writeStr(cursor, end, pname);
        writeStr(cursor, end, "\"} ");
        writeU64(cursor, end, s.duration_sum_ms);
        writeStr(cursor, end, "\n");
        writeStr(cursor, end, "llm_request_duration_milliseconds_count{provider=\"");
        writeStr(cursor, end, pname);
        writeStr(cursor, end, "\"} ");
        writeU64(cursor, end, s.duration_count);
        writeStr(cursor, end, "\n");
    }

    writeCounter(cursor, end, "llm_usage_extracted_total", "Requests where token usage was successfully extracted from the response", slices, field_usage_extracted);
    writeCounter(cursor, end, "llm_usage_missing_total", "Requests where token usage was absent in the response (cost data incomplete)", slices, field_usage_missing);
    writeCounter(cursor, end, "llm_prompt_tokens_total", "Accumulated prompt tokens (requires llm_metrics_emit_usage on)", slices, field_prompt_tokens);
    writeCounter(cursor, end, "llm_completion_tokens_total", "Accumulated completion tokens (requires llm_metrics_emit_usage on)", slices, field_completion_tokens);
    writeCounter(cursor, end, "llm_total_tokens_total", "Accumulated total tokens prompt+completion (requires llm_metrics_emit_usage on)", slices, field_total_tokens);

    writeAuthStatusCounter(cursor, end, "llm_requests_auth_status_total", "LLM requests observed with llm_auth_status labeling enabled on the source location", auth_slices, field_auth_requests_total);
    writeAuthStatusCounter(cursor, end, "llm_requests_error_provider_auth_status_total", "Provider-error requests observed with llm_auth_status labeling enabled on the source location", auth_slices, field_auth_error_provider);
    writeAuthStatusCounter(cursor, end, "llm_requests_error_gateway_auth_status_total", "Gateway-error requests observed with llm_auth_status labeling enabled on the source location", auth_slices, field_auth_error_gateway);
    writeModelCounter(cursor, end, "llm_requests_model_total", "LLM requests observed with llm_metrics_label_model enabled on the source location", view, field_model_requests_total);
    writeModelCounter(cursor, end, "llm_requests_error_provider_model_total", "Provider-error requests observed with llm_metrics_label_model enabled on the source location", view, field_model_error_provider);
    writeModelCounter(cursor, end, "llm_requests_error_gateway_model_total", "Gateway-error requests observed with llm_metrics_label_model enabled on the source location", view, field_model_error_gateway);

    // Milestone 2 Target 1: translation/replacement/outcome counters.
    writeCounter(cursor, end, "llm_requests_translation_total", "Requests where cross-dialect translation occurred (translation_happened=1)", slices, field_translation_total);
    writeCounter(cursor, end, "llm_requests_replacement_total", "Requests where pre-send provider replacement occurred (replacement_happened=1)", slices, field_replacement_total);
    writeOutcomeCounter(cursor, end, "llm_requests_resolution_outcome_total", "Requests by resolution outcome (requires llm_metrics_label_resolution_outcome on)", &view.by_outcome, field_outcome_total);

    // Milestone 2 Target 2: per-tenant counters (opt-in via llm_metrics_label_tenant).
    writeTenantCounter(cursor, end, "llm_requests_tenant_total", "LLM requests by tenant (requires llm_metrics_label_tenant on and llm_metrics_tenant_source)", view, field_tenant_requests_total);
    writeTenantCounter(cursor, end, "llm_requests_error_provider_tenant_total", "Provider-error requests by tenant (requires llm_metrics_label_tenant on)", view, field_tenant_error_provider);
    writeTenantCounter(cursor, end, "llm_requests_error_gateway_tenant_total", "Gateway-error requests by tenant (requires llm_metrics_label_tenant on)", view, field_tenant_error_gateway);
}

fn export_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Reject subrequests to prevent this handler from acting as an auth_request
    // allow-gate: returning 200 from a subrequest would bypass access control.
    if (r != r.*.main) {
        r.*.headers_out.status = 403;
        r.*.headers_out.content_length_n = 0;
        return http.ngx_http_send_header(r);
    }

    _ = http.ngx_http_discard_request_body(r);

    const mcf = core.castPtr(
        llm_metrics_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_metrics_module),
    ) orelse return NGX_ERROR;
    const sp = getStoreAndPool(mcf);
    const store = sp.store orelse {
        r.*.headers_out.status = 503;
        r.*.headers_out.content_length_n = 0;
        return http.ngx_http_send_header(r);
    };

    if (store.*.initialized != 1) {
        r.*.headers_out.status = 503;
        r.*.headers_out.content_length_n = 0;
        return http.ngx_http_send_header(r);
    }

    // Allocate response buffer.
    const b = buf.ngx_create_temp_buf(r.*.pool, EXPORT_BUF_SIZE);
    if (b == core.nullptr(buf.ngx_buf_t)) return NGX_ERROR;

    // Worker counters are read atomically without the slab mutex. The mutex
    // protects only the global model/tenant tables whose writers also take it.
    var view = aggregateWorkers(store);
    const shpool = sp.shpool orelse return NGX_ERROR;
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    view.model_overflow = store.*.model_overflow;
    view.by_model = store.*.by_model;
    view.tenant_overflow = store.*.tenant_overflow;
    view.by_tenant = store.*.by_tenant;
    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    var cursor: [*c]u8 = b.*.last;
    const end: [*c]u8 = b.*.end;
    formatMetrics(&cursor, end, &view);

    // Overflow guard: if cursor reached the buffer end, output was cut mid-line.
    // Return 503 so the scraper can detect and retry rather than parsing truncated text.
    if (@intFromPtr(cursor) >= @intFromPtr(end)) {
        r.*.headers_out.status = 503;
        r.*.headers_out.content_length_n = 0;
        return http.ngx_http_send_header(r);
    }

    b.*.last = cursor;

    b.*.flags.last_buf = r == r.*.main;
    b.*.flags.last_in_chain = true;

    const content_len: off_t = @intCast(@intFromPtr(b.*.last) - @intFromPtr(b.*.pos));
    r.*.headers_out.status = 200;
    r.*.headers_out.content_type = ngx_string("text/plain; version=0.0.4; charset=utf-8");
    r.*.headers_out.content_length_n = content_len;

    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK or r.*.flags1.header_only) return rc;

    const cl = buf.ngx_alloc_chain_link(r.*.pool) orelse return NGX_ERROR;
    cl.*.buf = b;
    cl.*.next = core.nullptr(buf.ngx_chain_t);

    return http.ngx_http_output_filter(r, cl);
}

// ── Directive handlers ────────────────────────────────────────────────────────

fn ngx_conf_set_llm_metrics(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(llm_metrics_loc_conf, loc)) |lccf| lccf.*.enabled = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_zone(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf = core.castPtr(llm_metrics_main_conf, main) orelse return conf.NGX_CONF_OK;
    if (mcf.*.zone_set != 0) {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_zone is duplicate", .{});
        return conf.NGX_CONF_ERROR;
    }

    var i: ngx_uint_t = 1;
    const name_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const size_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;

    mcf.*.zone_name = name_arg.*;
    const sz = core.slicify(u8, size_arg.*.data, size_arg.*.len);
    mcf.*.zone_size = parseZoneSize(sz) orelse {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_zone: invalid size (expected positive integer with optional k/m suffix)", .{});
        return conf.NGX_CONF_ERROR;
    };

    mcf.*.zone_set = 1;
    return conf.NGX_CONF_OK;
}

fn parseZoneSize(sz: []const u8) ?usize {
    if (sz.len == 0) return null;

    var base = sz;
    var mult: usize = 1;
    const suffix = sz[sz.len - 1];
    if (suffix == 'm' or suffix == 'M') {
        base = sz[0 .. sz.len - 1];
        mult = 1024 * 1024;
    } else if (suffix == 'k' or suffix == 'K') {
        base = sz[0 .. sz.len - 1];
        mult = 1024;
    }

    if (base.len == 0) return null;
    const n = std.fmt.parseInt(usize, base, 10) catch return null;
    if (n == 0) return null;
    return std.math.mul(usize, n, mult) catch return null;
}

fn ngx_conf_set_emit_usage(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.emit_usage = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.emit_usage = 0;
    } else {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_emit_usage: must be on or off", .{});
        return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_label_auth_status(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.label_auth_status = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.label_auth_status = 0;
    } else {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_label_auth_status: must be on or off", .{});
        return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_label_model(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.label_model = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.label_model = 0;
    } else {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_label_model: must be on or off", .{});
        return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 1: `llm_metrics_label_resolution_outcome on|off;`
// When on, the by_outcome counters in the store are updated in LOG phase and exported.
// Cardinality is fixed at OUTCOME_COUNT buckets — no unbounded label values.
fn ngx_conf_set_label_resolution_outcome(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.label_resolution_outcome = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.label_resolution_outcome = 0;
    } else {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_label_resolution_outcome: must be on or off", .{});
        return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 2: `llm_metrics_label_tenant on|off;`
fn ngx_conf_set_label_tenant(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.label_tenant = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.label_tenant = 0;
    } else {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_label_tenant: must be on or off", .{});
        return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 2: `llm_metrics_tenant_source $varname;`
// Accepts a variable name (with or without leading $) and stores its index for use in LOG phase.
fn ngx_conf_set_tenant_source(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    const idx = http.ngx_http_get_variable_index(cf, &n);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.tenant_var_idx = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_export(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_metrics_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "prometheus")) {
        lccf.*.export_mode = EXPORT_PROMETHEUS;
    } else {
        log.ngz_log_error(1, cf.*.log, 0, "llm_metrics_export: unknown mode (supported: prometheus)", .{});
        return conf.NGX_CONF_ERROR;
    }
    // Register the export content handler for this location.
    const clcf = core.castPtr(
        http.ngx_http_core_loc_conf_t,
        conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
    ) orelse return conf.NGX_CONF_ERROR;
    clcf.*.handler = export_handler;
    return conf.NGX_CONF_OK;
}

// ── Module lifecycle ──────────────────────────────────────────────────────────

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_metrics_main_conf, cf.*.pool) orelse return null;
    p.*.zone_size = DEFAULT_ZONE_SIZE;
    p.*.zone_set = 0;
    p.*.zone = core.nullptr(core.ngx_shm_zone_t);
    p.*.llm_auth_status_idx = -1;
    return p;
}

fn init_main_conf(cf: [*c]ngx_conf_t, mcf_ptr: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = mcf_ptr;
    return conf.NGX_CONF_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_metrics_loc_conf, cf.*.pool) orelse return null;
    p.*.enabled = conf.NGX_CONF_UNSET;
    p.*.emit_usage = EMIT_USAGE_UNSET;
    p.*.label_model = conf.NGX_CONF_UNSET;
    p.*.label_auth_status = conf.NGX_CONF_UNSET;
    p.*.export_mode = EXPORT_NONE;
    p.*.label_resolution_outcome = conf.NGX_CONF_UNSET;
    p.*.label_tenant = conf.NGX_CONF_UNSET;
    p.*.tenant_var_idx = -1;
    return p;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(llm_metrics_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(llm_metrics_loc_conf, child) orelse return conf.NGX_CONF_OK;
    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }
    if (c.*.emit_usage == EMIT_USAGE_UNSET) {
        c.*.emit_usage = if (prev.*.emit_usage == EMIT_USAGE_UNSET) 0 else prev.*.emit_usage;
    }
    if (c.*.label_model == conf.NGX_CONF_UNSET) {
        c.*.label_model = if (prev.*.label_model == conf.NGX_CONF_UNSET) 0 else prev.*.label_model;
    }
    if (c.*.label_auth_status == conf.NGX_CONF_UNSET) {
        c.*.label_auth_status = if (prev.*.label_auth_status == conf.NGX_CONF_UNSET) 0 else prev.*.label_auth_status;
    }
    if (c.*.export_mode == EXPORT_NONE and prev.*.export_mode != EXPORT_NONE) {
        c.*.export_mode = prev.*.export_mode;
    }
    if (c.*.label_resolution_outcome == conf.NGX_CONF_UNSET) {
        c.*.label_resolution_outcome = if (prev.*.label_resolution_outcome == conf.NGX_CONF_UNSET) 0 else prev.*.label_resolution_outcome;
    }
    if (c.*.label_tenant == conf.NGX_CONF_UNSET) {
        c.*.label_tenant = if (prev.*.label_tenant == conf.NGX_CONF_UNSET) 0 else prev.*.label_tenant;
    }
    if (c.*.tenant_var_idx < 0 and prev.*.tenant_var_idx >= 0) {
        c.*.tenant_var_idx = prev.*.tenant_var_idx;
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const mcf = core.castPtr(
        llm_metrics_main_conf,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_llm_metrics_module),
    ) orelse return NGX_ERROR;

    // Create shared-memory zone.  Use a default name if none configured.
    const zone_size = if (mcf.*.zone_size > 0) mcf.*.zone_size else DEFAULT_ZONE_SIZE;
    var zone_name = if (mcf.*.zone_name.len > 0) mcf.*.zone_name else ngx_string("llm_metrics");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, zone_size, @constCast(&ngx_http_llm_metrics_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = zone_init;
    mcf.*.zone = zone;

    // Pre-index the one variable not available via ngx_http_llm_proxy_observe().
    mcf.*.llm_auth_status_idx = getVarIndex(cf, "llm_auth_status");

    // Register LOG phase handler.
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var log_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[NGX_HTTP_LOG_PHASE].handlers);
    const lh = log_handlers.append() catch return NGX_ERROR;
    lh.* = log_handler;

    return NGX_OK;
}

// ── Module definition ─────────────────────────────────────────────────────────

export const ngx_http_llm_metrics_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = init_main_conf,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_metrics_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_metrics"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_metrics,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_metrics_zone"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_zone,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_metrics_emit_usage"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_emit_usage,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_metrics_label_model"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_label_model,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_metrics_label_auth_status"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_label_auth_status,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_metrics_export"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_export,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Milestone 2 Target 1: resolution outcome label dimension (bounded, opt-in).
    ngx_command_t{
        .name = ngx_string("llm_metrics_label_resolution_outcome"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_label_resolution_outcome,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Milestone 2 Target 2: per-tenant label dimension (bounded, opt-in).
    ngx_command_t{
        .name = ngx_string("llm_metrics_label_tenant"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_label_tenant,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_metrics_tenant_source"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_tenant_source,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

// off_t is used for content_length_n
const off_t = core.off_t;

export var ngx_http_llm_metrics_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_metrics_commands),
    @constCast(&ngx_http_llm_metrics_module_ctx),
);

test "aggregateWorkers sums per-worker counters" {
    var store = std.mem.zeroes(LlmMetricsStore);
    store.initialized = 1;
    store.store_size = @sizeOf(LlmMetricsStore);

    store.workers[0].by_provider[PROV_OPENAI].requests_total = 2;
    store.workers[1].by_provider[PROV_OPENAI].requests_total = 3;
    store.workers[0].by_outcome[OUTCOME_AS_REQUESTED].requests_total = 4;
    store.workers[1].by_outcome[OUTCOME_AS_REQUESTED].requests_total = 5;
    store.workers[2].by_auth_status[AUTH_RESOLVED].requests_total = 7;
    store.workers[3].by_auth_status[AUTH_RESOLVED].requests_error_gateway = 1;

    const view = aggregateWorkers(&store);
    try std.testing.expectEqual(@as(u64, 5), view.by_provider[PROV_OPENAI].requests_total);
    try std.testing.expectEqual(@as(u64, 9), view.by_outcome[OUTCOME_AS_REQUESTED].requests_total);
    try std.testing.expectEqual(@as(u64, 7), view.by_auth_status[AUTH_RESOLVED].requests_total);
    try std.testing.expectEqual(@as(u64, 1), view.by_auth_status[AUTH_RESOLVED].requests_error_gateway);
}

test "workerSlotForId wraps instead of collapsing onto the last slot" {
    try std.testing.expectEqual(@as(usize, 0), workerSlotForId(0));
    try std.testing.expectEqual(@as(usize, MAX_WORKERS - 1), workerSlotForId(MAX_WORKERS - 1));
    try std.testing.expectEqual(@as(usize, 0), workerSlotForId(MAX_WORKERS));
    try std.testing.expectEqual(@as(usize, 1), workerSlotForId(MAX_WORKERS + 1));
}

test "parseZoneSize rejects overflow" {
    try std.testing.expectEqual(@as(?usize, null), parseZoneSize("999999999999999999999999999999999999999999999999999999m"));
    try std.testing.expectEqual(@as(?usize, null), parseZoneSize("999999999999999999999999999999999999999999999999999999k"));
}
