#!/bin/sh
set -eu

token_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
nginz_root=${NGINZ_ROOT:-"$(dirname "$token_root")/nginz"}
nginx_source="$nginz_root/submodules/nginx"
build_root=${COMBINED_BUILD_ROOT:-"${TMPDIR:-/tmp}/nginz-token-combined-nginx.$$"}
trap 'rm -rf "$build_root"' EXIT HUP INT TERM

zig build --build-file "$nginz_root/build.zig" --cache-dir "$nginz_root/.zig-cache" \
    --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}" \
    -Doptimize=ReleaseSmall package
zig build --build-file "$token_root/build.zig" --cache-dir "$token_root/.zig-cache" \
    --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}" \
    -Doptimize=ReleaseSmall package

quickjs_version=$(cat "$nginz_root/submodules/quickjs/VERSION")
make -C "$nginz_root/submodules/quickjs" \
    CFLAGS="-fPIC -fwrapv -D_GNU_SOURCE -DCONFIG_VERSION=\\\"$quickjs_version\\\"" \
    libquickjs.a

rm -rf "$build_root"
cp -a "$nginx_source" "$build_root"
cd "$build_root"
set -- ./auto/configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --add-module="$nginz_root/submodules/njs/nginx" \
    --with-cc-opt="-I $nginz_root/submodules/quickjs" \
    --with-ld-opt="-L $nginz_root/submodules/quickjs"

for module in \
    hello pgrest redis consul worker-events healthcheck cache-tags cache-purge \
    upstream-balancer dynamic-upstreams jwt acme jsonschema canary ratelimit \
    circuit-breaker graphql prometheus echoz requestid waf transform oidc wechatpay
do
    set -- "$@" "--add-module=$nginz_root/zig-out/modules/$module"
done

for module in \
    llm-proxy llm-auth llm-metrics llm-fallback llm-ratelimit llm-cost llm-cache llm-security
do
    set -- "$@" "--add-module=$token_root/zig-out/modules/$module"
done

"$@"
make -j"${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

mkdir -p "$token_root/zig-out/bin"
cp objs/nginx "$token_root/zig-out/bin/nginz-token-all"
printf '%s\n' "$token_root/zig-out/bin/nginz-token-all"
