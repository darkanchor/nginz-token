const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const log = ngx.log;
const ngx_file = ngx.file;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_HTTP_INTERNAL_SERVER_ERROR = http.NGX_HTTP_INTERNAL_SERVER_ERROR;

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
extern var ngx_http_llm_proxy_module: ngx_module_t;

const MAX_CREDENTIALS: usize = 8;
const MAX_TENANT_CREDENTIALS: usize = 16;
const MAX_PROJECT_CREDENTIALS: usize = 16;
const MAX_ORG_CREDENTIALS: usize = 8;
const empty_str = ngx_str_t{ .len = 0, .data = @constCast("") };

// Provider auth mode constants — auth-owned vocabulary consumed by llm-proxy.
pub const auth_mode_none: ngx_uint_t = 0; // no credential resolved
pub const auth_mode_bearer: ngx_uint_t = 1; // Authorization: Bearer <cred>
pub const auth_mode_x_api_key: ngx_uint_t = 2; // x-api-key: <cred>

// AuthResolution is the cross-module interface llm-proxy calls to get auth policy.
// credential holds the resolved secret value (Phase 3+); llm-proxy writes it into
// the upstream auth header and must not expose it through nginx variables.
// Cross-module ABI struct — single source of truth in llm_contract.zig (do not re-declare).
pub const AuthResolution = contract.AuthResolution;

const status_disabled = ngx_string("disabled");
const status_missing_provider = ngx_string("missing_provider");
const status_missing_credential = ngx_string("missing_credential");
const status_missing_secret = ngx_string("missing_secret");
const status_resolved = ngx_string("resolved");
const fail_reason_none = ngx_string("");
const fail_reason_provider_missing = ngx_string("provider_missing");
const fail_reason_credential_missing = ngx_string("credential_missing");
// Milestone 2: updated vocabulary (tenant→client; org/project added).
const fail_reason_client_missing = ngx_string("client_missing");
const fail_reason_client_credential_missing = ngx_string("client_credential_missing");
const fail_reason_project_missing = ngx_string("project_missing");
const fail_reason_project_credential_missing = ngx_string("project_credential_missing");
const fail_reason_org_missing = ngx_string("org_missing");
const fail_reason_org_credential_missing = ngx_string("org_credential_missing");
const fail_reason_secret_unresolved = ngx_string("secret_unresolved");
const key_source_env = ngx_string("env");
const key_source_file = ngx_string("file");
const key_source_literal = ngx_string("literal");
const literal_id_prefix = "literal-id:";

// llm_auth_credential_t stores both the non-secret config identifier and the
// resolved secret value. Resolution happens at config-parse time so workers
// pay no per-request I/O cost. On nginx reload the config is re-parsed and
// secrets are re-read from their sources.
const llm_auth_credential_t = extern struct {
    provider: ngx_str_t,
    identifier: ngx_str_t, // non-secret config reference: "env:VAR", "file:PATH", or plain string
    secret: ngx_str_t, // resolved value; empty when source lookup failed at parse time
    key_source: ngx_str_t,
    fingerprint: ngx_str_t,
};

const llm_auth_tenant_credential_t = extern struct {
    tenant: ngx_str_t,
    provider: ngx_str_t,
    identifier: ngx_str_t,
    secret: ngx_str_t,
    key_source: ngx_str_t,
    fingerprint: ngx_str_t,
};

// Milestone 2 Target 2: project-scoped and org-scoped credential entries.
const llm_auth_project_credential_t = extern struct {
    project: ngx_str_t,
    provider: ngx_str_t,
    identifier: ngx_str_t,
    secret: ngx_str_t,
    key_source: ngx_str_t,
    fingerprint: ngx_str_t,
};

const llm_auth_org_credential_t = extern struct {
    org: ngx_str_t,
    provider: ngx_str_t,
    identifier: ngx_str_t,
    secret: ngx_str_t,
    key_source: ngx_str_t,
    fingerprint: ngx_str_t,
};

const llm_auth_loc_conf = extern struct {
    enabled: ngx_flag_t,
    fail_closed: ngx_flag_t,
    provider_hint: ngx_str_t,
    tenant_var_index: ngx_int_t, // client identity var (llm_auth_tenant / llm_auth_client)
    tenant_fallback_shared: ngx_flag_t,
    project_var_index: ngx_int_t, // project identity var (llm_auth_project)
    org_var_index: ngx_int_t, // org identity var (llm_auth_org)
    credentials: [MAX_CREDENTIALS]llm_auth_credential_t,
    credentials_count: ngx_uint_t,
    tenant_credentials: [MAX_TENANT_CREDENTIALS]llm_auth_tenant_credential_t,
    tenant_credentials_count: ngx_uint_t,
    project_credentials: [MAX_PROJECT_CREDENTIALS]llm_auth_project_credential_t,
    project_credentials_count: ngx_uint_t,
    org_credentials: [MAX_ORG_CREDENTIALS]llm_auth_org_credential_t,
    org_credentials_count: ngx_uint_t,
};

const LlmAuthCtx = extern struct {
    provider: ngx_str_t,
    credential: ngx_str_t, // non-secret identifier for $llm_auth_credential
    key_source: ngx_str_t,
    key_fingerprint: ngx_str_t,
    status: ngx_str_t,
    fail_reason: ngx_str_t,
    resolved: ngx_flag_t,
    secret: ngx_str_t, // resolved secret value; cached so ngx_http_llm_auth_resolve() skips recomputation
    // Milestone 2 Target 1: identity context (non-secret; safe to expose as variables).
    client: ngx_str_t, // resolved client identity ($llm_auth_client)
    project: ngx_str_t, // resolved project identity ($llm_auth_project)
    org: ngx_str_t, // resolved org identity ($llm_auth_org)
};

