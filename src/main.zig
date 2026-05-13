// mast — single-binary editor kernel. v0.1.0 commit-zero.
//
// Architecture: buffer-as-protocol + Janet-extensible M-x runner + session
// audit log. See README.md and docs/SPEC.md.
//
// v0.1 scope:
//   - Open a file as a `:file` buffer (positional arg)
//   - Interactive M-x dispatcher with positional args ($1, $2, ...)
//   - Built-in commands: pid, help, display, stax-search, stax-dashboard, stax-hunger
//   - Unrecognised verbs fall through to raw Janet eval
//   - Every session writes an append-only audit log
//
// Build:  zig build -Doptimize=ReleaseSmall
// Run:    ./zig-out/bin/mast [file]

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const SessionAudit = @import("audit.zig").SessionAudit;

const janet = @cImport({
    @cInclude("janet.h");
});

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

const Allocator = std.mem.Allocator;
const print = std.debug.print;

// ─── Globals shared with Janet C-callbacks ─────────────────────────────
//
// Janet's C ABI takes plain function pointers (no userdata). We expose
// editor state via a global so the bound functions can reach it. The
// global is set once in main() and never mutated after init.

var g_current_buffer: ?*Buffer = null;
var g_audit: ?*SessionAudit = null;

// ─── Janet C-functions ──────────────────────────────────────────────────

fn cmd_stax_pid(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    const pid: i32 = @intCast(libc.getpid());
    return janet.janet_wrap_integer(pid);
}

fn cmd_stax_bash(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (argc != 1) {
        janet.janet_panicf("stax-bash: expected 1 argument, got %d", argc);
    }
    const arg = argv[0];
    const s_ptr = janet.janet_unwrap_string(arg);
    const c_str = @as([*c]const u8, @ptrCast(s_ptr));
    const rc: i32 = @intCast(libc.system(c_str));
    return janet.janet_wrap_integer(rc);
}

/// `(buffer-name)` — current buffer name, or nil if no buffer is open.
fn cmd_buffer_name(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    if (g_current_buffer) |b| {
        return janet.janet_wrap_string(janet.janet_string(b.name.ptr, @intCast(b.name.len)));
    }
    return janet.janet_wrap_nil();
}

/// `(buffer-size)` — byte length of current buffer.
fn cmd_buffer_size(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    if (g_current_buffer) |b| return janet.janet_wrap_integer(@intCast(b.contents.len));
    return janet.janet_wrap_integer(0);
}

// ─── Built-in M-x commands ─────────────────────────────────────────────

const BuiltinCmd = struct {
    name: []const u8,
    janet_expr: []const u8,
    description: []const u8,
};

const BUILTINS = [_]BuiltinCmd{
    .{ .name = "pid", .janet_expr = "(stax-pid)", .description = "Show host PID" },
    .{ .name = "help", .janet_expr = "MAST_HELP_SENTINEL", .description = "Print this list" },
    .{ .name = "display", .janet_expr = "MAST_DISPLAY_SENTINEL", .description = "Render the current buffer" },
    .{ .name = "buffer-name", .janet_expr = "(buffer-name)", .description = "Name of current buffer" },
    .{ .name = "buffer-size", .janet_expr = "(buffer-size)", .description = "Byte size of current buffer" },
    .{ .name = "stax-search", .janet_expr = "(stax-bash (string \"stax-search \" $1))", .description = "Run stax-search Q" },
    .{ .name = "stax-dashboard", .janet_expr = "(stax-bash \"stax-dashboard --top 8\")", .description = "Show fleet dashboard" },
    .{ .name = "stax-hunger", .janet_expr = "(stax-bash \"stax-hunger --human\")", .description = "Show lane lifecycle classification" },
};

const HELP_TEXT =
    \\Built-in M-x commands:
    \\  M-x pid                 Show host PID
    \\  M-x help                This help
    \\  M-x display             Render the current buffer
    \\  M-x buffer-name         Name of the current buffer
    \\  M-x buffer-size         Byte size of the current buffer
    \\  M-x stax-search Q       Run stax-search Q (delegates to local CLI)
    \\  M-x stax-dashboard      Show stax fleet dashboard
    \\  M-x stax-hunger         Show per-lane lifecycle classification
    \\  M-x exit                Quit
    \\  (anything else)         Evaluated as raw Janet
    \\
;

// ─── Argument substitution ─────────────────────────────────────────────

