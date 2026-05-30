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

    /// Insert `bytes` at byte-offset `at`. `at == contents.len` is the
    /// degenerate "insert at end" case and is identical to `append`.
    /// `at > contents.len` is rejected as `error.OutOfRange` rather than
    /// silently clamped, because the caller is mis-modeling the buffer
    /// and a silent clamp turns a logic bug into a data bug.
    ///
    /// If the buffer's `mark` is at or past the insertion point, it is
    /// shifted forward by `bytes.len` so a cursor stays "in front of"
    /// the inserted text rather than landing in the middle of it. This
    /// is the principle-of-least-surprise contract real editors use.
    ///
    /// Marks the buffer dirty.
    pub fn insertAt(self: *Buffer, at: usize, bytes: []const u8) !void {
        if (at > self.contents.len) return error.OutOfRange;
        if (bytes.len == 0) return; // no-op, no dirty flip

        const new_len = self.contents.len + bytes.len;
        const copy = try self.allocator.alloc(u8, new_len);
        @memcpy(copy[0..at], self.contents[0..at]);
        @memcpy(copy[at .. at + bytes.len], bytes);
        @memcpy(copy[at + bytes.len ..], self.contents[at..]);
        self.allocator.free(self.contents);
        self.contents = copy;
        if (self.mark >= at) self.mark += bytes.len;
        self.dirty = true;
    }

    /// Delete the byte range `[start, end)`. `start == end` is a no-op
    /// (does NOT flip dirty). `end > contents.len` or `start > end` is
    /// rejected as `error.OutOfRange` — silent clamping has the same
    /// failure mode as `insertAt` above.
    ///
    /// `mark` is updated to track the deletion:
    ///   - if mark < start, mark is unchanged
    ///   - if start <= mark < end, mark snaps to start (cursor was in
    ///     the deleted range; land it at the deletion point)
    ///   - if mark >= end, mark shifts left by (end - start)
    ///
    /// Marks the buffer dirty (when range is non-empty).
    pub fn deleteRange(self: *Buffer, start: usize, end: usize) !void {
        if (start > end) return error.OutOfRange;
        if (end > self.contents.len) return error.OutOfRange;
        if (start == end) return; // no-op, no dirty flip

        const del_len = end - start;
        const new_len = self.contents.len - del_len;
        const copy = try self.allocator.alloc(u8, new_len);
        @memcpy(copy[0..start], self.contents[0..start]);
        @memcpy(copy[start..], self.contents[end..]);
        self.allocator.free(self.contents);
        self.contents = copy;

        if (self.mark >= end) {
            self.mark -= del_len;
        } else if (self.mark > start) {
            self.mark = start;
        }
        self.dirty = true;
    }

    /// Find the first byte offset where `pattern` starts in the buffer,
    /// or `null` if not present. Empty pattern returns `0` by convention
    /// (matches `std.mem.indexOf` + `strstr(3)` semantics: the empty
    /// string is a prefix of every position, and 0 is the leftmost).
    /// On an empty buffer with non-empty pattern returns `null`.
    pub fn findFirst(self: *const Buffer, pattern: []const u8) ?usize {
        if (pattern.len == 0) return 0;
        return std.mem.indexOf(u8, self.contents, pattern);
    }

    /// Find the first byte offset where `pattern` starts at or after
    /// `start`, or `null` if not present. Empty pattern returns
    /// `min(start, contents.len)` (same anchor-at-cursor semantics as
    /// `findFirst` lifted by `start`). `start > contents.len` is clamped
    /// to `contents.len` rather than rejected — search past EOF is a
    /// natural miss, not a usage bug.
    pub fn findFrom(self: *const Buffer, pattern: []const u8, start: usize) ?usize {
        const clamped = @min(start, self.contents.len);
        if (pattern.len == 0) return clamped;
        if (clamped >= self.contents.len) return null;
        const off_in_tail = std.mem.indexOf(u8, self.contents[clamped..], pattern) orelse return null;
        return clamped + off_in_tail;
    }

    /// Replace the first occurrence of `pattern` with `replacement` by
    /// composing `findFirst` + `deleteRange` + `insertAt`. Returns
    /// `true` if a replacement was made, `false` if the pattern was not
    /// found. An empty `pattern` returns `error.EmptyPattern` — the
    /// degenerate "match every position" interpretation would either
    /// loop forever (replace-all) or no-op (replace-first inserts at 0
    /// then matches the just-inserted text), neither of which is what
    /// the caller meant. Force the caller to disambiguate.
    ///
    /// Empty `replacement` is the natural "delete first occurrence"
    /// composition and is fully supported.
    pub fn replaceFirst(self: *Buffer, pattern: []const u8, replacement: []const u8) !bool {
        if (pattern.len == 0) return error.EmptyPattern;
        const at = self.findFirst(pattern) orelse return false;
        // Composition order is load-bearing: deleteRange first, then
        // insertAt at the same offset. If we insertAt first, the
        // pattern's start offset still points into the old text but the
        // subsequent deleteRange would target shifted bytes.
        try self.deleteRange(at, at + pattern.len);
        try self.insertAt(at, replacement);
        return true;
    }

    /// Return every non-overlapping byte offset at which `pattern`
    /// starts in the buffer. The returned slice is owned by the caller
    /// and must be freed with `allocator.free`. Empty pattern returns
    /// `error.EmptyPattern`; same disambiguation as `replaceFirst`:
    /// "match every position" would yield contents.len+1 zero-width
    /// offsets, which is never what the caller meant and would explode
    /// the allocator on large buffers.
    ///
    /// Overlap convention: non-overlapping, left-anchored. For
    /// haystack "aaaa" with pattern "aa" the offsets are `[0, 2]`, not
    /// `[0, 1, 2]`. After each hit at offset `o` the scanner advances
    /// to `o + pattern.len`. This is the same convention `tr` /
    /// `grep -o` / `std.mem.replaceOwned` use.
    pub fn findAll(self: *const Buffer, allocator: std.mem.Allocator, pattern: []const u8) ![]usize {
        if (pattern.len == 0) return error.EmptyPattern;
        var hits: std.ArrayList(usize) = .empty;
        errdefer hits.deinit(allocator);
        var cursor: usize = 0;
        while (cursor <= self.contents.len) {
            const found = self.findFrom(pattern, cursor) orelse break;
            try hits.append(allocator, found);
            cursor = found + pattern.len;
        }
        return hits.toOwnedSlice(allocator);
    }

    /// Replace every non-overlapping occurrence of `pattern` with
    /// `replacement` by composing `findFrom` + `deleteRange` +
    /// `insertAt` in a forward-walking loop. Returns the count of
    /// replacements made (0 if pattern not present).
    ///
    /// The cursor advances past each insertion (`cursor = at +
    /// replacement.len`), so a `(replace-all "a" "aa")` terminates
    /// after touching every original `a` exactly once; the
    /// newly-inserted "aa" is NOT re-scanned. This matches
    /// `std.mem.replaceOwned` semantics and is the only termination-
    /// safe convention when replacement may contain pattern.
    ///
    /// Empty `pattern` returns `error.EmptyPattern` for the same
    /// reason `replaceFirst` does; the alternative is an infinite
    /// loop or an N+1 zero-width insert. Empty `replacement` is the
    /// natural "delete all occurrences" composition and is supported.
    pub fn replaceAll(self: *Buffer, pattern: []const u8, replacement: []const u8) !usize {
        if (pattern.len == 0) return error.EmptyPattern;
        var count: usize = 0;
        var cursor: usize = 0;
        while (cursor <= self.contents.len) {
            const at = self.findFrom(pattern, cursor) orelse break;
            // Composition order matches replaceFirst: deleteRange first
            // so the pattern's offset is still valid, then insertAt at
            // the same offset.
            try self.deleteRange(at, at + pattern.len);
            try self.insertAt(at, replacement);
            count += 1;
            // Walk forward past the inserted bytes. If we left cursor at
            // `at` and replacement starts with pattern (e.g. pattern="a"
            // replacement="aa"), the next iteration would match again
            // and spin forever.
            cursor = at + replacement.len;
        }
        return count;
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

// ---------------------------------------------------------------------------
// Property-based tests on the buffer protocol. 5000-trial corpora establish
// load-bearing invariants under randomized input.
// ---------------------------------------------------------------------------

test "property: fromBytes is byte-identity round-trip across 5000 random shapes" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234_abcd_5678_ef01);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 5000) : (trial += 1) {
        const len = rand.intRangeAtMost(usize, 0, 256);
        const bytes = try a.alloc(u8, len);
        defer a.free(bytes);
        rand.bytes(bytes);
        var b = try Buffer.fromBytes(a, .agent, "p", bytes);
        defer b.deinit();
        try std.testing.expectEqualSlices(u8, bytes, b.contents);
    }
}

