const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const log = ngx.log;
const shm = ngx.shm;

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

extern var ngx_http_core_module: ngx_module_t;

// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const LlmProxyObservable = contract.LlmProxyObservable;

extern fn ngx_http_llm_proxy_observe(r: [*c]ngx_http_request_t) LlmProxyObservable;
extern fn ngx_http_llm_proxy_effective_provider(r: [*c]ngx_http_request_t) ngx_str_t;
extern fn ngx_http_llm_proxy_resolution_outcome(r: [*c]ngx_http_request_t) ngx_uint_t;
extern fn ngx_http_llm_proxy_total_tokens(r: [*c]ngx_http_request_t) ngx_uint_t;

// M2 Target 7/5: cross-module observable from llm-cost for spend budget path.
// Must match the LlmCostObservable extern struct in ngx_http_llm_cost.zig.
// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
const LlmCostObservable = contract.LlmCostObservable;
extern fn ngx_http_llm_cost_observe(r: [*c]ngx_http_request_t) LlmCostObservable;
extern fn ngx_http_llm_cost_unit_for_provider(r: [*c]ngx_http_request_t, provider: ngx_str_t) ngx_str_t;

// ── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_ZONE_SIZE: usize = 1 * 1024 * 1024;
const MAX_ENTRIES: usize = 4096;
const STRIPE_COUNT: usize = 64;
const ENTRIES_PER_STRIPE: usize = MAX_ENTRIES / STRIPE_COUNT;
const DEFAULT_RESERVE_TOKENS: ngx_uint_t = 1000;
const MAX_OVERRIDES: usize = 4;
const NGX_HTTP_TOO_MANY_REQUESTS: ngx_int_t = 429;
const NGX_HTTP_LOG_PHASE: usize = 10; // not exported by bindings
const CACHE_LINE_SIZE: usize = 64;

// M2 Target 5: monthly spend budget constants.
const SPEND_SCOPE_ORG: ngx_uint_t = 0;
const SPEND_SCOPE_PROJECT: ngx_uint_t = 1;
const SPEND_SCOPE_CLIENT: ngx_uint_t = 2;
const MAX_SPEND_SCOPES: usize = 6; // up to 2 units × 3 scopes per location
const MAX_SPEND_ENTRIES: usize = 2048;
const SPEND_STRIPE_COUNT: usize = 64;
const SPEND_ENTRIES_PER_STRIPE: usize = MAX_SPEND_ENTRIES / SPEND_STRIPE_COUNT; // 32

// M2 Target 3: model/provider basis for tier override resolution.
const MODEL_BASIS_EFFECTIVE: ngx_uint_t = 0; // default: use $llm_effective_model
const MODEL_BASIS_REQUESTED: ngx_uint_t = 1; // use $llm_requested_model

// M2 Target 5: one configured spend budget entry stored in loc_conf.
// id_var_indices: [org_idx, project_idx, client_idx] — -1 when not used for this scope.
const SpendScopeEntry = extern struct {
    scope: ngx_uint_t,
    budget_micros: u64,
    unit: ngx_str_t,
    id_var_indices: [3]ngx_int_t,
};

// M2 Target 2: resolution outcomes from llm-proxy (must match llm-proxy constants).
const RESOLUTION_OUTCOME_REJECTED_OUT_OF_SCOPE: ngx_uint_t = 3;
const RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE: ngx_uint_t = 4;

// ── Tier override (Phase 4) ───────────────────────────────────────────────────

const RateTierOverride = extern struct {
    pattern: ngx_str_t, // model prefix or exact provider name
    requests_per_minute: ngx_uint_t, // 0 = not set
    tokens_per_minute: ngx_uint_t, // 0 = not set
};

// ── Config structs ────────────────────────────────────────────────────────────

const llm_ratelimit_main_conf = extern struct {
    zone_name: ngx_str_t,
    zone_size: usize,
    zone_set: ngx_flag_t,
    // Zone descriptors are owned by this nginx configuration cycle.
    rate_zone: [*c]core.ngx_shm_zone_t,
    spend_zone: [*c]core.ngx_shm_zone_t,
    // Pre-indexed llm-proxy variable indices (set in postconfiguration).
    // -1 when the variable is not registered (llm-proxy not in binary or not configured).
    llm_total_tokens_idx: ngx_int_t, // Phase 3: $llm_total_tokens
    llm_model_idx: ngx_int_t, // Phase 4: $llm_model (requested model, backward compat)
    llm_provider_idx: ngx_int_t, // Phase 4: $llm_provider
    llm_reset_after_ms_idx: ngx_int_t, // Phase 4: $llm_reset_after_ms
    // M2 Target 2: translation detection and rejection-before-send reconciliation.
    llm_requested_dialect_idx: ngx_int_t, // $llm_requested_dialect (ACCESS phase)
    llm_effective_dialect_idx: ngx_int_t, // $llm_effective_dialect (ACCESS phase)
    llm_translation_happened_idx: ngx_int_t, // $llm_translation_happened (LOG phase)
    llm_resolution_outcome_idx: ngx_int_t, // $llm_resolution_outcome (LOG phase)
    // M2 Target 3: requested vs effective model/provider for tier overrides.
    llm_requested_model_idx: ngx_int_t, // $llm_requested_model
    llm_requested_provider_idx: ngx_int_t, // $llm_requested_provider
    llm_effective_model_idx: ngx_int_t, // $llm_effective_model
    llm_effective_provider_idx: ngx_int_t, // $llm_effective_provider
    // M2 Target 5: set to 1 by first llm_ratelimit_spend_scope directive.
    spend_enabled: ngx_flag_t,
};

const llm_ratelimit_loc_conf = extern struct {
    enabled: ngx_flag_t,
    requests_per_minute: ngx_uint_t,
    rpm_set: ngx_flag_t,
    burst_requests: ngx_uint_t,
    burst_set: ngx_flag_t,
    tokens_per_minute: ngx_uint_t, // Phase 3
    tpm_set: ngx_flag_t,
    reserve_tokens: ngx_uint_t, // Phase 3: pre-flight reservation per request
    reserve_set: ngx_flag_t,
    key_var: ngx_str_t,
    key_var_index: ngx_int_t,
    fail_open: ngx_flag_t,
    dry_run: ngx_flag_t,
    // Phase 4: per-model and per-provider tier overrides
    model_overrides: [MAX_OVERRIDES]RateTierOverride,
    model_overrides_count: ngx_uint_t,
    provider_overrides: [MAX_OVERRIDES]RateTierOverride,
    provider_overrides_count: ngx_uint_t,
    cooldown_enabled: ngx_flag_t, // Phase 4: apply provider-feedback cooldown
    // M2 Target 2: translated-traffic quota limits.
    translated_rpm: ngx_uint_t, // 0 = not set
    translated_tpm: ngx_uint_t, // 0 = not set
    translated_rpm_set: ngx_flag_t,
    translated_tpm_set: ngx_flag_t,
    // M2 Target 3: which variable to use for model/provider tier resolution.
    model_basis: ngx_uint_t, // MODEL_BASIS_EFFECTIVE (0) | MODEL_BASIS_REQUESTED (1)
    provider_basis: ngx_uint_t,
    // M2 Target 5: spend budget scope entries for this location.
    spend_scopes: [MAX_SPEND_SCOPES]SpendScopeEntry,
    spend_count: ngx_uint_t,
    spend_reserve_unit: ngx_str_t,
    spend_reserve_micros: u64,
    spend_reserve_set: ngx_flag_t,
};

// ── Shared memory ─────────────────────────────────────────────────────────────

// Per-caller ledger entry padded to exactly one 64-byte cache line.
// Padding eliminates false sharing between adjacent entries in the hot scan
// path when multiple workers release their locks and invalidate each other's
// L1/L2 cache lines.
const LlmRateLimitEntry = extern struct {
    key_hash: u64,
    req_count: u64,
    token_count: u64, // includes pre-flight reservations, reconciled in LOG phase
    window_minute: i64, // unix epoch / 60 — same window for req and token counts
    last_used: i64,
    cooldown_until_ms: u64, // Phase 4: wall-clock ms when cooldown expires (0 = none)
    _pad: [16]u8, // pad to 64 bytes — one cache line
};

comptime {
    std.debug.assert(@sizeOf(LlmRateLimitEntry) == 64);
}

const StripeStore = extern struct {
    entry_count: ngx_uint_t,
    _header_pad: [56]u8, // keep entry_count on its own cache line
    entries: [ENTRIES_PER_STRIPE]LlmRateLimitEntry,
};

comptime {
    std.debug.assert(@offsetOf(StripeStore, "entries") == CACHE_LINE_SIZE);
    std.debug.assert(@sizeOf(StripeStore) == CACHE_LINE_SIZE + ENTRIES_PER_STRIPE * CACHE_LINE_SIZE);
}

// The store header lives on its own 64-byte cache line. The surrounding slab
// pool's nginx-managed mutex protects the striped entry arrays.
const llm_ratelimit_store = extern struct {
    initialized: ngx_flag_t,
    store_size: usize, // sentinel: must match @sizeOf(llm_ratelimit_store) on hot-reload
    _header_pad: [48]u8,
    stripes: [STRIPE_COUNT]StripeStore,
};

comptime {
    std.debug.assert(@offsetOf(llm_ratelimit_store, "stripes") == CACHE_LINE_SIZE);
}

// M2 Target 5: per-scope monthly spend counter entry — one cache line.
const SpendEntry = extern struct {
    key_hash: u64,
    spend_micros: u64, // actual spend plus opt-in in-flight reservations
    year_month: u32, // YYYYMM encoding; entry is stale when this differs from current month
    last_used: i64,
    _pad: [32]u8,
};

comptime {
    std.debug.assert(@sizeOf(SpendEntry) == CACHE_LINE_SIZE);
}

const SpendStripeStore = extern struct {
    entry_count: ngx_uint_t,
    _header_pad: [56]u8,
    entries: [SPEND_ENTRIES_PER_STRIPE]SpendEntry,
};

comptime {
    std.debug.assert(@offsetOf(SpendStripeStore, "entries") == CACHE_LINE_SIZE);
}

const llm_spend_store = extern struct {
    initialized: ngx_flag_t,
    store_size: usize,
    _header_pad: [48]u8,
    stripes: [SPEND_STRIPE_COUNT]SpendStripeStore,
};

comptime {
    std.debug.assert(@offsetOf(llm_spend_store, "stripes") == CACHE_LINE_SIZE);
}

// ── Per-request context ───────────────────────────────────────────────────────

const deny_reason_none = ngx_str_t{ .len = 0, .data = @constCast("") };
const deny_reason_budget = ngx_string("request_budget_exhausted");
const deny_reason_tokens = ngx_string("token_budget_exhausted");
const deny_reason_identity = ngx_string("identity_missing");
const deny_reason_config = ngx_string("config_invalid");
const deny_reason_cooldown = ngx_string("provider_cooldown"); // Phase 4
const deny_reason_spend = ngx_string("spend_budget_exhausted"); // M2 Target 5

const SpendRequestScopeCache = extern struct {
    ids: [3]ngx_str_t,
    valid: ngx_flag_t, // 0=empty, 1=ids cached, 2=ids cached + spend reserved
};

const LlmRatelimitCtx = extern struct {
    deny_reason: ngx_str_t,
    remaining_requests: ngx_uint_t,
    remaining_tokens: ngx_uint_t, // Phase 3
    token_reservation: ngx_uint_t, // Phase 3: tokens reserved in ACCESS, for LOG reconciliation
    key_hash: u64, // Phase 3: stored for LOG reconciliation lookup
    dry_run: ngx_flag_t,
    translated: ngx_flag_t, // M2 Target 2: 1 if translation detected in ACCESS phase
    // M2 Target 5: spend budget state
    spend_deny_unit: ngx_str_t, // unit whose budget is exhausted; zero-len when not denied
    spend_incremented: ngx_flag_t, // LOG phase guard: 1 after spend counters incremented
    spend_scope_cache: [MAX_SPEND_SCOPES]SpendRequestScopeCache,
};

// ── Utility functions ─────────────────────────────────────────────────────────

fn hashBytes(bytes: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (bytes) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return if (h == 0) 1 else h;
}

