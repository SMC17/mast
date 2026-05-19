// mast — single-binary editor kernel.
//
// Architecture: buffer-as-protocol + Janet-extensible M-x runner + session
// audit log. See README.md and docs/SPEC.md.
//
// Current scope:
//   - Open a file as a `:file` buffer (positional arg)
//   - Interactive M-x dispatcher with positional args ($1, $2, ...)
//   - Built-in commands: pid, help, display, buffer-name, buffer-size,
//     append, save, save-as, stax-search, stax-dashboard, stax-hunger
//   - Atomic write-back via `M-x save` / `M-x save-as` (rename-after-fsync)
//   - Unrecognised verbs fall through to raw Janet eval
//   - $XDG_CONFIG_HOME/mast/init.janet loaded on startup
//   - Every session writes an append-only audit log
//
// Build:  zig build -Doptimize=ReleaseSmall
// Run:    ./zig-out/bin/mast [file]

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const SessionAudit = @import("audit.zig").SessionAudit;
const sandbox = @import("sandbox.zig");

const janet = @import("janet_c.zig").c;

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
});

const Allocator = std.mem.Allocator;
const print = std.debug.print;

// ─── Globals shared with Janet C-callbacks ─────────────────────────────
//
// Janet's C ABI takes plain function pointers (no userdata). We expose
// editor state via a global so the bound functions can reach it.
//
// Multi-buffer state (added 2026-05-19): `g_buffers` is the live ring,
// `g_current_index` is the index of the buffer that the legacy
// `(buffer-name)` / `(buffer-size)` / `M-x display` operations target.
// All single-buffer code paths now delegate to `currentBuffer()` so the
// "no buffer open" semantics are uniform across single and multi cases.
// A freshly-launched mast with no positional file arg starts with an
// empty ring; the first `M-x save-as` / `M-x new-buffer` populates it.

var g_buffers: std.ArrayList(Buffer) = .empty;
var g_current_index: usize = 0;
var g_audit: ?*SessionAudit = null;

fn currentBuffer() ?*Buffer {
    if (g_buffers.items.len == 0) return null;
    if (g_current_index >= g_buffers.items.len) return null;
    return &g_buffers.items[g_current_index];
}

/// Add a Buffer to the ring and switch focus to it. Returns its index.
fn addBuffer(allocator: Allocator, buf: Buffer) !usize {
    try g_buffers.append(allocator, buf);
    g_current_index = g_buffers.items.len - 1;
    return g_current_index;
}

/// Switch focus to the buffer at `idx`. Returns false if out of range.
fn switchBuffer(idx: usize) bool {
    if (idx >= g_buffers.items.len) return false;
    g_current_index = idx;
    return true;
}

/// Cycle focus forward. No-op on empty ring. Returns new index (or 0).
fn nextBuffer() usize {
    if (g_buffers.items.len == 0) return 0;
    g_current_index = (g_current_index + 1) % g_buffers.items.len;
    return g_current_index;
}

/// Cycle focus backward. No-op on empty ring. Returns new index (or 0).
fn prevBuffer() usize {
    if (g_buffers.items.len == 0) return 0;
    g_current_index = if (g_current_index == 0) g_buffers.items.len - 1 else g_current_index - 1;
    return g_current_index;
}

// ─── Sandbox strict mode ────────────────────────────────────────────────
//
// `MAST_SANDBOX_STRICT` toggles whether the host applies its v1 default
// policy (auto-grant `exec` so first-party verbs work out of the box) or
// runs the production binary with the same default-deny posture the unit
// tests prove on a fresh VM. When strict, NO capabilities are granted at
// startup: `M-x stax-search`, `M-x stax-dashboard`, `M-x stax-hunger`,
// `(os/shell ...)`, and any other `exec`-requiring verb will fail with
// the standard "denied — capability `exec` not granted" panic.
//
// Parser lives in sandbox.zig so the unit test can exercise it without
// dragging main.zig into a test target.

fn read_strict_env() bool {
    const raw = libc.getenv("MAST_SANDBOX_STRICT");
    if (raw == null) return false;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(raw.?)));
    return sandbox.strictModeFromEnv(s);
}