test "property: append is monotonic + total-byte-conserving across 1000 sequences" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdead_beef_1234_5678);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        var b = try Buffer.fromBytes(a, .agent, "p", "");
        defer b.deinit();
        const num_appends = rand.intRangeAtMost(usize, 0, 20);
        var expected_size: usize = 0;
        var k: usize = 0;
        while (k < num_appends) : (k += 1) {
            const chunk_len = rand.intRangeAtMost(usize, 0, 32);
            const chunk = try a.alloc(u8, chunk_len);
            defer a.free(chunk);
            for (chunk) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'z');
            try b.append(chunk);
            expected_size += chunk_len;
            try std.testing.expectEqual(expected_size, b.contents.len);
        }
        // After at least one append, dirty must be true (if num_appends>0).
        if (num_appends > 0) try std.testing.expect(b.dirty);
    }
}

test "property: setContents is destructive replacement + dirty across 1000 trials" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xcafe_babe_0000_face);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        const orig_len = rand.intRangeAtMost(usize, 0, 64);
        const orig = try a.alloc(u8, orig_len);
        defer a.free(orig);
        rand.bytes(orig);
        var b = try Buffer.fromBytes(a, .agent, "p", orig);
        defer b.deinit();
        try std.testing.expect(!b.dirty);
        try std.testing.expectEqualSlices(u8, orig, b.contents);

        const new_len = rand.intRangeAtMost(usize, 0, 64);
        const new_bytes = try a.alloc(u8, new_len);
        defer a.free(new_bytes);
        rand.bytes(new_bytes);
        try b.setContents(new_bytes);
        try std.testing.expectEqualSlices(u8, new_bytes, b.contents);
        try std.testing.expect(b.dirty);
    }
}