const LlmProxyCtx = extern struct {
    provider: ngx_str_t,
    model: ngx_str_t,
    upstream: ngx_str_t,
    is_streaming: ngx_flag_t,
    body_parsed: ngx_flag_t,
    prompt_tokens: ngx_uint_t,
    completion_tokens: ngx_uint_t,
    total_tokens: ngx_uint_t,
    usage_extracted: ngx_flag_t,
};

const CredentialView = struct {
    identifier: ngx_str_t,
    secret: ngx_str_t,
    key_source: ngx_str_t,
    fingerprint: ngx_str_t,
};

const CredentialDecision = struct {
    credential: ?CredentialView,
    fail_reason: ngx_str_t,
};

const IdentityContext = struct {
    client: ngx_str_t,
    project: ngx_str_t,
    org: ngx_str_t,
};

// copy_to_pool allocates a fresh copy of slice in pool.
fn copy_to_pool(slice: []const u8, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    if (slice.len == 0) return null;
    const p = core.castPtr(u8, core.ngx_pnalloc(pool, slice.len)) orelse return null;
    @memcpy(core.slicify(u8, p, slice.len), slice);
    return ngx_str_t{ .data = p, .len = slice.len };
}

fn copy_cstring_to_pool(slice: []const u8, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    const p = core.castPtr(u8, core.ngx_pnalloc(pool, slice.len + 1)) orelse return null;
    @memcpy(core.slicify(u8, p, slice.len), slice);
    p[slice.len] = 0;
    return ngx_str_t{ .data = p, .len = slice.len };
}

// trim_trailing_whitespace reduces len to strip trailing \n \r \t space.
// The data pointer is unchanged; the trimmed bytes remain in pool but are
// not considered part of the string.
fn trim_trailing_whitespace(s: ngx_str_t) ngx_str_t {
    var end = s.len;
    while (end > 0) {
        const c = s.data[end - 1];
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') {
            end -= 1;
        } else break;
    }
    return ngx_str_t{ .data = s.data, .len = end };
}

fn resolve_file_secret_path(cf: [*c]ngx_conf_t, raw_path: []const u8) ngx_str_t {
    // Reject any path component that is ".." to prevent traversal out of the
    // config directory (or out of any absolute prefix for absolute paths).
    var it = std.mem.splitScalar(u8, raw_path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return empty_str;
    }

    if (std.fs.path.isAbsolute(raw_path)) {
        return copy_cstring_to_pool(raw_path, cf.*.pool) orelse empty_str;
    }

    const conf_name = cf.*.conf_file.*.file.name;
    const conf_path = core.slicify(u8, conf_name.data, conf_name.len);
    const slash = std.mem.lastIndexOfScalar(u8, conf_path, '/') orelse return empty_str;
    const joined = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}/{s}",
        .{ conf_path[0..slash], raw_path },
    ) catch return empty_str;
    defer std.heap.page_allocator.free(joined);

    return copy_cstring_to_pool(joined, cf.*.pool) orelse empty_str;
}

// resolve_secret_config resolves the secret value for a credential identifier
// at config-parse time. Supported prefixes:
//   env:VARNAME  — read environment variable; empty if unset
//   file:PATH    — read file content relative to config dir; empty on error
//   <plain>      — the identifier is the value itself (dev / test mode)
fn resolve_secret_config(cf: [*c]ngx_conf_t, identifier: ngx_str_t) ngx_str_t {
    const lg = ngx.log;
    const s = core.slicify(u8, identifier.data, identifier.len);

    if (std.mem.startsWith(u8, s, "env:")) {
        if (identifier.len <= 4) return empty_str;
        // nginx config tokenizer null-terminates args, so data[len]==0.
        // data+4 points to "VARNAME\0" — safe to use as C string directly.
        const var_name: [*:0]const u8 = @ptrCast(identifier.data + 4);
        const val = std.c.getenv(var_name) orelse return empty_str;
        const vlen = std.mem.len(val);
        return copy_to_pool(val[0..vlen], cf.*.pool) orelse empty_str;
    }

    if (std.mem.startsWith(u8, s, "file:")) {
        if (identifier.len <= 5) return empty_str;
        const raw_path = s[5..];
        const path = resolve_file_secret_path(cf, raw_path);
        if (path.len == 0) return empty_str;
        const content = ngx_file.ngz_open_file(path, cf.*.log, cf.*.pool) catch |err| {
            lg.ngz_log_error(lg.NGX_LOG_ERR, cf.*.log, 0, "llm-auth: file resolve: open failed for %V err=%d", .{ &path, @intFromError(err) });
            return empty_str;
        };
        return trim_trailing_whitespace(content);
    }

    // Secret-safe literal form:
    //   literal-id:<non-secret-id>:<secret>
    // The first field is exposed through $llm_auth_credential; only the suffix
    // after the second ':' is used as the provider credential. Existing plain
    // literals retain their legacy behavior for compatibility.
    if (std.mem.startsWith(u8, s, literal_id_prefix)) {
        const rest = s[literal_id_prefix.len..];
        const separator = std.mem.indexOfScalar(u8, rest, ':') orelse return empty_str;
        if (separator == 0 or separator + 1 >= rest.len) return empty_str;
        return copy_to_pool(rest[separator + 1 ..], cf.*.pool) orelse empty_str;
    }

    // Plain string — the identifier is the value itself.
    return identifier;
}

