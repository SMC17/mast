# Changelog

All notable changes to `mast` will be documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### agent/spawn async + live-tail — 2026-05-19 (v0.3 of agent-as-buffer)

The synchronous `(agent/run cmd)` shipped earlier today has a non-blocking
sibling: `(agent/spawn cmd)` returns a handle id immediately, and the
:agent buffer accumulates stdout (and stderr) as `(agent/poll handle)` is
called. The full surface:

| Form | Behavior |
|------|----------|
| `(agent/spawn cmd)` | fork+exec `/bin/sh -c <cmd>` with non-blocking stdout+stderr pipe; create :agent buffer; return handle id |
| `(agent/poll handle)` | drain pipe → buffer; return exit status int if exited, nil if still running |
| `(agent/wait handle)` | block until exit (10ms poll loop); return exit status |
| `(agent/count)` | number of registered handles |
| `(agent/alive? handle)` | true if handle exists and is unclosed |

Lifecycle invariants:
- Handle id is the index into `g_agents`; never reused, never reordered.
- The :agent buffer at `h.buffer_idx` is owned by the buffer ring; the
  handle holds an index, not a pointer (the ArrayList could relocate on grow).
- `h.stdout_fd` is closed exactly once — when the child exits AND poll
  observes the exit (tracked by `h.closed`).
- Zombie reaping: `waitpid(WNOHANG)` runs on every poll; `agent/wait` loops
  polling + 10ms sleeps. Process exit reaps any still-running children
  with `SIGTERM` + final `waitpid` for cleanup.

Smoke-test evidence (interactive):

```
(def h (agent/spawn "echo line1 ; sleep 1 ; echo line2 ; sleep 1 ; echo line3"))
→ 0
(agent/alive? h)
→ true
(agent/poll h)
→ nil        ; still running
(agent/wait h)
→ 0          ; exit status, after ~2 seconds
display
── [:agent] echo line1 ; sleep 1 ; echo line2 ; sleep 1 ; echo line3 * ──
   1  line1
   2  line2
   3  line3
```

Many agents can run in parallel (each spawn returns its own handle). The
v0.3 surface is the actual "background fleet" foundation the steipete
frame names — addressable, pollable, composable.

Known gaps for v0.3.x:
- The poll loop in `agent/wait` is 10ms-sleep, not `poll(2)`-based.
  v0.3.x will route through real `poll(2)` on stdout_fd + child for
  better latency under many concurrent agents.
- No `agent/kill handle` yet (process exit reaps, but no in-session
  cancellation).
- No structured handle metadata via `(agent/info handle)` —
  closed state inferable via `agent/alive?` only.

### Residuals #6 + #7 closure — 2026-05-19 (v0.2.1)

Same `REMOVED_BINDINGS`-pattern closure applied to the two remaining
named residuals in `docs/SANDBOX_THREAT_MODEL.md` §6.

- **Residual #6 — environment-variable bindings.** `os/getenv`,
  `os/setenv`, `os/environ` REMOVED. Env vars routinely carry secrets
  (TOKEN_*, AWS_*, ANTHROPIC_API_KEY); no script-side granted path is
  honest in v0.2. v0.3 may add a host-bound allowlisted
  `(env/get "KEY_NAME")` with explicit per-key grants.
- **Residual #7 — ancillary filesystem-metadata bindings.** `os/stat`,
  `os/lstat`, `os/dir`, `os/realpath`, `os/readlink`, `os/mkdir`,
  `os/rmdir`, `os/rm`, `os/rename`, `os/touch`, `os/symlink`,
  `os/chmod` all REMOVED. Lower blast than the primary read/write
  path (already removed in G2), but a script could still enumerate
  the home directory or `chmod 777` a file. v0.3 path-prefix
  capabilities will reinstate granted paths.

The static `REMOVED_BINDINGS` list grows from 16 → 31 entries; the
load-bearing test (`G2 closure: every REMOVED_BINDINGS entry panics
from Janet`) iterates 31/31 invocations. 20/20 tests pass.

### G2 sandbox closure — 2026-05-19

The "residual ungated Janet surface" originally listed in
`docs/SANDBOX_THREAT_MODEL.md` §1 — `os/execute`, `os/spawn`, `file/*`,
`net/*`, `native`, `unmarshal`, `os/exit` — is closed via the
"removed from the embedded env" path the threat model itself named as
a valid closure. Symbols still resolve at Janet compile time, but
invoking them panics with a documented message naming the symbol and
pointing at the threat model.

