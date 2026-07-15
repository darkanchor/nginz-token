const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const log = ngx.log;
const file = ngx.file;

const ngx_flag_t = core.ngx_flag_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_str_t = core.ngx_str_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;
const ngx_string = ngx.string.ngx_string;

// M2 Target 1: main config holds pre-indexed llm-proxy variable indices.
const llm_security_main_conf = extern struct {
    llm_translation_happened_idx: ngx_int_t, // $llm_translation_happened (set by llm-proxy)
    llm_body_parsed_idx: ngx_int_t, // $llm_body_parsed (set by llm-proxy)
};

const SECURITY_MODE_UNSET: ngx_uint_t = 0;
const SECURITY_MODE_DETECT: ngx_uint_t = 1;
const SECURITY_MODE_BLOCK: ngx_uint_t = 2;
const SECURITY_MODE_REDACT: ngx_uint_t = 3; // Phase 4: allowed when inspect_response=on

const SECURITY_ACTION_NONE: ngx_uint_t = 0;
const SECURITY_ACTION_DETECT: ngx_uint_t = 1;
const SECURITY_ACTION_BLOCK: ngx_uint_t = 2;
const SECURITY_ACTION_REDACT: ngx_uint_t = 3;

const MAX_SECURITY_RULES: usize = 64;

const SecurityRule = extern struct {
    id: ngx_str_t,
    pattern: ngx_str_t,
    action: ngx_uint_t,
};

const llm_security_loc_conf = extern struct {
    enabled: ngx_flag_t,
    mode: ngx_uint_t,
    rules_file: ngx_str_t,
    org_rules_file: ngx_str_t,
    project_rules_file: ngx_str_t,
    fail_closed: ngx_flag_t,
    inspect_response: ngx_flag_t,
    rules: [*c]SecurityRule, // pool-allocated, null if no rules loaded
    rules_count: ngx_uint_t,
    org_var_index: ngx_int_t,
    project_var_index: ngx_int_t,
    policy_source: ngx_str_t,
    reject_oversized_request: ngx_flag_t,
    reject_oversized_response: ngx_flag_t,
};

// Per-request security outcome; allocated lazily on first inspect call.
const LlmSecurityCtx = extern struct {
    detected: ngx_flag_t,
    blocked: ngx_flag_t,
    rule_id: ngx_str_t,
    action: ngx_uint_t,
    // Phase 4: response-phase outcome
    response_detected: ngx_flag_t,
    response_blocked: ngx_flag_t,
    response_rule_id: ngx_str_t,
    response_action: ngx_uint_t,
    // M2 Target 1: path observability — was this request translated?
    translation_happened: ngx_flag_t,
    org: ngx_str_t,
    project: ngx_str_t,
    policy_source: ngx_str_t,
};

// Cross-module outcome struct; exported for llm-proxy consumption.
// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
pub const LlmSecurityOutcome = contract.LlmSecurityOutcome;

const empty_str = ngx_str_t{ .len = 0, .data = @constCast("") };

fn cast(loc: ?*anyopaque) ?*llm_security_loc_conf {
    return @ptrCast(core.castPtr(llm_security_loc_conf, loc));
}

fn get_ctx(r: [*c]ngx_http_request_t) ?[*c]LlmSecurityCtx {
    return core.castPtr(LlmSecurityCtx, r.*.ctx[ngx_http_llm_security_module.ctx_index]);
}

fn get_main_conf(r: [*c]ngx_http_request_t) ?*llm_security_main_conf {
    return @ptrCast(@alignCast(core.castPtr(
        llm_security_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_llm_security_module),
    )));
}

fn resolveUintVar(r: [*c]ngx_http_request_t, idx: core.ngx_int_t) ?ngx_uint_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    const s = core.slicify(u8, val.*.data, val.*.flags.len);
    return std.fmt.parseInt(ngx_uint_t, s, 10) catch null;
}

fn resolveStrVar(r: [*c]ngx_http_request_t, idx: core.ngx_int_t) ?ngx_str_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    return ngx_str_t{ .data = val.*.data, .len = val.*.flags.len };
}

fn action_strength(action: ngx_uint_t) ngx_uint_t {
    return switch (action) {
        SECURITY_ACTION_DETECT => 1,
        SECURITY_ACTION_REDACT => 2,
        SECURITY_ACTION_BLOCK => 3,
        else => 0,
    };
}

fn action_name(action: ngx_uint_t) ngx_str_t {
    return switch (action) {
        SECURITY_ACTION_DETECT => ngx_string("detect"),
        SECURITY_ACTION_BLOCK => ngx_string("block"),
        SECURITY_ACTION_REDACT => ngx_string("redact"),
        else => ngx_string("none"),
    };
}

// ── Rules file parsing ────────────────────────────────────────────────────────

