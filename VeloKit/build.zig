const std = @import("std");
const buildpkg = @import("src/build/main.zig");

const app_version = @import("build.zig.zon").version;
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    const config = try buildpkg.Config.init(b, app_version);
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const xcframework = try buildpkg.VeloKitXCFramework.init(
        b,
        &deps,
    );
    xcframework.install();
}
