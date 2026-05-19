// sandbox.zig — first slice of mast's capability model.
//
// Status (2026-05-14):
//   Proof level: scaffold, unit-tested for the one gated binding.
//   NOT production-grade. NOT a sandbox in the OS-isolation sense.
//   See docs/SANDBOX_THREAT_MODEL.md for the full posture, asset inventory,
//   and known gaps.
//
// What this module IS today:
//   - A capability vocabulary (`Capability` enum) with default-deny semantics.
//   - A `Sandbox` struct held in a host-side global so Janet C-callbacks can
//     consult it without a userdata channel from Janet (Janet's cfunction
//     ABI takes no userdata pointer).
//   - One worked example: `os/shell` is replaced in the core env with a
//     capability-gated wrapper. Default: panic. With `Capability.exec`
//     granted: pass through via libc.system. The mast-bound `stax-bash`
//     cfunction registered by main.zig consults the same capability set,
//     closing the parallel shell-out path.
//
// What this module is NOT:
//   - A complete enumeration of Janet's dangerous bindings (see threat
//     model §"Known gaps" for the residual list — file/, net/, os/exit,
//     os/execute, os/spawn, native, unmarshal, ev/thread, ffi/, etc.).
//   - Path-prefix or argv-pattern granular — the cap is binary on/off in v1.
//   - Resource-quota aware (no CPU, memory, or wall-clock bounds).
//   - Audit-logging — the gated bindings panic on deny; they do not emit
//     audit events. v2 will route deny events through SessionAudit.
//   - Defense against `cfunction` callbacks defined by the host with no
//     capability check (the host is part of the TCB — only Janet-reachable
//     paths are mediated). main.zig MUST consult `g_sandbox` from any new
//     binding it introduces; see `gated_stax_bash` for the pattern.

const std = @import("std");

const janet = @import("janet_c.zig").c;

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

// Re-exported for main.zig — janet C ABI has no userdata, callers need the
// same `janet` namespace this file already routes through @cImport.
pub const c_janet = janet;

// ─── Capability vocabulary ─────────────────────────────────────────────
//
// These are the named capabilities the threat model enumerates. Today
// only `.exec` is enforced at any binding; the others are stubs that
// document the intended surface so the threat-model doc and the code
// agree on vocabulary.

pub const Capability = enum {
    /// Run an external process (os/execute, os/spawn, os/shell, posix-fork,
    /// posix-exec, the mast-bound stax-bash).
    exec,
    /// Read from the filesystem (file/open r-mode, slurp, os/stat, os/dir,
    /// os/readlink, dofile).
    fs_read,
    /// Write to the filesystem (file/open w-mode, spit, os/mkdir, os/rm,
    /// os/rename, os/touch, os/symlink, os/chmod).
    fs_write,
    /// Open an outbound network connection (net/connect).
    net_connect,
    /// Bind a listening socket (net/listen, net/accept).
    net_listen,
    /// Read process environment (os/getenv, os/environ).
    env_read,
    /// Mutate process environment (os/setenv).
    env_write,
    /// Load dynamic native modules (.so / .dylib) via `native` or `import`
    /// on a non-Janet file (JANET_SANDBOX_DYNAMIC_MODULES territory).
    dynamic_modules,
    /// Foreign-function-interface — defining and calling raw C symbols.
    /// Maps to JANET_SANDBOX_FFI_DEFINE + JANET_SANDBOX_FFI_USE +
    /// JANET_SANDBOX_FFI_JIT.
    ffi,
    /// Deserialize arbitrary Janet values (`unmarshal`). High-risk because
    /// marshalled blobs can carry executable bytecode.
    unmarshal,
    /// Terminate the host process (os/exit). NOT covered by Janet's
    /// built-in JANET_SANDBOX_* bits — we MUST wrap os/exit ourselves.
    process_exit,
};

/// A capability set. Backed by a bit-field over the enum, which is small
/// enough (~11 bits today) to fit a `u32`.
pub const CapabilitySet = struct {
    bits: u32 = 0,

    pub fn empty() CapabilitySet {
        return .{ .bits = 0 };
    }

    pub fn grant(self: *CapabilitySet, cap: Capability) void {
        self.bits |= bit(cap);
    }

    pub fn has(self: CapabilitySet, cap: Capability) bool {
        return (self.bits & bit(cap)) != 0;
    }

    fn bit(cap: Capability) u32 {
        return @as(u32, 1) << @intCast(@intFromEnum(cap));
    }
};