fn parse_rule_action(raw: []const u8, default_action: ngx_uint_t) ?ngx_uint_t {
    if (raw.len == 0) return default_action;
    if (std.mem.eql(u8, raw, "detect")) return SECURITY_ACTION_DETECT;
    if (std.mem.eql(u8, raw, "block")) return SECURITY_ACTION_BLOCK;
    if (std.mem.eql(u8, raw, "redact")) return SECURITY_ACTION_REDACT;
    return null;
}

// Parse a rules file whose content has already been read into `content`.
// Format:
//   RULE_ID:literal_pattern
//   RULE_ID|detect:literal_pattern
//   RULE_ID|block:literal_pattern
//   RULE_ID|redact:literal_pattern
fn parse_rules(
    content: ngx_str_t,
    rules_arr: [*c]SecurityRule,
    pool: [*c]core.ngx_pool_t,
    default_action: ngx_uint_t,
    count_out: *ngx_uint_t,
) bool {
    count_out.* = 0;
    const text = core.slicify(u8, content.data, content.len);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (count_out.* >= MAX_SECURITY_RULES) return false;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const lhs = std.mem.trim(u8, line[0..colon], " \t");
        const pattern_s = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (lhs.len == 0 or pattern_s.len == 0) return false;

        const pipe = std.mem.indexOfScalar(u8, lhs, '|');
        const rule_id_s = if (pipe) |p| std.mem.trim(u8, lhs[0..p], " \t") else lhs;
        const action_s = if (pipe) |p| std.mem.trim(u8, lhs[p + 1 ..], " \t") else "";
        const action = parse_rule_action(action_s, default_action) orelse return false;
        if (rule_id_s.len == 0) return false;

        // Allocate pool copies of id and pattern.
        const id_buf = core.ngx_pnalloc(pool, rule_id_s.len) orelse return false;
        const id_ptr = core.castPtr(u8, id_buf) orelse return false;
        @memcpy(id_ptr[0..rule_id_s.len], rule_id_s);

        // Store lowercase copy of pattern for case-insensitive matching.
        const pat_buf = core.ngx_pnalloc(pool, pattern_s.len) orelse return false;
        const pat_ptr = core.castPtr(u8, pat_buf) orelse return false;
        for (pattern_s, 0..) |ch, i| pat_ptr[i] = std.ascii.toLower(ch);

        rules_arr[count_out.*] = SecurityRule{
            .id = ngx_str_t{ .data = id_ptr, .len = rule_id_s.len },
            .pattern = ngx_str_t{ .data = pat_ptr, .len = pattern_s.len },
            .action = action,
        };
        count_out.* += 1;
    }
    return true;
}

// Load rules file from the given path into the supplied rule array.
fn load_rules(
    cf: [*c]ngx_conf_t,
    path: ngx_str_t,
    rules_arr: [*c]SecurityRule,
    default_action: ngx_uint_t,
    count_out: *ngx_uint_t,
) bool {
    const content = file.ngz_open_file(path, cf.*.log, cf.*.pool) catch {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: failed to open rules file: %V", .{&path});
        return false;
    };
    return parse_rules(content, rules_arr, cf.*.pool, default_action, count_out);
}

// ── Pattern matching ──────────────────────────────────────────────────────────