fn key_source_for_identifier(identifier: ngx_str_t) ngx_str_t {
    const s = core.slicify(u8, identifier.data, identifier.len);
    if (std.mem.startsWith(u8, s, "env:")) return key_source_env;
    if (std.mem.startsWith(u8, s, "file:")) return key_source_file;
    return key_source_literal;
}

fn observable_identifier_for_config(cf: [*c]ngx_conf_t, identifier: ngx_str_t) ngx_str_t {
    const s = core.slicify(u8, identifier.data, identifier.len);
    if (!std.mem.startsWith(u8, s, literal_id_prefix)) return identifier;
    const rest = s[literal_id_prefix.len..];
    const separator = std.mem.indexOfScalar(u8, rest, ':') orelse return empty_str;
    if (separator == 0) return empty_str;
    return copy_to_pool(rest[0..separator], cf.*.pool) orelse empty_str;
}

fn fingerprint_for_identifier(identifier: ngx_str_t, pool: [*c]core.ngx_pool_t) ngx_str_t {
    const raw = core.slicify(u8, identifier.data, identifier.len);
    if (raw.len == 0) return empty_str;

    // Fingerprints are correlation labels, not secret verifiers. Hash only the
    // non-secret source identifier so an exposed fingerprint cannot be used to
    // test guesses for an API key. Plain literals have no safe identifier, so
    // deliberately collapse them to a fixed label.
    const source = if (std.mem.startsWith(u8, raw, literal_id_prefix)) blk: {
        const rest = raw[literal_id_prefix.len..];
        const separator = std.mem.indexOfScalar(u8, rest, ':') orelse return empty_str;
        if (separator == 0) return empty_str;
        break :blk rest[0..separator];
    } else if (std.mem.startsWith(u8, raw, "env:") or std.mem.startsWith(u8, raw, "file:"))
        raw
    else
        "literal";

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest[0..12], .lower);
    var scratch: [3 + encoded.len]u8 = undefined;
    const rendered = std.fmt.bufPrint(&scratch, "id:{s}", .{encoded}) catch return empty_str;
    return copy_to_pool(rendered, pool) orelse empty_str;
}

