# mast status

Last touched: 2026-05-15

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
| Sandbox capability model (`os/shell` + `stax-bash`) | `audited` + `unit-tested`                          | `docs/SANDBOX_THREAT_MODEL.md` is the self-applied audit; `src/sandbox.zig` ships 6 in-source tests covering deny + grant + argc-bounds + ASCII-CI compare      |
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
  mutation + file saves + sandbox-gated calls. Status:
  `NOT YET CLOSED`.
- **G2 — Wrap the residual ungated Janet surface.** The threat model
  (`docs/SANDBOX_THREAT_MODEL.md` §1) names the surface that v1 does
  NOT gate: `os/execute`, `os/spawn`, `file/*`, `net/*`, `native`,
  `unmarshal`, `os/exit`. Each is reachable from a Janet script under
  strict mode today. Until these are wrapped (or removed from the
  embedded env), the sandbox is a *first slice*, not a complete
  capability model. Status: `NOT YET CLOSED`.
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

Only after G5 + at least one of G1 / G2 / G3 / G4 do the words
"production-grade" or "stable v1" honestly fit. Until then, mast
ships as a pre-1.0 substrate with mutation-proven mechanism on the
one binding it wraps, an observable strict-mode posture, and an
explicit list of residual gaps.
