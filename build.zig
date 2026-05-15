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
    const test_step = b.step("test", "Run unit tests (buffer protocol + sandbox)");
    test_step.dependOn(&run_buffer_tests.step);

    // Sandbox tests — need the full Janet runtime linked in so the
    // gated wrappers can actually stand up a VM.
    const sandbox_test_mod = b.createModule(.{
        .root_source_file = b.path("src/sandbox.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandbox_test_mod.addCSourceFile(.{
        .file = b.path("vendored/janet/janet.c"),
        .flags = &.{
            "-std=c99",
            "-fno-strict-aliasing",
            "-Wno-unused-parameter",
        },
    });
    sandbox_test_mod.addIncludePath(b.path("vendored/janet"));
    sandbox_test_mod.link_libc = true;
    sandbox_test_mod.linkSystemLibrary("m", .{});
    if (t.os.tag == .linux) {
        sandbox_test_mod.linkSystemLibrary("pthread", .{});
        sandbox_test_mod.linkSystemLibrary("dl", .{});
        sandbox_test_mod.linkSystemLibrary("rt", .{});
    }
    const sandbox_tests = b.addTest(.{ .root_module = sandbox_test_mod });
    const run_sandbox_tests = b.addRunArtifact(sandbox_tests);
    test_step.dependOn(&run_sandbox_tests.step);

    // Integration test: spawns the actual installed `mast` binary with
    // MAST_SANDBOX_STRICT=1 and asserts the deny path is observable on
    // stderr. Implemented as a bash script (tests/strict_mode_integration.sh)
    // to insulate the test from Zig 0.16's std.process / std.Io churn —
    // the contract being tested is "the binary, when run with an env var,
    // emits a specific diagnostic to stderr", which is exactly what shell
    // pipelines + grep are good at. The script is invoked through
    // b.addSystemCommand and gated on the install step so the binary
    // exists before the test runs.
    const integration_smoke = b.addSystemCommand(&.{
        "bash",
        "tests/strict_mode_integration.sh",
    });
    integration_smoke.setEnvironmentVariable("MAST_BIN", b.getInstallPath(.bin, "mast"));
    integration_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&integration_smoke.step);

    // `zig build doctest` — README claim verification.
    //
    // Same discipline as zig-cobs / zig-frame-protocol / zig-graph /
    // zig-h3: every executable claim in README.md (build steps,
    // documented CLI flags, M-x verbs, the Janet quickstart
    // `(+ 1 2)` → 3, the MAST_SANDBOX_STRICT env-var posture,
    // examples/init.janet) is exercised against the shipped binary.
    //
    // The script is bash so it stays insulated from Zig 0.16 std.process
    // churn — same rationale as strict_mode_integration.sh. The doctest
    // step depends on the install step so $MAST_BIN exists before checks
    // run, and reuses strict_mode_integration.sh wholesale for the
    // strict-mode cases (one canonical script, two callers).
    const doctest = b.addSystemCommand(&.{
        "bash",
        "tools/doctest.sh",
    });
    doctest.setEnvironmentVariable("MAST_BIN", b.getInstallPath(.bin, "mast"));
    doctest.step.dependOn(b.getInstallStep());
    const doctest_step = b.step("doctest", "Verify README executable claims against the shipped binary");
    doctest_step.dependOn(&doctest.step);

    // `zig build bench-buffer` — buffer-protocol throughput benchmark.
    // Reports parseable bench=NAME ... ns_per_op=N lines to stderr.
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const buffer_module = b.createModule(.{
        .root_source_file = b.path("src/buffer.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    buffer_module.link_libc = true;
    buffer_module.linkSystemLibrary("m", .{});
    if (t.os.tag == .linux) {
        buffer_module.linkSystemLibrary("pthread", .{});
        buffer_module.linkSystemLibrary("dl", .{});
        buffer_module.linkSystemLibrary("rt", .{});
    }
    const bench_buffer_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench_buffer.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_buffer_mod.addImport("buffer", buffer_module);
    bench_buffer_mod.link_libc = true;
    bench_buffer_mod.linkSystemLibrary("m", .{});
    if (t.os.tag == .linux) {
        bench_buffer_mod.linkSystemLibrary("pthread", .{});
        bench_buffer_mod.linkSystemLibrary("dl", .{});
        bench_buffer_mod.linkSystemLibrary("rt", .{});
    }
    const bench_buffer_exe = b.addExecutable(.{
        .name = "bench-buffer",
        .root_module = bench_buffer_mod,
    });
    const run_bench_buffer = b.addRunArtifact(bench_buffer_exe);
    run_bench_buffer.has_side_effects = true;
    const bench_step = b.step("bench-buffer", "Run buffer-protocol throughput benchmark");
    bench_step.dependOn(&run_bench_buffer.step);
}