fn set_var(v: [*c]ngx_http_variable_value_t, s: ngx_str_t) void {
    v.*.data = s.data;
    v.*.flags.len = @intCast(s.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = s.len == 0;
}

fn get_ctx(r: [*c]ngx_http_request_t) ?[*c]LlmAuthCtx {
    return core.castPtr(LlmAuthCtx, r.*.ctx[ngx_http_llm_auth_module.ctx_index]);
}

fn get_llm_proxy_ctx(r: [*c]ngx_http_request_t) ?[*c]LlmProxyCtx {
    return core.castPtr(
        LlmProxyCtx,
        r.*.ctx[ngx_http_llm_proxy_module.ctx_index],
    );
}

fn get_llm_provider(r: [*c]ngx_http_request_t) ngx_str_t {
    const proxy_ctx = get_llm_proxy_ctx(r) orelse return empty_str;
    return proxy_ctx.*.provider;
}

fn resolveStrVar(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?ngx_str_t {
    if (idx < 0) return null;
    const val = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (val == null or val == core.nullptr(ngx_http_variable_value_t)) return null;
    if (val.*.flags.not_found or val.*.flags.len == 0) return null;
    return ngx_str_t{ .data = val.*.data, .len = val.*.flags.len };
}

fn find_credential(provider: ngx_str_t, lccf: *llm_auth_loc_conf) ?*llm_auth_credential_t {
    if (provider.len == 0) return null;
    const wanted = core.slicify(u8, provider.data, provider.len);

    var i: usize = 0;
    while (i < lccf.credentials_count) : (i += 1) {
        const slot = &lccf.credentials[i];
        const have = core.slicify(u8, slot.provider.data, slot.provider.len);
        if (std.mem.eql(u8, wanted, have)) return slot;
    }

    return null;
}

fn find_tenant_credential(tenant: ngx_str_t, provider: ngx_str_t, lccf: *llm_auth_loc_conf) ?*llm_auth_tenant_credential_t {
    if (tenant.len == 0 or provider.len == 0) return null;
    const wanted_tenant = core.slicify(u8, tenant.data, tenant.len);
    const wanted_provider = core.slicify(u8, provider.data, provider.len);

    var i: usize = 0;
    while (i < lccf.tenant_credentials_count) : (i += 1) {
        const slot = &lccf.tenant_credentials[i];
        const have_tenant = core.slicify(u8, slot.tenant.data, slot.tenant.len);
        const have_provider = core.slicify(u8, slot.provider.data, slot.provider.len);
        if (std.mem.eql(u8, wanted_tenant, have_tenant) and std.mem.eql(u8, wanted_provider, have_provider)) return slot;
    }

    return null;
}

fn find_project_credential(project: ngx_str_t, provider: ngx_str_t, lccf: *llm_auth_loc_conf) ?*llm_auth_project_credential_t {
    if (project.len == 0 or provider.len == 0) return null;
    const wp = core.slicify(u8, project.data, project.len);
    const wprov = core.slicify(u8, provider.data, provider.len);
    var i: usize = 0;
    while (i < lccf.project_credentials_count) : (i += 1) {
        const slot = &lccf.project_credentials[i];
        if (std.mem.eql(u8, wp, core.slicify(u8, slot.project.data, slot.project.len)) and
            std.mem.eql(u8, wprov, core.slicify(u8, slot.provider.data, slot.provider.len))) return slot;
    }
    return null;
}

fn find_org_credential(org: ngx_str_t, provider: ngx_str_t, lccf: *llm_auth_loc_conf) ?*llm_auth_org_credential_t {
    if (org.len == 0 or provider.len == 0) return null;
    const wo = core.slicify(u8, org.data, org.len);
    const wprov = core.slicify(u8, provider.data, provider.len);
    var i: usize = 0;
    while (i < lccf.org_credentials_count) : (i += 1) {
        const slot = &lccf.org_credentials[i];
        if (std.mem.eql(u8, wo, core.slicify(u8, slot.org.data, slot.org.len)) and
            std.mem.eql(u8, wprov, core.slicify(u8, slot.provider.data, slot.provider.len))) return slot;
    }
    return null;
}

fn resolve_tenant(r: [*c]ngx_http_request_t, lccf: *llm_auth_loc_conf) ngx_str_t {
    return resolveStrVar(r, lccf.tenant_var_index) orelse empty_str;
}

fn resolve_identity_context(r: [*c]ngx_http_request_t, lccf: *llm_auth_loc_conf) IdentityContext {
    return .{
        .client = resolve_tenant(r, lccf),
        .project = resolveStrVar(r, lccf.project_var_index) orelse empty_str,
        .org = resolveStrVar(r, lccf.org_var_index) orelse empty_str,
    };
}

fn cred_decision(identifier: ngx_str_t, secret: ngx_str_t, key_source: ngx_str_t, fingerprint: ngx_str_t) CredentialDecision {
    return .{ .credential = .{ .identifier = identifier, .secret = secret, .key_source = key_source, .fingerprint = fingerprint }, .fail_reason = fail_reason_none };
}

// Milestone 2 Target 2: three-level cascade — client → project → org → shared.
// Each level is tried in order. The deny check fires after all levels are exhausted
// if any configured identity scope had its variable set but found no credential.
// The most specific fail reason (client > project > org) is reported.
fn select_credential(
    identities: IdentityContext,
    provider: ngx_str_t,
    lccf: *llm_auth_loc_conf,
) CredentialDecision {
    var most_specific_fail: ngx_str_t = fail_reason_none;

    // Level 1: client (existing tenant semantics, now renamed to "client")
    const client = identities.client;
    if (client.len > 0) {
        if (find_tenant_credential(client, provider, lccf)) |c| return cred_decision(c.*.identifier, c.*.secret, c.*.key_source, c.*.fingerprint);
        if (lccf.tenant_credentials_count > 0) most_specific_fail = fail_reason_client_credential_missing;
    } else if (lccf.tenant_var_index >= 0 and lccf.tenant_credentials_count > 0) {
        most_specific_fail = fail_reason_client_missing;
    }

    // Level 2: project
    const project = identities.project;
    if (project.len > 0) {
        if (find_project_credential(project, provider, lccf)) |c| return cred_decision(c.*.identifier, c.*.secret, c.*.key_source, c.*.fingerprint);
        if (lccf.project_credentials_count > 0 and most_specific_fail.len == 0) most_specific_fail = fail_reason_project_credential_missing;
    } else if (lccf.project_var_index >= 0 and lccf.project_credentials_count > 0 and most_specific_fail.len == 0) {
        most_specific_fail = fail_reason_project_missing;
    }

    // Level 3: org
    const org = identities.org;
    if (org.len > 0) {
        if (find_org_credential(org, provider, lccf)) |c| return cred_decision(c.*.identifier, c.*.secret, c.*.key_source, c.*.fingerprint);
        if (lccf.org_credentials_count > 0 and most_specific_fail.len == 0) most_specific_fail = fail_reason_org_credential_missing;
    } else if (lccf.org_var_index >= 0 and lccf.org_credentials_count > 0 and most_specific_fail.len == 0) {
        most_specific_fail = fail_reason_org_missing;
    }

    // If any configured identity scope was active (var set, no credential found) and no fallback allowed: deny.
    if (most_specific_fail.len > 0 and lccf.tenant_fallback_shared != 1) {
        return .{ .credential = null, .fail_reason = most_specific_fail };
    }

    // Shared provider credential (platform-wide fallback)
    if (find_credential(provider, lccf)) |c| return cred_decision(c.*.identifier, c.*.secret, c.*.key_source, c.*.fingerprint);

    return .{ .credential = null, .fail_reason = fail_reason_credential_missing };
}

fn validate_loc_conf(cf: [*c]ngx_conf_t, lccf: *llm_auth_loc_conf) [*c]u8 {
    const lg = ngx.log;

    if (lccf.tenant_credentials_count > 0 and lccf.tenant_var_index < 0) {
        lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: tenant credentials require llm_auth_tenant", .{});
        return conf.NGX_CONF_ERROR;
    }
    // tenant_fallback_shared requires at least one identity var (tenant/client, project, or org).
    const any_identity_var = lccf.tenant_var_index >= 0 or lccf.project_var_index >= 0 or lccf.org_var_index >= 0;
    if (lccf.tenant_fallback_shared == 1 and !any_identity_var) {
        lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: llm_auth_tenant_fallback_shared requires llm_auth_tenant, llm_auth_project, or llm_auth_org", .{});
        return conf.NGX_CONF_ERROR;
    }
    if (lccf.project_credentials_count > 0 and lccf.project_var_index < 0) {
        lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: project credentials require llm_auth_project", .{});
        return conf.NGX_CONF_ERROR;
    }
    if (lccf.org_credentials_count > 0 and lccf.org_var_index < 0) {
        lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: org credentials require llm_auth_org", .{});
        return conf.NGX_CONF_ERROR;
    }

    var i: usize = 0;
    while (i < lccf.credentials_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < lccf.credentials_count) : (j += 1) {
            if (std.mem.eql(u8, core.slicify(u8, lccf.credentials[i].provider.data, lccf.credentials[i].provider.len), core.slicify(u8, lccf.credentials[j].provider.data, lccf.credentials[j].provider.len))) {
                lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: duplicate shared credential for provider %V", .{&lccf.credentials[i].provider});
                return conf.NGX_CONF_ERROR;
            }
        }
    }

    i = 0;
    while (i < lccf.tenant_credentials_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < lccf.tenant_credentials_count) : (j += 1) {
            const same_key = std.mem.eql(u8, core.slicify(u8, lccf.tenant_credentials[i].tenant.data, lccf.tenant_credentials[i].tenant.len), core.slicify(u8, lccf.tenant_credentials[j].tenant.data, lccf.tenant_credentials[j].tenant.len));
            const same_prov = std.mem.eql(u8, core.slicify(u8, lccf.tenant_credentials[i].provider.data, lccf.tenant_credentials[i].provider.len), core.slicify(u8, lccf.tenant_credentials[j].provider.data, lccf.tenant_credentials[j].provider.len));
            if (same_key and same_prov) {
                lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: duplicate tenant credential for tenant %V provider %V", .{ &lccf.tenant_credentials[i].tenant, &lccf.tenant_credentials[i].provider });
                return conf.NGX_CONF_ERROR;
            }
        }
    }

    i = 0;
    while (i < lccf.project_credentials_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < lccf.project_credentials_count) : (j += 1) {
            const same_key = std.mem.eql(u8, core.slicify(u8, lccf.project_credentials[i].project.data, lccf.project_credentials[i].project.len), core.slicify(u8, lccf.project_credentials[j].project.data, lccf.project_credentials[j].project.len));
            const same_prov = std.mem.eql(u8, core.slicify(u8, lccf.project_credentials[i].provider.data, lccf.project_credentials[i].provider.len), core.slicify(u8, lccf.project_credentials[j].provider.data, lccf.project_credentials[j].provider.len));
            if (same_key and same_prov) {
                lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: duplicate project credential for project %V provider %V", .{ &lccf.project_credentials[i].project, &lccf.project_credentials[i].provider });
                return conf.NGX_CONF_ERROR;
            }
        }
    }

    i = 0;
    while (i < lccf.org_credentials_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < lccf.org_credentials_count) : (j += 1) {
            const same_key = std.mem.eql(u8, core.slicify(u8, lccf.org_credentials[i].org.data, lccf.org_credentials[i].org.len), core.slicify(u8, lccf.org_credentials[j].org.data, lccf.org_credentials[j].org.len));
            const same_prov = std.mem.eql(u8, core.slicify(u8, lccf.org_credentials[i].provider.data, lccf.org_credentials[i].provider.len), core.slicify(u8, lccf.org_credentials[j].provider.data, lccf.org_credentials[j].provider.len));
            if (same_key and same_prov) {
                lg.ngz_log_error(lg.NGX_LOG_EMERG, cf.*.log, 0, "llm-auth: duplicate org credential for org %V provider %V", .{ &lccf.org_credentials[i].org, &lccf.org_credentials[i].provider });
                return conf.NGX_CONF_ERROR;
            }
        }
    }

    return conf.NGX_CONF_OK;
}