// ─── Sandbox state (host-side global) ───────────────────────────────────
//
// Janet's cfunction ABI (`Janet (*)(int32_t, Janet*)`) takes no userdata,
// so the gated wrappers consult a process-global for the active capability
// set. This is the same shape main.zig already uses for g_current_buffer
// and g_audit. In a multi-environment future we'd key off `janet_vm.fiber`
// or a JanetTable per env, but v1 holds one env.

pub var g_sandbox: CapabilitySet = .{ .bits = 0 };

// ─── Gated wrappers ─────────────────────────────────────────────────────
//
// Replacement bindings installed by `applyDefaultDeny` over the core env
// AFTER the host's own cfunctions are defined but BEFORE any user code
// (init.janet or REPL) runs. Each wrapper re-implements the underlying
// system call rather than delegating to Janet's original cfunction, so
// the threat-model invariant ("the gate decides, not Janet's stdlib")
// holds without depending on Janet's internal unwrap macros.

fn gated_os_shell(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!g_sandbox.has(.exec)) {
        observe(.exec_gated);
        janet.janet_panicf(
            "mast.sandbox: os/shell denied — capability `exec` not granted (default-deny)",
        );
    }
    if (argc < 1) {
        // No-argv form of os/shell in Janet is `(os/shell)` (spawn
        // interactive shell). We deny that on the same cap, but require
        // argv.len >= 1 for the simpler v1 implementation.
        janet.janet_panicf("mast.sandbox: gated os/shell requires 1 string arg");
    }
    const arg = argv[0];
    const s_ptr = janet.janet_unwrap_string(arg);
    const c_str = @as([*c]const u8, @ptrCast(s_ptr));
    const rc: i32 = @intCast(libc.system(c_str));
    return janet.janet_wrap_integer(rc);
}

/// Capability-gated drop-in for main.zig's `cmd_stax_bash`. main.zig
/// MUST register this (or its own cfunc that delegates here) so that
/// the stax-bash surface respects the same default-deny posture.
pub fn gated_stax_bash(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    if (!g_sandbox.has(.exec)) {
        observe(.exec_gated);
        janet.janet_panicf(
            "mast.sandbox: stax-bash denied — capability `exec` not granted (default-deny)",
        );
    }
    if (argc != 1) {
        janet.janet_panicf("stax-bash: expected 1 argument, got %d", argc);
    }
    const arg = argv[0];
    const s_ptr = janet.janet_unwrap_string(arg);
    const c_str = @as([*c]const u8, @ptrCast(s_ptr));
    const rc: i32 = @intCast(libc.system(c_str));
    return janet.janet_wrap_integer(rc);
}

// ─── Deny-event observer (audit-log routing, v0.3.x) ───────────────────
//
// Closes residual #9 of docs/SANDBOX_THREAT_MODEL.md §6: previously every
// removed-binding panic and every os/shell-without-exec deny went only to
// stderr via janet_panicf. The host had no first-class hook to route deny
// events into SessionAudit. The observer below lets main.zig register a
// callback that fires BEFORE the panic propagates. The category — not the
// individual symbol — is the audit grain; categories are the load-bearing
// aggregation level for "what kind of capability did the script try to
// reach for." Individual symbols still appear in Janet's stacktrace.

pub const DenyCategory = enum {
    /// os/shell or stax-bash invoked without `exec` capability.
    exec_gated,
    /// One of the removed-from-env subprocess primitives.
    subprocess,
    /// One of the removed file-I/O primitives.
    file_io,
    /// One of the removed network primitives.
    net,
    /// `native` (dynamic-module loading).
    native,
    /// `unmarshal` (bytecode deserialization).
    unmarshal,
    /// `os/exit` (host-lifecycle termination).
    exit,
    /// `dofile` (file-load combined with eval).
    dofile,
    /// Env-var bindings (os/getenv, os/setenv, os/environ).
    env,
    /// Ancillary filesystem-metadata bindings (os/stat, os/dir, os/mkdir, etc.).
    fs_ancillary,
};

pub var g_deny_observer: ?*const fn (cat: DenyCategory) void = null;

fn observe(cat: DenyCategory) void {
    if (g_deny_observer) |f| f(cat);
}

