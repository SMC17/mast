# Buffer-Protocol Binding (Janet ↔ Zig host)

**Date:** 2026-05-13
**Status:** sketch. Becomes `compiled` after the §5 build test in `EXTENSIBILITY_LANGUAGE.md` lands.
**Parents:** `SPEC.md` §3.1 (buffer-as-protocol primitive), `EXTENSIBILITY_LANGUAGE.md` §5(2) (foundation-first verification gate #2).
**Companions:** `STRATEGIC_POSITION.md`, `feedback_foundation_first.md`, `feedback_robust_over_parlor_tricks.md`.

The buffer protocol is the API contract between Janet user code and the Zig editor kernel. Every observable editor object (file, conversation, heartbeat tail, search result, manifest event stream) appears in Janet as a table conforming to this protocol. There is no second access path.

---

## 1. The table shape

A buffer is a Janet table with a fixed set of reserved keys. Every key is either a callable (a registered Zig CFunction) or another table. **No key ever holds a raw pointer, a Zig buffer view, or any object whose lifetime is not GC-managed by Janet.**

```janet
# Schematic of what `(stax/open-file "/path/to/file")` returns to user code:
@{:read        <cfn>      # (buf :read start end)  -> string
  :write       <cfn>      # (buf :write start end s) -> nil | panic
  :subscribe   <cfn>      # (buf :subscribe events callback) -> sub-id
  :unsubscribe <cfn>      # (buf :unsubscribe sub-id) -> nil
  :point       <cfn>      # (buf :point)  -> int     (zero-arg getter)
  :point-set!  <cfn>      # (buf :point-set! n) -> nil
  :mark        <cfn>      # (buf :mark)   -> int | nil
  :mark-set!   <cfn>      # (buf :mark-set! n) -> nil
  :region      <cfn>      # (buf :region) -> [start end] | nil
  :mode        @{...}     # function-table; see §3.6
  :properties  @{...}     # key-value map; see §3.7
  :buffer-id   <int>}     # opaque host handle; users never construct this
```

Convention: every callable takes the buffer table as its first explicit argument so the Zig side gets a consistent self-pointer; the `(buf :keyword args...)` form Janet supports is sugar that the spec recommends but does not require.

---

## 2. Per-key contract

| Key | Kind | Signature | Contract |
|---|---|---|---|
| `:read` | cfn | `(buf :read start end)` → string | Returns a fresh Janet string holding bytes `[start, end)` in UTF-8. **Copy on every call.** Out-of-range → panic. `start=end` returns the empty string. |
| `:write` | cfn | `(buf :write start end s)` → nil | Replaces bytes `[start, end)` with the UTF-8 contents of Janet string `s`. Emits a `buffer-write` manifest event automatically (Janet code never logs). Panics on invalid range or read-only buffers. |
| `:subscribe` | cfn | `(buf :subscribe events cb)` → sub-id | `events` is a tuple of keywords: `:change`, `:save`, `:point-move`, `:mode-change`, `:close`. `cb` is a Janet callable invoked on the main editor fiber (never from an inotify thread). Returns an integer sub-id. |
| `:unsubscribe` | cfn | `(buf :unsubscribe sub-id)` → nil | Idempotent. Unknown sub-id is a no-op, not a panic. |
| `:point` / `:point-set!` | cfn / cfn | `(buf :point)` → int, `(buf :point-set! n)` → nil | Point is the cursor offset in bytes. Reads are always fresh (Zig holds the authoritative int). Setting an out-of-range offset clamps to `[0, len]` and emits `:point-move`. |
| `:mark` / `:mark-set!` | cfn / cfn | as above, plus `:mark` may return `nil` | `nil` means "no mark set." `:mark-set! nil` clears the mark. |
| `:region` | cfn | `(buf :region)` → `[start end]` \| `nil` | Convenience: returns the ordered range between point and mark, or `nil` if no mark. |
| `:mode` | table | — | A function-table of operations valid for this buffer kind. File buffers expose `:save`, `:revert`. Agent-conversation buffers expose `:send`, `:cancel`. Search-result buffers expose `:open-hit`, `:refine`. The host populates `:mode` at construction; user code may extend it via `put`, but mode is the buffer's contract surface for what's *meaningful* on it. |
| `:properties` | table | — | Key-value map with reserved keys: `:agent-attached` (bool), `:last-event` (manifest event id or nil), `:dirty` (bool), `:derived-from` (buffer-id or nil), `:read-only` (bool), `:encoding` (`:utf-8` for v0.1; reserved for future), `:size` (int, fresh each read). User-defined keys are allowed but must namespace under `:user/...` to avoid collision. |
| `:buffer-id` | int | — | Opaque integer handle. Users may compare for equality but must not synthesize. The Zig host uses this to look up the storage for callables. |

---

## 3. Ownership and copy semantics

The load-bearing rules. These are why "Janet never touches raw memory" holds.

1. **The Zig host owns all buffer storage.** The actual bytes live in a host-side allocator (flat `ArrayList(u8)` for v0.1; a rope or piece-table is the upgrade path documented in `SPEC.md` and is invisible at this protocol surface).

2. **Every `:read` copies.** The Zig CFunction allocates a fresh Janet string via `janet_stringv(bytes_ptr, len)`, which copies into Janet's GC arena. The pointer Janet sees is owned by Janet's GC. The Zig buffer's bytes are unobservable to Janet after the call returns.

3. **Every `:write` copies in.** The Janet string handed to `:write` is read via `janet_unwrap_string(s)` to get a `const u8*`, immediately copied into the host buffer, and then forgotten. Janet may GC the original string after the call returns; the host never holds a borrowed pointer past the call boundary.

4. **No `janet_buffer*` (Janet's mutable byte type) is ever returned from a `:read`.** Janet's `buffer` type exposes a writable byte array that could, in theory, be aliased back to host memory. The protocol forbids that path. If a future `:read-bytes` variant returns a Janet `buffer`, it does so by *copy*, not by alias.

5. **Numeric keys (point, mark, sub-id) are passed by value.** Janet's int representation is opaque; the cfn unwraps to `i64` and re-wraps on return.

6. **Tables held inside `:mode` and `:properties` are owned by Janet.** The host populates them at buffer construction by inserting Janet values; thereafter Janet's GC governs their lifetime. The host does not retain pointers into those tables.

7. **No two buffers ever share storage.** A `:derived-from` property is bookkeeping (the host can decide to share underlying bytes copy-on-write), but the *protocol* presents each buffer as independent storage. A `:write` to a derived buffer never visibly mutates the parent.

These rules together mean: a Janet command can lose its reference to a buffer and the host can free its storage in any order, with no use-after-free path. Lifetimes are decoupled by copy.

---

## 4. Errors, threading, encoding

**Errors.** Every Zig cfn that detects a contract violation calls `janet_panic` with a structured message. The message is a Janet keyword tuple, not a string, so Janet `try` handlers can pattern-match: `[:out-of-range :read 0 1024 :buffer-size 512]`. Panics never leak Zig stack traces to Janet (Type-I hazard if they did — would tempt users to grep Zig internals).

**Threading.** Janet runs on the main editor fiber. Inotify events, heartbeat-tail polling, agent-process stdout — all enqueue into a host-side MPSC queue. The main fiber drains the queue between command dispatches and invokes registered `:subscribe` callbacks then. **`:subscribe` callbacks never execute from a thread other than the main fiber.** This is the simple-and-true threading model for v0.1; a future fiber-per-buffer model is a v0.2 question and would require widening the contract.

**Encoding.** UTF-8 throughout. The host validates UTF-8 on `:write`; an invalid sequence is a panic, not a silent corruption. Byte-level access for binary files is out of scope for v0.1; a future `:read-bytes` / `:write-bytes` pair would return/accept Janet `buffer` (by copy, per rule 4) and would set `:encoding` to `:binary`.

---

## 5. Worked example

Defining a Janet command that uppercases the selected region:

```janet
(defn upcase-region [buf]
  (let [region ((buf :region))]
    (unless region (error :no-region))
    (let [[s e] region
          text  ((buf :read) s e)]
      ((buf :write) s e (string/ascii-upper text)))))

# Register so it shows up under M-x:
(register-command :upcase-region upcase-region)
```

At runtime:
- `(buf :region)` calls into Zig, which reads point + mark and returns `[s e]` (a fresh Janet tuple).
- `(buf :read)` returns the cfn; calling it with `s e` invokes the Zig accessor, which copies bytes into a Janet GC string.
- `string/ascii-upper` is pure Janet on the copy — Zig storage is untouched.
- `(buf :write)` calls into Zig with the new string; Zig copies it in and emits a `buffer-write` manifest event under the current session-id.

No raw pointer is ever held by Janet code. Janet never knows the buffer's flat-vs-rope representation. The host can swap the implementation under v0.2 without changing a line of this command.

---

## 6. Out-of-scope for v0.1 (gated by foundation-first)

- **Atomic multi-buffer transactions** — applying an edit across two buffers as a single unit. v0.2.
- **Backpressure on slow subscribers** — if a Janet `:subscribe` callback runs slow, events queue. The v0.1 policy is "queue until 1024 events, then drop with a `:subscribe-overflow` event injected." Documented here for explicit decision; not a future TBD.
- **Cross-process buffers** — a buffer backed by a separate `stax-*` process's stdout tail. v0.2; the protocol surface is unchanged but the host plumbing widens.
- **Memory-mapped buffers for huge files** — the rule "every `:read` copies" still holds at the protocol surface, but the host can lazy-load chunks under the hood. Implementation concern, not protocol concern. Flagged so it doesn't get treated as a contract change later.
- **Janet-defined modes** — for v0.1, `:mode` is host-populated and read-mostly from Janet. User-defined modes are a v0.2 surface.

---

## 7. Type-I / Type-II audit

**Type-I (overclaim).**
- "Janet never touches raw memory" is true *only if* the `:read-bytes`/`:write-bytes` future variants never alias host buffers. The §3 rules forbid aliasing; the verification is that the eventual implementation has a unit test confirming `janet_unwrap_buffer` is never called on a value the host retained a pointer to.
- "Every `:read` copies" hides the cost model. On a 100 MB buffer with a frequent `:read 0 size` call, the protocol mandates a 100 MB copy per call. The host SHOULD reject reads above a budget (e.g., 16 MB) with `:read-too-large` panic and require the caller to range-chunk. This is a host-side guard, not a protocol guarantee — name it so users don't write code that depends on full-buffer reads working.
- The threading model claims `:subscribe` callbacks "never execute from a non-main thread." This is a host invariant, not a Janet language guarantee. If a user calls into Janet via `janet_call` from a Zig thread (which the host should never do but a buggy extension could), the invariant breaks. The mitigation is a debug-build assertion (`std.debug.assert`) that checks the calling thread-id is the main editor thread on every cfn entry; release builds drop the check.
- The "no manifest event leak" claim — `:write` auto-emits — is reliable only if the host's manifest-write call cannot fail silently. If the manifest log is offline, the host should panic the `:write` rather than silently dropping the event. Foundation-first: audit discipline > user convenience.

**Type-II (missed risk).**
- The protocol has no notion of *transactionality within a single buffer*. A Janet command that does `:read; transform; :write` can race with an inotify-driven external file change between the read and the write. v0.1 ships single-Janet-fiber serialization (no concurrency *within* Janet), but external file mutation is a real source of lost-update bugs. The v0.2 fix is a `:version` property on every buffer; `:write` takes an expected-version and panics on mismatch. Documenting now so v0.1 callers can opt into manual version checks via `:properties`.
- The protocol does not expose **undo** as a primitive. Janet user code can build undo on top of the manifest log, but a "first-class `:undo` callable on every buffer" is a v0.1 ergonomic miss. Decision: defer to v0.2 deliberately — undo semantics differ enough across buffer kinds (file vs agent conversation) that a single protocol-level `:undo` would either be too thin or too presumptuous.
- The mode table (`:mode`) is the substrate's extension point for "what operations make sense on this buffer." If two different host-emitted buffers expose the same `:mode` callable name with different semantics (e.g., `:save` meaning "write to disk" in a file buffer and `:save` meaning "fork to a new conversation" in an agent buffer), Janet code that's mode-agnostic will misfire. The fix is a naming convention: mode callables are prefixed by kind (`:file/save`, `:agent/save`). Open question for the v0.1 mode table; resolve before the M-x demo (foundation-first verification step 3).
- The protocol assumes a single Janet runtime per editor process. The substrate's `stax-spawn` discipline could imply a future "one Janet runtime per agent fiber for sandboxing" model. v0.1 punts to single-runtime; the protocol surface is identical either way, but inter-runtime buffer sharing would need its own contract.
- We have not asked: does `:subscribe` survive a buffer kill? Decision for v0.1: `:close` is the final event emitted; subscribers are unregistered automatically after `:close` delivers. Janet code receives a clean signal and then the buffer table's cfns all panic with `:buffer-closed` on further calls.

---

## 8. Verification (gates promotion from `sketch` to `compiled`)

1. Janet build test (`EXTENSIBILITY_LANGUAGE.md` §5 step 1) confirms `@cImport(janet.h)` works.
2. A minimal Zig program registers `:read` + `:write` + `:point` cfns against a 32-byte in-memory buffer and demonstrates the worked example from §5 round-tripping a string mutation.
3. A unit test under `~/mac-mining/editor-substrate/build-tests/buffer-protocol-smoke/` confirms:
   - Reading past `:size` panics with `[:out-of-range :read ...]`.
   - Writing invalid UTF-8 panics with `[:invalid-utf8 ...]`.
   - Subscribing, mutating, then unsubscribing delivers exactly one `:change` event in order.
4. The smoke test runs cleanly on Apple Silicon and on Linux (per `project_three_os_mesh.md`).

When all four land, this document's proof level moves from `sketch` to `compiled`, and the buffer protocol is no longer a load-bearing assumption — it is a verified contract.

---

No public push. The substrate stays in BUILDER mode until the green-light gate clears.

---

## 8. `:gpu-tile` buffer kind (sketch — v0.3+, kernel-stack composition)

The kernel-stack landscape (`project_kernel_stack_landscape_2026.md`) names Triton / ThunderKittens / CuTe-DSL / Helion / Mojo as the layer the editor substrate's runtime axis must compose with. `:gpu-tile` is the buffer kind that integrates that layer.

A `:gpu-tile` buffer wraps storage that lives in GPU memory (HBM or shared mem) rather than host RAM. Janet code on the editor-substrate side never sees the device pointer; the Zig host owns a *handle*. `:read` / `:write` perform host↔device copies through the kernel runtime in use.

| Key | Behavior on a `:gpu-tile` |
|---|---|
| `:read [start end]` | DtoH copy of the slice. Triggers a stream sync if pending kernels write to this tile. |
| `:write [start end bytes]` | HtoD copy of the slice. Schedules any kernel registered as a post-write hook via `:mode :post-write`. |
| `:mode` | Function-table includes `:launch` (re-run producing kernel), `:sync` (wait for in-flight), `:device` (return device handle for further kernel work), `:layout` (return DSL-specific layout descriptor, e.g. CuTe-DSL `Layout<Shape<M,N>, Stride<...>>`) |
| `:properties.kernel-runtime` | `:triton` / `:thunderkittens` / `:cute-dsl` / `:helion` / `:cutlass` / `:vendor-cudnn` |
| `:properties.precision` | `:fp32` / `:fp16` / `:bf16` / `:fp8-e4m3` / `:fp8-e5m2` / `:int8` (single dtype per buffer in v0.3) |
| `:properties.device` | `(:cuda 0 :sm-75)` for the Turing 1650M, `(:cuda 0 :sm-90)` for H100, `(:metal 0 :m2-max)` for Apple Silicon |
| `:properties.persistent` | If `true`, GC doesn't reclaim between dependent-kernel sessions |
| `:close` | Frees device memory, cancels in-flight kernels, runs all subscribers with the close sentinel |

Lifetime is reference-counted on the Zig side; Janet GC finalizers decrement. Long-lived tiles set `:properties.persistent`.

**v0.3 deliverable:** one shipped backing — Triton on the Linux box (Turing CC 7.5), a 30-line attention kernel exposed as a `:gpu-tile` buffer. The interface validates against the buffer protocol; the implementation proves the kernel-DSL composes with the editor substrate without leaking device pointers into Janet.

**Why this matters for the Mercantile Thesis appliance-layer claim:** the eight-axis check names runtime + silicon-path as two of the eight. Before this sketch, runtime implied "local LLM inference daemon." The kernel-stack landscape says the runtime axis is broader. `:gpu-tile` is the foundation-first integration: every kernel runtime exposes the same buffer interface; user code in Janet treats GPU tiles the same way it treats file buffers. The license posture (AGPL host) absorbs whatever kernel DSL the substrate ships with (Triton is MIT — clean compose; CuTe-DSL would need a dual-license carve-out).

**Open questions gating v0.3:**

1. Pinned-host-memory `:read` semantics. Janet's allocator doesn't pin; Zig pre-allocates a pinned scratch arena.
2. Stream + event model. Multiple `:gpu-tile`s on the same CUDA stream for ordering; `:subscribe :change` maps to events.
3. Layout descriptor encoding. CuTe-DSL form is canonical; other DSLs may need opaque tokens.
4. Cross-platform parity (CUDA vs Metal vs Vulkan). v0.3 ships CUDA only; Metal in v0.5+ once the macOS kernel-DSL ecosystem matures.

Status: SKETCH. The four open questions above gate promotion to `compiled`. First concrete code lands when the Triton smoke (`project_kernel_stack_landscape_2026.md` next-frontier item 1) compiles cleanly.