fn provider_auth_mode(provider: ngx_str_t) ngx_uint_t {
    const name = core.slicify(u8, provider.data, provider.len);
    if (std.mem.eql(u8, name, "anthropic")) return auth_mode_x_api_key;
    return auth_mode_bearer; // openai and openai-compatible default
}

// ngx_http_llm_auth_resolve is the cross-module interface consumed by llm-proxy.
// credential in the returned AuthResolution holds the resolved secret value —
// llm-proxy uses it to set the upstream auth header. It must not be stored in
// nginx variables or logs. Phase 2 llm-proxy integration is still deferred;
// see Runtime Integration Deferral in README.
pub export fn ngx_http_llm_auth_resolve(r: [*c]ngx_http_request_t) AuthResolution {
    var res = AuthResolution{
        .provider = empty_str,
        .mode = auth_mode_none,
        .credential = empty_str,
        .fail_closed = 0,
        .status = status_missing_provider,
        .fail_reason = fail_reason_provider_missing,
    };

    const lccf = core.castPtr(
        llm_auth_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_auth_module),
    ) orelse return res;

    // Return cached decision when access phase already resolved this request.
    // If ACCESS ran before llm-proxy populated provider context, ctx.resolved may
    // still only reflect an early "missing_provider" placeholder and must be
    // recomputed here from the now-available proxy facts.
    if (get_ctx(r)) |ctx| {
        if (ctx.*.resolved == 1 and ctx.*.provider.len > 0) {
            return AuthResolution{
                .provider = ctx.*.provider,
                .mode = provider_auth_mode(ctx.*.provider),
                .credential = ctx.*.secret,
                .fail_closed = lccf.*.fail_closed,
                .status = ctx.*.status,
                .fail_reason = ctx.*.fail_reason,
            };
        }
    }

    res.fail_closed = lccf.*.fail_closed;
    res.provider = if (lccf.*.provider_hint.len > 0) lccf.*.provider_hint else get_llm_provider(r);
    if (res.provider.len == 0) {
        res.status = status_missing_provider;
        res.fail_reason = fail_reason_provider_missing;
        return res;
    }

    const identities = if (get_ctx(r)) |ctx|
        IdentityContext{ .client = ctx.*.client, .project = ctx.*.project, .org = ctx.*.org }
    else
        resolve_identity_context(r, lccf);
    const decision = select_credential(identities, res.provider, lccf);
    const cred = decision.credential orelse {
        res.status = status_missing_credential;
        res.fail_reason = decision.fail_reason;
        return res;
    };

    if (cred.secret.len == 0) {
        res.status = status_missing_secret;
        res.fail_reason = fail_reason_secret_unresolved;
        return res;
    }

    res.credential = cred.secret; // actual secret value for upstream use
    res.mode = provider_auth_mode(res.provider);
    res.status = status_resolved;
    res.fail_reason = fail_reason_none;
    return res;
}

