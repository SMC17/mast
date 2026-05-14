# mast — Sandbox Threat Model & Capability Vocabulary

Status: 2026-05-14. Proof level: **audited** (this document) + **unit-tested**
(the one currently-gated binding, `os/shell`).

This document IS the audit. The persona is the assistant working as a senior
systems / security engineer; no external review claimed. Self-applied,
hostile-reviewer voice. The artifact stands or falls on the analysis below,
not on whose name signs it.

The corresponding code lives in `src/sandbox.zig`, wired into the main
binary by `src/main.zig` between `janet_core_env` and the first user-script
evaluation.

---

## 1. What this document is and is NOT

**This document IS:**

- The capability vocabulary mast will gate against, with default-deny
  semantics named at the type level.
- The asset inventory the gates protect (filesystem, exec, network,
  environment, sibling buffers, host process lifecycle).
- An honest scoping of what the v1 slice enforces and what it leaves
  open.

**This document is NOT:**

- A claim that mast is sandboxed. It is not. v1 ships a *first slice* of
  a capability model — one (1) Janet stdlib binding is wrapped, plus the
  host-bound `stax-bash` cfunction. The other dangerous Janet stdlib
  bindings (file/, net/, os/exit, os/execute, os/spawn, native, etc.)
  are NOT wrapped in v1.
- A guarantee against in-process exploitation. Janet runs in the same
  address space as mast and shares the libc heap; a Janet-side
  type-confusion or buffer-overrun in Janet itself bypasses every gate
  in this document. Janet's hardening is upstream's concern, not ours.
- A defense against denial-of-service. A pathological Janet script can
  trivially exhaust CPU, RAM, or fd's. v1 has no quotas.
- A defense against the host. Anyone with write access to mast's source
  tree or its installed binary can disable every gate. The TCB is the
  binary + libc + the Janet runtime. Capability checks only mediate
  Janet-reachable code paths against the running host.

---

## 2. Trust boundary

```
┌────────────────────────────────────────────────────────────────┐
│  mast process                                                  │
│                                                                │
│  ┌──────────────────────────────────────────────┐              │
│  │  HOST (trusted)                              │              │
│  │  - main.zig, buffer.zig, audit.zig,          │              │
│  │    sandbox.zig                               │              │
│  │  - libc, kernel syscalls                     │              │
│  │  - Janet runtime (vendored, MIT)             │              │
│  └─────────┬────────────────────────────────────┘              │
│            │                                                   │
│            │ janet_dostring / janet_call                       │
│            │ ── BOUNDARY ──                                    │
│            ▼                                                   │
│  ┌──────────────────────────────────────────────┐              │
│  │  JANET SCRIPTS (untrusted by default)        │              │
│  │  - init.janet                                │              │
│  │  - REPL-typed forms                          │              │
│  │  - module-loaded code (future)               │              │
│  │  - agent-injected buffers eval'd as Janet    │              │
│  │    (future, multi-agent integration)         │              │
│  └──────────────────────────────────────────────┘              │
└────────────────────────────────────────────────────────────────┘
```

**Adversarial assumption.** A Janet script can call any binding present
in the env and any Janet stdlib function reachable through that env. The
threat model assumes the script is adversarial: it will probe for
unwrapped dangerous functions, attempt to re-resolve symbols via
`module/find` or `dyn`, attempt to load modules that pull in dangerous
bindings, and call any host-defined cfunction that lacks an explicit
capability check. **A binding that exists without a gate is implicitly
granted to every script.**

The host is part of the TCB. Host code (main.zig, buffer.zig, etc.) can
call libc directly and is NOT subject to the capability check — capabilities
mediate only the *Janet → host* call boundary.

---

## 3. Capability vocabulary

The set of capabilities enumerated in `src/sandbox.zig` is the
type-level commitment. Adding a new capability is a deliberate design
act, not an emergent feature.

