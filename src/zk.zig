// zk.zig: zettelkasten editor surface for mast.
//
// Wires mast as the structural-edit surface for ~/codex (atomic-note
// substrate) and ~/0theta (canonical-archive arc). Two primitives:
//
//   zettelkasten-open    (root, slug)
//     Resolve `slug` to a file path under `root`. The first-path-segment
//     rule: walk the top-level subdirs of `root` (depth=1) and return the
//     first `<subdir>/<slug>.md` that exists. Mirrors the codex-tool
//     category-walk so the same slug a wiki-link references is the slug
//     mast accepts.
//
//   zettelkasten-batch-replace  (root, pattern, replacement)
//     Walk every `.md` file under `root` (recursive), run `replaceAll`,
//     append one structural-edit JSONL row per file touched (count >= 0).
//     The audit log is the load-bearing artifact: codex-tool can re-read
//     it on next graph audit to know what mast did.
//
// Audit-log shape (one JSON object per line, default
// `~/.mast-zk-audit.jsonl`, override via `--audit-path`):
//
//   { "ts": <unix-sec>,
//     "fleet": "zk-batch-replace",
//     "root": "<absolute-root>",
//     "file_rel": "<path-relative-to-root>",
//     "pattern": "<escaped-pattern>",
//     "replacement": "<escaped-replacement>",
//     "count": <int>,
//     "sha_before": "<hex-sha256>",
//     "sha_after":  "<hex-sha256>" }
//
// Per the falsifier in exp-1780164320-543035644: for every audit row with
// count > 0, sha_before MUST differ from sha_after. The smoke run cross-
// checks this invariant against a real temp directory.
//
// libc-only filesystem path (consistent with audit.zig + main.zig
// rationale: insulate from Zig 0.13–0.16 std.fs/std.Io churn).

const std = @import("std");

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("errno.h");
});

pub const Error = error{
    SlugNotFound,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    RenameFailed,
    AuditOpenFailed,
    AuditWriteFailed,
    OutOfMemory,
    NoSpaceLeft,
    EmptyPattern,
    StatFailed,
    InvalidRoot,
};

// ─── slug resolution ────────────────────────────────────────────────────

/// Resolve `slug` to a path under `root`. Walks the top-level subdirs of
/// `root` (depth=1) and returns the first `<subdir>/<slug>.md` that
/// exists. Returns `error.SlugNotFound` if no category contains the slug.
///
/// Caller owns the returned buffer (allocator-allocated).
pub fn resolveSlug(
    allocator: std.mem.Allocator,
    root: []const u8,
    slug: []const u8,
) Error![]u8 {
    if (root.len == 0) return error.InvalidRoot;
    // Quick path: if the slug already contains a '/', honor it as-is
    // (caller already named the category). Same shape as codex-tool's
    // "explicit-category" override.
    if (std.mem.indexOfScalar(u8, slug, '/') != null) {
        const path = try allocPathJoin(allocator, root, slug);
        if (existsRegular(path)) return path;
        allocator.free(path);
        return error.SlugNotFound;
    }

    // Open the root and iterate top-level entries via libc opendir.
    const c_root = allocator.dupeZ(u8, root) catch return error.OutOfMemory;
    defer allocator.free(c_root);
    const dirp = libc.opendir(@ptrCast(c_root.ptr));
    if (dirp == null) return error.InvalidRoot;
    defer _ = libc.closedir(dirp);

    while (true) {
        const ent_ptr = libc.readdir(dirp);
        if (ent_ptr == null) break;
        const ent = ent_ptr.*;
        const name_c: [*:0]const u8 = @ptrCast(&ent.d_name);
        const name = std.mem.span(name_c);
        if (name.len == 0) continue;
        if (name[0] == '.') continue; // skip ., .., dot-dirs
        // Build "<root>/<subdir>/<slug>.md" and stat it.
        var stack_buf: [1024]u8 = undefined;
        const candidate = std.fmt.bufPrint(
            &stack_buf,
            "{s}/{s}/{s}.md",
            .{ root, name, slug },
        ) catch return error.NoSpaceLeft;
        if (existsRegular(candidate)) {
            return allocator.dupe(u8, candidate) catch return error.OutOfMemory;
        }
    }
    return error.SlugNotFound;
}

