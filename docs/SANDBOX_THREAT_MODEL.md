# mast — Sandbox Threat Model & Capability Vocabulary

Status: 2026-05-19. Proof level: **audited** (this document) + **unit-tested**
(the gated bindings `os/shell` + `stax-bash`, plus every removed binding
in the static `REMOVED_BINDINGS` list — see §5) +
**posture-observable-end-to-end** in the production binary under
`MAST_SANDBOX_STRICT=1` (see §5 `MAST_SANDBOX_STRICT`).

**G2 closure 2026-05-19.** The "residual ungated Janet surface" the
original document called out — `os/execute`, `os/spawn`, `file/*`,
`net/*`, `native`, `unmarshal`, `os/exit` — is now closed via the
"removed from the embedded env" path this document already named as
valid (§6, prior wording). Each of those symbols still resolves
(Janet's compile-time symbol resolution still works), but invoking
them panics with a documented message that names the symbol and
points back here. The closure is iterated against a single static
list (`src/sandbox.zig::REMOVED_BINDINGS`), and the load-bearing
test (`G2 closure: every REMOVED_BINDINGS entry panics from Janet`)
walks the same list — adding to one without the other trips CI.

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

- A claim that mast is sandboxed in the OS-isolation sense. It is not.
  v0.2 ships a capability model where one (1) Janet stdlib binding
  (`os/shell`) plus the host-bound `stax-bash` are GATED on `exec`,
  AND the rest of the original residual surface (`os/execute`,
  `os/spawn`, `os/posix-fork`, `os/posix-exec`, `file/open`,
  `file/temp`, `slurp`, `spit`, `dofile`, `net/connect`, `net/listen`,
  `net/accept`, `net/accept-loop`, `native`, `unmarshal`, `os/exit`)
  is REMOVED from the embedded env via panic stubs. This is not a
  process-level sandbox — it is a Janet-script-level capability model
  whose mediation point is the C-binding boundary.
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

| Capability        | Gates (intended)                                                                 | Status (post-G2, 2026-05-19) |
|-------------------|----------------------------------------------------------------------------------|------------------------------|
| `exec`            | `os/execute`, `os/spawn`, `os/shell`, `os/posix-fork`, `os/posix-exec`, `stax-bash` | `os/shell` + `stax-bash` GATED on `exec`; `os/execute`, `os/spawn`, `os/posix-fork`, `os/posix-exec` REMOVED from env (narrowed surface) |
| `fs_read`         | `file/open` (r-mode), `slurp`, `os/stat`, `os/lstat`, `os/dir`, `os/readlink`, `dofile`, `os/realpath` | `file/open`, `slurp`, `file/temp`, `dofile` REMOVED; ancillary `os/stat`/`os/dir`/`os/readlink`/`os/realpath` still present (read-only metadata, lower blast; v0.3 work) |
| `fs_write`        | `file/open` (w-mode), `spit`, `os/mkdir`, `os/rmdir`, `os/rm`, `os/rename`, `os/touch`, `os/symlink`, `os/link`, `os/chmod` | `file/open` and `spit` REMOVED; ancillary `os/*` filesystem mutators still present (v0.3 work) |
| `net_connect`     | `net/connect`                                                                    | `net/connect` REMOVED |
| `net_listen`      | `net/listen`, `net/accept`, `net/accept-loop`                                    | `net/listen`, `net/accept`, `net/accept-loop` REMOVED |
| `env_read`        | `os/getenv`, `os/environ`                                                        | `os/getenv`, `os/environ` REMOVED 2026-05-19 (v0.2.1; residual #6 closure) |
| `env_write`       | `os/setenv`                                                                      | `os/setenv` REMOVED 2026-05-19 (v0.2.1; residual #6 closure) |
| `dynamic_modules` | `native`, `import`-of-native, `module/load`-of-shared-object                     | `native` REMOVED (which also blocks `import` / `module/load` of `.so` since both resolve through `native`); `.janet`-path `import` is blocked transitively because `slurp` is removed |
| `ffi`             | `ffi/native`, `ffi/lookup`, `ffi/signature`, `ffi/jitfn`                         | none today; the vendored Janet build does not compile in JANET_EV-style FFI, so this row is largely theoretical — re-audit when the build config changes |
| `unmarshal`       | `unmarshal`                                                                      | `unmarshal` REMOVED |
| `process_exit`    | `os/exit`                                                                        | `os/exit` REMOVED |

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

## 5. What v0.2 enforces

### 5.1 Gated path (`os/shell` + `stax-bash`)

`src/sandbox.zig::applyDefaultDeny` does ONE capability-gated
replacement:

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

### 5.2 Removed-from-env path (G2 closure, 2026-05-19)

`applyDefaultDeny` ALSO iterates the static `REMOVED_BINDINGS` list
and replaces each named symbol with a panic stub categorized by
removal reason (subprocess / file-io / net / native / unmarshal /
exit / dofile). The threat-model-§6-prior-wording explicitly named
"removed from the embedded env" as a valid closure path for these.
v0.2 takes it. The full list, as of 2026-05-19:

```
Subprocess (narrowed to os/shell + stax-bash):
  os/execute, os/spawn, os/posix-fork, os/posix-exec
File I/O (host buffer ops are the v0.2 interface):
  file/open, file/temp, slurp, spit, dofile
Network (host-bound HTTP allowlist deferred to v0.3):
  net/connect, net/listen, net/accept, net/accept-loop
RCE primitives (no granted path in v0.2):
  native, unmarshal
Host lifecycle:
  os/exit
```

Each panic stub names the symbol and points back at this document.

### 5.3 Tests

Eight in-source tests in `src/sandbox.zig`:

- `"default-deny: os/shell panics when exec capability is absent"`
- `"grant: os/shell succeeds when exec capability is granted"`
- `"gated_stax_bash: argc=1 succeeds; argc=0 / argc=2 panic (kills mutant M04)"`
- `"capability set: grant / has / revokeAll behave correctly"`
- `"eqAsciiCI handles every A-Z boundary (caught by mutation testing 2026-05-14)"`
- `"MAST_SANDBOX_STRICT env parsing: truthy / falsy / case-insensitive"`
- **`"G2 closure: every REMOVED_BINDINGS entry panics from Janet"`** —
  the load-bearing G2 test. Stands up a fresh Janet VM, applies the
  default-deny, GRANTS EVERY CAPABILITY (so a regression that
  accidentally re-routes removed bindings through a cap check would
  show up as a non-panic), then invokes every entry in the static
  `REMOVED_BINDINGS` list from Janet and asserts each one panics.
  Iterates the same list `applyDefaultDeny` uses, so the install
  path and the test can never drift.
- **`"G2 closure: applyDefaultDeny returns the expected number of replacements"`** —
  catches a silent-drift mutant where the install loop early-returns
  or skips entries.

All pass on Linux x86_64 as of 2026-05-19; wired into `zig build test`.

### v1 host policy

By default the mast binary grants `Capability.exec` unconditionally at
startup because mast's own first-party verbs (`M-x stax-search`,
`M-x stax-dashboard`, `M-x stax-hunger`) shell out via `stax-bash`,
AND fall-through Janet expressions in the REPL share the same env.
Without this grant the out-of-the-box experience breaks.

**This is a policy choice, not a mechanism limitation.** The mechanism
is the binding-level gate, proven by the unit tests against a fresh,
no-grant env. v2 will scope grants per-script-load so a runtime-loaded
module gets a fresh, default-deny capability set even though init.janet
(loaded under host policy) has the `exec` cap.

### `MAST_SANDBOX_STRICT` — production-binary observation of default-deny

Setting the env var `MAST_SANDBOX_STRICT` to a truthy value
(`1` / `true` / `yes` / `on`, case-insensitive) suppresses the v1
auto-grant of `exec`. The production binary then runs with the same
default-deny posture the sandbox unit tests prove on a fresh VM:

```
$ MAST_SANDBOX_STRICT=1 ./zig-out/bin/mast
mast: MAST_SANDBOX_STRICT enabled — `exec` capability NOT auto-granted. ...
M-x x (os/shell "true")
  → error: mast.sandbox: os/shell denied — capability `exec` not granted (default-deny)
```

What this moves: the claim "deny-by-default works" was previously
load-bearing on the sandbox.zig unit tests against a fresh VM. With
`MAST_SANDBOX_STRICT` available, the same claim is now observable
end-to-end against the shipped binary, exercised by
`tests/strict_mode_integration.sh` via `zig build test`. This is a
posture upgrade from **mechanism-proven (unit tests)** to
**posture-observable-end-to-end (production binary)**.

What this does NOT move: every residual gap listed in §6 below remains
present under strict mode. `os/execute`, `os/spawn`, `posix-fork`,
`posix-exec`, `file/*`, `net/*`, `native`, `unmarshal`, `os/exit` are
not gated AT ALL in v1 — a strict-mode session can still invoke any of
them. Strict mode demonstrates the gate that exists; it does not
retroactively gate the residual surface.

Parser semantics (`src/sandbox.zig::strictModeFromEnv`):

- Truthy (case-insensitive exact match): `1`, `true`, `yes`, `on`
- Falsy: empty string, `0`, `false`, `no`, `off`, anything else,
  trailing/leading whitespace included
- Unset env var: falsy (handled upstream in `main.zig::read_strict_env`)

---

## 6. What v0.2 does NOT defend against — explicit residual gaps

A senior reviewer will flag every one of these. We name them rather
than hide them. **Items #1–5 of the prior version are CLOSED by G2
(2026-05-19); the strikethroughs are kept for changelog continuity.**

1. ~~**Unwrapped subprocess primitives.** `os/execute`, `os/spawn`,
   `os/posix-fork`, `os/posix-exec` remain bare.~~ **CLOSED 2026-05-19:**
   all four are removed from the embedded env via panic stubs. Subprocess
   surface is narrowed to `os/shell` + `stax-bash`, both gated on `exec`.
2. ~~**No file/ or net/ gating.**~~ **CLOSED 2026-05-19:** `file/open`,
   `file/temp`, `slurp`, `spit`, `dofile`, `net/connect`, `net/listen`,
   `net/accept`, `net/accept-loop` removed via panic stubs. *Ancillary*
   `os/*` filesystem metadata bindings (`os/stat`, `os/dir`, `os/mkdir`,
   `os/rm`, `os/rename`, etc.) remain present — they have lower blast
   radius than the I/O primitives and are deferred to v0.3 path-prefix
   capabilities work.
3. ~~**No `native` or `import` gating.**~~ **CLOSED 2026-05-19:** `native`
   removed via panic stub. `import` and `module/load` resolve through
   `native` for `.so` modules, so the `.so` path is blocked transitively.
   The `.janet`-source path of `import`/`module/load` is blocked
   transitively because `slurp` is removed (the loader can't read the file).
4. ~~**No `unmarshal` gating.**~~ **CLOSED 2026-05-19:** `unmarshal`
   removed via panic stub. Marshal blobs cannot be deserialized from
   Janet in v0.2 at all.
5. ~~**No `os/exit` gating.**~~ **CLOSED 2026-05-19:** `os/exit` removed
   via panic stub. Host controls process lifecycle.

**Residual gaps still present in v0.2.1:**

6. ~~**No environment-variable gating.**~~ **CLOSED 2026-05-19 (v0.2.1):**
   `os/getenv`, `os/setenv`, `os/environ` removed via panic stubs.
   `(os/getenv "AWS_SECRET_ACCESS_KEY")` now panics with the documented
   removed-env message. v0.3 may add a host-bound allowlisted
   `(env/get "KEY_NAME")` cfunction with explicit per-key grants.
7. ~~**Ancillary filesystem-metadata bindings.**~~ **CLOSED 2026-05-19
   (v0.2.1):** `os/stat`, `os/lstat`, `os/dir`, `os/realpath`,
   `os/readlink`, `os/mkdir`, `os/rmdir`, `os/rm`, `os/rename`,
   `os/touch`, `os/symlink`, `os/chmod` all removed via panic stubs.
   v0.3 will reintroduce granted paths via per-path-prefix capability
   gates.
8. **No resource quotas.** A pathological Janet script can spin a tight
   `(while true)` loop, fill the heap with a `(repeat 1e9 ...)`, or open
   thousands of fds. v0.3+ territory; requires a Janet fiber-level
   interrupt primitive we have not designed yet.
9. **No audit-log routing of deny / removed-binding events.** Today's
   gated wrapper and the removed-binding panic stubs `janet_panicf` on
   trigger; the panic message goes through Janet's normal stacktrace
   path to stderr. It does NOT route through `SessionAudit`. v0.3 will
   add a `sandbox-deny` event-type to the audit log so denials are
   queryable from the session log.
10. **No defense against host-side `cfunction` regression.** Any new
    `janet_def`-registered cfunction in `main.zig` that calls a dangerous
    syscall WITHOUT consulting `g_sandbox` re-opens the gap. The
    convention is documented in `sandbox.zig` (see `gated_stax_bash`
    pattern), but it is convention, not a compile-time check. A static
    audit pass over `janet_def` registrations is a v0.3 follow-up.
11. **No defense against Janet itself.** A Janet runtime bug
    (out-of-bounds read, type confusion in `unmarshal`) gives an attacker
    everything. Tracking Janet upstream security advisories is operational
    discipline, not engineering work. (Note: `unmarshal` is removed, but
    Janet's marshal-format parser is still compiled in.)
12. **No defense against host-process privilege.** mast runs as the user.
    If the user is root, every gate above is moot — root can also bypass
    `chmod` permissions on the user's own files. Run mast unprivileged.
13. **Single-process grant scoping.** Today `sandbox.grant` is
    process-global. Two separate Janet environments in the same process
    share the same capability set. v2 keys the set off the `JanetTable*`.

---

## 7. Out of scope for v1

The following are intentionally deferred. Listing them here so they
don't get smuggled in as v1 claims:

- **Per-path capability granularity.** Today `fs_read` is binary on/off.
  A real capability model accepts a path-prefix argument
  (`fs_read[<codex-tree>/**]`). v2.
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
run an external command without `exec`"* — previously trivial via
`(os/execute ...)` — is now closed by the G2 removal. The
`G2 closure: every REMOVED_BINDINGS entry panics from Janet` test
exercises `(os/execute ...)`, `(os/spawn ...)`, `(os/posix-fork ...)`,
`(os/posix-exec ...)` directly and asserts each panics under
default-deny AND under all-caps-granted. The stronger falsification
target for v0.2 is:

```janet
# In a fresh mast session with sandbox.revokeAll() called:
(slurp "/etc/shadow")           # MUST panic with file-I/O removed-stub
(net/connect "evil.example" 80)  # MUST panic with network removed-stub
(unmarshal @"\xff\xff")          # MUST panic with unmarshal removed-stub
(os/exit 1)                      # MUST panic with os/exit removed-stub
```

If any of those returns a value instead of triggering Janet's panic,
the claim is false. The G2 closure test exercises each one.

---

## 10. References

- Janet sandbox primitive: `vendored/janet/janet.h` lines 2083–2107
  (`JANET_SANDBOX_*` bitset + `janet_sandbox()` / `janet_sandbox_assert()`).
- Janet stdlib registrations: `vendored/janet/janet.c` line 24884
  (`os/`), 18421 (`file/`), 21893 (`net/`), 12481 (`ev/`).
- mast capability code: `src/sandbox.zig`.
- mast wiring: `src/main.zig` between `janet_core_env` and the REPL.
- Strict-mode integration test: `tests/strict_mode_integration.sh`
  (5 cases, wired into `zig build test`).
- Janet's own `janet_def` shape (env entry = `{:value <cfunction> ...}`):
  `vendored/janet/janet.c` line 34162.
