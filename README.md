# mast

[![CI](https://github.com/SMC17/mast/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/mast/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/SMC17/mast?include_prereleases&sort=semver)](https://github.com/SMC17/mast/releases)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or-later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

> Single-binary editor kernel. Buffer-as-protocol. Janet-extensible. AGPL.

`mast` is a small editor kernel with one design commitment: every observable object (buffers, modes, prompts, audit events) is reachable through one scriptable protocol. That protocol is reachable from Janet at runtime. There is no second access path.

The Emacs lesson — that any operation that touches the buffer should go through a public scriptable surface — applied as the load-bearing constraint, with the Zig host kept small enough (`src/` is readable end-to-end in an afternoon) that the buffer protocol is the integration story rather than a feature list.

## Status — pre-1.0 substrate

Despite the `v1.0.0` → `v1.5.0` git tag progression, mast is pre-1.0
in semver spirit. Two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the language hits 1.0, no
   Zig project can credibly claim API stability beyond "stable on Zig
   0.16 today."
2. **No production deployment.** Zero real-traffic operation, zero soak
   time, zero production-incident history. The v1.x tags mark a
   *shipping-process hygiene* milestone (LICENSE / SECURITY / CONTRIBUTING
   / CI / CODE_OF_CONDUCT / dependabot / CODEOWNERS) — necessary, not
   sufficient, for "production-grade."

Proof vocabulary used below: `sketch`, `scaffold`, `compiled`,
`unit-tested`, `integration-tested`, `audited`, `benchmarked`,
`hardware-verified`. Stronger words than the evidence are Type I.

What does work, measured on Linux x86_64 (Zig 0.16.0, 2026-08-20):

| Gate | Proof | Evidence |
|---|---|---|
| Janet embeds in a Zig binary | `compiled` | vendored Janet, single binary, `zig build` |
| Buffer-as-protocol | `unit-tested` | `docs/buffer-protocol.md`, in-source tests in `src/buffer.zig` |
| M-x command runner | `unit-tested` | `docs/SPEC.md`, in-source tests |
| File-write + atomic save | `unit-tested` | tmp + fsync + rename |
| Buffer-protocol property corpus + bench | `benchmarked` | see `BENCH.md` (existing numbers; no new benches in this ship) |
| G2 sandbox closure | `audited` (self-applied) + `unit-tested` | **73** dangerous Janet bindings removed via panic stubs; install + test iterate the same static list; not an independent review (G4 open) |
| Resource quota — wall-clock | `integration-tested` | `tests/quota_integration.sh` 8/8 against the shipped binary |
| Multi-buffer ring | `integration-tested` | `tools/doctest.sh` lifecycle |
| Agent-as-buffer sync + async | `integration-tested` | `tools/doctest.sh` `agent/run` / `agent/spawn` / `agent/wait` |
| In-house ANSI/termios TUI | `integration-tested` | `mast --tui [file]` doctest (alt-screen + `q` exit) |
| Host-cfunction regression scan | `audited` (static) | `tools/cfunction-audit.sh` wired into `zig build test`; 2026-08-20: 35 cfunctions, 2 gated, 33 benign, 0 violations |
| README/code drift | `integration-tested` | `zig build doctest` → `tools/doctest.sh` **25/25 PASS** (2026-08-20) |
| Skill system | `unit-tested` | `src/skills.zig` 5 tests |
| Plan substrate | `unit-tested` | `src/plan.zig` 7 tests |
| Proof gate | `unit-tested` + `integration-tested` | `zig build test` → **180/180 tests passed** (Linux x86_64, 2026-08-20) |

macOS arm64 is a CI target (`compiled` when that workflow is green). This
session did not re-run macOS. Do not treat a Linux pass as a multi-OS soak.

**Gates still open before "production-grade" honestly fits:**

- **G1 — Real Janet script under load.** Partially closed:
  in-tree `examples/init.janet` (178 lines) loads. Operator home-config
  size is not a repo receipt. Soak time is the missing piece.
- **G3 — Soak time.** ≥30 days of continuous use as the daily editor
  with audit log retained and reviewed for capability-deny anomalies.
  **Not yet started. Not claimed.**
- **G4 — Independent security review.** Second pair of eyes on
  `src/sandbox.zig` + `docs/SANDBOX_THREAT_MODEL.md`. Not yet done.
  Internal substitute (self-applied threat model + mutation suite +
  `cfunction-audit.sh` + 25/25 doctest) is the strongest current
  substitute, not a replacement.
- **G5 — Zig 1.0.** Out of this repo's control.

Roadmap items still open: local-inference daemon, native Windows,
TUI per-row damage tracking (frame-level shipped v1.3.2; row-level
diff deferred), `pidfd_open`/`kqueue` agent poll (current `poll(2)`
backstop wakes every 500ms). See `CHANGELOG.md` for per-tag scope.
Full proof index: `STATUS.md`.

## Build

Requires Zig 0.16+. No system Janet, no system deps beyond libc + (on Linux) pthread/dl/rt.

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/mast --help
```

The amalgamated Janet source (3.3 MB) is vendored at `vendored/janet/janet.c`; the Zig build compiles it directly. No external `make` required.

Proof gate:

```sh
zig build test
```

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
M-x stax-search hello          # delegates to stax-search if installed
M-x exit
```

The M-x dispatcher currently splits on whitespace. Quoted multi-word
arguments are not parsed; use a single token or a Janet form.

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

## Agentic primitives (v1.5)

Three interlocking systems shipped in v1.5.0. All require an `init.janet`
that loads the surface (see `examples/init.janet` Section 7). Skills and
plan are `unit-tested`. The verify verbs are gated on `exec` and require
a locally installed verification pipeline; they are not a soak.

### Skills — Janet plugins from disk

Drop a `*.janet` file with a comment-header frontmatter block into
`~/.config/mast/skills/<category>/`:

```janet
# name: type1-audit
# version: 0.1.0
# category: verification
# description: Run 4-stage adversarial verification
# requires: exec

(defn run [& args]
  (verify/run (first args)))
```

```
M-x (skill/reload)                           # re-scan skills dir
M-x (skill/list)                             # array of {name description}
M-x (skill/run "type1-audit" "notes.md")     # invoke by name; requires: exec gate enforced
```

### Plan substrate — session plan + append-only log

```
M-x (plan/propose "implement X" nil "zig build test" "src/x.zig")
  → 1                                        # task id
M-x (plan/propose "write tests" 1 "64 pass" "")
  → 2                                        # child of task 1
M-x (plan/status 1 "done")
M-x (plan/compact)                           # removes done+verified leaf tasks
  → 1                                        # tasks removed
M-x (plan/context)                           # compact serialization
  → plan (1 active):
    [pending] 2: write tests
      verify: 64 pass
```

Tasks persist only for the session; the JSONL event log at
`$XDG_STATE_HOME/stax/plan-events.jsonl` (default
`~/.local/state/stax/plan-events.jsonl`) is append-only.

### Adversarial verification loop

Wires a 4-stage local verification pipeline as a mast tool. Requires the
pipeline installed and the `exec` capability granted. This is not an
independent security review (see G4).

```
M-x (verify/run "path/to/claim.md")         # async; returns agent handle
M-x (verify/buffer)                          # async verify of current buffer
M-x (verify/buffer-wait)                     # blocking; opens proofs/*.verified.md as new :file buffer
```

`verify/buffer-wait` derives the proof output path from the pipeline's
`$REPO_ROOT/proofs/<basename>.verified.md` convention before spawning,
polls stdout until exit, then opens the result as a new buffer at the
returned index.

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
  mutants, not coverage gaps. Last recorded result: 8/10 killed.
  Not re-run in this session.
- **Drift-proof removed-bindings list.** 73 panic-stubbed Janet
  bindings (`os/execute`, `os/spawn`, `file/*`, `net/*`, `native`,
  `unmarshal`, `os/exit`, plus later adversarial-review closures)
  are iterated by both the static `REMOVED_BINDINGS` list and the
  `G2 closure` test. Adding to one without the other trips CI.
- **Observable strict-mode posture.** `MAST_SANDBOX_STRICT=1` flips
  the default-grant policy; the deny-by-default claim is observable
  against the shipped binary, not just the test rig. The 5/5
  strict-mode integration test runs in `zig build test`.
- **README/code drift check.** `tools/doctest.sh` runs the README's
  example invocations against the shipped binary. 25/25 PASS on
  2026-08-20 (`zig build doctest`).

## Security / Sandbox

The sandbox is a **Janet-script-level capability model**, not OS isolation —
see `docs/SANDBOX_THREAT_MODEL.md` for the full posture, asset inventory,
and explicit residual gaps.

G2 (the named ungated surface from v1: `os/execute`, `os/spawn`,
`file/*`, `net/*`, `native`, `unmarshal`, `os/exit`) is closed by
*removal*: those symbols resolve to panic stubs. Subprocess is narrowed
to `os/shell` + host-bound `stax-bash`, both gated on the `exec`
capability. Residual gaps that remain (compile/signal/debug retained
because removing them breaks the language; some `os/*` metadata
bindings retained as low-severity) are listed in the threat model.
They are not "ungated exec." Do not read "capability model" as
"container."

### `MAST_SANDBOX_STRICT`

Set `MAST_SANDBOX_STRICT=1` (also accepts `true`/`yes`/`on`,
case-insensitive) to suppress the host-policy auto-grant of `exec`.
The shipped binary then runs in the same default-deny posture the
sandbox unit tests prove on a fresh VM: any verb that shells out
(`M-x stax-search`, `M-x stax-dashboard`, `M-x stax-hunger`,
`(os/shell ...)`, `(stax-bash ...)`) fails loudly with
`denied capability: exec`.

```sh
MAST_SANDBOX_STRICT=1 ./zig-out/bin/mast
M-x stax-dashboard
  → error: mast.sandbox: stax-bash denied — capability `exec` not granted (default-deny)
```

What strict mode buys you: the deny-by-default claim is observable
end-to-end against the shipped binary, not just the test rig. What it
does NOT buy you: OS isolation, defense against retained language
primitives (`compile`, `signal`, `debug/*`), or G4 (independent
review). `MAST_SANDBOX_STRICT=0` / unset / `false` / `no` / `off`
leaves the default policy in place.

## Why "mast"

A mast is the load-bearing spar everything hangs off — sails, rigging, cargo nets, flags. In the kernel metaphor it is the single primitive everything composes through: a buffer hangs off the protocol, an agent hangs off a buffer, an audit event hangs off an agent.

## Architecture

See `docs/SPEC.md` for the architectural sketch and
`docs/EXTENSIBILITY_LANGUAGE.md` for the Janet decision. Highlights:

- **Buffer-as-protocol.** Every observable object exposes `read`, `write`, `subscribe`, `mark`, `mode`, `properties`. There is no second access path. This is a design commitment, not a property proven against adversarial input.
- **Extensibility through Janet.** Janet was chosen because it embeds cleanly in a single Zig binary, supports interactive REPL evaluation against the live editor process, and exposes the buffer surface as a first-class scripting target.
- **Agent integration through CLIs, not network sockets.** Editor commands that invoke an agent route through locally-installed CLIs — never directly to a frontier API. This is an architectural commitment, not a configuration option.
- **Append-only audit log.** Every editor session writes to `$XDG_STATE_HOME/stax/editor-sessions/<session-id>.jsonl`. The kernel cannot lie to its future self about what it did.

## Honest risks — Type I and Type II

**Type I — what could be overclaimed.** The v1.x git tags are a
shipping-process hygiene milestone, not a maturity certificate. This
kernel is not a measured replacement for any other editor, and it has
no published user count. The mutation-suite-kills-M01 claim refers to
*one* load-bearing mutation; 8 of 10 mutations killed, 2 documented as
equivalent — the residual surface is the 2-survivor classification.
The "buffer-as-protocol" architectural framing reflects a design
decision, not a property proven against adversarial input. The
property corpus is on the buffer protocol, not on the Janet sandbox.
G3 soak has not started. G4 independent review has not happened.
Self-applied adversarial review is not external review.

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

The vendored Janet runtime stays under its original MIT license at `vendored/janet/LICENSE`.

## Contributing

Issues and discussion welcome. The kernel is small enough to be read
end-to-end in an hour. Useful paths right now:

1. Buffer-protocol refinements (see `docs/buffer-protocol.md`).
2. Additional built-in M-x commands that compose with other local CLIs.
3. Platform smoke tests on architectures other than x86_64 Linux / arm64 macOS.
4. TUI per-row damage tracking (v1.3.2 ships frame-level diff —
   "skip emit if frame identical." Row-level diff would only emit
   changed rows on large terminals).
5. Real `poll(2)` on both stdout_fd AND the child (`pidfd_open` on Linux,
   `kqueue` on macOS) — current code uses `poll(2)` on stdout_fd with a
   500ms backstop waitpid.
6. Skill / plan persistence across sessions — the plan JSONL log
   persists; the in-memory task list does not.

Do not claim G3, G4, production-grade, or a user count in a PR.
