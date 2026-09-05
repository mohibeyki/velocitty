/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");

const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Standard build configuration options.
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
wasm_target: WasmTarget,

/// Comptime interfaces
app_runtime: ApprtRuntime = .none,
renderer: RendererBackend = .metal,
font_backend: FontBackend = .coretext,

/// Feature flags
x11: bool = false,
wayland: bool = false,
sentry: bool = false,
simd: bool = true,
i18n: bool = false,
wasm_shared: bool = true,

/// Internal entry point and application version
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// Binary properties
strip: bool = false,

// Internal engine switches retained for shared code.
flatpak: bool = false,
snap: bool = false,

/// Environmental properties
env: *const std.process.Environ.Map,

/// The engine is a private arm64 macOS build, not a configurable SDK.
pub fn init(b: *std.Build, appVersion: []const u8) !Config {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .macos or target.result.cpu.arch != .aarch64)
        return error.UnsupportedTarget;

    // Use bundled dependencies for the static Xcode artifact.
    for ([_][]const u8{
        "freetype",  "harfbuzz", "fontconfig",  "libpng",  "zlib",
        "oniguruma", "glslang",  "spirv-cross", "simdutf",
    }) |dep| {
        _ = b.systemIntegrationOption(dep, .{ .default = false });
    }

    return .{
        .optimize = optimize,
        .target = genericMacOSTarget(b, .aarch64),
        .env = &b.graph.environ_map,
        .wasm_target = .browser,
        .app_runtime = .none,
        .font_backend = .coretext,
        .renderer = .metal,
        .version = try std.SemanticVersion.parse(appVersion),
        .strip = b.option(bool, "strip", "Strip engine debug symbols") orelse switch (optimize) {
            .Debug, .ReleaseSafe => false,
            .ReleaseFast, .ReleaseSmall => true,
        },
    };
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "flatpak", self.flatpak);
    step.addOption(bool, "snap", self.snap);
    step.addOption(bool, "x11", self.x11);
    step.addOption(bool, "wayland", self.wayland);
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(WasmTarget, "wasm_target", self.wasm_target);
    step.addOption(bool, "wasm_shared", self.wasm_shared);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var app_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
        &app_version_buf,
        "{f}",
        .{self.version},
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// Returns the build options for the terminal module. This assumes a
/// Ghostty executable being built. Callers should modify this as needed.
pub fn terminalOptions(
    self: *const Config,
    artifact: TerminalBuildOptions.Artifact,
    optimize: std.builtin.OptimizeMode,
) TerminalBuildOptions {
    return .{
        .artifact = artifact,
        .simd = self.simd,
        .oniguruma = true,
        .c_abi = false,
        .features = .{},
        .version = self.version,
        .slow_runtime_safety = switch (optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config, io: std.Io) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(io, q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .flatpak = options.flatpak,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .snap = options.snap,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
        .i18n = options.i18n,
    };
}

/// Whether release artifacts should omit frame pointers.
///
/// Stripped release builds omit them in general, but we always keep frame
/// pointers on Apple platforms: the Apple arm64 ABI expects x29 to
/// be a valid frame pointer and Apple's profiling and crash reporting
/// tools rely on it for backtraces.
pub fn omitFramePointer(self: *const Config) bool {
    if (self.target.result.os.tag.isDarwin()) return false;
    return self.strip;
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // We support back to the earliest officially supported version
        // of macOS by Apple. EOL versions are not supported.
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}

/// Returns the minimum OS version for lib-vt build.
///
/// This should only be used for Darwin targets.
pub fn osVersionMinLibVt(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    // lib-vt is the only thing we still build for iOS, so its deployment
    // target lives here rather than in osVersionMin.
    if (tag == .ios) return .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
    return osVersionMin(tag);
}

// Returns a ResolvedTarget for a mac with a `target.result.cpu.model.name` of `generic`.
// `b.standardTargetOptions()` returns a more specific cpu like `apple_a15`.
//
// This is used to workaround compilation issues on macOS.
// (see for example https://github.com/mitchellh/ghostty/issues/1640).
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
}

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};