// ─── Removed-binding stubs (G2 closure) ─────────────────────────────────
//
// The threat model (docs/SANDBOX_THREAT_MODEL.md §6) names "wrapped or
// removed from the embedded env" as the two valid closure paths for the
// residual dangerous-binding surface. v0.2 takes the REMOVAL path for the
// binding families that v0.2 has no honest granted-path implementation for:
//
//   - subprocess primitives beyond os/shell (os/execute, os/spawn,
//     os/posix-fork, os/posix-exec) — narrowed to os/shell + stax-bash as
//     the SINGLE granted exec interface
//   - file I/O (file/open, slurp, spit, file/temp, dofile) — host buffer
//     ops are the v0.2 interface; per-path-prefix grants are v0.3 territory
//   - network (net/connect, net/listen, net/accept, net/accept-loop)
//   - dynamic-module loading (native) — full RCE primitive
//   - bytecode-bearing deserialization (unmarshal) — full RCE primitive
//   - host-process termination (os/exit) — the host controls lifecycle
//
// Each removed binding is REPLACED with a panic stub that names the symbol
// and points at the threat-model document. This is observably different
// from "binding not present" (which would Janet-compile-error as "unknown
// symbol") — scripts that REFER to these symbols compile fine but PANIC
// at call time with the documented message. That preserves Janet's
// expectation that core-env symbols resolve.
//
// The stubs are uniform: each is one cfunction that calls a shared panic
// helper. The per-symbol identity comes from the symbol name passed to
// janet_def at install time and shows up in Janet's stacktrace.

fn panic_removed_subprocess(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.subprocess);
    janet.janet_panicf(
        "mast.sandbox: this subprocess primitive is REMOVED in v0.2 — " ++
            "use (os/shell ...) with `exec` capability instead. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3.",
    );
}

fn panic_removed_file_io(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.file_io);
    janet.janet_panicf(
        "mast.sandbox: file-I/O bindings are REMOVED in v0.2 — " ++
            "use host buffer operations (M-x save / append) instead. " ++
            "Per-path-prefix file capabilities are v0.3 work. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3.",
    );
}

fn panic_removed_net(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.net);
    janet.janet_panicf(
        "mast.sandbox: network bindings are REMOVED in v0.2 — " ++
            "host-bound HTTP cfunctions with explicit allowlists are v0.3 work. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3.",
    );
}

fn panic_removed_native(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.native);
    janet.janet_panicf(
        "mast.sandbox: dynamic-module loading (native) is REMOVED in v0.2 — " ++
            "loaded native modules run arbitrary C in-process and bypass every gate. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3 + §6.",
    );
}

fn panic_removed_unmarshal(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.unmarshal);
    janet.janet_panicf(
        "mast.sandbox: unmarshal is REMOVED in v0.2 — " ++
            "marshal blobs carry executable bytecode; full-RCE primitive on attacker-controlled input. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3 + §4 #6.",
    );
}

fn panic_removed_exit(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.exit);
    janet.janet_panicf(
        "mast.sandbox: os/exit is REMOVED in v0.2 — " ++
            "the host controls process lifecycle. Use `M-x exit` from the REPL. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3.",
    );
}

fn panic_removed_dofile(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.dofile);
    janet.janet_panicf(
        "mast.sandbox: dofile is REMOVED in v0.2 — " ++
            "combines unguarded file read with eval; load scripts via init.janet only. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3.",
    );
}

fn panic_removed_env(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.env);
    janet.janet_panicf(
        "mast.sandbox: environment-variable bindings are REMOVED in v0.2.1 — " ++
            "env vars routinely carry secrets (TOKEN_*, AWS_*, ANTHROPIC_API_KEY); " ++
            "no script-side granted path. v0.3 may add a host-bound allowlisted " ++
            "(env/get \"KEY_NAME\") with explicit per-key grants. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3 + §6 #6.",
    );
}

fn panic_removed_fs_ancillary(argc: i32, argv: [*c]janet.Janet) callconv(.c) janet.Janet {
    _ = argc;
    _ = argv;
    observe(.fs_ancillary);
    janet.janet_panicf(
        "mast.sandbox: ancillary filesystem-metadata bindings are REMOVED in v0.2.1 — " ++
            "directory enumeration / stat / mkdir / rm / rename / chmod / symlink " ++
            "give partial visibility and mutation without going through the primary " ++
            "read/write path that v0.2 already removed. v0.3 will add per-path-prefix " ++
            "fs_read / fs_write capability gating. " ++
            "See docs/SANDBOX_THREAT_MODEL.md §3 + §6 #7.",
    );
}

