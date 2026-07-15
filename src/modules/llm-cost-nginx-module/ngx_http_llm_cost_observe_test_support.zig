const std = @import("std");
const ngx = @import("ngx");
const contract = @import("llm_contract");

const core = ngx.core;
const http = ngx.http;

const ngx_str_t = core.ngx_str_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_http_request_t = http.ngx_http_request_t;

// Mock must return the exact same layout as the real owner — alias the contract.
const LlmCostObservable = contract.LlmCostObservable;

export fn ngx_http_llm_cost_observe(r: [*c]ngx_http_request_t) callconv(.c) LlmCostObservable {
    _ = r;
    return std.mem.zeroes(LlmCostObservable);
}

export fn ngx_http_llm_cost_unit_for_provider(r: [*c]ngx_http_request_t, provider: ngx_str_t) callconv(.c) ngx_str_t {
    _ = r;
    _ = provider;
    return ngx_str_t{ .data = @constCast("usd"), .len = 3 };
}
