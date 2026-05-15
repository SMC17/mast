//! Buffer protocol throughput benchmark.
//!
//! Measures the load-bearing buffer ops: fromBytes (constructor),
//! append (line-by-line growth), setContents (atomic replacement),
//! and save (atomic write-to-disk). Output is parseable
//! `bench=NAME ... ns_per_op=N ops_per_sec=N` lines compatible with
//! the rest of the stax repo bench-collector toolchain.
//!
//! Run with `zig build bench-buffer -Doptimize=ReleaseFast`.

const std = @import("std");
const buffer = @import("buffer");

const libc = @cImport({
    @cInclude("unistd.h");
});

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const a = std.heap.smp_allocator;

    std.debug.print("# mast bench: buffer protocol (ReleaseFast, MONOTONIC ns)\n", .{});

    // --- bench: fromBytes at various sizes ---
    const sizes = [_]usize{ 16, 256, 4096, 65536 };
    for (sizes) |size| {
        const data = try a.alloc(u8, size);
        defer a.free(data);
        @memset(data, 'X');
        const iters: usize = if (size <= 256) 200_000 else if (size <= 4096) 50_000 else 5_000;

        // Warmup
        var w: usize = 0;
        while (w < 100) : (w += 1) {
            var b = try buffer.Buffer.fromBytes(a, .agent, "warm", data);
            b.deinit();
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var b = try buffer.Buffer.fromBytes(a, .agent, "p", data);
            b.deinit();
        }
        const elapsed = nanos() - t0;
        std.debug.print(
            "bench=fromBytes size={d} iters={d} total_ns={d} ns_per_op={d} ops_per_sec={d}\n",
            .{ size, iters, elapsed, elapsed / iters, (iters * std.time.ns_per_s) / elapsed },
        );
    }

    // --- bench: append N chunks ---
    const chunk_counts = [_]usize{ 10, 100, 1000 };
    for (chunk_counts) |n_chunks| {
        const chunk = "Hello, world! This is a line.\n";
        const iters: usize = if (n_chunks <= 100) 5_000 else 500;

        const t0 = nanos();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var b = try buffer.Buffer.fromBytes(a, .agent, "p", "");
            defer b.deinit();
            var k: usize = 0;
            while (k < n_chunks) : (k += 1) {
                try b.append(chunk);
            }
        }
        const elapsed = nanos() - t0;
        const total_appends = iters * n_chunks;
        std.debug.print(
            "bench=append chunks_per_buf={d} iters={d} total_appends={d} total_ns={d} ns_per_append={d} appends_per_sec={d}\n",
            .{ n_chunks, iters, total_appends, elapsed, elapsed / total_appends, (total_appends * std.time.ns_per_s) / elapsed },
        );
    }

    // --- bench: setContents replacement ---
    for (sizes) |size| {
        const data = try a.alloc(u8, size);
        defer a.free(data);
        @memset(data, 'Y');
        const iters: usize = if (size <= 256) 200_000 else if (size <= 4096) 50_000 else 5_000;

        var b = try buffer.Buffer.fromBytes(a, .agent, "p", "");
        defer b.deinit();

        const t0 = nanos();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            try b.setContents(data);
        }
        const elapsed = nanos() - t0;
        std.debug.print(
            "bench=setContents size={d} iters={d} total_ns={d} ns_per_op={d} ops_per_sec={d}\n",
            .{ size, iters, elapsed, elapsed / iters, (iters * std.time.ns_per_s) / elapsed },
        );
    }

    // --- bench: save (touches disk) ---
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/mast-bench-save-{d}.bin", .{libc.getpid()});

    for (sizes) |size| {
        const data = try a.alloc(u8, size);
        defer a.free(data);
        @memset(data, 'Z');
        const iters: usize = if (size <= 256) 5_000 else if (size <= 4096) 2_000 else 500;

        var b = try buffer.Buffer.fromBytes(a, .file, path, data);
        defer b.deinit();

        const t0 = nanos();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            b.dirty = true;
            _ = try b.save();
        }
        const elapsed = nanos() - t0;
        std.debug.print(
            "bench=save size={d} iters={d} total_ns={d} ns_per_op={d} ops_per_sec={d}\n",
            .{ size, iters, elapsed, elapsed / iters, (iters * std.time.ns_per_s) / elapsed },
        );
    }

    // Cleanup
    const c_path = try a.dupeZ(u8, path);
    defer a.free(c_path);
    _ = libc.unlink(@ptrCast(c_path.ptr));
}
