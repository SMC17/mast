# Extensibility Language Decision

**Decision deadline (per SPEC.md §3.2):** Q2 2026.
**Date of this memo:** 2026-05-13.
**Status:** decision memo. **AUDITED on both Linux AND Apple Silicon (arm64)** as of 2026-05-13. Linux build: 945 KB stripped, 5/6 criteria pass + valgrind clean. Apple Silicon build: 962 KB Mach-O arm64, all 3 smoke-test checks green (eval round-trip, Zig-fn registration, error-path detection). Janet decision is locked for the substrate's v0.1 commit-zero. See `~/mac-mining/editor-substrate/build-tests/janet-zig-smoke/RUN_LOG.md`.
**Companion:** `~/mac-mining/editor-substrate/SPEC.md`, `~/blog/content/posts/apple-next-pixar-emacs.md`.

---

## 1. Why this decision is load-bearing

The extensibility language is the choice the substrate cannot revise after commit zero without rewriting the kernel. Every editor command, every agent surface, every user customization will route through it. Emacs is what it is because of Elisp, not because of buffers. Pick wrong, and the substrate carries the wrong scripting architecture for 10+ years.

The four hard constraints from `SPEC.md`:

- Embeddable in a single Zig binary.
- Interactive REPL evaluation against the live editor process.
- First-class binding to the buffer-as-protocol surface.
- Total runtime small enough to keep the substrate under 10 MB.

Two soft constraints from doctrine:

- License-clean against AGPL host (no copyleft drag from a GPL extension language onto AGPL host code; permissive is preferred).
- Mature enough to bet a v0.1 ship on (no alpha projects in the kernel).

---

## 2. The candidates

| Candidate | License | Maturity | Runtime size | Embed surface | Apple Silicon | Lisp fidelity |
|---|---|---|---|---|---|---|
| **Janet** | MIT | high (since 2017) | ~1 MB binary | C API, single header | native (no JIT) | high (Scheme-influenced) |
| **Fennel** | MIT | high (since 2016) | 300 KB Fennel + Lua (~500–800 KB total) | Lua C API (indirection) | native via PUC Lua; LuaJIT weak on arm64 | medium (Clojure-style) |
| **Guile** | GPL | highest (since 1995) | ~25–30 MB shared lib | `libguile` C API | mature | highest (R5RS + most R6RS) |
| **Element 0 (Elz)** | Apache-2.0 | alpha (v0.1.0-alpha.5, Dec 2025) | small (Zig-native) | `@import("elz")` | native (Zig) | high (R5RS-ish, growing) |