fn getCurrentMinute() i64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| return @divTrunc(@as(i64, @intCast(t.*.sec)), 60);
    return 0;
}

fn getCurrentMs() u64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| return @as(u64, @intCast(t.*.sec)) * 1000 + @as(u64, t.*.msec);
    return 0;
}

fn getStoreAndPool(mcf: [*c]llm_ratelimit_main_conf) struct { shpool: [*c]core.ngx_slab_pool_t, store: [*c]llm_ratelimit_store } {
    const zone = mcf.*.rate_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(llm_ratelimit_store) };
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(llm_ratelimit_store) };
    const store = core.castPtr(llm_ratelimit_store, zone.*.data) orelse return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(llm_ratelimit_store) };
    return .{ .shpool = shpool, .store = store };
}

fn zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        const prev = core.castPtr(llm_ratelimit_store, data) orelse return NGX_ERROR;
        if (prev.*.initialized == 1 and prev.*.store_size == @sizeOf(llm_ratelimit_store)) {
            zone.*.data = data;
            return NGX_OK;
        }
        return NGX_ERROR; // store layout changed — full restart required
    }
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        const prev = core.castPtr(llm_ratelimit_store, shpool.*.data) orelse return NGX_ERROR;
        if (prev.*.initialized == 1 and prev.*.store_size == @sizeOf(llm_ratelimit_store)) {
            zone.*.data = shpool.*.data;
            return NGX_OK;
        }
        return NGX_ERROR;
    }
    const mem = shm.ngx_slab_calloc(shpool, @sizeOf(llm_ratelimit_store)) orelse return NGX_ERROR;
    const store = core.castPtr(llm_ratelimit_store, mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(llm_ratelimit_store);
    store.*.initialized = 1;
    store.*.store_size = @sizeOf(llm_ratelimit_store);
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn spend_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        const prev = core.castPtr(llm_spend_store, data) orelse return NGX_ERROR;
        if (prev.*.initialized == 1 and prev.*.store_size == @sizeOf(llm_spend_store)) {
            zone.*.data = data;
            return NGX_OK;
        }
        return NGX_ERROR;
    }
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        const prev = core.castPtr(llm_spend_store, shpool.*.data) orelse return NGX_ERROR;
        if (prev.*.initialized == 1 and prev.*.store_size == @sizeOf(llm_spend_store)) {
            zone.*.data = shpool.*.data;
            return NGX_OK;
        }
        return NGX_ERROR;
    }
    const mem = shm.ngx_slab_calloc(shpool, @sizeOf(llm_spend_store)) orelse return NGX_ERROR;
    const store = core.castPtr(llm_spend_store, mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(llm_spend_store);
    store.*.initialized = 1;
    store.*.store_size = @sizeOf(llm_spend_store);
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn getSpendStoreAndPool(mcf: [*c]llm_ratelimit_main_conf) struct { shpool: [*c]core.ngx_slab_pool_t, store: [*c]llm_spend_store } {
    const zone = mcf.*.spend_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(llm_spend_store) };
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(llm_spend_store) };
    const store = core.castPtr(llm_spend_store, zone.*.data) orelse return .{ .shpool = core.nullptr(core.ngx_slab_pool_t), .store = core.nullptr(llm_spend_store) };
    return .{ .shpool = shpool, .store = store };
}

fn spendStripeForHash(store: *llm_spend_store, key_hash: u64) *SpendStripeStore {
    return &store.stripes[spendStripeIndexForHash(key_hash)];
}

// ── Spend helper functions ────────────────────────────────────────────────────

fn keyAppend(kbuf: []u8, pos: *usize, data: []const u8) bool {
    if (pos.* + data.len > kbuf.len) return false;
    @memcpy(kbuf[pos.*..][0..data.len], data);
    pos.* += data.len;
    return true;
}

fn buildSpendKey(
    kbuf: []u8,
    scope: ngx_uint_t,
    unit: ngx_str_t,
    org_id: ?ngx_str_t,
    project_id: ?ngx_str_t,
    client_id: ?ngx_str_t,
    ym: u32,
) ?[]u8 {
    var pos: usize = 0;
    const scope_prefix: []const u8 = switch (scope) {
        SPEND_SCOPE_ORG => "spend:org:",
        SPEND_SCOPE_PROJECT => "spend:project:",
        SPEND_SCOPE_CLIENT => "spend:client:",
        else => return null,
    };
    if (!keyAppend(kbuf, &pos, scope_prefix)) return null;
    // org_id is required for all scopes
    const oid = org_id orelse return null;
    if (!keyAppend(kbuf, &pos, core.slicify(u8, oid.data, oid.len))) return null;
    if (scope >= SPEND_SCOPE_PROJECT) {
        if (!keyAppend(kbuf, &pos, ":")) return null;
        const pid = project_id orelse return null;
        if (!keyAppend(kbuf, &pos, core.slicify(u8, pid.data, pid.len))) return null;
    }
    if (scope >= SPEND_SCOPE_CLIENT) {
        if (!keyAppend(kbuf, &pos, ":")) return null;
        const cid = client_id orelse return null;
        if (!keyAppend(kbuf, &pos, core.slicify(u8, cid.data, cid.len))) return null;
    }
    if (!keyAppend(kbuf, &pos, ":")) return null;
    if (!keyAppend(kbuf, &pos, core.slicify(u8, unit.data, unit.len))) return null;
    if (!keyAppend(kbuf, &pos, ":")) return null;
    var ym_buf: [7]u8 = undefined;
    const ym_str = std.fmt.bufPrint(&ym_buf, "{d}", .{ym}) catch return null;
    if (!keyAppend(kbuf, &pos, ym_str)) return null;
    return kbuf[0..pos];
}

// Howard Hinnant algorithm: Unix epoch seconds → YYYYMM as u32.
fn epochSecsToYearMonth(sec: i64) u32 {
    const days: i64 = @divFloor(sec, 86400);
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;
    return @intCast(@as(i64, @intCast(year)) * 100 + @as(i64, @intCast(m)));
}

// Derive current local calendar YYYYMM from nginx's cached time (gmtoff in minutes).
fn getLocalYearMonth() u32 {
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        const local_sec: i64 = @as(i64, @intCast(t.*.sec)) + @as(i64, t.*.gmtoff) * 60;
        return epochSecsToYearMonth(local_sec);
    }
    return 0;
}

fn spendStripeIndexForHash(key_hash: u64) usize {
    return @intCast(key_hash & (SPEND_STRIPE_COUNT - 1));
}

// Find an existing entry for key_hash in the current month; null if stale or missing.
fn findSpendEntry(store: *llm_spend_store, key_hash: u64, ym: u32, now_min: i64) ?*SpendEntry {
    const stripe_idx = spendStripeIndexForHash(key_hash);
    const stripe: *SpendStripeStore = &store.stripes[stripe_idx];
    const count: usize = @intCast(@atomicLoad(ngx_uint_t, &stripe.entry_count, .acquire));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e: *SpendEntry = &stripe.entries[i];
        if (@atomicLoad(u64, &e.key_hash, .acquire) == key_hash) {
            if (e.year_month != ym) return null; // stale month — treat as zero
            e.last_used = now_min;
            return e;
        }
    }
    return null;
}

// Get or create a spend entry; resets stale entries on month rollover.
fn getOrCreateSpendEntry(store: *llm_spend_store, key_hash: u64, ym: u32, now_min: i64) *SpendEntry {
    const stripe_idx = spendStripeIndexForHash(key_hash);
    const stripe: *SpendStripeStore = &store.stripes[stripe_idx];
    const count: usize = @intCast(@atomicLoad(ngx_uint_t, &stripe.entry_count, .acquire));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e: *SpendEntry = &stripe.entries[i];
        if (@atomicLoad(u64, &e.key_hash, .acquire) == key_hash) {
            if (e.year_month != ym) {
                e.spend_micros = 0;
                e.year_month = ym;
            }
            e.last_used = now_min;
            return e;
        }
    }
    if (count < SPEND_ENTRIES_PER_STRIPE) {
        const e: *SpendEntry = &stripe.entries[count];
        // Publish the active-prefix length last. If a worker dies during
        // initialization, the next owner cannot observe a partial entry.
        e.* = .{ .key_hash = 0, .spend_micros = 0, .year_month = ym, .last_used = now_min, ._pad = [1]u8{0} ** 32 };
        @atomicStore(u64, &e.key_hash, key_hash, .release);
        @atomicStore(ngx_uint_t, &stripe.entry_count, @intCast(count + 1), .release);
        return e;
    }
    // Evict a stale entry first; otherwise evict the least recently used current entry.
    var victim: usize = 0;
    var oldest_time: i64 = std.math.maxInt(i64);
    i = 0;
    while (i < SPEND_ENTRIES_PER_STRIPE) : (i += 1) {
        if (stripe.entries[i].year_month != ym) {
            victim = i;
            break;
        }
        if (stripe.entries[i].last_used < oldest_time) {
            oldest_time = stripe.entries[i].last_used;
            victim = i;
        }
    }
    const e: *SpendEntry = &stripe.entries[victim];
    // Invalidate before replacement and publish the new key last. A forced
    // unlock after worker death therefore exposes either the old entry, no
    // entry, or the fully initialized replacement—never a partial match.
    @atomicStore(u64, &e.key_hash, 0, .release);
    e.spend_micros = 0;
    e.year_month = ym;
    e.last_used = now_min;
    @atomicStore(u64, &e.key_hash, key_hash, .release);
    return e;
}

fn resolveEffectiveProvider(r: [*c]ngx_http_request_t) ?ngx_str_t {
    const provider = ngx_http_llm_proxy_effective_provider(r);
    if (provider.len > 0) return provider;
    return null;
}

fn resolveEffectiveCostUnit(r: [*c]ngx_http_request_t) ?ngx_str_t {
    const provider = resolveEffectiveProvider(r) orelse return null;
    const unit = ngx_http_llm_cost_unit_for_provider(r, provider);
    if (unit.len == 0) return null;
    return unit;
}

fn releaseSpendReservations(
    mcf: [*c]llm_ratelimit_main_conf,
    lccf: *llm_ratelimit_loc_conf,
    cache: *[MAX_SPEND_SCOPES]SpendRequestScopeCache,
) void {
    if (lccf.spend_reserve_micros == 0) return;
    const sp = getSpendStoreAndPool(mcf);
    const shpool = sp.shpool orelse return;
    const spend_store = sp.store orelse return;
    const ym = getLocalYearMonth();
    if (ym == 0) return;
    const now_min = @divTrunc(@as(i64, @intCast(getCurrentMs() / 1000)), 60);
    var key_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < lccf.spend_count) : (i += 1) {
        if (cache[i].valid != 2) continue;
        const entry = &lccf.spend_scopes[i];
        const ids = cache[i].ids;
        const key = buildSpendKey(&key_buf, entry.scope, entry.unit, if (ids[0].len > 0) ids[0] else null, if (ids[1].len > 0) ids[1] else null, if (ids[2].len > 0) ids[2] else null, ym) orelse continue;
        const key_hash = hashBytes(key);
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        if (findSpendEntry(spend_store, key_hash, ym, now_min)) |spend_entry| {
            spend_entry.spend_micros -|= lccf.spend_reserve_micros;
        }
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        cache[i].valid = 1;
    }
}

