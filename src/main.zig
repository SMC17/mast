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
// editor state via a global so the bound functions can reach it. The
// global is set once in main() and never mutated after init.

var g_current_buffer: ?*Buffer = null;
var g_audit: ?*SessionAudit = null;
// Storage slot for buffers created at runtime by `M-x save-as` or future
// `M-x new-buffer`. The slot is undefined until the first buffer is created;
// g_current_buffer points to it when initialized. v0.2 multi-buffer will
// replace this with a Buffer ring.
var g_initial_buffer_storage: Buffer = undefined;

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

    print("mast v1.1.0 — single-binary editor kernel\n", .{});
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
                if (g_current_buffer) |buf| {
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
                if (g_current_buffer) |buf| {
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
                if (g_current_buffer == null) {
                    const new_buf = Buffer.fromBytes(allocator, .file, parsed.args[0], "") catch |e| {
                        print("  (could not create buffer: {})\n\n", .{e});
                        continue;
                    };
                    g_initial_buffer_storage = new_buf;
                    g_current_buffer = &g_initial_buffer_storage;
                    try audit.write("buffer-create", .{ .path = parsed.args[0], .kind = "file" });
                }
                if (g_current_buffer) |buf| {
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
            print("mast v1.1.0\n", .{});
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

    // HOST POLICY (v1): grant `exec` at startup because mast's own
    // first-party verbs (`M-x stax-search`, `M-x stax-dashboard`,
    // `M-x stax-hunger`) shell out via `stax-bash`, AND fall-through Janet
    // expressions are evaluated in the same env. Without this grant the
    // out-of-the-box experience breaks. The MECHANISM (binding-level
    // gate + capability check) is independent of this policy choice; v2
    // will scope grants per-script-load so a runtime-loaded module gets
    // a fresh, default-deny capability set even though init.janet had
    // exec. See SANDBOX_THREAT_MODEL.md §"v1 host policy" + §"What v1
    // does NOT defend against".
    sandbox.grant(.exec);
    try audit.write("sandbox-grant", .{ .capability = "exec", .scope = "host-policy-v1" });

    // Open initial file as :file buffer if provided. Routes through the
    // global storage slot so runtime-created buffers (via M-x save-as) share
    // the same ownership model.
    if (initial_file) |path| {
        g_initial_buffer_storage = Buffer.fromFile(allocator, path) catch |e| {
            print("could not open {s}: {}\n", .{ path, e });
            std.process.exit(2);
        };
        g_current_buffer = &g_initial_buffer_storage;
        try audit.write("buffer-open", .{ .path = path, .kind = "file" });
    }
    defer if (g_current_buffer) |b| b.deinit();

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
