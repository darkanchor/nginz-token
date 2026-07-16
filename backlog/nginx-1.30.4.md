# Deferred nginx 1.30.4 migration

Status: deferred until the next stable-release backlog batch.

The published release must remain pinned to nginx 1.30.3 and retain its current
Zig bindings. Do not apply any item below to an already released image.

## Upstream range

- Current tag: `release-1.30.3`
- Current commit: `47c3628d23efaa1bfb1a32afbe9e3d013f860c2c`
- Target tag: `release-1.30.4`
- Target commit: `017cf98dcce217946572a896f0992370475e189f`
- Review range: `release-1.30.3..release-1.30.4`

The range contains nginx script-buffer bounds checks, stale regex-capture
cleanup, access-log bounds checks, and duplicate subrequest-finalization
protection. It changes 19 upstream files, including both HTTP and stream script
engines. The released images may currently be HTTP-focused, but this repository
must retain the same HTTP and stream binding/check-layout surface as
`nginz-token`. Release timing is the intended difference between the two
repositories; omitting stream compatibility work is not.

## Required release-batch changes

1. Update `submodules/nginx` from `release-1.30.3` to `release-1.30.4` and verify
   the gitlink points to `017cf98dcce217946572a896f0992370475e189f`.
2. Update `ngx_http_script_engine_t` in `src/ngx/ngx.zig` by adding
   `end: [*c]u_char` immediately after `pos`. This mirrors the new upstream
   buffer-end pointer.
3. Update the HTTP layout assertions in `src/ngx/ngx_http.zig`:
   - `@sizeOf(ngx_http_script_engine_t)`: `88` -> `96`
   - `ngx_http_script_engine_t.flags.flushed` byte offset: `64` -> `72`
4. Apply the same stream binding gap fixes required for the corresponding
   `nginz-token` migration. These belong in the batch even when no released
   image currently exposes a stream workload:
   - define `ngx_stream_script_engine_t` in `src/ngx/ngx_vx.zig`, including the
     nginx 1.30.4 `end` pointer after `pos`, its flags, `status`, and `session`;
   - expose `ngx_stream_script_check_length`;
   - align the missing stream upstream/server, shared-zone, resolver,
     round-robin-zone, and session regex-capture fields with the bundled nginx
     configuration;
   - replace placeholder stream layout tests with exact size assertions for the
     script engine, session, upstream server/configuration, and round-robin
     peer/peer-set structures.
5. Add the C-vs-Zig `check-layout` build step before accepting the release and
   enable its stream half with `-DNGX_STREAM=1`. Keep the C and Zig probes
   aligned for stream structure sizes, key offsets, and bitfields, including
   `ngx_stream_script_engine_t.end`, `.status`, and `.flushed`.
6. Compare the completed migration against the reviewed `nginz-token` migration
   and account for every difference. Apart from release-only metadata and image
   packaging, the nginx bindings, layout checker, and tests should match.
7. Review the final staged diff to ensure no unrelated feature, dependency, or
   image-content changes are folded into the stable nginx patch batch.

## Verification gate

Run at minimum:

```sh
zig build check-layout
zig build test
zig build
bun test tests/llm-proxy/
```

The full HTTP/core/stream reference result from the aligned 1.30.4 bindings is
247 layout checks with zero mismatches. Retain the existing 221 passing
`llm-proxy` tests as the application regression baseline.

Before publishing replacement images:

- confirm `nginz-token -V` reports nginx 1.30.4;
- run configuration tests and startup smoke tests for every released image
  variant;
- run at least one stream configuration/startup smoke test so the retained
  stream ABI is exercised rather than compile-only;
- exercise representative buffered, streaming/SSE, rewrite, proxy, and access
  log paths affected by the upstream range;
- rebuild the complete stable image matrix from the same reviewed commit;
- retain the last 1.30.3 image digests and rollback procedure until the new
  images pass the release soak.

## Explicitly deferred

This backlog entry records future work only. The nginx submodule, generated or
manual Zig bindings, build graph, tests, and released Docker artifacts remain
unchanged in the current stable release.
