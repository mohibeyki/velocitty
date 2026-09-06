//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const global = @import("../global.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.embedded_window);

pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.c) void,

        /// Callback called to handle an action.
        action: *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool,

        /// Read the clipboard value. The result only reports facts about
        /// the clipboard: whether the request was started (in which case
        /// complete_clipboard_request or deny_clipboard_request must
        /// eventually be called with the given state pointer), whether the
        /// clipboard has no servable contents, or whether the clipboard
        /// can't be read at all. How each non-started state is answered is
        /// up to the core.
        ///
        /// The MIME types are exactly the representations the caller wants
        /// served; the embedder should read only those. Text-like types
        /// are always requested as the canonical "text/plain". The final
        /// bool asks for the listing of all MIME types available on the
        /// clipboard to be delivered with the completion.
        read_clipboard: *const fn (
            SurfaceUD,
            c_int,
            *apprt.ClipboardRequest,
            [*]const [*:0]const u8,
            usize,
            bool,
        ) callconv(.c) apprt.ClipboardReadResult,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The
        /// embedder must call complete_clipboard_request (usually with
        /// the confirmation's contents, which are only borrowed for
        /// this call) or deny_clipboard_request with the given request.
        confirm_read_clipboard: *const fn (
            SurfaceUD,
            *const CAPI.ClipboardConfirm,
            *apprt.ClipboardRequest,
            apprt.ClipboardRequestType,
        ) callconv(.c) void,

        /// Write the clipboard value.
        write_clipboard: *const fn (
            SurfaceUD,
            c_int,
            [*]const CAPI.ClipboardContent,
            usize,
            bool,
        ) callconv(.c) void,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,
    };

    /// This is the key event sent for velokit_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        action: input.Action,
        mods: input.Mods,
        consumed_mods: input.Mods,
        keycode: u32,
        text: ?[:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert a libghostty key event into a core key event.
        fn core(self: KeyEvent) ?input.KeyEvent {
            const text: []const u8 = if (self.text) |v| v else "";
            const unshifted_codepoint: u21 = std.math.cast(
                u21,
                self.unshifted_codepoint,
            ) orelse 0;

            // We want to get the physical unmapped key to process keybinds.
            const physical_key = keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;

            // Build our final key event
            return .{
                .action = self.action,
                .key = physical_key,
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }
    };

    core_app: *CoreApp,
    opts: Options,

    /// The keyboard layout keymap. This is lazily initialized on first
    /// use because creating it requires talking to the text input
    /// system (TIS on macOS), and the first such call in a process is
    /// slow (multiple milliseconds). It is only needed once keyboard
    /// events start flowing, at which point the system is warm.
    keymap: ?input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = null,
        };
    }

    pub fn terminate(self: *App) void {
        if (self.keymap) |*v| v.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = event.core() orelse
            return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => true,
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap. If it was never initialized we don't need
        // to do anything since lazy initialization will pick up the
        // current layout.
        if (self.keymap) |*v| try v.reload();
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Lazily initialize the keymap.
        const keymap: *input.Keymap = keymap: {
            if (self.keymap == null) {
                self.keymap = input.Keymap.init() catch |err| {
                    log.warn("error initializing keymap err={}", .{err});
                    return .unknown;
                };
            }

            break :keymap &self.keymap.?;
        };

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(self: *App, opts: Surface.Options) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface
        try surface.init(self, opts);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }

    /// Send the given IPC to a running Ghostty. Returns `true` if the action was
    /// able to be performed, `false` otherwise.
    ///
    /// Note that this is a static function. Since this is called from a CLI app (or
    /// some other process that is not Ghostty) there is no full-featured apprt App
    /// to use.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || apprt.ipc.Errors)!bool {
        switch (action) {
            .new_window => return false,
            .new_tab => return false,
            .toggle_quick_terminal => return false,
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = std.enums.fromInt(PlatformTag, tag_int) orelse return error.InvalidEnumTag;
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: [*:0]const u8,

    /// The value of the environment variable.
    value: [*:0]const u8,
};

