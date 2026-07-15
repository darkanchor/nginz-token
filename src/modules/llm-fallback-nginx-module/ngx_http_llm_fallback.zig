const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const log = ngx.log;

const ngx_flag_t = core.ngx_flag_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_str_t = core.ngx_str_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_string = ngx.string.ngx_string;

const FALLBACK_MODE_UNSET: ngx_uint_t = 0;
const FALLBACK_MODE_BASIC: ngx_uint_t = 1;
// ADVANCED = 2 belongs to Phase 5; the directive handler rejects it explicitly.

// Phase 3: failure class bitmask constants.
pub const FALLBACK_CLASS_CONNECT_ERROR: ngx_uint_t = 1 << 0;
pub const FALLBACK_CLASS_TRANSPORT_TIMEOUT: ngx_uint_t = 1 << 1;
pub const FALLBACK_CLASS_RATE_LIMITED: ngx_uint_t = 1 << 2;
pub const FALLBACK_CLASS_UPSTREAM_5XX: ngx_uint_t = 1 << 3;

pub const FALLBACK_REASON_NONE: ngx_uint_t = 0;
pub const FALLBACK_REASON_CONNECT_ERROR: ngx_uint_t = 1;
pub const FALLBACK_REASON_TRANSPORT_TIMEOUT: ngx_uint_t = 2;
pub const FALLBACK_REASON_RATE_LIMITED: ngx_uint_t = 3;
pub const FALLBACK_REASON_UPSTREAM_5XX: ngx_uint_t = 4;

const MAX_FALLBACK_ROUTES: usize = 16;
const MAX_FALLBACK_REPLACES: usize = 16;

// Milestone 2 Target 3: translation fallback policy values.
pub const TRANSLATION_FALLBACK_ALLOW: ngx_uint_t = 0;      // default: cross-dialect fallback allowed
pub const TRANSLATION_FALLBACK_DISCOURAGE: ngx_uint_t = 1; // allowed but marked as policy_mismatch
pub const TRANSLATION_FALLBACK_FORBID: ngx_uint_t = 2;     // cross-dialect fallback forbidden; mark suppressed

// Milestone 2 Target 2: optional model override on a fallback route.
// target_model is empty for routes without a model override (provider-only replacement).
const FallbackRoute = extern struct {
    primary: ngx_str_t,
    secondary: ngx_str_t,
    target_model: ngx_str_t,
};

// Milestone 2 Target 1: pre-send replacement rule.
// When the gateway would route to `provider`, replace it with `replacement` BEFORE the first send.
// This is distinct from `FallbackRoute` which only activates AFTER a classified failure.
const FallbackReplace = extern struct {
    provider: ngx_str_t,
    replacement: ngx_str_t,
};

const llm_fallback_loc_conf = extern struct {
    enabled: ngx_flag_t,
    mode: ngx_uint_t,
    max_attempts: ngx_uint_t,
    routes: [MAX_FALLBACK_ROUTES]FallbackRoute,
    routes_count: ngx_uint_t,
    // Phase 3: failure taxonomy
    on_classes: ngx_uint_t, // bitmask of FALLBACK_CLASS_* bits; 0 = nothing retryable
    allow_streaming: ngx_flag_t, // NGX_CONF_UNSET → 0 (streaming fallback off by default)
    // Milestone 2 Target 1: pre-send replacement rules
    replaces: [MAX_FALLBACK_REPLACES]FallbackReplace,
    replaces_count: ngx_uint_t,
    // Milestone 2 Target 3: translation fallback policy
    translation_fallback: ngx_uint_t, // TRANSLATION_FALLBACK_*; default ALLOW (0)
};

fn is_retryable_status_with_classes(status: ngx_uint_t, on_classes: ngx_uint_t) ngx_flag_t {
    // status==0 means nginx observed a transport-level failure before any HTTP
    // response status existed. The status-only API cannot distinguish
    // connect_error from transport_timeout, so treat 0 as a generic transport
    // failure that matches either configured transport class.
    if (status == 0 and
        (on_classes & (FALLBACK_CLASS_CONNECT_ERROR | FALLBACK_CLASS_TRANSPORT_TIMEOUT)) != 0)
    {
        return 1;
    }
    if (status == 429 and (on_classes & FALLBACK_CLASS_RATE_LIMITED) != 0) return 1;
    if (status >= 500 and status < 600 and (on_classes & FALLBACK_CLASS_UPSTREAM_5XX) != 0) return 1;
    return 0;
}

