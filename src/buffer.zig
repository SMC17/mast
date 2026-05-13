// buffer.zig — buffer-as-protocol v0.1 implementation.
//
// Every observable object in the editor is a Buffer. v0.1 ships four kinds:
//   .file      — backed by a path on disk
//   .agent     — output stream from a CLI invocation
//   .manifest  — tail of an append-only event log
//   .search    — result list from a query
//
// The protocol surface (read, write, mark, properties) is intentionally
// minimal in v0.1. The contract is in docs/buffer-protocol.md.

const std = @import("std");

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
});

pub const Kind = enum {
    file,
    agent,
    manifest,
    search,
};

pub const Buffer = struct {
    kind: Kind,
    name: []const u8, // human-readable label (filename, agent id, etc.)
    contents: []u8, // owned bytes
    mark: usize = 0, // current cursor / read position
    dirty: bool = false,
    allocator: std.mem.Allocator,

    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);
        const c_ptr: [*c]const u8 = @ptrCast(c_path.ptr);
        const fd = libc.open(c_ptr, libc.O_RDONLY);
        if (fd < 0) return error.OpenFailed;
        defer _ = libc.close(fd);

        var st: libc.struct_stat = undefined;
        if (libc.fstat(fd, &st) != 0) return error.StatFailed;
        const size: usize = @intCast(st.st_size);

        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        var read_total: usize = 0;
        while (read_total < size) {
            const rc = libc.read(fd, buf.ptr + read_total, size - read_total);
            if (rc <= 0) break;
            read_total += @intCast(rc);
        }
        return Buffer{
            .kind = .file,
            .name = try allocator.dupe(u8, path),
            .contents = buf,
            .allocator = allocator,
        };
    }

    pub fn fromBytes(allocator: std.mem.Allocator, kind: Kind, name: []const u8, bytes: []const u8) !Buffer {
        return Buffer{
            .kind = kind,
            .name = try allocator.dupe(u8, name),
            .contents = try allocator.dupe(u8, bytes),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.name);
        self.allocator.free(self.contents);
    }

    pub fn lineCount(self: *const Buffer) usize {
        var n: usize = 0;
        for (self.contents) |c| {
            if (c == '\n') n += 1;
        }
        if (self.contents.len > 0 and self.contents[self.contents.len - 1] != '\n') n += 1;
        return n;
    }

    /// Render the first `max_lines` lines to `writer`, prefixed by a
    /// status header. Returns the number of bytes written.
    pub fn render(self: *const Buffer, writer: anytype, max_lines: usize) !usize {
        const kind_label = switch (self.kind) {
            .file => "file",
            .agent => "agent",
            .manifest => "manifest",
            .search => "search",
        };
        var byte_count: usize = 0;
        byte_count += try writer.print(
            "── [:{s}] {s} — {d} lines, {d} bytes ──\n",
            .{ kind_label, self.name, self.lineCount(), self.contents.len },
        );
        var line_no: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < self.contents.len and line_no < max_lines) : (i += 1) {
            if (self.contents[i] == '\n') {
                line_no += 1;
                byte_count += try writer.print(
                    "{d:>4}  {s}\n",
                    .{ line_no, self.contents[line_start..i] },
                );
                line_start = i + 1;
            }
        }
        // Trailing partial line
        if (line_no < max_lines and line_start < self.contents.len) {
            line_no += 1;
            byte_count += try writer.print(
                "{d:>4}  {s}\n",
                .{ line_no, self.contents[line_start..] },
            );
        }
        if (line_no < self.lineCount()) {
            byte_count += try writer.print(
                "... ({d} more lines)\n",
                .{self.lineCount() - line_no},
            );
        }
        return byte_count;
    }
};

test "buffer.fromBytes round-trips" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "test", "hello\nworld\n");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 2), b.lineCount());
    try std.testing.expectEqualStrings("test", b.name);
}