fn var_auth_provider(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.provider else empty_str);
    return NGX_OK;
}

fn var_auth_credential(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    // ctx.credential holds the non-secret identifier, not the resolved secret.
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.credential else empty_str);
    return NGX_OK;
}

fn var_auth_status(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.status else empty_str);
    return NGX_OK;
}

fn var_auth_key_source(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.key_source else empty_str);
    return NGX_OK;
}

fn var_auth_key_fingerprint(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.key_fingerprint else empty_str);
    return NGX_OK;
}

fn var_auth_fail_reason(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.fail_reason else empty_str);
    return NGX_OK;
}

// Milestone 2 Target 1: identity context variables (non-secret; safe to observe).
fn var_auth_client(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.client else empty_str);
    return NGX_OK;
}

fn var_auth_project(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.project else empty_str);
    return NGX_OK;
}

fn var_auth_org(r: [*c]ngx_http_request_t, v: [*c]ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    _ = data;
    set_var(v, if (get_ctx(r)) |ctx| ctx.*.org else empty_str);
    return NGX_OK;
}

export fn ngx_http_llm_auth_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        llm_auth_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_auth_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;

    const ctx = http.ngz_http_get_module_ctx(LlmAuthCtx, r, &ngx_http_llm_auth_module) catch return NGX_ERROR;
    if (ctx.*.resolved == 1) return NGX_DECLINED;
    ctx.*.provider = empty_str;
    ctx.*.credential = empty_str;
    ctx.*.key_source = empty_str;
    ctx.*.key_fingerprint = empty_str;
    ctx.*.status = status_disabled;
    ctx.*.fail_reason = fail_reason_none;
    ctx.*.secret = empty_str;
    ctx.*.client = empty_str;
    ctx.*.project = empty_str;
    ctx.*.org = empty_str;

    ctx.*.provider = if (lccf.*.provider_hint.len > 0) lccf.*.provider_hint else get_llm_provider(r);
    if (ctx.*.provider.len == 0) {
        ctx.*.resolved = 1;
        ctx.*.status = status_missing_provider;
        ctx.*.fail_reason = fail_reason_provider_missing;
        return if (lccf.*.fail_closed == 1) NGX_HTTP_INTERNAL_SERVER_ERROR else NGX_DECLINED;
    }

    // Populate identity context before credential selection (non-secret; drives $llm_auth_* vars).
    const identities = resolve_identity_context(r, lccf);
    ctx.*.client = identities.client;
    ctx.*.project = identities.project;
    ctx.*.org = identities.org;

    const decision = select_credential(identities, ctx.*.provider, lccf);
    const cred = decision.credential orelse {
        ctx.*.resolved = 1;
        ctx.*.status = status_missing_credential;
        ctx.*.fail_reason = decision.fail_reason;
        return if (lccf.*.fail_closed == 1) NGX_HTTP_INTERNAL_SERVER_ERROR else NGX_DECLINED;
    };

    // Store the non-secret identifier in ctx so $llm_auth_credential never exposes
    // the actual secret value.  The secret is cached separately for resolve().
    ctx.*.credential = cred.identifier;
    ctx.*.key_source = cred.key_source;
    ctx.*.key_fingerprint = cred.fingerprint;
    ctx.*.secret = cred.secret;

    if (cred.secret.len == 0) {
        ctx.*.resolved = 1;
        ctx.*.status = status_missing_secret;
        ctx.*.fail_reason = fail_reason_secret_unresolved;
        return if (lccf.*.fail_closed == 1) NGX_HTTP_INTERNAL_SERVER_ERROR else NGX_DECLINED;
    }

    ctx.*.resolved = 1;
    ctx.*.status = status_resolved;
    ctx.*.fail_reason = fail_reason_none;
    return NGX_DECLINED;
}