// Case-insensitive substring search.
fn contains_ci(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != nc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn str_eq_ci(a: ngx_str_t, b: ngx_str_t) bool {
    if (a.len != b.len) return false;
    return std.ascii.eqlIgnoreCase(
        core.slicify(u8, a.data, a.len),
        core.slicify(u8, b.data, b.len),
    );
}

fn merge_layered_rules(
    cf: [*c]ngx_conf_t,
    lccf: *llm_security_loc_conf,
    org_rules: [*c]SecurityRule,
    org_count: ngx_uint_t,
    project_rules: [*c]SecurityRule,
    project_count: ngx_uint_t,
) bool {
    const merged = core.ngz_pcalloc_n(@intCast(MAX_SECURITY_RULES), SecurityRule, cf.*.pool) orelse return false;
    var merged_count: ngx_uint_t = 0;

    var i: ngx_uint_t = 0;
    while (i < org_count) : (i += 1) {
        merged[merged_count] = org_rules[i];
        merged_count += 1;
    }

    i = 0;
    while (i < project_count) : (i += 1) {
        const pr = project_rules[i];
        var found: ?usize = null;
        var j: usize = 0;
        while (j < merged_count) : (j += 1) {
            if (str_eq_ci(merged[j].id, pr.id)) {
                found = j;
                break;
            }
        }
        if (found) |idx| {
            const org_rule = merged[idx];
            if (!str_eq_ci(org_rule.pattern, pr.pattern)) {
                log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_project_rules_file: rule '%V' must keep the org pattern; add a new rule id for project-specific narrowing", .{&pr.id});
                return false;
            }
            if (action_strength(pr.action) < action_strength(org_rule.action)) {
                const org_action = action_name(org_rule.action);
                const project_action = action_name(pr.action);
                log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_project_rules_file: rule '%V' cannot weaken org policy (%V -> %V)", .{ &pr.id, &org_action, &project_action });
                return false;
            }
            merged[idx].action = pr.action;
        } else {
            if (merged_count >= MAX_SECURITY_RULES) return false;
            merged[merged_count] = pr;
            merged_count += 1;
        }
    }

    lccf.rules = merged;
    lccf.rules_count = merged_count;
    lccf.policy_source = if (project_count > 0) ngx_string("org+project") else ngx_string("org");
    return true;
}

// Returns index of strongest matching rule or rules_count if none matched.
// Stops early when a block match (the strongest possible action) is found.
fn first_match(lccf: *const llm_security_loc_conf, text: []const u8) ngx_uint_t {
    const max_strength = action_strength(SECURITY_ACTION_BLOCK);
    var i: ngx_uint_t = 0;
    var best_idx = lccf.rules_count;
    var best_strength: ngx_uint_t = 0;
    while (i < lccf.rules_count) : (i += 1) {
        const rule = &lccf.rules[i];
        const pat = core.slicify(u8, rule.pattern.data, rule.pattern.len);
        if (!contains_ci(text, pat)) continue;
        const strength = action_strength(rule.action);
        if (best_idx == lccf.rules_count or strength > best_strength) {
            best_idx = i;
            best_strength = strength;
            if (best_strength >= max_strength) break;
        }
    }
    return best_idx; // no match when == rules_count
}

// ── Response body redaction ───────────────────────────────────────────────────

// Replace ALL case-insensitive occurrences of pattern in body with "[REDACTED]".
// Returns the modified body, or null when a matching body cannot be redacted.
fn redact_body(r: [*c]ngx_http_request_t, body: ngx_str_t, pattern: ngx_str_t) ?ngx_str_t {
    if (body.len == 0 or pattern.len == 0) return body;
    const haystack = core.slicify(u8, body.data, body.len);
    const needle = core.slicify(u8, pattern.data, pattern.len);
    if (haystack.len < needle.len) return body;

    const redacted = "[REDACTED]";

    // First pass: count matches and compute new length.
    var match_count: usize = 0;
    var scan: usize = 0;
    while (scan <= haystack.len - needle.len) {
        var matched = true;
        for (needle, 0..) |nc, k| {
            if (std.ascii.toLower(haystack[scan + k]) != nc) {
                matched = false;
                break;
            }
        }
        if (matched) {
            match_count += 1;
            scan += needle.len;
        } else {
            scan += 1;
        }
    }
    if (match_count == 0) return body;

    // new_len is always >= 0: each match replaces needle.len bytes with redacted.len bytes,
    // and count * needle.len <= haystack.len (non-overlapping matches).
    const replacement_len = std.math.mul(usize, match_count, redacted.len) catch return null;
    const removed_len = match_count * needle.len;
    const expanded_len = std.math.add(usize, haystack.len, replacement_len) catch return null;
    const new_len = expanded_len - removed_len;
    const raw = core.ngx_pnalloc(r.*.pool, new_len) orelse return null;
    const out = core.castPtr(u8, raw) orelse return null;

    // Second pass: build the redacted buffer.
    var src: usize = 0;
    var dst: usize = 0;
    while (src <= haystack.len - needle.len) {
        var matched = true;
        for (needle, 0..) |nc, k| {
            if (std.ascii.toLower(haystack[src + k]) != nc) {
                matched = false;
                break;
            }
        }
        if (matched) {
            @memcpy(out[dst .. dst + redacted.len], redacted);
            dst += redacted.len;
            src += needle.len;
        } else {
            out[dst] = haystack[src];
            dst += 1;
            src += 1;
        }
    }
    if (src < haystack.len) {
        @memcpy(out[dst .. dst + (haystack.len - src)], haystack[src..]);
    }

    return ngx_str_t{ .data = out, .len = new_len };
}

// ── Exported inspection API ───────────────────────────────────────────────────

// Called by llm-proxy body_handler after request body is parsed.
// Scans `body` against configured rules and records the outcome in per-request ctx.
// Returns the outcome so llm-proxy can immediately block the request if needed.
export fn ngx_http_llm_security_inspect_request(
    r: [*c]ngx_http_request_t,
    body: ngx_str_t,
) LlmSecurityOutcome {
    // M2 Target 1: read translation_happened from llm-proxy before inspection.
    const mcf_opt = get_main_conf(r);
    const translation_val: ngx_flag_t = if (mcf_opt) |mcf|
        (if (resolveUintVar(r, mcf.llm_translation_happened_idx)) |v| @intCast(v) else 0)
    else
        0;

    const none = LlmSecurityOutcome{
        .detected = 0,
        .blocked = 0,
        .inspection_failed = 0,
        .rule_id = empty_str,
        .action = SECURITY_ACTION_NONE,
        .response_detected = 0,
        .response_blocked = 0,
        .response_rule_id = empty_str,
        .response_action = SECURITY_ACTION_NONE,
        .redacted_body = empty_str,
        .translation_happened = translation_val,
    };

    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module)) orelse return none;
    if (lccf.enabled != 1 or lccf.mode == SECURITY_MODE_UNSET) return none;

    const ctx = http.ngz_http_get_module_ctx(LlmSecurityCtx, r, &ngx_http_llm_security_module) catch {
        if (lccf.fail_closed == 1) {
            return LlmSecurityOutcome{
                .detected = 0,
                .blocked = 1,
                .inspection_failed = 1,
                .rule_id = empty_str,
                .action = SECURITY_ACTION_BLOCK,
                .response_detected = 0,
                .response_blocked = 0,
                .response_rule_id = empty_str,
                .response_action = SECURITY_ACTION_NONE,
                .redacted_body = empty_str,
                .translation_happened = translation_val,
            };
        }
        return none;
    };
    ctx.*.translation_happened = translation_val;
    ctx.*.org = if (lccf.org_var_index >= 0) (resolveStrVar(r, lccf.org_var_index) orelse empty_str) else empty_str;
    ctx.*.project = if (lccf.project_var_index >= 0) (resolveStrVar(r, lccf.project_var_index) orelse empty_str) else empty_str;
    ctx.*.policy_source = lccf.policy_source;

    if (lccf.rules_count == 0) return none;

    const text = core.slicify(u8, body.data, body.len);
    const idx = first_match(lccf, text);
    if (idx >= lccf.rules_count) {
        // No violation.
        ctx.*.detected = 0;
        ctx.*.blocked = 0;
        ctx.*.rule_id = empty_str;
        ctx.*.action = SECURITY_ACTION_NONE;
        return none;
    }

    const matched_rule = &lccf.rules[idx];
    ctx.*.rule_id = matched_rule.id;
    ctx.*.detected = 1;

    switch (matched_rule.action) {
        SECURITY_ACTION_DETECT => {
            ctx.*.blocked = 0;
            ctx.*.action = SECURITY_ACTION_DETECT;
            log.ngz_log_error(log.NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_security: request violation detected (rule: %V)", .{&matched_rule.id});
        },
        SECURITY_ACTION_REDACT, SECURITY_ACTION_BLOCK => {
            // Request-side redact is not meaningful (body is not modified before send).
            // Canonicalize to block so $llm_security_action matches the actual behavior.
            ctx.*.blocked = 1;
            ctx.*.action = SECURITY_ACTION_BLOCK;
            log.ngz_log_error(log.NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_security: request blocked (rule: %V)", .{&matched_rule.id});
        },
        else => {},
    }

    return LlmSecurityOutcome{
        .detected = ctx.*.detected,
        .blocked = ctx.*.blocked,
        .inspection_failed = 0,
        .rule_id = ctx.*.rule_id,
        .action = ctx.*.action,
        .response_detected = 0,
        .response_blocked = 0,
        .response_rule_id = empty_str,
        .response_action = SECURITY_ACTION_NONE,
        .redacted_body = empty_str,
        .translation_happened = ctx.*.translation_happened,
    };
}

// Called by llm-proxy body_filter after the response body is accumulated.
// For redact mode, writes a modified body into `out_body`.
export fn ngx_http_llm_security_inspect_response(
    r: [*c]ngx_http_request_t,
    body: ngx_str_t,
    out_body: [*c]ngx_str_t,
) LlmSecurityOutcome {
    const mcf_r = get_main_conf(r);
    const tr_val: ngx_flag_t = if (mcf_r) |mcf|
        (if (resolveUintVar(r, mcf.llm_translation_happened_idx)) |v| @intCast(v) else 0)
    else
        0;
    const none = LlmSecurityOutcome{
        .detected = 0,
        .blocked = 0,
        .inspection_failed = 0,
        .rule_id = empty_str,
        .action = SECURITY_ACTION_NONE,
        .response_detected = 0,
        .response_blocked = 0,
        .response_rule_id = empty_str,
        .response_action = SECURITY_ACTION_NONE,
        .redacted_body = empty_str,
        .translation_happened = tr_val,
    };

    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module)) orelse return none;
    if (lccf.enabled != 1 or lccf.inspect_response != 1) return none;
    if (lccf.mode == SECURITY_MODE_UNSET) return none;

    const existing_ctx = get_ctx(r);
    const ctx = existing_ctx orelse http.ngz_http_get_module_ctx(LlmSecurityCtx, r, &ngx_http_llm_security_module) catch {
        var failed = none;
        failed.inspection_failed = 1;
        if (lccf.fail_closed == 1) {
            failed.response_blocked = 1;
            failed.response_action = SECURITY_ACTION_BLOCK;
        }
        return failed;
    };
    if (existing_ctx == null) {
        ctx.*.translation_happened = tr_val;
        ctx.*.org = if (lccf.org_var_index >= 0) (resolveStrVar(r, lccf.org_var_index) orelse empty_str) else empty_str;
        ctx.*.project = if (lccf.project_var_index >= 0) (resolveStrVar(r, lccf.project_var_index) orelse empty_str) else empty_str;
        ctx.*.policy_source = lccf.policy_source;
    }

    if (lccf.rules_count == 0) return none;

    const text = core.slicify(u8, body.data, body.len);
    const idx = first_match(lccf, text);
    if (idx >= lccf.rules_count) {
        ctx.*.response_detected = 0;
        ctx.*.response_blocked = 0;
        ctx.*.response_rule_id = empty_str;
        ctx.*.response_action = SECURITY_ACTION_NONE;
        return none;
    }

    const matched_rule = &lccf.rules[idx];
    ctx.*.response_rule_id = matched_rule.id;
    ctx.*.response_detected = 1;

    var result = LlmSecurityOutcome{
        .detected = ctx.*.detected,
        .blocked = ctx.*.blocked,
        .inspection_failed = 0,
        .rule_id = ctx.*.rule_id,
        .action = ctx.*.action,
        .response_detected = 1,
        .response_blocked = 0,
        .response_rule_id = matched_rule.id,
        .response_action = SECURITY_ACTION_NONE,
        .redacted_body = empty_str,
        .translation_happened = ctx.*.translation_happened,
    };

    switch (matched_rule.action) {
        SECURITY_ACTION_DETECT => {
            ctx.*.response_blocked = 0;
            ctx.*.response_action = SECURITY_ACTION_DETECT;
            result.response_action = SECURITY_ACTION_DETECT;
            log.ngz_log_error(log.NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_security: response violation detected (rule: %V)", .{&matched_rule.id});
        },
        SECURITY_ACTION_BLOCK => {
            ctx.*.response_blocked = 1;
            ctx.*.response_action = SECURITY_ACTION_BLOCK;
            result.response_blocked = 1;
            result.response_action = SECURITY_ACTION_BLOCK;
            log.ngz_log_error(log.NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_security: response blocked (rule: %V)", .{&matched_rule.id});
        },
        SECURITY_ACTION_REDACT => {
            // Perform body redaction.
            if (redact_body(r, body, matched_rule.pattern)) |new_body| {
                ctx.*.response_blocked = 0;
                ctx.*.response_action = SECURITY_ACTION_REDACT;
                result.response_action = SECURITY_ACTION_REDACT;
                out_body.* = new_body;
                result.redacted_body = new_body;
                log.ngz_log_error(log.NGX_LOG_NOTICE, r.*.connection.*.log, 0, "llm_security: response redacted (rule: %V)", .{&matched_rule.id});
            } else {
                ctx.*.response_action = SECURITY_ACTION_NONE;
                result.inspection_failed = 1;
                if (lccf.fail_closed == 1) {
                    ctx.*.response_blocked = 1;
                    result.response_blocked = 1;
                    result.response_action = SECURITY_ACTION_BLOCK;
                } else {
                    ctx.*.response_blocked = 0;
                }
                log.ngz_log_error(log.NGX_LOG_ERR, r.*.connection.*.log, 0, "llm_security: response redaction failed (rule: %V)", .{&matched_rule.id});
            }
        },
        else => {},
    }

    return result;
}

// ── Variable getters ──────────────────────────────────────────────────────────

fn set_var(v: [*c]ngx_http_variable_value_t, s: ngx_str_t) void {
    v.*.data = s.data;
    v.*.flags.len = @intCast(s.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = s.len == 0;
}

fn var_sec_detected(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    const s = if (get_ctx(r)) |ctx| (if (ctx.*.detected == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return core.NGX_OK;
}

fn var_sec_blocked(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    const s = if (get_ctx(r)) |ctx| (if (ctx.*.blocked == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return core.NGX_OK;
}

fn var_sec_rule_id(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.rule_id else empty_str);
    return core.NGX_OK;
}

fn var_sec_action(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    const s = if (get_ctx(r)) |ctx| action_name(ctx.*.action) else ngx_string("none");
    set_var(v, s);
    return core.NGX_OK;
}

fn var_sec_response_detected(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    const s = if (get_ctx(r)) |ctx| (if (ctx.*.response_detected == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return core.NGX_OK;
}

fn var_sec_response_blocked(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    const s = if (get_ctx(r)) |ctx| (if (ctx.*.response_blocked == 1) ngx_string("1") else ngx_string("0")) else ngx_string("0");
    set_var(v, s);
    return core.NGX_OK;
}

fn var_sec_response_rule_id(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.response_rule_id else empty_str);
    return core.NGX_OK;
}

fn var_sec_org(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.org else empty_str);
    return core.NGX_OK;
}

fn var_sec_project(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.project else empty_str);
    return core.NGX_OK;
}

fn var_sec_policy_source(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    if (get_ctx(r)) |ctx| {
        set_var(v, ctx.*.policy_source);
        return core.NGX_OK;
    }
    const lccf = cast(conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_security_module)) orelse {
        set_var(v, empty_str);
        return core.NGX_OK;
    };
    set_var(v, lccf.policy_source);
    return core.NGX_OK;
}

// M2 Target 1: $llm_security_inspection_path — "native" or "translated".
// Reflects whether llm-proxy performed a dialect translation before inspection.
fn var_sec_inspection_path(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) core.ngx_int_t {
    _ = data;
    const translation_happened = if (get_ctx(r)) |ctx| ctx.*.translation_happened else blk: {
        // ctx not yet allocated; read directly from llm-proxy variable.
        const mcf = get_main_conf(r) orelse break :blk @as(ngx_flag_t, 0);
        break :blk if (resolveUintVar(r, mcf.llm_translation_happened_idx)) |v2| @as(ngx_flag_t, @intCast(v2)) else 0;
    };
    const s = if (translation_happened == 1) ngx_string("translated") else ngx_string("native");
    set_var(v, s);
    return core.NGX_OK;
}

// ── postconfiguration ─────────────────────────────────────────────────────────

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(llm_security_main_conf, cf.*.pool) orelse return null;
    p.*.llm_translation_happened_idx = -1;
    p.*.llm_body_parsed_idx = -1;
    return p;
}

fn init_main_conf(cf: [*c]ngx_conf_t, mcf_ptr: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = mcf_ptr;
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) core.ngx_int_t {
    // Pre-index llm-proxy variables. Non-fatal — returns -1 if not registered.
    const mcf: *llm_security_main_conf = @ptrCast(@alignCast(
        core.castPtr(llm_security_main_conf, conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_llm_security_module)) orelse return core.NGX_ERROR,
    ));
    mcf.llm_translation_happened_idx = blk: {
        var n = ngx_str_t{ .data = @constCast("llm_translation_happened"), .len = "llm_translation_happened".len };
        break :blk http.ngx_http_get_variable_index(cf, &n);
    };
    mcf.llm_body_parsed_idx = blk: {
        var n = ngx_str_t{ .data = @constCast("llm_body_parsed"), .len = "llm_body_parsed".len };
        break :blk http.ngx_http_get_variable_index(cf, &n);
    };

    const var_defs = [_]struct {
        name: []const u8,
        getter: *const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, core.uintptr_t) callconv(.c) core.ngx_int_t,
    }{
        .{ .name = "llm_security_detected", .getter = &var_sec_detected },
        .{ .name = "llm_security_blocked", .getter = &var_sec_blocked },
        .{ .name = "llm_security_rule_id", .getter = &var_sec_rule_id },
        .{ .name = "llm_security_action", .getter = &var_sec_action },
        .{ .name = "llm_security_response_detected", .getter = &var_sec_response_detected },
        .{ .name = "llm_security_response_blocked", .getter = &var_sec_response_blocked },
        .{ .name = "llm_security_response_rule_id", .getter = &var_sec_response_rule_id },
        .{ .name = "llm_security_org", .getter = &var_sec_org },
        .{ .name = "llm_security_project", .getter = &var_sec_project },
        .{ .name = "llm_security_policy_source", .getter = &var_sec_policy_source },
        // M2 Target 1: inspection path observability
        .{ .name = "llm_security_inspection_path", .getter = &var_sec_inspection_path },
    };
    for (&var_defs) |*vd| {
        var vn = ngx_str_t{ .len = vd.name.len, .data = @constCast(vd.name.ptr) };
        if (http.ngx_http_add_variable(cf, &vn, http.NGX_HTTP_VAR_NOCACHEABLE)) |v| {
            v.*.get_handler = vd.getter;
            v.*.data = 0;
        }
    }
    return core.NGX_OK;
}

