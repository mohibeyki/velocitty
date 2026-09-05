//! Logging for Velocitty's private terminal engine.
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const macos = @import("macos");
const global = @import("global.zig");

// The function std.log will call.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // On Mac, we use unified logging. To view this:
    //
    //   log stream --level debug --predicate 'subsystem=="app.velocitty.velokit"'
    //
    // macOS logging is thread safe so no need for locks/mutexes
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!global.logging().macos) break :macos;

        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

        // Convert our levels to Mac levels
        const mac_level: macos.os.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };

        macosLogger(scope).log(
            std.heap.c_allocator,
            mac_level,
            prefix ++ format,
            args,
        );
    }

    stderr: {
        // don't log debug messages to stderr unless we are a debug build
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;

        // skip if we are not logging to stderr
        if (!global.logging().stderr) break :stderr;

        // Lock so we are thread-safe
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();

        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend stderr.file_writer.interface.print(level_txt ++ prefix ++ format ++ "\n", args) catch break :stderr;
        nosuspend stderr.file_writer.interface.flush() catch break :stderr;
    }
}

/// Returns the macOS unified logging logger for the given scope. The
/// logger is created once per scope and cached for the lifetime of the
/// process, because os_log object creation is slow (it shows up in
/// startup profiles when done per log call) and Apple's guidance is to
/// create loggers once and reuse them.
fn macosLogger(comptime scope: @TypeOf(.EnumLiteral)) *macos.os.Log {
    const S = struct {
        var cached: std.atomic.Value(?*macos.os.Log) = .init(null);
    };

    if (S.cached.load(.acquire)) |v| return v;

    // Create and attempt to store our logger. If we race with another
    // thread then we use theirs and release ours.
    const created = macos.os.Log.create(
        build_config.log_subsystem,
        @tagName(scope),
    );
    if (S.cached.cmpxchgStrong(
        null,
        created,
        .acq_rel,
        .acquire,
    )) |existing| {
        created.release();
        return existing.?;
    }

    return created;
}

pub const std_options: std.Options = .{
    // Our log level is always at least info in every build mode.
    //
    // Note, we don't lower this to debug even with conditional logging
    // via GHOSTTY_LOG because our debug logs are very expensive to
    // calculate and we want to make sure they're optimized out in
    // builds.
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },

    .logFn = logFn,

    // If are building for a non-MacOS Darwin target (e.g., iOS), we need to
    // disable stack tracing for the time being. This is due to the fact that
    // Zig switched to using _dyld_get_image_header_containing_address and some
    // other (deprecated) calls to speed up stack unwinding; these calls are
    // available on MacOS, but not on other platforms.
    //
    // A fix has already been submitted to exempt non-MacOS (but still Darwin)
    // targets, so this can likely be removed in Zig 0.17.0, or a 0.16.x patch
    // version if it releases beforehand.
    //
    // More details:
    //   https://codeberg.org/ziglang/zig/commit/89f86e46d278a35a613bbc662cdd3f65ffc76ed7
    //
    .allow_stack_tracing = if (builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .macos)
        false
    else
        !builtin.strip_debug_info,
};
