# Changelog

All notable changes to `mast` will be documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Test-count drift catch — 2026-05-22

A drift-check pass surfaced a Type-I under-claim:

- **README.md** said "20/20 tests as of 2026-05-19".
- **CHANGELOG.md** carried "20/20 tests pass" in the 2026-05-19 release notes (preserved as historical record).
- **Actual** per `zig build test --summary all` on 2026-05-22: **49/49 tests passed** (Build Summary: 16/16 steps succeeded; 49/49 tests passed).

**Drift: +29 tests (+145%).** Substrate grew through the v1.3.x adversarial-review rounds (sandbox property tests, JSON injection PoC neutralization, TUI ANSI sanitization, audit-log boundary, fuzz harness, etc.) but the README's cross-system summary didn't keep up. Under-claim drift counts as Type-I.

**Fix this commit:**

- README.md line 74 updated to "49/49 tests as of 2026-05-22".
- Historical CHANGELOG entries citing "20/20" or smaller counts are preserved as accurate historical records (they document the substrate state at the date of the release entry).
- Drift-check now wired into CI (this release; see `.github/workflows/ci.yml` test-count-drift job).

### v1.4.0 — shell-cfunction quota propagation (closes round-5 residual #30) (2026-05-20)

The only remaining named mast residual from rounds 1–5 of adversarial
review is now closed. Pre-v1.4: `(os/shell "sleep 9999")` with
`MAST_EVAL_TIMEOUT_SEC=2` blocked for 9999 seconds because
`libc.system` is TEMP_FAILURE_RETRY-style — its internal `waitpid`
swallows EINTR, so SIGALRM bumped `g_alarm_fires` but the VM was
parked in the cfunction and the interrupt only took effect when
bytecode resumed (after the shell exited).

**v1.4 architecture:** new `sandbox.g_shell_runner` function-pointer
hook. `main.zig::runShellExitOnly` is the production runner; it does
`fork` + `execv` then a poll loop with `waitpid(WNOHANG)` +
`usleep(50ms)`, checking `g_alarm_fires` between iterations. On
quota fire: `SIGTERM` the child, blocking-reap via `waitpid`, write
`shell-quota-interrupt` audit event, return `-1` sentinel.
`gated_os_shell` + `gated_stax_bash` route through the hook instead
of calling `libc.system` directly.

The legacy `libc.system` fallback remains for early-startup / test
contexts when no host runner is installed.

**Smoke confirmation:**
```
$ printf '(os/shell "sleep 9999")\nexit\n' | MAST_EVAL_TIMEOUT_SEC=2 ./zig-out/bin/mast
M-x   → -1            # quota fired after ~2s; pre-v1.4 this was 9999s
M-x (exiting)         # editor recovered cleanly
```

**Test coverage:** `tests/quota_integration.sh` grows to 8/8 (added
Case 5 + Case 6: wall-clock bound + `-1` sentinel assertion).

**Known v1.4.1 follow-up:** `cmd_agent_run` (the synchronous
`(agent/run ...)` path) still uses `libc.popen` + `fread`. The
popen→fork+exec+capture-stdout refactor is substantially larger than
the exit-only path. The async surface (`agent/spawn` + `agent/wait`)
is already quota-bounded as of v1.3.9 + v1.3.10 and is the
recommended way to capture stdout under quota.

API-additive: new `sandbox.g_shell_runner` public hook; no removals.

### v1.3.10 — round-5 adversarial review: production-robustness closures (2026-05-19)

Round 5 explicitly noted: **"rounds 1-4 + fuzz exhausted the
privilege-escalation surface; round 5's findings are production-
robustness, NOT 'no-escape' claims."** Net-new escalation paths: **zero**. v1.3.10 closes 4 of
round 5's 5 findings; #30 is named as honest residual with v1.4
implementation path.

**Finding #30 — shell-cfunction quota bypass (HONEST RESIDUAL).**
`gated_os_shell`, `gated_stax_bash`, `cmd_agent_run` all sit on
`libc.system` / `libc.popen` which swallow EINTR via internal
`TEMP_FAILURE_RETRY` `waitpid`. SIGALRM fires, handler bumps
`g_alarm_fires`, but the VM is parked in the cfunction — interrupt
only takes effect when bytecode resumes after the shell exits. PoC:
`(os/shell "sleep 9999")` blocks for 9999 seconds despite quota.
**v1.4 path:** replace `libc.system` / `popen` in all three sites
with `fork`+`execv`+poll+waitpid bounded by `g_alarm_fires` (mirror
the `cmd_agent_wait` pattern; ~50 lines per site × 3 sites).
**Severity:** liveness, not security. Documented in §6 #30.

**Finding #31 — `g_alarm_fires` TOCTOU.** CLOSED. `janet_dostring_quota`
now uses `@atomicRmw(.Xchg, 0)` to atomically read-and-zero the
counter; any SIGALRM that delivers after the Xchg is credited to the
NEXT dostring's counter.

**Finding #32 — `janet_panicf` longjmps past Zig `defer` (structural
class).** CLOSED. Removed `defer allocator.free(cmd_z)` in
`cmd_agent_spawn`; removed `defer captured.deinit(allocator)` in
`cmd_agent_run`. Each panic site + happy path deinit explicitly.
Both functions carry the doctrine comment: **no Zig `defer` in any
cfunction reachable by `janet_panicf`.**

**Finding #33 — `cmd_agent_wait` quota-panic leak.** CLOSED. Before
panicking on quota interrupt, the cfunction now SIGTERM's the child,
closes stdout, blocking-reaps via waitpid, marks `h.closed`, sets
`h.exit_status = -1`, writes an `agent-wait-quota-interrupt` audit
event. No more leaks per interrupt.

**Finding #34 — `agentDrain` iteration cap.** CLOSED. Cap of 256
iterations (~1 MB per drain call) as defense-in-depth. NONBLOCK fd +
~64KB pipe buffer already bound this in practice.

**Tests:** 49/49 in-source + 6/6 quota integration + 25/25 doctest +
5/5 strict-mode + sandbox-fuzz clean + cfunction-audit 0 violations
+ 8/10 mutation.

### v1.3.9 — round-4 adversarial review: bugs in MY OWN fix code (2026-05-19)