// ACCESS phase: check configured spend budgets for the request's effective cost unit.
// Returns the exhausted cost unit or null.
fn checkSpendBudgets(mcf: [*c]llm_ratelimit_main_conf, r: [*c]ngx_http_request_t, lccf: *llm_ratelimit_loc_conf, cache: ?*[MAX_SPEND_SCOPES]SpendRequestScopeCache) ?ngx_str_t {
    const spend_count = lccf.spend_count;
    if (spend_count == 0) return null;
    const effective_unit = resolveEffectiveCostUnit(r) orelse return null;
    const sp = getSpendStoreAndPool(mcf);
    const shpool = sp.shpool orelse return null;
    const spend_store = sp.store orelse return null;
    const ym = getLocalYearMonth();
    if (ym == 0) return null;
    const now_min = @divTrunc(@as(i64, @intCast(getCurrentMs() / 1000)), 60);
    var exhausted_unit: ?ngx_str_t = null;
    var key_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < spend_count) : (i += 1) {
        const entry: *SpendScopeEntry = &lccf.spend_scopes[i];
        if (!strEql(entry.unit, effective_unit)) continue;
        const org_id: ?ngx_str_t = if (entry.id_var_indices[0] >= 0)
            resolveStrVar(r, entry.id_var_indices[0])
        else
            null;
        const project_id: ?ngx_str_t = if (entry.id_var_indices[1] >= 0)
            resolveStrVar(r, entry.id_var_indices[1])
        else
            null;
        const client_id: ?ngx_str_t = if (entry.id_var_indices[2] >= 0)
            resolveStrVar(r, entry.id_var_indices[2])
        else
            null;
        if (cache) |c| cacheSpendScopeIds(c, i, org_id, project_id, client_id);
        const key = buildSpendKey(&key_buf, entry.scope, entry.unit, org_id, project_id, client_id, ym) orelse continue;
        const key_hash = hashBytes(key);
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        const hard_reserve = lccf.dry_run != 1 and
            lccf.spend_reserve_micros > 0 and
            strEql(entry.unit, lccf.spend_reserve_unit);
        const current = if (hard_reserve)
            getOrCreateSpendEntry(spend_store, key_hash, ym, now_min)
        else
            findSpendEntry(spend_store, key_hash, ym, now_min);
        const committed = if (current) |e| e.spend_micros else 0;
        const exhausted = committed >= entry.budget_micros or
            (hard_reserve and lccf.spend_reserve_micros > entry.budget_micros -| committed);
        if (!exhausted and hard_reserve) {
            current.?.spend_micros +|= lccf.spend_reserve_micros;
            if (cache) |c| c[i].valid = 2;
        }
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        if (exhausted and exhausted_unit == null) {
            exhausted_unit = entry.unit;
            if (cache) |c| releaseSpendReservations(mcf, lccf, c);
            break;
        }
    }
    return exhausted_unit;
}

// LOG phase: increment spend counters for each scope matching the effective cost unit.
fn reconcileSpendCounters(
    mcf: [*c]llm_ratelimit_main_conf,
    r: [*c]ngx_http_request_t,
    lccf: *llm_ratelimit_loc_conf,
    ctx: ?*LlmRatelimitCtx,
    cost_unit: ngx_str_t,
    cost_micros: u64,
    cost_eligible: bool,
    release_only: bool,
) void {
    const spend_count = lccf.spend_count;
    if (spend_count == 0) return;
    const sp = getSpendStoreAndPool(mcf);
    const shpool = sp.shpool orelse return;
    const spend_store = sp.store orelse return;
    const ym = getLocalYearMonth();
    if (ym == 0) return;
    const now_min = @divTrunc(@as(i64, @intCast(getCurrentMs() / 1000)), 60);
    var key_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < spend_count) : (i += 1) {
        const entry: *SpendScopeEntry = &lccf.spend_scopes[i];
        const cached_reservation = if (ctx) |c| c.spend_scope_cache[i].valid == 2 else false;
        const add_actual = cost_eligible and strEql(entry.unit, cost_unit);
        const release_reservation = cached_reservation and (cost_eligible or release_only);
        if (!add_actual and !release_reservation) continue;
        const org_id = resolveSpendScopeId(r, entry, ctx, i, 0);
        const project_id = resolveSpendScopeId(r, entry, ctx, i, 1);
        const client_id = resolveSpendScopeId(r, entry, ctx, i, 2);
        const key = buildSpendKey(&key_buf, entry.scope, entry.unit, org_id, project_id, client_id, ym) orelse continue;
        const key_hash = hashBytes(key);
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        const spend_entry = getOrCreateSpendEntry(spend_store, key_hash, ym, now_min);
        if (release_reservation) spend_entry.spend_micros -|= lccf.spend_reserve_micros;
        if (add_actual) spend_entry.spend_micros +|= cost_micros;
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
    }
}

// ── Ledger operations ─────────────────────────────────────────────────────────

fn stripeIndexForHash(key_hash: u64) usize {
    return @intCast(key_hash & (STRIPE_COUNT - 1));
}

fn stripeForHash(store: *llm_ratelimit_store, key_hash: u64) *StripeStore {
    return &store.stripes[stripeIndexForHash(key_hash)];
}

fn getOrCreateEntry(store: *llm_ratelimit_store, key_hash: u64, now_min: i64) *LlmRateLimitEntry {
    const stripe = stripeForHash(store, key_hash);

    // Fast path: scan only the populated prefix of the entry array.
    // entry_count tracks the highest index ever assigned and is monotonically
    // non-decreasing.  On the common path (< MAX_ENTRIES unique keys ever
    // seen) this avoids touching empty cache lines past the active region.
    const count: usize = @intCast(@atomicLoad(ngx_uint_t, &stripe.entry_count, .acquire));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = &stripe.entries[i];
        if (@atomicLoad(u64, &e.key_hash, .acquire) == key_hash) return e;
    }

    // Not found in the active prefix — either create a new entry or evict.
    if (count < ENTRIES_PER_STRIPE) {
        const e = &stripe.entries[count];
        e.* = .{
            .key_hash = 0,
            .req_count = 0,
            .token_count = 0,
            .window_minute = now_min,
            .last_used = now_min,
            .cooldown_until_ms = 0,
            ._pad = [1]u8{0} ** 16,
        };
        @atomicStore(u64, &e.key_hash, key_hash, .release);
        @atomicStore(ngx_uint_t, &stripe.entry_count, @intCast(count + 1), .release);
        return e;
    }

    // Eviction path: this stripe is full — find the LRU entry within the stripe.
    var oldest_idx: usize = 0;
    var oldest_time: i64 = std.math.maxInt(i64);
    i = 0;
    while (i < ENTRIES_PER_STRIPE) : (i += 1) {
        if (stripe.entries[i].last_used < oldest_time) {
            oldest_time = stripe.entries[i].last_used;
            oldest_idx = i;
        }
    }
    const e = &stripe.entries[oldest_idx];
    @atomicStore(u64, &e.key_hash, 0, .release);
    e.req_count = 0;
    e.token_count = 0;
    e.window_minute = now_min;
    e.last_used = now_min;
    e.cooldown_until_ms = 0;
    @atomicStore(u64, &e.key_hash, key_hash, .release);
    return e;
}

const QuotaResult = struct {
    allowed: bool,
    deny_reason: ngx_str_t,
    remaining_req: ngx_uint_t,
    remaining_tok: ngx_uint_t,
    token_reservation: ngx_uint_t,
};

fn checkAndConsume(
    store: *llm_ratelimit_store,
    key_hash: u64,
    rpm: ngx_uint_t,
    burst_req: ngx_uint_t,
    tpm: ngx_uint_t,
    reserve: ngx_uint_t,
    now_ms: u64,
) QuotaResult {
    const now_min = @divTrunc(@as(i64, @intCast(now_ms / 1000)), 60);
    const entry = getOrCreateEntry(store, key_hash, now_min);

    // Phase 4: check cooldown first
    if (entry.cooldown_until_ms > 0 and now_ms < entry.cooldown_until_ms) {
        return .{
            .allowed = false,
            .deny_reason = deny_reason_cooldown,
            .remaining_req = 0,
            .remaining_tok = 0,
            .token_reservation = 0,
        };
    }

    // Reset window if expired
    if (now_min > entry.window_minute) {
        // Publish the new window after its counters are reset. A worker killed
        // mid-reset leaves the old window visible, so the replacement worker
        // safely repeats the reset instead of consuming stale counters.
        entry.req_count = 0;
        entry.token_count = 0;
        @atomicStore(i64, &entry.window_minute, now_min, .release);
    }
    entry.last_used = now_min;

    const req_limit: u64 = @as(u64, rpm) + @as(u64, burst_req);

    // Request budget check
    if (entry.req_count >= req_limit) {
        return .{
            .allowed = false,
            .deny_reason = deny_reason_budget,
            .remaining_req = 0,
            .remaining_tok = remainingTokens(entry, tpm),
            .token_reservation = 0,
        };
    }

    // Token budget check (Phase 3)
    if (tpm > 0 and entry.token_count +| reserve > tpm) {
        return .{
            .allowed = false,
            .deny_reason = deny_reason_tokens,
            .remaining_req = @intCast(req_limit - entry.req_count),
            .remaining_tok = 0,
            .token_reservation = 0,
        };
    }

    // Allow: consume request slot and reserve tokens
    var tok_reserved: ngx_uint_t = 0;
    if (tpm > 0 and reserve > 0) {
        const can_reserve = if (entry.token_count + reserve > tpm) tpm - entry.token_count else reserve;
        entry.token_count += can_reserve;
        tok_reserved = @intCast(can_reserve);
    }
    // Publish request admission last. A killed worker may leave a conservative
    // token reservation, but can never publish an admitted request without its
    // associated token commitment.
    entry.req_count += 1;

    return .{
        .allowed = true,
        .deny_reason = deny_reason_none,
        .remaining_req = @intCast(req_limit - entry.req_count),
        .remaining_tok = remainingTokens(entry, tpm),
        .token_reservation = tok_reserved,
    };
}

fn remainingTokens(entry: *LlmRateLimitEntry, tpm: ngx_uint_t) ngx_uint_t {
    if (tpm == 0) return 0;
    if (entry.token_count >= tpm) return 0;
    return @intCast(tpm - entry.token_count);
}

// LOG phase: reconcile token reservation with actual usage from llm-proxy.
// actual=0 means usage was not available; keep reservation as-is (documented fallback).
// Helper: scan the active prefix of entries for the given key_hash.
// Returns the entry or null if not found (should only happen after eviction).
fn findEntry(store: *llm_ratelimit_store, key_hash: u64) ?*LlmRateLimitEntry {
    const stripe = stripeForHash(store, key_hash);
    const count: usize = @intCast(@atomicLoad(ngx_uint_t, &stripe.entry_count, .acquire));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (@atomicLoad(u64, &stripe.entries[i].key_hash, .acquire) == key_hash) return &stripe.entries[i];
    }
    return null;
}

fn reconcileTokens(store: *llm_ratelimit_store, key_hash: u64, reservation: ngx_uint_t, actual: ngx_uint_t) void {
    if (reservation == actual) return;
    const e = findEntry(store, key_hash) orelse return;
    if (actual > reservation) {
        e.token_count +|= actual - reservation;
    } else {
        e.token_count -|= reservation - actual;
    }
}

// LOG phase: set provider-feedback cooldown (Phase 4).
fn setCooldown(store: *llm_ratelimit_store, key_hash: u64, cooldown_ms: u64) void {
    const e = findEntry(store, key_hash) orelse return;
    if (cooldown_ms > e.cooldown_until_ms) e.cooldown_until_ms = cooldown_ms;
}

// M2 Target 2: LOG phase — return a request slot when the request was rejected
// before reaching the upstream (REJECTED_OUT_OF_SCOPE or REJECTED_UNRESOLVABLE).
// This prevents gateway routing failures from silently burning caller quota.
fn returnRequestSlot(store: *llm_ratelimit_store, key_hash: u64) void {
    const e = findEntry(store, key_hash) orelse return;
    if (e.req_count > 0) e.req_count -= 1;
}

// ── Variable getters ──────────────────────────────────────────────────────────