/// The static list of removals. Each entry: (Janet symbol, panic stub,
/// short docstring shown by Janet's `(doc ...)`). Adding to this list is
/// a single-line change; the test below iterates the same list to prove
/// every entry actually panics from Janet.
pub const RemovedBinding = struct {
    sym: [*:0]const u8,
    stub: *const fn (i32, [*c]janet.Janet) callconv(.c) janet.Janet,
    doc: [*:0]const u8,
};

pub const REMOVED_BINDINGS = [_]RemovedBinding{
    // Subprocess primitives beyond os/shell — narrowed surface.
    .{ .sym = "os/execute", .stub = panic_removed_subprocess, .doc = "mast-sandbox: REMOVED. Use (os/shell ...) + `exec` cap." },
    .{ .sym = "os/spawn", .stub = panic_removed_subprocess, .doc = "mast-sandbox: REMOVED. Use (os/shell ...) + `exec` cap." },
    .{ .sym = "os/posix-fork", .stub = panic_removed_subprocess, .doc = "mast-sandbox: REMOVED. Use (os/shell ...) + `exec` cap." },
    .{ .sym = "os/posix-exec", .stub = panic_removed_subprocess, .doc = "mast-sandbox: REMOVED. Use (os/shell ...) + `exec` cap." },

    // File I/O — host buffer ops are the v0.2 interface.
    .{ .sym = "file/open", .stub = panic_removed_file_io, .doc = "mast-sandbox: REMOVED. Use host buffer ops." },
    .{ .sym = "file/temp", .stub = panic_removed_file_io, .doc = "mast-sandbox: REMOVED. Use host buffer ops." },
    .{ .sym = "slurp", .stub = panic_removed_file_io, .doc = "mast-sandbox: REMOVED. Use host buffer ops." },
    .{ .sym = "spit", .stub = panic_removed_file_io, .doc = "mast-sandbox: REMOVED. Use host buffer ops." },
    .{ .sym = "dofile", .stub = panic_removed_dofile, .doc = "mast-sandbox: REMOVED. Load via init.janet." },

    // Network — no granted path in v0.2.
    .{ .sym = "net/connect", .stub = panic_removed_net, .doc = "mast-sandbox: REMOVED in v0.2." },
    .{ .sym = "net/listen", .stub = panic_removed_net, .doc = "mast-sandbox: REMOVED in v0.2." },
    .{ .sym = "net/accept", .stub = panic_removed_net, .doc = "mast-sandbox: REMOVED in v0.2." },
    .{ .sym = "net/accept-loop", .stub = panic_removed_net, .doc = "mast-sandbox: REMOVED in v0.2." },

    // Dynamic-module loading + bytecode unmarshal + host termination.
    .{ .sym = "native", .stub = panic_removed_native, .doc = "mast-sandbox: REMOVED in v0.2." },
    .{ .sym = "unmarshal", .stub = panic_removed_unmarshal, .doc = "mast-sandbox: REMOVED in v0.2." },
    .{ .sym = "os/exit", .stub = panic_removed_exit, .doc = "mast-sandbox: REMOVED in v0.2." },

    // v0.2.1 (2026-05-19) — residual #6 closure: environment-variable bindings.
    // Env vars routinely carry secrets; no script-side granted path is honest in v0.2.
    .{ .sym = "os/getenv", .stub = panic_removed_env, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/setenv", .stub = panic_removed_env, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/environ", .stub = panic_removed_env, .doc = "mast-sandbox: REMOVED in v0.2.1." },

    // v0.2.1 (2026-05-19) — residual #7 closure: ancillary filesystem-metadata
    // bindings. Lower blast than file/open + slurp + spit (no content read or
    // large write), but a Janet script can still enumerate the user's home
    // directory or chmod 777 a file. Removed in v0.2.1; v0.3 path-prefix
    // capabilities will reinstate granted paths.
    .{ .sym = "os/stat", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/lstat", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/dir", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/realpath", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/readlink", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/mkdir", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/rmdir", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/rm", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/rename", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/touch", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/symlink", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
    .{ .sym = "os/chmod", .stub = panic_removed_fs_ancillary, .doc = "mast-sandbox: REMOVED in v0.2.1." },
};

// ─── Application ────────────────────────────────────────────────────────

/// Install the gated wrappers over the supplied env. MUST be called after
/// `janet_core_env` and BEFORE any user code runs. Returns the number of
/// replaced bindings (gated + removed); callers SHOULD assert this matches
/// `1 + REMOVED_BINDINGS.len` so that a future Janet upgrade that renames
/// any of these symbols is caught loudly at startup.
pub fn applyDefaultDeny(env: *janet.JanetTable) usize {
    var replaced: usize = 0;

    // Replace os/shell with the capability-gated wrapper. We use janet_def
    // so the binding lives in the same shape Janet's own JANET_CORE_REG
    // produces (env[symbol] is a sub-table with :value key, not the raw
    // cfunction). A bare janet_table_put would install the wrong shape and
    // the compiler would report "unknown symbol".
    janet.janet_def(
        env,
        "os/shell",
        janet.janet_wrap_cfunction(gated_os_shell),
        "mast-sandbox: capability-gated os/shell — requires `exec`.",
    );
    replaced += 1;

    // Replace every entry in REMOVED_BINDINGS with its panic stub. The
    // honest closure for "wrap or remove" per docs/SANDBOX_THREAT_MODEL.md
    // §6 — these symbols still resolve (so referencing them compiles), but
    // calling them panics with a documented message.
    inline for (REMOVED_BINDINGS) |rb| {
        janet.janet_def(
            env,
            rb.sym,
            janet.janet_wrap_cfunction(rb.stub),
            rb.doc,
        );
        replaced += 1;
    }

    return replaced;
}

/// Grant a capability to the live sandbox. Called by the host when a
/// script is loaded with an explicit capability manifest. v1 has no
/// per-script scoping — granting is process-global until revoked.
pub fn grant(cap: Capability) void {
    g_sandbox.grant(cap);
}

/// Revoke all capabilities. Returns the sandbox to default-deny.
pub fn revokeAll() void {
    g_sandbox = .{ .bits = 0 };
}

// ─── Strict-mode env-var parsing ────────────────────────────────────────
//
// `MAST_SANDBOX_STRICT` suppresses the host's v1 auto-grant of `exec` so
// the production binary exhibits the same default-deny posture proved by
// the unit tests on a fresh VM. The parser accepts case-insensitive
// "1" / "true" / "yes" / "on" as truthy; everything else (including the
// empty string, "0", "false", "no", "off", garbage) is falsy. Unset is
// also falsy — main.zig handles `getenv == null` upstream of this call.
//
// Living in sandbox.zig (rather than main.zig) so the unit test target
// can reach it without dragging the main binary into a test module.

pub fn strictModeFromEnv(val: []const u8) bool {
    if (val.len == 0) return false;
    if (eqAsciiCI(val, "1")) return true;
    if (eqAsciiCI(val, "true")) return true;
    if (eqAsciiCI(val, "yes")) return true;
    if (eqAsciiCI(val, "on")) return true;
    return false;
}

fn eqAsciiCI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const ca = a[i];
        const cb = b[i];
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// These tests stand up a real Janet VM, install the gated wrappers,
// and verify the deny / allow behavior. They're the load-bearing proof
// that the capability model works end-to-end on at least one binding.

test "default-deny: os/shell panics when exec capability is absent" {
    if (janet.janet_init() != 0) return error.JanetInitFailed;
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null) orelse return error.NoCoreEnv;

    revokeAll();
    const n = applyDefaultDeny(env);
    try std.testing.expect(n >= 1);

    // (os/shell "true") — should panic because cap.exec is not granted.
    // janet_dostring returns a non-zero status on panic.
    const src = "(os/shell \"true\")";
    var out: janet.Janet = undefined;
    const status = janet.janet_dostring(env, src.ptr, "deny-test", &out);
    try std.testing.expect(status != 0);
}

