//! Private configuration bridge for Velocitty.
const global = @import("../global.zig");
const Config = @import("Config.zig");
const std = @import("std");
const log = std.log.scoped(.config);

export fn velokit_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn velokit_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

// Use one argument per value, never a generated config file: embedded newlines
// and equals signs stay inside the value and cannot introduce another setting.
export fn velokit_config_set(self: *Config, key_z: [*:0]const u8, value_z: [*:0]const u8) bool {
    const key = std.mem.span(key_z);
    const value = std.mem.span(value_z);
    for (key) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    if (key.len == 0) return false;
    const alloc = self.arenaAlloc();
    const arg = std.fmt.allocPrintSentinel(alloc, "--{s}={s}", .{ key, value }, 0) catch return false;
    var iter = struct {
        arg: ?[:0]const u8,
        pub fn next(it: *@This()) ?[:0]const u8 {
            defer it.arg = null;
            return it.arg;
        }
    }{ .arg = arg };
    self.loadIter(global.alloc(), &iter) catch return false;

    // The native numeric parser accepts NaN/Infinity. They cannot be used by
    // the renderer safely, even when supplied as TOML strings.
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .float) {
            if (!std.math.isFinite(@field(self, field.name))) {
                self._diagnostics.append(alloc, .{
                    .key = field.name,
                    .message = "must be finite",
                }) catch return false;
            }
        }
    }
    return self._diagnostics.empty();
}

// Returned message belongs to the configuration and stays valid until freed
// or modified. Swift copies it before releasing a failed candidate.
export fn velokit_config_error(self: *const Config) ?[*:0]const u8 {
    const messages = self._diagnostics.precompute.messages.items;
    return if (messages.len > 0) messages[0].ptr else null;
}

export fn velokit_config_finalize(self: *Config, base: [*:0]const u8) bool {
    self.expandPaths(std.mem.span(base)) catch return false;
    if (!self._diagnostics.empty()) return false;
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
        return false;
    };
    return self._diagnostics.empty();
}

export fn velokit_config_get(self: *Config, ptr: *anyopaque, key_str: [*]const u8, len: usize) bool {
    const Key = @import("key.zig").Key;
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return @import("c_get.zig").get(self, key, ptr);
}