// ─── Janet C-functions ──────────────────────────────────────────────────

fn cmd_stax_pid(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    const pid: i32 = @intCast(libc.getpid());
    return janet.janet_wrap_integer(pid);
}

// NOTE: `stax-bash` is registered against `sandbox.gated_stax_bash`, which
// consults the host capability set before shelling out. The legacy
// pass-through implementation was removed in the sandbox slice — see
// docs/SANDBOX_THREAT_MODEL.md §3 (capability vocabulary, `exec`).

/// `(buffer-name)` — current buffer name, or nil if no buffer is open.
fn cmd_buffer_name(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    if (currentBuffer()) |b| {
        return janet.janet_wrap_string(janet.janet_string(b.name.ptr, @intCast(b.name.len)));
    }
    return janet.janet_wrap_nil();
}

/// `(buffer-size)` — byte length of current buffer.
fn cmd_buffer_size(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    if (currentBuffer()) |b| return janet.janet_wrap_integer(@intCast(b.contents.len));
    return janet.janet_wrap_integer(0);
}

/// `(buffer-count)` — number of buffers in the ring.
fn cmd_buffer_count(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    return janet.janet_wrap_integer(@intCast(g_buffers.items.len));
}

/// `(buffer-current-index)` — 0-based index of the focused buffer.
fn cmd_buffer_current_index(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    return janet.janet_wrap_integer(@intCast(g_current_index));
}

/// `(buffer-next)` — cycle focus forward. Returns new index, or 0 on empty.
fn cmd_buffer_next(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    return janet.janet_wrap_integer(@intCast(nextBuffer()));
}

/// `(buffer-prev)` — cycle focus backward. Returns new index, or 0 on empty.
fn cmd_buffer_prev(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    return janet.janet_wrap_integer(@intCast(prevBuffer()));
}

/// `(agent/run cmd)` — shell out, capture stdout into a NEW :agent buffer,
/// switch focus to it, return its index. Requires `exec` capability via the
/// same default-deny posture as `os/shell` / `stax-bash`. This is the v0.2
/// realization of "agent-as-buffer" — the buffer is the air-traffic-control
/// surface for each running CLI. Non-streaming for v0.2: the call blocks
/// until the child process exits, then the full stdout becomes the buffer's
/// contents. v0.3 will add the live-tail variant.
fn cmd_agent_run(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/run denied — `exec` capability not granted (default-deny)");
    }
    if (argc != 1) {
        janet.janet_panicf("agent/run: expected 1 string argument (cmd), got %d", argc);
    }
    const s_ptr = janet.janet_unwrap_string(argv[0]);
    const c_str = @as([*c]const u8, @ptrCast(s_ptr));
    const c_mode: [*c]const u8 = @ptrCast("r".ptr);

    const fp = libc.popen(c_str, c_mode);
    if (fp == null) {
        janet.janet_panicf("agent/run: popen failed");
    }

    const allocator = std.heap.c_allocator;
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = libc.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        captured.appendSlice(allocator, chunk[0..n]) catch {
            _ = libc.pclose(fp);
            janet.janet_panicf("agent/run: OOM while capturing stdout");
        };
    }
    const exit_status = libc.pclose(fp);

    // Buffer name = first 64 chars of the command, sanitized for display.
    var name_buf: [80]u8 = undefined;
    const s_len = std.mem.len(s_ptr);
    const name_len = @min(s_len, 64);
    var i: usize = 0;
    while (i < name_len) : (i += 1) {
        const ch = s_ptr[i];
        name_buf[i] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    }
    const name_slice = name_buf[0..name_len];

    const buf = Buffer.fromBytes(allocator, .agent, name_slice, captured.items) catch {
        janet.janet_panicf("agent/run: failed to create :agent buffer");
    };
    const new_idx = addBuffer(allocator, buf) catch {
        janet.janet_panicf("agent/run: failed to add buffer to ring");
    };

    if (g_audit) |a| {
        a.write("agent-run", .{
            .index = new_idx,
            .bytes = captured.items.len,
            .exit_status = exit_status,
        }) catch {};
    }

    return janet.janet_wrap_integer(@intCast(new_idx));
}