- **Subprocess surface narrowed** to `os/shell` + `stax-bash`, both
  gated on the `exec` capability. `os/execute`, `os/spawn`,
  `os/posix-fork`, `os/posix-exec` REMOVED.
- **File I/O removed:** `file/open`, `file/temp`, `slurp`, `spit`,
  `dofile`. Host buffer ops (`M-x save` / `M-x save-as` / `M-x append`)
  are the v0.2 file-I/O interface.
- **Network removed:** `net/connect`, `net/listen`, `net/accept`,
  `net/accept-loop`. Host-bound HTTP cfunctions with explicit
  allowlists are v0.3.
- **RCE primitives removed:** `native` (which transitively blocks
  `.so` loading via `import`/`module/load`), `unmarshal`.
- **Host lifecycle:** `os/exit` REMOVED.

Drift-resistance: the install path (`sandbox.applyDefaultDeny`) and
the test (`G2 closure: every REMOVED_BINDINGS entry panics from Janet`)
both iterate the same static `REMOVED_BINDINGS` list — adding a
removal in one without the other trips CI.

Per-binding panic test runs with **every capability granted** so a
future regression that accidentally re-routes a removed binding
through a cap check shows up as a non-panic, not as a deny.

Residual gaps (named for honesty, deferred to v0.3): env-var bindings
(`os/getenv`/`setenv`/`environ`), ancillary filesystem-metadata
bindings (`os/stat`/`os/dir`/`os/mkdir`/etc.), resource quotas, audit-log
routing of deny events, host-cfunction regression discipline.

Tests: **20/20 pass**, including 2 new G2 closure tests
(`G2 closure: every REMOVED_BINDINGS entry panics from Janet`,
`G2 closure: applyDefaultDeny returns the expected number of replacements`).

STATUS.md G2 flips from `NOT YET CLOSED` to `CLOSED 2026-05-19`.

### Honesty correction — 2026-05-15

Prior `v1.0` / `v1.1` / "production-grade hygiene milestone" framing was a
Type-I error class per the no-premature-production-claims doctrine:

- **Zig itself is on 0.16, not 1.0.** No Zig project can credibly claim
  API stability beyond "stable on Zig 0.16 today" until the language
  itself ships 1.0. The v1.x git tags are honored for changelog
  continuity, but every reader should treat this as **pre-1.0 in semver
  spirit** until both that gate and a real-deployment gate close.
- **Zero production deployment exists.** No real-traffic operation, no
  soak time, no incident history. The hygiene work
  (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT / dependabot
  / CODEOWNERS) is real. The production claim it implied **wasn't
  earned.**

The mechanism work this cycle is what it is — neither more nor less:

- **Sandbox capability model is mechanism-proven on one binding.** The
  M01 mutation (the `g_sandbox.has(.exec)` sense flip on `os/shell`) is
  KILLED by the test suite. The load-bearing security check is
  mutation-resistant — that is the strongest honest claim. It is **not**
  a claim that mast is sandboxed; `docs/SANDBOX_THREAT_MODEL.md` §1 lists
  every still-ungated Janet binding (`os/execute`, `os/spawn`, `file/*`,
  `net/*`, `native`, `unmarshal`, `os/exit`).
- **`MAST_SANDBOX_STRICT` is posture-observable end-to-end.** Five
  integration cases (`tests/strict_mode_integration.sh`) spawn the built
  binary with the env var set and assert deny-on-stderr. This is
  observability of the gate that exists — not retroactive coverage of
  the residual ungated surface.
- **Buffer protocol + atomic file-write are unit-tested** (round-trip,
  append + dirty flag, atomic tmp+fsync+rename save, saveAs
  kind-conversion, partial-EOF reader-mock pinning the M09 boundary).
  That is `unit-tested`, not `integration-tested` against real editor
  workflows.
- **README/code drift is gated by 12/12 doctest checks** in
  `tools/doctest.sh`, including the 5/5 strict-mode integration cases it
  delegates to. The doctest gates README-to-binary drift, not narrative
  accuracy of design docs.