fn str_eq(a: ngx_str_t, b: ngx_str_t) bool {
    const as = core.slicify(u8, a.data, a.len);
    const bs = core.slicify(u8, b.data, b.len);
    return std.mem.eql(u8, as, bs);
}

fn has_duplicate_primary(routes: *const [MAX_FALLBACK_ROUTES]FallbackRoute, count: usize) bool {
    for (0..count) |i| {
        for (i + 1..count) |j| {
            if (str_eq(routes[i].primary, routes[j].primary)) return true;
        }
    }
    return false;
}

fn has_cycle(routes: *const [MAX_FALLBACK_ROUTES]FallbackRoute, count: usize) bool {
    // Each primary is unique (enforced by has_duplicate_primary). The graph is a
    // directed forest: each node has at most one outgoing edge. Use a visited-set
    // DFS to detect cycles. A u16 bitmask suffices since MAX_FALLBACK_ROUTES=16.
    for (0..count) |start_idx| {
        var visited: u16 = @as(u16, 1) << @intCast(start_idx);
        var current = routes[start_idx].secondary;
        while (true) {
            var next_idx: ?usize = null;
            for (0..count) |j| {
                if (str_eq(routes[j].primary, current)) {
                    next_idx = j;
                    break;
                }
            }
            const j = next_idx orelse break; // dead end — no cycle from this start
            if ((visited >> @intCast(j)) & 1 != 0) return true; // revisited — cycle
            visited |= @as(u16, 1) << @intCast(j);
            current = routes[j].secondary;
        }
    }
    return false;
}

fn cast(loc: ?*anyopaque) ?*llm_fallback_loc_conf {
    return @ptrCast(core.castPtr(llm_fallback_loc_conf, loc));
}

// ── Exported policy API (consumed by llm-proxy) ───────────────────────────────

// Milestone 2 Target 1: look up the pre-send replacement provider for the given effective provider.
// Returns the replacement provider name, or empty_str if no replacement rule applies.
// Called from llm-proxy body handler BEFORE the first upstream send and BEFORE translation.
export fn ngx_http_llm_fallback_lookup_replacement(
    r: [*c]ngx_http_request_t,
    provider: ngx_str_t,
) ngx_str_t {
    const empty = ngx_str_t{ .len = 0, .data = @constCast("") };
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse return empty;
    if (lccf.enabled != 1 or lccf.replaces_count == 0) return empty;
    if (provider.len == 0) return empty;

    const n: usize = @intCast(lccf.replaces_count);
    for (0..n) |i| {
        if (str_eq(lccf.replaces[i].provider, provider)) return lccf.replaces[i].replacement;
    }
    return empty;
}

// FallbackRouteLookup is the combined result for a single route table scan.
// Use ngx_http_llm_fallback_lookup_route() instead of calling lookup_secondary and
// lookup_secondary_model separately — they scan the same table and fetch the same loc_conf.
// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
pub const FallbackRouteLookup = contract.FallbackRouteLookup;

// Returns secondary and target_model for the matching primary in one scan.
export fn ngx_http_llm_fallback_lookup_route(
    r: [*c]ngx_http_request_t,
    primary: ngx_str_t,
) FallbackRouteLookup {
    const empty = ngx_str_t{ .len = 0, .data = @constCast("") };
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse
        return .{ .secondary = empty, .target_model = empty };
    if (lccf.enabled != 1 or lccf.routes_count == 0 or primary.len == 0)
        return .{ .secondary = empty, .target_model = empty };

    const n: usize = @intCast(lccf.routes_count);
    for (0..n) |i| {
        if (str_eq(lccf.routes[i].primary, primary)) return .{
            .secondary = lccf.routes[i].secondary,
            .target_model = lccf.routes[i].target_model,
        };
    }
    return .{ .secondary = empty, .target_model = empty };
}

