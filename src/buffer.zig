// buffer.zig — buffer-as-protocol implementation.
//
// Every observable object in the editor is a Buffer. The first-class kinds
// shipped today are:
//   .file      — backed by a path on disk (read and write)
//   .agent     — output stream from a CLI invocation
//   .manifest  — tail of an append-only event log
//   .search    — result list from a query
//
// The protocol surface (read, write, mark, properties) is intentionally
// minimal. The contract is in docs/buffer-protocol.md.

const std = @import("std");

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("stdio.h"); // rename(2)
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
        var reader = LibcFdReader{ .fd = fd };
        _ = readToBuffer(reader.readerFn(), &reader, buf);
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

    /// Replace the buffer's contents in-place. Marks the buffer dirty so
    /// `save` knows there are unwritten changes. Frees the previous bytes.
    pub fn setContents(self: *Buffer, new_bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, new_bytes);
        self.allocator.free(self.contents);
        self.contents = copy;
        self.dirty = true;
        if (self.mark > copy.len) self.mark = copy.len;
    }

    /// Append bytes to the buffer (the common "type at end" operation).
    pub fn append(self: *Buffer, bytes: []const u8) !void {
        const new_len = self.contents.len + bytes.len;
        const copy = try self.allocator.alloc(u8, new_len);
        @memcpy(copy[0..self.contents.len], self.contents);
        @memcpy(copy[self.contents.len..], bytes);
        self.allocator.free(self.contents);
        self.contents = copy;
        self.dirty = true;
    }

    /// Write the buffer to disk. For `:file` kind, writes to its `name`
    /// path. For other kinds, the caller MUST supply a path via `saveAs`.
    /// Returns the number of bytes written.
    ///
    /// Write is atomic: writes go to `<path>.tmp.<pid>`, then rename — so
    /// a crash mid-write can't truncate the original file.
    pub fn save(self: *Buffer) !usize {
        if (self.kind != .file) return error.NotAFileBuffer;
        const n = try writeAtomically(self.allocator, self.name, self.contents);
        self.dirty = false;
        return n;
    }

    /// Write the buffer to a new path, switching the buffer's identity to
    /// the new path (kind becomes `:file`). Used for save-as and for
    /// converting a non-file buffer (`:agent`, `:search`) to a file.
    pub fn saveAs(self: *Buffer, path: []const u8) !usize {
        const n = try writeAtomically(self.allocator, path, self.contents);
        const new_name = try self.allocator.dupe(u8, path);
        self.allocator.free(self.name);
        self.name = new_name;
        self.kind = .file;
        self.dirty = false;
        return n;
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

/// Function-pointer signature for a "read N bytes into ptr, return isize"
/// callable. Matches libc.read's shape. Returning <= 0 (EOF or error)
/// terminates `readToBuffer`. This indirection exists so the read loop in
/// `Buffer.fromFile` can be unit-tested deterministically against partial-
/// EOF (read returns 0 before the requested size is filled) without needing
/// a real pipe/socket fixture.
pub const ReadFn = *const fn (ctx: *anyopaque, ptr: [*]u8, len: usize) isize;

/// Drain a reader into `buf` until either `buf.len` bytes have been read
/// or the reader returns <= 0 (EOF or error). Returns the number of bytes
/// actually written into `buf`.
///
/// The boundary that mutation operator M09 targets is the `rc <= 0 break`
/// guard: on a partial EOF (read returns 0 before buf is filled), the
/// loop MUST break or it spins forever calling read(). The accompanying
/// test `readToBuffer: terminates on partial-EOF` pins this.
pub fn readToBuffer(read_fn: ReadFn, ctx: *anyopaque, buf: []u8) usize {
    var read_total: usize = 0;
    while (read_total < buf.len) {
        const rc = read_fn(ctx, buf.ptr + read_total, buf.len - read_total);
        if (rc <= 0) break;
        read_total += @intCast(rc);
    }
    return read_total;
}

/// Thin libc-backed reader that adapts `libc.read(fd, ...)` to the
/// `ReadFn` shape. The fd is borrowed; the caller owns lifetime.
const LibcFdReader = struct {
    fd: c_int,

    fn read(ctx: *anyopaque, ptr: [*]u8, len: usize) isize {
        const self: *LibcFdReader = @ptrCast(@alignCast(ctx));
        return libc.read(self.fd, ptr, len);
    }

    fn readerFn(_: *LibcFdReader) ReadFn {
        return &LibcFdReader.read;
    }
};

fn writeAtomically(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !usize {
    // Compose a temp path next to the target so rename(2) is atomic on the
    // same filesystem. PID disambiguates concurrent writers in the same dir.
    var tmp_path_buf: [1024]u8 = undefined;
    const pid: i32 = @intCast(libc.getpid());
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}\x00", .{ path, pid });

    const c_tmp: [*c]const u8 = @ptrCast(tmp_path.ptr);
    const flags = libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC;
    const fd = libc.open(c_tmp, flags, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = libc.close(fd);

    var written: usize = 0;
    while (written < contents.len) {
        const rc = libc.write(fd, contents.ptr + written, contents.len - written);
        if (rc < 0) {
            _ = libc.unlink(c_tmp);
            return error.WriteFailed;
        }
        written += @intCast(rc);
    }

    // Sync the tmp file before rename so the rename's atomicity guarantee
    // actually means "post-rename content is durable on disk."
    if (libc.fsync(fd) != 0) {
        // Some filesystems don't support fsync (eg /tmp on tmpfs); not fatal.
        std.debug.print("(save: fsync failed; rename is atomic but not crash-durable on this fs)\n", .{});
    }

    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);
    if (libc.rename(c_tmp, @ptrCast(c_path.ptr)) != 0) {
        _ = libc.unlink(c_tmp);
        return error.RenameFailed;
    }
    return written;
}

/// Test-only reader: returns `first_chunk` bytes once, then 0 (EOF)
/// forever — modeling a pipe/socket that closed mid-stream after writing
/// fewer bytes than the caller expected. The `safety_cap` exists so that
/// if `readToBuffer`'s EOF-break is removed (mutation operator M09:
/// `rc <= 0` → `rc < 0`), the test terminates rather than hanging the
/// whole test binary — we then prove the mutant ran past the expected
/// call count via `call_count`.
const PartialEofReader = struct {
    first_chunk: usize,
    chunk_byte: u8 = 'A',
    call_count: usize = 0,
    safety_cap: usize = 1024,

    fn read(ctx: *anyopaque, ptr: [*]u8, len: usize) isize {
        const self: *PartialEofReader = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        if (self.call_count > self.safety_cap) return -1; // escape hatch
        if (self.call_count == 1) {
            const n = @min(self.first_chunk, len);
            var i: usize = 0;
            while (i < n) : (i += 1) ptr[i] = self.chunk_byte;
            return @intCast(n);
        }
        return 0; // EOF on every subsequent call
    }

    fn readerFn() ReadFn {
        return &PartialEofReader.read;
    }
};

test "readToBuffer: terminates on partial-EOF (pins M09 boundary)" {
    // size=10, reader delivers 5 bytes then EOF. The original loop must
    // break after the second call (rc==0). A mutant `rc < 0 break` would
    // spin forever calling read(); the reader's safety_cap converts that
    // hang into a finite-but-large call_count we can assert against.
    var reader = PartialEofReader{ .first_chunk = 5, .chunk_byte = 'X' };
    var buf: [10]u8 = undefined;
    @memset(&buf, 0);
    const n = readToBuffer(PartialEofReader.readerFn(), &reader, &buf);

    // Under the live (un-mutated) implementation:
    //   - 5 bytes delivered, then EOF break
    //   - exactly 2 read() calls
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(usize, 2), reader.call_count);
    try std.testing.expectEqual(@as(u8, 'X'), buf[0]);
    try std.testing.expectEqual(@as(u8, 'X'), buf[4]);
    try std.testing.expectEqual(@as(u8, 0), buf[5]); // untouched
}

