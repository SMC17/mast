# mast — adversarial security review, round 4, 2026-05-19

Self-applied hostile-reviewer round 4 against post-v1.3.8 state.
Persona: round-4 reviewer, NOT external. Focused review found **2
net-new load-bearing bugs in the v1.3.4–v1.3.8 fix code itself**.
Composability and unprobed-arity searches turned up no NEW escalation
paths beyond what rounds 1–3 already documented.

---

## 1. SIGALRM quota leaks `auto_suspend` — one timeout permanently breaks the session

**File.** `src/main.zig::alarm_handler` (155–159) + `janet_dostring_quota`
(181–186).

**Bug.** `alarm_handler` calls `janet_interpreter_interrupt(vm)`, which
does `janet_atomic_inc(&vm->auto_suspend)` (janet.c:31290–93). The
matching `janet_interpreter_interrupt_handled` (atomic decrement) is
**never called by mast.** After any timeout fires, `vm->auto_suspend == 1`
for the rest of the process. Every subsequent bytecode op checks
`vm_maybe_auto_suspend` (janet.c:35906) and returns
`JANET_SIGNAL_INTERRUPT` at the first opportunity. `auto_suspend`
resets only via `janet_init()` (janet.c:37486) — called once per process.

**PoC.**
```
MAST_EVAL_TIMEOUT_SEC=2 ./zig-out/bin/mast
M-x (while true 1)   # quota fires after 2s, "interrupted" reported
M-x (+ 1 2)          # returns status != 0 immediately; every later
                     # eval interrupts at first bytecode op
```
`tests/quota_integration.sh` doesn't catch this — it pipes ONE
expression then EOFs. The REPL session is the surface.

**Fix.** After `janet_dostring` returns, call
`janet_interpreter_interrupt_handled(janet_local_vm())` exactly when
the alarm actually fired (count fires in a `volatile sig_atomic_t` in
the handler, decrement that many times after each dostring).

**Severity.** Liveness, not security. The §6 #8 SANDBOX_THREAT_MODEL
claim "editor recovers cleanly" is wrong for the multi-eval REPL.

---

## 2. Wall-clock quota only bounds Janet bytecode, NOT blocking cfunctions

**File.** Same wrapper + `cmd_agent_wait` (504–540).

**Bug.** `vm_maybe_auto_suspend` only fires inside the Janet interpreter
loop. A cfunction implemented in Zig (`cmd_agent_wait`,
`cmd_agent_poll`, `gated_os_shell` via `libc.system`) runs to
completion regardless. `cmd_agent_wait`'s `libc.poll(..., 500ms)`
returns EINTR on SIGALRM but the loop silently retries.

**PoC** (default policy, exec granted):
```
M-x (agent/spawn "sleep 9999")
M-x (agent/wait 0)   # blocks 9999 seconds despite MAST_EVAL_TIMEOUT_SEC=30
```
Combined with bug #1: when `agent/wait` finally returns, the leaked
`auto_suspend` interrupts every subsequent eval immediately.

**Fix.** `cmd_agent_wait` checks `janet_vm.auto_suspend` between poll
iterations and returns early, OR adds a per-call deadline arg.
Round 1 #7 gestured at this; the fix landed as a capability gate. The
gate prevents a no-exec script from calling `agent/wait`, but a script
that legitimately holds `exec` is still DoS-able via this path.

---

## Round-3 unprobed-arity check — net-new gaps: 0

5 most-likely-dangerous PANICKED-ARITY syms with valid argv:

| Symbol | Predicted result |
|--------|------------------|
| `compile`        | Returns function; gated bindings resolve through root-env (the default-deny env). No escalation. |
| `signal`         | Yields out of dostring; can't mutate cap state. |
| `parser/produce` | Returns parse node. Pure parsing. |
| `fiber/new`      | `env` arg is dynamic vars, NOT symbol resolution. Resuming still hits gated cfuncs. |
| `ev/sleep`       | Blocks like `agent/wait` — re-confirms bug #2. |

**Composability.** Round 2 #5 doctrine: `compile + signal + parser/* +
debug/*` can construct code static review misses. But every dangerous
target is still gated at the call boundary in v1.3.8. Residual #19 is
correctly classified — a v0.4 doctrine constraint, not an exploit.

---

## Audit of v1.3.4–v1.3.8 fix code

- `alarm_handler`: signal-safe in isolation (thread-local addr-of +
  atomic-inc). Clean — but see bug #1.
- `sanitizeNameInto` (110–122): bounded, no off-by-one.
  **Regression.** `MAST_NEWBUFFER_SENTINEL` (924) and
  `MAST_SAVEAS_SENTINEL` (1037–38) `print(... {s} ..., .{parsed.args[0]})`
  with raw user bytes. Buffer.name closed round 2 #3; the
  immediate-feedback echo line was missed. Same OSC 52 vector via a
  different stdout sink.
- `appendByte`, `frame_changed`: bounded; no off-by-one.
- `O_CLOEXEC` sweep verified at `audit.zig:69`, `main.zig:1504`, and
  the spawn pipe (`fcntl F_SETFD`). Inconsistency: pipe uses fcntl
  post-creation instead of `pipe2(O_CLOEXEC)`. v1 is single-threaded
  so the window is theoretical, but `pipe2` is the correct primitive.
- `agent/spawn` name sanitizer (332) uses `>= 0x20 and < 0x7f`
  (strips UTF-8 entirely); `sanitizeNameInto` keeps high-bit.
  Inconsistent doctrine; converge on the looser version.

---

## Doctrine — v0.4 manifest plan

How "runtime grant against empty default-deny env" (round 2 #5)
composes with the agent-as-buffer fleet that needs `exec` by design:

1. `init.janet` declares `(use-capabilities :exec)`; host parses before
   eval. init.janet is host-trusted (truncation warning v1.3.7).
2. Buffer-loaded scripts (`agent/spawn-script`) get a FRESH env
   (proto=gated root-env) AND a FRESH cap set (`empty()`). Their own
   `(use-capabilities ...)` first form is the request; ungranted caps
   panic at call time.
3. Cap set lives in `std.AutoHashMap(*JanetTable, CapabilitySet)`
   keyed off env identity — not the process-global `g_sandbox`.
4. Gated wrappers consult
   `g_sandbox_for(janet_vm.fiber->env).has(.exec)`.

**Honest constraint.** Source-scan of the manifest is fine at the
init.janet trust boundary, NEVER enough for a buffer-loaded script.
Runtime grant must happen at fiber-creation time and live in the host.