fn get_deny_reason(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(LlmRatelimitCtx, r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (ctx.*.deny_reason.len == 0) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = ctx.*.deny_reason.data;
    v.*.flags.len = @intCast(ctx.*.deny_reason.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn get_remaining_requests(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    return renderUintVar(r, v, blk: {
        const ctx = core.castPtr(LlmRatelimitCtx, r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index]) orelse break :blk null;
        break :blk ctx.*.remaining_requests;
    });
}

fn get_remaining_tokens(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    return renderUintVar(r, v, blk: {
        const ctx = core.castPtr(LlmRatelimitCtx, r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index]) orelse break :blk null;
        if (ctx.*.remaining_tokens == 0 and ctx.*.deny_reason.len == 0) break :blk null; // no tpm configured
        break :blk ctx.*.remaining_tokens;
    });
}

fn get_spend_deny_unit(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(LlmRatelimitCtx, r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (ctx.*.spend_deny_unit.len == 0) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = ctx.*.spend_deny_unit.data;
    v.*.flags.len = @intCast(ctx.*.spend_deny_unit.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn renderUintVar(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, val: ?ngx_uint_t) ngx_int_t {
    const n = val orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    var scratch: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&scratch, "{d}", .{n}) catch {
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

// ── Context helpers ───────────────────────────────────────────────────────────

fn setCtx(r: [*c]ngx_http_request_t, result: QuotaResult, key_hash: u64, dry_run: ngx_flag_t, translated: ngx_flag_t) void {
    const ctx = core.ngz_pcalloc_c(LlmRatelimitCtx, r.*.pool) orelse return;
    ctx.*.deny_reason = result.deny_reason;
    ctx.*.remaining_requests = result.remaining_req;
    ctx.*.remaining_tokens = result.remaining_tok;
    ctx.*.token_reservation = result.token_reservation;
    ctx.*.key_hash = key_hash;
    ctx.*.dry_run = dry_run;
    ctx.*.translated = translated;
    ctx.*.spend_deny_unit = deny_reason_none;
    ctx.*.spend_incremented = 0;
    r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index] = ctx;
}

// M2 Target 5: set ctx for a spend-budget deny (no quota entry consumed).
fn setCtxSpendDeny(r: [*c]ngx_http_request_t, dry_run: ngx_flag_t, unit: ngx_str_t) void {
    const ctx = core.ngz_pcalloc_c(LlmRatelimitCtx, r.*.pool) orelse return;
    ctx.*.deny_reason = deny_reason_spend;
    ctx.*.remaining_requests = 0;
    ctx.*.remaining_tokens = 0;
    ctx.*.token_reservation = 0;
    ctx.*.key_hash = 0;
    ctx.*.dry_run = dry_run;
    ctx.*.translated = 0;
    ctx.*.spend_deny_unit = unit;
    ctx.*.spend_incremented = 0;
    r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index] = ctx;
}

// ── Variable resolution helpers ───────────────────────────────────────────────

fn resolveKey(r: [*c]ngx_http_request_t, lccf: *llm_ratelimit_loc_conf) ?ngx_str_t {
    if (lccf.*.key_var_index < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(lccf.*.key_var_index));
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

fn isRejectedResolutionOutcome(outcome: ngx_uint_t) bool {
    return outcome == RESOLUTION_OUTCOME_REJECTED_OUT_OF_SCOPE or
        outcome == RESOLUTION_OUTCOME_REJECTED_UNRESOLVABLE;
}

fn resolveStrVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?ngx_str_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    return ngx_str_t{ .data = val.*.data, .len = val.*.flags.len };
}

fn cacheSpendScopeIds(cache: *[MAX_SPEND_SCOPES]SpendRequestScopeCache, scope_idx: usize, org_id: ?ngx_str_t, project_id: ?ngx_str_t, client_id: ?ngx_str_t) void {
    if (scope_idx >= MAX_SPEND_SCOPES) return;
    cache[scope_idx] = .{
        .ids = .{
            org_id orelse deny_reason_none,
            project_id orelse deny_reason_none,
            client_id orelse deny_reason_none,
        },
        .valid = 1,
    };
}

fn setSpendCacheForRequest(r: [*c]ngx_http_request_t, cache: *const [MAX_SPEND_SCOPES]SpendRequestScopeCache) void {
    const ctx = core.castPtr(LlmRatelimitCtx, r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index]) orelse return;
    ctx.*.spend_scope_cache = cache.*;
}

fn resolveSpendScopeId(
    r: [*c]ngx_http_request_t,
    entry: *SpendScopeEntry,
    ctx: ?*LlmRatelimitCtx,
    scope_idx: usize,
    id_idx: usize,
) ?ngx_str_t {
    if (id_idx >= 3) return null;
    if (ctx) |c| if (scope_idx < MAX_SPEND_SCOPES) {
        const cached = c.spend_scope_cache[scope_idx];
        if (cached.valid != 0) {
            const id = cached.ids[id_idx];
            return if (id.len > 0) id else null;
        }
    };
    return if (entry.id_var_indices[id_idx] >= 0)
        resolveStrVar(r, entry.id_var_indices[id_idx])
    else
        null;
}

// ── Phase 4: tier resolution ──────────────────────────────────────────────────

fn strStartsWith(s: ngx_str_t, prefix: ngx_str_t) bool {
    if (s.len < prefix.len) return false;
    const a = core.slicify(u8, s.data, prefix.len);
    const b = core.slicify(u8, prefix.data, prefix.len);
    return std.ascii.eqlIgnoreCase(a, b);
}

fn strEql(a: ngx_str_t, b: ngx_str_t) bool {
    if (a.len != b.len) return false;
    return std.ascii.eqlIgnoreCase(
        core.slicify(u8, a.data, a.len),
        core.slicify(u8, b.data, b.len),
    );
}

// Apply the first matching model tier override. Returns rpm/tpm from override or 0 if no match.
fn resolveModelOverride(model: ngx_str_t, lccf: *llm_ratelimit_loc_conf) struct { rpm: ngx_uint_t, tpm: ngx_uint_t } {
    if (model.len == 0 or lccf.*.model_overrides_count == 0) return .{ .rpm = 0, .tpm = 0 };
    var i: usize = 0;
    while (i < lccf.*.model_overrides_count) : (i += 1) {
        const o = &lccf.*.model_overrides[i];
        if (o.*.pattern.len == 0) continue;
        if (strStartsWith(model, o.*.pattern)) return .{ .rpm = o.*.requests_per_minute, .tpm = o.*.tokens_per_minute };
    }
    return .{ .rpm = 0, .tpm = 0 };
}

fn resolveProviderOverride(provider: ngx_str_t, lccf: *llm_ratelimit_loc_conf) struct { rpm: ngx_uint_t, tpm: ngx_uint_t } {
    if (provider.len == 0 or lccf.*.provider_overrides_count == 0) return .{ .rpm = 0, .tpm = 0 };
    var i: usize = 0;
    while (i < lccf.*.provider_overrides_count) : (i += 1) {
        const o = &lccf.*.provider_overrides[i];
        if (o.*.pattern.len == 0) continue;
        if (strEql(provider, o.*.pattern)) return .{ .rpm = o.*.requests_per_minute, .tpm = o.*.tokens_per_minute };
    }
    return .{ .rpm = 0, .tpm = 0 };
}

// M2 Target 2: detect translation by comparing requested vs effective dialect.
// Both are set by llm-proxy in ACCESS phase (after body parsing), so available here.
fn isTranslationExpected(obs: LlmProxyObservable) bool {
    if (obs.requested_dialect.len == 0 or obs.effective_dialect.len == 0) return false;
    return !strEql(obs.requested_dialect, obs.effective_dialect);
}

// M2 Target 3: pick model variable based on configured basis.
// Falls back to $llm_model (original behavior) if effective_model is unavailable.
fn resolveModelVar(obs: LlmProxyObservable, lccf: *llm_ratelimit_loc_conf) ?ngx_str_t {
    if (lccf.*.model_basis == MODEL_BASIS_REQUESTED) {
        return if (obs.requested_model.len > 0) obs.requested_model else null;
    }
    if (obs.effective_model.len > 0) return obs.effective_model;
    return if (obs.model.len > 0) obs.model else null;
}

// M2 Target 3: pick provider variable based on configured basis.
fn resolveProviderVar(obs: LlmProxyObservable, lccf: *llm_ratelimit_loc_conf) ?ngx_str_t {
    if (lccf.*.provider_basis == MODEL_BASIS_REQUESTED) {
        return if (obs.requested_provider.len > 0) obs.requested_provider else null;
    }
    if (obs.effective_provider.len > 0) return obs.effective_provider;
    return if (obs.provider.len > 0) obs.provider else null;
}

// Resolve effective RPM and TPM for this request:
// translation limits (M2) > model overrides (Phase 4) > provider overrides > base config.
fn resolveEffectiveQuota(
    r: [*c]ngx_http_request_t,
    lccf: *llm_ratelimit_loc_conf,
) struct { rpm: ngx_uint_t, tpm: ngx_uint_t, reserve: ngx_uint_t, translated: ngx_flag_t } {
    var rpm = lccf.*.requests_per_minute;
    var tpm = lccf.*.tokens_per_minute;
    const reserve = if (lccf.*.reserve_tokens > 0) lccf.*.reserve_tokens else DEFAULT_RESERVE_TOKENS;

    // Common allow-path fast path: when no translated quotas and no tier overrides
    // are configured, the request does not need any llm-proxy variable resolution.
    if (lccf.*.translated_rpm_set != 1 and
        lccf.*.translated_tpm_set != 1 and
        lccf.*.model_overrides_count == 0 and
        lccf.*.provider_overrides_count == 0)
    {
        return .{ .rpm = rpm, .tpm = tpm, .reserve = reserve, .translated = 0 };
    }

    const obs = ngx_http_llm_proxy_observe(r);

    // M2 Target 2: override with translated limits when translation is detected.
    // Translation check precedes model/provider tier overrides because the translation
    // penalty is orthogonal to model-specific pricing — it can apply on top.
    const translating: ngx_flag_t =
        if ((lccf.*.translated_rpm_set == 1 or lccf.*.translated_tpm_set == 1) and isTranslationExpected(obs))
            1
        else
            0;
    if (translating == 1) {
        if (lccf.*.translated_rpm_set == 1 and lccf.*.translated_rpm > 0) rpm = lccf.*.translated_rpm;
        if (lccf.*.translated_tpm_set == 1 and lccf.*.translated_tpm > 0) tpm = lccf.*.translated_tpm;
    }

    // M2 Target 3: model tier override uses effective_model by default.
    if (lccf.*.model_overrides_count > 0) {
        if (resolveModelVar(obs, lccf)) |model| {
            const mo = resolveModelOverride(model, lccf);
            if (mo.rpm > 0) rpm = mo.rpm;
            if (mo.tpm > 0) tpm = mo.tpm;
            return .{ .rpm = rpm, .tpm = tpm, .reserve = reserve, .translated = translating };
        }
    }

    // M2 Target 3: provider tier override uses effective_provider by default.
    if (lccf.*.provider_overrides_count > 0) {
        if (resolveProviderVar(obs, lccf)) |provider| {
            const po = resolveProviderOverride(provider, lccf);
            if (po.rpm > 0) rpm = po.rpm;
            if (po.tpm > 0) tpm = po.tpm;
        }
    }

    return .{ .rpm = rpm, .tpm = tpm, .reserve = reserve, .translated = translating };
}

// ── Phase handlers ────────────────────────────────────────────────────────────

fn access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        llm_ratelimit_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_ratelimit_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;

    const mcf = core.castPtr(
        llm_ratelimit_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_ratelimit_module),
    ) orelse return NGX_DECLINED;

    const dry_run = lccf.*.dry_run;
    const fail_open = lccf.*.fail_open;

    // Config validation: rpm must be set when enabled.
    if (lccf.*.requests_per_minute == 0) {
        setCtx(r, .{
            .allowed = false,
            .deny_reason = deny_reason_config,
            .remaining_req = 0,
            .remaining_tok = 0,
            .token_reservation = 0,
        }, 0, dry_run, 0);
        if (dry_run == 1) return NGX_DECLINED;
        return NGX_HTTP_TOO_MANY_REQUESTS;
    }

    const key_str = resolveKey(r, lccf) orelse {
        setCtx(r, .{
            .allowed = false,
            .deny_reason = deny_reason_identity,
            .remaining_req = 0,
            .remaining_tok = 0,
            .token_reservation = 0,
        }, 0, dry_run, 0);
        if (fail_open == 1 or dry_run == 1) return NGX_DECLINED;
        return NGX_HTTP_TOO_MANY_REQUESTS;
    };

    const key_hash = hashBytes(core.slicify(u8, key_str.data, key_str.len));

    const rate_sp = getStoreAndPool(mcf);
    const rate_shpool = rate_sp.shpool orelse {
        setCtx(r, .{ .allowed = true, .deny_reason = deny_reason_none, .remaining_req = 0, .remaining_tok = 0, .token_reservation = 0 }, key_hash, dry_run, 0);
        return NGX_DECLINED;
    };
    const store = rate_sp.store orelse {
        setCtx(r, .{ .allowed = true, .deny_reason = deny_reason_none, .remaining_req = 0, .remaining_tok = 0, .token_reservation = 0 }, key_hash, dry_run, 0);
        return NGX_DECLINED;
    };

    // M2 Target 5: check spend budgets before consuming quota slots.
    // Use lccf as *T (not [*c]T) for array field access.
    const lccf_ptr: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(lccf));
    var spend_scope_cache = std.mem.zeroes([MAX_SPEND_SCOPES]SpendRequestScopeCache);
    if (checkSpendBudgets(mcf, r, lccf_ptr, &spend_scope_cache)) |exhausted_unit| {
        setCtxSpendDeny(r, dry_run, exhausted_unit);
        setSpendCacheForRequest(r, &spend_scope_cache);
        if (dry_run == 1) return NGX_DECLINED;
        return NGX_HTTP_TOO_MANY_REQUESTS;
    }

    const quota = resolveEffectiveQuota(r, lccf);

    shm.ngx_shmtx_lock(&rate_shpool.*.mutex);
    const result = checkAndConsume(store, key_hash, quota.rpm, lccf.*.burst_requests, quota.tpm, quota.reserve, getCurrentMs());
    shm.ngx_shmtx_unlock(&rate_shpool.*.mutex);

    setCtx(r, result, key_hash, dry_run, quota.translated);

    if (!result.allowed) {
        releaseSpendReservations(mcf, lccf_ptr, &spend_scope_cache);
        setSpendCacheForRequest(r, &spend_scope_cache);
        if (dry_run == 1) return NGX_DECLINED;
        return NGX_HTTP_TOO_MANY_REQUESTS;
    }
    setSpendCacheForRequest(r, &spend_scope_cache);
    return NGX_DECLINED;
}