// Milestone 2 Target 2: look up the optional model override for a fallback route's secondary.
// Returns the target_model from the matching route, or empty_str if no override (provider-only route).
// Called from llm-proxy detect_fallback_outcome to update effective_model after a retry.
export fn ngx_http_llm_fallback_lookup_secondary_model(
    r: [*c]ngx_http_request_t,
    primary: ngx_str_t,
) ngx_str_t {
    const empty = ngx_str_t{ .len = 0, .data = @constCast("") };
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse return empty;
    if (lccf.enabled != 1) return empty;

    const n: usize = @intCast(lccf.routes_count);
    for (0..n) |i| {
        if (str_eq(lccf.routes[i].primary, primary)) return lccf.routes[i].target_model;
    }
    return empty;
}

// Milestone 2 Target 3: return the configured translation fallback policy.
// TRANSLATION_FALLBACK_ALLOW (0): cross-dialect retry is allowed (default).
// TRANSLATION_FALLBACK_DISCOURAGE (1): cross-dialect retry is allowed but marked as policy_mismatch.
// TRANSLATION_FALLBACK_FORBID (2): cross-dialect retry is treated as policy violation; suppressed in outcomes.
export fn ngx_http_llm_fallback_translation_policy(
    r: [*c]ngx_http_request_t,
) ngx_uint_t {
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse return TRANSLATION_FALLBACK_ALLOW;
    if (lccf.enabled != 1) return TRANSLATION_FALLBACK_ALLOW;
    return lccf.translation_fallback;
}

// Returns the secondary provider for the given primary, or empty_str if no route.
export fn ngx_http_llm_fallback_lookup_secondary(
    r: [*c]ngx_http_request_t,
    primary: ngx_str_t,
) ngx_str_t {
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse
        return ngx_str_t{ .len = 0, .data = @constCast("") };
    if (lccf.enabled != 1) return ngx_str_t{ .len = 0, .data = @constCast("") };

    const n: usize = @intCast(lccf.routes_count);
    for (0..n) |i| {
        if (str_eq(lccf.routes[i].primary, primary)) return lccf.routes[i].secondary;
    }
    return ngx_str_t{ .len = 0, .data = @constCast("") };
}

// Returns 1 if the given upstream HTTP status is retryable under current policy.
// status=0 means connect error (no HTTP response received).
// is_streaming=1 suppresses retry when allow_streaming=off (the default).
export fn ngx_http_llm_fallback_is_retryable(
    r: [*c]ngx_http_request_t,
    status: ngx_uint_t,
    is_streaming: ngx_flag_t,
) ngx_flag_t {
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse return 0;
    if (lccf.enabled != 1 or lccf.on_classes == 0) return 0;

    // Streaming fallback is suppressed by default.
    if (is_streaming == 1 and lccf.allow_streaming != 1) return 0;

    return is_retryable_status_with_classes(status, lccf.on_classes);
}

// Returns the configured max_attempts limit (0 if unset or disabled).
// Callers must keep proxy_next_upstream_tries in sync with this value.
export fn ngx_http_llm_fallback_max_attempts_limit(
    r: [*c]ngx_http_request_t,
) ngx_uint_t {
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse return 0;
    if (lccf.enabled != 1) return 0;
    return lccf.max_attempts;
}

export fn ngx_http_llm_fallback_is_reason_retryable(
    r: [*c]ngx_http_request_t,
    reason: ngx_uint_t,
    is_streaming: ngx_flag_t,
) ngx_flag_t {
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_fallback_module)) orelse return 0;
    if (lccf.enabled != 1 or lccf.on_classes == 0) return 0;

    if (is_streaming == 1 and lccf.allow_streaming != 1) return 0;

    return switch (reason) {
        FALLBACK_REASON_CONNECT_ERROR => if ((lccf.on_classes & FALLBACK_CLASS_CONNECT_ERROR) != 0) 1 else 0,
        FALLBACK_REASON_TRANSPORT_TIMEOUT => if ((lccf.on_classes & FALLBACK_CLASS_TRANSPORT_TIMEOUT) != 0) 1 else 0,
        FALLBACK_REASON_RATE_LIMITED => if ((lccf.on_classes & FALLBACK_CLASS_RATE_LIMITED) != 0) 1 else 0,
        FALLBACK_REASON_UPSTREAM_5XX => if ((lccf.on_classes & FALLBACK_CLASS_UPSTREAM_5XX) != 0) 1 else 0,
        else => 0,
    };
}