fn substitute_args(allocator: Allocator, expr: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (c == '$' and i + 1 < expr.len) {
            const nxt = expr[i + 1];
            if (nxt >= '1' and nxt <= '9') {
                const idx: usize = @intCast(nxt - '1');
                if (idx < args.len) {
                    try out.append(allocator, '"');
                    for (args[idx]) |a| try out.append(allocator, a);
                    try out.append(allocator, '"');
                } else {
                    try out.appendSlice(allocator, "nil");
                }
                i += 2;
                continue;
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// ─── M-x line parser ───────────────────────────────────────────────────

const ParsedMx = struct {
    verb: []const u8,
    args: [][]const u8,
};

fn parse_mx_line(allocator: Allocator, line: []const u8) !?ParsedMx {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    var rest: []const u8 = trimmed;
    if (std.mem.startsWith(u8, trimmed, "M-x ")) rest = trimmed[4..];
    if (std.mem.startsWith(u8, rest, "m-x ")) rest = rest[4..];
    var iter = std.mem.tokenizeAny(u8, rest, " \t");
    const verb = iter.next() orelse return null;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (iter.next()) |a| try args.append(allocator, a);
    return ParsedMx{
        .verb = verb,
        .args = try args.toOwnedSlice(allocator),
    };
}

// ─── REPL loop ─────────────────────────────────────────────────────────

fn run_repl(allocator: Allocator, env: *janet.JanetTable, audit: *SessionAudit) !void {
    var line_buf: [4096]u8 = undefined;

    print("mast v0.1.0 — single-binary editor kernel\n", .{});
    print("Type 'M-x help' or just 'help'. Ctrl-D to quit.\n\n", .{});

    var leftover_buf: [4096]u8 = undefined;
    var leftover_len: usize = 0;

    while (true) {
        print("M-x ", .{});

        const line_end: ?usize = blk: {
            if (leftover_len > 0) {
                if (std.mem.indexOfScalar(u8, leftover_buf[0..leftover_len], '\n')) |i| break :blk i;
            }
            const space = leftover_buf.len - leftover_len;
            if (space == 0) {
                leftover_len = 0;
                break :blk null;
            }
            const rc = libc.read(0, &leftover_buf[leftover_len], space);
            if (rc <= 0) {
                print("\n(EOF)\n", .{});
                return;
            }
            leftover_len += @intCast(rc);
            if (std.mem.indexOfScalar(u8, leftover_buf[0..leftover_len], '\n')) |i| break :blk i;
            break :blk null;
        };
        if (line_end == null) continue;

        const idx = line_end.?;
        const len_local = if (idx == 0) 0 else idx;
        std.mem.copyForwards(u8, line_buf[0..len_local], leftover_buf[0..len_local]);
        const consumed = idx + 1;
        std.mem.copyForwards(u8, leftover_buf[0 .. leftover_len - consumed], leftover_buf[consumed..leftover_len]);
        leftover_len -= consumed;
        const line = line_buf[0..len_local];

        const parsed = (try parse_mx_line(allocator, line)) orelse continue;
        defer allocator.free(parsed.args);

        try audit.write("mx-input", .{ .verb = parsed.verb });

        if (std.mem.eql(u8, parsed.verb, "exit") or std.mem.eql(u8, parsed.verb, "quit")) {
            print("(exiting)\n", .{});
            break;
        }

        var found: ?BuiltinCmd = null;
        for (BUILTINS) |b| {
            if (std.mem.eql(u8, b.name, parsed.verb)) {
                found = b;
                break;
            }
        }

        // Sentinel-handled commands (don't go through Janet)
        if (found) |b| {
            if (std.mem.eql(u8, b.janet_expr, "MAST_HELP_SENTINEL")) {
                print("{s}\n", .{HELP_TEXT});
                continue;
            }
            if (std.mem.eql(u8, b.janet_expr, "MAST_DISPLAY_SENTINEL")) {
                if (g_current_buffer) |buf| {
                    // Render straight to stderr via std.debug.print so we don't
                    // depend on a particular std.io writer shape (which has
                    // churned across Zig 0.13–0.16). v0.2 will route through a
                    // proper TUI surface.
                    var line_no: usize = 0;
                    var line_start: usize = 0;
                    print("── [:{s}] {s} — {d} lines, {d} bytes ──\n", .{
                        @tagName(buf.kind), buf.name, buf.lineCount(), buf.contents.len,
                    });
                    var i: usize = 0;
                    const MAX_LINES: usize = 50;
                    while (i < buf.contents.len and line_no < MAX_LINES) : (i += 1) {
                        if (buf.contents[i] == '\n') {
                            line_no += 1;
                            print("{d:>4}  {s}\n", .{ line_no, buf.contents[line_start..i] });
                            line_start = i + 1;
                        }
                    }
                    if (line_no < MAX_LINES and line_start < buf.contents.len) {
                        line_no += 1;
                        print("{d:>4}  {s}\n", .{ line_no, buf.contents[line_start..] });
                    }
                    if (line_no < buf.lineCount()) {
                        print("... ({d} more lines)\n", .{buf.lineCount() - line_no});
                    }
                    print("\n", .{});
                } else {
                    print("  (no buffer open)\n\n", .{});
                }
                continue;
            }
        }

        const janet_src = if (found) |b|
            try substitute_args(allocator, b.janet_expr, parsed.args)
        else blk: {
            // Fall through to raw Janet eval: strip an "M-x " prefix if
            // present so users can type `M-x (+ 1 2)` AND `(+ 1 2)`.
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            const stripped = if (std.mem.startsWith(u8, trimmed, "M-x "))
                trimmed[4..]
            else if (std.mem.startsWith(u8, trimmed, "m-x "))
                trimmed[4..]
            else
                trimmed;
            break :blk try allocator.dupe(u8, stripped);
        };
        defer allocator.free(janet_src);

        const c_src = try allocator.dupeZ(u8, janet_src);
        defer allocator.free(c_src);

        var out: janet.Janet = undefined;
        const status = janet.janet_dostring(env, c_src.ptr, "mx", &out);
        if (status != 0) {
            print("  (error: status={d})\n\n", .{status});
            try audit.write("mx-error", .{ .verb = parsed.verb, .status = status });
            continue;
        }

        const rendered = janet.janet_to_string(out);
        const rendered_ptr = @as([*c]const u8, @ptrCast(rendered));
        const len = std.mem.len(rendered_ptr);
        const slice = rendered_ptr[0..len];
        print("  → ", .{});
        if (slice.len >= 2 and slice[0] == '"' and slice[slice.len - 1] == '"') {
            print("{s}\n\n", .{slice[1 .. slice.len - 1]});
        } else {
            print("{s}\n\n", .{slice});
        }
    }
}

// ─── main ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;

    var args_iter = init.args.iterate();
    _ = args_iter.next(); // skip argv[0]

    // First positional arg: optional file path to open as :file buffer
    var initial_file: ?[]const u8 = null;
    if (args_iter.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            print("usage: mast [file]\n\n", .{});
            print("{s}", .{HELP_TEXT});
            return;
        }
        if (std.mem.eql(u8, a, "--version")) {
            print("mast v0.1.0\n", .{});
            return;
        }
        initial_file = try allocator.dupe(u8, a);
    }
    defer if (initial_file) |p| allocator.free(p);

    if (janet.janet_init() != 0) {
        print("FAIL janet_init\n", .{});
        std.process.exit(1);
    }
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null);

    janet.janet_def(env, "stax-pid", janet.janet_wrap_cfunction(cmd_stax_pid), "Host PID.");
    janet.janet_def(env, "stax-bash", janet.janet_wrap_cfunction(cmd_stax_bash), "Run a bash command; return exit status.");
    janet.janet_def(env, "buffer-name", janet.janet_wrap_cfunction(cmd_buffer_name), "Current buffer name, or nil.");
    janet.janet_def(env, "buffer-size", janet.janet_wrap_cfunction(cmd_buffer_size), "Current buffer byte size.");

    // Session audit log
    var audit = try SessionAudit.init(allocator, @intCast(libc.getpid()));
    defer audit.deinit();
    g_audit = &audit;

    // Open initial file as :file buffer if provided
    var buffer_storage: Buffer = undefined;
    if (initial_file) |path| {
        buffer_storage = Buffer.fromFile(allocator, path) catch |e| {
            print("could not open {s}: {}\n", .{ path, e });
            std.process.exit(2);
        };
        g_current_buffer = &buffer_storage;
        try audit.write("buffer-open", .{ .path = path, .kind = "file" });
    }
    defer if (g_current_buffer) |b| b.deinit();

    try run_repl(allocator, env.?, &audit);
}
