const VeloKitXCFramework = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
const VeloKitLib = @import("VeloKitLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");

xcframework: *XCFrameworkStep,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !VeloKitXCFramework {
    const library = try VeloKitLib.initStatic(b, deps);

    // Generate a headers directory with only velokit.h and the module
    // map. We can't use include/ directly because it also contains the
    // public VT headers, which would trigger
    // "umbrella header does not include header" warnings from Clang's
    // module system.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("include/velokit.h"), "velokit.h");
    _ = wf.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
    const headers = wf.getDirectory();

    // The XCFramework wraps the library so the Swift app can link it.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "VeloKit",
        .out_path = "build/VeloKit.xcframework",
        .libraries = &.{.{
            .library = library.output,
            .headers = headers,
            .dsym = library.dsym,
        }},
    });

    return .{
        .xcframework = xcframework,
    };
}

pub fn install(self: *const VeloKitXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const VeloKitXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
