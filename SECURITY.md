# Security Policy

## Reporting a Vulnerability

If you discover a security issue in `mast`, please report it privately via GitHub's [private vulnerability reporting](https://github.com/SMC17/mast/security/advisories/new) — **do not** open a public issue for security bugs.

Include in the report:

- The affected version (tag or commit SHA).
- A minimal reproduction (input, command-line, expected vs actual behavior).
- The platform you observed it on (Linux x86_64, Apple Silicon arm64, etc.).
- Your assessment of the severity if you have one.

You will get an acknowledgement within 7 days. Confirmed reports will get a fix in a patch release and a co-author credit in the CHANGELOG. If a CVE is appropriate, we will request one via GitHub's CVE Numbering Authority.

## Scope

In-scope:

- The mast binary (anything under `src/`, `build.zig`, `build.zig.zon`).
- The vendored Janet runtime (`vendored/janet/`) — we will forward upstream-relevant findings to the [Janet maintainers](https://github.com/janet-lang/janet) per their security policy.

Out of scope:

- Vulnerabilities in third-party CLIs that `mast` shells out to via the built-in `stax-*` commands. Report those upstream.
- Theoretical attacks that require local root or physical access — mast is a single-user terminal binary, not a privileged daemon.

## Supported Versions

mast is in active early development. We support the latest tagged release on the `main` branch. Older tags receive security fixes only if the issue is severe and the fix is small.

## Adversarial review trail

As of 2026-05-19 the sandbox model has been audited via **four rounds of self-applied hostile-reviewer review + one fuzz harness**. The full trail ships in the repository:

| Round | Findings | Closure release | Report |
|-------|---------:|----------------:|--------|
| 1 — manual hostile-reviewer | 7 (fs bypass, FFI live, JSON injection, ANSI injection, process control, bytecode, agent/wait DoS) | v1.3.4 | `research/2026-05-19-adversarial-review.md` |
| 2 — manual, post-round-1 | 4 + doctrine (ev/thread VM bypass, O_CLOEXEC leak, list-buffers sanitize gap, audit buffer overflow) | v1.3.6 | `research/2026-05-19-adversarial-review-round2.md` |
| 3 — runtime fuzz enumeration | 2 (ffi/calling-conventions, ffi/trampoline missed in round-2 source-reading) | v1.3.7 | `tools/sandbox-fuzz.{janet,sh}` |
| 4 — audit of MY OWN fix code | 2 critical (SIGALRM auto_suspend leak, wall-clock quota didn't bound blocking cfunctions) + 1 regression + 1 doctrine | v1.3.9 | `research/2026-05-19-adversarial-review-round4.md` |

The persona for each round is "self-applied hostile-reviewer," per the `feedback_no_fake_credentialing` doctrine. None of these is a substitute for **external** independent security review, which remains [STATUS.md](STATUS.md) gate G4 (still open).

If you're considering an independent review, the round 4 report is the best starting point — it audits the fix code from rounds 1–3 and found real bugs there. Continuing that pattern is the highest-leverage next move.

## Sandbox-model design constraints (informative)

`docs/SANDBOX_THREAT_MODEL.md` is the canonical reference. Quick summary:

- The sandbox is a **Janet-script-level capability model**, not OS isolation. Operators that need OS isolation should layer mast inside a container or VM.
- 73 dangerous Janet bindings are removed from the embedded env (panic on call). The static list is iterated by both the install path AND the load-bearing test, so install-and-test cannot drift.
- Audit-log writes are JSON-escaped + bounded; the audit fd has `O_CLOEXEC` so children don't inherit it.
- Wall-clock resource quota via SIGALRM + `janet_interpreter_interrupt`. `MAST_EVAL_TIMEOUT_SEC` env var (default 30s) bounds Janet bytecode + `agent/wait`.
- TUI render path + buffer-name write path both sanitize untrusted bytes (ESC, BEL, DEL, other C0 control bytes) to `?` to prevent ANSI escape injection.
- `compile`, `signal`, `debug/*` are intentionally retained (removing them breaks the language); the v2 capability-manifest plan must therefore be a runtime grant, not a source scan.
- 17 `os/*` metadata bindings are intentionally retained as low-severity (pure metadata or bounded-by-quota); 3 with actual impact were closed in v1.3.8.
