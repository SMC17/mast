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