test "property: save+fromFile round-trips 200 random buffers byte-for-byte" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0123_4567_89ab_cdef);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const len = rand.intRangeAtMost(usize, 0, 1024);
        const bytes = try a.alloc(u8, len);
        defer a.free(bytes);
        rand.bytes(bytes);

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/mast-prop-{d}-{d}.bin", .{ libc.getpid(), trial });

        var b = try Buffer.fromBytes(a, .file, path, bytes);
        defer b.deinit();
        b.dirty = true;
        const n = try b.save();
        try std.testing.expectEqual(len, n);

        var b2 = try Buffer.fromFile(a, path);
        defer b2.deinit();
        try std.testing.expectEqualSlices(u8, bytes, b2.contents);

        const c_path = try a.dupeZ(u8, path);
        defer a.free(c_path);
        _ = libc.unlink(@ptrCast(c_path.ptr));
    }
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

// ---------------------------------------------------------------------------
// insertAt / deleteRange — random-access editing primitives.
// These close the v1.4 gap "the buffer protocol only supports end-append and
// full-replace; real editing requires offset-positioned insert and delete."
// ---------------------------------------------------------------------------

test "insertAt: at start prepends bytes + shifts mark forward" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "world");
    defer b.deinit();
    b.mark = 3; // cursor inside "world"
    try b.insertAt(0, "hello, ");
    try std.testing.expectEqualStrings("hello, world", b.contents);
    try std.testing.expect(b.dirty);
    try std.testing.expectEqual(@as(usize, 10), b.mark); // 3 + 7
}

test "insertAt: at middle splits + interleaves" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZ");
    defer b.deinit();
    try b.insertAt(3, "123");
    try std.testing.expectEqualStrings("abc123XYZ", b.contents);
}

test "insertAt: at end == append behavior" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try b.insertAt(3, "def");
    try std.testing.expectEqualStrings("abcdef", b.contents);
}

test "insertAt: past-end rejected (no silent clamp)" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try std.testing.expectError(error.OutOfRange, b.insertAt(99, "X"));
    // Buffer unchanged, NOT dirty after rejected op.
    try std.testing.expectEqualStrings("abc", b.contents);
    try std.testing.expect(!b.dirty);
}

test "insertAt: empty-bytes is no-op (does NOT flip dirty)" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try std.testing.expect(!b.dirty);
    try b.insertAt(1, "");
    try std.testing.expectEqualStrings("abc", b.contents);
    try std.testing.expect(!b.dirty);
}

test "insertAt: mark before insertion point is NOT shifted" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    b.mark = 2;
    try b.insertAt(4, "XYZ");
    try std.testing.expectEqualStrings("abcdXYZef", b.contents);
    try std.testing.expectEqual(@as(usize, 2), b.mark);
}