/// `(buffer-switch idx)` — focus buffer at index. Returns the new index
/// on success, or -1 if `idx` was out of range or unparseable. Accepts
/// either an integer (from direct Janet) or a string (from the M-x
/// positional-arg substitution which always quotes args).
fn cmd_buffer_switch(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (argc != 1) {
        janet.janet_panicf("buffer-switch: expected 1 argument, got %d", argc);
    }
    var idx_i32: i32 = -1;
    const t = janet.janet_type(argv[0]);
    if (t == janet.JANET_NUMBER) {
        idx_i32 = janet.janet_unwrap_integer(argv[0]);
    } else if (t == janet.JANET_STRING) {
        const s_ptr = janet.janet_unwrap_string(argv[0]);
        const len = janet.janet_string_length(s_ptr);
        if (len == 0) return janet.janet_wrap_integer(-1);
        const bytes = @as([*]const u8, @ptrCast(s_ptr))[0..@intCast(len)];
        idx_i32 = std.fmt.parseInt(i32, bytes, 10) catch return janet.janet_wrap_integer(-1);
    } else {
        return janet.janet_wrap_integer(-1);
    }
    if (idx_i32 < 0) return janet.janet_wrap_integer(-1);
    const idx: usize = @intCast(idx_i32);
    if (switchBuffer(idx)) {
        return janet.janet_wrap_integer(@intCast(g_current_index));
    }
    return janet.janet_wrap_integer(-1);
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
    .{ .name = "buffer-count", .janet_expr = "(buffer-count)", .description = "Number of buffers in the ring" },
    .{ .name = "list-buffers", .janet_expr = "MAST_LISTBUFFERS_SENTINEL", .description = "List all buffers; * marks current" },
    .{ .name = "next-buffer", .janet_expr = "(buffer-next)", .description = "Cycle focus forward" },
    .{ .name = "prev-buffer", .janet_expr = "(buffer-prev)", .description = "Cycle focus backward" },
    .{ .name = "switch-buffer", .janet_expr = "(buffer-switch $1)", .description = "Switch focus to buffer at index N" },
    .{ .name = "new-buffer", .janet_expr = "MAST_NEWBUFFER_SENTINEL", .description = "Create a new empty :agent buffer named <name>" },
    .{ .name = "agent-run", .janet_expr = "(agent/run $1)", .description = "Spawn $1 as a shell command, capture stdout to a new :agent buffer" },
    .{ .name = "append", .janet_expr = "MAST_APPEND_SENTINEL", .description = "Append text to the current buffer (marks dirty)" },
    .{ .name = "save", .janet_expr = "MAST_SAVE_SENTINEL", .description = "Save the current :file buffer atomically" },
    .{ .name = "save-as", .janet_expr = "MAST_SAVEAS_SENTINEL", .description = "Save buffer to a new path (becomes :file)" },
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
    \\  M-x buffer-count        Number of buffers in the ring
    \\  M-x list-buffers        List all buffers; * marks current
    \\  M-x next-buffer         Cycle focus forward
    \\  M-x prev-buffer         Cycle focus backward
    \\  M-x switch-buffer N     Switch focus to buffer at index N
    \\  M-x new-buffer <name>   Create a new empty :agent buffer
    \\  M-x agent-run <cmd>     Spawn <cmd>, capture stdout to a new :agent buffer
    \\  M-x append <text…>      Append <text> + newline to current buffer
    \\  M-x save                Atomically save current :file buffer
    \\  M-x save-as <path>      Save buffer to <path>; buffer becomes :file
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

    print("mast v1.2.0 — single-binary editor kernel\n", .{});
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
            if (std.mem.eql(u8, b.janet_expr, "MAST_LISTBUFFERS_SENTINEL")) {
                if (g_buffers.items.len == 0) {
                    print("  (no buffers — try `mast <file>` or `M-x new-buffer <name>`)\n\n", .{});
                    continue;
                }
                print("── buffers ({d}) ──\n", .{g_buffers.items.len});
                for (g_buffers.items, 0..) |buf, i_buf| {
                    const marker: u8 = if (i_buf == g_current_index) '*' else ' ';
                    print("  {c} [{d}] [:{s}] {s}{s} — {d} bytes\n", .{
                        marker,
                        i_buf,
                        @tagName(buf.kind),
                        buf.name,
                        if (buf.dirty) " (dirty)" else "",
                        buf.contents.len,
                    });
                }
                print("\n", .{});
                continue;
            }
            if (std.mem.eql(u8, b.janet_expr, "MAST_NEWBUFFER_SENTINEL")) {
                if (parsed.args.len == 0) {
                    print("  (usage: M-x new-buffer <name>)\n\n", .{});
                    continue;
                }
                const new_buf = Buffer.fromBytes(allocator, .agent, parsed.args[0], "") catch |e| {
                    print("  (new-buffer error: {})\n\n", .{e});
                    continue;
                };
                const new_idx = addBuffer(allocator, new_buf) catch |e| {
                    print("  (new-buffer add error: {})\n\n", .{e});
                    continue;
                };
                print("  → created buffer [{d}] :agent {s}\n\n", .{ new_idx, parsed.args[0] });
                try audit.write("buffer-create", .{ .name = parsed.args[0], .kind = "agent", .index = new_idx });
                continue;
            }
            if (std.mem.eql(u8, b.janet_expr, "MAST_DISPLAY_SENTINEL")) {
                if (currentBuffer()) |buf| {
                    // Render straight to stderr via std.debug.print so we don't
                    // depend on a particular std.io writer shape (which has
                    // churned across Zig 0.13–0.16). v0.2 will route through a
                    // proper TUI surface.
                    var line_no: usize = 0;
                    var line_start: usize = 0;
                    print("── [:{s}] {s}{s} — {d} lines, {d} bytes ──\n", .{
                        @tagName(buf.kind),
                        buf.name,
                        if (buf.dirty) " *" else "",
                        buf.lineCount(),
                        buf.contents.len,
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
            if (std.mem.eql(u8, b.janet_expr, "MAST_APPEND_SENTINEL")) {
                if (currentBuffer()) |buf| {
                    // Reassemble all positional args back into a single string
                    // separated by single spaces. The parser already split on
                    // whitespace; we want "M-x append hello world" to append
                    // "hello world\n" not append two separate lines.
                    var combined: std.ArrayList(u8) = .empty;
                    defer combined.deinit(allocator);
                    for (parsed.args, 0..) |arg, i_arg| {
                        if (i_arg > 0) try combined.append(allocator, ' ');
                        try combined.appendSlice(allocator, arg);
                    }
                    try combined.append(allocator, '\n');
                    buf.append(combined.items) catch |e| {
                        print("  (append error: {})\n\n", .{e});
                        try audit.write("mx-append-error", .{ .err = @errorName(e) });
                        continue;
                    };
                    print("  → appended {d} bytes; buffer now {d} bytes, dirty\n\n",
                          .{ combined.items.len, buf.contents.len });
                    try audit.write("buffer-append", .{ .bytes = combined.items.len });
                } else {
                    print("  (no buffer open — try `mast <file>` or `M-x save-as <path>`)\n\n", .{});
                }
                continue;
            }
            if (std.mem.eql(u8, b.janet_expr, "MAST_SAVE_SENTINEL")) {
                if (currentBuffer()) |buf| {
                    const n = buf.save() catch |e| {
                        print("  (save error: {})\n\n", .{e});
                        try audit.write("mx-save-error", .{ .err = @errorName(e), .path = buf.name });
                        continue;
                    };
                    print("  → wrote {d} bytes to {s}\n\n", .{ n, buf.name });
                    try audit.write("buffer-save", .{ .path = buf.name, .bytes = n });
                } else {
                    print("  (no buffer open)\n\n", .{});
                }
                continue;
            }
            if (std.mem.eql(u8, b.janet_expr, "MAST_SAVEAS_SENTINEL")) {
                if (parsed.args.len == 0) {
                    print("  (usage: M-x save-as <path>)\n\n", .{});
                    continue;
                }
                // If no buffer is open, create an empty :file buffer at the
                // target path (same semantics as `vim some-new-file.txt`).
                if (currentBuffer() == null) {
                    const new_buf = Buffer.fromBytes(allocator, .file, parsed.args[0], "") catch |e| {
                        print("  (could not create buffer: {})\n\n", .{e});
                        continue;
                    };
                    _ = addBuffer(allocator, new_buf) catch |e| {
                        print("  (could not add buffer to ring: {})\n\n", .{e});
                        continue;
                    };
                    try audit.write("buffer-create", .{ .path = parsed.args[0], .kind = "file" });
                }
                if (currentBuffer()) |buf| {
                    const n = buf.saveAs(parsed.args[0]) catch |e| {
                        print("  (save-as error: {})\n\n", .{e});
                        try audit.write("mx-saveas-error", .{ .err = @errorName(e), .path = parsed.args[0] });
                        continue;
                    };
                    print("  → wrote {d} bytes to {s} (buffer is now :file)\n\n",
                          .{ n, parsed.args[0] });
                    try audit.write("buffer-saveas", .{ .path = parsed.args[0], .bytes = n });
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
            print("mast v1.2.0\n", .{});
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
    janet.janet_def(env, "stax-bash", janet.janet_wrap_cfunction(sandbox.gated_stax_bash), "Run a bash command; return exit status. Requires `exec` capability.");
    janet.janet_def(env, "buffer-name", janet.janet_wrap_cfunction(cmd_buffer_name), "Current buffer name, or nil.");
    janet.janet_def(env, "buffer-size", janet.janet_wrap_cfunction(cmd_buffer_size), "Current buffer byte size.");
    janet.janet_def(env, "buffer-count", janet.janet_wrap_cfunction(cmd_buffer_count), "Number of buffers in the ring.");
    janet.janet_def(env, "buffer-current-index", janet.janet_wrap_cfunction(cmd_buffer_current_index), "Index of the focused buffer.");
    janet.janet_def(env, "buffer-next", janet.janet_wrap_cfunction(cmd_buffer_next), "Cycle focus forward; returns new index.");
    janet.janet_def(env, "buffer-prev", janet.janet_wrap_cfunction(cmd_buffer_prev), "Cycle focus backward; returns new index.");
    janet.janet_def(env, "buffer-switch", janet.janet_wrap_cfunction(cmd_buffer_switch), "(buffer-switch idx) — focus buffer at index, returns new index or -1.");
    janet.janet_def(env, "agent/run", janet.janet_wrap_cfunction(cmd_agent_run), "(agent/run cmd) — spawn cmd, capture stdout into a new :agent buffer, return its index. Requires `exec`.");

    // Install capability-gated wrappers over Janet's stdlib dangerous
    // bindings. The MECHANISM is default-deny at the binding boundary;
    // see docs/SANDBOX_THREAT_MODEL.md for the threat model + invariants.
    // (Audit log writes are deferred until SessionAudit is initialized
    // below — applyDefaultDeny itself is side-effect-free w.r.t. the audit.)
    const replaced_bindings = sandbox.applyDefaultDeny(env.?);

    // Session audit log
    var audit = try SessionAudit.init(allocator, @intCast(libc.getpid()));
    defer audit.deinit();
    g_audit = &audit;

    try audit.write("sandbox-applied", .{ .replaced = replaced_bindings });

    // HOST POLICY (v1): by default grant `exec` at startup because mast's own
    // first-party verbs (`M-x stax-search`, `M-x stax-dashboard`,
    // `M-x stax-hunger`) shell out via `stax-bash`, AND fall-through Janet
    // expressions are evaluated in the same env. Without this grant the
    // out-of-the-box experience breaks. The MECHANISM (binding-level
    // gate + capability check) is independent of this policy choice; v2
    // will scope grants per-script-load so a runtime-loaded module gets
    // a fresh, default-deny capability set even though init.janet had
    // exec. See SANDBOX_THREAT_MODEL.md §"v1 host policy" + §"What v1
    // does NOT defend against".
    //
    // STRICT MODE: if MAST_SANDBOX_STRICT is set to a truthy value
    // (1/true/yes/on, case-insensitive), the auto-grant is suppressed.
    // The production binary then exhibits the same default-deny posture
    // the sandbox unit tests prove on a fresh VM — first-party verbs that
    // need `exec` fail loudly with the standard panic. This moves the
    // sandbox claim from "mechanism-proven in tests" to
    // "deny-by-default observable in the production binary".
    const strict = read_strict_env();
    if (strict) {
        try audit.write("sandbox-strict-mode", .{ .source = "MAST_SANDBOX_STRICT", .auto_grant_exec = false });
        print("mast: MAST_SANDBOX_STRICT enabled — `exec` capability NOT auto-granted. " ++
              "Verbs that shell out (stax-search/dashboard/hunger, os/shell, stax-bash) " ++
              "will fail with `denied capability: exec`.\n", .{});
    } else {
        sandbox.grant(.exec);
        try audit.write("sandbox-grant", .{ .capability = "exec", .scope = "host-policy-v1" });
    }

    // Open initial file as :file buffer if provided. Routes through the
    // multi-buffer ring (added 2026-05-19) so runtime-created buffers (via
    // M-x save-as / M-x new-buffer) share the same ownership model.
    if (initial_file) |path| {
        const opened = Buffer.fromFile(allocator, path) catch |e| {
            print("could not open {s}: {}\n", .{ path, e });
            std.process.exit(2);
        };
        _ = addBuffer(allocator, opened) catch |e| {
            print("could not register {s} in buffer ring: {}\n", .{ path, e });
            std.process.exit(2);
        };
        try audit.write("buffer-open", .{ .path = path, .kind = "file" });
    }
    // Deinit every buffer in the ring at process exit. Each Buffer owns its
    // own name + contents; ArrayList.deinit frees the backing storage.
    defer {
        for (g_buffers.items) |*b| b.deinit();
        g_buffers.deinit(allocator);
    }

    // Load $XDG_CONFIG_HOME/mast/init.janet (default ~/.config/mast/init.janet)
    // before entering the REPL so user-defined commands are available at the
    // first M-x prompt. Per SPEC.md §6 v0.1 deliverable #5.
    load_init_janet(allocator, env.?, &audit) catch |e| {
        // Non-fatal: missing init.janet is normal, parse errors are surfaced
        // by Janet itself.
        switch (e) {
            error.InitFileMissing => {},
            else => print("init.janet load: {}\n", .{e}),
        }
    };

    try run_repl(allocator, env.?, &audit);
}

fn load_init_janet(allocator: Allocator, env: *janet.JanetTable, audit: *SessionAudit) !void {
    // Resolve config path: $XDG_CONFIG_HOME/mast/init.janet or ~/.config/mast/init.janet
    const env_config = libc.getenv("XDG_CONFIG_HOME");
    const env_home = libc.getenv("HOME");
    var path_buf: [512]u8 = undefined;
    const path = if (env_config != null) blk: {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(env_config.?)));
        break :blk try std.fmt.bufPrint(&path_buf, "{s}/mast/init.janet", .{s});
    } else blk: {
        const h = if (env_home != null)
            std.mem.span(@as([*:0]const u8, @ptrCast(env_home.?)))
        else
            return error.InitFileMissing;
        break :blk try std.fmt.bufPrint(&path_buf, "{s}/.config/mast/init.janet", .{h});
    };

    // Attempt to read the file via libc (consistent with the rest of the
    // codebase, which avoids std.fs/std.Io churn across Zig 0.13–0.16).
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);
    const fd = libc.open(@ptrCast(c_path.ptr), libc.O_RDONLY);
    if (fd < 0) return error.InitFileMissing;
    defer _ = libc.close(fd);

    var contents = try allocator.alloc(u8, 65536); // 64 KB cap on init.janet
    defer allocator.free(contents);
    const rc = libc.read(fd, contents.ptr, contents.len - 1);
    if (rc <= 0) return error.InitFileEmpty;
    const len: usize = @intCast(rc);
    contents[len] = 0;

    var out: janet.Janet = undefined;
    const status = janet.janet_dostring(env, @ptrCast(contents.ptr), "init.janet", &out);
    if (status != 0) {
        print("init.janet: eval error (status={d})\n", .{status});
        try audit.write("init-janet-error", .{ .path = path, .status = status });
        return error.InitFileEvalFailed;
    }
    print("init.janet loaded from {s}\n", .{path});
    try audit.write("init-janet-loaded", .{ .path = path, .bytes = len });
}