test "grant: os/shell succeeds when exec capability is granted" {
    if (janet.janet_init() != 0) return error.JanetInitFailed;
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null) orelse return error.NoCoreEnv;

    revokeAll();
    const n = applyDefaultDeny(env);
    try std.testing.expect(n >= 1);

    grant(.exec);

    // (os/shell "true") — should succeed and return exit status 0.
    const src = "(os/shell \"true\")";
    var out: janet.Janet = undefined;
    const status = janet.janet_dostring(env, src.ptr, "grant-test", &out);
    try std.testing.expectEqual(@as(c_int, 0), status);

    // Clean up so we don't leak grant state across tests.
    revokeAll();
}

test "gated_stax_bash: argc=1 succeeds; argc=0 / argc=2 panic (kills mutant M04)" {
    // Mutation testing surfaced that `argc != 1 -> argc == 1` slipped
    // through: no existing test called gated_stax_bash with the wrong
    // number of arguments. This pins all three relevant argcs.
    if (janet.janet_init() != 0) return error.JanetInitFailed;
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null) orelse return error.NoCoreEnv;

    revokeAll();
    _ = applyDefaultDeny(env);

    // Register gated_stax_bash exactly as main.zig does at startup.
    janet.janet_def(
        env,
        "stax-bash",
        janet.janet_wrap_cfunction(gated_stax_bash),
        "mast-sandbox: capability-gated stax-bash — requires `exec`.",
    );
    grant(.exec);
    defer revokeAll();

    // (stax-bash "true") — argc == 1, must succeed.
    {
        const src = "(stax-bash \"true\")";
        var out: janet.Janet = undefined;
        const status = janet.janet_dostring(env, src.ptr, "stax-bash-argc1", &out);
        try std.testing.expectEqual(@as(c_int, 0), status);
    }

    // (stax-bash) — argc == 0, must panic.
    {
        const src = "(stax-bash)";
        var out: janet.Janet = undefined;
        const status = janet.janet_dostring(env, src.ptr, "stax-bash-argc0", &out);
        try std.testing.expect(status != 0);
    }

    // (stax-bash "a" "b") — argc == 2, must panic.
    {
        const src = "(stax-bash \"a\" \"b\")";
        var out: janet.Janet = undefined;
        const status = janet.janet_dostring(env, src.ptr, "stax-bash-argc2", &out);
        try std.testing.expect(status != 0);
    }
}