- **Mutation score is 8/10** (80%) after M09 closure, with the two
  survivors (M08 fd-zero, M10 mark-clamp no-op) classified honestly as
  equivalent mutants in `CHANGELOG.md` and `tools/mutation-test.sh`.

Going forward, the AGENT_HARNESS proof vocabulary (`scaffold` /
`compiled` / `unit-tested` / `integration-tested` / `audited` /
`benchmarked` / `hardware-verified`) is used strictly. See `STATUS.md`
for the per-component proof index and the gates (G1 real Janet under
load; G2 wrap the residual `os/execute`, `os/spawn`, `file/*`, `net/*`,
`native`, `unmarshal`, `os/exit` surface; G3 soak time; G4 independent
security review; G5 Zig 1.0) that would justify a stronger claim.

### Added

- **`tools/doctest.sh` + `zig build doctest`** — README claim verification harness. Twelve checks against the shipped binary, each one tied to an executable claim in `README.md`: documented build steps (`zig build`, `zig build test`) exist; `mast --help` prints the documented `usage: mast …` line; built-in M-x verbs `help` / `pid` / `exit` work as documented; the README Janet quickstart `M-x (+ 1 2)` → `→ 3` evaluates to the documented answer; `examples/init.janet` (referenced from README §Extending) loads on startup without a Janet parse/eval error and exposes the documented `(hello "world")` → `"hello, world"`; `MAST_SANDBOX_STRICT=1` strict-mode posture is observable end-to-end (delegates to `tests/strict_mode_integration.sh`, 5/5 cases); and `M-x stax-search` is gated under strict mode. 12/12 PASS. Same documentation-test discipline shipped in `zig-cobs`, `zig-frame-protocol`, `zig-graph`, `zig-h3`. The doctest step depends on the install step so the binary is present before checks run, and reuses `strict_mode_integration.sh` rather than duplicating its 5 cases. **README/code drift surfaced and annotated**: `README §Run` shows `M-x stax-search "query here"` with a quoted multi-word arg, but `parse_mx_line()` in `src/main.zig` whitespace-splits before any quote-aware handling, so the quoted form parse-errors via the Janet fall-through. The doctest exercises the unquoted form and the comment in `tools/doctest.sh` (Check 8) names the drift so a follow-up can either teach the parser about quotes or correct the README.

- **First slice of a capability model** (`src/sandbox.zig`, `docs/SANDBOX_THREAT_MODEL.md`): default-deny posture documented and worked end-to-end on one Janet stdlib binding — `os/shell` — plus the host-bound `stax-bash`. `os/execute`, `os/spawn`, `file/*`, `net/*`, `native`, `unmarshal`, and `os/exit` remain ungated; the threat-model doc lists every residual gap. Not a sandbox in the OS-isolation sense. Two unit tests cover deny + grant on `os/shell`.
- **`tools/mutation-test.sh`** — stylized mutation-testing harness applying 10 hand-picked operators across `src/sandbox.zig` (capability check + argc bounds + case-insensitive ASCII compare) and `src/buffer.zig` (file-IO boundaries). **M01 — the capability-check sense flip on `g_sandbox.has(.exec)` — is KILLED**: the load-bearing security claim is mutation-resistant in the test suite. Progression after this session's regression tests: 5/10 → 6/10 (eqAsciiCI A-Z) → 7/10 (stax-bash argc) → **8/10 (M09 read-loop partial-EOF — see entry below)** with 2 remaining classified honestly as equivalent mutants:
  - **M08 — equivalent mutant** (in practice): `Buffer.fromFile` calls `libc.open()` which only ever returns 0 if stdin is closed before the call. Under normal flow `fd >= 3`, so `fd < 0` vs `fd <= 0` are observationally identical.
  - **M10 — equivalent mutant**: `mark > copy.len` → `>=` differs only at `mark == copy.len`, where the clamp `self.mark = copy.len` is a no-op (`mark` is already `copy.len`). Identical externally-observable behavior in every reachable state.