(Sources: each project's public docs page as of 2026-05-13. Janet at version 1.41.2; Fennel at 1.6.1; Guile at 3.0.11; Element 0 at v0.1.0-alpha.5.)

### Per-candidate detail

#### Janet — Calvin Rose, since 2017

The strongest substrate candidate. Single C library (`janet.h` + `libjanet.a`) with a documented embedding API covering type wrapping, eval, calling Janet from C, registering C functions as Janet callables, and an event loop. The runtime ships fibers (coroutines), multithreading, and a built-in PEG library. License is MIT — clean against the AGPL host. Version 1.41.2 in 2026, active maintainer, used in production at small scale by `andrewchambers` and the Spry web framework. The Lisp lineage is Scheme-influenced with optional Lua-style indented syntax.

What I can verify from the public docs: small runtime, clear C API surface, native Apple Silicon support, MIT licensing.

What I can't verify without a build: the actual Zig integration story. The Janet C API is conventional; `@cImport` should bind cleanly, but it needs a build test before we commit. Estimated time: half a day.

#### Fennel — Phil Hagelberg, since 2016

The strongest "substrate that already has a community" candidate. Fennel is a Lisp surface that compiles to Lua. Embed via the standard Lua C API. The Lua ecosystem (TIC-80, LÖVE 2D, Awesome WM, Neovim plugins via Hotpot, Wezterm config) means the editor inherits a large extension corpus on day one.

Two structural issues:

- Lua-the-language is a small surface; Fennel adds macros and a Lisp shape on top of it. Compared to Janet, the underlying primitives are weaker — Lua has tables, not first-class persistent data structures.
- LuaJIT is the performance story for Lua, and LuaJIT on Apple Silicon arm64 has known weaknesses (the `arm64` port lags `x86_64` and Mike Pall stopped active maintenance in 2022). PUC Lua works fine on Apple Silicon, but the perf delta vs Janet's native event loop is real for compute-heavy editor commands.

Runtime size is the win: 300 KB Fennel standalone + PUC Lua 5.4 (~250 KB linked) keeps the editor well under the 10 MB budget.

#### Guile — GNU project, since 1995

Out. Two reasons.

The first is license posture. Guile is LGPL-3.0+, which is technically compatible with AGPL-3.0+ host code but introduces a license-drag pattern the merchant-position memo (`STRATEGIC_POSITION.md`) deliberately forecloses. Apple's organizational reflex against LGPL dependencies is documented; LGPL would chill the absorbability thesis even when it's technically compatible.

The second is runtime size. Guile's shared library is in the 25–30 MB range, which alone breaks the substrate's ≤10 MB binary target. There's no path to a sub-10 MB binary with Guile linked.

Guile is the most Scheme-faithful candidate and the most production-proven (Guix, GnuCash, GDB extensions, Lepton-EDA). For a different substrate with different constraints, it would be the right call. For this substrate, no.

#### Element 0 (Elz) — habedi, alpha as of Dec 2025

The most architecturally appealing option that the foundation-first doctrine forbids us from picking right now.

Element 0 is a Zig-native embeddable Lisp, R5RS-ish, with the cleanest possible Zig integration (`@import("elz")`). 26 stars, 1 fork, 20 commits on main, latest release v0.1.0-alpha.5 (2025-12-21), uses BDWGC for garbage collection. Apache-2.0 licensed.

The foundation-first problem: this is an alpha project with one primary maintainer. Betting the substrate's extensibility layer on an alpha is exactly the failure mode `feedback_foundation_first.md` warns against. If Element 0 stops being maintained in 2027 — entirely plausible at this stage — the substrate has a kernel-shaped hole that's expensive to refill.

The bet I'd take instead: ship v0.1 on Janet, watch Element 0 for the next 12–18 months, and consider a v2.0 port to Element 0 (or its successor) once Zig-native Lisp ecosystem is production-mature. Defer rather than decline.

---

## 3. Decision matrix

Eight criteria, weighted by load-bearing impact on the substrate's strategic position.

| Criterion (weight) | Janet | Fennel | Guile | Element 0 |
|---|---|---|---|---|
| License clean vs AGPL host (high) | **MIT — best** | MIT — best | LGPL — drag risk | Apache-2.0 — best |
| ≤10 MB binary (high) | **~1 MB ✓** | ~800 KB ✓ | 25–30 MB ✗ | small ✓ |
| Zig embeddability (high) | C API via `@cImport` — clean | Lua C API — indirection | libguile.so — heavy | **native `@import`** |
| Apple Silicon perf (high) | **native, no JIT needed** | PUC Lua ok; LuaJIT weak | mature | native |
| Maturity (high) | **2017, active** | **2016, active** | **1995, most mature** | alpha, 2025 |
| Lisp lineage fidelity (medium) | high | medium | **highest** | high (growing) |
| Extension ecosystem reach (medium) | small but active | **large (Lua)** | large (Scheme + GNU) | tiny (early) |
| Foundation-first risk (high) | **low** | low | medium (size) | **high (alpha)** |

Tiebreaker matrix interpretation: Janet wins on six of the eight criteria, with Fennel tying on three and Element 0 winning on two (license + embeddability) but losing on the foundation-first criterion that vetoes everything else for v0.1.

---

## 4. Decision

**Janet is the chosen extensibility language for v0.1.**

The decision is gated on one verification step before commit zero: a build test that demonstrates `@cImport` of `janet.h` from a Zig host, with the Janet runtime registering a Zig function as a Janet callable, evaluating a Janet expression that calls it, and surfacing the return value back to Zig. Time budget: half a day. If the test surfaces a structural impedance mismatch between Janet's C API and Zig's `@cImport` (e.g., variadic macros that don't translate cleanly), revisit.

**Backup if the build test fails: Fennel.** The Lua C API is the most-translated FFI surface in the open-source world, and Zig binds Lua cleanly. The Lisp-fidelity downgrade is real but acceptable; the editor's substrate logic carries the Lisp surface, not the underlying primitives.

**Decline: Guile.** Size + license drag are structural disqualifiers for v0.1. Revisit only if the substrate's strategic geometry changes (it won't).

**Defer: Element 0.** Watch for v0.3+ maturity (target observation 2027-Q3). If Element 0 reaches production-grade maturity with multiple contributors and a stable API, a substrate v2.0 port becomes a credible bet. Until then, foundation-first forbids it.

---

## 5. Foundation-first verification (gates commit zero)

Three checks before the first commit lands. Each is small enough to ship in a day; all three are required.

1. **Janet build test.** Confirm `@cImport(janet.h)` works, native Zig function registration works, eval-and-return cycle works on both Apple Silicon and Linux. Output: a 30-line working sample at `~/mac-mining/editor-substrate/build-tests/janet-zig-smoke/`. Budget: half a day.

2. **Buffer-protocol binding sketch.** Write 1–2 pages on how Janet sees buffers. The mapping I'd start with: each buffer becomes a Janet table with `:read`, `:write`, `:mark`, `:point`, `:mode`, `:properties` keys whose values are either data or callables. Janet code never touches raw memory; the Zig host owns the buffer storage and exposes accessor callables. Output: `~/mac-mining/editor-substrate/buffer-protocol.md`. Budget: 1 day.

3. **Smallest "M-x command" cycle.** Demonstrate the editor reading user input, dispatching to a Janet-defined command, mutating a buffer, and rendering. Even at terminal-mock level, this proves the command-runner architecture is sound. Output: a working demo binary. Budget: 2 days.

Total foundation-first budget: 3.5 days. The commit-zero target shifts from Q3 2026 to ~Q3 2026 with these gates closed by end of Q2 2026.

---

## 6. Type-I / Type-II audit on this decision

**Type-I (overclaim) risk.** This memo claims Janet's C embedding is "clean" without having actually built against it from Zig. The verification step in §5 closes this gap, but until the build test runs, the decision is `sketch` not `audited`. The strategic position memo's voice ("Build the substrate. Ship the substrate.") should not be read as "Janet is verified to work in Zig"; it's "Janet is the chosen candidate, verification pending."

The "Guile is out on license" claim is a strategic-posture argument, not a legal one. LGPL-with-AGPL compatibility holds under the FSF's published guidance. The decline reason is the absorbability thesis from `STRATEGIC_POSITION.md` — Apple's organizational reflex against LGPL — which is itself a structural-pattern claim and not a documented Apple policy. Could be wrong. If Apple's organizational reflex changes, Guile becomes available again.

**Type-II (missed risk).** This memo doesn't deeply evaluate three options that could turn out to matter:

- **Wren** (Bob Nystrom's small embeddable language) — fast, lightweight, but class-based not Lisp-based. Out of scope for the Lisp-substrate thesis but worth flagging.
- **MicroScheme variants** (Chibi Scheme, Tinyscheme, S7) — small Scheme implementations that might match Janet on size while keeping Scheme-fidelity higher. Worth a follow-up evaluation in Q3 2026 before committing v0.1 if Janet's verification step surfaces an issue.
- **A second extensibility language in the binary** (e.g., Janet for command/UI logic + Lua for ecosystem reach). Adds complexity but might be the right call once the substrate has 10+ external users.

The decision is also conditional on Janet's maintenance staying active. Calvin Rose has been the primary maintainer since 2017; the bus factor is one person. If maintenance lapses, the substrate inherits a maintenance burden it didn't budget for. Mitigation: clone the Janet repo into the substrate's monorepo (Janet is MIT, so this is fully permitted), pin to a specific version, take on local patches as needed. Most editors that embed a language do this anyway.

---

## 7. What this unblocks

With Janet chosen (pending build test), the substrate's foundation-first chain is:

1. Janet build test → buffer-protocol binding sketch → M-x command-runner demo (this memo's §5, 3.5 days)
2. v0.1 kernel scope: buffer-as-protocol primitive + 4 built-in commands (SPEC.md §6, ≈ 4–6 weeks)
3. v0.1 AGPL public repository, OSS commit zero (SPEC.md §6, target Q3 2026 per the companion essay's Bet 1)

The next memo I owe is the buffer-protocol binding spec. Filing as a TODO under SPEC.md §3.1.

---

## 8. References

Public sources cross-checked 2026-05-13:

- Janet: <https://janet-lang.org/docs/index.html> (version 1.41.2, copyright © Calvin Rose & contributors 2026)
- Fennel: <https://fennel-lang.org/> (version 1.6.1, "Standalone binaries can be as small as 300kb", Lua compatibility model)
- Guile: <https://www.gnu.org/software/guile/> (version 3.0.11, 2025-12-01; LGPL; R5RS + most R6RS)
- Element 0: <https://github.com/Element0Lang/element-0> (v0.1.0-alpha.5, 2025-12-21; Apache-2.0; BDWGC)

Status: DRAFT — no public push. The decision becomes audited once the build test in §5 lands.
