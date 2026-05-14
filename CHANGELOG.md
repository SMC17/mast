## v1.0.0 — 2026-05-13

**Production-grade hygiene milestone.**

- SECURITY.md present (coordinated disclosure policy).
- CODE_OF_CONDUCT.md (Contributor Covenant 2.1).
- Dependabot configured for github-actions security updates (monthly).
- CODEOWNERS routes review to @SMC17.
- LICENSE, README, CONTRIBUTING, CI workflow verified.
- v1.x cycle: surface stable; breaking changes bump to v2.x.

# Changelog

All notable changes to `mast` will be documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