fn allocPathJoin(allocator: std.mem.Allocator, root: []const u8, sub: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    out.appendSlice(allocator, root) catch return error.OutOfMemory;
    if (root.len > 0 and root[root.len - 1] != '/') {
        out.append(allocator, '/') catch return error.OutOfMemory;
    }
    out.appendSlice(allocator, sub) catch return error.OutOfMemory;
    // Always end with `.md` to match the convention codex-tool uses.
    if (!std.mem.endsWith(u8, sub, ".md")) {
        out.appendSlice(allocator, ".md") catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Stat a path and return true if it exists and is a regular file.
fn existsRegular(path: []const u8) bool {
    var st: libc.struct_stat = undefined;
    var nul_buf: [1024]u8 = undefined;
    if (path.len + 1 > nul_buf.len) return false;
    @memcpy(nul_buf[0..path.len], path);
    nul_buf[path.len] = 0;
    if (libc.stat(@ptrCast(&nul_buf[0]), &st) != 0) return false;
    // S_IFREG = 0o100000 on Linux; bit-mask via S_IFMT == 0o170000.
    const S_IFMT: c_uint = 0o170000;
    const S_IFREG: c_uint = 0o100000;
    return (st.st_mode & S_IFMT) == S_IFREG;
}

// ─── recursive .md walk + batch replace ─────────────────────────────────

pub const ReplaceRow = struct {
    file_rel: []const u8, // owned
    count: usize,
    sha_before: [64]u8,
    sha_after: [64]u8,
};

pub const ReplaceResult = struct {
    rows: []ReplaceRow,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplaceResult) void {
        for (self.rows) |r| {
            self.allocator.free(r.file_rel);
        }
        self.allocator.free(self.rows);
    }
};

/// Walk every `.md` file under `root` (recursive), run `replaceAll` per
/// file, return a ReplaceRow per file walked. Files with count == 0 are
/// still emitted so the audit log captures the negative case (closes the
/// "did mast scan it?" question).
pub fn batchReplace(
    allocator: std.mem.Allocator,
    root: []const u8,
    pattern: []const u8,
    replacement: []const u8,
) Error!ReplaceResult {
    if (pattern.len == 0) return error.EmptyPattern;
    var rows: std.ArrayList(ReplaceRow) = .empty;
    errdefer {
        for (rows.items) |r| allocator.free(r.file_rel);
        rows.deinit(allocator);
    }
    try walkAndReplace(allocator, root, "", pattern, replacement, &rows);
    const owned = rows.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return ReplaceResult{ .rows = owned, .allocator = allocator };
}

fn walkAndReplace(
    allocator: std.mem.Allocator,
    root: []const u8,
    rel_prefix: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    rows: *std.ArrayList(ReplaceRow),
) Error!void {
    // Build the absolute directory path: root + "/" + rel_prefix (when
    // non-empty).
    var dir_buf: [2048]u8 = undefined;
    const dir_path = if (rel_prefix.len == 0)
        std.fmt.bufPrint(&dir_buf, "{s}", .{root}) catch return error.NoSpaceLeft
    else
        std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ root, rel_prefix }) catch return error.NoSpaceLeft;

    // Need a NUL-terminated copy for opendir.
    var dir_buf_z: [2048]u8 = undefined;
    if (dir_path.len + 1 > dir_buf_z.len) return error.NoSpaceLeft;
    @memcpy(dir_buf_z[0..dir_path.len], dir_path);
    dir_buf_z[dir_path.len] = 0;

    const dirp = libc.opendir(@ptrCast(&dir_buf_z[0]));
    if (dirp == null) return error.InvalidRoot;
    defer _ = libc.closedir(dirp);

    while (true) {
        const ent_ptr = libc.readdir(dirp);
        if (ent_ptr == null) break;
        const ent = ent_ptr.*;
        const name_c: [*:0]const u8 = @ptrCast(&ent.d_name);
        const name = std.mem.span(name_c);
        if (name.len == 0) continue;
        if (name[0] == '.') continue;

        // Stat to decide file vs directory.
        var child_abs_buf: [2048]u8 = undefined;
        const child_abs = std.fmt.bufPrint(
            &child_abs_buf,
            "{s}/{s}",
            .{ dir_path, name },
        ) catch return error.NoSpaceLeft;

        var st: libc.struct_stat = undefined;
        var nul_buf: [2048]u8 = undefined;
        if (child_abs.len + 1 > nul_buf.len) return error.NoSpaceLeft;
        @memcpy(nul_buf[0..child_abs.len], child_abs);
        nul_buf[child_abs.len] = 0;
        if (libc.stat(@ptrCast(&nul_buf[0]), &st) != 0) continue;

        const S_IFMT: c_uint = 0o170000;
        const S_IFREG: c_uint = 0o100000;
        const S_IFDIR: c_uint = 0o040000;
        const mode_kind = st.st_mode & S_IFMT;

        // Build relative path: rel_prefix + "/" + name (handle empty prefix).
        var rel_buf: [2048]u8 = undefined;
        const rel_child = if (rel_prefix.len == 0)
            std.fmt.bufPrint(&rel_buf, "{s}", .{name}) catch return error.NoSpaceLeft
        else
            std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ rel_prefix, name }) catch return error.NoSpaceLeft;

        if (mode_kind == S_IFDIR) {
            // Recurse. Need a stable copy of rel_child because the next
            // recursion may overwrite rel_buf.
            const rel_child_owned = allocator.dupe(u8, rel_child) catch return error.OutOfMemory;
            defer allocator.free(rel_child_owned);
            try walkAndReplace(allocator, root, rel_child_owned, pattern, replacement, rows);
        } else if (mode_kind == S_IFREG) {
            // Only operate on .md files.
            if (!std.mem.endsWith(u8, name, ".md")) continue;
            try replaceOneFile(allocator, child_abs, rel_child, pattern, replacement, rows);
        }
    }
}

