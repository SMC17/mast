# Changelog

All notable changes to `mast` will be documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`tools/doctest.sh` + `zig build doctest`** — README claim verification harness. Twelve checks against the shipped binary, each one tied to an executable claim in `README.md`: documented build steps (`zig build`, `zig build test`) exist; `mast --help` prints the documented `usage: mast …` line; built-in M-x verbs `help` / `pid` / `exit` work as documented; the README Janet quickstart `M-x (+ 1 2)` → `→ 3` evaluates to the documented answer; `examples/init.janet` (referenced from README §Extending) loads on startup without a Janet parse/eval error and exposes the documented `(hello "world")` → `"hello, world"`; `MAST_SANDBOX_STRICT=1` strict-mode posture is observable end-to-end (delegates to `tests/strict_mode_integration.sh`, 5/5 cases); and `M-x stax-search` is gated under strict mode. 12/12 PASS. Same documentation-test discipline shipped in `zig-cobs`, `zig-frame-protocol`, `zig-graph`, `zig-h3`. The doctest step depends on the install step so the binary is present before checks run, and reuses `strict_mode_integration.sh` rather than duplicating its 5 cases. **README/code drift surfaced and annotated**: `README §Run` shows `M-x stax-search "query here"` with a quoted multi-word arg, but `parse_mx_line()` in `src/main.zig` whitespace-splits before any quote-aware handling, so the quoted form parse-errors via the Janet fall-through. The doctest exercises the unquoted form and the comment in `tools/doctest.sh` (Check 8) names the drift so a follow-up can either teach the parser about quotes or correct the README.

- **First slice of a capability model** (`src/sandbox.zig`, `docs/SANDBOX_THREAT_MODEL.md`): default-deny posture documented and worked end-to-end on one Janet stdlib binding — `os/shell` — plus the host-bound `stax-bash`. `os/execute`, `os/spawn`, `file/*`, `net/*`, `native`, `unmarshal`, and `os/exit` remain ungated; the threat-model doc lists every residual gap. Not a sandbox in the OS-isolation sense. Two unit tests cover deny + grant on `os/shell`.
- **`tools/mutation-test.sh`** — stylized mutation-testing harness applying 10 hand-picked operators across `src/sandbox.zig` (capability check + argc bounds + case-insensitive ASCII compare) and `src/buffer.zig` (file-IO boundaries). **M01 — the capability-check sense flip on `g_sandbox.has(.exec)` — is KILLED**: the load-bearing security claim is mutation-resistant in the test suite. Progression after this session's regression tests: 5/10 → 6/10 (eqAsciiCI A-Z) → **7/10 (stax-bash argc)** with 3 remaining classified honestly:
  - **M08 — equivalent mutant** (in practice): `Buffer.fromFile` calls `libc.open()` which only ever returns 0 if stdin is closed before the call. Under normal flow `fd >= 3`, so `fd < 0` vs `fd <= 0` are observationally identical.
  - **M09 — REAL BUG, deferred**: read-loop `rc <= 0` → `rc < 0` causes an infinite loop on a partial EOF (read returns 0 before `read_total == size`). The fix is closable but needs a deterministic mid-stream-EOF fixture (pipe/socket controlled to return 0 after N bytes, or libc.read mocking). Filed for follow-up.
  - **M10 — equivalent mutant**: `mark > copy.len` → `>=` differs only at `mark == copy.len`, where the clamp `self.mark = copy.len` is a no-op (`mark` is already `copy.len`). Identical externally-observable behavior in every reachable state.
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