// Phase 2 & 3 LOG handler.
//
// Responsibilities:
//   Phase 2: the request outcome is already correct — all ACCESS-allowed requests
//   consumed a slot regardless of upstream outcome. No extra action needed.
//
//   Phase 3 (token reconciliation): if llm-proxy extracted token usage from the
//   response, replace the pre-flight reservation with the actual count. If usage
//   is unavailable, the reservation stands (documented fallback mode).
//
//   Phase 4 (provider cooldown): if the upstream returned 429 and reset_after_ms
//   is available, set a cooldown on the caller's ledger entry.
//
//   M2 Target 2 (rejection-before-send reconciliation): if resolution_outcome
//   indicates the request was rejected before reaching the upstream, return the
//   consumed request slot. This avoids penalizing callers for routing failures.
fn log_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const ctx = core.castPtr(LlmRatelimitCtx, r.*.ctx[ngx_http_llm_ratelimit_module.ctx_index]) orelse return NGX_OK;

    const lccf = core.castPtr(
        llm_ratelimit_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_ratelimit_module),
    ) orelse return NGX_OK;

    if (lccf.*.enabled != 1) return NGX_OK;

    const mcf = core.castPtr(
        llm_ratelimit_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_ratelimit_module),
    ) orelse return NGX_OK;

    const do_return_slot = isRejectedResolutionOutcome(ngx_http_llm_proxy_resolution_outcome(r));

    // M2 Target 5: increment spend counters for every completed request including dry_run.
    // Must run before the dry_run early-return so dry_run observations are recorded.
    // Guard with spend_incremented to survive subrequest/multi-phase re-entry.
    if (ctx.*.spend_incremented == 0) {
        const lccf_ptr: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(lccf));
        if (lccf_ptr.spend_count > 0) {
            const cost_obs = ngx_http_llm_cost_observe(r);
            reconcileSpendCounters(
                mcf,
                r,
                lccf_ptr,
                ctx,
                cost_obs.cost_unit,
                cost_obs.total_cost_micros,
                cost_obs.eligible == 1,
                do_return_slot,
            );
            ctx.*.spend_incremented = 1;
        }
    }

    // Only reconcile quota for non-dry-run requests that consumed a reservation.
    if (ctx.*.dry_run == 1) return NGX_OK;

    const key_hash = ctx.*.key_hash;
    if (key_hash == 0) return NGX_OK;

    const sp = getStoreAndPool(mcf);
    const shpool = sp.shpool orelse return NGX_OK;
    const store = sp.store orelse return NGX_OK;

    // Compute all needed values before taking the lock to minimize critical section.

    // Phase 3: reconcile token reservation with actual usage.
    var do_reconcile = false;
    var actual_tokens: ngx_uint_t = 0;
    if (ctx.*.token_reservation > 0) {
        actual_tokens = ngx_http_llm_proxy_total_tokens(r);
        // actual_tokens == 0: usage not available — keep reservation as-is (fallback mode).
        if (actual_tokens > 0) do_reconcile = true;
    }

    // Phase 4: apply provider-feedback cooldown if upstream rate-limited us.
    var do_cooldown = false;
    var cooldown_until_ms: u64 = 0;
    if (lccf.*.cooldown_enabled == 1) {
        if (r.*.headers_out.status == 429) {
            if (resolveUintVar(r, mcf.*.llm_reset_after_ms_idx)) |reset_ms| {
                if (reset_ms > 0) {
                    cooldown_until_ms = getCurrentMs() + reset_ms;
                    do_cooldown = true;
                }
            }
        }
    }

    // M2 Target 2: return the consumed slot when the request was rejected before upstream send.
    // These outcomes are set by llm-proxy after ACCESS phase, so only visible in LOG.
    // Use the lightweight single-field accessor to avoid the full ~216-byte observe() copy.
    // All three operations target the same key_hash and therefore the same stripe lock.
    // Acquire once and dispatch all pending work inside the critical section.
    if (do_reconcile or do_cooldown or do_return_slot) {
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        if (do_reconcile) reconcileTokens(store, key_hash, ctx.*.token_reservation, actual_tokens);
        if (do_cooldown) setCooldown(store, key_hash, cooldown_until_ms);
        if (do_return_slot) returnRequestSlot(store, key_hash);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
    }

    return NGX_OK;
}

// ── Config parsing ────────────────────────────────────────────────────────────

fn parseSize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    const last = s[s.len - 1];
    if (last == 'k' or last == 'K') {
        const n = std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch return null;
        return std.math.mul(usize, n, 1024) catch return null;
    }
    if (last == 'm' or last == 'M') {
        const n = std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch return null;
        return std.math.mul(usize, n, 1024 * 1024) catch return null;
    }
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn normalizeVarName(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[0] == '$') return raw[1..];
    return raw;
}

fn getVarIndex(cf: [*c]ngx_conf_t, name: []const u8) ngx_int_t {
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    return http.ngx_http_get_variable_index(cf, &n);
}

fn ngx_conf_set_llm_ratelimit(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(llm_ratelimit_loc_conf, loc)) |lccf| lccf.*.enabled = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_zone(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, main: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const mcf = core.castPtr(llm_ratelimit_main_conf, main) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const name_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const size_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const size = parseSize(core.slicify(u8, size_arg.*.data, size_arg.*.len)) orelse return conf.NGX_CONF_ERROR;
    mcf.*.zone_name = name_arg.*;
    mcf.*.zone_size = size;
    mcf.*.zone_set = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_key(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const normalized = normalizeVarName(core.slicify(u8, arg.*.data, arg.*.len));
    if (normalized.len == 0) return conf.NGX_CONF_ERROR;
    const idx = getVarIndex(cf, normalized);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.key_var = arg.*;
    lccf.*.key_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_rpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.*.requests_per_minute = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, arg.*.data, arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    lccf.*.rpm_set = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_burst(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.*.burst_requests = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, arg.*.data, arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    lccf.*.burst_set = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_tpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.*.tokens_per_minute = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, arg.*.data, arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    lccf.*.tpm_set = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_reserve(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.*.reserve_tokens = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, arg.*.data, arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    lccf.*.reserve_set = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_fail_open(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.fail_open = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.fail_open = 0;
    } else return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_dry_run(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.dry_run = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.dry_run = 0;
    } else return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cooldown(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "on")) {
        lccf.*.cooldown_enabled = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.*.cooldown_enabled = 0;
    } else return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// M2 Target 2: llm_ratelimit_translated_rpm <n>
fn ngx_conf_set_translated_rpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.*.translated_rpm = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, arg.*.data, arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    lccf.*.translated_rpm_set = 1;
    return conf.NGX_CONF_OK;
}

// M2 Target 2: llm_ratelimit_translated_tpm <n>
fn ngx_conf_set_translated_tpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.*.translated_tpm = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, arg.*.data, arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    lccf.*.translated_tpm_set = 1;
    return conf.NGX_CONF_OK;
}

// M2 Target 3: llm_ratelimit_model_basis requested|effective
fn ngx_conf_set_model_basis(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "effective")) {
        lccf.*.model_basis = MODEL_BASIS_EFFECTIVE;
    } else if (std.mem.eql(u8, s, "requested")) {
        lccf.*.model_basis = MODEL_BASIS_REQUESTED;
    } else return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// M2 Target 3: llm_ratelimit_provider_basis requested|effective
fn ngx_conf_set_provider_basis(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, s, "effective")) {
        lccf.*.provider_basis = MODEL_BASIS_EFFECTIVE;
    } else if (std.mem.eql(u8, s, "requested")) {
        lccf.*.provider_basis = MODEL_BASIS_REQUESTED;
    } else return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn findOverrideIndex(overrides: []const RateTierOverride, count: ngx_uint_t, pattern: ngx_str_t) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (strEql(overrides[i].pattern, pattern)) return i;
    }
    return null;
}

fn upsertOverride(
    overrides: []RateTierOverride,
    count: *ngx_uint_t,
    pattern: ngx_str_t,
    rpm: ?ngx_uint_t,
    tpm: ?ngx_uint_t,
) !void {
    const idx = findOverrideIndex(overrides, count.*, pattern) orelse blk: {
        if (count.* >= overrides.len) return error.NoSpaceLeft;
        const next: usize = count.*;
        overrides[next] = .{
            .pattern = pattern,
            .requests_per_minute = 0,
            .tokens_per_minute = 0,
        };
        count.* += 1;
        break :blk next;
    };

    if (rpm) |v| overrides[idx].requests_per_minute = v;
    if (tpm) |v| overrides[idx].tokens_per_minute = v;
}

fn parsePositiveMicros(raw: []const u8) ?u64 {
    const value = std.fmt.parseFloat(f64, raw) catch return null;
    if (value <= 0.0 or !std.math.isFinite(value)) return null;
    const scaled = value * 1_000_000.0;
    if (!std.math.isFinite(scaled)) return null;
    const capped = @min(scaled, @as(f64, @floatFromInt(std.math.maxInt(u64) / 2)));
    return @intFromFloat(@ceil(capped));
}

// Phase 4: llm_ratelimit_model_rpm <pattern> <rpm>
fn ngx_conf_set_model_rpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    // castPtr returns [*c]T; cast to *T before accessing array fields ([*c]T.*.array[i] is broken).
    const lccf: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR));
    var i: ngx_uint_t = 1;
    const pat_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const rpm_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const rpm = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, rpm_arg.*.data, rpm_arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    upsertOverride(lccf.model_overrides[0..], &lccf.model_overrides_count, pat_arg.*, rpm, null) catch return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// Phase 4: llm_ratelimit_provider_rpm <provider> <rpm>
fn ngx_conf_set_provider_rpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR));
    var i: ngx_uint_t = 1;
    const pat_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const rpm_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const rpm = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, rpm_arg.*.data, rpm_arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    upsertOverride(lccf.provider_overrides[0..], &lccf.provider_overrides_count, pat_arg.*, rpm, null) catch return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// Phase 4: llm_ratelimit_model_tpm <pattern> <tpm>
fn ngx_conf_set_model_tpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR));
    var i: ngx_uint_t = 1;
    const pat_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const tpm_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const tpm = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, tpm_arg.*.data, tpm_arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    upsertOverride(lccf.model_overrides[0..], &lccf.model_overrides_count, pat_arg.*, null, tpm) catch return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// Phase 4: llm_ratelimit_provider_tpm <provider> <tpm>