test "capability set: grant / has / revokeAll behave correctly" {
    var caps: CapabilitySet = .empty();
    try std.testing.expect(!caps.has(.exec));
    caps.grant(.exec);
    try std.testing.expect(caps.has(.exec));
    try std.testing.expect(!caps.has(.fs_write));
    caps.grant(.fs_write);
    try std.testing.expect(caps.has(.exec));
    try std.testing.expect(caps.has(.fs_write));
}

test "eqAsciiCI handles every A-Z boundary (caught by mutation testing 2026-05-14)" {
    // Mutation testing surfaced that ca >= 'A' -> ca > 'A' slipped through:
    // none of the truthy/falsy keywords contain a capital 'A' as a letter
    // that needs lowercasing, so the off-by-one at the bottom of the A-Z
    // range was observationally invisible. This test pins the boundary
    // by exercising every single A-Z letter as the leading character.
    try std.testing.expect(eqAsciiCI("A", "a"));
    try std.testing.expect(eqAsciiCI("B", "b"));
    try std.testing.expect(eqAsciiCI("Z", "z"));
    // And the boundary in the other direction (lowercase reaches uppercase):
    try std.testing.expect(eqAsciiCI("a", "A"));
    try std.testing.expect(eqAsciiCI("z", "Z"));
    // And mixed-case sequences exercising every A-Z position:
    try std.testing.expect(eqAsciiCI("AbCdEf", "aBcDeF"));
    try std.testing.expect(eqAsciiCI("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"));
    // Non-letters must NOT be munged:
    try std.testing.expect(eqAsciiCI("@", "@")); // ASCII just before 'A'
    try std.testing.expect(!eqAsciiCI("@", "`")); // ASCII just before 'a'; not equal
    try std.testing.expect(eqAsciiCI("[", "[")); // ASCII just after 'Z'
    try std.testing.expect(!eqAsciiCI("[", "{")); // ASCII just after 'z'; not equal
}

