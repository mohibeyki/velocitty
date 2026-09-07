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

export fn velokit_config_clone(self: *const Config) ?*Config {
    const result = global.alloc().create(Config) catch return null;
    result.* = self.clone(global.alloc()) catch {
        global.alloc().destroy(result);
        return null;
    };
    return result;
}

// Use one argument per value, never a generated config file: embedded newlines
// and equals signs stay inside the value and cannot introduce another setting.
export fn velokit_config_set(self: *Config, key_z: [*:0]const u8, value_z: [*:0]const u8) bool {
    const previous_diagnostics = self._diagnostics.precompute.messages.items.len;
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
    return self._diagnostics.precompute.messages.items.len == previous_diagnostics;
}

// Returned message belongs to the configuration and stays valid until freed
// or modified. Swift copies it before releasing a failed candidate.
export fn velokit_config_error(self: *const Config) ?[*:0]const u8 {
    return velokit_config_diagnostic(self, 0);
}

export fn velokit_config_diagnostic(self: *const Config, index: usize) ?[*:0]const u8 {
    const messages = self._diagnostics.precompute.messages.items;
    return if (index < messages.len) messages[index].ptr else null;
}

export fn velokit_config_finalize(self: *Config, base: [*:0]const u8) bool {
    if (!self._diagnostics.empty()) return false;
    self.expandPaths(std.mem.span(base)) catch return false;
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
        return false;
    };
    // Path diagnostics are recoverable: the engine removes unusable paths.
    // False is reserved for failures that prevent finalization itself.
    return true;
}

// Check the native value's C representation before writing to a typed destination.
// Failed reads leave output untouched. Borrowed pointers live with the config.
fn readChecked(comptime Out: type, self: *const Config, key_z: [*:0]const u8, output: *Out) bool {
    @setEvalBranchQuota(100_000);
    const key = std.meta.stringToEnum(Config.Key, std.mem.span(key_z)) orelse return false;
    switch (key) {
        inline else => |tag| return writeChecked(Out, @field(self, @tagName(tag)), output),
    }
}

fn writeChecked(comptime Out: type, value: anytype, output: *Out) bool {
    const T = @TypeOf(value);
    if (T == Out) {
        output.* = value;
        return true;
    }
    switch (@typeInfo(T)) {
        .optional => return writeChecked(Out, value orelse return false, output),
        .@"enum" => if (Out == ?[*:0]const u8) {
            output.* = @tagName(value);
            return true;
        },
        .pointer => if (T == [:0]const u8 and Out == ?[*:0]const u8) {
            output.* = value.ptr;
            return true;
        },
        .int => if (T == u8 and Out == u32) {
            output.* = value;
            return true;
        },
        .@"struct", .@"union" => {
            if (@hasDecl(T, "cval")) return writeChecked(Out, value.cval(), output);
            if (@typeInfo(T) == .@"struct") {
                const info = @typeInfo(T).@"struct";
                if (info.layout == .@"packed" and Out == u32) {
                    const Backing = info.backing_integer.?;
                    if (@bitSizeOf(Backing) <= 32) {
                        output.* = @intCast(@as(Backing, @bitCast(value)));
                        return true;
                    }
                }
            }
        },
        else => {},
    }
    return false;
}

export fn velokit_config_get_bool(self: *const Config, key: [*:0]const u8, output: *bool) bool {
    return readChecked(bool, self, key, output);
}

export fn velokit_config_get_int16(self: *const Config, key: [*:0]const u8, output: *i16) bool {
    return readChecked(i16, self, key, output);
}

export fn velokit_config_get_uint32(self: *const Config, key: [*:0]const u8, output: *u32) bool {
    return readChecked(u32, self, key, output);
}

export fn velokit_config_get_double(self: *const Config, key: [*:0]const u8, output: *f64) bool {
    return readChecked(f64, self, key, output);
}

export fn velokit_config_get_milliseconds(self: *const Config, key: [*:0]const u8, output: *usize) bool {
    return readChecked(usize, self, key, output);
}

export fn velokit_config_get_string(self: *const Config, key: [*:0]const u8, output: *?[*:0]const u8) bool {
    return readChecked(?[*:0]const u8, self, key, output);
}

