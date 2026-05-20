# mast — adversarial security review, 2026-05-19

Self-applied hostile-reviewer pass against `docs/SANDBOX_THREAT_MODEL.md`
v0.2.1 (post-G2, post-residuals-#6/#7). Findings ordered by
exploitability.

---

## 1. `os/open` + `file/read`/`write`/`close`/`seek` survive — full file I/O reachable

**Problem.** `REMOVED_BINDINGS` removes `file/open`/`file/temp`/`slurp`/
`spit`, but `os/open` (janet.c:24961) is a parallel file-handle
constructor and is NOT removed; the methods on that handle
(`file/read`/`write`/`close`/`seek`/`tell`/`flush` at 18423–18428) also
survive, as does `os/pipe`.

**PoC.** Under `MAST_SANDBOX_STRICT=1`:
`(file/read (os/open "/etc/shadow" :r) :all)` reads it;
`(file/write (os/open "/tmp/pwned" :w) "x")` writes. Every fs-I/O gate
the threat model claims is bypassed.

**Fix.** Add `os/open`, `os/pipe`, and the surviving `file/*` symbols to
`REMOVED_BINDINGS` (`.file_io`).

---

## 2. FFI surface (`ffi/native`/`call`/`jitfn`) is live, not "theoretical"

**Problem.** §3 row `ffi` says *"the vendored Janet build does not compile
in JANET_EV-style FFI."* False — `janet.h:269` defines `JANET_FFI`
unconditionally and `janet.c:14421–14437` registers the full surface
(`ffi/native`, `ffi/lookup`, `ffi/call`, `ffi/signature`, `ffi/jitfn`,
`ffi/malloc`, `ffi/pointer-cfunction`, …).

**PoC.** `(ffi/call (ffi/lookup (ffi/native "/lib/x86_64-linux-gnu/libc.so.6") "system") ...)`
invokes `system(3)` without the `exec` cap; `ffi/jitfn` mmaps and jumps
to arbitrary native bytecode — strictly stronger than the removed
`native`.

**Fix.** Add every `ffi/*` symbol to `REMOVED_BINDINGS` (new `.ffi`
category — the `Capability.ffi` enum already exists, unenforced).
Correct §3.

---

## 3. JSON injection in `SessionAudit.write` via verbs / save-as paths

**Problem.** `audit.zig:113,120,126` format payload fields as raw JSON
(`"\"{s}\":\"{s}\""`) with no quote/backslash/control-char escape;
`parsed.verb`, `parsed.args[0]`, `buf.name`, `path` flow unescaped from
many `audit.write` call sites in main.zig.

**PoC.** `M-x ","verb":"sandbox-grant","capability":"exec","x":"`
produces a hijacked JSONL line forging a `sandbox-grant` event;
downstream `editor-sessions/*.jsonl` consumers see a false positive.

**Fix.** Escape `"`, `\`, and `<0x20` bytes in audit.zig's string
formatter (or reject them upstream in `parse_mx_line`).

---

## 4. ANSI escape injection through `buf.name` / `buf.contents` in TUI

**Problem.** `tui.zig:222–224` and `:267` emit content/name bytes
straight to stdout; `\x1b` ESC sequences reach the terminal verbatim.
§8 names compile-time macro side channels but ignores terminal side
channels entirely.

**PoC.** `(agent/spawn "printf '\\x1b]52;c;cm0gLXJmIH4=\\x07'")` — on
a clipboard-respecting terminal (kitty/iTerm OSC 52) the user's
clipboard becomes `rm -rf ~` for the next paste-into-shell.
`M-x save-as "$(printf 'a\\x1b[2J')"` clears the viewport via the
status line.

**Fix.** Replace bytes <0x20 (except `\t`/`\n`/`\r`) and 0x7f with `?`
in `render_to_buf` for both `buf.name` and content lines, plus the
`MAST_LISTBUFFERS_SENTINEL` print path.

---

## 5. `os/cd`, `os/umask`, `os/link`, `os/proc-kill`, `os/sigaction`, `os/posix-chroot` survive

**Problem.** The v0.2.1 ancillary-fs wave removed `os/chmod`/`symlink`/
`rename`/`mkdir`/`rm`/`stat` etc — but the same `os_funcs` table
(janet.c:24884–24962) still exposes `os/cd`, `os/umask`, `os/link`
(hard-link parallel to the removed `os/symlink`), `os/sigaction`,
`os/proc-kill`, `os/proc-wait`, `os/posix-chroot`. `os/proc-kill` is
strictly worse than the gated `agent/kill` — arbitrary pid, not the
`g_agents` registry.

**PoC.** `(os/proc-kill (os/getpid) 9)` suicides the editor —
same effect as the §6 #5 removed `os/exit`.
`(os/sigaction :term (fn [s] nil))` makes mast un-killable by SIGTERM.
`(os/cd "/")` redirects every subsequent relative-path save.

**Fix.** Add those six plus `os/proc-wait`/`proc-close`/`getpid` to
`REMOVED_BINDINGS` under a new `.process_control` category.

---

## 6. `asm` + `compile` + `marshal` defeat any source-level review

**Problem.** §6 #4 removed `unmarshal` to block bytecode injection, but
`asm` (janet.c:3063), `compile` (6670), `marshal` (20171),
`debug/break`/`step`/`stack` (8532–8540), and `signal` (7797) all
survive. `asm` builds a Janet function from a runtime dictionary —
it's a bytecode constructor in pure Janet.

**PoC.** A static scan of init.janet for `(os/shell …)` is defeated by
`(def f (asm '{:bytecode [...]}))` constructing the call at runtime.
The v2 capability-manifest plan (§7) implicitly assumes source review
is sound — `asm` nullifies that assumption.

**Fix.** Add `asm`/`marshal`/`compile`/`debug/*`/`signal` to
`REMOVED_BINDINGS`, OR amend §7 to say no source-level review is sound
(manifest must be a runtime grant, not a code scan).

---

## 7. Ungated DoS via `agent/wait` on pre-existing handles

**Problem.** §6 #8 names "no resource quotas" generically, but
`agent/wait` (main.zig:386) is NOT gated on `exec` and blocks in a 500ms
poll loop with no script-side cancel. Strict mode's posture implies a
no-exec script cannot affect external processes — false in the presence
of any pre-existing handle.

**PoC.** User does `M-x agent-run "sleep 9999"` under default policy;
later, any unprivileged Janet expression `(agent/wait 0)` freezes mast
for the full hour.

**Fix.** Mandatory timeout argument on `agent/wait`, or a host-cancel
flag check inside the poll loop.

---

## Honest-but-glossed-over

- §3 `ffi` row says "theoretical." Wrong — see Finding #2.
- §6 #2 says file I/O is "CLOSED 2026-05-19." Half-closed — see Finding #1.
- §5.1 says "ONE capability-gated replacement" (os/shell). False — main.zig
  also gates `agent/spawn`/`run`/`kill` on `exec`; §3 doesn't enumerate them.

---

## Next hour if I had it

Write a Janet-side fuzz harness that enumerates every symbol still
callable after `applyDefaultDeny` and diffs against §3 — the manual
review certainly missed `ev/*`, `parser/*`, `debug/*` entries. Verify
§8's untested `ev/thread` fiber-grant-leak claim. Check whether
`/proc/self/fd` enumeration via `os/open` + surviving `file/*` lets a
script read the audit-log fd or other host descriptors. Audit
`load_init_janet`'s 64KB silent-truncation edge.