fn ngx_conf_set_provider_tpm(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR));
    var i: ngx_uint_t = 1;
    const pat_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const tpm_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const tpm = std.fmt.parseInt(ngx_uint_t, core.slicify(u8, tpm_arg.*.data, tpm_arg.*.len), 10) catch return conf.NGX_CONF_ERROR;
    upsertOverride(lccf.provider_overrides[0..], &lccf.provider_overrides_count, pat_arg.*, null, tpm) catch return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

// M2 Target 5: llm_ratelimit_spend_scope <scope> <unit> <id_var> [<id_var>...] <budget>
// scope: organization | project | client
// unit:  usd | credits | <any cost unit string>
// id_vars: one, two, or three nginx variable names for org_id, [project_id], [client_id]
// budget: decimal value in the given unit (e.g. 50.00); stored as micros.
fn ngx_conf_set_spend_scope(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR));
    const mcf = core.castPtr(
        llm_ratelimit_main_conf,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_llm_ratelimit_module),
    ) orelse return conf.NGX_CONF_ERROR;

    if (lccf.spend_count >= MAX_SPEND_SCOPES) return conf.NGX_CONF_ERROR;

    var idx: ngx_uint_t = 1;
    // arg 1: scope
    const scope_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &idx) orelse return conf.NGX_CONF_ERROR;
    const scope_s = core.slicify(u8, scope_arg.*.data, scope_arg.*.len);
    const scope: ngx_uint_t = if (std.mem.eql(u8, scope_s, "organization"))
        SPEND_SCOPE_ORG
    else if (std.mem.eql(u8, scope_s, "project"))
        SPEND_SCOPE_PROJECT
    else if (std.mem.eql(u8, scope_s, "client"))
        SPEND_SCOPE_CLIENT
    else
        return conf.NGX_CONF_ERROR;

    // Required id_var count: org=1, project=2, client=3.
    const required_id_vars: usize = scope + 1;
    const expected_args = @as(ngx_uint_t, @intCast(4 + required_id_vars)); // directive name + scope + unit + ids + budget
    if (cf.*.args.*.nelts != expected_args) return conf.NGX_CONF_ERROR;

    // arg 2: unit
    const unit_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &idx) orelse return conf.NGX_CONF_ERROR;

    // args 3..(3+required_id_vars-1): id variable names
    var id_var_indices: [3]ngx_int_t = .{ -1, -1, -1 };
    var vi: usize = 0;
    while (vi < required_id_vars) : (vi += 1) {
        const var_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &idx) orelse return conf.NGX_CONF_ERROR;
        const normalized = normalizeVarName(core.slicify(u8, var_arg.*.data, var_arg.*.len));
        if (normalized.len == 0) return conf.NGX_CONF_ERROR;
        const var_idx = getVarIndex(cf, normalized);
        if (var_idx < 0) return conf.NGX_CONF_ERROR;
        id_var_indices[vi] = var_idx;
    }

    // last arg: budget as decimal (e.g. "50.00"); convert to micros.
    const budget_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &idx) orelse return conf.NGX_CONF_ERROR;
    const budget_s = core.slicify(u8, budget_arg.*.data, budget_arg.*.len);
    const budget_micros = parsePositiveMicros(budget_s) orelse return conf.NGX_CONF_ERROR;

    const entry: *SpendScopeEntry = &lccf.spend_scopes[lccf.spend_count];
    entry.scope = scope;
    entry.budget_micros = budget_micros;
    entry.unit = unit_arg.*;
    entry.id_var_indices = id_var_indices;
    lccf.spend_count += 1;

    mcf.*.spend_enabled = 1;
    return conf.NGX_CONF_OK;
}

// llm_ratelimit_reserve_spend <unit> <amount>
// Opt-in conservative in-flight reservation for every configured spend scope
// using the selected cost unit. The amount is reconciled to actual cost in LOG.
fn ngx_conf_set_spend_reserve(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    if (lccf.*.spend_reserve_set != conf.NGX_CONF_UNSET) return conf.NGX_CONF_ERROR;
    var idx: ngx_uint_t = 1;
    const unit = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &idx) orelse return conf.NGX_CONF_ERROR;
    const amount = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &idx) orelse return conf.NGX_CONF_ERROR;
    const micros = parsePositiveMicros(core.slicify(u8, amount.*.data, amount.*.len)) orelse return conf.NGX_CONF_ERROR;
    lccf.*.spend_reserve_unit = unit.*;
    lccf.*.spend_reserve_micros = micros;
    lccf.*.spend_reserve_set = 1;
    return conf.NGX_CONF_OK;
}

// ── Module lifecycle ──────────────────────────────────────────────────────────

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_ratelimit_main_conf, cf.*.pool) orelse return null;
    p.*.zone_size = DEFAULT_ZONE_SIZE;
    p.*.zone_set = 0;
    p.*.rate_zone = core.nullptr(core.ngx_shm_zone_t);
    p.*.spend_zone = core.nullptr(core.ngx_shm_zone_t);
    p.*.llm_total_tokens_idx = -1;
    p.*.llm_model_idx = -1;
    p.*.llm_provider_idx = -1;
    p.*.llm_reset_after_ms_idx = -1;
    p.*.llm_requested_dialect_idx = -1;
    p.*.llm_effective_dialect_idx = -1;
    p.*.llm_translation_happened_idx = -1;
    p.*.llm_resolution_outcome_idx = -1;
    p.*.llm_requested_model_idx = -1;
    p.*.llm_requested_provider_idx = -1;
    p.*.llm_effective_model_idx = -1;
    p.*.llm_effective_provider_idx = -1;
    p.*.spend_enabled = 0;
    return p;
}

fn init_main_conf(cf: [*c]ngx_conf_t, mcf_ptr: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = mcf_ptr;
    return conf.NGX_CONF_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_ratelimit_loc_conf, cf.*.pool) orelse return null;
    p.*.enabled = conf.NGX_CONF_UNSET;
    p.*.requests_per_minute = 0;
    p.*.rpm_set = conf.NGX_CONF_UNSET;
    p.*.burst_requests = 0;
    p.*.burst_set = conf.NGX_CONF_UNSET;
    p.*.tokens_per_minute = 0;
    p.*.tpm_set = conf.NGX_CONF_UNSET;
    p.*.reserve_tokens = DEFAULT_RESERVE_TOKENS;
    p.*.reserve_set = conf.NGX_CONF_UNSET;
    p.*.key_var_index = -1;
    p.*.fail_open = 0;
    p.*.dry_run = 0;
    p.*.model_overrides_count = 0;
    p.*.provider_overrides_count = 0;
    p.*.cooldown_enabled = 0;
    p.*.translated_rpm = 0;
    p.*.translated_tpm = 0;
    p.*.translated_rpm_set = 0;
    p.*.translated_tpm_set = 0;
    p.*.model_basis = MODEL_BASIS_EFFECTIVE;
    p.*.provider_basis = MODEL_BASIS_EFFECTIVE;
    p.*.spend_count = 0;
    p.*.spend_reserve_micros = 0;
    p.*.spend_reserve_set = conf.NGX_CONF_UNSET;
    return p;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(llm_ratelimit_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(llm_ratelimit_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == conf.NGX_CONF_UNSET) c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;

    if (c.*.rpm_set == conf.NGX_CONF_UNSET) {
        c.*.requests_per_minute = if (prev.*.rpm_set != conf.NGX_CONF_UNSET) prev.*.requests_per_minute else 0;
        c.*.rpm_set = prev.*.rpm_set;
    }
    if (c.*.burst_set == conf.NGX_CONF_UNSET) {
        c.*.burst_requests = if (prev.*.burst_set != conf.NGX_CONF_UNSET) prev.*.burst_requests else 0;
        c.*.burst_set = prev.*.burst_set;
    }
    if (c.*.tpm_set == conf.NGX_CONF_UNSET) {
        c.*.tokens_per_minute = if (prev.*.tpm_set != conf.NGX_CONF_UNSET) prev.*.tokens_per_minute else 0;
        c.*.tpm_set = prev.*.tpm_set;
    }
    if (c.*.reserve_set == conf.NGX_CONF_UNSET) {
        c.*.reserve_tokens = if (prev.*.reserve_set != conf.NGX_CONF_UNSET) prev.*.reserve_tokens else DEFAULT_RESERVE_TOKENS;
        c.*.reserve_set = prev.*.reserve_set;
    }
    if (c.*.key_var.data == null and prev.*.key_var.data != null) {
        c.*.key_var = prev.*.key_var;
        c.*.key_var_index = prev.*.key_var_index;
    }
    if (c.*.fail_open == 0 and prev.*.fail_open != 0) c.*.fail_open = prev.*.fail_open;
    if (c.*.dry_run == 0 and prev.*.dry_run != 0) c.*.dry_run = prev.*.dry_run;
    if (c.*.cooldown_enabled == 0 and prev.*.cooldown_enabled != 0) c.*.cooldown_enabled = prev.*.cooldown_enabled;

    if (c.*.model_overrides_count == 0 and prev.*.model_overrides_count > 0) {
        c.*.model_overrides = prev.*.model_overrides;
        c.*.model_overrides_count = prev.*.model_overrides_count;
    }
    if (c.*.provider_overrides_count == 0 and prev.*.provider_overrides_count > 0) {
        c.*.provider_overrides = prev.*.provider_overrides;
        c.*.provider_overrides_count = prev.*.provider_overrides_count;
    }

    // M2 Target 2: inherit translated quota limits from parent.
    if (c.*.translated_rpm_set == 0 and prev.*.translated_rpm_set != 0) {
        c.*.translated_rpm = prev.*.translated_rpm;
        c.*.translated_rpm_set = prev.*.translated_rpm_set;
    }
    if (c.*.translated_tpm_set == 0 and prev.*.translated_tpm_set != 0) {
        c.*.translated_tpm = prev.*.translated_tpm;
        c.*.translated_tpm_set = prev.*.translated_tpm_set;
    }

    // M2 Target 3: inherit model/provider basis from parent.
    // basis defaults to EFFECTIVE (0), so only inherit when parent explicitly set it.
    if (c.*.model_basis == MODEL_BASIS_EFFECTIVE and prev.*.model_basis == MODEL_BASIS_REQUESTED)
        c.*.model_basis = MODEL_BASIS_REQUESTED;
    if (c.*.provider_basis == MODEL_BASIS_EFFECTIVE and prev.*.provider_basis == MODEL_BASIS_REQUESTED)
        c.*.provider_basis = MODEL_BASIS_REQUESTED;

    // M2 Target 5: inherit spend scopes from parent when child has none.
    if (c.*.spend_count == 0 and prev.*.spend_count > 0) {
        const cp: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(c));
        const pp: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(prev));
        cp.spend_scopes = pp.spend_scopes;
        cp.spend_count = pp.spend_count;
    }
    if (c.*.spend_reserve_set == conf.NGX_CONF_UNSET) {
        c.*.spend_reserve_unit = prev.*.spend_reserve_unit;
        c.*.spend_reserve_micros = prev.*.spend_reserve_micros;
        c.*.spend_reserve_set = if (prev.*.spend_reserve_set == conf.NGX_CONF_UNSET) 0 else prev.*.spend_reserve_set;
    }
    if (c.*.spend_reserve_micros > 0) {
        var found_unit = false;
        var i: usize = 0;
        while (i < c.*.spend_count) : (i += 1) {
            const cp: *llm_ratelimit_loc_conf = @ptrCast(@alignCast(c));
            if (strEql(cp.spend_scopes[i].unit, c.*.spend_reserve_unit)) {
                found_unit = true;
                break;
            }
        }
        if (!found_unit) return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn preaccess_handler(r: [*c]http.ngx_http_request_t) callconv(.c) core.ngx_int_t {
    const lccf = core.castPtr(
        llm_ratelimit_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_ratelimit_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;
    if (r == r.*.main) return NGX_DECLINED;

    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_ratelimit: subrequests are not supported on llm_ratelimit-enabled locations", .{});
    return http.NGX_HTTP_FORBIDDEN;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const mcf = core.castPtr(
        llm_ratelimit_main_conf,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_llm_ratelimit_module),
    ) orelse return NGX_ERROR;

    // Create shared-memory zone.
    const zone_size = if (mcf.*.zone_size > 0) mcf.*.zone_size else DEFAULT_ZONE_SIZE;
    var zone_name = if (mcf.*.zone_name.len > 0) mcf.*.zone_name else ngx_string("llm_ratelimit");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, zone_size, @constCast(&ngx_http_llm_ratelimit_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = zone_init;
    mcf.*.rate_zone = zone;

    // Pre-index llm-proxy variables consumed by this module at runtime.
    mcf.*.llm_total_tokens_idx = getVarIndex(cf, "llm_total_tokens");
    mcf.*.llm_reset_after_ms_idx = getVarIndex(cf, "llm_reset_after_ms");

    // M2 Target 5: register separate spend SHM zone when spend budgets are configured.
    if (mcf.*.spend_enabled == 1) {
        // Build spend zone name: "{ratelimit_zone_name}_spend" allocated from conf pool.
        const base_name = if (mcf.*.zone_name.len > 0) mcf.*.zone_name else ngx_string("llm_ratelimit");
        const suffix = "_spend";
        const spend_name_len = base_name.len + suffix.len;
        const spend_name_buf = core.ngx_palloc(cf.*.pool, spend_name_len);
        if (spend_name_buf == null) return NGX_ERROR;
        const spend_name_slice: [*]u8 = @ptrCast(spend_name_buf.?);
        @memcpy(spend_name_slice[0..base_name.len], core.slicify(u8, base_name.data, base_name.len));
        @memcpy(spend_name_slice[base_name.len..spend_name_len], suffix);
        var spend_zone_name = ngx_str_t{ .data = spend_name_slice, .len = spend_name_len };
        const spend_zone_size: usize = @sizeOf(llm_spend_store) + 128 * 1024; // struct + slab overhead
        const sz = shm.ngx_shared_memory_add(cf, &spend_zone_name, spend_zone_size, @constCast(&ngx_http_llm_ratelimit_module));
        if (sz == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
        sz.*.init = spend_zone_init;
        mcf.*.spend_zone = sz;
    }

    // Register gateway quota variables.
    // Note: llm-proxy owns $llm_ratelimit_remaining_requests (provider rate-limit header).
    // This module exposes $llm_ratelimit_quota_remaining (gateway-enforced request quota)
    // and $llm_ratelimit_token_quota_remaining (gateway-enforced token quota).
    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{
            .name = ngx_string("llm_ratelimit_deny_reason"),
            .set_handler = null,
            .get_handler = get_deny_reason,
            .data = 0,
            .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
            .index = 0,
        },
        http.ngx_http_variable_t{
            .name = ngx_string("llm_ratelimit_quota_remaining"),
            .set_handler = null,
            .get_handler = get_remaining_requests,
            .data = 0,
            .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
            .index = 0,
        },
        http.ngx_http_variable_t{
            .name = ngx_string("llm_ratelimit_token_quota_remaining"),
            .set_handler = null,
            .get_handler = get_remaining_tokens,
            .data = 0,
            .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
            .index = 0,
        },
        http.ngx_http_variable_t{
            .name = ngx_string("llm_ratelimit_spend_deny_unit"),
            .set_handler = null,
            .get_handler = get_spend_deny_unit,
            .data = 0,
            .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
            .index = 0,
        },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Register PREACCESS and ACCESS phase handlers.
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var preaccess_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[http.NGX_HTTP_PREACCESS_PHASE].handlers);
    const ph = preaccess_handlers.append() catch return NGX_ERROR;
    ph.* = preaccess_handler;

    var access_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers);
    const ah = access_handlers.append() catch return NGX_ERROR;
    ah.* = access_handler;

    // Register LOG phase handler (Phase 2/3/4/M2).
    var log_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[NGX_HTTP_LOG_PHASE].handlers);
    const lh = log_handlers.append() catch return NGX_ERROR;
    lh.* = log_handler;

    return NGX_OK;
}