fn ngx_http_llm_auth_preaccess_handler(r: [*c]http.ngx_http_request_t) callconv(.c) core.ngx_int_t {
    const lccf = core.castPtr(
        llm_auth_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_llm_auth_module),
    ) orelse return core.NGX_DECLINED;

    if (lccf.*.enabled != 1) return core.NGX_DECLINED;
    if (r == r.*.main) return core.NGX_DECLINED;

    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0, "llm_auth: subrequests are not supported on llm_auth-enabled locations", .{});
    return http.NGX_HTTP_FORBIDDEN;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const var_defs = [_]struct {
        name: []const u8,
        getter: *const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, core.uintptr_t) callconv(.c) ngx_int_t,
    }{
        .{ .name = "llm_auth_provider", .getter = &var_auth_provider },
        .{ .name = "llm_auth_credential", .getter = &var_auth_credential },
        .{ .name = "llm_auth_status", .getter = &var_auth_status },
        .{ .name = "llm_auth_key_source", .getter = &var_auth_key_source },
        .{ .name = "llm_auth_key_fingerprint", .getter = &var_auth_key_fingerprint },
        .{ .name = "llm_auth_fail_reason", .getter = &var_auth_fail_reason },
        // Milestone 2 Target 1: identity context variables.
        .{ .name = "llm_auth_client", .getter = &var_auth_client },
        .{ .name = "llm_auth_project", .getter = &var_auth_project },
        .{ .name = "llm_auth_org", .getter = &var_auth_org },
    };

    for (&var_defs) |*vd| {
        var vn = ngx_str_t{ .len = vd.name.len, .data = @constCast(vd.name.ptr) };
        if (http.ngx_http_add_variable(cf, &vn, http.NGX_HTTP_VAR_NOCACHEABLE)) |v| {
            v.*.get_handler = vd.getter;
            v.*.data = 0;
        }
    }

    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var preaccess_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_PREACCESS_PHASE].handlers,
    );
    const preaccess = preaccess_handlers.append() catch return NGX_ERROR;
    preaccess.* = ngx_http_llm_auth_preaccess_handler;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_llm_auth_access_handler;

    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(llm_auth_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.fail_closed = conf.NGX_CONF_UNSET;
        p.*.provider_hint = empty_str;
        p.*.tenant_var_index = -1;
        p.*.tenant_fallback_shared = conf.NGX_CONF_UNSET;
        p.*.project_var_index = -1;
        p.*.org_var_index = -1;
        p.*.credentials_count = 0;
        p.*.tenant_credentials_count = 0;
        p.*.project_credentials_count = 0;
        p.*.org_credentials_count = 0;
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev: *llm_auth_loc_conf = @ptrCast(core.castPtr(llm_auth_loc_conf, parent) orelse return conf.NGX_CONF_OK);
    const c: *llm_auth_loc_conf = @ptrCast(core.castPtr(llm_auth_loc_conf, child) orelse return conf.NGX_CONF_OK);

    if (c.enabled == conf.NGX_CONF_UNSET) {
        c.enabled = if (prev.enabled == conf.NGX_CONF_UNSET) 0 else prev.enabled;
    }
    if (c.fail_closed == conf.NGX_CONF_UNSET) {
        c.fail_closed = if (prev.fail_closed == conf.NGX_CONF_UNSET) 0 else prev.fail_closed;
    }
    if (c.tenant_fallback_shared == conf.NGX_CONF_UNSET) {
        c.tenant_fallback_shared = if (prev.tenant_fallback_shared == conf.NGX_CONF_UNSET) 0 else prev.tenant_fallback_shared;
    }
    if (c.provider_hint.len == 0 and prev.provider_hint.len > 0) {
        c.provider_hint = prev.provider_hint;
    }
    if (c.tenant_var_index < 0 and prev.tenant_var_index >= 0) {
        c.tenant_var_index = prev.tenant_var_index;
    }
    if (c.project_var_index < 0 and prev.project_var_index >= 0) {
        c.project_var_index = prev.project_var_index;
    }
    if (c.org_var_index < 0 and prev.org_var_index >= 0) {
        c.org_var_index = prev.org_var_index;
    }
    if (c.credentials_count == 0 and prev.credentials_count > 0) {
        var i: usize = 0;
        while (i < prev.credentials_count) : (i += 1) {
            c.credentials[i] = prev.credentials[i];
        }
        c.credentials_count = prev.credentials_count;
    }
    if (c.tenant_credentials_count == 0 and prev.tenant_credentials_count > 0) {
        var i: usize = 0;
        while (i < prev.tenant_credentials_count) : (i += 1) {
            c.tenant_credentials[i] = prev.tenant_credentials[i];
        }
        c.tenant_credentials_count = prev.tenant_credentials_count;
    }
    if (c.project_credentials_count == 0 and prev.project_credentials_count > 0) {
        var i: usize = 0;
        while (i < prev.project_credentials_count) : (i += 1) {
            c.project_credentials[i] = prev.project_credentials[i];
        }
        c.project_credentials_count = prev.project_credentials_count;
    }
    if (c.org_credentials_count == 0 and prev.org_credentials_count > 0) {
        var i: usize = 0;
        while (i < prev.org_credentials_count) : (i += 1) {
            c.org_credentials[i] = prev.org_credentials[i];
        }
        c.org_credentials_count = prev.org_credentials_count;
    }

    return validate_loc_conf(cf, c);
}

