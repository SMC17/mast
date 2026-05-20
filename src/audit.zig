// audit.zig — session audit log writer.
//
// Every mast session emits one append-only JSONL file at
//   $XDG_STATE_HOME/stax/editor-sessions/<session-id>.jsonl
// (default ~/.local/state/stax/editor-sessions/<session-id>.jsonl)
//
// Uses libc directly (open/write/close + makedir via shell-out) for stable
// behavior across Zig 0.13–0.16 — std.fs/std.Io is in heavy churn.

const std = @import("std");

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("time.h");
});

fn unixSec() i64 {
    return @intCast(libc.time(null));
}

pub const SessionAudit = struct {
    fd: c_int = -1,
    session_id: [16]u8 = [_]u8{0} ** 16,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pid: i32) !SessionAudit {
        const ms = unixSec();
        var seed_buf: [64]u8 = undefined;
        const seed = try std.fmt.bufPrint(&seed_buf, "{d}:{d}", .{ pid, ms });
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(seed, &hash, .{});
        var sid: [16]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (hash[0..8], 0..) |byte, i| {
            sid[i * 2] = hex_chars[byte >> 4];
            sid[i * 2 + 1] = hex_chars[byte & 0xf];
        }

        const env_state_c = libc.getenv("XDG_STATE_HOME");
        const env_home_c = libc.getenv("HOME");
        var dir_path_buf: [512]u8 = undefined;
        const dir_path = if (env_state_c != null) blk: {
            const s = std.mem.span(@as([*:0]const u8, @ptrCast(env_state_c.?)));
            break :blk try std.fmt.bufPrint(&dir_path_buf, "{s}/stax/editor-sessions", .{s});
        } else blk: {
            const home = if (env_home_c != null)
                std.mem.span(@as([*:0]const u8, @ptrCast(env_home_c.?)))
            else
                "/tmp";
            break :blk try std.fmt.bufPrint(&dir_path_buf, "{s}/.local/state/stax/editor-sessions", .{home});
        };

        // mkdir -p via libc, walking the path
        try mkdirP(allocator, dir_path);

        var file_path_buf: [600]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}.jsonl\x00", .{ dir_path, sid });

        const c_path: [*c]const u8 = @ptrCast(file_path.ptr);
        // O_CLOEXEC closes round-2 adversarial finding #2: without it,
        // spawned children (agent/spawn, agent/run, gated stax-bash)
        // inherit a writable fd to the audit log and can bypass
        // writeJsonString by writing directly via /proc/self/fd.
        const fd = libc.open(c_path, libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return error.OpenFailed;

        var sa = SessionAudit{
            .fd = fd,
            .session_id = sid,
            .allocator = allocator,
        };
        try sa.write("session-start", .{ .pid = pid });
        return sa;
    }

    pub fn deinit(self: *SessionAudit) void {
        if (self.fd >= 0) {
            self.write("session-end", .{}) catch {};
            _ = libc.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn write(self: *SessionAudit, event: []const u8, payload: anytype) !void {
        if (self.fd < 0) return;
        // Buffer sized to comfortably hold any single event line.  Every
        // append below goes through bounded helpers (`appendByte`,
        // `writeJsonString`) so a long user-controlled field (eg. a
        // 4000-char save-as path) returns NoSpaceLeft cleanly instead of
        // overflowing the stack array.  Closes round-2 adversarial
        // finding #4 (unbounded `buf[written] = X` near the 4096 ceiling).
        var buf: [4096]u8 = undefined;
        var written: usize = 0;
        const header = try std.fmt.bufPrint(buf[written..], "{{\"ts\":{d},\"sid\":\"{s}\",\"event\":", .{
            unixSec(),
            self.session_id,
        });
        written += header.len;
        // Event name flows from caller code (always trusted string literals
        // today), but escape it anyway for defense in depth so a hypothetical
        // future caller passing user data can't break the JSON line.
        written += try writeJsonString(buf[written..], event);

        const T = @TypeOf(payload);
        const ti = @typeInfo(T);
        if (ti == .@"struct" and ti.@"struct".fields.len > 0) {
            const sep = try std.fmt.bufPrint(buf[written..], ",\"payload\":{{", .{});
            written += sep.len;
            inline for (ti.@"struct".fields, 0..) |field, i| {
                if (i > 0) {
                    try appendByte(&buf, &written, ',');
                }
                const field_val = @field(payload, field.name);
                const ftype = @TypeOf(field_val);
                const ftype_info = @typeInfo(ftype);
                switch (ftype_info) {
                    .int, .comptime_int => {
                        const r = try std.fmt.bufPrint(buf[written..], "\"{s}\":{d}", .{ field.name, field_val });
                        written += r.len;
                    },
                    .bool => {
                        const r = try std.fmt.bufPrint(buf[written..], "\"{s}\":{s}", .{ field.name, if (field_val) "true" else "false" });
                        written += r.len;
                    },
                    .pointer => |p| {
                        if (p.size == .slice and p.child == u8) {
                            // Slice-of-u8 — user-controllable. Escape it.
                            written += try writeKvString(buf[written..], field.name, field_val);
                        } else if (p.size == .one) {
                            const child_info = @typeInfo(p.child);
                            if (child_info == .array and child_info.array.child == u8) {
                                const slice: []const u8 = field_val[0..];
                                written += try writeKvString(buf[written..], field.name, slice);
                            } else {
                                const r = try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name});
                                written += r.len;
                            }
                        } else {
                            const r = try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name});
                            written += r.len;
                        }
                    },
                    .array => |arr| if (arr.child == u8) {
                        written += try writeKvString(buf[written..], field.name, field_val[0..]);
                    } else {
                        const r = try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name});
                        written += r.len;
                    },
                    else => {
                        const r = try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name});
                        written += r.len;
                    },
                }
            }
            try appendByte(&buf, &written, '}');
        }
        try appendByte(&buf, &written, '}');
        try appendByte(&buf, &written, '\n');

        const rc = libc.write(self.fd, &buf[0], written);
        if (rc < 0) return error.WriteFailed;
    }
};