- **M09 read-loop partial-EOF — KILLED** (was filed as REAL BUG, deferred). The mutant `rc <= 0` → `rc < 0` would cause `Buffer.fromFile` to spin in an infinite loop on a partial-EOF read (read returns 0 before `read_total == size` — possible on a pipe/socket that closes mid-stream, or any non-regular fd whose `st_size` overshoots what `read()` will deliver). Closed via a small Option-A refactor: the read loop was extracted into a free function `readToBuffer(read_fn, ctx, buf)` taking a `ReadFn = *const fn (ctx, ptr, len) isize` callable matching libc.read's shape. `Buffer.fromFile` now plumbs libc.read through a `LibcFdReader` adapter; the file-path behavior is unchanged byte-for-byte (the `:file` round-trip test still passes). The new test `readToBuffer: terminates on partial-EOF (pins M09 boundary)` uses a `PartialEofReader` mock that delivers N bytes on the first call then returns 0 forever, with a safety-cap that returns -1 after 1024 calls so a mutated build terminates rather than hanging the whole test binary. The test asserts both the byte count AND `call_count == 2` (one data call + one EOF call): under live code exactly two read() calls happen; under the mutant `call_count` blows past 2 to the safety-cap range, failing the equality and killing the mutant. Mutation harness re-run: 7/10 → 8/10 with M09 KILLED. Test count: 10 → 12 unit + 5 integration cases (added `readToBuffer: terminates on partial-EOF (pins M09 boundary)` + `readToBuffer: fills buffer when reader delivers exactly size bytes`).
- **`eqAsciiCI` A-Z boundary regression test** (sandbox.zig:288) — pins case-insensitive compare across every A-Z position plus the ASCII characters immediately before/after the letter ranges (`@`, `[`, `\``, `{`). Closed mutation finding M07 (`ca >= 'A'` → `ca > 'A'` slipped through because none of the existing truthy / falsy keywords contain a capital `A`).
- **`MAST_SANDBOX_STRICT` env var**: setting this to `1` / `true` / `yes` / `on` (case-insensitive) suppresses the v1 host-policy auto-grant of `exec`. The production binary then runs with the same default-deny posture the sandbox unit tests prove on a fresh VM — `M-x stax-search`, `M-x stax-dashboard`, `M-x stax-hunger`, `(os/shell ...)`, and `(stax-bash ...)` all fail with `denied capability: exec`. This moves the sandbox posture from **mechanism-proven (unit tests on a fresh VM)** to **posture-observable-end-to-end (production binary)**. Honest scope: strict mode demonstrates the gate that exists; it does not retroactively gate the still-ungated residual surface (`os/execute`, `os/spawn`, `file/*`, `net/*`, `native`, `unmarshal`, `os/exit`) — those v2 gaps remain reachable under strict mode. Documented in `README.md` (Security / Sandbox section) and `docs/SANDBOX_THREAT_MODEL.md` §5. One new unit test exercises the env-var parser (`strictModeFromEnv`: truthy/falsy/case-insensitive); one new integration test (`tests/strict_mode_integration.sh`, 5 cases) spawns the built binary with the env var set and asserts the deny diagnostic appears on stderr. Test count: 7 → 8 unit + 5 integration cases.

## [1.1.0] — 2026-05-13

First substantive feature release post-hygiene-v1.0.

### Added

- **File-write buffers.** `:file` buffers now support `save` and `save-as`. Writes are atomic: data goes to `<path>.tmp.<pid>`, `fsync` is invoked on the temp fd, then `rename(2)` swaps it into place — a crash mid-write cannot truncate the original file.
- **`Buffer.append(bytes)`** + **`Buffer.setContents(bytes)`**: mutating-buffer primitives. Both mark the buffer `dirty` for the save-state contract.
- **`Buffer.saveAs(path)`**: converts any buffer kind (`:agent`, `:search`, `:manifest`) into a `:file` rooted at the new path. The buffer's `name` and `kind` reassign on success.
- New built-in `M-x` verbs: `append <text…>`, `save`, `save-as <path>`. If `save-as` is invoked with no buffer open, mast creates an empty `:file` buffer at the path first (same semantics as `vim newfile.txt`).
- Dirty indicator (`*`) in the `M-x display` status header so users can see whether their buffer has unwritten changes.
- Audit-log events for every mutation: `buffer-create`, `buffer-append`, `buffer-save`, `buffer-saveas`, plus matching `mx-*-error` rows.
- **`zig build test`** step: 4 unit tests for the buffer protocol (round-trip, append+dirty, atomic save, saveAs kind-conversion). Wired into CI on both Linux x86_64 and Apple Silicon arm64.
- CI: new save-round-trip smoke (`save-as` → `append` → `save` → on-disk byte-match) on both platforms.

