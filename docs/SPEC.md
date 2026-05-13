# Editor Substrate — Architecture Sketch

**Working name:** TBD. Working directory: `~/mac-mining/editor-substrate/`. Internal handle: "the substrate" until a Lineage-compatible name lands.
**Doctrine anchors:** `feedback_cli_first_mcp_dead.md` (Zig CLIs as substrate, Elixir/BEAM orchestration), `feedback_no_paid_api_keys.md` (subscription-CLI auth + open weights), `project_three_os_mesh.md` (per-node mechanical sympathy), `project_sovereign_hardware_aether.md` (anti-cloud, supplier-independent intelligence), `feedback_foundation_first.md` (bottom-up; no upper layer before its substrate is solid), `feedback_no_sovereign_coinage.md` (no new sovereign-X names).
**Companion essay:** `~/blog/content/posts/apple-next-pixar-emacs.md` (DRAFT). The essay states the thesis. This file is the engineering substrate the essay depends on.
**Status:** scoping sketch, 2026-05-13. First-ship target Q3 2026 per the essay's Bet 1.

---

## 1. What the substrate is

A single-binary local-first editor kernel that exposes the buffer-as-protocol primitive, integrates natively with the existing stax agent fleet, runs on Apple silicon and on Linux as first-class targets, and ships under AGPL on day one.

The substrate is not an editor with features. It is a substrate that happens to ship with editing as one application. Compiler integration, debugger, file manager, agent orchestration, knowledge-graph queries, dream-cycle consolidation, and audit-register operations are all first-class applications of the substrate, written against the same primitives.

This is Emacs's architectural lesson applied to the appliance-layer era of the Mercantile Thesis. Every operation that touches the buffer goes through a public scriptable surface. Extensibility is not a feature, it is the architecture.

## 2. What it composes with (load-bearing dependencies)

Every one of these already exists locally. The substrate's first ship is the kernel that lets them compose through a single user surface.

- `~/.local/bin/stax-manifest` — the event log + `active` (fresh state) + `exit --artifact` (auditable exits). Buffer-state transitions become manifest events.
- `~/.local/bin/stax-spawn` — local + remote (tailnet) lane spawning with preflight. Editor commands that need an out-of-process agent route through this.
- `~/.local/bin/stax-search` — the M44 knowledge graph + semantic search over the 466-doc corpus. The editor exposes `M-x stax-search` as a first-class navigation operation.
- `~/.local/bin/stax-heartbeat` — fleet pulse JSONL. The editor reads this for status-line awareness.
- `~/.local/bin/stax-hunger` — per-pane lifecycle classification. The editor uses it to decide which agent to route a query to.
- `~/.local/bin/stax-dream consolidate` — application-layer dream cycle. The editor invokes it after every closed buffer or every N minutes idle, depending on session shape.
- `~/.local/bin/stax-dashboard` — single-screen fleet observability. The editor exposes a status pane sourced from this.
- `~/.local/bin/stax-cost` — token-burn parser. Editor surfaces a per-session $-meter in the modeline.
- `~/codex/` — the zettelkasten substrate. The editor exposes `M-x codex-link` and `M-x codex-promote-auto-derived`.

The dependency direction is one-way: the editor depends on the CLI substrate. The CLI substrate does not depend on the editor. The substrate's CLIs continue to work standalone; the editor adds a richer composition surface.

## 3. Architecture (first-ship scope)

### 3.1 Buffer-as-protocol primitive

Every observable object in the editor is a buffer. Files are buffers. Agent conversations are buffers. Heartbeat snapshots are buffers. Search results are buffers. Manifest event tails are buffers. The buffer interface exposes:

- `read` / `write` (with optional encoding)
- `subscribe` (inotify-style or polling-fallback for buffers backed by a file)
- `mark` / `point` / `region` (selection state)
- `mode` (a function-table of operations valid for this buffer)
- `properties` (key-value map with reserved keys for `agent-attached`, `last-event`, `dirty`, `derived-from`)

All editor commands operate on buffers through this interface. There is no second access path.

### 3.2 Extensibility layer

The substrate ships with one extensibility language. Candidate decision is open (Janet, Fennel, Guile, or a Zig-embedded interpreter). Hard requirements:

- It must be embeddable in a single Zig binary.
- It must support REPL-level interactive evaluation against the live editor process.
- It must expose the buffer-as-protocol surface as a first-class scripting target.
- It must have a runtime small enough to ship in a sub-10 MB binary.

Decision deadline: Q2 2026, before the v0.1 commit. The choice gates the entire substrate.

### 3.3 Agent integration

Editor commands that invoke an agent route through `stax-spawn` (for new agents) or `stax-manifest active` + `tmux send-keys` (for existing live lanes). The editor never opens a network connection to a frontier API directly; all auth flows through the locally-installed CLI's subscription auth or local OSS model. This is `feedback_no_paid_api_keys.md` enforced at the architecture level.

The editor presents three default agent surfaces:

- **Edit-this-buffer agent** — single-shot transformation of the current buffer. Routes to `claude` CLI by default with prompt + buffer as stdin.
- **Lane agent** — long-running task in a tmux-wrapped tab. Routes to `stax-spawn` and inherits the new preflight discipline.
- **Search agent** — read-only retrieval over the local corpus via `stax-search`. Returns a buffer of results, not a chat.

Each surface emits manifest events (`buffer-attached`, `agent-handoff`, `buffer-released`) so the dream cycle has the data it needs to consolidate.

### 3.4 Hardware-native runtime (deferred to ship 3)

The first ship doesn't include the local inference daemon. The buffer protocol is designed so a local-inference backend can replace the CLI-subscription-auth route without breaking buffer semantics. This is foundation-first: the editor kernel ships first; the local inference daemon ships when the kernel is solid.

