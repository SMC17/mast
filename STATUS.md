# mast status

Last touched: 2026-05-19

## Honest version posture

Despite the `v1.0.0`, `v1.1.0`, and `v1.2.0` git tags, this project is **pre-1.0
in semver spirit** for two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits
   1.0, no Zig project can credibly claim API stability beyond
   "stable on Zig 0.16 today." Tagging v1.x against a pre-1.0
   substrate is a vanity claim — the language guarantees aren't there
   yet. The vendored Janet runtime is independent of this, but the
   Zig host code is the surface most consumers depend on.
2. **No production deployment exists.** mast has zero real-traffic
   operation, zero soak time, zero production-incident history. The
   `v1.0.0` tag was described as a "production-grade hygiene
   milestone" — the hygiene work
   (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT /
   dependabot / CODEOWNERS) is real, but those are **shipping-process
   hygiene**: necessary, not sufficient, for "production-grade."

The hygiene work is real. The v1.x git tags will be honored for
changelog continuity. But every reader should treat this as a pre-1.0
substrate until both gates above close.

## Proof-vocabulary index (per `~/AGENT_HARNESS.md`)

| component                                | proof level                                       | evidence                                                                                                                                                       |
|------------------------------------------|---------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Sandbox capability model (`os/shell` + `stax-bash` gated; **65** dangerous bindings removed as of v1.3.4) | `audited` + `unit-tested`                          | `docs/SANDBOX_THREAT_MODEL.md` is the self-applied audit + 2 rounds of self-applied adversarial review (research/2026-05-19-adversarial-review*.md); `src/sandbox.zig` ships 12 in-source tests covering deny + grant + argc-bounds + ASCII-CI compare + every removed-binding panics from Janet (drift-proof against the static **65-entry** `REMOVED_BINDINGS` list) + deny-observer fires for every category + 3 property tests (grant idempotency, revokeAll invariant, panic-invariance under random cap sets) |
| Sandbox mechanism — capability check     | `audited` (mutation-proven)                       | `tools/mutation-test.sh` M01 — the `g_sandbox.has(.exec)` sense flip — is KILLED; the load-bearing security check is mutation-resistant                       |
| Sandbox-deny audit routing               | `unit-tested`                                     | `sandbox.g_deny_observer` callback fires BEFORE `janet_panicf`; `main.zig::onSandboxDeny` routes events to `SessionAudit` as `sandbox-deny` records with category tag (closes threat-model §6 residual #9) |
| Host-cfunction regression discipline     | `audited` + `tooled`                              | `tools/cfunction-audit.sh` enumerates every `janet_def`-registered cfunction and FAILS if any touches `libc.system`/`popen`/`exec`/`fork` without a capability check; wired into `zig build test` (closes residual #10); current scan: 15 cfunctions, 3 gated, 12 benign, 0 violations |
| `MAST_SANDBOX_STRICT` env var            | `posture-observable-end-to-end`                   | `tests/strict_mode_integration.sh` 5/5 cases against the built binary; one in-source env-parser test (`strictModeFromEnv`); README §Security/Sandbox documents |
| Buffer protocol (`fromBytes` / `append` / `setContents`) | `unit-tested`                                     | 6 in-source tests in `src/buffer.zig` covering round-trip + dirty-flag + saveAs kind-conversion + partial-EOF mock + 6 property tests (5000 + 1000 + 1000 + 2000 + 200 + 100 trials)            |
| File-write / atomic save                 | `unit-tested`                                     | atomic-save unit test in `src/buffer.zig` (tmp + fsync + rename); CI save-round-trip smoke (Linux x86_64 + macOS arm64)                                         |
| Multi-buffer ring                        | `posture-observable-end-to-end`                   | `tools/doctest.sh` verifies empty-ring → new-buffer alpha → new-buffer beta → list-buffers reports "buffers (2)" → switch-buffer 0 → buffer-name = alpha → next-buffer → buffer-name = beta cycle |
| Agent-as-buffer (sync `agent/run`)       | `posture-observable-end-to-end`                   | `tools/doctest.sh` verifies `(agent/run "echo …")` returns new buffer index AND captures cmd stdout into a `:agent` buffer renderable via `M-x display`        |
| Agent-as-buffer (async `agent/spawn` + live-tail) | `posture-observable-end-to-end`            | `tools/doctest.sh` verifies `(agent/spawn cmd)` → handle int, `(agent/wait h)` → exit-status int, `(agent/alive? h)` → false after exit, captured stdout reaches the `:agent` buffer; `agent/wait` uses `poll(2)` on stdout_fd with 500ms backstop (closes §6 residual #8) |
| Agent-as-buffer (in-session cancel)      | `unit-tested` (smoke)                             | `(agent/kill handle)` returns bool, sends SIGTERM (v1.3.2); audited as `agent-kill` event; gated on `exec`; smoke-tested: spawn `sleep 30` + kill + wait completes in <1s instead of 30s |
| ANSI/termios TUI (`--tui`)               | `posture-observable-end-to-end`                   | `tools/doctest.sh` verifies `mast --tui <file>` exits 0 on 'q' AND emits the alt-screen-enter ANSI escape (1049h); in-source compile-check test in `src/tui.zig` |
| TUI damage tracker (frame-level)         | `unit-tested`                                     | `tui.FrameState` + `tui.emit_with_damage` diff against previous frame and skip write when unchanged; `tui.invalidate(state)` forces full redraw; v1.3.2 two in-source tests (render determinism + diff/invalidate cycle); closes v1.3.0 §honest-residuals "TUI is full-redraw per keystroke" in the common case |
| TUI damage tracker (per-row)             | `unit-tested`                                     | `tui.diff_rows(state, allocator, current, out_changed)` splits frame on "\\r\\n", returns indices of changed rows; pure (no stdout side-effect); v1.3.3 three in-source tests (first-call-all-changed, single-row-mutation, invalidate-forces-all) |
| Sandbox property tests                   | `audited` (property-tested)                       | `src/sandbox.zig` v1.3.3 — grant idempotency (5000 trials), revokeAll invariant (1000 trials), REMOVED_BINDINGS panic-invariance under 200 random cap sets × 9 probe symbols (1800 Janet invocations); catches any future regression that routes a removed binding through a cap check |
| Adversarial-review-driven closures (v1.3.4) | `audited` (self-applied hostile-reviewer) + `unit-tested` | `research/2026-05-19-adversarial-review.md` ran a self-applied hostile-review pass against the post-v1.3.3 threat model and found 7 net-new gaps: file/* + os/open bypass, FFI surface live, audit JSON injection, TUI ANSI injection, process-control survivors, bytecode constructors, agent/wait DoS. v1.3.4 closes findings #1, #2, #5, #6, #7 mechanically + finds #3 (audit JSONString escape) + #4 (TUI sanitize_into) with in-source tests for each. REMOVED_BINDINGS grows 31 → 65 entries. |
| Resource quota (wall-clock) (v1.3.5)     | `posture-observable-end-to-end`                   | SIGALRM handler + `janet_interpreter_interrupt(janet_local_vm())`; `janet_dostring_quota` wraps every eval call site; `MAST_EVAL_TIMEOUT_SEC` env var (default 30s, cap 3600s). Smoke-tested live: `(while true 1)` with 3s budget interrupts cleanly + editor recovers. Closes threat-model §6 #8 wall-clock dimension. Memory + fd quota extend the same primitive (deferred to v0.4). |
| Audit-log JSON escape (anti-injection)   | `unit-tested`                                     | `src/audit.zig::writeJsonString` escapes `"`/`\\`/`\\u00XX` per RFC 8259; 4 in-source tests cover trivial ASCII round-trip, quote/backslash/newline escape, control-byte escape, and the published adversarial PoC neutralization (closes finding #3) |
| TUI ANSI-escape sanitization             | `unit-tested`                                     | `src/tui.zig::sanitize_into` replaces ESC/BEL/DEL/other C0 control bytes (except `\\t`/`\\n`/`\\r`) with `?` in render path for buf.name + buf.contents; 3 in-source tests cover OSC 52 clipboard-hijack PoC, UTF-8 passthrough, DEL handling (closes finding #4) |
| README/code drift                        | `unit-tested`                                     | `tools/doctest.sh` 25/25 PASS against the shipped binary, including the 5/5 `MAST_SANDBOX_STRICT` integration cases it delegates to, the multi-buffer lifecycle, agent/run + agent/spawn cycles, --tui launch, and G2 panic observability |
| Mutation surface                         | `audited`                                         | `tools/mutation-test.sh` 8/10 killed; 2 survivors classified honestly as equivalent mutants (M08 fd-zero, M10 mark-clamp no-op); no new survivors emerged from the v1.3.x sandbox extensions |
| Cross-platform build                     | `compiled` (CI only)                              | CI matrix on Linux x86_64 + macOS arm64 with Zig 0.16.0                                                                                                        |

## Gates that would justify a stronger claim

- **G1 — Real Janet script under load.** A non-toy `.janet` user
  config (≥ a few hundred lines) loaded by mast and exercised over
  a meaningful session, ideally driving the editor through buffer
  mutation + file saves + sandbox-gated calls. Status: `PARTIALLY
  CLOSED 2026-05-19`. `~/.config/mast/init.janet` is 207 lines / 25
  user-script verbs across 7 sections (utility / experiment register
  / buffer introspection / sandbox-posture probes / fleet workflows
  / codex / morning-brief), loads cleanly on startup, and the
  `sandbox-audit` verb returns 8/8 "G2 OK" lines confirming every
  REMOVED_BINDINGS panic is observable end-to-end from user-script
  context (not just from in-source Zig tests). Soak time (G3)
  remains the missing G1 component — "loaded once" is not "exercised
  over a meaningful session."
- **G2 — Wrap the residual ungated Janet surface.** The threat model
  (`docs/SANDBOX_THREAT_MODEL.md` §1) named the surface that v1 did
  NOT gate: `os/execute`, `os/spawn`, `file/*`, `net/*`, `native`,
  `unmarshal`, `os/exit`. v0.2 closes G2 via the "removed from the
  embedded env" path the threat model itself names as valid: each of
  those symbols now resolves to a panic stub that names the symbol and
  points at the threat model. Subprocess surface is narrowed to
  `os/shell` + `stax-bash` (both gated on `exec`). The
  `REMOVED_BINDINGS` static list and the `G2 closure` test iterate the
  same set, so adding to one without the other will trip CI.
  Status: `CLOSED 2026-05-19`. **v0.2.1 follow-up the same day** closed
  the two named residual gaps (#6 env-var bindings, #7 ancillary
  filesystem-metadata bindings) using the same `REMOVED_BINDINGS`
  pattern: `os/getenv` / `os/setenv` / `os/environ` removed, and the
  12 ancillary `os/` filesystem bindings (`stat`/`lstat`/`dir`/
  `realpath`/`readlink`/`mkdir`/`rmdir`/`rm`/`rename`/`touch`/
  `symlink`/`chmod`) removed. Static list now at 31 entries;
  test iterates 31/31.
- **G3 — Soak time.** ≥30 days of continuous mast use as the daily
  editor for at least one real workflow (driving real-stax-CLI
  invocations, holding real buffers under real edits), with the
  audit log retained and reviewed for capability-deny anomalies.
  Status: `NOT YET CLOSED`.
- **G4 — Independent security review.** A second pair of eyes on
  `src/sandbox.zig` + `docs/SANDBOX_THREAT_MODEL.md`, ideally someone
  who has shipped capability-based isolation in production. Status:
  `NOT YET CLOSED`. The internal hostile-reviewer audit
  (`docs/SANDBOX_THREAT_MODEL.md` self-applied + the mutation-test
  surface + the `cfunction-audit.sh` static check) is the strongest
  current substitute, but is not a substitute for external eyes.
- **G5 — Zig 1.0 reaches stable.** The language-level guarantee that
  makes the v1.x tag mean what it says in any other ecosystem.
  Status: `NOT YET CLOSED` (out of this repo's control).

Only after G5 + at least one of G1 / G3 / G4 do the words
"production-grade" or "stable v1" honestly fit (G2 alone is not
sufficient — sandbox completeness is a necessary condition for
the substrate's security claim, not for the version claim). Until
then, mast ships as a pre-1.0 substrate with mutation-proven
mechanism on the `os/shell` + `stax-bash` gated path, every other
dangerous Janet binding removed from the embedded env, an observable
strict-mode posture, and an explicit list of residual gaps.
