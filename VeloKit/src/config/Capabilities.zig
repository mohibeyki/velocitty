//! Actions exposed by the Velocitty host. Shared by configuration and command UI.
const std = @import("std");
const Binding = @import("../input/Binding.zig");

pub fn supported(action: Binding.Action) bool {
    const unsupported = std.StaticStringMap(void).initComptime(.{
        .{ "show_on_screen_keyboard", {} },
        .{ "move_tab_to_new_window", {} }, .{ "equalize_splits", {} },
        .{ "toggle_split_zoom", {} }, .{ "toggle_tab_overview", {} }, .{ "toggle_quick_terminal", {} },
        .{ "undo", {} }, .{ "redo", {} }, .{ "check_for_updates", {} }, .{ "inspector", {} },
        .{ "show_gtk_inspector", {} }, .{ "crash", {} }, .{ "export_terminal_io", {} },
        .{ "toggle_window_decorations", {} },
    });
    return !unsupported.has(@tagName(action));
}

export fn velokit_action_supported(value: [*:0]const u8) bool {
    return supported(Binding.Action.parse(std.mem.span(value)) catch return false);
}

pub fn optionSupported(key: []const u8, value: []const u8, alloc: std.mem.Allocator) !bool {
    if (std.mem.eql(u8, key, "keybind")) {
        var binding = value;
        const end = std.mem.indexOfScalar(u8, value, '=') orelse value.len;
        if (std.mem.indexOfScalar(u8, value[0..end], '/')) |slash| {
            if (slash > 0 and std.mem.indexOfAny(u8, value[0..slash], "+>") == null)
                binding = value[slash + 1 ..];
        }
        // Empty/reset/table declarations are handled by the native config parser.
        const parser = Binding.Parser.init(binding) catch return true;
        return supported(parser.action);
    }
    if (std.mem.eql(u8, key, "command-palette-entry") and value.len > 0) {
        var commands: @import("Config.zig").RepeatableCommand = .{};
        commands.parseCLI(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return true, // Let the regular parser diagnose syntax errors.
        };
        for (commands.value.items) |command| if (!supported(command.action)) return false;
    }
    return true;
}

pub fn prune(set: *Binding.Set, alloc: std.mem.Allocator) void {
    var index: usize = 0;
    while (index < set.bindings.count()) {
        const keep = switch (set.bindings.values()[index]) {
            .leaf => |leaf| supported(leaf.action),
            .leaf_chained => |leaf| keep: {
                for (leaf.actions.items) |action| if (!supported(action)) break :keep false;
                break :keep true;
            },
            .leader => |child| keep: {
                prune(child, alloc);
                break :keep child.bindings.count() > 0;
            },
        };
        if (keep) index += 1 else set.remove(alloc, set.bindings.keys()[index]);
    }
}

pub fn pruneCommands(commands: *@import("Config.zig").RepeatableCommand) void {
    var index: usize = 0;
    while (index < commands.value.items.len) {
        if (supported(commands.value.items[index].action)) {
            index += 1;
        } else {
            _ = commands.value.orderedRemove(index);
            _ = commands.value_c.orderedRemove(index);
        }
    }
}