// ── Module definition ─────────────────────────────────────────────────────────

export const ngx_http_llm_ratelimit_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = init_main_conf,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_ratelimit_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_ratelimit"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_ratelimit,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_zone"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_zone,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_key"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_key,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_requests_per_minute"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_rpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_burst_requests"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_burst,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_tokens_per_minute"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_tpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_reserve_tokens"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_reserve,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_fail_open"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_fail_open,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_dry_run"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_dry_run,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_cooldown"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_cooldown,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_model_rpm"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_model_rpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_provider_rpm"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_provider_rpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_model_tpm"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_model_tpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_provider_tpm"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_provider_tpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // M2 Target 2
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_translated_rpm"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_translated_rpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_translated_tpm"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_translated_tpm,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // M2 Target 3
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_model_basis"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_model_basis,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_provider_basis"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_provider_basis,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // M2 Target 5: llm_ratelimit_spend_scope <scope> <unit> <id_var>... <budget>
    // Takes 4, 5, or 6 args depending on scope (org=4, project=5, client=6).
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_spend_scope"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE4 | conf.NGX_CONF_TAKE5 | conf.NGX_CONF_TAKE6,
        .set = ngx_conf_set_spend_scope,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_ratelimit_reserve_spend"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_spend_reserve,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_llm_ratelimit_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_ratelimit_commands),
    @constCast(&ngx_http_llm_ratelimit_module_ctx),
);

// ── Unit tests ────────────────────────────────────────────────────────────────

const expectEqual = std.testing.expectEqual;

test "hashBytes is stable and non-zero" {
    const h1 = hashBytes("user-alice");
    const h2 = hashBytes("user-alice");
    const h3 = hashBytes("user-bob");
    try expectEqual(h1, h2);
    try std.testing.expect(h1 != 0);
    try std.testing.expect(h1 != h3);
}

test "positive spend values round conservatively to micros" {
    try expectEqual(@as(?u64, 1), parsePositiveMicros("0.0000001"));
    try expectEqual(@as(?u64, 1), parsePositiveMicros("0.000001"));
    try expectEqual(@as(?u64, 1000), parsePositiveMicros("0.001"));
    try expectEqual(@as(?u64, null), parsePositiveMicros("0"));
    try expectEqual(@as(?u64, null), parsePositiveMicros("-1"));
}

test "request quota enforcement" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    const h = hashBytes("test-key");
    const now_ms: u64 = 1000000;
    const r1 = checkAndConsume(&store, h, 3, 0, 0, 0, now_ms);
    try std.testing.expect(r1.allowed);
    try expectEqual(@as(ngx_uint_t, 2), r1.remaining_req);
    const r2 = checkAndConsume(&store, h, 3, 0, 0, 0, now_ms);
    try std.testing.expect(r2.allowed);
    const r3 = checkAndConsume(&store, h, 3, 0, 0, 0, now_ms);
    try std.testing.expect(r3.allowed);
    const r4 = checkAndConsume(&store, h, 3, 0, 0, 0, now_ms);
    try std.testing.expect(!r4.allowed);
    try expectEqual(deny_reason_budget.len, r4.deny_reason.len);
}

test "burst allowance extends request budget" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    const h = hashBytes("burst-key");
    const now_ms: u64 = 2000000;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const r = checkAndConsume(&store, h, 2, 1, 0, 0, now_ms);
        try std.testing.expect(r.allowed);
    }
    const over = checkAndConsume(&store, h, 2, 1, 0, 0, now_ms);
    try std.testing.expect(!over.allowed);
}

test "separate keys have independent counters" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    const ha = hashBytes("alice");
    const hb = hashBytes("bob");
    const now_ms: u64 = 3000000;
    _ = checkAndConsume(&store, ha, 2, 0, 0, 0, now_ms);
    _ = checkAndConsume(&store, ha, 2, 0, 0, 0, now_ms);
    const alice_over = checkAndConsume(&store, ha, 2, 0, 0, 0, now_ms);
    try std.testing.expect(!alice_over.allowed);
    const bob_ok = checkAndConsume(&store, hb, 2, 0, 0, 0, now_ms);
    try std.testing.expect(bob_ok.allowed);
}

test "token budget pre-flight check" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    const h = hashBytes("tok-key");
    const now_ms: u64 = 4000000;
    // tpm=100, reserve=40 → 2 requests fit (40+40=80 ≤ 100), third gets partial, fourth denied
    const r1 = checkAndConsume(&store, h, 10, 0, 100, 40, now_ms);
    try std.testing.expect(r1.allowed);
    try expectEqual(@as(ngx_uint_t, 40), r1.token_reservation);
    const r2 = checkAndConsume(&store, h, 10, 0, 100, 40, now_ms);
    try std.testing.expect(r2.allowed);
    // token_count = 80, reserve=40 → 80+40=120 > 100, denied
    const r3 = checkAndConsume(&store, h, 10, 0, 100, 40, now_ms);
    try std.testing.expect(!r3.allowed);
    try expectEqual(deny_reason_tokens.len, r3.deny_reason.len);
}

test "token reconciliation adjusts counter" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    store.store_size = @sizeOf(llm_ratelimit_store);
    const h = hashBytes("reconcile-key");
    const now_ms: u64 = 5000000;
    // Reserve 100 tokens
    _ = checkAndConsume(&store, h, 10, 0, 1000, 100, now_ms);
    // Actual usage was only 60 — reconcile down
    reconcileTokens(&store, h, 100, 60);
    const entry = findEntry(&store, h) orelse unreachable;
    try expectEqual(@as(u64, 60), entry.token_count);
}

test "token reconciliation over-usage" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    store.store_size = @sizeOf(llm_ratelimit_store);
    const h = hashBytes("overuse-key");
    const now_ms: u64 = 6000000;
    _ = checkAndConsume(&store, h, 10, 0, 1000, 100, now_ms);
    // Actual was 200, reserved 100 → counter increases by 100
    reconcileTokens(&store, h, 100, 200);
    const found_entry = findEntry(&store, h);
    try std.testing.expect(found_entry != null);
    try expectEqual(@as(u64, 200), found_entry.?.token_count);
}

test "cooldown blocks requests" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    const h = hashBytes("cd-key");
    const now_ms: u64 = 7000000;
    // First request allowed
    const r1 = checkAndConsume(&store, h, 10, 0, 0, 0, now_ms);
    try std.testing.expect(r1.allowed);
    // Set cooldown for 5 seconds
    setCooldown(&store, h, now_ms + 5000);
    // Same millisecond — should be blocked
    const r2 = checkAndConsume(&store, h, 10, 0, 0, 0, now_ms);
    try std.testing.expect(!r2.allowed);
    try expectEqual(deny_reason_cooldown.len, r2.deny_reason.len);
    // After cooldown expires — should be allowed
    const r3 = checkAndConsume(&store, h, 10, 0, 0, 0, now_ms + 5001);
    try std.testing.expect(r3.allowed);
}

test "parseSize parses k/m suffixes" {
    try expectEqual(@as(?usize, 1024), parseSize("1k"));
    try expectEqual(@as(?usize, 2048), parseSize("2K"));
    try expectEqual(@as(?usize, 1048576), parseSize("1m"));
    try expectEqual(@as(?usize, 512), parseSize("512"));
    try expectEqual(@as(?usize, null), parseSize("bad"));
    try expectEqual(@as(?usize, null), parseSize("999999999999999999999999999999999999999999999999999999m"));
    try expectEqual(@as(?usize, null), parseSize("999999999999999999999999999999999999999999999999999999k"));
}

test "strStartsWith case-insensitive" {
    const gpt4 = ngx_string("gpt-4o");
    const prefix = ngx_string("GPT-4");
    try std.testing.expect(strStartsWith(gpt4, prefix));
    const other = ngx_string("claude-3");
    try std.testing.expect(!strStartsWith(other, prefix));
}

test "override upsert merges rate and token tiers regardless of directive order" {
    var overrides = std.mem.zeroes([MAX_OVERRIDES]RateTierOverride);
    var count: ngx_uint_t = 0;
    const pattern = ngx_string("openai");

    try upsertOverride(overrides[0..], &count, pattern, null, 150);
    try upsertOverride(overrides[0..], &count, pattern, 2, null);

    try expectEqual(@as(ngx_uint_t, 1), count);
    try expectEqual(@as(ngx_uint_t, 2), overrides[0].requests_per_minute);
    try expectEqual(@as(ngx_uint_t, 150), overrides[0].tokens_per_minute);
}

