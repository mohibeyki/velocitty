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
    const library = try buildpkg.VeloKitLib.initStatic(b, &deps);
    b.getInstallStep().dependOn(&b.addInstallFile(library.output, "lib/libvelokit.a").step);
    b.installFile("include/velokit.h", "include/velokit.h");
    b.installFile("include/module.modulemap", "include/module.modulemap");

    const terminfo = comptime blk: {
        @setEvalBranchQuota(100_000);
        var buffer: [16384]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        @import("src/terminfo/main.zig").ghostty.encode(&writer) catch unreachable;
        break :blk buffer[0..writer.end].*;
    };
    const files = b.addWriteFiles();
    const source = files.add("ghostty.terminfo", &terminfo);
    const tic = b.addSystemCommand(&.{ "/usr/bin/tic", "-x", "-o" });
    const database = tic.addOutputDirectoryArg("terminfo");
    tic.addFileArg(source);
    // Keep the installed tree exact when generated entries are renamed or removed.
    const destination = b.getInstallPath(.prefix, "share/terminfo");
    const mkdir = b.addSystemCommand(&.{ "/bin/mkdir", "-p", destination });
    const install = b.addSystemCommand(&.{ "/usr/bin/rsync", "-a", "--delete" });
    install.addDecoratedDirectoryArg("", database, "/");
    install.addArg(destination);
    install.step.dependOn(&mkdir.step);
    b.getInstallStep().dependOn(&install.step);
}
