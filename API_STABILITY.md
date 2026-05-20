# API stability

mast follows [Semantic Versioning 2.0.0](https://semver.org/) with
the caveats below.

## Pre-1.0 posture

Despite the `v1.x` tag pattern, this project is **pre-1.0 in semver
spirit** for two reasons documented in [STATUS.md](STATUS.md):

1. **Zig is on 0.16, not 1.0.** No Zig project can credibly claim
   long-term API stability beyond "stable on Zig 0.16 today."
2. **No production deployment.** mast has zero real-traffic
   operation, zero soak time, zero production-incident history. The
   v1.x git tags are hygiene-milestone markers (LICENSE / CI /
   SECURITY / CONTRIBUTING / CODEOWNERS / 7200-trial property tests
   / atomic save / mutation harness), not production-grade signals.

The v1.x tags will be honored for changelog continuity. The next
major milestone (the surface layers — visual TUI, multi-buffer,
local-inference daemon) is when v2.x will be considered.

## What's stable in v1.x

### The buffer protocol

The Buffer struct's public interface is the load-bearing API surface.
Within v1.x:

- `Buffer.Kind` enum: `.file | .agent | .manifest | .search`. New
  variants may be added at any minor version (consumers must use
  `else =>` exhaustively).
- `Buffer.fromBytes(allocator, kind, name, bytes)` — constructor.
- `Buffer.fromFile(allocator, path)` — file-backed constructor.
- `Buffer.append(text)` — append + mark dirty.
- `Buffer.setContents(new_bytes)` — destructive replacement +
  mark dirty.
- `Buffer.save()` — atomic save for `.file` kind buffers.
- `Buffer.saveAs(path)` — save + convert `.agent` → `.file`.
- `Buffer.deinit()` — free allocator-owned memory.

The struct fields (`kind, name, contents, mark, dirty`) are stable;
field types are documented in `src/buffer.zig`.

### The M-x verb surface

The built-in M-x verbs are stable. As of v1.3.0:

- **Core:** `pid`, `help`, `display`, `exit`
- **Buffer introspection:** `buffer-name`, `buffer-size`, `buffer-count`
- **Buffer mutation:** `append <text…>`, `save`, `save-as <path>`
- **Multi-buffer ring:** `list-buffers`, `next-buffer`, `prev-buffer`,
  `switch-buffer N`, `new-buffer <name>`
- **Agent-as-buffer:** `agent-run <cmd>`
- **stax-fleet bridges:** `stax-search Q`, `stax-dashboard`, `stax-hunger`
- **Raw Janet fall-through:** any line not matching a builtin is
  evaluated in the live Janet env

New verbs may be added at any minor version. Removal happens only at
a major version bump with the deprecation window below.

### The Janet C-callback ABI

The C-callbacks the Janet runtime invokes are stable in signature.
As of v1.3.0:

- `(stax-pid)`, `(buffer-name)`, `(buffer-size)`, `(buffer-count)`,
  `(buffer-current-index)`, `(buffer-next)`, `(buffer-prev)`,
  `(buffer-switch idx)` — host introspection / navigation
- `(agent/run cmd)` — sync spawn-and-capture (returns buffer index)
- `(agent/spawn cmd)` — async spawn (returns handle int)
- `(agent/poll handle)` — drain pipe, return exit-status int or nil
- `(agent/wait handle)` — block until exit, return exit-status int
- `(agent/count)`, `(agent/alive? handle)` — handle introspection
- `(stax-bash cmd)` — capability-gated shell-out

Adding new C-callbacks is a minor bump; renaming or removing existing
ones is a major bump with the deprecation window below.

### The TUI surface (v1.3.0)

The `--tui` CLI flag and the in-house ANSI/termios windowed view are
stable in v1.x. Key bindings (`j`/`k`/Up/Down scroll, `g`/`G`
top/bottom, `n`/`p` cycle buffers, `:` minibuffer, `q`/Ctrl-C exit)
may grow but will not change meaning at a minor version. The
underlying renderer (full-redraw per keystroke; row prefix; reverse-
video status; ANSI escape codes) is implementation detail subject to
change at minor versions.

## What's stable in the sandbox

Per [docs/SANDBOX_THREAT_MODEL.md](docs/SANDBOX_THREAT_MODEL.md):

- `os/shell` and `stax-bash` require the `exec` capability or panic —
  load-bearing default-deny, mutation-test M01 KILLED.
- `MAST_SANDBOX_STRICT=1` env var suppresses the v1 host-policy
  auto-grant of `exec` so the production binary exhibits default-deny.
- `gated_stax_bash` accepts exactly one argv element; any other count
  panics (M04 KILLED).
- **65-entry `REMOVED_BINDINGS` static list** (v1.3.0 base + v1.3.4 adversarial closures): the dangerous
  Janet symbols documented in threat-model §5.2 are removed from the
  embedded env via panic stubs. The static list and the load-bearing
  test (`G2 closure: every REMOVED_BINDINGS entry panics from Janet`)
  iterate the same set; adding to one without the other trips CI.
- **`sandbox.g_deny_observer` callback** (v1.3.x): host hook that
  fires BEFORE `janet_panicf` for every deny event. Categories enum
  (`exec_gated`, `subprocess`, `file_io`, `net`, `native`, `unmarshal`,
  `exit`, `dofile`, `env`, `fs_ancillary`) may grow at minor versions.
- The sandbox's `Capability` set may grow new variants at minor
  versions (consumers should handle unknown caps gracefully).
- **`tools/cfunction-audit.sh`** (v1.3.x): static check that every
  host-registered cfunction with a dangerous syscall in its body
  consults the capability set. Wired into `zig build test`.

## What's UNSTABLE

- The internal layout of `src/janet_c.zig` (the `@cImport` block).
- The exact bytes emitted by `M-x display` for various Buffer kinds —
  the prefix/format may change at any minor version.
- The JSON / TSV output of any future `--format=json` flags
  (currently unset; reserved for v2.x).
- The atomic-save tmp path naming (currently
  `/tmp/mast-{file}-{pid}.tmp`) — implementation detail.

## Deprecation policy

If a stable surface needs to change:

1. The new surface ships alongside the old in version `vN.M+1` with
   the old marked deprecated in the changelog.
2. The old surface continues to work for at least 6 months OR until
   the next major version, whichever is later.
3. Removal happens only at a major version bump.

## Verification

Releases from v1.2.0 onward are GPG-signed git tags:

```sh
git tag -v v1.X.Y
# gpg: Good signature from "stax release signer ..."
```

Public key fingerprint: `079261B06444C6A410B3BE363CFCB60243028886`
(also at [`release-signing.gpg.pub`](release-signing.gpg.pub) once
that file is added — currently mast carries GPG-only provenance,
not the cosign double-provenance the substrate-tier projects ship).

## Per-release scope

| Version | Substrate gates                                                | Major additions                                   |
|---------|----------------------------------------------------------------|---------------------------------------------------|
| v0.1.0  | initial buffer + Janet embed                                   | first release                                     |
| v0.1.1  | sandbox capability model + 4 sandbox tests                     | `MAST_SANDBOX_STRICT` env var                     |
| v1.0.0  | shipping-process hygiene milestone (still pre-1.0 in spirit)   | LICENSE / SECURITY / CONTRIBUTING / CODE_OF_CONDUCT |
| v1.1.0  | file-write buffer ops + atomic save + 12 doctest checks        | save / saveAs / mutation harness 8/10            |
| v1.2.0  | 7200-trial property corpus + buffer-protocol benchmark         | BENCH.md + 16/16 tests + GPG-signed tag           |
| v1.3.0  | G2 sandbox closure (31 removed bindings) + multi-buffer ring + agent-as-buffer (sync + async/live-tail) + in-house ANSI/termios TUI behind --tui | `(agent/spawn/poll/wait/count/alive?)`, `M-x list-buffers/next/prev/switch-buffer/new-buffer/agent-run`, `--tui` flag, 22/22 tests |
| v1.3.x  | residual closures: sandbox-deny audit routing (§6 #9) + agent/wait poll(2) (§6 #8 partial) + host-cfunction regression discipline (§6 #10) + TUI minibuffer sentinels | `tools/cfunction-audit.sh`, `sandbox.DenyCategory` + `g_deny_observer`, doctest extended to 25/25 |
| v1.3.2 / v1.3.3 | agent/kill + TUI damage tracker (frame + per-row) + sandbox property tests + Janet quota primitive identified + examples/init.janet expansion | `(agent/kill h)`, `tui.frame_changed` / `diff_rows`, 3 sandbox property tests, `janet_interpreter_interrupt` documented as v0.4 implementation path |
| v1.3.4  | **adversarial-review-driven security closures (round 1)** — fs bypass via os/open + parallel file/* methods, full FFI surface (15 syms), audit-log JSON injection, TUI ANSI escape injection (OSC 52 clipboard hijack), process-control survivors, bytecode constructors, agent/wait DoS under STRICT | 7 findings closed, 1 honest residual (#19 compile/signal/debug retained), REMOVED_BINDINGS grows 31 → 65, new DenyCategory variants `.ffi` / `.process_control` / `.bytecode`, audit.zig::writeJsonString + tui.zig::sanitize_into helpers with 7 new in-source tests |
| v1.3.5  | **wall-clock resource quota** — SIGALRM + janet_interpreter_interrupt + MAST_EVAL_TIMEOUT_SEC env var; cancelled fiber surfaces as mx-error, editor recovers without dying | closes threat-model §6 #8 wall-clock dimension; memory + fd quotas extend same primitive, deferred to v0.4 |