test "deleteRange: middle excision shrinks buffer + clamps mark" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZdef");
    defer b.deinit();
    b.mark = 5; // inside the doomed range [3,6)
    try b.deleteRange(3, 6);
    try std.testing.expectEqualStrings("abcdef", b.contents);
    try std.testing.expect(b.dirty);
    try std.testing.expectEqual(@as(usize, 3), b.mark); // snapped to start
}

test "deleteRange: mark after deletion shifts left by deleted-len" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZdef");
    defer b.deinit();
    b.mark = 8; // past end of deletion
    try b.deleteRange(3, 6);
    try std.testing.expectEqualStrings("abcdef", b.contents);
    try std.testing.expectEqual(@as(usize, 5), b.mark); // 8 - 3
}

test "deleteRange: mark before deletion unchanged" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZdef");
    defer b.deinit();
    b.mark = 2;
    try b.deleteRange(3, 6);
    try std.testing.expectEqual(@as(usize, 2), b.mark);
}

test "deleteRange: empty range is no-op (does NOT flip dirty)" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try std.testing.expect(!b.dirty);
    try b.deleteRange(1, 1);
    try std.testing.expectEqualStrings("abc", b.contents);
    try std.testing.expect(!b.dirty);
}

test "deleteRange: full-buffer deletion empties contents" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try b.deleteRange(0, 6);
    try std.testing.expectEqualStrings("", b.contents);
    try std.testing.expect(b.dirty);
}

test "deleteRange: end past contents rejected" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try std.testing.expectError(error.OutOfRange, b.deleteRange(0, 99));
    try std.testing.expectEqualStrings("abc", b.contents);
    try std.testing.expect(!b.dirty);
}

test "deleteRange: start > end rejected" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expectError(error.OutOfRange, b.deleteRange(4, 2));
    try std.testing.expectEqualStrings("abcdef", b.contents);
    try std.testing.expect(!b.dirty);
}

test "property: insertAt then deleteRange round-trips across 1000 random shapes" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xFEED_BEEF_CAFE_0000);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        const base_len = rand.intRangeAtMost(usize, 0, 128);
        const base = try a.alloc(u8, base_len);
        defer a.free(base);
        for (base) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'z');

        var b = try Buffer.fromBytes(a, .agent, "p", base);
        defer b.deinit();

        const at = if (base_len == 0) 0 else rand.intRangeAtMost(usize, 0, base_len);
        const ins_len = rand.intRangeAtMost(usize, 0, 32);
        const ins = try a.alloc(u8, ins_len);
        defer a.free(ins);
        for (ins) |*c| c.* = rand.intRangeAtMost(u8, 'A', 'Z');

        try b.insertAt(at, ins);
        try std.testing.expectEqual(base_len + ins_len, b.contents.len);

        // Delete the inserted run — buffer must be byte-identical to base.
        try b.deleteRange(at, at + ins_len);
        try std.testing.expectEqualSlices(u8, base, b.contents);
    }
}

test "property: insertAt+deleteRange match model across 500 random sequences" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDEAD_C0DE_DEAD_BEEF);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        const init_len = rand.intRangeAtMost(usize, 0, 32);
        const init_bytes = try a.alloc(u8, init_len);
        defer a.free(init_bytes);
        for (init_bytes) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'z');

        var b = try Buffer.fromBytes(a, .agent, "p", init_bytes);
        defer b.deinit();

        var model: std.ArrayList(u8) = .empty;
        defer model.deinit(a);
        try model.appendSlice(a, init_bytes);

        const num_ops = rand.intRangeAtMost(usize, 1, 10);
        var op: usize = 0;
        while (op < num_ops) : (op += 1) {
            if (rand.boolean() and model.items.len > 0) {
                // deleteRange a random sub-range
                const s = rand.intRangeAtMost(usize, 0, model.items.len);
                const e = rand.intRangeAtMost(usize, s, model.items.len);
                try b.deleteRange(s, e);
                model.replaceRangeAssumeCapacity(s, e - s, &.{});
            } else {
                // insertAt a random offset
                const at = rand.intRangeAtMost(usize, 0, model.items.len);
                const ins_len = rand.intRangeAtMost(usize, 0, 16);
                const ins = try a.alloc(u8, ins_len);
                defer a.free(ins);
                for (ins) |*c| c.* = rand.intRangeAtMost(u8, '0', '9');
                try b.insertAt(at, ins);
                try model.insertSlice(a, at, ins);
            }
            try std.testing.expectEqualSlices(u8, model.items, b.contents);
        }
    }
}