fn replaceOneFile(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    rel_path: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    rows: *std.ArrayList(ReplaceRow),
) Error!void {
    const c_abs = allocator.dupeZ(u8, abs_path) catch return error.OutOfMemory;
    defer allocator.free(c_abs);
    const fd = libc.open(@ptrCast(c_abs.ptr), libc.O_RDONLY | libc.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;

    var st: libc.struct_stat = undefined;
    if (libc.fstat(fd, &st) != 0) {
        _ = libc.close(fd);
        return error.StatFailed;
    }
    const size: usize = @intCast(st.st_size);
    const before = allocator.alloc(u8, size) catch {
        _ = libc.close(fd);
        return error.OutOfMemory;
    };
    defer allocator.free(before);

    var read_total: usize = 0;
    while (read_total < size) {
        const rc = libc.read(fd, before.ptr + read_total, size - read_total);
        if (rc <= 0) break;
        read_total += @intCast(rc);
    }
    _ = libc.close(fd);
    if (read_total != size) return error.ReadFailed;

    // Run replaceAll in a fresh ArrayList (using ArrayList rather than
    // Buffer.replaceAll so this module stays import-free of buffer.zig
    // and the tests don't pull in libc-link decisions from buffer).
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(allocator);
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor <= before.len) {
        const slice = before[cursor..];
        const found = std.mem.indexOf(u8, slice, pattern) orelse {
            after.appendSlice(allocator, slice) catch return error.OutOfMemory;
            break;
        };
        after.appendSlice(allocator, slice[0..found]) catch return error.OutOfMemory;
        after.appendSlice(allocator, replacement) catch return error.OutOfMemory;
        count += 1;
        cursor = cursor + found + pattern.len;
    }

    var sha_before: [64]u8 = undefined;
    var sha_after: [64]u8 = undefined;
    sha256Hex(before, &sha_before);
    if (count > 0) {
        // Atomic write-back: same posture as Buffer.save (write to
        // .tmp.<pid> then rename, so a crash mid-write can't truncate the
        // source file).
        try writeAtomically(allocator, abs_path, after.items);
        sha256Hex(after.items, &sha_after);
    } else {
        // No edits: file content unchanged, sha_after == sha_before.
        @memcpy(&sha_after, &sha_before);
    }

    const rel_owned = allocator.dupe(u8, rel_path) catch return error.OutOfMemory;
    errdefer allocator.free(rel_owned);
    rows.append(allocator, .{
        .file_rel = rel_owned,
        .count = count,
        .sha_before = sha_before,
        .sha_after = sha_after,
    }) catch return error.OutOfMemory;
}

