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
const tui = @import("tui.zig");

const janet = @import("janet_c.zig").c;

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
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

/// Sanitize a user-supplied buffer name in place (round-2 adversarial
/// finding #3): canonicalize on write at the trust boundary instead of
/// hoping every reader remembers to sanitize. Replaces ESC, BEL, DEL,
/// and other C0 control bytes (except `\t`/`\n`/`\r`) with `?`. Returns
/// the slice of `out_buf` actually written.
fn sanitizeNameInto(out_buf: []u8, raw: []const u8) []const u8 {
    const n = @min(raw.len, out_buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = raw[i];
        out_buf[i] = switch (c) {
            0x09, 0x0a, 0x0d => c,
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => '?',
            else => c,
        };
    }
    return out_buf[0..n];
}

fn onSandboxDeny(cat: sandbox.DenyCategory) void {
    if (g_audit) |a| {
        a.write("sandbox-deny", .{ .category = @tagName(cat) }) catch {};
    }
}

// ─── Resource quota: SIGALRM + janet_interpreter_interrupt ─────────────
//
// Closes the v1.3.0 §honest-residuals "no resource quotas" item using
// the primitive identified in v1.3.3 (janet_interpreter_interrupt +
// janet_local_vm in vendored/janet/janet.h lines 2066–2072).
//
// How it works:
//   1. alarm_handler() runs in signal context when SIGALRM fires.
//      It calls janet_interpreter_interrupt(janet_local_vm()) which
//      tells the Janet VM to cancel the currently-running fiber at
//      the next bytecode-op boundary.
//   2. Before each janet_dostring call, the caller arms libc.alarm(N).
//      After the call returns or panics, the caller disarms with
//      libc.alarm(0).
//   3. The cancelled fiber returns a non-zero status to janet_dostring,
//      which mast then surfaces as a normal eval error (the audit log
//      records mx-error with status=1).
//
// Configurable via MAST_EVAL_TIMEOUT_SEC env var. Default 30 seconds —
// enough for most agent-driven workflows, short enough that a
// (while true) doesn't freeze the editor.

const DEFAULT_EVAL_TIMEOUT_SEC: c_uint = 30;
var g_eval_timeout_sec: c_uint = DEFAULT_EVAL_TIMEOUT_SEC;

fn alarm_handler(sig: c_int) callconv(.c) void {
    _ = sig;
    const vm = janet.janet_local_vm();
    if (vm != null) janet.janet_interpreter_interrupt(vm);
}

fn install_eval_timeout(audit: ?*SessionAudit) void {
    // Read env var override (matches the strict-mode parsing pattern).
    const raw = libc.getenv("MAST_EVAL_TIMEOUT_SEC");
    if (raw != null) {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(raw.?)));
        const parsed = std.fmt.parseInt(c_uint, s, 10) catch DEFAULT_EVAL_TIMEOUT_SEC;
        // Cap at 1 hour as a sanity backstop.
        g_eval_timeout_sec = if (parsed > 0 and parsed <= 3600) parsed else DEFAULT_EVAL_TIMEOUT_SEC;
    }
    // Install the SIGALRM handler. signal(2) is the simplest portable
    // call; sigaction would give more control over flags but signal is
    // sufficient for the one-shot alarm-fires-interrupt pattern.
    _ = libc.signal(libc.SIGALRM, &alarm_handler);
    if (audit) |a| {
        a.write("eval-timeout-installed", .{ .seconds = g_eval_timeout_sec }) catch {};
    }
}

/// Run a janet_dostring with the resource-quota alarm armed.
/// Caller owns the c_src lifetime.
fn janet_dostring_quota(env: *janet.JanetTable, c_src: [*c]const u8, label: [*c]const u8, out: *janet.Janet) c_int {
    _ = libc.alarm(g_eval_timeout_sec);
    const status = janet.janet_dostring(env, c_src, label, out);
    _ = libc.alarm(0);
    return status;
}

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