// ── Configuration callbacks ───────────────────────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(llm_fallback_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.allow_streaming = conf.NGX_CONF_UNSET;
        // mode, max_attempts, routes_count, on_classes, replaces_count, translation_fallback all zero from pcalloc
        return p;
    }
    return null;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    const prev = cast(parent) orelse return conf.NGX_CONF_OK;
    const c = cast(child) orelse return conf.NGX_CONF_OK;

    if (c.enabled == conf.NGX_CONF_UNSET) {
        c.enabled = if (prev.enabled == conf.NGX_CONF_UNSET) 0 else prev.enabled;
    }
    if (c.mode == FALLBACK_MODE_UNSET) {
        c.mode = prev.mode;
    }
    if (c.max_attempts == 0) {
        c.max_attempts = prev.max_attempts;
    }
    if (c.routes_count == 0 and prev.routes_count > 0) {
        const n: usize = @intCast(prev.routes_count);
        for (0..n) |i| {
            c.routes[i] = prev.routes[i];
        }
        c.routes_count = prev.routes_count;
    }
    // Phase 3: inherit failure taxonomy.
    if (c.on_classes == 0 and prev.on_classes != 0) {
        c.on_classes = prev.on_classes;
    }
    if (c.allow_streaming == conf.NGX_CONF_UNSET) {
        c.allow_streaming = if (prev.allow_streaming == conf.NGX_CONF_UNSET) 0 else prev.allow_streaming;
    }
    // Milestone 2 Target 1: inherit pre-send replacement rules.
    if (c.replaces_count == 0 and prev.replaces_count > 0) {
        const nr: usize = @intCast(prev.replaces_count);
        for (0..nr) |i| {
            c.replaces[i] = prev.replaces[i];
        }
        c.replaces_count = prev.replaces_count;
    }
    // Milestone 2 Target 3: inherit translation fallback policy.
    if (c.translation_fallback == TRANSLATION_FALLBACK_ALLOW and prev.translation_fallback != TRANSLATION_FALLBACK_ALLOW) {
        c.translation_fallback = prev.translation_fallback;
    }

    const n: usize = @intCast(c.routes_count);

    if (has_duplicate_primary(&c.routes, n)) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_route: duplicate primary provider; each provider may appear as primary at most once", .{});
        return conf.NGX_CONF_ERROR;
    }

    if (has_cycle(&c.routes, n)) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_route: cyclic fallback graph detected; routes must form a directed acyclic chain", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

// ── Directive handlers ────────────────────────────────────────────────────────

fn ngx_conf_set_llm_fallback(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (cast(loc)) |lccf| lccf.enabled = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_fallback_route(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    if (lccf.routes_count >= MAX_FALLBACK_ROUTES) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_route: route limit reached (max 16)", .{});
        return conf.NGX_CONF_ERROR;
    }

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const primary = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const secondary = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    // Milestone 2 Target 2: optional 3rd arg is a model override for the fallback target.
    const target_model_opt = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);

    const slot: usize = @intCast(lccf.routes_count);
    lccf.routes[slot].primary = primary.*;
    lccf.routes[slot].secondary = secondary.*;
    lccf.routes[slot].target_model = if (target_model_opt) |m| m.* else ngx_str_t{ .len = 0, .data = @constCast("") };
    lccf.routes_count += 1;

    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 1: `llm_fallback_replace <provider> <replacement>;`
// Registers a pre-send replacement rule: when llm-proxy resolves `provider` as the first-hop
// target, it is replaced by `replacement` BEFORE auth preparation, translation, and upstream send.
// Unlike llm_fallback_route (which fires AFTER a failure), this fires on every matching request.
fn ngx_conf_set_llm_fallback_replace(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    if (lccf.replaces_count >= MAX_FALLBACK_REPLACES) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_replace: replacement limit reached (max 16)", .{});
        return conf.NGX_CONF_ERROR;
    }

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const replacement = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    const slot: usize = @intCast(lccf.replaces_count);
    lccf.replaces[slot].provider = provider.*;
    lccf.replaces[slot].replacement = replacement.*;
    lccf.replaces_count += 1;

    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 3: `llm_fallback_translation_fallback allow|discourage|forbid;`