fn sha256Hex(data: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0xf];
    }
}

fn writeAtomically(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) Error!void {
    var tmp_buf: [2300]u8 = undefined;
    const pid = libc.getpid();
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}\x00", .{ path, pid }) catch return error.NoSpaceLeft;
    const c_tmp: [*c]const u8 = @ptrCast(tmp_path.ptr);
    const fd = libc.open(
        c_tmp,
        libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC,
        @as(c_uint, 0o644),
    );
    if (fd < 0) return error.OpenFailed;

    var written: usize = 0;
    while (written < contents.len) {
        const rc = libc.write(fd, contents.ptr + written, contents.len - written);
        if (rc <= 0) {
            _ = libc.close(fd);
            _ = libc.unlink(c_tmp);
            return error.WriteFailed;
        }
        written += @intCast(rc);
    }
    _ = libc.fsync(fd);
    _ = libc.close(fd);

    const c_path = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(c_path);
    if (libc.rename(c_tmp, @ptrCast(c_path.ptr)) != 0) {
        _ = libc.unlink(c_tmp);
        return error.RenameFailed;
    }
}

// ─── audit-log writer ───────────────────────────────────────────────────

/// Open the audit-log file at `path` in append mode. Caller closes via
/// `libc.close(fd)`.
pub fn openAuditLog(allocator: std.mem.Allocator, path: []const u8) Error!c_int {
    const c_path = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(c_path);
    const fd = libc.open(
        @ptrCast(c_path.ptr),
        libc.O_WRONLY | libc.O_CREAT | libc.O_APPEND | libc.O_CLOEXEC,
        @as(c_uint, 0o644),
    );
    if (fd < 0) return error.AuditOpenFailed;
    return fd;
}

/// Append one structural-edit JSONL row to `fd`. Strings are JSON-escaped
/// per RFC 8259 so a pattern containing `"` or `\n` cannot break the line.
pub fn appendAuditRow(
    fd: c_int,
    ts: i64,
    root: []const u8,
    file_rel: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    count: usize,
    sha_before: []const u8,
    sha_after: []const u8,
) Error!void {
    // 8 KB scratch is enough for any single row given the upstream
    // pattern/replacement caps (M-x line length is 256, audit-log writer
    // truncates).
    var buf: [8192]u8 = undefined;
    var w: usize = 0;

    const header = std.fmt.bufPrint(
        buf[w..],
        "{{\"ts\":{d},\"fleet\":\"zk-batch-replace\",\"root\":",
        .{ts},
    ) catch return error.NoSpaceLeft;
    w += header.len;
    w += try writeJsonString(buf[w..], root);

    const a = std.fmt.bufPrint(buf[w..], ",\"file_rel\":", .{}) catch return error.NoSpaceLeft;
    w += a.len;
    w += try writeJsonString(buf[w..], file_rel);

    const b = std.fmt.bufPrint(buf[w..], ",\"pattern\":", .{}) catch return error.NoSpaceLeft;
    w += b.len;
    w += try writeJsonString(buf[w..], pattern);

    const c = std.fmt.bufPrint(buf[w..], ",\"replacement\":", .{}) catch return error.NoSpaceLeft;
    w += c.len;
    w += try writeJsonString(buf[w..], replacement);

    const d = std.fmt.bufPrint(
        buf[w..],
        ",\"count\":{d},\"sha_before\":\"{s}\",\"sha_after\":\"{s}\"}}\n",
        .{ count, sha_before, sha_after },
    ) catch return error.NoSpaceLeft;
    w += d.len;

    const rc = libc.write(fd, &buf[0], w);
    if (rc < 0) return error.AuditWriteFailed;
}