### Changed

- v1.x cycle continues per the Virgil convention: surface stable. The new `save` / `save-as` / `append` verbs are additive; no existing verb's semantics change.
- `main.zig` buffer storage moved from a function-local `var` to a module-level slot (`g_initial_buffer_storage`) so REPL-side commands like `save-as` can install a new buffer at runtime. v2.0 will replace this with a multi-buffer ring.

## [1.0.0] — 2026-05-13

**Production-grade hygiene milestone.**

- SECURITY.md present (coordinated disclosure policy).
- CODE_OF_CONDUCT.md (Contributor Covenant 2.1).
- Dependabot configured for github-actions security updates (monthly).
- CODEOWNERS routes review to @SMC17.
- LICENSE, README, CONTRIBUTING, CI workflow verified.
- v1.x cycle: surface stable; breaking changes bump to v2.x.

## [0.1.1] — 2026-05-13

### Added

- **`init.janet` loading**: on startup, mast reads `$XDG_CONFIG_HOME/mast/init.janet` (defaults to `~/.config/mast/init.janet`) and evaluates it in the live Janet env so user-defined commands are available at the first `M-x` prompt. This closes SPEC.md §6 v0.1 deliverable #5.
- **GitHub Actions CI** (`.github/workflows/ci.yml`): Linux x86_64 + macOS arm64 build matrix with Zig 0.16.0, asserts `M-x (+ 2 40)` → 42 (Janet eval fall-through) and `M-x display` renders a `:file` buffer.
- **README badges**: CI status, release version, license, Zig version.

### Fixed

- CI stderr capture: `std.debug.print` writes to stderr; the smoke test now uses `2>&1` so the OUTPUT capture sees what the user sees at the terminal.
- `audit.zig`: pointer-to-array-of-u8 (`*const [N:0]u8`, e.g. the string literal `"file"`) now serializes as `"file"` instead of `null` in the payload.

## [0.1.0] — 2026-05-13

Commit-zero. Foundation-first gates 1–3 green on Linux x86_64 and Apple Silicon arm64.

### Added

- Single-binary editor kernel built around three primitives:
  - **Janet** embedded via `@cImport` from a vendored amalgamated `janet.c` (MIT, Calvin Rose); no system runtime required.
  - **Buffer-as-protocol** — every observable object in the editor is a buffer; first-class kinds in v0.1 are `:file`, `:agent`, `:manifest`, `:search`.
  - **M-x command runner** — line-oriented dispatcher with positional arg substitution. Falls through to raw Janet eval for unrecognised verbs.
- Four built-in M-x commands shipped: `pid`, `help`, `stax-search`, `stax-dashboard`, `stax-hunger` (the last three shell out to the local stax-* CLIs when available).
- Cross-platform build (Linux x86_64, Apple Silicon arm64). Build artifacts: ~950 KB on Linux, ~962 KB on Mach-O arm64.
- AGPL-3.0-or-later license. Vendored Janet keeps its MIT license inline at `vendored/janet/LICENSE`.
- Companion docs: SPEC.md (architecture), EXTENSIBILITY_LANGUAGE.md (Janet decision memo), buffer-protocol.md (Janet ↔ Zig binding), STRATEGIC_POSITION.md (positioning vs Emacs / VS Code / Cursor).

### Not in v0.1

- Visual rendering / TUI. The runner is line-oriented. Cursor + windowing land in v0.2.
- File-writing buffers. v0.1 opens files but does not write them.
- Local-inference daemon. The runtime axis composes through `stax-*` CLIs only in v0.1.
- Multi-buffer state machine. v0.1 holds one buffer at a time.
- Windows native support. WSL2 only.

### Foundation-first gates passed

| Gate | Linux x86_64 | Apple Silicon arm64 |
|---|---|---|
| 1. Janet build test | ✓ 945 KB, valgrind clean | ✓ 962 KB Mach-O arm64, 3/3 checks |
| 2. Buffer-protocol binding sketch | ✓ docs/buffer-protocol.md | ✓ (platform-independent) |
| 3. M-x command-runner demo | ✓ 954 KB | ✓ Mach-O arm64 |