// ============================================================================
// Extended buffer-protocol property corpus — mixed-op sequence stress test.
// 2000 trials of randomly-interleaved append+setContents+saveAs+save against
// a model implementation. Closes the v1.2.x property-coverage axis with
// adversarial sequences that single-op tests can't reach.
// ============================================================================

test "property: 2000-trial mixed-op sequence matches model implementation" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xBEEF_FEED_DEAD_C0DE);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        // Start with a random initial buffer
        const init_len = rand.intRangeAtMost(usize, 0, 64);
        const init_bytes = try a.alloc(u8, init_len);
        defer a.free(init_bytes);
        for (init_bytes) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'z');

        var b = try Buffer.fromBytes(a, .agent, "p", init_bytes);
        defer b.deinit();

        // Model: just track expected contents and dirty flag separately
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(a);
        try expected.appendSlice(a, init_bytes);
        var expected_dirty = false;

        const num_ops = rand.intRangeAtMost(usize, 1, 12);
        var op: usize = 0;
        while (op < num_ops) : (op += 1) {
            const choice = rand.intRangeAtMost(u8, 0, 2);
            switch (choice) {
                0 => {
                    // append
                    const chunk_len = rand.intRangeAtMost(usize, 0, 16);
                    const chunk = try a.alloc(u8, chunk_len);
                    defer a.free(chunk);
                    for (chunk) |*c| c.* = rand.intRangeAtMost(u8, 'A', 'Z');
                    try b.append(chunk);
                    try expected.appendSlice(a, chunk);
                    if (chunk_len > 0) expected_dirty = true;
                },
                1 => {
                    // setContents
                    const new_len = rand.intRangeAtMost(usize, 0, 64);
                    const new_bytes = try a.alloc(u8, new_len);
                    defer a.free(new_bytes);
                    for (new_bytes) |*c| c.* = rand.intRangeAtMost(u8, '0', '9');
                    try b.setContents(new_bytes);
                    expected.clearRetainingCapacity();
                    try expected.appendSlice(a, new_bytes);
                    expected_dirty = true;
                },
                else => {
                    // Read-only check (no mutation): just verify the contents
                    // still match the model. This catches between-op state drift.
                    try std.testing.expectEqualSlices(u8, expected.items, b.contents);
                },
            }
            // After every op, contents must match model.
            try std.testing.expectEqualSlices(u8, expected.items, b.contents);
            // Dirty flag tracks model.
            if (expected_dirty) try std.testing.expect(b.dirty);
        }
    }
}

// ---------------------------------------------------------------------------
// findFirst / findFrom / replaceFirst — search + replace primitive.
// These close the v1.5 gap: insertAt + deleteRange give random-access
// editing but the script can't ask "where is this pattern?" without
// reaching into Buffer.contents directly. replaceFirst composes the two
// write primitives so the script layer never has to.
// ---------------------------------------------------------------------------

test "findFirst: empty buffer returns null for non-empty pattern" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, null), b.findFirst("abc"));
}

test "findFirst: empty buffer + empty pattern returns 0 (anchor convention)" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, 0), b.findFirst(""));
}

test "findFirst: hit at start, middle, end-of-buffer" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZpqr");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, 0), b.findFirst("abc"));
    try std.testing.expectEqual(@as(?usize, 3), b.findFirst("XYZ"));
    // Tail-anchored hit (last byte): "r" only occurs at index 8.
    try std.testing.expectEqual(@as(?usize, 8), b.findFirst("r"));
}

test "findFirst: miss returns null" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, null), b.findFirst("XYZ"));
}

test "findFirst: empty pattern on non-empty buffer returns 0" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, 0), b.findFirst(""));
}

test "findFrom: skips past the first hit" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZabcXYZ");
    defer b.deinit();
    // First "abc" is at 0; starting from 1 we should find the second at 6.
    try std.testing.expectEqual(@as(?usize, 6), b.findFrom("abc", 1));
    // Starting exactly at the second hit returns it.
    try std.testing.expectEqual(@as(?usize, 6), b.findFrom("abc", 6));
    // Starting past the second hit returns null (no third occurrence).
    try std.testing.expectEqual(@as(?usize, null), b.findFrom("abc", 7));
}