Round 4 of self-applied hostile review against post-v1.3.8 mast found
**2 critical load-bearing bugs in the v1.3.4-v1.3.8 fix code itself**
plus 2 minor items. The auto_suspend leak (#1) is the most important
shipment of the day — pre-fix, ONE quota timeout broke every
subsequent eval for the rest of the process.

**Finding #1 — SIGALRM quota leaked `auto_suspend` (CRITICAL).**
`janet_interpreter_interrupt(vm)` does `janet_atomic_inc(&vm->auto_suspend)`.
The matching `janet_interpreter_interrupt_handled` (atomic decrement)
was NEVER called by mast. After any timeout fired, `vm->auto_suspend`
== 1 for the rest of the process; every subsequent bytecode op
returned `JANET_SIGNAL_INTERRUPT` at the first opportunity.
`tests/quota_integration.sh` missed it because the test piped ONE
expression then EOFed.

**Fix:** new `g_alarm_fires: c_int` atomic counter; `alarm_handler`
increments via `@atomicRmw`; `janet_dostring_quota` atomically loads
+ drains the count after the eval returns, calling
`janet_interpreter_interrupt_handled` once per fire. `auto_suspend`
goes back to 0 between evals.

**Regression test added:** `tests/quota_integration.sh` Case 4 sends
`(while true 1)\n(+ 2 40)\nexit\n` in a single session and asserts
the second eval returns `→ 42`. Pre-fix, the second eval would
interrupt at the first bytecode op.

**Finding #2 — wall-clock quota only bounded Janet bytecode, not
blocking cfunctions.** `cmd_agent_wait`'s `libc.poll(..., 500ms)`
returned EINTR on SIGALRM but the loop silently retried.
`(agent/spawn "sleep 9999"); (agent/wait 0)` blocked for the full
9999s regardless of `MAST_EVAL_TIMEOUT_SEC=30`.

**Fix:** `cmd_agent_wait` snapshots `g_alarm_fires` at entry and
checks it between poll iterations; if the handler bumped it during
this call, the cfunction panics with "interrupted by quota."

**Regression of round-2 #3.** `MAST_NEWBUFFER_SENTINEL` (line 963)
and `MAST_SAVEAS_SENTINEL` (line 1079) printed `parsed.args[0]`
raw via `print(... {s} ...)` — same OSC 52 clipboard-hijack vector
through a different stdout sink. v1.3.6's `sanitizeNameInto`
sanitized the Buffer.name canonicalize path but the immediate-feedback
echo was missed. **Fixed:** both echo lines now use the sanitized
buffer instead of raw `parsed.args[0]`.

**Sanitizer doctrine convergence.** `agent/spawn`'s name_buf loop
used `>= 0x20 and < 0x7f` (strips UTF-8 entirely); `sanitizeNameInto`
keeps high-bit. **Fixed:** `agent/spawn` now uses the same case-by-
case switch as `sanitizeNameInto` (preserves UTF-8, strips only
control bytes).

**Tests:** 49/49 in-source + 6/6 quota integration (was 5/5, +1 for
the round-4 regression test) + 25/25 doctest + 5/5 strict-mode
integration + sandbox-fuzz clean.

### v1.3.8 — init.janet truncation warning + selective os/* closures (2026-05-19)

Two of the round-2 honest-residuals named in v1.3.6 are now closed.

**`init.janet` 64KB truncation now WARNS instead of silently truncating.**
Pre-v1.3.8 `load_init_janet` capped at 65535 bytes and silently
truncated longer files. Now: `fstat` the file first; if size > 65535,
print a clear warning AND write `init-janet-truncated` to the audit log
with `actual_bytes` + `max_bytes`. Users will notice they need to split
their config or raise the cap. Closes round-2 residual
"64KB init.janet silent-truncation edge."

**3 selective `os/*` closures** out of the 17 round-2 enumerated
surviving metadata bindings. The other 14 are intentionally retained
as pure-metadata (`os/time` / `os/date` / `os/strftime` / `os/clock` /
`os/cryptorand` / `os/isatty` / `os/arch` / `os/compiler` /
`os/cpu-count` / `os/perm-string` / `os/perm-int` / `os/mktime`) or
bounded-by-quota (`os/sleep`) or already-low-risk (`os/getpid` —
process pid is visible in /proc anyway). The 3 removed are:

- **`os/cwd`** — leaks the `$HOME` path via current-working-directory
  string (information leak, especially under STRICT mode).
- **`os/setlocale`** — process-wide state mutation (changing the locale
  affects number/date formatting for the whole mast process,
  including the audit log).
- **`os/which`** — program-discovery info leak (`(os/which "kubectl")`
  tells the script which binaries are on PATH).

`REMOVED_BINDINGS` grows 70 → 73. Sandbox-fuzz post-fix:
`host=16 returned=42 panicked-mast=74 panicked-arity=241 panicked-other=`
— 0 violations.

### v1.3.7 — round-3 fuzz harness + ffi/calling-conventions + ffi/trampoline (2026-05-19)

Round 2 prescribed a fuzz harness that walks `(all-bindings root-env)`
post-`applyDefaultDeny`, calls each cfunction with no args, and FAILS
if any dangerous-looking symbol returned a value without panic. This
release ships it as `tools/sandbox-fuzz.{janet,sh}` and wires it into
`zig build test` (and as standalone `zig build sandbox-fuzz`).

**First run found 2 more FFI symbols** that round 2 missed when
enumerating the ffi namespace:
- `ffi/calling-conventions` (returns the list of supported calling
  conventions — read-only metadata, but leaks FFI's presence)
- `ffi/trampoline` (returns a pointer to a JIT trampoline)

Both added to `REMOVED_BINDINGS`. `REMOVED_BINDINGS` grows 68 → 70.

**Fuzz outcome reporting:**

```
=== mast sandbox-fuzz (round-3 prescribed) ===
  host=16 returned=45 panicked-mast=71 panicked-arity=242 panicked-other=
PASS: no dangerous cfunction returned a value from default-deny env.
```

- `host` = mast-host cfunctions (stax-*/buffer-*/agent-*), expected
- `returned` = pure-function Janet stdlib (+, length, string, etc.)
  that operate on data only, no syscall — benign
- `panicked-mast` = removed-binding panics fired correctly (our gates)
- `panicked-arity` = Janet's own arg-validation fired before our gate
  could run — these are functions that need args; fuzz didn't probe
  with valid args (known limitation, documented in the script)
- `panicked-other` = neither — would flag for review

**Doctrine:** the fuzz harness catches transitive re-exposures via
`module/find` / `require` that source-reading reviews would miss. The
round-3 prescription is now alive as a continuous check, not a
one-time audit.

### v1.3.6 — round-2 adversarial review closures (2026-05-19)

A second self-applied hostile-reviewer pass against the post-v1.3.4 +
v1.3.5 state found 4 more net-new gaps + 1 doctrine update. All
closed in v1.3.6.

**Finding #1 — `ev/thread` re-instantiates a fresh Janet VM bypassing
applyDefaultDeny.** Janet's `ev/thread` calls `janet_init()` in a new
OS thread, creating a fresh VM with the FULL stdlib. Every removed
binding (os/shell, slurp, ffi/*, unmarshal, asm) was reachable from
the spawned thread. CLOSED: `ev/thread`, `ev/thread-chan`,
`ev/spawn-thread` added to `REMOVED_BINDINGS` under new
`DenyCategory.threading`. `ev/go` is single-thread and inherits the
gated env — intentionally NOT removed.

**Finding #2 — spawned children inherit the audit-log fd; bypass of
`writeJsonString`.** Without `O_CLOEXEC`, children of `agent/spawn`,
`agent/run`, and `os/shell` inherit the JSONL log fd; the child can
write raw bytes via `/proc/self/fd/<n>` and forge events past the
escape logic. CLOSED: `O_CLOEXEC` on `audit.zig::init`'s open call,
`main.zig::load_init_janet`'s open call, and `fcntl(F_SETFD,
FD_CLOEXEC)` on the `cmd_agent_spawn` pipe-read end.

**Finding #3 — `list-buffers` print path bypassed `sanitize_into`
(round-1 #4 only half-closed).** v1.3.4 added `sanitize_into` only
inside `tui.render_to_buf`; the line-REPL `list-buffers` and
`M-x display` paths printed buffer names unsanitized. PoC:
`M-x new-buffer "$(printf 'a\x1b]52;c;...\x07')"` then
`M-x list-buffers` → OSC 52 clipboard hijack via the terminal.
CLOSED: new `sanitizeNameInto` helper canonicalizes buffer names at
the write site (`MAST_NEWBUFFER_SENTINEL`, `MAST_SAVEAS_SENTINEL`),
so every consumer sees safe bytes. **Doctrine:** sanitize at the
trust boundary, not scattered across render sites.

**Finding #4 — `audit.zig::write` had unbounded `buf[written] = X`
writes near the 4096 ceiling.** `writeJsonString` could succeed at
exactly `out.len == 4096`, then the next `buf[4096] = '}'` was one
byte past the stack array (UB). PoC: `M-x save-as <~4000-char
path>`. CLOSED: new `appendByte(buf, &written, b)` bounded helper
returns `error.NoSpaceLeft` on overflow; every bare-array-write site
in `audit.zig::write` converted. Long inputs now surface as a
write-failed error instead of corrupting adjacent stack slots.

**Finding #5 — §7 manifest doctrine.** Doc-only: the v2 capability-
manifest plan must explicitly say source-scan is unsound. With
`compile` + `parser/produce` retained (intentional per residual
#19), a script can build code at runtime that never appears as a
literal in init.janet. Manifest must be a runtime grant against
an empty default-deny env. Threat model §6 #25 updated.

**REMOVED_BINDINGS grows 65 → 68 entries** (the +3 ev-thread family).
The G2 closure property test now iterates 68 entries × 9 probe
categories × 200 random cap sets = 122,400 Janet invocations
confirming the panic invariant.

### v1.3.5 — resource quota via SIGALRM + janet_interpreter_interrupt (2026-05-19)

Closes the long-standing v1.3.0 §honest-residuals "no resource quotas"
item. The primitive was identified in v1.3.3
(`janet_interpreter_interrupt` + `janet_local_vm` in
`vendored/janet/janet.h` lines 2066–2072); v1.3.5 wires it up.

**How it works:**

1. `alarm_handler` runs in signal context when SIGALRM fires. It calls
   `janet_interpreter_interrupt(janet_local_vm())`, which tells the
   Janet VM to cancel the currently-running fiber at the next
   bytecode-op boundary.
2. `janet_dostring_quota` wraps every `janet_dostring` call in the
   REPL + `cmd_agent_run` + `load_init_janet` paths: `libc.alarm(N)`
   before, `libc.alarm(0)` after.
3. The cancelled fiber returns non-zero status to `janet_dostring`,
   surfaced as a normal `mx-error` audit event. mast does NOT die —
   the editor recovers cleanly.

**Configurable** via `MAST_EVAL_TIMEOUT_SEC` env var (default 30s,
cap 3600s).

**Smoke test confirmation:**

```
$ printf '(while true 1)' | MAST_EVAL_TIMEOUT_SEC=3 ./zig-out/bin/mast
M-x interrupted:
  in thunk [mx] on line 1, column 1
  (error: status=1)
M-x
```

A `(while true 1)` infinite loop is cleanly interrupted after 3
seconds; mast presents the next prompt. Pre-v1.3.5 this would freeze
mast until the user hit Ctrl-C externally.

**What this means for the threat model:** §6 #8 "no resource quotas"
flips from open to CLOSED. The primitive is exercised in production
paths, not just documented.

### v1.3.4 — adversarial-review-driven security closures (2026-05-19)

A self-applied hostile-reviewer pass against the post-v1.3.3 threat
model found seven net-new gaps the prior audit missed. All seven are
addressed in this release (six closed mechanically, one documented as
intentional residual).

**Finding #1 — `os/open` + `file/*` methods bypassed the v0.2 file-I/O
closure.** The prior closure removed `file/open`/`slurp`/`spit` but
left the parallel constructor `os/open` plus `file/read`/`write`/
`close`/`seek`/`tell`/`flush`/`lines` and `os/pipe` live, so under
`MAST_SANDBOX_STRICT=1` a Janet script could still do
`(file/read (os/open "/etc/shadow" :r) :all)`. **CLOSED:** 9 new
symbols added to `REMOVED_BINDINGS`.

**Finding #2 — FFI surface live, not "theoretical."** The §3 `ffi`
row claimed the vendored Janet did not compile FFI; in fact
`janet.h:269` defines `JANET_FFI` unconditionally and the full surface
(`ffi/native`/`call`/`jitfn`/`malloc`/`free`/`read`/`write`/
`pointer-cfunction`/`pointer-buffer`/`signature`/`struct`/`size`/
`align`/`context`) was live. `ffi/jitfn` alone is strictly stronger
than the removed `native` — mmap + execute arbitrary bytecode.
**CLOSED:** 15 new symbols added to `REMOVED_BINDINGS` under new
`DenyCategory.ffi`.

**Finding #3 — JSON injection in `SessionAudit.write`.** Payload string
fields were formatted as raw JSON via `bufPrint("\"{s}\":\"{s}\"")`
with no escape. A hostile M-x verb / save-as path / buffer name could
forge log lines — eg. a verb containing `","verb":"sandbox-grant","x":"`
would forge a `sandbox-grant` event downstream. **CLOSED:** new
`writeJsonString` helper escapes `"`, `\`, control bytes (`\u00XX` for
0x00–0x1f and 0x7f). 4 in-source tests including PoC neutralization.

**Finding #4 — ANSI escape injection through buffer name + contents
in the TUI.** `src/tui.zig` emitted `buf.name` (settable via
`M-x save-as`) and `buf.contents` (carrying agent-spawn stdout) raw to
stdout. PoC:
`(agent/spawn "printf '\\x1b]52;c;cm0gLXJmIH4=\\x07'")` puts
`rm -rf ~` into the terminal clipboard on OSC-52-respecting terminals.
**CLOSED:** `sanitize_into` helper replaces ESC/BEL/DEL/other C0
control bytes (except `\t`/`\n`/`\r`) with `?` in the render path.
3 in-source tests cover the OSC 52 PoC + UTF-8 passthrough + DEL.

**Finding #5 — process-control survivors.** `os/cd`, `os/umask`,
`os/link`, `os/proc-kill` (arbitrary-pid signal, strictly worse than
the gated `agent/kill`), `os/proc-wait`, `os/proc-close`,
`os/sigaction`, `os/posix-chroot` all survived the v0.2.1
ancillary-fs sweep. `os/sigaction` could make mast un-killable by
SIGTERM. **CLOSED:** 8 new symbols added to `REMOVED_BINDINGS` under
new `DenyCategory.process_control`.

**Finding #6 — bytecode constructors defeat source review.** `asm`
(constructs Janet functions from a runtime dictionary — pure-Janet
bytecode builder) and `marshal` (paired serializer to the
already-removed `unmarshal`) defeated any source-level review of user
scripts. The v2 capability-manifest plan implicitly assumes source
review is sound; `asm` nullifies that. **CLOSED:** 2 new symbols
added to `REMOVED_BINDINGS` under new `DenyCategory.bytecode`. Note:
`compile`, `signal`, `debug/*` are intentionally NOT removed —
removing them would break the language; tracked as residual #19.

**Finding #7 — `agent/wait` DoS under strict mode.** `agent/wait`
(and `poll` / `count` / `alive?`) were not gated on `exec`. PoC: user
runs `M-x agent-run "sleep 9999"` under default policy; later any
strict-mode script calling `(agent/wait 0)` froze mast for the full
hour. **CLOSED:** every `agent/*` operation now gated on `exec`,
matching the capability domain that created the handle.

**`REMOVED_BINDINGS` list grows 31 → 65.** Property test
(`REMOVED_BINDINGS panic-invariance under random cap sets`) iterates
the new total: 200 trials × all 65 entries → 13,000 Janet invocations,
all confirm panic.

**Tests after v1.3.4:** 61 in-source (12 buffer + 21 tui + 4 audit +
12 sandbox + transitive duplicates; the build summary reports
"49/49 unique" elsewhere depending on which sub-modules included
which) + 25/25 doctest + 5/5 strict-mode integration + 0/16
cfunction-audit violations + 8/10 mutation-test.

### v1.3.3 — per-row damage tracker + sandbox property tests + Janet quota primitive identified (2026-05-19)

Three substrate-level additions on top of v1.3.2.

**1. Per-row TUI damage tracking.** `tui.diff_rows(state, allocator,
current, out_changed)` splits the rendered frame on `\r\n` boundaries
and returns the indices of rows that changed since the previous frame.
Pure — no stdout side-effect (same isolation discipline that fixed the
v1.3.2 FrameState test deadlock). The v1.3.2 frame-level
`emit_with_damage` path is unchanged; per-row is opt-in for callers
that want row-granular emission on large terminals. Three new tests
(first-call-all-changed, single-row-mutation produces single-row
emit, invalidate forces all rows). Closes the v1.3.2
§honest-residuals "per-row TUI damage tracking" target.

**2. Sandbox property tests.** Three new property-based tests in
`src/sandbox.zig` raise mutation surface coverage beyond the
example-based G2 closure test:

- Grant idempotency (5000 trials): any 0–50 random grants preserve
  the bit-field invariant.
- revokeAll empties (1000 trials): after revokeAll no Capability
  variant is held, regardless of grant history.
- REMOVED_BINDINGS panic-invariance under random cap sets (200 trials
  × 9 probe symbols = 1800 Janet invocations): every removed binding
  panics regardless of which capabilities are granted. Catches the
  highest-leverage regression: a future code change accidentally
  routes a removed binding through a cap check (which the example G2
  test wouldn't catch — it grants all caps; this test randomizes).

**3. Janet resource-quota primitive identified.** The threat model
§6 #8 previously said "needs a Janet fiber-level interrupt primitive
we have not designed yet." Wrong — Janet exports
`janet_interpreter_interrupt(JanetVM *vm)` + `JANET_SIGNAL_INTERRUPT`
in `vendored/janet/janet.h` lines 1524–2072, plus `janet_addtimeout`
for event-loop fibers. v0.3.x implementation path now documented:
SIGALRM handler + `libc.alarm(N)` around each `janet_dostring` call.
Not implemented in v1.3.3 — design pending — but the substrate now
knows the primitive exists.

**4. examples/init.janet** expanded from 28 → 110 lines covering
the full v1.3.x cfunction surface: stax-fleet bridges, buffer
introspection, agent-as-buffer (sync + async with parallel-three
demo), sandbox-posture probes, composite session-brief verb. New
users now have a copy-pasteable starting point. Doctest still
25/25 (hello pin preserved).

Tests: **42/42 in-source** (12 buffer + 18 tui-with-transitive-buffer
+ 12 sandbox, was 39; +3 sandbox property), 25/25 doctest, 5/5 strict
integration, 0/16 cfunction-audit violations, 8/10 mutation-test.

### v1.3.2 — agent/kill + TUI damage tracker (2026-05-19)

Two more v1.3.0 honest-residuals closed:

- **`(agent/kill handle)`.** Sends SIGTERM to the agent's process.
  Returns boolean (true = signaled). Audited via `agent-kill` event.
  Gated on `exec`. Reaping is still via `(agent/wait handle)` after.
  Closes the "no `agent/kill handle` for in-session cancellation"
  residual.
- **TUI damage tracker.** `tui.render_to_buf` writes into a
  caller-supplied byte buffer; `tui.FrameState` + `tui.emit_with_damage`
  diff against the previous frame and skip the write when unchanged.
  `tui.invalidate(state)` forces full redraw (resize / out-of-band
  stdout writes). Repeated no-op keystrokes (unbound keys, scrolling
  past EOF on a short buffer, holding a key) no longer trigger a
  screen rewrite. Closes the "TUI is full-redraw per keystroke"
  residual in the common case.

Two new in-source tests cover the damage tracker
(`render_to_buf produces deterministic output for the empty-buffer case`
+ `FrameState damage tracker skips emit when frame is unchanged`).

`tools/cfunction-audit.sh` confirms 16 cfunctions / 3 gated /
13 benign / 0 violations after the agent/kill addition.

### v1.3.x — residual closures + tooling (2026-05-19)

Four residuals named in the v1.3.0 release notes closed in a single round:

- **Residual #9 — sandbox-deny audit routing.** `sandbox.DenyCategory`
  enum + `sandbox.g_deny_observer` callback. Every panic stub (and the
  two exec-gated wrappers) call `observe(category)` BEFORE `janet_panicf`,
  so even unrecoverable denies leave a trace in `SessionAudit` as
  `sandbox-deny` records before Janet's stacktrace hits stderr. One new
  in-source test exercises 5 categories from a single VM.
- **Residual #8 — `agent/wait` poll(2).** Replaced 10ms `usleep` loop
  with `poll(2)` on stdout_fd + 500ms backstop timeout. Lower CPU under
  many concurrent agents, faster wake on bursty output.
- **Residual #10 — host-cfunction regression discipline.**
  `tools/cfunction-audit.sh` enumerates every `janet_def`-registered
  cfunction and FAILS if any touches `libc.system`/`popen`/`exec`/`fork`
  without consulting the capability set. Wired into `zig build test`.
  Initial scan: 15 cfunctions, 3 gated, 12 benign, 0 violations.
- **TUI minibuffer sentinel handling** (deferred from v0.3 prototype).
  `execute_mx_line()` now handles `MAST_APPEND_SENTINEL`,
  `MAST_SAVE_SENTINEL`, `MAST_SAVEAS_SENTINEL`, `MAST_NEWBUFFER_SENTINEL`
  directly. Display-only sentinels (help/display/list-buffers) skipped
  because the TUI renders that state inline.

Documentation drift discipline also strengthened: `tools/doctest.sh`
extended from 13 → 25 checks covering the multi-buffer ring lifecycle,
agent/run + agent/spawn + agent/wait + agent/alive? cycles, the `--tui`
launch + alt-screen entry, and the G2 panic message observability from
user-script context.

Mutation-test re-run after the v1.3.x extensions: 8/10 killed, 80% score
unchanged. No new survivors emerged from the new code.

Tests: **22/22 in-source** + 5/5 strict-mode integration + 25/25 doctest
+ 0 cfunction-audit violations + 8/10 mutation killed (2 documented
equivalent mutants).

### In-house ANSI TUI behind --tui — 2026-05-19 (v0.3)

`src/tui.zig` ships a minimal windowed view that runs in the alt-screen
under termios raw mode. Why in-house and not vaxis: mast's build doctrine
is single-binary, zero external Zig deps (no `build.zig.zon` today).
Adding vaxis would break the doctrine AND introduce Zig 0.13 → 0.16
churn we explicitly route around in `buffer.zig` / `sandbox.zig` /
`main.zig`. ANSI escape codes + libc termios reach 95% of what a v0.3
view needs without any of that risk. vaxis re-evaluation is a v0.4
question, post-Zig-1.0.

What the v0.3 TUI does:
- Alt-screen enter + cursor hide on start; full restore on exit
- Renders buffer with dim line numbers, reverse-video status line at
  row N-1, minibuffer line at row N
- Key dispatch: `j/k` or `Up/Down` scroll; `g/G` top/bottom;
  `n/p` cycle buffers; `:` enter minibuffer; `q` or Ctrl-C exit
- Minibuffer routes through the same `execute_mx_line` helper the line
  REPL uses, so any Janet-expressible verb works in both surfaces.
  Sentinel verbs (display/save/append/save-as) are deliberately punted
  to the line REPL for the v0.3 prototype.

Invocation: `mast --tui [file]`. The flag is opt-in; default behavior
is unchanged. The TUI module is host code outside the Janet trust
boundary — Janet scripts cannot drive the TUI directly, they can only
mutate buffers (which the TUI re-renders).

21/21 tests pass (was 20; +1 tui compile-check).

### agent/spawn async + live-tail — 2026-05-19 (v0.3 of agent-as-buffer)

The synchronous `(agent/run cmd)` shipped earlier today has a non-blocking
sibling: `(agent/spawn cmd)` returns a handle id immediately, and the
:agent buffer accumulates stdout (and stderr) as `(agent/poll handle)` is
called. The full surface:

| Form | Behavior |
|------|----------|
| `(agent/spawn cmd)` | fork+exec `/bin/sh -c <cmd>` with non-blocking stdout+stderr pipe; create :agent buffer; return handle id |
| `(agent/poll handle)` | drain pipe → buffer; return exit status int if exited, nil if still running |
| `(agent/wait handle)` | block until exit (10ms poll loop); return exit status |
| `(agent/count)` | number of registered handles |
| `(agent/alive? handle)` | true if handle exists and is unclosed |

Lifecycle invariants:
- Handle id is the index into `g_agents`; never reused, never reordered.
- The :agent buffer at `h.buffer_idx` is owned by the buffer ring; the
  handle holds an index, not a pointer (the ArrayList could relocate on grow).
- `h.stdout_fd` is closed exactly once — when the child exits AND poll
  observes the exit (tracked by `h.closed`).
- Zombie reaping: `waitpid(WNOHANG)` runs on every poll; `agent/wait` loops
  polling + 10ms sleeps. Process exit reaps any still-running children
  with `SIGTERM` + final `waitpid` for cleanup.

Smoke-test evidence (interactive):

```
(def h (agent/spawn "echo line1 ; sleep 1 ; echo line2 ; sleep 1 ; echo line3"))
→ 0
(agent/alive? h)
→ true
(agent/poll h)
→ nil        ; still running
(agent/wait h)
→ 0          ; exit status, after ~2 seconds
display
── [:agent] echo line1 ; sleep 1 ; echo line2 ; sleep 1 ; echo line3 * ──
   1  line1
   2  line2
   3  line3
```

Many agents can run in parallel (each spawn returns its own handle). The
v0.3 surface is the actual "background fleet" foundation the steipete
frame names — addressable, pollable, composable.

Known gaps for v0.3.x:
- The poll loop in `agent/wait` is 10ms-sleep, not `poll(2)`-based.
  v0.3.x will route through real `poll(2)` on stdout_fd + child for
  better latency under many concurrent agents.
- No `agent/kill handle` yet (process exit reaps, but no in-session
  cancellation).
- No structured handle metadata via `(agent/info handle)` —
  closed state inferable via `agent/alive?` only.

### Residuals #6 + #7 closure — 2026-05-19 (v0.2.1)

Same `REMOVED_BINDINGS`-pattern closure applied to the two remaining
named residuals in `docs/SANDBOX_THREAT_MODEL.md` §6.

- **Residual #6 — environment-variable bindings.** `os/getenv`,
  `os/setenv`, `os/environ` REMOVED. Env vars routinely carry secrets
  (TOKEN_*, AWS_*, ANTHROPIC_API_KEY); no script-side granted path is
  honest in v0.2. v0.3 may add a host-bound allowlisted
  `(env/get "KEY_NAME")` with explicit per-key grants.
- **Residual #7 — ancillary filesystem-metadata bindings.** `os/stat`,
  `os/lstat`, `os/dir`, `os/realpath`, `os/readlink`, `os/mkdir`,
  `os/rmdir`, `os/rm`, `os/rename`, `os/touch`, `os/symlink`,
  `os/chmod` all REMOVED. Lower blast than the primary read/write
  path (already removed in G2), but a script could still enumerate
  the home directory or `chmod 777` a file. v0.3 path-prefix
  capabilities will reinstate granted paths.

The static `REMOVED_BINDINGS` list grows from 16 → 31 entries; the
load-bearing test (`G2 closure: every REMOVED_BINDINGS entry panics
from Janet`) iterates 31/31 invocations. 20/20 tests pass.

### G2 sandbox closure — 2026-05-19

The "residual ungated Janet surface" originally listed in
`docs/SANDBOX_THREAT_MODEL.md` §1 — `os/execute`, `os/spawn`, `file/*`,
`net/*`, `native`, `unmarshal`, `os/exit` — is closed via the
"removed from the embedded env" path the threat model itself named as
a valid closure. Symbols still resolve at Janet compile time, but
invoking them panics with a documented message naming the symbol and
pointing at the threat model.

- **Subprocess surface narrowed** to `os/shell` + `stax-bash`, both
  gated on the `exec` capability. `os/execute`, `os/spawn`,
  `os/posix-fork`, `os/posix-exec` REMOVED.
- **File I/O removed:** `file/open`, `file/temp`, `slurp`, `spit`,
  `dofile`. Host buffer ops (`M-x save` / `M-x save-as` / `M-x append`)
  are the v0.2 file-I/O interface.
- **Network removed:** `net/connect`, `net/listen`, `net/accept`,
  `net/accept-loop`. Host-bound HTTP cfunctions with explicit
  allowlists are v0.3.
- **RCE primitives removed:** `native` (which transitively blocks
  `.so` loading via `import`/`module/load`), `unmarshal`.
- **Host lifecycle:** `os/exit` REMOVED.

Drift-resistance: the install path (`sandbox.applyDefaultDeny`) and
the test (`G2 closure: every REMOVED_BINDINGS entry panics from Janet`)
both iterate the same static `REMOVED_BINDINGS` list — adding a
removal in one without the other trips CI.

Per-binding panic test runs with **every capability granted** so a
future regression that accidentally re-routes a removed binding
through a cap check shows up as a non-panic, not as a deny.

Residual gaps (named for honesty, deferred to v0.3): env-var bindings
(`os/getenv`/`setenv`/`environ`), ancillary filesystem-metadata
bindings (`os/stat`/`os/dir`/`os/mkdir`/etc.), resource quotas, audit-log
routing of deny events, host-cfunction regression discipline.

Tests: **20/20 pass**, including 2 new G2 closure tests
(`G2 closure: every REMOVED_BINDINGS entry panics from Janet`,
`G2 closure: applyDefaultDeny returns the expected number of replacements`).

STATUS.md G2 flips from `NOT YET CLOSED` to `CLOSED 2026-05-19`.

### Honesty correction — 2026-05-15

Prior `v1.0` / `v1.1` / "production-grade hygiene milestone" framing was a
Type-I error class per the no-premature-production-claims doctrine:

- **Zig itself is on 0.16, not 1.0.** No Zig project can credibly claim
  API stability beyond "stable on Zig 0.16 today" until the language
  itself ships 1.0. The v1.x git tags are honored for changelog
  continuity, but every reader should treat this as **pre-1.0 in semver
  spirit** until both that gate and a real-deployment gate close.
- **Zero production deployment exists.** No real-traffic operation, no
  soak time, no incident history. The hygiene work
  (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT / dependabot
  / CODEOWNERS) is real. The production claim it implied **wasn't
  earned.**

The mechanism work this cycle is what it is — neither more nor less:

- **Sandbox capability model is mechanism-proven on one binding.** The
  M01 mutation (the `g_sandbox.has(.exec)` sense flip on `os/shell`) is
  KILLED by the test suite. The load-bearing security check is
  mutation-resistant — that is the strongest honest claim. It is **not**
  a claim that mast is sandboxed; `docs/SANDBOX_THREAT_MODEL.md` §1 lists
  every still-ungated Janet binding (`os/execute`, `os/spawn`, `file/*`,
  `net/*`, `native`, `unmarshal`, `os/exit`).
- **`MAST_SANDBOX_STRICT` is posture-observable end-to-end.** Five
  integration cases (`tests/strict_mode_integration.sh`) spawn the built
  binary with the env var set and assert deny-on-stderr. This is
  observability of the gate that exists — not retroactive coverage of
  the residual ungated surface.
- **Buffer protocol + atomic file-write are unit-tested** (round-trip,
  append + dirty flag, atomic tmp+fsync+rename save, saveAs
  kind-conversion, partial-EOF reader-mock pinning the M09 boundary).
  That is `unit-tested`, not `integration-tested` against real editor
  workflows.
- **README/code drift is gated by 12/12 doctest checks** in
  `tools/doctest.sh`, including the 5/5 strict-mode integration cases it
  delegates to. The doctest gates README-to-binary drift, not narrative
  accuracy of design docs.
- **Mutation score is 8/10** (80%) after M09 closure, with the two
  survivors (M08 fd-zero, M10 mark-clamp no-op) classified honestly as
  equivalent mutants in `CHANGELOG.md` and `tools/mutation-test.sh`.

Going forward, the AGENT_HARNESS proof vocabulary (`scaffold` /
`compiled` / `unit-tested` / `integration-tested` / `audited` /
`benchmarked` / `hardware-verified`) is used strictly. See `STATUS.md`
for the per-component proof index and the gates (G1 real Janet under
load; G2 wrap the residual `os/execute`, `os/spawn`, `file/*`, `net/*`,
`native`, `unmarshal`, `os/exit` surface; G3 soak time; G4 independent
security review; G5 Zig 1.0) that would justify a stronger claim.

### Added

- **`tools/doctest.sh` + `zig build doctest`** — README claim verification harness. Twelve checks against the shipped binary, each one tied to an executable claim in `README.md`: documented build steps (`zig build`, `zig build test`) exist; `mast --help` prints the documented `usage: mast …` line; built-in M-x verbs `help` / `pid` / `exit` work as documented; the README Janet quickstart `M-x (+ 1 2)` → `→ 3` evaluates to the documented answer; `examples/init.janet` (referenced from README §Extending) loads on startup without a Janet parse/eval error and exposes the documented `(hello "world")` → `"hello, world"`; `MAST_SANDBOX_STRICT=1` strict-mode posture is observable end-to-end (delegates to `tests/strict_mode_integration.sh`, 5/5 cases); and `M-x stax-search` is gated under strict mode. 12/12 PASS. Same documentation-test discipline shipped in `zig-cobs`, `zig-frame-protocol`, `zig-graph`, `zig-h3`. The doctest step depends on the install step so the binary is present before checks run, and reuses `strict_mode_integration.sh` rather than duplicating its 5 cases. **README/code drift surfaced and annotated**: `README §Run` shows `M-x stax-search "query here"` with a quoted multi-word arg, but `parse_mx_line()` in `src/main.zig` whitespace-splits before any quote-aware handling, so the quoted form parse-errors via the Janet fall-through. The doctest exercises the unquoted form and the comment in `tools/doctest.sh` (Check 8) names the drift so a follow-up can either teach the parser about quotes or correct the README.

- **First slice of a capability model** (`src/sandbox.zig`, `docs/SANDBOX_THREAT_MODEL.md`): default-deny posture documented and worked end-to-end on one Janet stdlib binding — `os/shell` — plus the host-bound `stax-bash`. `os/execute`, `os/spawn`, `file/*`, `net/*`, `native`, `unmarshal`, and `os/exit` remain ungated; the threat-model doc lists every residual gap. Not a sandbox in the OS-isolation sense. Two unit tests cover deny + grant on `os/shell`.
- **`tools/mutation-test.sh`** — stylized mutation-testing harness applying 10 hand-picked operators across `src/sandbox.zig` (capability check + argc bounds + case-insensitive ASCII compare) and `src/buffer.zig` (file-IO boundaries). **M01 — the capability-check sense flip on `g_sandbox.has(.exec)` — is KILLED**: the load-bearing security claim is mutation-resistant in the test suite. Progression after this session's regression tests: 5/10 → 6/10 (eqAsciiCI A-Z) → 7/10 (stax-bash argc) → **8/10 (M09 read-loop partial-EOF — see entry below)** with 2 remaining classified honestly as equivalent mutants:
  - **M08 — equivalent mutant** (in practice): `Buffer.fromFile` calls `libc.open()` which only ever returns 0 if stdin is closed before the call. Under normal flow `fd >= 3`, so `fd < 0` vs `fd <= 0` are observationally identical.
  - **M10 — equivalent mutant**: `mark > copy.len` → `>=` differs only at `mark == copy.len`, where the clamp `self.mark = copy.len` is a no-op (`mark` is already `copy.len`). Identical externally-observable behavior in every reachable state.

- **M09 read-loop partial-EOF — KILLED** (was filed as REAL BUG, deferred). The mutant `rc <= 0` → `rc < 0` would cause `Buffer.fromFile` to spin in an infinite loop on a partial-EOF read (read returns 0 before `read_total == size` — possible on a pipe/socket that closes mid-stream, or any non-regular fd whose `st_size` overshoots what `read()` will deliver). Closed via a small Option-A refactor: the read loop was extracted into a free function `readToBuffer(read_fn, ctx, buf)` taking a `ReadFn = *const fn (ctx, ptr, len) isize` callable matching libc.read's shape. `Buffer.fromFile` now plumbs libc.read through a `LibcFdReader` adapter; the file-path behavior is unchanged byte-for-byte (the `:file` round-trip test still passes). The new test `readToBuffer: terminates on partial-EOF (pins M09 boundary)` uses a `PartialEofReader` mock that delivers N bytes on the first call then returns 0 forever, with a safety-cap that returns -1 after 1024 calls so a mutated build terminates rather than hanging the whole test binary. The test asserts both the byte count AND `call_count == 2` (one data call + one EOF call): under live code exactly two read() calls happen; under the mutant `call_count` blows past 2 to the safety-cap range, failing the equality and killing the mutant. Mutation harness re-run: 7/10 → 8/10 with M09 KILLED. Test count: 10 → 12 unit + 5 integration cases (added `readToBuffer: terminates on partial-EOF (pins M09 boundary)` + `readToBuffer: fills buffer when reader delivers exactly size bytes`).
- **`eqAsciiCI` A-Z boundary regression test** (sandbox.zig:288) — pins case-insensitive compare across every A-Z position plus the ASCII characters immediately before/after the letter ranges (`@`, `[`, `\``, `{`). Closed mutation finding M07 (`ca >= 'A'` → `ca > 'A'` slipped through because none of the existing truthy / falsy keywords contain a capital `A`).
- **`MAST_SANDBOX_STRICT` env var**: setting this to `1` / `true` / `yes` / `on` (case-insensitive) suppresses the v1 host-policy auto-grant of `exec`. The production binary then runs with the same default-deny posture the sandbox unit tests prove on a fresh VM — `M-x stax-search`, `M-x stax-dashboard`, `M-x stax-hunger`, `(os/shell ...)`, and `(stax-bash ...)` all fail with `denied capability: exec`. This moves the sandbox posture from **mechanism-proven (unit tests on a fresh VM)** to **posture-observable-end-to-end (production binary)**. Honest scope: strict mode demonstrates the gate that exists; it does not retroactively gate the still-ungated residual surface (`os/execute`, `os/spawn`, `file/*`, `net/*`, `native`, `unmarshal`, `os/exit`) — those v2 gaps remain reachable under strict mode. Documented in `README.md` (Security / Sandbox section) and `docs/SANDBOX_THREAT_MODEL.md` §5. One new unit test exercises the env-var parser (`strictModeFromEnv`: truthy/falsy/case-insensitive); one new integration test (`tests/strict_mode_integration.sh`, 5 cases) spawns the built binary with the env var set and asserts the deny diagnostic appears on stderr. Test count: 7 → 8 unit + 5 integration cases.

## [1.1.0] — 2026-05-13

First substantive feature release post-hygiene-v1.0.

### Added

- **File-write buffers.** `:file` buffers now support `save` and `save-as`. Writes are atomic: data goes to `<path>.tmp.<pid>`, `fsync` is invoked on the temp fd, then `rename(2)` swaps it into place — a crash mid-write cannot truncate the original file.
- **`Buffer.append(bytes)`** + **`Buffer.setContents(bytes)`**: mutating-buffer primitives. Both mark the buffer `dirty` for the save-state contract.
- **`Buffer.saveAs(path)`**: converts any buffer kind (`:agent`, `:search`, `:manifest`) into a `:file` rooted at the new path. The buffer's `name` and `kind` reassign on success.
- New built-in `M-x` verbs: `append <text…>`, `save`, `save-as <path>`. If `save-as` is invoked with no buffer open, mast creates an empty `:file` buffer at the path first (same semantics as `vim newfile.txt`).
- Dirty indicator (`*`) in the `M-x display` status header so users can see whether their buffer has unwritten changes.
- Audit-log events for every mutation: `buffer-create`, `buffer-append`, `buffer-save`, `buffer-saveas`, plus matching `mx-*-error` rows.
- **`zig build test`** step: 4 unit tests for the buffer protocol (round-trip, append+dirty, atomic save, saveAs kind-conversion). Wired into CI on both Linux x86_64 and Apple Silicon arm64.
- CI: new save-round-trip smoke (`save-as` → `append` → `save` → on-disk byte-match) on both platforms.

### Changed

- v1.x cycle continues per the Virgil convention: surface stable. The new `save` / `save-as` / `append` verbs are additive; no existing verb's semantics change.
- `main.zig` buffer storage moved from a function-local `var` to a module-level slot (`g_initial_buffer_storage`) so REPL-side commands like `save-as` can install a new buffer at runtime. v2.0 will replace this with a multi-buffer ring.

## [1.0.0] — 2026-05-13

**Production-grade hygiene milestone.**

- SECURITY.md present (coordinated disclosure policy).
- CODE_OF_CONDUCT.md (Contributor Covenant 2.1).
- Dependabot configured for github-actions security updates (monthly).
- CODEOWNERS routes review to @SMC17.
- LICENSE, README, CONTRIBUTING, CI workflow verified.
- v1.x cycle: surface stable; breaking changes bump to v2.x.

## [0.1.1] — 2026-05-13

### Added

- **`init.janet` loading**: on startup, mast reads `$XDG_CONFIG_HOME/mast/init.janet` (defaults to `~/.config/mast/init.janet`) and evaluates it in the live Janet env so user-defined commands are available at the first `M-x` prompt. This closes SPEC.md §6 v0.1 deliverable #5.
- **GitHub Actions CI** (`.github/workflows/ci.yml`): Linux x86_64 + macOS arm64 build matrix with Zig 0.16.0, asserts `M-x (+ 2 40)` → 42 (Janet eval fall-through) and `M-x display` renders a `:file` buffer.
- **README badges**: CI status, release version, license, Zig version.

### Fixed

- CI stderr capture: `std.debug.print` writes to stderr; the smoke test now uses `2>&1` so the OUTPUT capture sees what the user sees at the terminal.
- `audit.zig`: pointer-to-array-of-u8 (`*const [N:0]u8`, e.g. the string literal `"file"`) now serializes as `"file"` instead of `null` in the payload.

## [0.1.0] — 2026-05-13

Commit-zero. Foundation-first gates 1–3 green on Linux x86_64 and Apple Silicon arm64.

### Added

- Single-binary editor kernel built around three primitives:
  - **Janet** embedded via `@cImport` from a vendored amalgamated `janet.c` (MIT, Calvin Rose); no system runtime required.
  - **Buffer-as-protocol** — every observable object in the editor is a buffer; first-class kinds in v0.1 are `:file`, `:agent`, `:manifest`, `:search`.
  - **M-x command runner** — line-oriented dispatcher with positional arg substitution. Falls through to raw Janet eval for unrecognised verbs.
- Four built-in M-x commands shipped: `pid`, `help`, `stax-search`, `stax-dashboard`, `stax-hunger` (the last three shell out to the local stax-* CLIs when available).
- Cross-platform build (Linux x86_64, Apple Silicon arm64). Build artifacts: ~950 KB on Linux, ~962 KB on Mach-O arm64.
- AGPL-3.0-or-later license. Vendored Janet keeps its MIT license inline at `vendored/janet/LICENSE`.
- Companion docs: SPEC.md (architecture), buffer-protocol.md (Janet ↔ Zig binding).

### Not in v0.1

- Visual rendering / TUI. The runner is line-oriented. Cursor + windowing land in v0.2.
- File-writing buffers. v0.1 opens files but does not write them.
- Local-inference daemon. The runtime axis composes through `stax-*` CLIs only in v0.1.
- Multi-buffer state machine. v0.1 holds one buffer at a time.
- Windows native support. WSL2 only.

### Foundation-first gates passed

| Gate | Linux x86_64 | Apple Silicon arm64 |
|---|---|---|
| 1. Janet build test | ✓ 945 KB, valgrind clean | ✓ 962 KB Mach-O arm64, 3/3 checks |
| 2. Buffer-protocol binding sketch | ✓ docs/buffer-protocol.md | ✓ (platform-independent) |
| 3. M-x command-runner demo | ✓ 954 KB | ✓ Mach-O arm64 |
