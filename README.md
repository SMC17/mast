# mast

[![CI](https://github.com/SMC17/mast/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/mast/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SMC17/mast?include_prereleases&sort=semver)](https://github.com/SMC17/mast/releases)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

> Single-binary editor kernel. Buffer-as-protocol. Janet-extensible. AGPL.

`mast` is the load-bearing spar everything else hangs off — buffers, agents, search, audit. It is not "an editor with features." It is a substrate that ships with editing as one application. Compiler integration, debugger, file manager, agent orchestration, knowledge-graph queries, and audit-register operations are all first-class applications of the substrate, written against the same primitives.

This is Emacs's architectural lesson — *every operation that touches the buffer goes through a public scriptable surface* — applied to the appliance-layer era of multi-agent software.

## Status: v0.1.0 (commit-zero, 2026-05-13)

Foundation-first. Three gates are green on Linux x86_64 and Apple Silicon arm64:

| Gate | Status |
|---|---|
| 1. Janet embeds cleanly in a Zig binary | ✓ |
| 2. Buffer-as-protocol shape specified | ✓ |
| 3. M-x command runner dispatches | ✓ |

What's NOT in v0.1: visual TUI, file-writing buffers, local-inference daemon, multi-buffer state, native Windows. See `CHANGELOG.md` for the full v0.1 scope.

## Build

Requires Zig 0.16+. No system Janet, no system deps beyond libc + (on Linux) pthread/dl/rt.

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/mast --help
```

The amalgamated Janet source (3.3 MB) is vendored at `vendored/janet/janet.c`; the Zig build compiles it directly. No external `make` required.

## Run

```sh
# Interactive M-x dispatcher
./zig-out/bin/mast

# Open a file as a :file buffer
./zig-out/bin/mast README.md

# At the M-x prompt:
M-x help                       # built-in command list
M-x pid                        # show host PID
M-x stax-search "query here"   # delegates to stax-search if installed
M-x display                    # render current buffer
M-x exit
```

Unrecognised verbs are evaluated as raw Janet:

```
M-x (+ 1 2)
  → 3
```

## Why "mast"

A mast is the load-bearing spar everything hangs off — sails, rigging, cargo nets, flags. In the substrate metaphor it is the single primitive everything composes through: a buffer hangs off the protocol, an agent hangs off a buffer, an audit event hangs off an agent. The name is Lineage-compatible — the merchant marine is a recurring anchor in the [Lineage series](https://github.com/SMC17/stax-blog) of biographical merchant studies — without coining a new "sovereign-X" term.

## Architecture

See `docs/SPEC.md` for the full architectural sketch and `docs/STRATEGIC_POSITION.md` for the positioning vs Emacs / VS Code / Cursor. Highlights:

- **Buffer-as-protocol.** Every observable object exposes `read`, `write`, `subscribe`, `mark`, `mode`, `properties`. There is no second access path.
- **Extensibility through Janet.** Janet was chosen because it embeds cleanly in a single Zig binary, supports interactive REPL evaluation against the live editor process, and exposes the buffer surface as a first-class scripting target. See `docs/EXTENSIBILITY_LANGUAGE.md` for the decision memo.
- **Agent integration through CLIs, not network sockets.** Editor commands that invoke an agent route through locally-installed CLIs (`stax-spawn`, `stax-search`, `claude`, etc.) — never directly to a frontier API. This is an architectural commitment, not a configuration option.
- **Append-only audit log.** Every editor session writes to `~/.local/state/stax/editor-sessions/<session-id>.jsonl`. The substrate cannot lie to its future self about what it did.

## License

AGPL-3.0-or-later. See `LICENSE`.

The license is the architecture, not the legal afterthought. AGPL from commit zero so the substrate is *absorbable* by larger players without being closed-forkable by them. Dual-licensing is not on the table for v1.0.

The vendored Janet runtime stays under its original MIT license at `vendored/janet/LICENSE`.

## Contributing

Issues and discussion welcome. This is a v0.1 commit-zero — the substrate is small enough to be read end-to-end in an hour. The clearest contribution paths right now are:

1. Buffer-protocol refinements (see `docs/buffer-protocol.md`).
2. Additional built-in M-x commands that compose with other local CLIs.
3. Platform smoke tests on architectures other than x86_64 Linux / arm64 macOS.
4. A TUI renderer for v0.2 (`vaxis` is the leading candidate in the Zig ecosystem; bring receipts).

## Companion writing

The thesis that motivates this substrate is in [`apple-next-pixar-emacs`](https://github.com/SMC17/stax-blog) on the public blog. The broader Mercantile Thesis names the editor substrate as one of the eight appliance-layer axes the next decade will be decided on.
