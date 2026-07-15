const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;

const ngx_flag_t = core.ngx_flag_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_string = ngx.string.ngx_string;

const llm_cache_loc_conf = extern struct {
    enabled: ngx_flag_t,
};

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(llm_cache_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        return p;
    }
    return null;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(llm_cache_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(llm_cache_loc_conf, child) orelse return conf.NGX_CONF_OK;
    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_llm_cache(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(llm_cache_loc_conf, loc)) |lccf| lccf.*.enabled = 1;
    return conf.NGX_CONF_OK;
}

export const ngx_http_llm_cache_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_llm_cache_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("llm_cache"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_llm_cache,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_llm_cache_module = ngx.module.make_module(
    @constCast(&ngx_http_llm_cache_commands),
    @constCast(&ngx_http_llm_cache_module_ctx),
);