// ─── Async agent handle table (v0.3 of agent-as-buffer) ────────────────
//
// (agent/spawn cmd) is the non-blocking variant of (agent/run cmd). It
// fork+execs the command with a stdout pipe captured non-blockingly,
// creates a new :agent buffer for the live stream, and returns a HANDLE id
// (integer) the script can poll.
//
//   (def h (agent/spawn "stax-search merchants"))
//   (agent/poll h)   # nil if still running; exit-status integer if done
//   (agent/wait h)   # block until done, return exit status
//   (agent/list)     # tuple of {:id N :pid P :buffer-index I :closed B}
//
// This is the steipete-thesis surface in v0.3 form: many agents running
// in the background, each addressable as a buffer, each pollable as a
// handle. The buffer accumulates bytes as `agent/poll` is called.
//
// Lifecycle invariants:
//   - Handle id is the index into g_agents; never reused, never reordered.
//   - The :agent buffer at h.buffer_idx is owned by the buffer ring;
//     g_agents.items[h] holds the index, not the buffer pointer
//     (the ArrayList could relocate on grow).
//   - h.stdout_fd is closed exactly once — when the child exits AND poll
//     observes the exit. Tracked by h.closed.
//   - Zombie reaping: waitpid is called on every poll; explicit (agent/wait)
//     loops polling.

const AgentHandle = struct {
    pid: i32,
    stdout_fd: i32,
    buffer_idx: usize,
    closed: bool = false,
    exit_status: i32 = 0,
};

var g_agents: std.ArrayList(AgentHandle) = .empty;

/// Drain any bytes currently available on `h.stdout_fd` into the agent's
/// buffer. Returns the number of bytes drained on this call (0 if the
/// fd had nothing ready; the fd is O_NONBLOCK so reads do not block).
fn agentDrain(allocator: Allocator, h: *AgentHandle) usize {
    if (h.closed) return 0;
    if (h.buffer_idx >= g_buffers.items.len) return 0;
    var total: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = libc.read(h.stdout_fd, &chunk, chunk.len);
        if (n <= 0) break;
        const slice = chunk[0..@intCast(n)];
        g_buffers.items[h.buffer_idx].append(slice) catch return total;
        total += @intCast(n);
    }
    _ = allocator; // append uses the Buffer's own allocator
    return total;
}

/// `(agent/spawn cmd)` — fork+exec cmd with a non-blocking stdout pipe.
/// Creates a new :agent buffer for live stdout capture. Returns the
/// handle id (integer), which doubles as the index in g_agents. Switches
/// focus to the newly-created agent buffer.
fn cmd_agent_spawn(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/spawn denied — `exec` capability not granted (default-deny)");
    }
    if (argc != 1) {
        janet.janet_panicf("agent/spawn: expected 1 string argument (cmd), got %d", argc);
    }

    const allocator = std.heap.c_allocator;
    const s_ptr = janet.janet_unwrap_string(argv[0]);
    const s_len = std.mem.len(s_ptr);

    // Buffer name: shell command, sanitized + truncated to 64 chars.
    var name_buf: [80]u8 = undefined;
    const name_len = @min(s_len, 64);
    var ni: usize = 0;
    while (ni < name_len) : (ni += 1) {
        const ch = s_ptr[ni];
        name_buf[ni] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    }
    const buf = Buffer.fromBytes(allocator, .agent, name_buf[0..name_len], "") catch {
        janet.janet_panicf("agent/spawn: failed to create :agent buffer");
    };
    const buf_idx = addBuffer(allocator, buf) catch {
        janet.janet_panicf("agent/spawn: failed to add buffer to ring");
    };

    // Pipe + fork + exec via /bin/sh -c <cmd>.
    var pipefd: [2]c_int = undefined;
    if (libc.pipe(&pipefd) != 0) {
        janet.janet_panicf("agent/spawn: pipe(2) failed");
    }

    // C string for the command (Janet strings are not null-terminated guaranteed).
    const cmd_z = allocator.dupeZ(u8, @as([*]const u8, @ptrCast(s_ptr))[0..s_len]) catch {
        _ = libc.close(pipefd[0]);
        _ = libc.close(pipefd[1]);
        janet.janet_panicf("agent/spawn: OOM allocating command string");
    };
    defer allocator.free(cmd_z);

    const child = libc.fork();
    if (child < 0) {
        _ = libc.close(pipefd[0]);
        _ = libc.close(pipefd[1]);
        allocator.free(cmd_z);
        janet.janet_panicf("agent/spawn: fork(2) failed");
    }
    if (child == 0) {
        // Child: dup pipe-write to stdout, close pipe ends, exec.
        _ = libc.dup2(pipefd[1], 1);
        // Also redirect stderr to the same pipe so the buffer captures both.
        _ = libc.dup2(pipefd[1], 2);
        _ = libc.close(pipefd[0]);
        _ = libc.close(pipefd[1]);
        const sh: [*c]const u8 = @ptrCast("/bin/sh");
        // Use execv with a 4-element argv array; sidesteps variadic-null
        // marshalling that Zig 0.16 declines to guarantee for execl.
        const argv_array = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            @ptrCast(cmd_z.ptr),
        };
        _ = libc.execv(sh, @ptrCast(@constCast(&argv_array)));
        // execv only returns on failure.
        libc.exit(127);
    }

    // Parent: close write end, set read end non-blocking, register handle.
    _ = libc.close(pipefd[1]);
    const flags = libc.fcntl(pipefd[0], libc.F_GETFL, @as(c_int, 0));
    _ = libc.fcntl(pipefd[0], libc.F_SETFL, flags | libc.O_NONBLOCK);
    // FD_CLOEXEC on the pipe-read end so future fork+execs don't leak
    // it (round-2 adversarial finding #2). The pipe-write end was
    // already closed in the parent.
    const fdflags = libc.fcntl(pipefd[0], libc.F_GETFD, @as(c_int, 0));
    _ = libc.fcntl(pipefd[0], libc.F_SETFD, fdflags | libc.FD_CLOEXEC);

    g_agents.append(allocator, .{
        .pid = @intCast(child),
        .stdout_fd = pipefd[0],
        .buffer_idx = buf_idx,
    }) catch {
        _ = libc.close(pipefd[0]);
        janet.janet_panicf("agent/spawn: failed to register handle");
    };
    const handle_id = g_agents.items.len - 1;

    if (g_audit) |a| {
        a.write("agent-spawn", .{
            .handle = handle_id,
            .pid = child,
            .buffer_index = buf_idx,
        }) catch {};
    }

    return janet.janet_wrap_integer(@intCast(handle_id));
}