/// Resolve the audit-log path. Override > $HOME-based default
/// (~/.mast-zk-audit.jsonl) > "/tmp/.mast-zk-audit.jsonl".
pub fn resolveAuditPath(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
) Error![]u8 {
    if (override) |p| {
        return allocator.dupe(u8, p) catch return error.OutOfMemory;
    }
    const env_home_c = libc.getenv("HOME");
    if (env_home_c != null) {
        const home = std.mem.span(@as([*:0]const u8, @ptrCast(env_home_c.?)));
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.mast-zk-audit.jsonl", .{home}) catch return error.NoSpaceLeft;
        return allocator.dupe(u8, path) catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, "/tmp/.mast-zk-audit.jsonl") catch return error.OutOfMemory;
}

fn unixSec() i64 {
    return @intCast(libc.time(null));
}

/// One-shot helper: batchReplace + open audit + emit rows + close.
/// Returns the rows so callers (Janet wrapper, REPL, TUI) can echo a
/// summary.
pub fn batchReplaceAndAudit(
    allocator: std.mem.Allocator,
    root: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    audit_path_override: ?[]const u8,
) Error!ReplaceResult {
    var result = try batchReplace(allocator, root, pattern, replacement);
    errdefer result.deinit();

    const audit_path = try resolveAuditPath(allocator, audit_path_override);
    defer allocator.free(audit_path);
    const fd = try openAuditLog(allocator, audit_path);
    defer _ = libc.close(fd);

    const ts = unixSec();
    for (result.rows) |row| {
        try appendAuditRow(
            fd,
            ts,
            root,
            row.file_rel,
            pattern,
            replacement,
            row.count,
            row.sha_before[0..],
            row.sha_after[0..],
        );
    }
    return result;
}

// ─── JSON-escape (matches audit.zig posture) ────────────────────────────

fn writeJsonString(out: []u8, s: []const u8) Error!usize {
    if (out.len < 2) return error.NoSpaceLeft;
    var w: usize = 0;
    out[w] = '"';
    w += 1;
    for (s) |c| {
        switch (c) {
            '"' => {
                if (w + 2 > out.len) return error.NoSpaceLeft;
                out[w] = '\\';
                out[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                if (w + 2 > out.len) return error.NoSpaceLeft;
                out[w] = '\\';
                out[w + 1] = '\\';
                w += 2;
            },
            '\n' => {
                if (w + 2 > out.len) return error.NoSpaceLeft;
                out[w] = '\\';
                out[w + 1] = 'n';
                w += 2;
            },
            '\r' => {
                if (w + 2 > out.len) return error.NoSpaceLeft;
                out[w] = '\\';
                out[w + 1] = 'r';
                w += 2;
            },
            '\t' => {
                if (w + 2 > out.len) return error.NoSpaceLeft;
                out[w] = '\\';
                out[w + 1] = 't';
                w += 2;
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                if (w + 6 > out.len) return error.NoSpaceLeft;
                const hex = "0123456789abcdef";
                out[w] = '\\';
                out[w + 1] = 'u';
                out[w + 2] = '0';
                out[w + 3] = '0';
                out[w + 4] = hex[c >> 4];
                out[w + 5] = hex[c & 0x0f];
                w += 6;
            },
            else => {
                if (w + 1 > out.len) return error.NoSpaceLeft;
                out[w] = c;
                w += 1;
            },
        }
    }
    if (w + 1 > out.len) return error.NoSpaceLeft;
    out[w] = '"';
    w += 1;
    return w;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const pid = libc.getpid();
    const ts = unixSec();
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mast-zk-test-{d}-{d}-{s}", .{ pid, ts, suffix });
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);
    _ = libc.mkdir(@ptrCast(c_path.ptr), @as(c_uint, 0o755));
    return allocator.dupe(u8, path);
}