### 3.5 Audit register integration

Every editor session emits a session-id that maps 1:1 to a manifest spawn event. Every `M-x` command that has side effects writes to a session-local audit log under `~/.local/state/stax/editor-sessions/<session-id>.jsonl`. The audit log is append-only; the substrate is durable across power loss.

This is the audit-discipline doctrine (`feedback_audit_for_type1_type2.md`, `feedback_no_fake_credentialing.md`) made native to the editor itself. The editor cannot lie to its future self about what it did.

## 4. Non-goals (explicit, gated by foundation-first)

- **VS Code compatibility** — out of scope. The substrate is a different architecture; the migration story is for v1.0+, not v0.1.
- **GUI** — out of scope for v0.1. Terminal-first. A GUI is a v1.0 addition once the substrate is solid.
- **Web-based collaborative editing** — out of scope. Multi-user collaboration is a v2.0 question; the substrate is single-user-first.
- **Plugin marketplace** — out of scope. Extensibility ships through the language, not through a centralized registry.
- **Telemetry of any kind** — never. The substrate is local-first; no anonymous usage metrics, no crash reporting, no model-call logging to a remote endpoint.
- **Closed-source binary distribution** — never. AGPL from commit zero. Binary builds are mirrors of the source, not products.

## 5. License posture

AGPL-3.0-or-later from commit zero. The license is the architecture, not the legal afterthought. The Mercantile Thesis essay names license posture as one of the eight axes; this substrate puts it on the AGPL side deliberately so the substrate is absorbable by Apple or xAI without being closed-forkable by them.

Dual-licensing under a commercial-friendly OSI license is *not* on the table for v1.0. Revisit when the bidding-war thesis is actually tested (post Bet 3 in the companion essay).

## 6. First-ship deliverable (v0.1, target Q3 2026)

**Foundation-first gates (all 3 closed as of 2026-05-13):**

| Gate | Artifact | Linux x86_64 | Apple Silicon arm64 |
|---|---|---|---|
| 1. Janet build test | `build-tests/janet-zig-smoke/zig-out/bin/janet-zig-smoke` | ✓ 945 KB stripped, valgrind clean (0 lost) | ✓ 962 KB Mach-O arm64, 3/3 checks pass |
| 2. Buffer-protocol binding sketch | `buffer-protocol.md` | ✓ 14 KB doc; per-key contract + 4 canonical buffer kinds | ✓ same doc (platform-independent) |
| 3. M-x command-runner demo | `build-tests/mx-runner-demo/zig-out/bin/mx-runner-demo` | ✓ 954 KB; pid + help + dispatch table + REPL working | ✓ Mach-O arm64; pid + help + dispatch working |

The v0.1 commit-zero is now unblocked. The remaining gates before public-OSS-repo creation are operator-side decisions: (a) repo name, (b) AGPL license-file commit, (c) the no-public-pushes-yet doctrine green-light per `feedback_no_public_pushes_yet.md`.

A single Zig binary, ≤10 MB, that:

1. Opens a buffer from a file path, displays it in the terminal, supports basic navigation.
2. Exposes `M-x` command-runner that dispatches to a configurable command table.
3. Ships with four built-in commands: `M-x stax-search`, `M-x stax-dream`, `M-x stax-hunger`, `M-x stax-dashboard`. Each renders into a new buffer.
4. Embeds the extensibility language with a public buffer-protocol binding so users can define their own commands.
5. Reads `~/.config/stax-editor/init.<ext>` on startup for user customization.
6. Writes session audit log to `~/.local/state/stax/editor-sessions/<session-id>.jsonl`.

That's the v0.1. Nothing else. It composes with the agent fleet through CLI invocations, runs in a terminal, ships under AGPL, and is the substrate that everything else attaches to.

## 7. Type-I / Type-II audit on this sketch

**Type-I (overclaim) risk.** Calling this "Emacs reborn for the appliance-layer era" is a rhetorical instrument; Emacs has 40 years of accumulated discipline and a Lisp ecosystem this substrate won't match for years. The substrate's claim has to be that it ships the *architectural pattern* Emacs proved, not that it replaces Emacs day one. People who already use Emacs daily will probably keep using Emacs; the substrate's wedge is people who would use Emacs but don't because the activation energy is too high or the integration with modern AI workflows is missing.

The "single Zig binary ≤10 MB" claim is sketch-level until the extensibility language is chosen. If the chosen language adds 50 MB of runtime, the size claim has to be revised in public.

**Type-II (missed risk).** Single-user-first cuts off the network-effects path the Cursor business depends on. If the substrate succeeds technically but never produces a multi-user collaborative surface, it stays a niche tool and the Mercantile Thesis Bet 3 (Apple or xAI formal interest by 2028-06-30) is less likely to land. The collaborative-editing path is a v2.0 question, but the architecture has to be designed so the v2.0 surface is *possible* without rewriting the substrate.

The substrate has zero plan for Windows as a first-class target. The Three-OS Mesh doctrine says Windows is the production-business-tooling node, not the AI-substrate node — but the editor substrate's reach is limited if Windows users can't run it. WSL2 is the bridge for v0.1; native Windows ports are a v1.5 question.

## 8. Lane status

Active scoping. No commits yet. First commit gated on:

1. Extensibility-language choice (decision by 2026-06-30).
2. Buffer-protocol binding spec (draft by 2026-07-15).
3. First-ship deliverable §6 above scoped into milestones small enough to ship weekly.

The companion blog essay is in draft (`~/blog/content/posts/apple-next-pixar-emacs.md`). The strategic memo is in draft (`~/mac-mining/editor-substrate/STRATEGIC_POSITION.md`).

No public push until the v0.1 commit lands.