/// Bounded single-byte append. Returns error.NoSpaceLeft if the buffer
/// would overflow. Closes round-2 adversarial finding #4 — the bare
/// `buf[written] = X` writes had no bounds check and could touch one
/// byte past the 4096-byte stack array on long user input.
fn appendByte(buf: *[4096]u8, written: *usize, b: u8) !void {
    if (written.* >= buf.len) return error.NoSpaceLeft;
    buf[written.*] = b;
    written.* += 1;
}

// JSON-escape a string into `out`, prefixed with the opening `"` and
// suffixed with the closing `"`. Closes adversarial-review finding #3:
// user-controllable strings (M-x verbs, save-as paths, buffer names)
// would otherwise flow into the JSONL log unescaped, letting a hostile
// input forge sandbox-grant or session-end events by injecting `","`
// followed by attacker-chosen JSON. Now: `"`, `\`, and bytes < 0x20
// are escaped per RFC 8259; the resulting line is always one valid
// JSON object.
fn writeJsonString(out: []u8, s: []const u8) !usize {
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
                // Other control chars: \u00XX
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

/// Helper: emit `"name":"escaped(value)"` into `out`. Returns bytes written.
fn writeKvString(out: []u8, name: []const u8, value: []const u8) !usize {
    var w: usize = 0;
    // Field name is always a Zig comptime identifier — trusted, no escape.
    const prefix = try std.fmt.bufPrint(out[w..], "\"{s}\":", .{name});
    w += prefix.len;
    w += try writeJsonString(out[w..], value);
    return w;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "writeJsonString: trivial ASCII round-trips" {
    var buf: [64]u8 = undefined;
    const n = try writeJsonString(&buf, "hello");
    try std.testing.expectEqualStrings("\"hello\"", buf[0..n]);
}

test "writeJsonString: escapes quote backslash and newline (audit-injection guard)" {
    var buf: [64]u8 = undefined;
    const n = try writeJsonString(&buf, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\"", buf[0..n]);
}

test "writeJsonString: control bytes become \\u00XX (defense vs injection)" {
    var buf: [64]u8 = undefined;
    var input: [3]u8 = .{ 'x', 0x01, 'y' };
    const n = try writeJsonString(&buf, &input);
    try std.testing.expectEqualStrings("\"x\\u0001y\"", buf[0..n]);
}

test "writeJsonString: adversarial-review #3 PoC is neutralized" {
    // The published PoC: M-x verb containing `","verb":"sandbox-grant","x":"`
    // would, pre-fix, flow into a JSONL line that forged a sandbox-grant
    // event. Post-fix, the quotes get escaped and the malicious payload
    // becomes literal data inside the original event's verb field.
    var buf: [256]u8 = undefined;
    const evil = "\",\"verb\":\"sandbox-grant\",\"x\":\"";
    const n = try writeJsonString(&buf, evil);
    // Every internal `"` must be escaped.
    var quote_count: usize = 0;
    for (buf[0..n]) |c| {
        if (c == '"') quote_count += 1;
    }
    // Two delimiter quotes + every original quote escaped (so its `"`
    // doesn't count as a JSON delimiter — but it IS still a literal `"`
    // byte in the output, preceded by `\`).
    // We assert the simpler invariant: the output contains at least one
    // `\"` sequence per original quote, and starts + ends with `"`.
    try std.testing.expect(buf[0] == '"');
    try std.testing.expect(buf[n - 1] == '"');
    try std.testing.expect(quote_count > 2); // delimiters + escaped originals
    // The `\\"` (backslash-then-quote) pair must appear.
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\\\"") != null);
}

fn mkdirP(allocator: std.mem.Allocator, path: []const u8) !void {
    // Recursive mkdir -p via libc.mkdir
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        const sub = path[0..i];
        const c_sub = try allocator.dupeZ(u8, sub);
        defer allocator.free(c_sub);
        const c_ptr: [*c]const u8 = @ptrCast(c_sub.ptr);
        // EEXIST is fine; other errors will surface via the final open() call.
        _ = libc.mkdir(c_ptr, @as(c_uint, 0o755));
    }
}