fn mkdirIn(allocator: std.mem.Allocator, root: []const u8, sub: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, sub });
    const c = try allocator.dupeZ(u8, p);
    defer allocator.free(c);
    _ = libc.mkdir(@ptrCast(c.ptr), @as(c_uint, 0o755));
}

fn writeFile(allocator: std.mem.Allocator, root: []const u8, rel: []const u8, body: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel });
    const c = try allocator.dupeZ(u8, p);
    defer allocator.free(c);
    const fd = libc.open(@ptrCast(c.ptr), libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = libc.close(fd);
    var written: usize = 0;
    while (written < body.len) {
        const rc = libc.write(fd, body.ptr + written, body.len - written);
        if (rc <= 0) return error.WriteFailed;
        written += @intCast(rc);
    }
}

fn rmTree(allocator: std.mem.Allocator, root: []const u8) void {
    // Cheap recursive rm via shell-out (test-only helper; libc rmdir/unlink
    // walk would balloon the test boilerplate without buying coverage).
    var buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "rm -rf '{s}' 2>/dev/null\x00", .{root}) catch return;
    _ = libc.system(@ptrCast(cmd.ptr));
    _ = allocator;
}

fn readFileBytes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const c = try allocator.dupeZ(u8, path);
    defer allocator.free(c);
    const fd = libc.open(@ptrCast(c.ptr), libc.O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = libc.close(fd);
    var st: libc.struct_stat = undefined;
    if (libc.fstat(fd, &st) != 0) return error.StatFailed;
    const size: usize = @intCast(st.st_size);
    const buf = try allocator.alloc(u8, size);
    var read_total: usize = 0;
    while (read_total < size) {
        const rc = libc.read(fd, buf.ptr + read_total, size - read_total);
        if (rc <= 0) break;
        read_total += @intCast(rc);
    }
    return buf;
}

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

test "zk resolveSlug: known slug under known category resolves" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "resolve-ok");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "people");
    try writeFile(a, root, "people/mansa-musa.md", "# Mansa Musa\n");

    const path = try resolveSlug(a, root, "mansa-musa");
    defer a.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "/people/mansa-musa.md"));
}

test "zk resolveSlug: missing slug returns error.SlugNotFound" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "resolve-miss");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "concepts");
    try writeFile(a, root, "concepts/some-other-note.md", "# x\n");

    const err = resolveSlug(a, root, "no-such-slug");
    try testing.expectError(error.SlugNotFound, err);
}

test "zk batchReplace: zero-match scan emits a count=0 audit row with sha_before == sha_after" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "batch-nomatch");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "people");
    try writeFile(a, root, "people/x.md", "hello\n");

    var result = try batchReplace(a, root, "nope-pattern", "rep");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expectEqual(@as(usize, 0), result.rows[0].count);
    // count==0 means file untouched; sha_before == sha_after by contract.
    try testing.expectEqualSlices(u8, result.rows[0].sha_before[0..], result.rows[0].sha_after[0..]);
}

test "zk batchReplace: multi-file walk visits every .md and replaces in each" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "batch-multi");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "people");
    try mkdirIn(a, root, "concepts");
    try writeFile(a, root, "people/a.md", "foo bar foo\n");
    try writeFile(a, root, "people/b.md", "foo only here\n");
    try writeFile(a, root, "concepts/c.md", "no match in this one\n");
    // Sanity: non-.md file must NOT be touched.
    try writeFile(a, root, "concepts/skip.txt", "foo foo foo\n");

    var result = try batchReplace(a, root, "foo", "BAZ");
    defer result.deinit();

    // 3 markdown files walked (skip.txt excluded).
    try testing.expectEqual(@as(usize, 3), result.rows.len);

    var total: usize = 0;
    for (result.rows) |r| total += r.count;
    // a.md: 2 hits, b.md: 1 hit, c.md: 0 hits. Total 3.
    try testing.expectEqual(@as(usize, 3), total);

    // Non-.md untouched on disk.
    const skip_path = try std.fmt.allocPrint(a, "{s}/concepts/skip.txt", .{root});
    defer a.free(skip_path);
    const skip_bytes = try readFileBytes(a, skip_path);
    defer a.free(skip_bytes);
    try testing.expectEqualStrings("foo foo foo\n", skip_bytes);
}

