//! Private Swift/Zig entry point for Velocitty.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const builtin = @import("builtin");
const logging = @import("logging.zig");
const global = @import("global.zig");
const apprt = @import("apprt.zig");

// Some comptime assertions that our C API depends on.
comptime {
    // This bridge is only for the embedded runtime.
    if (!builtin.is_test) {
        assert(apprt.runtime == apprt.embedded);
    }
}

/// Process-wide engine logging.
pub const std_options = logging.std_options;

comptime {
    // These structs need to be referenced so the `export` functions
    // are truly exported by the C API lib.

    // Our config API
    _ = @import("config.zig").CApi;

    // Any apprt-specific C API, mainly libghostty for apprt.embedded.
    if (@hasDecl(apprt.runtime, "CAPI")) _ = apprt.runtime.CAPI;

    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

/// Initialize the terminal engine.
pub export fn velokit_init(argc: usize, argv: [*][*:0]u8) c_int {
    assert(builtin.link_libc);

    global.init(.{
        .c = .{
            .argc = argc,
            .argv = argv,
            .environ = if (std.process.Environ.Block == std.process.Environ.PosixBlock)
                // Asserting libc means that we can fast-path all POSIX blocks
                .{ .block = .{ .slice = std.c.environ[0..env_len: {
                    var len: usize = 0;
                    while (std.c.environ[len]) |_| : (len += 1) {}
                    break :env_len len;
                } :null] } }
            else
                // Anything that is not using PosixBlock is a global block for
                // purposes of initialization.
                .{ .block = .{ .use_global = true } },
        },
    }) catch |err| {
        std.log.err("failed to initialize VeloKit error={}", .{err});
        return 1;
    };

    return 0;
}