test "findFrom: start at hit position returns that hit" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "hello world");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, 6), b.findFrom("world", 6));
}

test "findFrom: start past end returns null for non-empty pattern" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, null), b.findFrom("a", 99));
}

test "findFrom: empty pattern returns clamped start" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc");
    defer b.deinit();
    try std.testing.expectEqual(@as(?usize, 2), b.findFrom("", 2));
    try std.testing.expectEqual(@as(?usize, 3), b.findFrom("", 99)); // clamped
}

test "replaceFirst: no-op when pattern missing (returns false, not dirty)" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expect(!b.dirty);
    const did = try b.replaceFirst("XYZ", "Q");
    try std.testing.expect(!did);
    try std.testing.expectEqualStrings("abcdef", b.contents);
    try std.testing.expect(!b.dirty);
}

test "replaceFirst: hit composes deleteRange + insertAt correctly" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "hello WORLD hello");
    defer b.deinit();
    const did = try b.replaceFirst("hello", "HI");
    try std.testing.expect(did);
    try std.testing.expectEqualStrings("HI WORLD hello", b.contents);
    try std.testing.expect(b.dirty);
}

test "replaceFirst: empty replacement equals delete-first-occurrence" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "remove ME please");
    defer b.deinit();
    const did = try b.replaceFirst("ME ", "");
    try std.testing.expect(did);
    try std.testing.expectEqualStrings("remove please", b.contents);
    try std.testing.expect(b.dirty);
}

test "replaceFirst: empty pattern returns error.EmptyPattern" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expectError(error.EmptyPattern, b.replaceFirst("", "X"));
    // Buffer unchanged; dirty NOT flipped.
    try std.testing.expectEqualStrings("abcdef", b.contents);
    try std.testing.expect(!b.dirty);
}

test "replaceFirst: replacement longer than pattern grows buffer correctly" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abc.def");
    defer b.deinit();
    const did = try b.replaceFirst(".", " AND ");
    try std.testing.expect(did);
    try std.testing.expectEqualStrings("abc AND def", b.contents);
}

test "replaceFirst: only replaces first occurrence, not all" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "a-b-c-d");
    defer b.deinit();
    const did = try b.replaceFirst("-", "+");
    try std.testing.expect(did);
    try std.testing.expectEqualStrings("a+b-c-d", b.contents);
}

test "property: replaceFirst matches std.mem.replace reference (500 trials)" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xF1D5_2EF_1ACE_0001);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        // Random haystack over a small alphabet so patterns actually hit.
        const haystack_len = rand.intRangeAtMost(usize, 0, 128);
        const haystack = try a.alloc(u8, haystack_len);
        defer a.free(haystack);
        for (haystack) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'd');

        // Pattern length 1-4 over the same alphabet.
        const pat_len = rand.intRangeAtMost(usize, 1, 4);
        const pattern = try a.alloc(u8, pat_len);
        defer a.free(pattern);
        for (pattern) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'd');

        // Replacement length 0-6 over a disjoint alphabet so it can't
        // itself match the pattern.
        const rep_len = rand.intRangeAtMost(usize, 0, 6);
        const replacement = try a.alloc(u8, rep_len);
        defer a.free(replacement);
        for (replacement) |*c| c.* = rand.intRangeAtMost(u8, 'W', 'Z');

        var b = try Buffer.fromBytes(a, .agent, "p", haystack);
        defer b.deinit();
        const did = try b.replaceFirst(pattern, replacement);

        // Reference model: find first occurrence manually, splice once.
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(a);
        if (std.mem.indexOf(u8, haystack, pattern)) |idx| {
            try expected.appendSlice(a, haystack[0..idx]);
            try expected.appendSlice(a, replacement);
            try expected.appendSlice(a, haystack[idx + pat_len ..]);
            try std.testing.expect(did);
        } else {
            try expected.appendSlice(a, haystack);
            try std.testing.expect(!did);
        }
        try std.testing.expectEqualSlices(u8, expected.items, b.contents);
    }
}

// ---------------------------------------------------------------------------
// findAll / replaceAll: bulk-replace primitive. The composition is
// findFrom + deleteRange + insertAt in a forward-walking loop. The
// load-bearing invariants are:
//   (a) non-overlapping, left-anchored offsets (matches std.mem semantics)
//   (b) replaceAll terminates even when replacement contains pattern
//       (cursor advances past inserted bytes, not past original pattern)
//   (c) empty pattern is rejected as EmptyPattern (same disambiguation
//       as replaceFirst; N+1 zero-width hits or infinite loop)
// ---------------------------------------------------------------------------