test "zk batchReplace: sha_before differs from sha_after for every count>0 row (falsifier guard)" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "batch-sha");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "people");
    try writeFile(a, root, "people/x.md", "old marker here\n");
    try writeFile(a, root, "people/y.md", "no marker present\n");
    try writeFile(a, root, "people/z.md", "marker marker\n");

    var result = try batchReplace(a, root, "marker", "TOKEN");
    defer result.deinit();

    var saw_positive = false;
    for (result.rows) |r| {
        if (r.count > 0) {
            saw_positive = true;
            try testing.expect(!std.mem.eql(u8, r.sha_before[0..], r.sha_after[0..]));
        } else {
            try testing.expectEqualSlices(u8, r.sha_before[0..], r.sha_after[0..]);
        }
    }
    try testing.expect(saw_positive);
}

test "zk audit-path override: rows land in the operator-supplied file" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "batch-audit");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "concepts");
    try writeFile(a, root, "concepts/x.md", "the cat sat\nthe cat napped\n");

    var override_buf: [512]u8 = undefined;
    const audit_path = try std.fmt.bufPrint(&override_buf, "{s}/audit.jsonl", .{root});

    var result = try batchReplaceAndAudit(a, root, "cat", "dog", audit_path);
    defer result.deinit();
    try testing.expect(result.rows.len > 0);

    const log_bytes = try readFileBytes(a, audit_path);
    defer a.free(log_bytes);
    // One JSONL line per file walked (here: 1 file, 1 line).
    try testing.expectEqual(@as(usize, 1), countLines(log_bytes));
    // Mandatory shape: fleet field and count field present.
    try testing.expect(std.mem.indexOf(u8, log_bytes, "\"fleet\":\"zk-batch-replace\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "\"sha_before\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "\"sha_after\"") != null);
}

test "zk batchReplace: nested subdirs are walked (recursive)" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "batch-nested");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "arc");
    try mkdirIn(a, root, "arc/subdir");
    try writeFile(a, root, "arc/top.md", "FOO\n");
    try writeFile(a, root, "arc/subdir/deep.md", "FOO FOO\n");

    var result = try batchReplace(a, root, "FOO", "BAR");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.rows.len);
    var total: usize = 0;
    for (result.rows) |r| total += r.count;
    try testing.expectEqual(@as(usize, 3), total);
}

test "zk resolveSlug: explicit category prefix honors the path" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "resolve-explicit");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "events");
    try mkdirIn(a, root, "people");
    // Two notes with the same base slug under different categories.
    try writeFile(a, root, "events/joint-slug.md", "event\n");
    try writeFile(a, root, "people/joint-slug.md", "person\n");

    // Explicit "events/joint-slug" must resolve to the event copy.
    const event_path = try resolveSlug(a, root, "events/joint-slug");
    defer a.free(event_path);
    try testing.expect(std.mem.endsWith(u8, event_path, "/events/joint-slug.md"));
}

test "zk batchReplace: empty pattern returns error.EmptyPattern" {
    const a = testing.allocator;
    const root = try mkTempDir(a, "batch-empty");
    defer a.free(root);
    defer rmTree(a, root);
    try mkdirIn(a, root, "people");
    try writeFile(a, root, "people/x.md", "anything\n");

    const err = batchReplace(a, root, "", "X");
    try testing.expectError(error.EmptyPattern, err);
}