test "G2 closure: every REMOVED_BINDINGS entry panics from Janet" {
    // The load-bearing test for G2. Iterates the SAME static list that
    // applyDefaultDeny uses, so the test and the install path can never
    // drift. Each removed symbol is invoked from Janet; the test asserts
    // janet_dostring returned non-zero (i.e. our panic propagated).
    //
    // Per-symbol invocation forms chosen to exercise the call path with
    // the minimum number of arguments Janet's parser will accept. We don't
    // care that the args are semantically valid — the gate fires BEFORE
    // Janet's argument validation.
    if (janet.janet_init() != 0) return error.JanetInitFailed;
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null) orelse return error.NoCoreEnv;

    revokeAll();
    _ = applyDefaultDeny(env);

    // Grant exec — this MUST NOT bypass the removed-binding panics, since
    // those bindings do not consult any capability. Granting all caps and
    // still seeing the panic is stronger than testing under deny.
    grant(.exec);
    grant(.fs_read);
    grant(.fs_write);
    grant(.net_connect);
    grant(.net_listen);
    grant(.dynamic_modules);
    grant(.unmarshal);
    grant(.process_exit);
    defer revokeAll();

    // Invocation forms — one per removed symbol. Strings are chosen to be
    // syntactically valid Janet so the parser accepts them; the call still
    // panics at our stub before any underlying syscall.
    const Invocation = struct { sym: []const u8, src: [:0]const u8 };
    const invocations = [_]Invocation{
        .{ .sym = "os/execute", .src = "(os/execute [\"true\"] :p)" },
        .{ .sym = "os/spawn", .src = "(os/spawn [\"true\"])" },
        .{ .sym = "os/posix-fork", .src = "(os/posix-fork)" },
        .{ .sym = "os/posix-exec", .src = "(os/posix-exec [\"true\"])" },
        .{ .sym = "file/open", .src = "(file/open \"/tmp/x\" :r)" },
        .{ .sym = "file/temp", .src = "(file/temp)" },
        .{ .sym = "slurp", .src = "(slurp \"/etc/hostname\")" },
        .{ .sym = "spit", .src = "(spit \"/tmp/pwn\" \"x\")" },
        .{ .sym = "dofile", .src = "(dofile \"/etc/hostname\")" },
        .{ .sym = "net/connect", .src = "(net/connect \"127.0.0.1\" \"22\")" },
        .{ .sym = "net/listen", .src = "(net/listen \"127.0.0.1\" \"0\")" },
        .{ .sym = "net/accept", .src = "(net/accept nil)" },
        .{ .sym = "net/accept-loop", .src = "(net/accept-loop nil (fn [c] nil))" },
        .{ .sym = "native", .src = "(native \"/nonexistent.so\")" },
        .{ .sym = "unmarshal", .src = "(unmarshal @\"x\")" },
        .{ .sym = "os/exit", .src = "(os/exit 0)" },
        // v0.2.1 — env-var residual #6
        .{ .sym = "os/getenv", .src = "(os/getenv \"HOME\")" },
        .{ .sym = "os/setenv", .src = "(os/setenv \"X\" \"y\")" },
        .{ .sym = "os/environ", .src = "(os/environ)" },
        // v0.2.1 — ancillary fs residual #7
        .{ .sym = "os/stat", .src = "(os/stat \"/etc/hostname\")" },
        .{ .sym = "os/lstat", .src = "(os/lstat \"/etc/hostname\")" },
        .{ .sym = "os/dir", .src = "(os/dir \"/tmp\")" },
        .{ .sym = "os/realpath", .src = "(os/realpath \"/etc\")" },
        .{ .sym = "os/readlink", .src = "(os/readlink \"/etc/hostname\")" },
        .{ .sym = "os/mkdir", .src = "(os/mkdir \"/tmp/mast-test-mkdir\")" },
        .{ .sym = "os/rmdir", .src = "(os/rmdir \"/tmp/mast-test-rmdir\")" },
        .{ .sym = "os/rm", .src = "(os/rm \"/tmp/mast-test-rm\")" },
        .{ .sym = "os/rename", .src = "(os/rename \"/tmp/a\" \"/tmp/b\")" },
        .{ .sym = "os/touch", .src = "(os/touch \"/tmp/mast-test-touch\")" },
        .{ .sym = "os/symlink", .src = "(os/symlink \"/tmp/x\" \"/tmp/y\")" },
        .{ .sym = "os/chmod", .src = "(os/chmod \"/tmp/x\" 8r777)" },
    };

    // The static list and the test list MUST cover the same set. If
    // REMOVED_BINDINGS grows, this assertion forces the test to grow too.
    try std.testing.expectEqual(REMOVED_BINDINGS.len, invocations.len);

    for (invocations) |inv| {
        var out: janet.Janet = undefined;
        const status = janet.janet_dostring(env, inv.src.ptr, "g2-removal-test", &out);
        if (status == 0) {
            std.debug.print("G2 LEAK: {s} did not panic — call returned status 0\n", .{inv.sym});
            return error.RemovedBindingDidNotPanic;
        }
    }
}