| Capability        | Gates (intended)                                                                 | Gated today |
|-------------------|----------------------------------------------------------------------------------|-------------|
| `exec`            | `os/execute`, `os/spawn`, `os/shell`, `os/posix-fork`, `os/posix-exec`, `stax-bash` | `os/shell` + `stax-bash` only |
| `fs_read`         | `file/open` (r-mode), `slurp`, `os/stat`, `os/lstat`, `os/dir`, `os/readlink`, `dofile`, `os/realpath` | none |
| `fs_write`        | `file/open` (w-mode), `spit`, `os/mkdir`, `os/rmdir`, `os/rm`, `os/rename`, `os/touch`, `os/symlink`, `os/link`, `os/chmod` | none |
| `net_connect`     | `net/connect`                                                                    | none |
| `net_listen`      | `net/listen`, `net/accept`, `net/accept-loop`                                    | none |
| `env_read`        | `os/getenv`, `os/environ`                                                        | none |
| `env_write`       | `os/setenv`                                                                      | none |
| `dynamic_modules` | `native`, `import`-of-native, `module/load`-of-shared-object                     | none |
| `ffi`             | `ffi/native`, `ffi/lookup`, `ffi/signature`, `ffi/jitfn`                         | none |
| `unmarshal`       | `unmarshal`                                                                      | none |
| `process_exit`    | `os/exit`                                                                        | none |

**Default: every capability denied.** The host explicitly grants
capabilities by calling `sandbox.grant(cap)`. There is no Janet-facing
form to grant or revoke. v1 grants are process-global; v2 will scope
them per-environment so multi-script futures get fresh, default-deny
sets.

### Enforcement point

The gate sits at the **C-binding boundary**. Each gated cfunction
checks `g_sandbox.has(cap)` as its first instruction and `janet_panicf`s
if absent. The panic propagates as a `JANET_SIGNAL_ERROR` and is
trappable by Janet's own `try` form. v1's host policy treats a denied
operation as a non-fatal error in the REPL session; the audit log
records the deny via the panic message in the standard Janet stacktrace.

Why binding-level wrappers instead of Janet's built-in
`janet_sandbox(flags)`? Janet's primitive is a **one-way, process-global
bitset**. Once a flag is set, no Janet code can ever invoke the gated
operation for the lifetime of the process. This is too coarse for
mast's threat model, which needs per-script granularity for the
multi-agent future. The binding-level wrapper is per-environment, so a
future v2 can hand different envs different cap sets.

---

## 4. Asset inventory — what the host has that scripts must NOT have

Listed in declining order of blast radius.

1. **Subprocess execution.** `os/shell`, `os/execute`, `os/spawn`,
   `posix-fork`, `posix-exec` plus the host-bound `stax-bash`. Any of
   these grants the script *full host privilege* via a child process.
   Highest priority to gate. Gated today: `os/shell` + `stax-bash`.
   Residual: `os/execute`, `os/spawn`, `os/posix-fork`, `os/posix-exec`.
2. **Filesystem write.** `file/open` w-mode, `spit`, `os/rm`, `os/mkdir`,
   `os/rename`, `os/symlink`, `os/chmod`. Lets a script tamper with mast's
   own config, audit logs, or any user file. Residual: not gated.