fn ngx_conf_set_llm_auth(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(llm_auth_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_auth_credential(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_OK;
    if (lccf.*.credentials_count >= MAX_CREDENTIALS) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;
    const credential = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_OK;

    const slot: usize = @intCast(lccf.*.credentials_count);
    var creds = lccf.*.credentials[0..];
    creds[slot].provider = provider.*;
    creds[slot].identifier = observable_identifier_for_config(cf, credential.*);
    creds[slot].secret = resolve_secret_config(cf, credential.*);
    creds[slot].key_source = key_source_for_identifier(credential.*);
    creds[slot].fingerprint = if (creds[slot].secret.len > 0) fingerprint_for_identifier(credential.*, cf.*.pool) else empty_str;
    lccf.*.credentials_count += 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_auth_tenant(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    const idx = http.ngx_http_get_variable_index(cf, &n);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.tenant_var_index = idx;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_auth_tenant_credential(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    if (lccf.*.tenant_credentials_count >= MAX_TENANT_CREDENTIALS) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const tenant = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const credential = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    const slot: usize = @intCast(lccf.*.tenant_credentials_count);
    var creds = lccf.*.tenant_credentials[0..];
    creds[slot].tenant = tenant.*;
    creds[slot].provider = provider.*;
    creds[slot].identifier = observable_identifier_for_config(cf, credential.*);
    creds[slot].secret = resolve_secret_config(cf, credential.*);
    creds[slot].key_source = key_source_for_identifier(credential.*);
    creds[slot].fingerprint = if (creds[slot].secret.len > 0) fingerprint_for_identifier(credential.*, cf.*.pool) else empty_str;
    lccf.*.tenant_credentials_count += 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_auth_provider(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_OK;

    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        lccf.*.provider_hint = arg.*;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_auth_fail_closed(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_OK;

    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const value = core.slicify(u8, arg.*.data, arg.*.len);
        lccf.*.fail_closed = if (std.mem.eql(u8, value, "on")) 1 else 0;
    }

    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 1: llm_auth_project $var — stores project identity variable index.
fn ngx_conf_set_llm_auth_project(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    const idx = http.ngx_http_get_variable_index(cf, &n);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.project_var_index = idx;
    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 1: llm_auth_org $var — stores org identity variable index.
fn ngx_conf_set_llm_auth_org(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    const name = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
    var n = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
    const idx = http.ngx_http_get_variable_index(cf, &n);
    if (idx < 0) return conf.NGX_CONF_ERROR;
    lccf.*.org_var_index = idx;
    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 2: llm_auth_project_credential <project> <provider> <credential>
fn ngx_conf_set_llm_auth_project_credential(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    if (lccf.*.project_credentials_count >= MAX_PROJECT_CREDENTIALS) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const project = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const credential = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    const slot: usize = @intCast(lccf.*.project_credentials_count);
    var pcreds = lccf.*.project_credentials[0..];
    pcreds[slot].project = project.*;
    pcreds[slot].provider = provider.*;
    pcreds[slot].identifier = observable_identifier_for_config(cf, credential.*);
    pcreds[slot].secret = resolve_secret_config(cf, credential.*);
    pcreds[slot].key_source = key_source_for_identifier(credential.*);
    pcreds[slot].fingerprint = if (pcreds[slot].secret.len > 0) fingerprint_for_identifier(credential.*, cf.*.pool) else empty_str;
    lccf.*.project_credentials_count += 1;
    return conf.NGX_CONF_OK;
}

// Milestone 2 Target 2: llm_auth_org_credential <org> <provider> <credential>
fn ngx_conf_set_llm_auth_org_credential(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    if (lccf.*.org_credentials_count >= MAX_ORG_CREDENTIALS) return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const org = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const provider = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;
    const credential = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return conf.NGX_CONF_ERROR;

    const slot: usize = @intCast(lccf.*.org_credentials_count);
    var ocreds = lccf.*.org_credentials[0..];
    ocreds[slot].org = org.*;
    ocreds[slot].provider = provider.*;
    ocreds[slot].identifier = observable_identifier_for_config(cf, credential.*);
    ocreds[slot].secret = resolve_secret_config(cf, credential.*);
    ocreds[slot].key_source = key_source_for_identifier(credential.*);
    ocreds[slot].fingerprint = if (ocreds[slot].secret.len > 0) fingerprint_for_identifier(credential.*, cf.*.pool) else empty_str;
    lccf.*.org_credentials_count += 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_auth_tenant_fallback_shared(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(llm_auth_loc_conf, loc) orelse return conf.NGX_CONF_OK;

    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const value = core.slicify(u8, arg.*.data, arg.*.len);
        lccf.*.tenant_fallback_shared = if (std.mem.eql(u8, value, "on")) 1 else 0;
    }

    return conf.NGX_CONF_OK;
}

export const ngx_http_llm_auth_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_auth_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_auth"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_auth,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_credential"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_llm_auth_credential,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_provider"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_auth_provider,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_tenant"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_auth_tenant,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_tenant_credential"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE3,
        .set = ngx_conf_set_llm_auth_tenant_credential,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_fail_closed"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_auth_fail_closed,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_tenant_fallback_shared"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_auth_tenant_fallback_shared,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Milestone 2 Target 1: org/project identity variable directives.
    ngx_command_t{
        .name = ngx_string("llm_auth_project"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_auth_project,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_org"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_llm_auth_org,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // Milestone 2 Target 2: project/org credential directives.
    ngx_command_t{
        .name = ngx_string("llm_auth_project_credential"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE3,
        .set = ngx_conf_set_llm_auth_project_credential,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("llm_auth_org_credential"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE3,
        .set = ngx_conf_set_llm_auth_org_credential,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_llm_auth_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_auth_commands),
    @constCast(&ngx_http_llm_auth_module_ctx),
);