test "findAll: 0 hits on empty buffer returns empty slice" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "");
    defer b.deinit();
    const hits = try b.findAll(a, "abc");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "findAll: 0 hits when pattern absent returns empty slice" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "the quick brown fox");
    defer b.deinit();
    const hits = try b.findAll(a, "zebra");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "findAll: 1 hit returns single offset" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcXYZdef");
    defer b.deinit();
    const hits = try b.findAll(a, "XYZ");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(usize, 3), hits[0]);
}

test "findAll: N non-overlapping hits returns all offsets in order" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "ab cd ab ef ab gh");
    defer b.deinit();
    const hits = try b.findAll(a, "ab");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    try std.testing.expectEqual(@as(usize, 0), hits[0]);
    try std.testing.expectEqual(@as(usize, 6), hits[1]);
    try std.testing.expectEqual(@as(usize, 12), hits[2]);
}

test "findAll: overlapping pattern uses non-overlapping convention" {
    // Haystack "aaaa" with pattern "aa": the documented convention is
    // non-overlapping, left-anchored: after matching at 0 the cursor
    // jumps to 2 (past the matched run), NOT 1. So hits are [0, 2],
    // not [0, 1, 2]. This matches std.mem / tr / grep -o.
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "aaaa");
    defer b.deinit();
    const hits = try b.findAll(a, "aa");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(usize, 0), hits[0]);
    try std.testing.expectEqual(@as(usize, 2), hits[1]);
}

test "findAll: empty pattern returns error.EmptyPattern" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expectError(error.EmptyPattern, b.findAll(a, ""));
}

test "findAll: single-byte pattern across whole buffer" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "a-b-c-d-e");
    defer b.deinit();
    const hits = try b.findAll(a, "-");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 4), hits.len);
    try std.testing.expectEqual(@as(usize, 1), hits[0]);
    try std.testing.expectEqual(@as(usize, 3), hits[1]);
    try std.testing.expectEqual(@as(usize, 5), hits[2]);
    try std.testing.expectEqual(@as(usize, 7), hits[3]);
}

test "replaceAll: 0-hit no-op returns 0 and does not flip dirty" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "the quick brown fox");
    defer b.deinit();
    try std.testing.expect(!b.dirty);
    const n = try b.replaceAll("zebra", "X");
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqualStrings("the quick brown fox", b.contents);
    try std.testing.expect(!b.dirty);
}

test "replaceAll: 1-hit identical to replaceFirst" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "hello WORLD");
    defer b.deinit();
    const n = try b.replaceAll("WORLD", "there");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("hello there", b.contents);
    try std.testing.expect(b.dirty);
}

test "replaceAll: N hits walk forward without infinite loop" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "a-b-c-d-e");
    defer b.deinit();
    const n = try b.replaceAll("-", "+");
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("a+b+c+d+e", b.contents);
    try std.testing.expect(b.dirty);
}

test "replaceAll: empty replacement equals delete-all-occurrences" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "ab_cd_ef_gh");
    defer b.deinit();
    const n = try b.replaceAll("_", "");
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abcdefgh", b.contents);
    try std.testing.expect(b.dirty);
}

test "replaceAll: replacement contains pattern does NOT loop forever" {
    // The termination-critical case: pattern="a" replacement="aa".
    // A naive cursor-stays-at-`at` implementation would match the
    // first inserted "a" of "aa", replace it with "aa", and spin
    // forever. The correct implementation advances cursor to `at +
    // replacement.len`, so each original "a" is touched exactly once.
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "aXaXa");
    defer b.deinit();
    const n = try b.replaceAll("a", "aa");
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("aaXaaXaa", b.contents);
    try std.testing.expect(b.dirty);
}

test "replaceAll: longer-replacement growth across N hits" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "foo.bar.baz");
    defer b.deinit();
    const n = try b.replaceAll(".", " AND ");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("foo AND bar AND baz", b.contents);
}

test "replaceAll: shorter-replacement shrinks across N hits" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "alphaXXXbetaXXXgamma");
    defer b.deinit();
    const n = try b.replaceAll("XXX", "-");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("alpha-beta-gamma", b.contents);
}

test "replaceAll: overlapping pattern uses non-overlapping convention" {
    // Same convention as findAll. "aaaa" with pattern "aa" replaced by
    // "B" must yield "BB" (two replacements, not three or one).
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "aaaa");
    defer b.deinit();
    const n = try b.replaceAll("aa", "B");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("BB", b.contents);
}