/// `(agent/poll handle)` — drain any bytes ready on the agent's stdout
/// into its :agent buffer, then check whether the child has exited.
/// Returns the integer exit status if the child has exited, nil otherwise.
/// On error returns the keyword :error. Safe to call repeatedly.
///
/// Gated on `exec`: poll surfaces process stdout (a side channel that a
/// non-exec script must not reach) and could otherwise be misused on a
/// pre-existing handle under MAST_SANDBOX_STRICT=1.
fn cmd_agent_poll(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/poll denied — `exec` capability not granted (default-deny)");
    }
    if (argc != 1) {
        janet.janet_panicf("agent/poll: expected 1 integer argument (handle), got %d", argc);
    }
    var handle_id_i32: i32 = -1;
    const t = janet.janet_type(argv[0]);
    if (t == janet.JANET_NUMBER) {
        handle_id_i32 = janet.janet_unwrap_integer(argv[0]);
    } else if (t == janet.JANET_STRING) {
        const s_ptr = janet.janet_unwrap_string(argv[0]);
        const len = janet.janet_string_length(s_ptr);
        const bytes = @as([*]const u8, @ptrCast(s_ptr))[0..@intCast(len)];
        handle_id_i32 = std.fmt.parseInt(i32, bytes, 10) catch -1;
    }
    if (handle_id_i32 < 0) return janet.janet_wrap_nil();
    const hid: usize = @intCast(handle_id_i32);
    if (hid >= g_agents.items.len) return janet.janet_wrap_nil();
    const h = &g_agents.items[hid];

    const allocator = std.heap.c_allocator;
    _ = agentDrain(allocator, h);

    if (h.closed) return janet.janet_wrap_integer(h.exit_status);

    var status: c_int = 0;
    const rc = libc.waitpid(@intCast(h.pid), &status, libc.WNOHANG);
    if (rc == 0) return janet.janet_wrap_nil(); // still running
    if (rc < 0) return janet.janet_wrap_nil();
    // Child exited — drain one more time in case bytes arrived between
    // the read loop and the waitpid call.
    _ = agentDrain(allocator, h);
    h.closed = true;
    // WEXITSTATUS macro: low byte after >> 8.
    h.exit_status = @intCast((status >> 8) & 0xff);
    _ = libc.close(h.stdout_fd);
    if (g_audit) |a| {
        a.write("agent-exit", .{
            .handle = hid,
            .pid = h.pid,
            .exit_status = h.exit_status,
        }) catch {};
    }
    return janet.janet_wrap_integer(h.exit_status);
}

