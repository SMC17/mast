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

// ─── Application ────────────────────────────────────────────────────────

/// Install the gated wrappers over the supplied env. MUST be called after
/// `janet_core_env` and BEFORE any user code runs. Returns the number of
/// replaced bindings; callers SHOULD assert > 0 in tests so that a future
/// Janet upgrade that renames `os/shell` is caught.
pub fn applyDefaultDeny(env: *janet.JanetTable) usize {
    var replaced: usize = 0;

    // Replace os/shell. We use janet_def so the binding lives in the same
    // shape Janet's own JANET_CORE_REG produces (env[symbol] is a sub-table
    // with :value key, not the raw cfunction). A bare janet_table_put would
    // install the wrong shape and the compiler would report "unknown symbol".
    janet.janet_def(
        env,
        "os/shell",
        janet.janet_wrap_cfunction(gated_os_shell),
        "mast-sandbox: capability-gated os/shell — requires `exec`.",
    );
    replaced += 1;

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