fn ngx_conf_set_llm_fallback_translation_fallback(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);

    if (std.mem.eql(u8, s, "allow")) {
        lccf.translation_fallback = TRANSLATION_FALLBACK_ALLOW;
    } else if (std.mem.eql(u8, s, "discourage")) {
        lccf.translation_fallback = TRANSLATION_FALLBACK_DISCOURAGE;
    } else if (std.mem.eql(u8, s, "forbid")) {
        lccf.translation_fallback = TRANSLATION_FALLBACK_FORBID;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_translation_fallback: unknown value; expected allow, discourage, or forbid", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_fallback_mode(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);

    if (std.mem.eql(u8, s, "basic")) {
        lccf.mode = FALLBACK_MODE_BASIC;
    } else if (std.mem.eql(u8, s, "advanced")) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_mode: advanced mode is not yet supported (Phase 5)", .{});
        return conf.NGX_CONF_ERROR;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_mode: unknown mode; supported values are: basic", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_fallback_max_attempts(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);
    const n = std.fmt.parseInt(ngx_uint_t, s, 10) catch {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_max_attempts: invalid value; expected a positive integer", .{});
        return conf.NGX_CONF_ERROR;
    };
    if (n == 0) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_max_attempts: value must be at least 1", .{});
        return conf.NGX_CONF_ERROR;
    }
    lccf.max_attempts = n;

    return conf.NGX_CONF_OK;
}

// Phase 3: `llm_fallback_on <class> [<class> ...];`
// Accepted tokens: connect_error transport_timeout rate_limited upstream_5xx
fn ngx_conf_set_llm_fallback_on(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    // args[0] = directive name; args[1..] = failure class tokens.
    const args_arr = cf.*.args;
    const nargs = args_arr.*.nelts;
    const elts = core.castPtr(ngx_str_t, args_arr.*.elts) orelse return conf.NGX_CONF_ERROR;

    var idx: usize = 1;
    while (idx < nargs) : (idx += 1) {
        const token = core.slicify(u8, elts[idx].data, elts[idx].len);
        if (std.mem.eql(u8, token, "connect_error")) {
            lccf.on_classes |= FALLBACK_CLASS_CONNECT_ERROR;
        } else if (std.mem.eql(u8, token, "transport_timeout")) {
            lccf.on_classes |= FALLBACK_CLASS_TRANSPORT_TIMEOUT;
        } else if (std.mem.eql(u8, token, "rate_limited")) {
            lccf.on_classes |= FALLBACK_CLASS_RATE_LIMITED;
        } else if (std.mem.eql(u8, token, "upstream_5xx")) {
            lccf.on_classes |= FALLBACK_CLASS_UPSTREAM_5XX;
        } else {
            log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
                "llm_fallback_on: unknown failure class '%V'; supported: connect_error transport_timeout rate_limited upstream_5xx",
                .{&elts[idx]});
            return conf.NGX_CONF_ERROR;
        }
    }

    return conf.NGX_CONF_OK;
}