/// `(agent/wait handle)` — block until the agent exits, return exit status.
/// Uses poll(2) on the stdout_fd with a 500ms backstop timeout. The
/// `poll` returns immediately when stdout has bytes ready or hits EOF
/// (which is how the kernel signals "child closed the pipe write end" —
/// almost always == process exit). The 500ms backstop covers the rare
/// case of a child that exits WITHOUT closing stdout (eg. a grandchild
/// still holding it) so we still notice exit via WNOHANG waitpid.
///
/// Gated on `exec`: closes adversarial-review finding #7. Without this
/// gate, a strict-mode script could call `(agent/wait 0)` on a
/// pre-existing handle and freeze mast for the full duration of the
/// child's lifetime — even though the script itself has no exec cap.
fn cmd_agent_wait(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/wait denied — `exec` capability not granted (default-deny)");
    }
    if (argc != 1) {
        janet.janet_panicf("agent/wait: expected 1 integer argument (handle), got %d", argc);
    }
    var handle_id_i32: i32 = -1;
    const t = janet.janet_type(argv[0]);
    if (t == janet.JANET_NUMBER) {
        handle_id_i32 = janet.janet_unwrap_integer(argv[0]);
    } else if (t == janet.JANET_STRING) {
        const s_ptr = janet.janet_unwrap_string(argv[0]);
        const len = janet.janet_string_length(s_ptr);
        const bytes = @as([*]const u8, @ptrCast(s_ptr))[0..@intCast(len)];
        handle_id_i32 = std.fmt.parseInt(i32, bytes, 10) catch -1;
    }
    if (handle_id_i32 < 0) return janet.janet_wrap_integer(-1);
    const hid: usize = @intCast(handle_id_i32);
    if (hid >= g_agents.items.len) return janet.janet_wrap_integer(-1);
    const h = &g_agents.items[hid];

    const allocator = std.heap.c_allocator;
    while (!h.closed) {
        // poll(2) on the stdout fd. Returns when:
        //   - revents & POLLIN: bytes ready → drain
        //   - revents & POLLHUP: pipe write end closed → child likely exited
        //   - timeout: 500ms elapsed without activity → fall through to waitpid
        var pfd: libc.struct_pollfd = .{
            .fd = h.stdout_fd,
            .events = libc.POLLIN,
            .revents = 0,
        };
        const rc = libc.poll(@ptrCast(&pfd), 1, 500);
        if (rc > 0) {
            _ = agentDrain(allocator, h);
        }
        // Whether or not the poll woke us, also do a non-blocking exit check.
        // The pipe can produce POLLIN even after the child exited (final
        // buffered bytes); waitpid is the authoritative exit detection.
        var status: c_int = 0;
        const wrc = libc.waitpid(@intCast(h.pid), &status, libc.WNOHANG);
        if (wrc > 0) {
            _ = agentDrain(allocator, h); // final drain
            h.closed = true;
            h.exit_status = @intCast((status >> 8) & 0xff);
            _ = libc.close(h.stdout_fd);
            if (g_audit) |a| {
                a.write("agent-exit", .{
                    .handle = hid,
                    .pid = h.pid,
                    .exit_status = h.exit_status,
                }) catch {};
            }
            break;
        }
        if (wrc < 0) break;
        // wrc == 0 means still running; loop back to poll
    }
    return janet.janet_wrap_integer(h.exit_status);
}

/// `(agent/count)` — number of registered handles (running + exited).
/// Gated on `exec` for symmetry; without the gate a strict-mode script
/// could enumerate the agent fleet's size as a side channel.
fn cmd_agent_count(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/count denied — `exec` capability not granted (default-deny)");
    }
    return janet.janet_wrap_integer(@intCast(g_agents.items.len));
}

