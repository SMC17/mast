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
        const fd = libc.open(c_path, libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC, @as(c_uint, 0o644));
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
        var buf: [4096]u8 = undefined;
        var written: usize = 0;
        const header = try std.fmt.bufPrint(buf[written..], "{{\"ts\":{d},\"sid\":\"{s}\",\"event\":\"{s}\"", .{
            unixSec(),
            self.session_id,
            event,
        });
        written += header.len;

        const T = @TypeOf(payload);
        const ti = @typeInfo(T);
        if (ti == .@"struct" and ti.@"struct".fields.len > 0) {
            const sep = try std.fmt.bufPrint(buf[written..], ",\"payload\":{{", .{});
            written += sep.len;
            inline for (ti.@"struct".fields, 0..) |field, i| {
                if (i > 0) {
                    buf[written] = ',';
                    written += 1;
                }
                const field_val = @field(payload, field.name);
                const ftype = @TypeOf(field_val);
                const ftype_info = @typeInfo(ftype);
                const rendered = switch (ftype_info) {
                    .int, .comptime_int => try std.fmt.bufPrint(buf[written..], "\"{s}\":{d}", .{ field.name, field_val }),
                    .pointer => |p| blk: {
                        if (p.size == .slice and p.child == u8) {
                            break :blk try std.fmt.bufPrint(buf[written..], "\"{s}\":\"{s}\"", .{ field.name, field_val });
                        }
                        // Pointer-to-array of u8 (string literals like "file")
                        if (p.size == .one) {
                            const child_info = @typeInfo(p.child);
                            if (child_info == .array and child_info.array.child == u8) {
                                const slice: []const u8 = field_val[0..];
                                break :blk try std.fmt.bufPrint(buf[written..], "\"{s}\":\"{s}\"", .{ field.name, slice });
                            }
                        }
                        break :blk try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name});
                    },
                    .array => |arr| if (arr.child == u8)
                        try std.fmt.bufPrint(buf[written..], "\"{s}\":\"{s}\"", .{ field.name, field_val[0..] })
                    else
                        try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name}),
                    else => try std.fmt.bufPrint(buf[written..], "\"{s}\":null", .{field.name}),
                };
                written += rendered.len;
            }
            buf[written] = '}';
            written += 1;
        }
        buf[written] = '}';
        written += 1;
        buf[written] = '\n';
        written += 1;

        const rc = libc.write(self.fd, &buf[0], written);
        if (rc < 0) return error.WriteFailed;
    }
};

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
