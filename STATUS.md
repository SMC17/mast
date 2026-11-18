---
last_touched: 2026-08-20
prior_touch: 2026-06-25
current_test_count: 180
proof_level: unit-tested
posture: pre-1.0-in-semver-spirit
upstream_zig_version: "0.16"
---

# mast status

Proof vocabulary (harness): `sketch`, `scaffold`, `compiled`,
`unit-tested`, `integration-tested`, `audited`, `benchmarked`,
`hardware-verified`. Rows below use those words only. Local synonym
`posture-observable-end-to-end` maps to `integration-tested`.
`tooled` is not a proof level; static scanners are `audited` (static)
when they ran.

Repo-level proof on 2026-11-17 (macOS arm64, Zig 0.16.0, fresh clone):
`zig build test --summary all` → **16/16 steps succeeded; 49/49 tests passed**.
On 2026-08-20 (Linux x86_64, Zig 0.16.0): `zig build doctest` → **25/25 PASS**. That is `unit-tested` +
`integration-tested`. It is not G3 soak and not G4 independent review.
Frontmatter `proof_level: unit-tested` is the strongest *repo-wide*
word that this run supports. Sandbox rows may still say `audited`
(self-applied).

`current_test_count: 180` is the Zig runner total from `--summary all`
(includes in-source tests reached through imports; some modules
re-execute others). Previously claimed 64 — that was drift.

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

No user count is claimed. G3 is the soak gate; it is open.

## Proof-vocabulary index

