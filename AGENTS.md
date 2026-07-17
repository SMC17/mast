# mast Agent Entry Point

Single-binary editor kernel (buffer-as-protocol, Janet-extensible) on Zig 0.16.

**Posture:** pre-1.0 in semver spirit (Zig 0.16; no production soak). Hygiene tags
are process milestones, not production-grade claims.

## Before you change anything

1. Read `README.md` and `STATUS.md`.
2. Read `docs/SANDBOX_THREAT_MODEL.md` before touching sandbox / Janet bindings.
3. Run the proof gate before claiming green.

## Proof gate

```sh
zig build test
```

## Allowed work

- docs/status reconciliation with honest pre-1.0 posture
- buffer protocol, modes, and gated agent surfaces with tests
- sandbox hardening that keeps REMOVED_BINDINGS drift-proof
- CI / proof-gate maintenance

## Forbidden without explicit operator intent

- sandbox bypass or ungated shell/exec
- private session logs in the tree
- live agent subprocess against non-owned systems
- credential access via Janet host
- "production-grade" / v1 stability claims while Zig is pre-1.0

## Escalation

Ask before sandbox model changes, capability grants, or agent/exec against
external systems.

## Hygiene

Org templates: `SMC17/stax-hygiene`.
