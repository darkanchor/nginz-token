const std = @import("std");

// nginx's main() returns int; renamed to main_nginx by project/nginz.patch.
extern fn main_nginx(argn: c_int, args: [*c][*c]const u8) callconv(.c) c_int;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    defer args.deinit();

    var args_array = std.array_list.Managed([*c]const u8).init(init.gpa);
    defer args_array.deinit();

    while (args.next()) |a| {
        try args_array.append(a.ptr);
    }
    const rc = main_nginx(@intCast(args_array.items.len), @ptrCast(args_array.items));
    // nginx's main returns 1 on error (e.g. bad config), 0 on success.
    // Propagate the code so callers such as `nginz-token -t` exit non-zero on failure.
    if (rc != 0) std.process.exit(@intCast(rc));
}