| component                                | proof level                                       | evidence                                                                                                                                                       |
|------------------------------------------|---------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Sandbox capability model (`os/shell` + `stax-bash` gated; **73** dangerous bindings removed) | `audited` (self-applied) + `unit-tested`          | `docs/SANDBOX_THREAT_MODEL.md` is the self-applied audit + self-applied adversarial-review rounds under `research/`; `src/sandbox.zig` ships 12 in-source tests covering deny + grant + argc-bounds + ASCII-CI compare + every removed-binding panics from Janet (drift-proof against the static **73-entry** `REMOVED_BINDINGS` list) + deny-observer fires for every category + 3 property tests. Independent review is G4, open. Historical v1.3.4 snapshot was 65 entries; current source is 73. |
| Sandbox mechanism — capability check     | `audited` (mutation-tested, self-applied)         | `tools/mutation-test.sh` M01 — the `g_sandbox.has(.exec)` sense flip — last recorded as KILLED. Not re-run 2026-08-20.                                         |
| Sandbox-deny audit routing               | `unit-tested`                                     | `sandbox.g_deny_observer` callback fires BEFORE `janet_panicf`; `main.zig::onSandboxDeny` routes events to `SessionAudit` as `sandbox-deny` records with category tag (closes threat-model §6 residual #9) |
| Host-cfunction regression discipline     | `audited` (static)                                | `tools/cfunction-audit.sh` enumerates every `janet_def`-registered cfunction and FAILS if any touches `libc.system`/`popen`/`exec`/`fork` without a capability check; wired into `zig build test`. 2026-08-20 scan: 35 cfunctions, 2 gated, 33 benign, 0 violations. |
| `MAST_SANDBOX_STRICT` env var            | `integration-tested`                              | `tests/strict_mode_integration.sh` 5/5 cases against the built binary (ran inside `zig build test` 2026-08-20); one in-source env-parser test |
| Buffer protocol (`fromBytes` / `append` / `setContents` + search/replace) | `unit-tested`                        | in-source tests in `src/buffer.zig` (61 tests in that file; property trials included as unit tests, not a separate proof level) |
| File-write / atomic save                 | `unit-tested`                                     | atomic-save unit test in `src/buffer.zig` (tmp + fsync + rename)                                                                                               |
| Multi-buffer ring                        | `integration-tested`                              | `tools/doctest.sh` verifies empty-ring → new-buffer alpha → new-buffer beta → list-buffers reports "buffers (2)" → switch-buffer 0 → buffer-name = alpha → next-buffer → buffer-name = beta cycle (25/25 PASS 2026-08-20) |
| Agent-as-buffer (sync `agent/run`)       | `integration-tested`                              | `tools/doctest.sh` verifies `(agent/run "echo …")` returns new buffer index AND captures cmd stdout into a `:agent` buffer |
| Agent-as-buffer (async `agent/spawn` + live-tail) | `integration-tested`                     | `tools/doctest.sh` verifies `(agent/spawn cmd)` → handle int, `(agent/wait h)` → exit-status int, `(agent/alive? h)` → false after exit; `agent/wait` uses `poll(2)` on stdout_fd with 500ms backstop |
| Agent-as-buffer (in-session cancel)      | `unit-tested` (smoke)                             | `(agent/kill handle)` returns bool, sends SIGTERM (v1.3.2); gated on `exec`; not re-soaked 2026-08-20 |
| ANSI/termios TUI (`--tui`)               | `integration-tested`                              | `tools/doctest.sh` verifies `mast --tui <file>` exits 0 on 'q' AND emits the alt-screen-enter ANSI escape (1049h) |
| TUI damage tracker (frame-level)         | `unit-tested`                                     | `tui.FrameState` + `tui.emit_with_damage`; in-source tests in `src/tui.zig` |
| TUI damage tracker (per-row)             | `unit-tested`                                     | `tui.diff_rows`; in-source tests in `src/tui.zig` |
| Sandbox property tests                   | `unit-tested`                                     | `src/sandbox.zig` — grant idempotency (5000 trials), revokeAll invariant (1000 trials), REMOVED_BINDINGS panic-invariance under 200 random cap sets × probe symbols. Property tests are unit tests, not an external audit. |
| Adversarial-review-driven closures (v1.3.4+) | `audited` (self-applied) + `unit-tested`      | Self-applied hostile-review rounds under `research/` found and closed named gaps (fs bypass, FFI, JSON injection, ANSI injection, process-control, bytecode, threading). REMOVED_BINDINGS grew 31 → 65 (v1.3.4) → **73** (current). Not G4. |
| Resource quota (wall-clock) (v1.3.5)     | `integration-tested`                              | `tests/quota_integration.sh` **8/8** against the shipped binary (ran inside `zig build test` 2026-08-20). Memory + fd quota still deferred. |
| Audit-log JSON escape (anti-injection)   | `unit-tested`                                     | `src/audit.zig::writeJsonString`; 4 in-source tests |
| TUI ANSI-escape sanitization             | `unit-tested`                                     | `src/tui.zig::sanitize_into`; in-source tests |
| Skills (`src/skills.zig`)                | `unit-tested`                                     | 5 in-source tests |
| Plan (`src/plan.zig`)                    | `unit-tested`                                     | 7 in-source tests |
| README/code drift                        | `integration-tested`                              | `zig build doctest` → `tools/doctest.sh` **25/25 PASS** 2026-08-20. (Older README text said 12/12; that was stale.) |
| Mutation surface                         | `audited` (self-applied; not re-run this session) | `tools/mutation-test.sh` last recorded 8/10 killed; 2 survivors classified as equivalent mutants (M08 fd-zero, M10 mark-clamp no-op) |
| Sandbox fuzz (round-3 harness)           | `integration-tested`                              | `tools/sandbox-fuzz.sh` PASS inside `zig build test` 2026-08-20 ("no dangerous cfunction returned a value from default-deny env") |
| Cross-platform build                     | `compiled` (CI when green)                        | CI matrix on Linux x86_64 + macOS arm64 with Zig 0.16.0. This session measured Linux only. |
| Fleet preflight                          | `scaffold`                                        | `tools/fleet-preflight` exists. Not real PR blocking and not real fleet review. |

## Gates that would justify a stronger claim

- **G1 — Real Janet script under load.** A non-toy `.janet` user
  config (≥ a few hundred lines) loaded by mast and exercised over
  a meaningful session, ideally driving the editor through buffer
  mutation + file saves + sandbox-gated calls. Status: `PARTIALLY
  CLOSED`. Public evidence: in-tree `examples/init.janet` (178 lines)
  loads on startup (`doctest` PASS 2026-08-20). Operator home-config
  line counts are not a repo receipt. Soak time (G3) remains the
  missing G1 component — "loaded once" is not "exercised over a
  meaningful session."
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
  Status: `CLOSED 2026-05-19`, with later adversarial-review rounds
  growing the list 31 → 65 → **73**. Residual retained primitives
  (`compile` / `signal` / `debug/*`, selected `os/*` metadata) are
  named in the threat model — they are not a silent reopen of G2.
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