// Phase 3: `llm_fallback_allow_streaming on|off;`
fn ngx_conf_set_llm_fallback_allow_streaming(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const s = core.slicify(u8, arg.*.data, arg.*.len);

    if (std.mem.eql(u8, s, "on")) {
        lccf.allow_streaming = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.allow_streaming = 0;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0,
            "llm_fallback_allow_streaming: invalid value; expected on or off", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

// ── Module wiring ─────────────────────────────────────────────────────────────

export const ngx_http_llm_fallback_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_fallback_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_fallback"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_fallback,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        // Milestone 2 Target 2: optional 3rd arg is a target model override.
        .name = ngx_string("llm_fallback_route"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE23,
        .set = ngx_conf_set_llm_fallback_route,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_fallback_mode"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_fallback_mode,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_fallback_max_attempts"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_fallback_max_attempts,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_fallback_on"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_1MORE,
        .set = ngx_conf_set_llm_fallback_on,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_fallback_allow_streaming"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_fallback_allow_streaming,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Milestone 2 Target 1: pre-send replacement rule.
    ngx_command_t{
        .name = ngx_string("llm_fallback_replace"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_llm_fallback_replace,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Milestone 2 Target 3: translation fallback policy.
    ngx_command_t{
        .name = ngx_string("llm_fallback_translation_fallback"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_fallback_translation_fallback,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_llm_fallback_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_fallback_commands),
    @constCast(&ngx_http_llm_fallback_module_ctx),
);

// ── Unit tests ────────────────────────────────────────────────────────────────

fn test_str(s: []const u8) ngx_str_t {
    return ngx_str_t{ .data = @constCast(s.ptr), .len = s.len };
}

fn test_route(primary: []const u8, secondary: []const u8) FallbackRoute {
    return FallbackRoute{
        .primary = test_str(primary),
        .secondary = test_str(secondary),
        .target_model = test_str(""),
    };
}

test "has_cycle: two-node cycle A→B→A is detected" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("A", "B");
    routes[1] = test_route("B", "A");
    try std.testing.expect(has_cycle(&routes, 2));
}

test "has_cycle: three-node cycle A→B→C→A is detected" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("A", "B");
    routes[1] = test_route("B", "C");
    routes[2] = test_route("C", "A");
    try std.testing.expect(has_cycle(&routes, 3));
}

test "has_cycle: embedded cycle B→C→B with external entry A→B is detected" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("A", "B");
    routes[1] = test_route("B", "C");
    routes[2] = test_route("C", "B");
    try std.testing.expect(has_cycle(&routes, 3));
}

test "has_cycle: linear chain A→B→C→D is not a false positive" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("A", "B");
    routes[1] = test_route("B", "C");
    routes[2] = test_route("C", "D");
    try std.testing.expect(!has_cycle(&routes, 3));
}

test "has_cycle: longer chain of four routes is not a false positive" {
    // A→B→C→D→E (4 routes). Starting from A, the traversal makes 3 successful
    // hops (B→C, C→D, D→E) and then terminates because E has no route.
    // Verifies no false positive from a chain that reaches routes_count-1 hops.
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("A", "B");
    routes[1] = test_route("B", "C");
    routes[2] = test_route("C", "D");
    routes[3] = test_route("D", "E");
    try std.testing.expect(!has_cycle(&routes, 4));
}

test "has_cycle: disconnected acyclic routes are not false positives" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("openai", "anthropic");
    routes[1] = test_route("bedrock", "azure");
    try std.testing.expect(!has_cycle(&routes, 2));
}

test "has_cycle: single route is never a cycle" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("openai", "anthropic");
    try std.testing.expect(!has_cycle(&routes, 1));
}

test "has_duplicate_primary: detects duplicate primary in route list" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("openai", "anthropic");
    routes[1] = test_route("openai", "bedrock");
    try std.testing.expect(has_duplicate_primary(&routes, 2));
}

test "has_duplicate_primary: unique primaries return false" {
    var routes = std.mem.zeroes([MAX_FALLBACK_ROUTES]FallbackRoute);
    routes[0] = test_route("openai", "anthropic");
    routes[1] = test_route("anthropic", "bedrock");
    try std.testing.expect(!has_duplicate_primary(&routes, 2));
}

test "status-based retryability treats status=0 as generic transport failure" {
    try std.testing.expectEqual(@as(ngx_flag_t, 1), is_retryable_status_with_classes(0, FALLBACK_CLASS_CONNECT_ERROR));
    try std.testing.expectEqual(@as(ngx_flag_t, 1), is_retryable_status_with_classes(0, FALLBACK_CLASS_TRANSPORT_TIMEOUT));
    try std.testing.expectEqual(@as(ngx_flag_t, 1), is_retryable_status_with_classes(0, FALLBACK_CLASS_CONNECT_ERROR | FALLBACK_CLASS_TRANSPORT_TIMEOUT));
    try std.testing.expectEqual(@as(ngx_flag_t, 0), is_retryable_status_with_classes(0, FALLBACK_CLASS_RATE_LIMITED));
}