pub const Surface = struct {
    app: *App,
    platform: Platform,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    inspector: ?*Inspector = null,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: ?[*:0]const u8 = null,

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        ///
        /// This command always run in a shell (e.g. via `/bin/sh -c`),
        /// despite Ghostty allowing directly executed commands via config.
        /// This is a legacy thing and we should probably change it in the
        /// future once we have a concrete use case.
        command: ?[*:0]const u8 = null,

        /// Extra environment variables to set for the surface.
        env_vars: ?[*]EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                var dir = std.Io.Dir.openDirAbsolute(global.io(), wd, .{}) catch |err| {
                    log.warn(
                        "error opening requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };
                defer dir.close(global.io());

                const stat = dir.stat(global.io()) catch |err| {
                    log.warn(
                        "failed to stat requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };

                if (stat.kind != .directory) {
                    log.warn(
                        "requested working directory is not a directory dir={s}",
                        .{wd},
                    );
                    break :wd;
                }

                var wd_val: configpkg.WorkingDirectory = .{ .path = wd };
                if (wd_val.finalize(config.arenaAlloc())) |_| {
                    config.@"working-directory" = wd_val;
                } else |err| {
                    log.warn(
                        "error finalizing working directory config dir={s} err={}",
                        .{ wd_val.path, err },
                    );
                }
            }
        }

        // If we have a command from the options then we set it.
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        if (opts.env_var_count > 0) {
            const alloc = config.arenaAlloc();
            for (opts.env_vars.?[0..opts.env_var_count]) |env_var| {
                const key = std.mem.sliceTo(env_var.key, 0);
                const value = std.mem.sliceTo(env_var.value, 0);
                try config.env.map.put(
                    alloc,
                    try alloc.dupeZ(u8, key),
                    try alloc.dupeZ(u8, value),
                );
            }
        }

        // If we have an initial input then we set it.
        if (opts.initial_input) |c_input| {
            const alloc = config.arenaAlloc();

            // We need to escape the string because the "raw" field
            // expects a Zig string.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try std.zig.stringEscape(
                std.mem.sliceTo(c_input, 0),
                &buf.writer,
            );

            config.input.list.clearRetainingCapacity();
            try config.input.list.append(
                alloc,
                .{ .raw = try buf.toOwnedSliceSentinel(0) },
            );
        }

        // Wait after command
        if (opts.wait_after_command) {
            config.@"wait-after-command" = true;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection => self.app.opts.supports_selection_clipboard,

            // No embedder can serve the primary selection: the embedding
            // API has no option to declare support for it, and macOS (the
            // only GUI embedder) has no primary selection. The selection
            // flag above covers a distinct custom pasteboard, not this.
            .primary => false,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        // Kitty clipboard writes carry their own contents and read
        // nothing from the clipboard, so they skip the read callback
        // entirely: the request is completed immediately, and a
        // completion that requires confirmation diverts into the
        // apprt confirmation flow just like a read.
        if (state == .kitty_write) {
            // A write to a location the embedder can't serve is
            // rejected before the transaction completes so the caller
            // answers ENOSYS without a permission prompt, matching
            // reads, where the embedder reports an unsupported
            // location from the read callback. The write callback only
            // fires after any prompt, so it is too late to reject.
            if (!self.supportsClipboard(clipboard_type)) return .unsupported;

            const alloc = self.app.core_app.alloc;
            const state_ptr = try alloc.create(apprt.ClipboardRequest);
            errdefer alloc.destroy(state_ptr);
            state_ptr.* = state;
            self.completeKittyClipboardWrite(state_ptr);
            return .started;
        }

        // The representations the read wants served. Text-only
        // requesters ask for the canonical text type; Kitty clipboard
        // reads ask for exactly what the program requested, with
        // text-like aliases normalized so the embedder never has to
        // know about them.
        var mimes_buf: [terminal.kitty.clipboard.max_read_mimes][*:0]const u8 = undefined;
        const mimes: []const [*:0]const u8 = switch (state) {
            .paste, .osc_52_read => &.{"text/plain"},

            // A mode 5522 paste event only lists types and must not read
            // any clipboard data.
            .list => &.{},

            .kitty_read => |kitty| mimes: {
                assert(kitty.mimes.len <= mimes_buf.len);
                for (kitty.mimes, mimes_buf[0..kitty.mimes.len]) |mime, *dst| {
                    dst.* = if (terminal.clipboard.isTextMime(mime))
                        "text/plain"
                    else
                        mime.ptr;
                }
                break :mimes mimes_buf[0..kitty.mimes.len];
            },

            // Handled above.
            .kitty_write => unreachable,

            // No clipboard write code paths travel through this function
            .osc_52_write => unreachable,
        };
        const list = switch (state) {
            // Paste events need the full MIME listing without reading any
            // representation. Kitty reads only ask for it when requested.
            .list => true,
            .kitty_read => |kitty| kitty.list,
            else => false,
        };

        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        const result = self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
            mimes.ptr,
            mimes.len,
            list,
        );

        // Only a started request completes later and keeps the state.
        if (result != .started) alloc.destroy(state_ptr);
        return result;
    }

    /// Complete a Kitty clipboard protocol write request. The apprt
    /// contributes nothing to the completion (the authoritative
    /// contents live in the request itself), but a completion that
    /// requires confirmation diverts into the confirm callback, which
    /// keeps the state alive for the asynchronous prompt.
    fn completeKittyClipboardWrite(
        self: *Surface,
        state: *apprt.ClipboardRequest,
    ) void {
        const alloc = self.app.core_app.alloc;
        const kitty = state.kitty_write;

        self.core_surface.completeClipboardRequest(
            state.*,
            .{},
        ) catch |err| switch (err) {
            error.UnauthorizedPaste => {
                // Convert the would-be contents so the permission
                // prompt can display exactly what would be written.
                var stack = std.heap.stackFallback(1024, alloc);
                const conv_alloc = stack.get();
                const contents = conv_alloc.alloc(
                    CAPI.ClipboardContent,
                    kitty.contents.len,
                ) catch |alloc_err| {
                    log.err("error confirming clipboard request err={}", .{alloc_err});
                    self.core_surface.denyClipboardRequest(state.*);
                    alloc.destroy(state);
                    return;
                };
                defer conv_alloc.free(contents);
                for (kitty.contents, contents) |src, *dst| dst.* = .{
                    .mime = src.mime,
                    .data = src.data.ptr,
                    .len = src.data.len,
                };

                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    &.{
                        .contents = contents.ptr,
                        .contents_len = contents.len,
                        .available = null,
                        .available_len = 0,
                        .name = if (kitty.name.len > 0) kitty.name.ptr else null,
                        .can_remember = kitty.pw.len > 0,
                    },
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    fn completeClipboardRequest(
        self: *Surface,
        complete: *const CAPI.ClipboardComplete,
        state: *apprt.ClipboardRequest,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Convert the C representations to the core types. Everything
        // remains borrowed from the caller for the duration of the call.
        var stack = std.heap.stackFallback(1024, alloc);
        const conv_alloc = stack.get();

        const raw_contents: []const CAPI.ClipboardContent =
            if (complete.contents) |v| v[0..complete.contents_len] else &.{};
        const contents = conv_alloc.alloc(
            terminal.clipboard.Content,
            raw_contents.len,
        ) catch |err| {
            log.err("error completing clipboard request err={}", .{err});
            alloc.destroy(state);
            return;
        };
        defer conv_alloc.free(contents);
        for (raw_contents, contents) |raw, *content| content.* = .{
            .mime = std.mem.sliceTo(raw.mime, 0),
            .data = raw.data[0..raw.len],
        };

        const raw_available: []const [*:0]const u8 =
            if (complete.available) |v| v[0..complete.available_len] else &.{};
        const available = conv_alloc.alloc(
            []const u8,
            raw_available.len,
        ) catch |err| {
            log.err("error completing clipboard request err={}", .{err});
            alloc.destroy(state);
            return;
        };
        defer conv_alloc.free(available);
        for (raw_available, available) |raw, *mime| {
            mime.* = std.mem.sliceTo(raw, 0);
        }

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(state.*, .{
            .contents = contents,
            .available = available,
            .confirmed = complete.confirmed,
            .remember = complete.remember,
        }) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                // Session grant information for the permission prompt,
                // carried only by Kitty clipboard protocol requests.
                const name: ?[*:0]const u8, const can_remember: bool = switch (state.*) {
                    inline .kitty_read, .kitty_write => |kitty| .{
                        if (kitty.name.len > 0) kitty.name.ptr else null,
                        kitty.pw.len > 0,
                    },
                    else => .{ null, false },
                };

                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    &.{
                        .contents = complete.contents,
                        .contents_len = complete.contents_len,
                        .available = complete.available,
                        .available_len = complete.available_len,
                        .name = name,
                        .can_remember = can_remember,
                    },
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    fn denyClipboardRequest(
        self: *Surface,
        state: *apprt.ClipboardRequest,
    ) void {
        self.core_surface.denyClipboardRequest(state.*);
        self.app.core_app.alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        const alloc = self.app.core_app.alloc;
        const array = try alloc.alloc(CAPI.ClipboardContent, contents.len);
        defer alloc.free(array);
        for (contents, 0..) |content, i| {
            array[i] = .{
                .mime = content.mime,
                .data = content.data.ptr,
                .len = content.data.len,
            };
        }

        self.app.opts.write_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            array.ptr,
            array.len,
            confirm,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        // There are cases where the platform reports a mouse motion event
        // without the cursor actually moving. For example, on macOS, updating
        // the window title can trigger a phantom mouse-move event at the same
        // coordinates. This can cause the mouse to incorrectly unhide when
        // mouse-hide-while-typing is enabled (commonly seen with TUI apps
        // like Zellij that frequently update the title). To prevent incorrect
        // behavior, we only continue with callback logic if the cursor has
        // actually moved.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1) return;

        self.cursor_pos = pos;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface, context: apprt.surface.NewSurfaceContext) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        const working_directory: ?[*:0]const u8 = wd: {
            if (!apprt.surface.shouldInheritWorkingDirectory(context, &self.app.config)) break :wd null;
            const cwd = self.core_surface.pwd(self.app.core_app.alloc) catch null orelse break :wd null;
            defer self.app.core_app.alloc.free(cwd);
            break :wd self.app.core_app.alloc.dupeZ(u8, cwd) catch null;
        };

        return .{
            .font_size = font_size,
            .working_directory = working_directory,
            .context = context,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        var env = try global.environMap();
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                _ = env.orderedRemove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                _ = env.orderedRemove("__XPC_DYLD_LIBRARY_PATH");
                _ = env.orderedRemove("DYLD_FRAMEWORK_PATH");
                _ = env.orderedRemove("DYLD_INSERT_LIBRARIES");
                _ = env.orderedRemove("DYLD_LIBRARY_PATH");
                _ = env.orderedRemove("LD_LIBRARY_PATH");
                _ = env.orderedRemove("SECURITYSESSIONID");
                _ = env.orderedRemove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            _ = env.orderedRemove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) _ = env.orderedRemove("LANGUAGE");
        }

        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.Io.Timestamp = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.ImGui_DestroyContext(ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render(surface);
            }

            // Render
            cimgui.c.ImGui_Render();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.ImGui_GetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatCast(x));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // For precision scrolling (trackpads), the values are in pixels which
        // scroll way too fast. Scale them down to approximate discrete wheel
        // notches. imgui expects 1.0 to scroll ~5 lines of text.
        const scale: f64 = if (mods.precision) 0.1 else 1.0;
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff * scale),
            @floatCast(yoff * scale),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(prev.durationTo(now).toNanoseconds());
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .consumed_mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.consumed_mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    // ghostty_clipboard_content_s
    //
    // One representation of clipboard contents. The data is binary-safe
    // and its length is explicit; it is not sentinel-terminated.
    const ClipboardContent = extern struct {
        mime: [*:0]const u8,
        data: [*]const u8,
        len: usize,
    };

    // ghostty_clipboard_complete_s
    //
    // The payload for completing a clipboard read request. See
    // Surface.CompleteClipboard for the field documentation.
    const ClipboardComplete = extern struct {
        contents: ?[*]const ClipboardContent,
        contents_len: usize,
        available: ?[*]const [*:0]const u8,
        available_len: usize,
        confirmed: bool,
        remember: bool,
    };

    // ghostty_clipboard_confirm_s
    //
    // The payload of a clipboard read confirmation request: the
    // would-be completion contents plus the information shown in the
    // permission prompt. All memory is borrowed for the duration of
    // the confirm_read_clipboard callback.
    const ClipboardConfirm = extern struct {
        contents: ?[*]const ClipboardContent,
        contents_len: usize,
        available: ?[*]const [*:0]const u8,
        available_len: usize,

        /// The human friendly name of the requesting program for the
        /// prompt, null when the protocol doesn't carry one.
        name: ?[*:0]const u8,

        /// True when the user's decision may be remembered as a
        /// session grant, reported back through the completion's
        /// remember field.
        can_remember: bool,
    };

    /// Create a new app.
    export fn velokit_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        const core_app = try CoreApp.create(global.alloc());
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc().create(App);
        errdefer global.alloc().destroy(app);
        try app.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn velokit_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn velokit_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn velokit_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc().destroy(v);
        core_app.destroy();
    }

    /// Apply configuration to the app and its existing surfaces.
    export fn velokit_app_update_config(v: *App, config: *const Config) bool {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return false;
        };
        return true;
    }

    /// Update the focused state of the app.
    export fn velokit_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Returns initial surface options.
    export fn velokit_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn velokit_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*);
    }

    export fn velokit_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn velokit_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn velokit_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn velokit_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Update the content scale of the surface.
    export fn velokit_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn velokit_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn velokit_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Set the preedit text for the surface. This is used for IME
    /// composition. If the length is 0, then the preedit text is cleared.
    export fn velokit_surface_preedit(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.preeditCallback(if (len == 0) null else ptr[0..len]);
    }

    /// Invoke an action on the surface.
    export fn velokit_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        return ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={f} err={}", .{ action, err });
            return false;
        };
    }

    /// Complete a clipboard read request started via the read callback
    /// with the representations that could be served and, if requested,
    /// the listing of available MIME types. All memory is borrowed for
    /// the duration of the call. This can only be called once for a given
    /// request. Once it is called with a request the request pointer will
    /// be invalidated.
    ///
    /// To deny a request use velokit_surface_deny_clipboard_request
    /// instead.
    export fn velokit_surface_complete_clipboard_request(
        ptr: *Surface,
        complete: *const ClipboardComplete,
        state: *apprt.ClipboardRequest,
    ) void {
        ptr.completeClipboardRequest(complete, state);
    }

    /// Deny a clipboard read request started via the read callback,
    /// e.g. because the user rejected a confirmation prompt. Request
    /// types whose protocol expects an answer have their denial reply
    /// written to the pty. The request pointer is invalidated.
    export fn velokit_surface_deny_clipboard_request(
        ptr: *Surface,
        state: *apprt.ClipboardRequest,
    ) void {
        ptr.denyClipboardRequest(state);
    }
};
