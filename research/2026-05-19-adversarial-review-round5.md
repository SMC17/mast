# mast — adversarial security review, round 5, 2026-05-19

Self-applied hostile-reviewer round 5, post-v1.3.9. Four findings:
2 DoS/liveness, 1 leak class, 1 TOCTOU residue of round-4 fix. No
new privilege-escalation paths. Diminishing-returns note at end.

---

## 1. `gated_os_shell` / `gated_stax_bash` / `cmd_agent_run` swallow SIGALRM — quota INEFFECTIVE for shell cfunctions

**Files.** `src/sandbox.zig:127-145, 150-165`; `src/main.zig:659-727`.

**Bug.** All three block in `libc.system` / `libc.popen`+`fread`.
glibc `system(3)` is `TEMP_FAILURE_RETRY`-style — internal `waitpid`
swallows EINTR. SIGALRM fires, handler bumps `g_alarm_fires` and calls
`janet_interpreter_interrupt(vm)`, but the VM is parked in the
cfunction. Interrupt only takes effect when bytecode resumes — AFTER
the shell exits.

**PoC** (`MAST_EVAL_TIMEOUT_SEC=2`, exec granted):
```
M-x (os/shell "sleep 9999")   # 9999s, quota ignored
M-x (agent/run "sleep 9999")  # popen variant, same
M-x (stax-bash "sleep 9999")  # third surface, same
```
Round-4 #2 fixed `cmd_agent_wait` only — three sibling sites missed.
Type-II on round-4 fix scope.

**Fix.** `cmd_agent_run` → non-blocking-fd loop with `g_alarm_fires`
check (mirror `cmd_agent_wait`). Shell wrappers → replace
`libc.system` with `fork`+`execv`+`waitpid(WNOHANG)` loop; OR downgrade
SANDBOX_THREAT_MODEL §6 #8 — shell cfunctions are quota-exempt.

**Severity.** Liveness.

---

## 2. `g_alarm_fires` TOCTOU between `alarm(0)` and atomic load

**File.** `src/main.zig:197-211` (`janet_dostring_quota`).

**Bug.** `alarm(0)` (201) → `atomicLoad(g_alarm_fires)` (205) → drain
loop (207-209). A SIGALRM whose kernel timer expired BEFORE the
`alarm(0)` can still be in the signal-delivery queue. If the handler
runs AFTER the load but during/after the drain, count becomes N+1
while we drained N. One `auto_suspend` leak per race — regression of
round-4 #1, harder to trigger.

**Fix.** `atomicRmw .Exchange` swap to 0 (so any later fire is counted
toward the NEXT dostring); drain until `auto_suspend` reads 0 as
safety net. OR `sigprocmask`-block SIGALRM around the drain.

**Severity.** Liveness.

---

## 3. `janet_panicf` longjmps past Zig `defer` — cfunctions leak on panic

**Files.** `src/main.zig:373-385` (`agent/spawn` `cmd_z` defer 378,
panics 385/423 skip it). `:676-715` (`agent/run` `captured` defer 677,
panics 685/712/715 skip it).

**Bug.** `janet_panicf` → `janet_panic` → `longjmp`. Zig `defer` is
scope-exit; longjmp skips it. Every cfunction that allocates then
panics leaks. Structural, not v1.3.9-specific, unaudited rounds 1-4.

**PoC.** `(loop [_ :range [0 100000]] (try (agent/spawn "") nil))` —
each spawn fails buffer creation, panics, leaks duped name. Memory
grows monotonically.

**Fix.** Replace `defer` with named-block cleanup before each panic
site. Doctrine: NO Zig `defer` in any function reachable by
`janet_panicf`.

**Severity.** Resource leak → OOM. No escalation. Type-II:
longjmp/defer unaudited prior.

---

## 4. `cmd_agent_wait` quota-panic leaves agent unreaped + fd unclosed

**File.** `src/main.zig:535-543`.

**Bug.** Quota check trips → panic without `close(h.stdout_fd)`,
`h.closed=true`, or reaping the child. Child runs on, fd stays open.
Repeated quota-interrupted waits grow the agent table unboundedly.

**Fix.** Before panic at 542: best-effort `SIGTERM` to `h.pid`,
`close(h.stdout_fd)`. Or soft-return (`:interrupted`).

**Severity.** Resource leak.

---

## Audit of round-4 fix code

- `alarm_handler` (164-169): signal-safe; re-entry blocked by
  `signal()` default mask. Clean except for drain TOCTOU (#2).
- `g_alarm_fires`: c_int, one-shot alarm, ~1 fire/dostring, never
  user-decremented. No over/underflow.
- `cmd_agent_wait` `entry_fires` (534): correct baseline. Failure
  mode is unreaped child (#4), not the check.
- `sanitizeNameInto` convergence in `cmd_agent_run` (695-708):
  inlined switch matches canonical sanitizer. No drift.

## `cmd_agent_poll` quota — confirmed missing, low blast

`agentDrain` `libc.read`s NONBLOCK fd until EAGAIN; bounded by pipe
buffer (~64KB). Not exploit-grade. Add an iteration cap as cheap
defence-in-depth.

## NEW escalation paths — net-new: 0

`cmd_agent_run/kill/alive/spawn` reviewed for cap TOCTOU, state
corruption, integer overflow, handle reuse. Cap checks at entry;
`g_sandbox` mutations host-only; handle ids append-only; parses
bounded.

---

## Diminishing returns — honest

Rounds 1-4 + fuzz exhausted privilege-escalation surface. Round 5
finds liveness/leak bugs and one TOCTOU residue — meaningful for
production robustness, NOT for §6's "no-escape" claim. Round 6 should
pivot from review to (a) fuzz harness for the panic-leak class #3, or
(b) runtime cap-manifest implementation. A sixth pure-review pass
returns mostly noise.