// ── Configuration callbacks ───────────────────────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(llm_security_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.fail_closed = conf.NGX_CONF_UNSET;
        p.*.inspect_response = conf.NGX_CONF_UNSET;
        p.*.reject_oversized_request = conf.NGX_CONF_UNSET;
        p.*.reject_oversized_response = conf.NGX_CONF_UNSET;
        p.*.org_var_index = -1;
        p.*.project_var_index = -1;
        p.*.policy_source = ngx_string("legacy");
        // mode = SECURITY_MODE_UNSET (0), rules_file = empty, rules = null, rules_count = 0
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
    if (c.mode == SECURITY_MODE_UNSET) {
        c.mode = prev.mode;
    }
    if (c.rules_file.len == 0 and prev.rules_file.len > 0) {
        c.rules_file = prev.rules_file;
    }
    if (c.org_rules_file.len == 0 and prev.org_rules_file.len > 0) {
        c.org_rules_file = prev.org_rules_file;
    }
    if (c.project_rules_file.len == 0 and prev.project_rules_file.len > 0) {
        c.project_rules_file = prev.project_rules_file;
    }
    if (c.fail_closed == conf.NGX_CONF_UNSET) {
        c.fail_closed = if (prev.fail_closed == conf.NGX_CONF_UNSET) 0 else prev.fail_closed;
    }
    if (c.inspect_response == conf.NGX_CONF_UNSET) {
        c.inspect_response = if (prev.inspect_response == conf.NGX_CONF_UNSET) 0 else prev.inspect_response;
    }
    if (c.reject_oversized_request == conf.NGX_CONF_UNSET) {
        c.reject_oversized_request = if (prev.reject_oversized_request == conf.NGX_CONF_UNSET) 1 else prev.reject_oversized_request;
    }
    if (c.reject_oversized_response == conf.NGX_CONF_UNSET) {
        c.reject_oversized_response = if (prev.reject_oversized_response == conf.NGX_CONF_UNSET) 1 else prev.reject_oversized_response;
    }
    if (c.org_var_index < 0 and prev.org_var_index >= 0) {
        c.org_var_index = prev.org_var_index;
    }
    if (c.project_var_index < 0 and prev.project_var_index >= 0) {
        c.project_var_index = prev.project_var_index;
    }
    if (c.policy_source.len == 0 and prev.policy_source.len > 0) {
        c.policy_source = prev.policy_source;
    }

    // Inherit loaded rules from parent when child has none.
    if (c.rules == null and prev.rules != null) {
        c.rules = prev.rules;
        c.rules_count = prev.rules_count;
        c.policy_source = prev.policy_source;
    }

    if (c.rules_file.len > 0 and (c.org_rules_file.len > 0 or c.project_rules_file.len > 0)) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: cannot combine llm_security_rules_file with org/project layered rules files", .{});
        return conf.NGX_CONF_ERROR;
    }
    if (c.project_rules_file.len > 0 and c.org_rules_file.len == 0) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: llm_security_project_rules_file requires llm_security_org_rules_file", .{});
        return conf.NGX_CONF_ERROR;
    }

    // Validate: mode requires a rules file.
    if (c.enabled == 1 and c.mode != SECURITY_MODE_UNSET and c.rules_file.len == 0 and c.org_rules_file.len == 0) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: mode requires a rules file; add llm_security_rules_file", .{});
        return conf.NGX_CONF_ERROR;
    }

    // Phase 4: redact mode requires inspect_response on.
    if (c.mode == SECURITY_MODE_REDACT and c.inspect_response != 1) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: redact mode requires llm_security_inspect_response on", .{});
        return conf.NGX_CONF_ERROR;
    }

    // Response-body blocking needs a header-buffering substrate that does not
    // exist yet. Reject the config instead of allowing a client-visible reset.
    if (c.mode == SECURITY_MODE_BLOCK and c.inspect_response == 1) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: response blocking is not supported; use detect or redact when llm_security_inspect_response on", .{});
        return conf.NGX_CONF_ERROR;
    }
    if (c.rules == null and c.rules_file.len > 0) {
        const rules_arr = core.ngz_pcalloc_n(@intCast(MAX_SECURITY_RULES), SecurityRule, cf.*.pool) orelse return conf.NGX_CONF_ERROR;
        var count: ngx_uint_t = 0;
        if (!load_rules(cf, c.rules_file, rules_arr, c.mode, &count)) return conf.NGX_CONF_ERROR;
        c.rules = rules_arr;
        c.rules_count = count;
        c.policy_source = ngx_string("legacy");
    }
    if (c.rules == null and c.org_rules_file.len > 0) {
        if (!reload_layered_rules(cf, c)) return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

// ── Directive handlers ────────────────────────────────────────────────────────

fn ngx_conf_set_llm_security(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (cast(loc)) |lccf| lccf.enabled = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_mode(
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

    if (std.mem.eql(u8, s, "detect")) {
        lccf.mode = SECURITY_MODE_DETECT;
    } else if (std.mem.eql(u8, s, "block")) {
        lccf.mode = SECURITY_MODE_BLOCK;
    } else if (std.mem.eql(u8, s, "redact")) {
        // Allowed at directive level; validated in merge_loc_conf that inspect_response=on.
        lccf.mode = SECURITY_MODE_REDACT;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_mode: unknown mode; supported values are: detect block redact", .{});
        return conf.NGX_CONF_ERROR;
    }

    if (lccf.rules_file.len > 0) {
        const rules_arr = core.ngz_pcalloc_n(@intCast(MAX_SECURITY_RULES), SecurityRule, cf.*.pool) orelse return conf.NGX_CONF_ERROR;
        var count: ngx_uint_t = 0;
        if (!load_rules(cf, lccf.rules_file, rules_arr, lccf.mode, &count)) return conf.NGX_CONF_ERROR;
        lccf.rules = rules_arr;
        lccf.rules_count = count;
        lccf.policy_source = ngx_string("legacy");
    } else if (lccf.org_rules_file.len > 0) {
        if (!reload_layered_rules(cf, lccf)) return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_rules_file(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    var path = arg.*;
    // Resolve relative to the directory of the current config file.
    if (conf.ngx_conf_full_name(cf.*.cycle, &path, 1) != core.NGX_OK) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: failed to resolve rules file path", .{});
        return conf.NGX_CONF_ERROR;
    }
    lccf.rules_file = path;

    if (lccf.mode == SECURITY_MODE_UNSET) {
        return conf.NGX_CONF_OK;
    }

    const rules_arr = core.ngz_pcalloc_n(@intCast(MAX_SECURITY_RULES), SecurityRule, cf.*.pool) orelse return conf.NGX_CONF_ERROR;
    var count: ngx_uint_t = 0;
    if (!load_rules(cf, path, rules_arr, lccf.mode, &count)) {
        return conf.NGX_CONF_ERROR;
    }
    lccf.rules = rules_arr;
    lccf.rules_count = count;
    lccf.policy_source = ngx_string("legacy");

    return conf.NGX_CONF_OK;
}

fn resolve_rules_path(cf: [*c]ngx_conf_t, arg: *ngx_str_t) ?ngx_str_t {
    var path = arg.*;
    if (conf.ngx_conf_full_name(cf.*.cycle, &path, 1) != core.NGX_OK) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security: failed to resolve rules file path", .{});
        return null;
    }
    return path;
}

fn reload_layered_rules(cf: [*c]ngx_conf_t, lccf: *llm_security_loc_conf) bool {
    if (lccf.org_rules_file.len == 0) return true;
    const org_rules = core.ngz_pcalloc_n(@intCast(MAX_SECURITY_RULES), SecurityRule, cf.*.pool) orelse return false;
    var org_count: ngx_uint_t = 0;
    if (!load_rules(cf, lccf.org_rules_file, org_rules, lccf.mode, &org_count)) return false;

    if (lccf.project_rules_file.len == 0) {
        lccf.rules = org_rules;
        lccf.rules_count = org_count;
        lccf.policy_source = ngx_string("org");
        return true;
    }

    const project_rules = core.ngz_pcalloc_n(@intCast(MAX_SECURITY_RULES), SecurityRule, cf.*.pool) orelse return false;
    var project_count: ngx_uint_t = 0;
    if (!load_rules(cf, lccf.project_rules_file, project_rules, lccf.mode, &project_count)) return false;

    return merge_layered_rules(cf, lccf, org_rules, org_count, project_rules, project_count);
}

fn ngx_conf_set_llm_security_org_rules_file(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.org_rules_file = resolve_rules_path(cf, arg) orelse return conf.NGX_CONF_ERROR;
    if (lccf.mode == SECURITY_MODE_UNSET) return conf.NGX_CONF_OK;
    if (!reload_layered_rules(cf, lccf)) return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_project_rules_file(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    lccf.project_rules_file = resolve_rules_path(cf, arg) orelse return conf.NGX_CONF_ERROR;
    if (lccf.mode == SECURITY_MODE_UNSET) return conf.NGX_CONF_OK;
    if (!reload_layered_rules(cf, lccf)) return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_fail_closed(
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
        lccf.fail_closed = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.fail_closed = 0;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_fail_closed: invalid value; expected on or off", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_reject_oversized_request(
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
        lccf.reject_oversized_request = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.reject_oversized_request = 0;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_reject_oversized_request: invalid value; expected on or off", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_reject_oversized_response(
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
        lccf.reject_oversized_response = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.reject_oversized_response = 0;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_reject_oversized_response: invalid value; expected on or off", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_inspect_response(
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
        lccf.inspect_response = 1;
    } else if (std.mem.eql(u8, s, "off")) {
        lccf.inspect_response = 0;
    } else {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "llm_security_inspect_response: invalid value; expected on or off", .{});
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn parseVariableIndexDirective(cf: [*c]ngx_conf_t, arg: ngx_str_t) ngx_int_t {
    const raw = core.slicify(u8, arg.data, arg.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    return http.ngx_http_get_variable_index(cf, &n);
}

fn ngx_conf_set_llm_security_org(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.org_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_security_project(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = cast(loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 0;
    _ = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i);
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const idx = parseVariableIndexDirective(cf, arg.*);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.project_var_index = idx;
    return conf.NGX_CONF_OK;
}

// ── Module wiring ─────────────────────────────────────────────────────────────

export const ngx_http_llm_security_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = init_main_conf,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_security_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_security"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_security,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_mode"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_mode,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_rules_file"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_rules_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_org_rules_file"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_org_rules_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_project_rules_file"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_project_rules_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_fail_closed"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_fail_closed,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_reject_oversized_request"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_reject_oversized_request,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_reject_oversized_response"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_reject_oversized_response,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_inspect_response"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_inspect_response,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_org"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_org,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_security_project"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_security_project,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_llm_security_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_security_commands),
    @constCast(&ngx_http_llm_security_module_ctx),
);
