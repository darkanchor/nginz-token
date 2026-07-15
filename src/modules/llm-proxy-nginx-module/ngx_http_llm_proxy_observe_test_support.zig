const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const http = ngx.http;

const ngx_str_t = core.ngx_str_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_http_request_t = http.ngx_http_request_t;

// Mock must return the exact same layout as the real owner — alias the contract.
const LlmProxyObservable = contract.LlmProxyObservable;

export fn ngx_http_llm_proxy_observe(r: [*c]ngx_http_request_t) callconv(.c) LlmProxyObservable {
    _ = r;
    return std.mem.zeroes(LlmProxyObservable);
}

export fn ngx_http_llm_proxy_resolution_outcome(r: [*c]ngx_http_request_t) callconv(.c) ngx_uint_t {
    _ = r;
    return 0;
}

export fn ngx_http_llm_proxy_effective_provider(r: [*c]ngx_http_request_t) callconv(.c) ngx_str_t {
    _ = r;
    return std.mem.zeroes(ngx_str_t);
}

export fn ngx_http_llm_proxy_total_tokens(r: [*c]ngx_http_request_t) callconv(.c) ngx_uint_t {
    _ = r;
    return 0;
}