/// `(agent/kill handle)` — send SIGTERM to the agent's process. Best-effort:
/// returns true if the signal was sent, false if the handle is invalid or
/// already closed. Does NOT reap — call `(agent/wait handle)` after to
/// collect the exit status and close the stdout_fd. Gated on `exec` since
/// signaling a child process you started is part of the same capability.
fn cmd_agent_kill(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/kill denied — `exec` capability not granted (default-deny)");
    }
    if (argc != 1) {
        janet.janet_panicf("agent/kill: expected 1 integer argument (handle), got %d", argc);
    }
    var handle_id_i32: i32 = -1;
    const t = janet.janet_type(argv[0]);
    if (t == janet.JANET_NUMBER) {
        handle_id_i32 = janet.janet_unwrap_integer(argv[0]);
    } else if (t == janet.JANET_STRING) {
        const s_ptr = janet.janet_unwrap_string(argv[0]);
        const len = janet.janet_string_length(s_ptr);
        const bytes = @as([*]const u8, @ptrCast(s_ptr))[0..@intCast(len)];
        handle_id_i32 = std.fmt.parseInt(i32, bytes, 10) catch -1;
    }
    if (handle_id_i32 < 0) return janet.janet_wrap_false();
    const hid: usize = @intCast(handle_id_i32);
    if (hid >= g_agents.items.len) return janet.janet_wrap_false();
    const h = &g_agents.items[hid];
    if (h.closed) return janet.janet_wrap_false();
    const rc = libc.kill(@intCast(h.pid), libc.SIGTERM);
    if (g_audit) |a| {
        a.write("agent-kill", .{ .handle = hid, .pid = h.pid, .signal = "SIGTERM", .rc = rc }) catch {};
    }
    return if (rc == 0) janet.janet_wrap_true() else janet.janet_wrap_false();
}