test "replaceAll: empty pattern returns error.EmptyPattern" {
    const a = std.testing.allocator;
    var b = try Buffer.fromBytes(a, .agent, "t", "abcdef");
    defer b.deinit();
    try std.testing.expectError(error.EmptyPattern, b.replaceAll("", "X"));
    try std.testing.expectEqualStrings("abcdef", b.contents);
    try std.testing.expect(!b.dirty);
}

test "property: 500-trial replaceAll matches std.mem.replaceOwned reference" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xA11_BEEF_F00D_2024);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        // Small alphabet so patterns actually hit.
        const haystack_len = rand.intRangeAtMost(usize, 0, 128);
        const haystack = try a.alloc(u8, haystack_len);
        defer a.free(haystack);
        for (haystack) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'd');

        const pat_len = rand.intRangeAtMost(usize, 1, 4);
        const pattern = try a.alloc(u8, pat_len);
        defer a.free(pattern);
        for (pattern) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'd');

        // Replacement length 0-6. Use a disjoint alphabet so the
        // replacement bytes can't themselves form a new pattern hit.
        // std.mem.replaceOwned only does one pass, so to stay model-
        // equivalent we must too. (replaceAll's cursor-walk discipline
        // gives the same single-pass semantics; the disjoint alphabet
        // just makes the model trivial to compute.)
        const rep_len = rand.intRangeAtMost(usize, 0, 6);
        const replacement = try a.alloc(u8, rep_len);
        defer a.free(replacement);
        for (replacement) |*c| c.* = rand.intRangeAtMost(u8, 'W', 'Z');

        var b = try Buffer.fromBytes(a, .agent, "p", haystack);
        defer b.deinit();
        const count = try b.replaceAll(pattern, replacement);

        // Reference: std.mem.replaceOwned (which uses the same non-
        // overlapping left-anchored convention).
        const expected = try std.mem.replaceOwned(u8, a, haystack, pattern, replacement);
        defer a.free(expected);
        const expected_count = std.mem.count(u8, haystack, pattern);

        try std.testing.expectEqual(expected_count, count);
        try std.testing.expectEqualSlices(u8, expected, b.contents);
    }
}

test "property: findAll offsets are exactly the indexOf-walk reference (500 trials)" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xF1ED_A11_BABE_2024);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        const haystack_len = rand.intRangeAtMost(usize, 0, 128);
        const haystack = try a.alloc(u8, haystack_len);
        defer a.free(haystack);
        for (haystack) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'd');

        const pat_len = rand.intRangeAtMost(usize, 1, 4);
        const pattern = try a.alloc(u8, pat_len);
        defer a.free(pattern);
        for (pattern) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'd');

        var b = try Buffer.fromBytes(a, .agent, "p", haystack);
        defer b.deinit();
        const hits = try b.findAll(a, pattern);
        defer a.free(hits);

        // Reference: walk std.mem.indexOfPos forward, non-overlapping.
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(a);
        var cursor: usize = 0;
        while (cursor <= haystack.len) {
            const found = std.mem.indexOfPos(u8, haystack, cursor, pattern) orelse break;
            try expected.append(a, found);
            cursor = found + pat_len;
        }
        try std.testing.expectEqualSlices(usize, expected.items, hits);
    }
}

test "property: 100-trial save-then-fromFile preserves arbitrary binary content" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xCAFE_F00D_1234_5678);
    const rand = prng.random();
    var trial: usize = 0;
    while (trial < 100) : (trial += 1) {
        const len = rand.intRangeAtMost(usize, 0, 4096);
        const bytes = try a.alloc(u8, len);
        defer a.free(bytes);
        // Pure random bytes including high-bit chars and 0x00
        rand.bytes(bytes);

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/mast-prop-bin-{d}-{d}.dat", .{ libc.getpid(), trial });

        var b = try Buffer.fromBytes(a, .file, path, bytes);
        defer b.deinit();
        b.dirty = true;
        const n = try b.save();
        try std.testing.expectEqual(len, n);

        var b2 = try Buffer.fromFile(a, path);
        defer b2.deinit();
        try std.testing.expectEqualSlices(u8, bytes, b2.contents);

        const c_path = try a.dupeZ(u8, path);
        defer a.free(c_path);
        _ = libc.unlink(@ptrCast(c_path.ptr));
    }
}
