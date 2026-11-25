// SPDX-License-Identifier: GPL-3.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "Terminal engine optimization (default: fast)") orelse .fast;
    const Configuration = enum { Debug, Release };
    const configuration = @tagName(b.option(Configuration, "configuration", "Xcode app configuration") orelse .Debug);
    const products = "macos/build/Build/Products";
    const engine_prefix = b.option([]const u8, "engine-prefix", "VeloKit output directory for direct Xcode builds");

    const engine = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("-Doptimize={s}", .{@tagName(optimize)}), "--prefix" });
    if (engine_prefix) |prefix| engine.addArg(prefix) else engine.addDirectoryArg(b.path(b.fmt("{s}/VeloKit/{s}", .{ products, configuration })));
    engine.setCwd(b.path("VeloKit"));
    engine.has_side_effects = true;
    b.step("engine", "Build the private terminal engine").dependOn(&engine.step);

    const app = xcode(b, configuration, "build");
    app.step.dependOn(&engine.step);
    const app_path = b.path(b.fmt("{s}/{s}/Velocitty.app", .{ products, configuration }));
    const installed_app = b.graph.path(.install_prefix, "Velocitty.app");
    const mkdir = b.addSystemCommand(&.{ "/bin/mkdir", "-p" });
    mkdir.addDirectoryArg(installed_app);
    mkdir.step.dependOn(&app.step);
    const install = b.addSystemCommand(&.{ "/usr/bin/rsync", "-a", "--delete" });
    install.addDirectoryArg2(app_path, .{ .suffix = "/" });
    install.addDirectoryArg(installed_app);
    install.has_side_effects = true;
    install.step.dependOn(&mkdir.step);
    b.getInstallStep().dependOn(&install.step);

    const run = std.Build.Step.Run.create(b, "run Velocitty");
    run.addFileArg(b.graph.path(.install_prefix, "Velocitty.app/Contents/MacOS/Velocitty"));
    run.environ_map = appleEnvironment(b);
    run.addPassthruArgs();
    run.has_side_effects = true;
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Build and launch Velocitty").dependOn(&run.step);

    const config_tests = b.addSystemCommand(&.{ "/usr/bin/swift", "test", "--package-path", "macos" });
    config_tests.environ_map = appleEnvironment(b);
    config_tests.setCwd(b.path(""));
    config_tests.has_side_effects = true;
    const core_tests = xcode(b, configuration, "test");
    core_tests.addArgs(&.{ "-testPlan", "Core" });
    core_tests.step.dependOn(&engine.step);
    core_tests.step.dependOn(&config_tests.step);
    b.step("test", "Run configuration and Core tests").dependOn(&core_tests.step);
    const gui_tests = xcode(b, configuration, "test");
    gui_tests.addArgs(&.{ "-testPlan", "GUI" });
    gui_tests.step.dependOn(&engine.step);
    gui_tests.step.dependOn(&core_tests.step);
    b.step("test-gui", "Run all tests, including desktop and herdr integration checks").dependOn(&gui_tests.step);
}

fn xcode(b: *std.Build, configuration: []const u8, action: []const u8) *std.Build.Step.Run {
    const step = b.addSystemCommand(&.{
        "/usr/bin/xcodebuild",  "-quiet",                    "-project",         "macos/Velocitty.xcodeproj",
        "-scheme",              "Velocitty",                 "-configuration",   configuration,
        "-destination",         "platform=macOS,arch=arm64", "-derivedDataPath", "macos/build",
        "VELOKIT_PREBUILT=YES", action,
    });
    step.environ_map = appleEnvironment(b);
    step.setCwd(b.path(""));
    step.has_side_effects = true;
    return step;
}

fn appleEnvironment(b: *std.Build) *std.process.Environ.Map {
    const env = b.allocator.create(std.process.Environ.Map) catch @panic("out of memory");
    env.* = .init(b.allocator);
    for ([_][]const u8{ "PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SSH_AUTH_SOCK" }) |key| {
        if (b.graph.environ_map.get(key)) |value| env.put(key, value) catch @panic("out of memory");
    }
    return env;
}