// M2 Target 2: returnRequestSlot decrements req_count for rejected-before-send slots.
test "returnRequestSlot decrements consumed slot" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    store.store_size = @sizeOf(llm_ratelimit_store);
    const h = hashBytes("return-slot-key");
    const now_ms: u64 = 8000000;

    // Consume one slot.
    const r1 = checkAndConsume(&store, h, 5, 0, 0, 0, now_ms);
    try std.testing.expect(r1.allowed);

    const found = findEntry(&store, h);
    try std.testing.expect(found != null);
    try expectEqual(@as(u64, 1), found.?.req_count);

    // Return the slot (simulates rejected-before-send in LOG phase).
    returnRequestSlot(&store, h);
    try expectEqual(@as(u64, 0), found.?.req_count);

    // Should allow another request after slot return.
    const r2 = checkAndConsume(&store, h, 1, 0, 0, 0, now_ms);
    try std.testing.expect(r2.allowed);
}

// M2 Target 1: composite key hashes are deterministic and isolate org/project/client scopes.
// Operators build composite keys by combining identity segments in the llm_ratelimit_key var.
// This test verifies that different composite values never hash to the same entry.
test "composite key isolation for org/project/client scopes" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    const now_ms: u64 = 9000000;

    // Simulate org:project:client composite keys.
    const h_org_a_proj_1 = hashBytes("orgA:proj1:client-x");
    const h_org_a_proj_2 = hashBytes("orgA:proj2:client-x");
    const h_org_b_proj_1 = hashBytes("orgB:proj1:client-x");

    // Exhaust quota for orgA/proj1 (RPM=2).
    _ = checkAndConsume(&store, h_org_a_proj_1, 2, 0, 0, 0, now_ms);
    _ = checkAndConsume(&store, h_org_a_proj_1, 2, 0, 0, 0, now_ms);
    const over = checkAndConsume(&store, h_org_a_proj_1, 2, 0, 0, 0, now_ms);
    try std.testing.expect(!over.allowed);

    // orgA/proj2 and orgB/proj1 are unaffected.
    const r2 = checkAndConsume(&store, h_org_a_proj_2, 2, 0, 0, 0, now_ms);
    try std.testing.expect(r2.allowed);
    const r3 = checkAndConsume(&store, h_org_b_proj_1, 2, 0, 0, 0, now_ms);
    try std.testing.expect(r3.allowed);
}

// M2 Target 3: effective model basis selects from the effective_model variable
// when both requested and effective are available (simulated via hash key test only —
// live variable resolution requires nginx context).
test "model_basis constants are distinct" {
    try std.testing.expect(MODEL_BASIS_EFFECTIVE != MODEL_BASIS_REQUESTED);
}

test "entries live only in their owning stripe" {
    var store = std.mem.zeroes(llm_ratelimit_store);
    store.initialized = 1;
    store.store_size = @sizeOf(llm_ratelimit_store);
    const now_ms: u64 = 9100000;

    const a: u64 = 1;
    const b: u64 = 2;
    try std.testing.expect(stripeIndexForHash(a) != stripeIndexForHash(b));

    _ = checkAndConsume(&store, a, 2, 0, 0, 0, now_ms);
    _ = checkAndConsume(&store, b, 2, 0, 0, 0, now_ms);

    try std.testing.expectEqual(@as(ngx_uint_t, 1), store.stripes[stripeIndexForHash(a)].entry_count);
    try std.testing.expectEqual(@as(ngx_uint_t, 1), store.stripes[stripeIndexForHash(b)].entry_count);
}

// M2 Target 5: epochSecsToYearMonth correctness tests.
test "epochSecsToYearMonth known dates" {
    // 2026-06-01 00:00:00 UTC = 1780272000
    try std.testing.expectEqual(@as(u32, 202606), epochSecsToYearMonth(1780272000));
    // 2024-01-01 00:00:00 UTC = 1704067200
    try std.testing.expectEqual(@as(u32, 202401), epochSecsToYearMonth(1704067200));
    // 2024-12-31 23:59:59 UTC = 1735689599
    try std.testing.expectEqual(@as(u32, 202412), epochSecsToYearMonth(1735689599));
    // 2000-02-28 00:00:00 UTC = 951696000
    try std.testing.expectEqual(@as(u32, 200002), epochSecsToYearMonth(951696000));
    // 2000-03-01 00:00:00 UTC = 951868800
    try std.testing.expectEqual(@as(u32, 200003), epochSecsToYearMonth(951868800));
}

test "epochSecsToYearMonth month boundary at midnight" {
    // 2024-01-31 23:59:59 UTC
    const jan_end: i64 = 1706745599;
    // 2024-02-01 00:00:00 UTC
    const feb_start: i64 = 1706745600;
    try std.testing.expectEqual(@as(u32, 202401), epochSecsToYearMonth(jan_end));
    try std.testing.expectEqual(@as(u32, 202402), epochSecsToYearMonth(feb_start));
}

test "epochSecsToYearMonth timezone offset shifts month" {
    // 2026-07-01 00:00:00 UTC = 1782864000.
    // At 2026-06-30 20:00:00 UTC (local = 2026-07-01 04:00:00 UTC+8), month = July.
    const utc_sec: i64 = 1782864000 - 4 * 3600; // 2026-06-30 20:00:00 UTC
    const gmtoff_min: i64 = 480; // UTC+8 in minutes
    const local_sec = utc_sec + gmtoff_min * 60;
    try std.testing.expectEqual(@as(u32, 202607), epochSecsToYearMonth(local_sec));
}

test "buildSpendKey org scope" {
    var key_buf: [512]u8 = undefined;
    const unit = ngx_string("usd");
    var org_data: [5]u8 = "org-1".*;
    const org_id = ngx_str_t{ .data = &org_data, .len = 5 };
    const key = buildSpendKey(&key_buf, SPEND_SCOPE_ORG, unit, org_id, null, null, 202606);
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("spend:org:org-1:usd:202606", key.?);
}

test "buildSpendKey project scope" {
    var key_buf: [512]u8 = undefined;
    const unit = ngx_string("usd");
    var org_data: [5]u8 = "org-1".*;
    var proj_data: [6]u8 = "proj-2".*;
    const org_id = ngx_str_t{ .data = &org_data, .len = 5 };
    const project_id = ngx_str_t{ .data = &proj_data, .len = 6 };
    const key = buildSpendKey(&key_buf, SPEND_SCOPE_PROJECT, unit, org_id, project_id, null, 202606);
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("spend:project:org-1:proj-2:usd:202606", key.?);
}

test "buildSpendKey client scope" {
    var key_buf: [512]u8 = undefined;
    const unit = ngx_string("usd");
    var org_data: [5]u8 = "org-1".*;
    var proj_data: [6]u8 = "proj-2".*;
    var cli_data: [4]u8 = "cli3".*;
    const org_id = ngx_str_t{ .data = &org_data, .len = 5 };
    const project_id = ngx_str_t{ .data = &proj_data, .len = 6 };
    const client_id = ngx_str_t{ .data = &cli_data, .len = 4 };
    const key = buildSpendKey(&key_buf, SPEND_SCOPE_CLIENT, unit, org_id, project_id, client_id, 202606);
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("spend:client:org-1:proj-2:cli3:usd:202606", key.?);
}

test "buildSpendKey org-required: returns null when org_id missing" {
    var key_buf: [512]u8 = undefined;
    const unit = ngx_string("usd");
    const key = buildSpendKey(&key_buf, SPEND_SCOPE_ORG, unit, null, null, null, 202606);
    try std.testing.expect(key == null);
}

test "spend counter accumulates and resets on month rollover" {
    var store = std.mem.zeroes(llm_spend_store);
    store.initialized = 1;
    store.store_size = @sizeOf(llm_spend_store);
    const h = hashBytes("spend:org:org-1:usd:202606");
    const ym_june: u32 = 202606;
    const ym_july: u32 = 202607;
    const now_min: i64 = 10;

    // Accumulate spend in June.
    const e1 = getOrCreateSpendEntry(&store, h, ym_june, now_min);
    e1.spend_micros = 1_000_000; // 1 unit spent

    // Same month: counter persists.
    const e2 = findSpendEntry(&store, h, ym_june, now_min + 1);
    try std.testing.expect(e2 != null);
    try std.testing.expectEqual(@as(u64, 1_000_000), e2.?.spend_micros);

    // Different month (rollover): findSpendEntry returns null (stale).
    const e3 = findSpendEntry(&store, h, ym_july, now_min + 2);
    try std.testing.expect(e3 == null);

    // getOrCreateSpendEntry resets the counter for the new month.
    const e4 = getOrCreateSpendEntry(&store, h, ym_july, now_min + 3);
    try std.testing.expectEqual(@as(u64, 0), e4.spend_micros);
    try std.testing.expectEqual(ym_july, e4.year_month);
}

test "spend budget exhaustion" {
    var store = std.mem.zeroes(llm_spend_store);
    store.initialized = 1;
    const h = hashBytes("spend:org:org-X:usd:202606");
    const ym: u32 = 202606;
    const now_min: i64 = 20;

    // Budget is 5 USD = 5_000_000 micros.
    const budget_micros: u64 = 5_000_000;

    const e = getOrCreateSpendEntry(&store, h, ym, now_min);
    e.spend_micros = budget_micros - 1; // just under budget

    // Under budget: not exhausted.
    const current = findSpendEntry(&store, h, ym, now_min + 1);
    try std.testing.expect(current != null);
    try std.testing.expect(current.?.spend_micros < budget_micros);

    // Push over budget.
    e.spend_micros = budget_micros;
    const over = findSpendEntry(&store, h, ym, now_min + 2);
    try std.testing.expect(over != null);
    try std.testing.expect(over.?.spend_micros >= budget_micros);
}

test "spend stripes are independent" {
    var store = std.mem.zeroes(llm_spend_store);
    store.initialized = 1;
    const h1 = hashBytes("spend:org:org-A:usd:202606");
    const h2 = hashBytes("spend:org:org-B:usd:202606");
    const ym: u32 = 202606;
    const now_min: i64 = 30;

    if (spendStripeIndexForHash(h1) == spendStripeIndexForHash(h2)) return; // skip if same stripe

    const e1 = getOrCreateSpendEntry(&store, h1, ym, now_min);
    e1.spend_micros = 1_000_000;
    const e2 = getOrCreateSpendEntry(&store, h2, ym, now_min + 1);
    e2.spend_micros = 2_000_000;

    try std.testing.expectEqual(@as(u64, 1_000_000), (findSpendEntry(&store, h1, ym, now_min + 2) orelse unreachable).spend_micros);
    try std.testing.expectEqual(@as(u64, 2_000_000), (findSpendEntry(&store, h2, ym, now_min + 3) orelse unreachable).spend_micros);
}

test "spend entry eviction uses least recently used current-month entry" {
    var store = std.mem.zeroes(llm_spend_store);
    store.initialized = 1;
    const ym: u32 = 202606;
    const stripe_idx: u64 = 7;

    var hashes: [SPEND_ENTRIES_PER_STRIPE]u64 = undefined;
    var i: usize = 0;
    while (i < SPEND_ENTRIES_PER_STRIPE) : (i += 1) {
        const h = stripe_idx | (@as(u64, i + 1) << 6);
        hashes[i] = h;
        const e = getOrCreateSpendEntry(&store, h, ym, @as(i64, @intCast(100 + i)));
        e.spend_micros = @as(u64, i + 1);
    }

    _ = findSpendEntry(&store, hashes[0], ym, 1_000);
    const replacement_hash = stripe_idx | (@as(u64, SPEND_ENTRIES_PER_STRIPE + 1) << 6);
    _ = getOrCreateSpendEntry(&store, replacement_hash, ym, 2_000);

    try std.testing.expect(findSpendEntry(&store, hashes[0], ym, 2_001) != null);
    try std.testing.expect(findSpendEntry(&store, hashes[1], ym, 2_002) == null);
    try std.testing.expect(findSpendEntry(&store, replacement_hash, ym, 2_003) != null);
}
