const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Janet — compile the amalgamated source directly into the binary.
    // The vendored janet.c is ~3.3 MB; janet.h is 96 KB. No system Janet
    // needed.
    exe_mod.addCSourceFile(.{
        .file = b.path("vendored/janet/janet.c"),
        .flags = &.{
            "-std=c99",
            "-fno-strict-aliasing",
            "-Wno-unused-parameter",
            // Janet builds with -O2 by default; the Zig optimize mode controls
            // the rest. ReleaseSmall produces ~1MB binaries.
        },
    });
    exe_mod.addIncludePath(b.path("vendored/janet"));

    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("m", .{});

    // Platform-aware linking. On Darwin, pthread/dl are built into libc
    // (and -lrt doesn't exist). On Linux, all three are separate libs.
    const t = target.result;
    if (t.os.tag == .linux) {
        exe_mod.linkSystemLibrary("pthread", .{});
        exe_mod.linkSystemLibrary("dl", .{});
        exe_mod.linkSystemLibrary("rt", .{});
    }

    const exe = b.addExecutable(.{
        .name = "mast",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run mast");
    run_step.dependOn(&run_cmd.step);

    // `zig build smoke` — non-interactive smoke test using a heredoc-piped script
    const smoke_step = b.step("smoke", "Run a non-interactive smoke test");
    smoke_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests for the buffer protocol.
    // Tests need libc for the open/read/write/rename/unlink syscalls used by
    // Buffer.save/saveAs, so the test module mirrors the main exe's link
    // config.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;
    test_mod.linkSystemLibrary("m", .{});
    if (t.os.tag == .linux) {
        test_mod.linkSystemLibrary("pthread", .{});
        test_mod.linkSystemLibrary("dl", .{});
        test_mod.linkSystemLibrary("rt", .{});
    }

    const buffer_tests = b.addTest(.{ .root_module = test_mod });
    const run_buffer_tests = b.addRunArtifact(buffer_tests);
    const test_step = b.step("test", "Run unit tests (buffer protocol)");
    test_step.dependOn(&run_buffer_tests.step);
}