3. **Filesystem read.** `file/open` r-mode, `slurp`, `os/dir`, `os/stat`.
   Exfiltrates secrets (SSH keys, browser history, ~/.config/*). Residual.
4. **Network connect.** `net/connect`. Exfiltrates anything readable to
   any host the script can DNS-resolve. Residual.
5. **Module loading.** `native` (loads .so/.dylib), `import` of a path-resolvable
   module. A loaded native module runs arbitrary C in-process and
   bypasses every gate in this document. Residual.
6. **Unmarshal of attacker-controlled bytes.** Janet marshalled blobs
   can carry executable bytecode; `unmarshal` is a known full-RCE primitive
   if the input is attacker-controlled. Residual.
7. **Process exit.** `os/exit` terminates the host. Lower blast-radius
   (data-loss bounded to the unsaved buffer), but it lets a script
   trivially DoS the editor. Residual.
8. **Environment.** `os/getenv` reads env vars (TOKEN_* leaks). `os/setenv`
   mutates the env for any future child. Residual.
9. **Sibling buffers (mast-specific).** Once multi-buffer lands (v2),
   the `(buffer-name)` / `(buffer-size)` bindings will need cap-gating so
   a script attached to buffer A can't read buffer B without an explicit
   grant. v1 is single-buffer, so this is theoretical today.

---

## 5. What v1 enforces (the worked example)

`src/sandbox.zig::applyDefaultDeny` does ONE replacement:

```
env["os/shell"] = gated_os_shell
```

`gated_os_shell` checks `Capability.exec` before delegating to
`libc.system` (not to Janet's original `os/shell` — we reimplement the
shell-out so the gate doesn't depend on Janet's internal unwrap macros
which are nanboxing-dependent and not @cImport-friendly).

`src/main.zig` registers the host's `stax-bash` cfunction against
`sandbox.gated_stax_bash` (which performs the identical cap check) so
the parallel host-bound shell-out path respects the same posture.

Two tests in `src/sandbox.zig`:

- `"default-deny: os/shell panics when exec capability is absent"` —
  stands up a fresh Janet VM, applies the default-deny, evaluates
  `(os/shell "true")`, asserts `janet_dostring` returned non-zero
  status (i.e. Janet's panic propagated).
- `"grant: os/shell succeeds when exec capability is granted"` — same
  setup, but grants `Capability.exec` before evaluating, asserts
  status == 0.

Both pass on Linux x86_64 as of 2026-05-14. They are wired into
`zig build test` as a second test target with the full Janet runtime
linked in.

### v1 host policy

The mast binary grants `Capability.exec` unconditionally at startup
because mast's own first-party verbs (`M-x stax-search`,
`M-x stax-dashboard`, `M-x stax-hunger`) shell out via `stax-bash`,
AND fall-through Janet expressions in the REPL share the same env.
Without this grant the out-of-the-box experience breaks.

**This is a policy choice, not a mechanism limitation.** The mechanism
is the binding-level gate, proven by the unit tests against a fresh,
no-grant env. v2 will scope grants per-script-load so a runtime-loaded
module gets a fresh, default-deny capability set even though init.janet
(loaded under host policy) has the `exec` cap.

---

## 6. What v1 does NOT defend against — explicit residual gaps

A senior reviewer will flag every one of these. We name them rather
than hide them.

1. **Unwrapped subprocess primitives.** `os/execute`, `os/spawn`,
   `os/posix-fork`, `os/posix-exec` remain bare. A script can execute
   arbitrary commands by typing `(os/execute ["/bin/sh" "-c" "..."] :p)`
   and the gate on `os/shell` is silently bypassed. Fixing this is the
   single highest-leverage next move and is intentionally scoped to v2.
2. **No file/ or net/ gating.** Every filesystem and network binding is
   available unmediated. A script can `slurp` any readable file and
   `(net/connect ...)` anywhere.
3. **No `native` or `import` gating.** A script can load a shared library
   that bypasses every gate. v2 will gate `dynamic_modules`.
4. **No `unmarshal` gating.** Marshal blobs can carry bytecode. v2.
5. **No `os/exit` gating.** A script can terminate the host. v2.
6. **No environment-variable gating.** `(os/getenv "AWS_SECRET_ACCESS_KEY")`
   succeeds today. v2.
7. **No resource quotas.** A pathological Janet script can spin a tight
   `(while true)` loop, fill the heap with a `(repeat 1e9 ...)`, or open
   thousands of fds. v3 territory; requires a Janet fiber-level interrupt
   primitive we have not designed yet.
8. **No audit-log routing of deny events.** Today's gated wrapper
   `janet_panicf`s on deny; the panic message goes through Janet's normal
   stacktrace path to stderr. It does NOT route through `SessionAudit`.
   v2 will add a `sandbox-deny` event-type to the audit log.
9. **No defense against host-side `cfunction` regression.** Any new
   `janet_def`-registered cfunction in `main.zig` that calls a dangerous
   syscall WITHOUT consulting `g_sandbox` re-opens the gap. The
   convention is documented in `sandbox.zig` (see `gated_stax_bash`
   pattern), but it is convention, not a compile-time check. A static
   audit pass over `janet_def` registrations is a v1.5 follow-up.
10. **No defense against Janet itself.** A Janet runtime bug
    (out-of-bounds read, type confusion in `unmarshal`) gives an attacker
    everything. Tracking Janet upstream security advisories is operational
    discipline, not engineering work.
11. **No defense against host-process privilege.** mast runs as the user.
    If the user is root, every gate above is moot — root can also bypass
    `chmod` permissions on the user's own files. Run mast unprivileged.
12. **Single-process grant scoping.** Today `sandbox.grant` is
    process-global. Two separate Janet environments in the same process
    share the same capability set. v2 keys the set off the
    `JanetTable*`.

---

## 7. Out of scope for v1

The following are intentionally deferred. Listing them here so they
don't get smuggled in as v1 claims:

- **Per-path capability granularity.** Today `fs_read` is binary on/off.
  A real capability model accepts a path-prefix argument
  (`fs_read[/home/stax/codex/**]`). v2.
- **Argv-pattern granularity on `exec`.** Today `exec` either lets you
  run any command or nothing. v2 will accept an allowlist of regex / argv
  patterns.
- **Capability revocation mid-session.** Today `revokeAll()` exists for
  tests; production code never calls it. v2 will surface
  `M-x sandbox-revoke <cap>` so an operator can downgrade a running
  session.
- **Capability manifest in init.janet.** v2 will let `init.janet` declare
  its required caps in a top-of-file `(use-capabilities :exec :fs_read)`
  form; the host parses the form before evaluating the rest of the file
  and grants only the named caps.
- **Cross-environment isolation.** v2 will allow multiple Janet envs in
  one mast process with separate cap sets, enabling the multi-agent
  surface where a "research agent" buffer gets `fs_read` but no
  `net_connect` and an "exfil-sensitive" buffer gets neither.
- **Audit log of every cap check.** v2 will log every cap consult, not
  just denies, behind a `MAST_SANDBOX_VERBOSE` env var.

---

## 8. Known limitations and residual risk

- **Janet `cfunction` callbacks.** If the host hands a Janet function a
  callback that the host later invokes, the host invocation runs WITHOUT
  going through any gate. No such pattern exists in main.zig today;
  introducing one would need to push capability state into the callback
  frame.
- **Garbage-collector denial-of-service.** A Janet script can construct
  a deep object graph and pin it to the GC root, exhausting RAM. No quota.
- **Janet fibers.** Janet's `ev/` fibers (lightweight green threads) can
  run with their own dyn-vars. A grant in the main fiber MAY leak into
  a `ev/go` fiber today (untested). v2 must verify or scope.
- **Compilation-time access.** Janet's compiler resolves symbols at
  compile time via `janet_resolve`. A gated cfunction is invoked at
  *call* time, not at compile time, so `(eval-string "(os/shell ...)")` —
  which compiles a fresh form — still hits our gate. Good. But macros
  that expand to a gated form *at compile time* could be a side channel
  if a macro does `(os/shell ...)` as part of macro expansion. Audit any
  host-provided macros for this.
- **Time-of-check / time-of-use (TOCTOU).** The cap set is read at the
  start of the gated wrapper, then the syscall runs. Between those two
  points, no other thread modifies the cap set (v1 is single-threaded).
  When threading enters (v2 ev/thread), this needs revisiting.

---

## 9. Falsification — what would prove this document wrong

The load-bearing claim is: *"with `Capability.exec` not granted, a Janet
script cannot run `os/shell`"*. This is falsifiable by:

```janet
# In a fresh mast session with sandbox.revokeAll() called from the host:
(os/shell "echo pwned > /tmp/pwn")
# If /tmp/pwn exists after this, the claim is false.
```

The unit test in `src/sandbox.zig` exercises exactly this path. CI
status is the public falsification check.

Falsification of the stronger claim that *"a Janet script in mast cannot
run an external command without `exec`"* is currently TRIVIAL: substitute
`os/execute` or `os/spawn` for `os/shell`. **That is the v2 gap.** Today
this document does NOT make the stronger claim.

---

## 10. References

- Janet sandbox primitive: `vendored/janet/janet.h` lines 2083–2107
  (`JANET_SANDBOX_*` bitset + `janet_sandbox()` / `janet_sandbox_assert()`).
- Janet stdlib registrations: `vendored/janet/janet.c` line 24884
  (`os/`), 18421 (`file/`), 21893 (`net/`), 12481 (`ev/`).
- mast capability code: `src/sandbox.zig`.
- mast wiring: `src/main.zig` between `janet_core_env` and the REPL.
- Janet's own `janet_def` shape (env entry = `{:value <cfunction> ...}`):
  `vendored/janet/janet.c` line 34162.