test "readToBuffer: fills buffer when reader delivers exactly size bytes" {
    // Sanity case: reader returns full requested size in one call, loop
    // exits via the `read_total < buf.len` guard, no EOF break needed.
    const FullReader = struct {
        called: bool = false,
        fn read(ctx: *anyopaque, ptr: [*]u8, len: usize) isize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.called) return 0;
            self.called = true;
            var i: usize = 0;
            while (i < len) : (i += 1) ptr[i] = 'Q';
            return @intCast(len);
        }
    };
    var r = FullReader{};
    var buf: [8]u8 = undefined;
    const n = readToBuffer(&FullReader.read, &r, &buf);
    try std.testing.expectEqual(@as(usize, 8), n);
    for (buf) |c| try std.testing.expectEqual(@as(u8, 'Q'), c);
}

test "buffer.fromBytes round-trips" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "test", "hello\nworld\n");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 2), b.lineCount());
    try std.testing.expectEqualStrings("test", b.name);
}

test "buffer.append marks dirty + grows contents" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "test", "hello");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 5), b.contents.len);
    try std.testing.expect(!b.dirty);
    try b.append(", world\n");
    try std.testing.expectEqual(@as(usize, 13), b.contents.len);
    try std.testing.expect(b.dirty);
    try std.testing.expectEqualStrings("hello, world\n", b.contents);
}

test "buffer.save round-trips a :file buffer atomically" {
    const a = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/mast-buftest-{d}.txt", .{libc.getpid()});

    var b = try Buffer.fromBytes(a, .file, tmp_path, "");
    defer b.deinit();
    try b.append("alpha\nbeta\ngamma\n");
    try std.testing.expect(b.dirty);
    const n = try b.save();
    try std.testing.expectEqual(@as(usize, 17), n);
    try std.testing.expect(!b.dirty);

    // Read it back and compare
    var b2 = try Buffer.fromFile(a, tmp_path);
    defer b2.deinit();
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", b2.contents);

    // Cleanup
    const c_path = try a.dupeZ(u8, tmp_path);
    defer a.free(c_path);
    _ = libc.unlink(@ptrCast(c_path.ptr));
}

test "buffer.saveAs converts an :agent buffer into a :file buffer" {
    const a = std.testing.allocator;
    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/mast-saveas-{d}.txt", .{libc.getpid()});

    var b = try Buffer.fromBytes(a, .agent, "agent-output", "agent ran ok\nexit 0\n");
    defer b.deinit();
    try std.testing.expectEqual(Kind.agent, b.kind);
    const n = try b.saveAs(tmp_path);
    try std.testing.expectEqual(@as(usize, 20), n);
    try std.testing.expectEqual(Kind.file, b.kind);
    try std.testing.expectEqualStrings(tmp_path, b.name);
    try std.testing.expect(!b.dirty);

    const c_path = try a.dupeZ(u8, tmp_path);
    defer a.free(c_path);
    _ = libc.unlink(@ptrCast(c_path.ptr));
}
