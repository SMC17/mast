# mast

> **This is a syndication mirror.** Canonical origin lives at
> [sunlitmoon.online](https://sunlitmoon.online).
>
> The full README, documentation, BAKEOFF audit, benchmarks, and
> release notes are at the canonical origin. GitHub is kept as a
> private mirror for backup and historical reference.
>
> For collaboration: `sean@sunlitmoon.online`.

License: see [LICENSE](LICENSE).

---

## What mast is

A single-binary editor kernel for an era where you run many AI agents
in parallel and the editor is the air-traffic-control surface for that
fleet.

**Buffer-as-protocol** is the only access path: every observable object
in the editor (file on disk, output stream from a running CLI, tail of
an append-only event log, result list from a query) is a `Buffer`. The
editor binds a handful of cfunctions to Janet, and the rest of the
extensibility surface is Janet-side.

**Hard sandbox on the script side.** mast embeds Janet but does not let
a script reach the host process directly. The only granted shell-out
path is `os/shell` / `stax-bash`, both gated on the `exec` capability.
Every other dangerous Janet stdlib binding (`os/execute`, `os/spawn`,
`file/*`, `slurp`, `spit`, `dofile`, `net/*`, `native`, `unmarshal`,
`os/exit`) is removed from the embedded env and panics if invoked.
The threat model is at `docs/SANDBOX_THREAT_MODEL.md`; the closure is
test-iterated against a single static list so install-and-test cannot
drift.

**AGPL-3.0-or-later.** The licence is the architectural commitment, not
the marketing line. mast is designed to compose with the local CLI
fleet, not to call frontier APIs directly.

## v0.2 surface

- Multi-buffer ring with `M-x list-buffers` / `next-buffer` /
  `prev-buffer` / `switch-buffer N` / `new-buffer <name>`.
- `M-x agent-run <cmd>` (and the direct Janet form `(agent/run cmd)`)
  spawns `cmd` under the gated subprocess path, captures stdout into a
  new `:agent` buffer, switches focus to it, returns the new index.
  This is the v0.2 substrate for the agent-as-buffer model — each
  running command becomes a first-class editor object.
- `~/.config/mast/init.janet` loaded at startup. Reference config at
  `examples/init.janet`.
- Append-only audit log per session at
  `$XDG_STATE_HOME/stax/editor-sessions/<sid>.jsonl`.
- Atomic `M-x save` / `M-x save-as` (tmp + fsync + rename).
- `MAST_SANDBOX_STRICT=1` suppresses the v1 host policy's auto-grant of
  `exec`, so the production binary exhibits the same deny-by-default
  posture the unit tests prove.

## Honest version posture

The `v1.0` / `v1.1` / `v1.2` git tags are honored for changelog
continuity, but mast is pre-1.0 in semver spirit because Zig itself is
pre-1.0 and mast has zero production-deployment soak time. See
`STATUS.md` for the gate list (G1 init.janet under load, G2 sandbox
completeness, G3 soak, G4 independent review, G5 Zig 1.0) and which
ones are closed.

## Build

```
zig build                       # debug build to ./zig-out/bin/mast
zig build -Doptimize=ReleaseSmall
zig build test --summary all    # 49/49 tests as of 2026-05-22
```

Linux x86_64 + macOS arm64 are the supported targets. The build embeds
Janet via a vendored single-translation-unit `janet.c`; no system Janet
required.
