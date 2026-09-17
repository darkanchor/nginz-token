const std = @import("std");
const builtin = @import("builtin");
const common = @import("project/build_common.zig");
const exe = @import("project/build_exe.zig");
const njs = @import("project/build_njs.zig");
const core = @import("project/build_core.zig");
const http = @import("project/build_http.zig");
const cjson = @import("project/build_cjson.zig");
const libinjection = @import("project/build_libinjection.zig");
const patch = @import("project/build_patch.zig");
const quickjs = @import("project/build_quickjs.zig");
const stream = @import("project/build_stream.zig");
const http_modules = @import("project/build_modules.zig");
const package = @import("project/build_package.zig");
const check_layout = @import("project/build_check_layout.zig");

const NGINX = "src/ngx/nginx.zig";
const required_zig_version = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

var modules = [_][]const u8{
    "src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig",
    "src/modules/llm-auth-nginx-module/ngx_http_llm_auth.zig",
    "src/modules/llm-metrics-nginx-module/ngx_http_llm_metrics.zig",
    "src/modules/llm-fallback-nginx-module/ngx_http_llm_fallback.zig",
    "src/modules/llm-ratelimit-nginx-module/ngx_http_llm_ratelimit.zig",
    "src/modules/llm-cost-nginx-module/ngx_http_llm_cost.zig",
    "src/modules/llm-cache-nginx-module/ngx_http_llm_cache.zig",
    "src/modules/llm-security-nginx-module/ngx_http_llm_security.zig",
};

var tests = [_][]const u8{
    "src/ngx/ngx_pq.zig",
    "src/ngx/ngx_buf.zig",
    "src/ngx/ngx_ssl.zig",
    "src/ngx/ngx_log.zig",
    "src/ngx/ngx_conf.zig",
    "src/ngx/ngx_core.zig",
    "src/ngx/ngx_file.zig",
    "src/ngx/ngx_hash.zig",
    "src/ngx/ngx_http.zig",
    "src/ngx/ngx_list.zig",
    "src/ngx/ngx_cjson.zig",
    "src/ngx/ngx_event.zig",
    "src/ngx/ngx_queue.zig",
    "src/ngx/ngx_array.zig",
    "src/ngx/ngx_module.zig",
    "src/ngx/ngx_rbtree.zig",
    "src/ngx/ngx_string.zig",

    "src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig",
    "src/modules/llm-auth-nginx-module/ngx_http_llm_auth.zig",
    "src/modules/llm-metrics-nginx-module/ngx_http_llm_metrics.zig",
    "src/modules/llm-fallback-nginx-module/ngx_http_llm_fallback.zig",
    "src/modules/llm-ratelimit-nginx-module/ngx_http_llm_ratelimit.zig",
    "src/modules/llm-cost-nginx-module/ngx_http_llm_cost.zig",
    "src/modules/llm-cache-nginx-module/ngx_http_llm_cache.zig",
    "src/modules/llm-security-nginx-module/ngx_http_llm_security.zig",
};

const PN = struct {
    p: []const u8,
    n: []const u8,
};

fn module_path(f: []const u8) PN {
    var l: usize = 0;
    var d: usize = 0;
    for (f, 0..) |c, i| {
        if (c == '/') {
            l = i;
        }
        if (c == '.') {
            d = i;
        }
    }
    return PN{ .p = f[0..l], .n = f[l + 1 .. d] };
}

fn requires_llm_proxy_test_support(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/modules/llm-auth-nginx-module/ngx_http_llm_auth.zig");
}

fn requires_llm_proxy_observe_test_support(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/modules/llm-metrics-nginx-module/ngx_http_llm_metrics.zig") or
        std.mem.eql(u8, path, "src/modules/llm-ratelimit-nginx-module/ngx_http_llm_ratelimit.zig") or
        std.mem.eql(u8, path, "src/modules/llm-cost-nginx-module/ngx_http_llm_cost.zig");
}

fn requires_llm_cost_observe_test_support(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/modules/llm-ratelimit-nginx-module/ngx_http_llm_ratelimit.zig");
}

