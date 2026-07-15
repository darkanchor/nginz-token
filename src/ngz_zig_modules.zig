comptime {
    _ = @import("modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig");
    _ = @import("modules/llm-auth-nginx-module/ngx_http_llm_auth.zig");
    _ = @import("modules/llm-metrics-nginx-module/ngx_http_llm_metrics.zig");
    _ = @import("modules/llm-fallback-nginx-module/ngx_http_llm_fallback.zig");
    _ = @import("modules/llm-ratelimit-nginx-module/ngx_http_llm_ratelimit.zig");
    _ = @import("modules/llm-cost-nginx-module/ngx_http_llm_cost.zig");
    _ = @import("modules/llm-cache-nginx-module/ngx_http_llm_cache.zig");
    _ = @import("modules/llm-security-nginx-module/ngx_http_llm_security.zig");
}