test "deny observer fires for both exec-gated denies and removed-binding panics" {
    if (janet.janet_init() != 0) return error.JanetInitFailed;
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null) orelse return error.NoCoreEnv;

    revokeAll();
    _ = applyDefaultDeny(env);

    // Capture every observed category via a static counter array.
    const Probe = struct {
        var counts: [@typeInfo(DenyCategory).@"enum".fields.len]u32 = .{0} ** @typeInfo(DenyCategory).@"enum".fields.len;
        fn observer(cat: DenyCategory) void {
            counts[@intFromEnum(cat)] += 1;
        }
        fn reset() void {
            for (&counts) |*c| c.* = 0;
        }
    };
    Probe.reset();
    g_deny_observer = &Probe.observer;
    defer g_deny_observer = null;

    // Exec-gated path: os/shell without exec capability.
    {
        const src = "(os/shell \"true\")";
        var out: janet.Janet = undefined;
        _ = janet.janet_dostring(env, src.ptr, "obs-exec", &out);
    }
    try std.testing.expectEqual(@as(u32, 1), Probe.counts[@intFromEnum(DenyCategory.exec_gated)]);

    // Removed-binding path: os/execute should fire .subprocess.
    {
        const src = "(os/execute [\"true\"] :p)";
        var out: janet.Janet = undefined;
        _ = janet.janet_dostring(env, src.ptr, "obs-subprocess", &out);
    }
    try std.testing.expectEqual(@as(u32, 1), Probe.counts[@intFromEnum(DenyCategory.subprocess)]);

    // file-io path
    {
        const src = "(slurp \"/etc/hostname\")";
        var out: janet.Janet = undefined;
        _ = janet.janet_dostring(env, src.ptr, "obs-fileio", &out);
    }
    try std.testing.expectEqual(@as(u32, 1), Probe.counts[@intFromEnum(DenyCategory.file_io)]);

    // env path
    {
        const src = "(os/getenv \"HOME\")";
        var out: janet.Janet = undefined;
        _ = janet.janet_dostring(env, src.ptr, "obs-env", &out);
    }
    try std.testing.expectEqual(@as(u32, 1), Probe.counts[@intFromEnum(DenyCategory.env)]);

    // fs-ancillary path
    {
        const src = "(os/dir \"/tmp\")";
        var out: janet.Janet = undefined;
        _ = janet.janet_dostring(env, src.ptr, "obs-fsanc", &out);
    }
    try std.testing.expectEqual(@as(u32, 1), Probe.counts[@intFromEnum(DenyCategory.fs_ancillary)]);
}

test "G2 closure: applyDefaultDeny returns the expected number of replacements" {
    // Catches the silent-drift mutant: if REMOVED_BINDINGS is extended
    // but the install loop is broken (e.g. early return), the count
    // mismatch trips this test.
    if (janet.janet_init() != 0) return error.JanetInitFailed;
    defer janet.janet_deinit();

    const env = janet.janet_core_env(null) orelse return error.NoCoreEnv;

    revokeAll();
    const n = applyDefaultDeny(env);
    try std.testing.expectEqual(1 + REMOVED_BINDINGS.len, n);
}

test "MAST_SANDBOX_STRICT env parsing: truthy / falsy / case-insensitive" {
    // Truthy values
    try std.testing.expect(strictModeFromEnv("1"));
    try std.testing.expect(strictModeFromEnv("true"));
    try std.testing.expect(strictModeFromEnv("TRUE"));
    try std.testing.expect(strictModeFromEnv("True"));
    try std.testing.expect(strictModeFromEnv("yes"));
    try std.testing.expect(strictModeFromEnv("YES"));
    try std.testing.expect(strictModeFromEnv("on"));
    try std.testing.expect(strictModeFromEnv("ON"));

    // Falsy values — empty string, explicit "off"-style words, garbage
    try std.testing.expect(!strictModeFromEnv(""));
    try std.testing.expect(!strictModeFromEnv("0"));
    try std.testing.expect(!strictModeFromEnv("false"));
    try std.testing.expect(!strictModeFromEnv("False"));
    try std.testing.expect(!strictModeFromEnv("no"));
    try std.testing.expect(!strictModeFromEnv("off"));
    try std.testing.expect(!strictModeFromEnv("OFF"));
    try std.testing.expect(!strictModeFromEnv("nope"));
    try std.testing.expect(!strictModeFromEnv("2"));
    try std.testing.expect(!strictModeFromEnv("yes please"));
    try std.testing.expect(!strictModeFromEnv(" 1"));
    try std.testing.expect(!strictModeFromEnv("1 "));
}