fn requires_llm_auth_test_support(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig");
}

fn requires_llm_security_test_support(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig") or
        std.mem.eql(u8, path, "src/modules/llm-auth-nginx-module/ngx_http_llm_auth.zig");
}

fn requires_llm_fallback_test_support(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig") or
        std.mem.eql(u8, path, "src/modules/llm-auth-nginx-module/ngx_http_llm_auth.zig");
}

pub fn build(b: *std.Build) void {
    comptime {
        if (builtin.zig_version.order(required_zig_version) != .eq) {
            @compileError(std.fmt.comptimePrint(
                "nginz-token requires Zig {f}; found Zig {f}.",
                .{ required_zig_version, builtin.zig_version },
            ));
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const docker = b.option(bool, "docker", "configure with docker primitives") orelse false;

    const nginx = b.addModule("ngx", .{
        .root_source_file = b.path(NGINX),
        .target = target,
        .optimize = optimize,
    });

    const sig_opts = b.addOptions();
    sig_opts.addOption([]const u8, "nginx_signature", "8,4,8,0011111111010111011111111111111111");
    sig_opts.addOption(u32, "nginx_version", common.bundled_nginx_version());
    nginx.addImport("ngx_opts", sig_opts.createModule());

    const ngx_libinjection = b.createModule(.{
        .root_source_file = b.path("src/ngx/ngx_libinjection.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared cross-module ABI contract. Registered as a named module so every
    // compilation root (the bundled object, each *_test_support object, and the
    // standalone per-module test builds) imports the SAME struct definitions.
    // See src/modules/llm_contract.zig for why hand-copying these is unsafe.
    const llm_contract = b.createModule(.{
        .root_source_file = b.path("src/modules/llm_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    llm_contract.addImport("ngx", nginx);

    const patch_step = patch.patchStep(b, docker);

    // Build executable named "nginz-token"
    const nginz_token = b.addExecutable(.{
        .name = "nginz-token",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/nginz.zig"),
        }),
    });
    nginz_token.step.dependOn(patch_step);

    const ngz_modules = b.addObject(.{
        .name = "ngz_modules",
        .root_module = b.createModule(.{
            .pic = true,
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/ngz_modules.zig"),
            .link_libc = true,
        }),
    });
    nginz_token.root_module.addObject(ngz_modules);

    const ngz_zig_modules = b.addObject(.{
        .name = "ngz_zig_modules",
        .root_module = b.createModule(.{
            .pic = true,
            .root_source_file = b.path("src/ngz_zig_modules.zig"),
            .target = target,
            .optimize = common.cap_optimize(optimize),
            .link_libc = true,
        }),
    });
    for (modules) |m| {
        ngz_zig_modules.root_module.addIncludePath(b.path(module_path(m).p));
    }
    ngz_zig_modules.root_module.addImport("ngx", nginx);
    ngz_zig_modules.root_module.addImport("ngx_libinjection", ngx_libinjection);
    ngz_zig_modules.root_module.addImport("llm_contract", llm_contract);
    ngz_zig_modules.bundle_compiler_rt = true;
    nginz_token.root_module.addObject(ngz_zig_modules);

    const cjsonlib = cjson.build_cjson(b, target, optimize);
    const libinjectionlib = libinjection.build_libinjection(b, target, optimize);
    const package_step = package.createPackageSteps(
        b,
        target,
        optimize,
        nginx,
        cjsonlib,
        libinjectionlib,
    ) catch unreachable;
    const quickjslib = quickjs.build_quickjs(b, target, optimize);
    quickjslib.step.dependOn(patch_step);

    const njs_http_module = njs.build_njs(b, target, optimize, quickjslib) catch unreachable;
    nginz_token.root_module.addObject(njs_http_module);

    const corelib = core.build_core(b, target, optimize) catch unreachable;
    corelib.step.dependOn(patch_step);

    const httplib = http.build_http(b, target, optimize) catch unreachable;
    httplib.step.dependOn(&corelib.step);
    httplib.root_module.linkLibrary(corelib);

    const streamlib = stream.build_stream(b, target, optimize) catch unreachable;
    streamlib.step.dependOn(&corelib.step);
    streamlib.root_module.linkLibrary(corelib);

    const moduleslib = http_modules.build_modules(b, target, optimize) catch unreachable;
    moduleslib.step.dependOn(&httplib.step);
    moduleslib.root_module.linkLibrary(corelib);
    moduleslib.root_module.linkLibrary(httplib);

    nginz_token.root_module.link_libc = true;
    nginz_token.root_module.linkSystemLibrary("z", .{});
    nginz_token.root_module.linkSystemLibrary("pq", .{});
    nginz_token.root_module.linkSystemLibrary("ssl", .{});
    nginz_token.root_module.linkSystemLibrary("xml2", .{});
    nginz_token.root_module.linkSystemLibrary("xslt", .{});
    nginz_token.root_module.linkSystemLibrary("exslt", .{});
    nginz_token.root_module.linkSystemLibrary("crypt", .{});
    nginz_token.root_module.linkSystemLibrary("crypto", .{});
    nginz_token.root_module.linkSystemLibrary("pcre2-8", .{});
    nginz_token.root_module.linkSystemLibrary("pthread", .{});
    nginz_token.root_module.linkLibrary(corelib);
    nginz_token.root_module.linkLibrary(httplib);
    nginz_token.root_module.linkLibrary(streamlib);
    nginz_token.root_module.linkLibrary(moduleslib);
    nginz_token.root_module.linkLibrary(cjsonlib);
    nginz_token.root_module.linkLibrary(libinjectionlib);
    b.installArtifact(nginz_token);

    const test_step = b.step("test", "Run unit tests");
    package_step.dependOn(patch_step);

    const test_moduleslib = http_modules.build_test_modules(b, target, optimize) catch unreachable;
    test_moduleslib.step.dependOn(&httplib.step);
    test_moduleslib.root_module.linkLibrary(corelib);
    test_moduleslib.root_module.linkLibrary(httplib);
    test_step.dependOn(&test_moduleslib.step);

    const llm_proxy_test_support = b.addObject(.{
        .name = "ngx_http_llm_proxy_test_support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llm_proxy_test_support.root_module.addIncludePath(b.path("src/ngx/"));
    llm_proxy_test_support.root_module.addImport("ngx", nginx);
    llm_proxy_test_support.root_module.addImport("ngx_opts", sig_opts.createModule());
    llm_proxy_test_support.root_module.addImport("ngx_libinjection", ngx_libinjection);
    llm_proxy_test_support.root_module.addImport("llm_contract", llm_contract);

    const llm_proxy_observe_test_support = b.addObject(.{
        .name = "ngx_http_llm_proxy_observe_test_support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/llm-proxy-nginx-module/ngx_http_llm_proxy_observe_test_support.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llm_proxy_observe_test_support.root_module.addIncludePath(b.path("src/ngx/"));
    llm_proxy_observe_test_support.root_module.addImport("ngx", nginx);
    llm_proxy_observe_test_support.root_module.addImport("ngx_opts", sig_opts.createModule());
    llm_proxy_observe_test_support.root_module.addImport("ngx_libinjection", ngx_libinjection);
    llm_proxy_observe_test_support.root_module.addImport("llm_contract", llm_contract);

    const llm_auth_test_support = b.addObject(.{
        .name = "ngx_http_llm_auth_test_support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/llm-auth-nginx-module/ngx_http_llm_auth.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llm_auth_test_support.root_module.addIncludePath(b.path("src/ngx/"));
    llm_auth_test_support.root_module.addImport("ngx", nginx);
    llm_auth_test_support.root_module.addImport("ngx_opts", sig_opts.createModule());
    llm_auth_test_support.root_module.addImport("ngx_libinjection", ngx_libinjection);
    llm_auth_test_support.root_module.addImport("llm_contract", llm_contract);

    const llm_security_test_support = b.addObject(.{
        .name = "ngx_http_llm_security_test_support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/llm-security-nginx-module/ngx_http_llm_security.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llm_security_test_support.root_module.addIncludePath(b.path("src/ngx/"));
    llm_security_test_support.root_module.addImport("ngx", nginx);
    llm_security_test_support.root_module.addImport("ngx_opts", sig_opts.createModule());
    llm_security_test_support.root_module.addImport("ngx_libinjection", ngx_libinjection);
    llm_security_test_support.root_module.addImport("llm_contract", llm_contract);

    const llm_fallback_test_support = b.addObject(.{
        .name = "ngx_http_llm_fallback_test_support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/llm-fallback-nginx-module/ngx_http_llm_fallback.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llm_fallback_test_support.root_module.addIncludePath(b.path("src/ngx/"));
    llm_fallback_test_support.root_module.addImport("ngx", nginx);
    llm_fallback_test_support.root_module.addImport("ngx_opts", sig_opts.createModule());
    llm_fallback_test_support.root_module.addImport("ngx_libinjection", ngx_libinjection);
    llm_fallback_test_support.root_module.addImport("llm_contract", llm_contract);

    const llm_cost_observe_test_support = b.addObject(.{
        .name = "ngx_http_llm_cost_observe_test_support",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/llm-cost-nginx-module/ngx_http_llm_cost_observe_test_support.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    llm_cost_observe_test_support.root_module.addIncludePath(b.path("src/ngx/"));
    llm_cost_observe_test_support.root_module.addImport("ngx", nginx);
    llm_cost_observe_test_support.root_module.addImport("ngx_opts", sig_opts.createModule());
    llm_cost_observe_test_support.root_module.addImport("ngx_libinjection", ngx_libinjection);
    llm_cost_observe_test_support.root_module.addImport("llm_contract", llm_contract);

    for (tests) |case| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(case),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        t.root_module.linkSystemLibrary("z", .{});
        t.root_module.linkSystemLibrary("pq", .{});
        t.root_module.linkSystemLibrary("ssl", .{});
        t.root_module.linkSystemLibrary("xml2", .{});
        t.root_module.linkSystemLibrary("xslt", .{});
        t.root_module.linkSystemLibrary("exslt", .{});
        t.root_module.linkSystemLibrary("crypt", .{});
        t.root_module.linkSystemLibrary("crypto", .{});
        t.root_module.linkSystemLibrary("pcre2-8", .{});
        t.root_module.linkSystemLibrary("pthread", .{});
        t.root_module.linkLibrary(corelib);
        t.root_module.linkLibrary(httplib);
        t.root_module.linkLibrary(streamlib);
        t.root_module.linkLibrary(cjsonlib);
        t.root_module.linkLibrary(libinjectionlib);
        t.root_module.linkLibrary(test_moduleslib);
        if (requires_llm_proxy_test_support(case)) {
            t.root_module.addObject(llm_proxy_test_support);
        }
        if (requires_llm_proxy_observe_test_support(case)) {
            t.root_module.addObject(llm_proxy_observe_test_support);
        }
        if (requires_llm_auth_test_support(case)) {
            t.root_module.addObject(llm_auth_test_support);
        }
        if (requires_llm_security_test_support(case)) {
            t.root_module.addObject(llm_security_test_support);
        }
        if (requires_llm_fallback_test_support(case)) {
            t.root_module.addObject(llm_fallback_test_support);
        }
        if (requires_llm_cost_observe_test_support(case)) {
            t.root_module.addObject(llm_cost_observe_test_support);
        }
        t.root_module.addIncludePath(b.path("src/ngx/"));
        t.root_module.addImport("ngx", nginx);
        t.root_module.addImport("ngx_opts", sig_opts.createModule());
        t.root_module.addImport("ngx_libinjection", ngx_libinjection);
        t.root_module.addImport("llm_contract", llm_contract);

        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }

    const check_layout_step = b.step("check-layout", "Check C vs Zig struct layout compatibility");
    check_layout_step.dependOn(check_layout.addCheckLayoutSteps(b, target, optimize, nginx, patch_step));
}
