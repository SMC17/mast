# mast

[![CI](https://github.com/SMC17/mast/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/mast/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SMC17/mast?include_prereleases&sort=semver)](https://github.com/SMC17/mast/releases)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

> Single-binary editor kernel. Buffer-as-protocol. Janet-extensible. AGPL.

`mast` is a small editor kernel with one design commitment: every observable object (buffers, modes, prompts, audit events) is reachable through one scriptable protocol. That protocol is reachable from Janet at runtime. There is no second access path.

The Emacs lesson — that any operation that touches the buffer should go through a public scriptable surface — applied as the load-bearing constraint, with the Zig host kept small enough (`src/` is readable end-to-end in an afternoon) that the buffer protocol is the integration story rather than a feature list.

## Status — pre-1.0 substrate, hygiene milestone reached

Despite the `v1.0.0` / `v1.1.0` / `v1.2.0` git tags, mast is pre-1.0
in semver spirit. Two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the language hits 1.0, no
   Zig project can credibly claim API stability beyond "stable on Zig
   0.16 today."
2. **No production deployment.** Zero real-traffic operation, zero soak
   time, zero production-incident history. The v1.x tags mark a
   *shipping-process hygiene* milestone (LICENSE / SECURITY / CONTRIBUTING
   / CI / CODE_OF_CONDUCT / dependabot / CODEOWNERS) — necessary, not
   sufficient, for "production-grade."

What does work, green on Linux x86_64 + Apple Silicon arm64:

| Gate | Status | Evidence |
|---|---|---|
| Janet embeds cleanly in a Zig binary | done | vendored Janet, single binary, `zig build` green |
| Buffer-as-protocol shape specified | done | `docs/buffer-protocol.md`, in-source tests in `src/buffer.zig` |
| M-x command runner dispatches | done | `docs/SPEC.md`, in-source tests |
| File-write buffer ops + atomic save | done | tmp + fsync + rename, unit-tested |
| 7200-trial property corpus + buffer-protocol benchmark | done | see `BENCH.md` |
| **G2 sandbox closure + 2-round adversarial review** (v1.3.0 → v1.3.4) | done | **65** dangerous Janet bindings removed via panic stubs; install + test iterate same static list; threat-model §6 residuals #6 (env), #7 (ancillary-fs), #13–#18 + #20 (adversarial-review-driven: file/* via os/open, FFI, audit JSON injection, ANSI escape injection, process-control, bytecode, agent/* DoS) all CLOSED |
| **Resource quota — wall-clock** (v1.3.5) | done | SIGALRM + janet_interpreter_interrupt + MAST_EVAL_TIMEOUT_SEC env var (default 30s); `(while true 1)` cleanly interrupted; editor recovers without dying; closes threat-model §6 #8 wall-clock dimension |
| **Multi-buffer ring** (v1.3.0) | done | `M-x list-buffers` / `next-buffer` / `prev-buffer` / `switch-buffer N` / `new-buffer <name>`; doctest-verified lifecycle |
| **Agent-as-buffer — sync** (v1.3.0) | done | `(agent/run cmd)` + `M-x agent-run`: gated subprocess, capture stdout into `:agent` buffer |
| **Agent-as-buffer — async + live-tail** (v1.3.0) | done | `(agent/spawn cmd)` → handle; `agent/poll` / `agent/wait` / `agent/count` / `agent/alive?`; `agent/wait` uses `poll(2)` on stdout_fd with 500ms backstop |
| **In-house ANSI/termios TUI** (v1.3.0) | done | `mast --tui [file]`: alt-screen, raw-mode termios, line-numbered viewport, reverse-video status, minibuffer M-x with sentinel verbs |
| **Sandbox-deny audit routing** (v1.3.x) | done | `sandbox.g_deny_observer` fires BEFORE `janet_panicf`; main routes to `SessionAudit` as `sandbox-deny` records with category tag |
| **Host-cfunction regression discipline** (v1.3.x) | done | `tools/cfunction-audit.sh` enumerates every `janet_def` registration and FAILS on dangerous syscalls without cap-check; wired into `zig build test` |
| **README/code drift discipline** | done | `tools/doctest.sh` 25/25 PASS against shipped binary; covers build steps, multi-buffer lifecycle, agent sync+async cycles, --tui launch, G2 panic observability, strict-mode integration |

**Gates still open before "production-grade" honestly fits:**

- **G1 — Real Janet script under load.** Partially closed:
  `~/.config/mast/init.janet` is 207 lines / 25 verbs and loads
  cleanly. Soak time is the missing piece.
- **G3 — Soak time.** ≥30 days of continuous use as the daily editor
  with audit log retained and reviewed for capability-deny anomalies.
  Not yet started.
- **G4 — Independent security review.** Second pair of eyes on
  `src/sandbox.zig` + `docs/SANDBOX_THREAT_MODEL.md`. Not yet done.
  Internal substitute (self-applied threat model + 80% mutation
  score + `cfunction-audit.sh` static scan + 25/25 doctest) is the
  strongest current substitute, not a replacement.
- **G5 — Zig 1.0.** Out of this repo's control.

Roadmap items (NOT in v1.3.x): local-inference daemon, native Windows,
TUI damage tracker (full-redraw per keystroke today; adequate for
small terminals), resource quotas on pathological Janet scripts
(needs Janet fiber-level interrupt primitive not yet designed). See
`CHANGELOG.md` for per-tag scope.

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

## Empirical safety properties

mast is a Janet-embedding Zig binary that evaluates user-supplied forms
in-process. The capability model is a *first slice*, not OS isolation
— see `docs/SANDBOX_THREAT_MODEL.md` for the threat model, asset
inventory, and residual gaps.

What's been verified:

- **Mutation-resistant capability check.** `tools/mutation-test.sh`
  flips the load-bearing `g_sandbox.has(.exec)` sense; the suite kills
  the mutant. M01 is the one that matters for the security claim; M08
  (fd-zero) and M10 (mark-clamp no-op) are documented as equivalent
  mutants, not coverage gaps.
- **Drift-proof removed-bindings list.** Every panic-stubbed Janet
  binding (`os/execute`, `os/spawn`, `file/*`, `net/*`, `native`,
  `unmarshal`, `os/exit`) is iterated by both the static
  `REMOVED_BINDINGS` list and the `G2 closure` test. Adding to one
  without the other trips CI.
- **Observable strict-mode posture.** `MAST_SANDBOX_STRICT=1` flips
  the default-grant policy; the deny-by-default claim is now observable
  end-to-end against the shipped binary, not just the test rig. The
  5/5 strict-mode integration test runs in CI.
- **README/code drift check.** `tools/doctest.sh` runs the README's
  example invocations against the shipped binary. 12/12 PASS as of
  the last touched date in STATUS.md.

## Security / Sandbox

The v1 sandbox is a **first slice of a capability model**, not OS isolation —
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

A mast is the load-bearing spar everything hangs off — sails, rigging, cargo nets, flags. In the substrate metaphor it is the single primitive everything composes through: a buffer hangs off the protocol, an agent hangs off a buffer, an audit event hangs off an agent.

## Architecture

See `docs/SPEC.md` for the full architectural sketch and `docs/STRATEGIC_POSITION.md` for the positioning vs Emacs / VS Code / Cursor. Highlights:

- **Buffer-as-protocol.** Every observable object exposes `read`, `write`, `subscribe`, `mark`, `mode`, `properties`. There is no second access path.
- **Extensibility through Janet.** Janet was chosen because it embeds cleanly in a single Zig binary, supports interactive REPL evaluation against the live editor process, and exposes the buffer surface as a first-class scripting target. See `docs/EXTENSIBILITY_LANGUAGE.md` for the decision memo.
- **Agent integration through CLIs, not network sockets.** Editor commands that invoke an agent route through locally-installed CLIs (`stax-spawn`, `stax-search`, etc.) — never directly to a frontier API. This is an architectural commitment, not a configuration option.
- **Append-only audit log.** Every editor session writes to `~/.local/state/stax/editor-sessions/<session-id>.jsonl`. The substrate cannot lie to its future self about what it did.

## Honest risks — Type I and Type II

**Type I — what could be overclaimed.** The v1.x git tags are a
shipping-process hygiene milestone, not a maturity certificate. The
mutation-suite-kills-M01 claim refers to *one* load-bearing mutation;
8 of 10 mutations killed, 2 documented as equivalent — the residual
surface is the 2-survivor classification. The "buffer-as-protocol"
architectural framing reflects a design decision, not a property
proven against adversarial input. The 7200-trial property corpus is
on the buffer protocol, not on the Janet sandbox.

**Type II — what real risk might be missed.** A Janet embedding in a
single-binary process has a fundamentally larger attack surface than
no embedding. The strict-mode posture catches *operator-error
shell-out*; it does not catch a malicious Janet form that uses
allowed-by-default primitives in unexpected combinations. Plugins
that add native C bindings can re-introduce removed symbols without
tripping the static `REMOVED_BINDINGS` check (the check iterates
removed-from-Janet-env symbols, not all syscall-reachable code paths).
No measured behaviour on hostile Janet scripts. No SOC2 / FedRAMP /
third-party security review. Operators that need OS isolation should
layer mast inside a container or VM, not rely on the in-process
capability model alone.

## License

AGPL-3.0-or-later. See `LICENSE`.

The license is the architecture, not the legal afterthought. AGPL from commit zero so the substrate is *absorbable* by larger players without being closed-forkable by them. Dual-licensing is not on the table for v1.0.

The vendored Janet runtime stays under its original MIT license at `vendored/janet/LICENSE`.

## Contributing

Issues and discussion welcome. The substrate is small enough to be read end-to-end in an hour. The clearest contribution paths right now are:

1. Buffer-protocol refinements (see `docs/buffer-protocol.md`).
2. Additional built-in M-x commands that compose with other local CLIs.
3. Platform smoke tests on architectures other than x86_64 Linux / arm64 macOS.
4. ~~TUI damage-tracker for partial redraws~~ — **shipped in v1.3.2**
   via `tui.FrameState` + `tui.emit_with_damage`.
5. ~~`agent/kill handle` for in-session cancellation~~ — **shipped in
   v1.3.2** as `(agent/kill handle)` returning bool.
6. v0.4 vaxis re-evaluation post-Zig-1.0 (the v1.3.0 TUI is in-house
   ANSI because the build doctrine is single-binary zero-Zig-deps; this
   may relax once Zig 1.0 stabilizes the dep ecosystem).
7. TUI per-row damage tracking (v1.3.2 ships frame-level diff —
   "skip emit if frame identical." Row-level diff would only emit
   changed rows on large terminals; v0.4 work).
8. Real `poll(2)` on both stdout_fd AND the child (`pidfd_open` on Linux,
   `kqueue` on macOS) — v1.3.0 uses `poll(2)` on stdout_fd with a
   500ms backstop waitpid, which is fine for handfuls of agents but
   wakes the loop every 500ms even when nothing is happening.