export fn velokit_config_get_color(self: *const Config, key: [*:0]const u8, output: *Config.Color.C) bool {
    return readChecked(Config.Color.C, self, key, output);
}

export fn velokit_config_get_path(self: *const Config, key: [*:0]const u8, output: *Config.Path.C) bool {
    return readChecked(Config.Path.C, self, key, output);
}

export fn velokit_config_get_commands(self: *const Config, key: [*:0]const u8, output: *Config.RepeatableCommand.C) bool {
    return readChecked(Config.RepeatableCommand.C, self, key, output);
}

// Our header uses a 32-bit C modifier enum; the engine's packed Mods is 16-bit.
const CTrigger = extern struct {
    tag: @import("../input/Binding.zig").Trigger.C.Tag,
    key: @import("../input/Binding.zig").Trigger.C.Key,
    mods: u32,

    fn init(trigger: @import("../input/Binding.zig").Trigger) CTrigger {
        return .{
            .tag = trigger.key,
            .key = switch (trigger.key) {
                .physical => |key| .{ .physical = key },
                .unicode => |codepoint| .{ .unicode = @intCast(codepoint) },
                .catch_all => .{ .unicode = 0 },
            },
            .mods = @as(u16, @bitCast(trigger.mods)),
        };
    }
};

// Enumerate final global triggers, after remaps, clears, and overrides.
export fn velokit_config_global_trigger(self: *Config, index: usize, output: *CTrigger) bool {
    var count: usize = 0;
    var iterator = self.keybind.set.bindings.iterator();
    while (iterator.next()) |entry| {
        const flags = switch (entry.value_ptr.*) {
            .leaf => |leaf| leaf.flags,
            .leaf_chained => |leaf| leaf.flags,
            .leader => continue,
        };
        if (!flags.global) continue;
        if (count == index) {
            output.* = .init(entry.key_ptr.*);
            return true;
        }
        count += 1;
    }
    return false;
}

export fn velokit_keycode_for_key(key: @import("../input/key.zig").Key) u32 {
    for (@import("../input/keycodes.zig").entries) |entry| {
        if (entry.key == key) return entry.native;
    }
    return std.math.maxInt(u32);
}

export fn velokit_config_trigger(self: *Config, action_z: [*:0]const u8, output: *CTrigger) bool {
    const Binding = @import("../input/Binding.zig");
    const action = Binding.Action.parse(std.mem.span(action_z)) catch return false;
    // The engine reverse map deliberately omits performable bindings. AppKit
    // menus still need their labels (and standard editing shortcuts in fields).
    // Prefer the last usable binding; ignore unmapped dedicated Copy/Paste keys.
    const keys = self.keybind.set.bindings.keys();
    const values = self.keybind.set.bindings.values();
    var index = keys.len;
    while (index > 0) {
        index -= 1;
        const leaf = switch (values[index]) {
            .leaf => |value| value,
            else => continue,
        };
        if (!leaf.action.equal(action) or !leaf.flags.consumed) continue;
        const trigger = keys[index];
        switch (trigger.key) {
            .physical => |key| if (velokit_keycode_for_key(key) >= 128) {
                continue;
            },
            .unicode => {},
            .catch_all => continue,
        }
        output.* = .init(trigger);
        return true;
    }
    return false;
}

// Formatting uses the engine's own serializers so defaults cannot drift from
// the implementation. The returned string belongs to this configuration.
export fn velokit_config_format(self: *Config, key_z: [*:0]const u8) ?[*:0]const u8 {
    const key = std.meta.stringToEnum(Config.Key, std.mem.span(key_z)) orelse return null;
    var buf: std.Io.Writer.Allocating = .init(global.alloc());
    defer buf.deinit();
    switch (key) {
        inline else => |tag| {
            const value = @field(self, @tagName(tag));
            @import("formatter.zig").formatEntry(@TypeOf(value), @tagName(tag), value, &buf.writer) catch return null;
        },
    }
    return (self.arenaAlloc().dupeZ(u8, buf.written()) catch return null).ptr;
}
