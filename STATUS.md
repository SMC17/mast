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
| Sandbox capability model (`os/shell` + `stax-bash` gated; G2 residuals removed) | `audited` + `unit-tested`                          | `docs/SANDBOX_THREAT_MODEL.md` is the self-applied audit; `src/sandbox.zig` ships 8 in-source tests covering deny + grant + argc-bounds + ASCII-CI compare + every removed-binding panics from Janet (drift-proof against the static `REMOVED_BINDINGS` list) |
| Sandbox mechanism — capability check     | `audited` (mutation-proven)                       | `tools/mutation-test.sh` M01 — the `g_sandbox.has(.exec)` sense flip — is KILLED; the load-bearing security check is mutation-resistant                       |
| `MAST_SANDBOX_STRICT` env var            | `posture-observable-end-to-end`                   | `tests/strict_mode_integration.sh` 5/5 cases against the built binary; one in-source env-parser test (`strictModeFromEnv`); README §Security/Sandbox documents |
| Buffer protocol (`fromBytes` / `append` / `setContents`) | `unit-tested`                                     | 6 in-source tests in `src/buffer.zig` covering round-trip + dirty-flag + saveAs kind-conversion + partial-EOF mock                                              |
| File-write / atomic save                 | `unit-tested`                                     | atomic-save unit test in `src/buffer.zig` (tmp + fsync + rename); CI save-round-trip smoke (Linux x86_64 + macOS arm64)                                         |
| README/code drift                        | `unit-tested`                                     | `tools/doctest.sh` 12/12 PASS against the shipped binary, including the 5/5 `MAST_SANDBOX_STRICT` integration cases it delegates to                            |
| Mutation surface                         | `audited`                                         | `tools/mutation-test.sh` 8/10 killed after M09 read-loop closure; 2 survivors classified honestly as equivalent mutants (M08 fd-zero, M10 mark-clamp no-op)    |
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
  `NOT YET CLOSED`.
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
