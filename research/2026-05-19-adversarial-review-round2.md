# mast — adversarial security review, round 2, 2026-05-19

Self-applied hostile-reviewer round 2 against post-v1.3.4 state.
Round 1 = `2026-05-19-adversarial-review.md`. Findings ordered by
exploitability.

---

## 1. `ev/thread` re-instantiates a fresh Janet VM with the FULL stdlib

`vendored/janet/janet.c::janet_go_thread_subr` calls `janet_init()`
in a new OS thread, then `janet_unmarshal`s the user fiber into it.
`applyDefaultDeny` ran against ONE env in main; the new VM has none
of it. Every removed binding — `os/shell`, `os/execute`, `os/open`,
`slurp`, `spit`, `net/*`, `ffi/*`, `unmarshal`, `asm` — is fully
present. `ev/thread` is NOT in `REMOVED_BINDINGS` (only a stale
comment names it).

**PoC** (mechanically inevitable from upstream source, untested):
`(ev/thread (fn [_] (os/shell "echo PWNED > /tmp/pwn")) nil :n)`.
Under `MAST_SANDBOX_STRICT=1` the spawned thread runs `os/shell`
with no sandbox in scope. Confirms round-1 §8's "ev/thread
fiber-grant-leak (untested)" hint.

**Fix.** Add `ev/thread` + `ev/thread-chan` to `REMOVED_BINDINGS`
(new `.threading` category). `ev/go` is single-thread, doesn't
re-init, inherits the gated env — likely safe but audit.

---

## 2. Spawned children inherit audit-log fd — bypass of `writeJsonString`

`audit.zig:65` opens JSONL log with `O_WRONLY|O_CREAT|O_TRUNC` — no
`O_CLOEXEC`. `agent/spawn` (`main.zig:333`), `agent/run` via popen,
and `os/shell` fork+exec children inherit ALL fds by default. Child
has a writable fd to the audit file.

**PoC.** Under default (`exec` granted): `M-x agent-run "echo
'{...forged sandbox-grant JSON...}' >&FD"` where FD is the inherited
audit-fd (discoverable via `/proc/self/fd`). The escape work in
`writeJsonString` is bypassed — child writes raw bytes. Round-1 #3
closed in-process injection; round 2 finds the child-process channel.

**Fix.** `fcntl(fd, F_SETFD, FD_CLOEXEC)` after every `libc.open` /
`pipe` / `dup2` (`audit.zig:65`, `main.zig:1396`, `main.zig:264`).

---

## 3. `list-buffers` print path bypasses `sanitize_into` — round-1 #4 half-closed

Round 1 #4 explicitly named "**plus the `MAST_LISTBUFFERS_SENTINEL`
print path**." v1.3.4 added `sanitize_into` only inside
`render_to_buf`. `main.zig:863-870` does `print("... {s} ...",
.{buf.name})` through `std.debug.print` (stderr → same TTY) raw.
`agent/spawn` sanitizes its name_buf (good), but `M-x save-as` and
`M-x new-buffer` do NOT sanitize before storing in `Buffer.name`.

**PoC.** `M-x new-buffer "$(printf 'a\x1b]52;c;<b64>\x07')"` then
`M-x list-buffers` → OSC 52 clipboard hijack hits the terminal.

**Fix.** Sanitize at the buffer-name mutation point (canonicalize on
write). Doctrine: sanitize at the trust boundary, not every render
site. Type-I: fix-claim was overbroad.

---

## 4. `audit.zig::write` has unbounded `buf[written]` writes near 4096 ceiling

`audit.zig:106, 151, 154, 156` write `buf[written] = X` with no
bounds check. `writeJsonString` returns `NoSpaceLeft` on overflow,
but on success can return `w == out.len`, so `written` can hit 4096
exactly; next `buf[4096] = '}'` is one byte past the stack array
(UB). Same for `buf[written] = ','` between fields in the inline-for.

**PoC.** `M-x save-as <~4000-char path>` — `audit.write("buffer-save",
.{ .path = path })` overflows. Low-severity stack smash on Linux.

**Fix.** Wrap bare writes in a `try` helper or migrate the audit
buffer to `ArrayList(u8)`. Type-II on v1.3.4: introducing JSON escape
didn't audit surrounding buffer arithmetic.

---

## 5. Doctrine — §7 manifest plan must declare source-scan unsound

§6 #19 says `compile`+`signal`+`debug/*` defeat source review. But
§7's manifest line still reads as if `(use-capabilities :exec)`
parsed from source is sufficient. Composability:
`(compile (parser/produce p) ...)` + future `buffer-contents` =
code never appearing as a literal in init.janet.

**Fix.** Amend §7: manifest is a runtime grant against an empty
default-deny env; source scan is NEVER sufficient.

---

## Honest residuals round 2 leaves open

- `os/sleep`/`setlocale`/`cwd`/`getpid`/`cryptorand`/`isatty`/`perm-*`/
  `which`/`arch`/`compiler`/`cpu-count`/`m*time`/`date`/`strftime`/
  `clock` all survive. `os/sleep` is DoS-bounded by
  `MAST_EVAL_TIMEOUT_SEC`; rest are metadata. Need explicit §3
  enumeration, not silent omission.
- `ev/read`/`ev/write` harmless today (no JanetStream source after
  file/net removal); re-arm when v0.3 host-bound HTTP lands.
- `load_init_janet` 64KB silent truncation confirmed
  (`main.zig:1400-1402`). init.janet is host-trusted so low severity;
  `fstat`+warn is ~5 lines.

---

## Round 3

Ship the fuzz harness round 1 suggested: Janet script walking
`(all-bindings root-env)` post-`applyDefaultDeny`, diffed against
`REMOVED_BINDINGS`. Round 2 found `ev/thread` by source-reading; the
harness would catch transitive re-exposures via `module/find` /
`require`. Round 3 should also execute finding-#1 PoC end-to-end (not
just argue mechanical inevitability), and audit every `libc.open` /
`pipe` / `dup2` for missing `O_CLOEXEC` (round 2 named three; likely
more).
