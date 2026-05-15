# mast

[![CI](https://github.com/SMC17/mast/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/mast/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SMC17/mast?include_prereleases&sort=semver)](https://github.com/SMC17/mast/releases)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

> Single-binary editor kernel. Buffer-as-protocol. Janet-extensible. AGPL.

`mast` is the load-bearing spar everything else hangs off — buffers, agents, search, audit. It is not "an editor with features." It is a substrate that ships with editing as one application. Compiler integration, debugger, file manager, agent orchestration, knowledge-graph queries, and audit-register operations are all first-class applications of the substrate, written against the same primitives.

This is Emacs's architectural lesson — *every operation that touches the buffer goes through a public scriptable surface* — applied to the appliance-layer era of multi-agent software.

## Status: v1.2.0 — substrate stable, surface layers roadmap

Foundation-first. The v1.x line stabilizes the load-bearing substrate
gates; the visual / multi-buffer / agent layers stay explicitly in the
roadmap, not in this release.

Substrate (stable in v1.x, green on Linux x86_64 + Apple Silicon arm64):

| Gate | Status |
|---|---|
| 1. Janet embeds cleanly in a Zig binary | ✓ |
| 2. Buffer-as-protocol shape specified | ✓ |
| 3. M-x command runner dispatches | ✓ |
| 4. File-write buffer ops + atomic save (v1.1.0) | ✓ |
| 5. 7200-trial property corpus + buffer-protocol benchmark (v1.2.0) | ✓ |

What's still on the roadmap (NOT in v1.2.0): visual TUI, local-inference
daemon, multi-buffer state, native Windows. See `CHANGELOG.md` for the
full per-tag scope. The v1.x API on the substrate gates above is locked —
breaking changes wait for v2.0.

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
M-x display                    # render current buffer
M-x append some new content    # append text + newline; marks buffer dirty
M-x save                       # atomic write-back (tmp + fsync + rename)
M-x save-as /tmp/new.md        # save to a new path; buffer becomes :file
M-x stax-search "query here"   # delegates to stax-search if installed
M-x exit
```

### Atomic save

`M-x save` writes to a temporary file in the same directory (`<path>.tmp.<pid>`), `fsync`s it, then `rename(2)`s it into place. A crash mid-write cannot truncate the original file — the rename is atomic on a single filesystem, and the fsync makes the post-rename content durable.

Unrecognised verbs are evaluated as raw Janet:

```
M-x (+ 1 2)
  → 3
```

## Extending — `init.janet`

On startup, mast reads `$XDG_CONFIG_HOME/mast/init.janet` (default `~/.config/mast/init.janet`) and evaluates it in the live Janet env. Anything you define there is available at the first `M-x` prompt. A starter file is in `examples/init.janet`:

```janet
(def hello       (fn [name] (string "hello, " name)))
(def buffer-info (fn []     (if (buffer-name)
                              (string "buffer: " (buffer-name) ", " (buffer-size) " bytes")
                              "no buffer open")))
```

Then at the prompt:

```
M-x (hello "world")
  → hello, world
M-x (buffer-info)
  → no buffer open
```

The eval happens before the REPL starts and any error is non-fatal — mast still drops you into the prompt and the audit log records the failure.

## Security / Sandbox

mast embeds a Janet VM and evaluates user-supplied forms in-process. The
v1 sandbox is a **first slice of a capability model**, not OS isolation —
see `docs/SANDBOX_THREAT_MODEL.md` for the full posture, asset inventory,
and explicit residual gaps. Today only `exec`-class bindings (`os/shell`
and the host-bound `stax-bash`) are gated; `os/execute`, `os/spawn`,
`file/*`, `net/*`, `native`, `unmarshal`, `os/exit` remain ungated and
are tracked as v2 work.

### `MAST_SANDBOX_STRICT`

Set `MAST_SANDBOX_STRICT=1` (also accepts `true`/`yes`/`on`,
case-insensitive) to suppress the v1 host-policy auto-grant of `exec`.
The production binary then runs in the same default-deny posture the
sandbox unit tests prove on a fresh VM: any verb that shells out
(`M-x stax-search`, `M-x stax-dashboard`, `M-x stax-hunger`,
`(os/shell ...)`, `(stax-bash ...)`) fails loudly with
`denied capability: exec`.

```sh
MAST_SANDBOX_STRICT=1 ./zig-out/bin/mast
M-x stax-dashboard
  → error: mast.sandbox: stax-bash denied — capability `exec` not granted (default-deny)
```

What strict mode buys you: the deny-by-default claim is now observable
end-to-end against the shipped binary, not just the test rig. What it
does NOT buy you: defense against any of the `exec`-adjacent residual
gaps (`os/execute`, `os/spawn`, `posix-fork`, `posix-exec`) — those are
not gated at all in v1 and remain reachable under strict mode.
`MAST_SANDBOX_STRICT=0` / unset / `false` / `no` / `off` leaves the
default policy in place.

## Why "mast"

A mast is the load-bearing spar everything hangs off — sails, rigging, cargo nets, flags. In the substrate metaphor it is the single primitive everything composes through: a buffer hangs off the protocol, an agent hangs off a buffer, an audit event hangs off an agent. The name is Lineage-compatible — the merchant marine is a recurring anchor in the [Lineage series](https://github.com/SMC17/stax-blog) of biographical merchant studies — without coining a new "sovereign-X" term.

## Architecture

See `docs/SPEC.md` for the full architectural sketch and `docs/STRATEGIC_POSITION.md` for the positioning vs Emacs / VS Code / Cursor. Highlights:

- **Buffer-as-protocol.** Every observable object exposes `read`, `write`, `subscribe`, `mark`, `mode`, `properties`. There is no second access path.
- **Extensibility through Janet.** Janet was chosen because it embeds cleanly in a single Zig binary, supports interactive REPL evaluation against the live editor process, and exposes the buffer surface as a first-class scripting target. See `docs/EXTENSIBILITY_LANGUAGE.md` for the decision memo.
- **Agent integration through CLIs, not network sockets.** Editor commands that invoke an agent route through locally-installed CLIs (`stax-spawn`, `stax-search`, etc.) — never directly to a frontier API. This is an architectural commitment, not a configuration option.
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