/// `(agent/alive? handle)` — boolean, true if handle exists and is unclosed.
/// Gated on `exec`; without the gate a script can probe whether a
/// pre-existing handle is still running as a side channel.
fn cmd_agent_alive(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!sandbox.g_sandbox.has(.exec)) {
        janet.janet_panicf("mast.sandbox: agent/alive? denied — `exec` capability not granted (default-deny)");
    }
    if (argc != 1) return janet.janet_wrap_false();
    var handle_id_i32: i32 = -1;
    const t = janet.janet_type(argv[0]);
    if (t == janet.JANET_NUMBER) {
        handle_id_i32 = janet.janet_unwrap_integer(argv[0]);
    } else if (t == janet.JANET_STRING) {
        const s_ptr = janet.janet_unwrap_string(argv[0]);
        const len = janet.janet_string_length(s_ptr);
        const bytes = @as([*]const u8, @ptrCast(s_ptr))[0..@intCast(len)];
        handle_id_i32 = std.fmt.parseInt(i32, bytes, 10) catch -1;
    }
    if (handle_id_i32 < 0) return janet.janet_wrap_false();
    const hid: usize = @intCast(handle_id_i32);
    if (hid >= g_agents.items.len) return janet.janet_wrap_false();
    return if (g_agents.items[hid].closed) janet.janet_wrap_false() else janet.janet_wrap_true();
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
                // Sanitize the name at the trust boundary (round-2
                // adversarial finding #3 doctrine: canonicalize on write,
                // not on every read). list-buffers / display / TUI
                // status-bar all consume buf.name; sanitizing here means
                // every consumer sees safe bytes regardless of whether
                // they remember to sanitize themselves.
                var name_sanitized: [256]u8 = undefined;
                const raw_name = parsed.args[0];
                const sn = sanitizeNameInto(&name_sanitized, raw_name);
                const new_buf = Buffer.fromBytes(allocator, .agent, sn, "") catch |e| {
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
                // Sanitize path-as-name at the trust boundary (round-2
                // adversarial finding #3). The actual filesystem write
                // still uses the original (un-sanitized) path because
                // the underlying syscalls don't care about ANSI escapes
                // — but the in-memory buffer name (which flows into
                // list-buffers/display/TUI) must be safe to print.
                var name_sanitized: [512]u8 = undefined;
                _ = sanitizeNameInto(&name_sanitized, parsed.args[0]);
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
        const status = janet_dostring_quota(env, c_src.ptr, "mx", &out);
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

    // CLI flags: --tui enters the windowed view after init.janet loads.
    var initial_file: ?[]const u8 = null;
    var tui_mode = false;
    while (args_iter.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            print("usage: mast [--tui] [file]\n\n", .{});
            print("{s}", .{HELP_TEXT});
            return;
        }
        if (std.mem.eql(u8, a, "--version")) {
            print("mast v1.2.0\n", .{});
            return;
        }
        if (std.mem.eql(u8, a, "--tui")) {
            tui_mode = true;
            continue;
        }
        if (initial_file == null) {
            initial_file = try allocator.dupe(u8, a);
        }
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
    janet.janet_def(env, "agent/spawn", janet.janet_wrap_cfunction(cmd_agent_spawn), "(agent/spawn cmd) — non-blocking fork+exec; returns handle id. Buffer receives stdout via agent/poll. Requires `exec`.");
    janet.janet_def(env, "agent/poll", janet.janet_wrap_cfunction(cmd_agent_poll), "(agent/poll handle) — drain stdout into buffer; return exit status int if exited, nil otherwise.");
    janet.janet_def(env, "agent/wait", janet.janet_wrap_cfunction(cmd_agent_wait), "(agent/wait handle) — block until agent exits, return exit status.");
    janet.janet_def(env, "agent/count", janet.janet_wrap_cfunction(cmd_agent_count), "(agent/count) — number of registered agent handles.");
    janet.janet_def(env, "agent/alive?", janet.janet_wrap_cfunction(cmd_agent_alive), "(agent/alive? handle) — true if handle exists and is unclosed.");
    janet.janet_def(env, "agent/kill", janet.janet_wrap_cfunction(cmd_agent_kill), "(agent/kill handle) — SIGTERM the agent process; returns bool. Requires `exec`.");

    // Install capability-gated wrappers over Janet's stdlib dangerous
    // bindings. The MECHANISM is default-deny at the binding boundary;
    // see docs/SANDBOX_THREAT_MODEL.md for the threat model + invariants.
    // (Audit log writes are deferred until SessionAudit is initialized
    // below — applyDefaultDeny itself is side-effect-free w.r.t. the audit.)
    const replaced_bindings = sandbox.applyDefaultDeny(env.?);

    // Route sandbox-deny events into the session audit log. Closes
    // docs/SANDBOX_THREAT_MODEL.md §6 residual #9. The observer fires
    // BEFORE the panic propagates, so even unrecoverable denies leave a
    // trace in the audit log before Janet's stacktrace surfaces to stderr.
    sandbox.g_deny_observer = &onSandboxDeny;

    // Session audit log
    var audit = try SessionAudit.init(allocator, @intCast(libc.getpid()));
    defer audit.deinit();
    g_audit = &audit;

    try audit.write("sandbox-applied", .{ .replaced = replaced_bindings });

    // Install the resource-quota alarm handler (v1.3.5 — closes the
    // long-standing §honest-residuals "no resource quotas" item using
    // janet_interpreter_interrupt + SIGALRM). Configurable via
    // MAST_EVAL_TIMEOUT_SEC env var; default 30 seconds.
    install_eval_timeout(&audit);

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
    // Reap any still-running agents at process exit so we don't leak zombies.
    // Best-effort: SIGTERM, drain pipe, close fd, waitpid. Per-handle errors
    // are swallowed because we're already exiting.
    defer {
        for (g_agents.items) |*h| {
            if (!h.closed) {
                _ = libc.kill(@intCast(h.pid), libc.SIGTERM);
                _ = libc.close(h.stdout_fd);
                var st: c_int = 0;
                _ = libc.waitpid(@intCast(h.pid), &st, 0);
            }
        }
        g_agents.deinit(allocator);
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

    if (tui_mode) {
        try run_tui(allocator, env.?, &audit);
    } else {
        try run_repl(allocator, env.?, &audit);
    }
}

// ─── TUI run loop ──────────────────────────────────────────────────────
//
// Enters raw mode, draws the viewport, reads keys, dispatches to the
// existing M-x machinery via janet_dostring. The render is full-redraw
// per keystroke — adequate for a v0.3 prototype on terminals smaller
// than 200x80. v0.3.x will add diff-render via a damage tracker.
//
// Key dispatch:
//   j / Down  → scroll down
//   k / Up    → scroll up
//   g         → top of buffer (scroll = 0)
//   G         → bottom of buffer (scroll = lineCount - viewport_rows)
//   n         → next buffer (cycles g_current_index forward)
//   p         → prev buffer
//   :         → read a M-x command into the minibuffer, execute on Enter
//   q         → exit TUI back to caller
//   Ctrl-C    → exit TUI

fn run_tui(allocator: Allocator, env: *janet.JanetTable, audit: *SessionAudit) !void {
    var raw = tui.RawMode.enter();
    defer raw.exit();

    try audit.write("tui-enter", .{});
    defer audit.write("tui-exit", .{}) catch {};

    var scroll: usize = 0;
    var minibuffer_buf: [256]u8 = undefined;
    var minibuffer_len: usize = 0;
    var in_mx_mode = false;

    // Damage-tracker state: render into `frame`, diff against the last
    // emit via `frame_state`. Closes the v1.3.0 "full-redraw per keystroke"
    // residual — repeated no-op keystrokes (eg. cycling past EOF, pressing
    // a key the TUI doesn't bind) no longer cost a screen-rewrite.
    var frame_state = tui.FrameState{};
    defer frame_state.deinit(allocator);
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    while (true) {
        const cur = currentBuffer();
        const total = g_buffers.items.len;
        const minibuffer_slice: ?[]const u8 = if (in_mx_mode) minibuffer_buf[0..minibuffer_len] else null;
        frame.clearRetainingCapacity();
        tui.render_to_buf(&frame, allocator, cur, scroll, g_current_index, total, minibuffer_slice);
        _ = tui.emit_with_damage(&frame_state, allocator, frame.items);

        const k = tui.readKey();
        const k_int = @intFromEnum(k);

        if (in_mx_mode) {
            // Minibuffer input loop
            if (k_int == 0x0a or k_int == 0x0d) {
                // Enter — execute the line
                const cmd_line = minibuffer_buf[0..minibuffer_len];
                if (cmd_line.len > 0) {
                    try execute_mx_line(allocator, env, audit, cmd_line);
                }
                minibuffer_len = 0;
                in_mx_mode = false;
                continue;
            }
            if (k_int == 0x1b) {
                // ESC — cancel minibuffer
                minibuffer_len = 0;
                in_mx_mode = false;
                continue;
            }
            if (k_int == 0x7f or k_int == 0x08) {
                // Backspace
                if (minibuffer_len > 0) minibuffer_len -= 1;
                continue;
            }
            if (k_int >= 0x20 and k_int < 0x7f and minibuffer_len < minibuffer_buf.len) {
                minibuffer_buf[minibuffer_len] = @intCast(k_int);
                minibuffer_len += 1;
            }
            continue;
        }

        // Navigation mode
        switch (k_int) {
            'q', 0x03 => break, // q or Ctrl-C
            'j' => scroll += 1,
            'k' => if (scroll > 0) {
                scroll -= 1;
            },
            'g' => scroll = 0,
            'G' => {
                if (cur) |b| {
                    const dims = tui.terminalSize();
                    const viewport: usize = if (dims.rows > 3) dims.rows - 2 else 1;
                    const lines = b.lineCount();
                    scroll = if (lines > viewport) lines - viewport else 0;
                }
            },
            'n' => {
                _ = nextBuffer();
                scroll = 0;
            },
            'p' => {
                _ = prevBuffer();
                scroll = 0;
            },
            ':' => in_mx_mode = true,
            else => {
                // Arrow keys
                if (k == .down) scroll += 1;
                if (k == .up and scroll > 0) scroll -= 1;
            },
        }
    }
}

/// Shared M-x dispatch used by both the line REPL and the TUI minibuffer.
/// Routes through parse_mx_line, the builtin table, and falls through to
/// raw Janet eval. The TUI variant suppresses the print() side-effects
/// the REPL emits; results are visible on the next full-redraw.
///
/// Sentinel verbs that mutate buffer state (append / save / save-as /
/// new-buffer) ARE handled here so the TUI minibuffer can drive them.
/// Display-only sentinels (help / display / list-buffers) are skipped
/// because the TUI already renders that state inline.
fn execute_mx_line(allocator: Allocator, env: *janet.JanetTable, audit: *SessionAudit, line: []const u8) !void {
    const parsed = (try parse_mx_line(allocator, line)) orelse return;
    defer allocator.free(parsed.args);
    try audit.write("mx-input", .{ .verb = parsed.verb });

    if (std.mem.eql(u8, parsed.verb, "exit") or std.mem.eql(u8, parsed.verb, "quit")) {
        return; // TUI loop will exit when q is pressed; ignore here
    }

    var found: ?BuiltinCmd = null;
    for (BUILTINS) |b| {
        if (std.mem.eql(u8, b.name, parsed.verb)) {
            found = b;
            break;
        }
    }

    if (found) |b| {
        if (std.mem.eql(u8, b.janet_expr, "MAST_APPEND_SENTINEL")) {
            if (currentBuffer()) |buf| {
                var combined: std.ArrayList(u8) = .empty;
                defer combined.deinit(allocator);
                for (parsed.args, 0..) |arg, i_arg| {
                    if (i_arg > 0) try combined.append(allocator, ' ');
                    try combined.appendSlice(allocator, arg);
                }
                try combined.append(allocator, '\n');
                buf.append(combined.items) catch |e| {
                    try audit.write("mx-append-error", .{ .err = @errorName(e) });
                    return;
                };
                try audit.write("buffer-append", .{ .bytes = combined.items.len, .via = "tui" });
            }
            return;
        }
        if (std.mem.eql(u8, b.janet_expr, "MAST_SAVE_SENTINEL")) {
            if (currentBuffer()) |buf| {
                _ = buf.save() catch |e| {
                    try audit.write("mx-save-error", .{ .err = @errorName(e), .path = buf.name });
                    return;
                };
                try audit.write("buffer-save", .{ .path = buf.name, .via = "tui" });
            }
            return;
        }
        if (std.mem.eql(u8, b.janet_expr, "MAST_SAVEAS_SENTINEL")) {
            if (parsed.args.len == 0) {
                try audit.write("mx-saveas-error", .{ .err = "missing-path", .via = "tui" });
                return;
            }
            if (currentBuffer() == null) {
                const new_buf = Buffer.fromBytes(allocator, .file, parsed.args[0], "") catch |e| {
                    try audit.write("mx-saveas-error", .{ .err = @errorName(e), .via = "tui" });
                    return;
                };
                _ = addBuffer(allocator, new_buf) catch |e| {
                    try audit.write("mx-saveas-error", .{ .err = @errorName(e), .via = "tui" });
                    return;
                };
                try audit.write("buffer-create", .{ .path = parsed.args[0], .kind = "file", .via = "tui" });
            }
            if (currentBuffer()) |buf| {
                _ = buf.saveAs(parsed.args[0]) catch |e| {
                    try audit.write("mx-saveas-error", .{ .err = @errorName(e), .path = parsed.args[0] });
                    return;
                };
                try audit.write("buffer-saveas", .{ .path = parsed.args[0], .via = "tui" });
            }
            return;
        }
        if (std.mem.eql(u8, b.janet_expr, "MAST_NEWBUFFER_SENTINEL")) {
            if (parsed.args.len == 0) {
                try audit.write("mx-newbuffer-error", .{ .err = "missing-name", .via = "tui" });
                return;
            }
            const new_buf = Buffer.fromBytes(allocator, .agent, parsed.args[0], "") catch |e| {
                try audit.write("mx-newbuffer-error", .{ .err = @errorName(e), .via = "tui" });
                return;
            };
            const new_idx = addBuffer(allocator, new_buf) catch |e| {
                try audit.write("mx-newbuffer-error", .{ .err = @errorName(e), .via = "tui" });
                return;
            };
            try audit.write("buffer-create", .{ .name = parsed.args[0], .kind = "agent", .index = new_idx, .via = "tui" });
            return;
        }
        if (std.mem.startsWith(u8, b.janet_expr, "MAST_")) {
            // Display-only sentinels (help / display / list-buffers): skip
            // in the TUI because the TUI already renders that state inline.
            try audit.write("tui-sentinel-skipped", .{ .verb = parsed.verb });
            return;
        }
    }

    const janet_src = if (found) |b|
        try substitute_args(allocator, b.janet_expr, parsed.args)
    else
        try allocator.dupe(u8, line);
    defer allocator.free(janet_src);

    const c_src = try allocator.dupeZ(u8, janet_src);
    defer allocator.free(c_src);
    var out: janet.Janet = undefined;
    const status = janet.janet_dostring(env, c_src.ptr, "tui-mx", &out);
    if (status != 0) {
        try audit.write("mx-error", .{ .verb = parsed.verb, .status = status });
    }
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
    // O_CLOEXEC closes round-2 adversarial finding #2 for the
    // init.janet read fd; without it children inherit the open file.
    const fd = libc.open(@ptrCast(c_path.ptr), libc.O_RDONLY | libc.O_CLOEXEC);
    if (fd < 0) return error.InitFileMissing;
    defer _ = libc.close(fd);

    var contents = try allocator.alloc(u8, 65536); // 64 KB cap on init.janet
    defer allocator.free(contents);
    const rc = libc.read(fd, contents.ptr, contents.len - 1);
    if (rc <= 0) return error.InitFileEmpty;
    const len: usize = @intCast(rc);
    contents[len] = 0;

    var out: janet.Janet = undefined;
    const status = janet_dostring_quota(env, @ptrCast(contents.ptr), "init.janet", &out);
    if (status != 0) {
        print("init.janet: eval error (status={d})\n", .{status});
        try audit.write("init-janet-error", .{ .path = path, .status = status });
        return error.InitFileEvalFailed;
    }
    print("init.janet loaded from {s}\n", .{path});
    try audit.write("init-janet-loaded", .{ .path = path, .bytes = len });
}
