# API stability

mast follows [Semantic Versioning 2.0.0](https://semver.org/) with
the caveats below.

## Pre-1.0 posture

Despite the `v1.x` tag pattern, this project is **pre-1.0 in semver
spirit** for two reasons documented in [STATUS.md](STATUS.md):

1. **Zig is on 0.16, not 1.0.** No Zig project can credibly claim
   long-term API stability beyond "stable on Zig 0.16 today."
2. **No production deployment.** mast has zero real-traffic
   operation, zero soak time, zero production-incident history. The
   v1.x git tags are hygiene-milestone markers (LICENSE / CI /
   SECURITY / CONTRIBUTING / CODEOWNERS / 7200-trial property tests
   / atomic save / mutation harness), not production-grade signals.

The v1.x tags will be honored for changelog continuity. The next
major milestone (the surface layers — visual TUI, multi-buffer,
local-inference daemon) is when v2.x will be considered.

## What's stable in v1.x

### The buffer protocol

The Buffer struct's public interface is the load-bearing API surface.
Within v1.x:

- `Buffer.Kind` enum: `.file | .agent | .manifest | .search`. New
  variants may be added at any minor version (consumers must use
  `else =>` exhaustively).
- `Buffer.fromBytes(allocator, kind, name, bytes)` — constructor.
- `Buffer.fromFile(allocator, path)` — file-backed constructor.
- `Buffer.append(text)` — append + mark dirty.
- `Buffer.setContents(new_bytes)` — destructive replacement +
  mark dirty.
- `Buffer.save()` — atomic save for `.file` kind buffers.
- `Buffer.saveAs(path)` — save + convert `.agent` → `.file`.
- `Buffer.deinit()` — free allocator-owned memory.

The struct fields (`kind, name, contents, mark, dirty`) are stable;
field types are documented in `src/buffer.zig`.

### The M-x verb surface

The built-in M-x verbs (`pid`, `help`, `display`, `buffer-name`,
`buffer-size`, `append`, `save`, `save-as`, `stax-search`,
`stax-dashboard`, `stax-hunger`, `exit`) and the Janet fall-through
eval path are stable. New verbs may be added at any minor version.

### The Janet C-callback ABI

`cmd_stax_pid`, `cmd_buffer_name`, `cmd_buffer_size` — the three
C-callbacks the Janet runtime invokes — are stable in signature and
semantics. Adding new C-callbacks is a minor bump; renaming or
removing existing ones is a major bump with the deprecation window
below.

## What's stable in the sandbox

Per [docs/SANDBOX_THREAT_MODEL.md](docs/SANDBOX_THREAT_MODEL.md):

- `os/shell` requires the `exec` capability or panics — load-bearing
  default-deny.
- `MAST_SANDBOX_STRICT=1` env var disables the eval/load fall-through
  for untrusted contexts.
- `gated_stax_bash` accepts exactly one argv element; any other count
  panics.
- The sandbox's `Capability` set (`{.exec}`) may grow new variants at
  minor versions (consumers should handle unknown caps gracefully).

## What's UNSTABLE

- The internal layout of `src/janet_c.zig` (the `@cImport` block).
- The exact bytes emitted by `M-x display` for various Buffer kinds —
  the prefix/format may change at any minor version.
- The JSON / TSV output of any future `--format=json` flags
  (currently unset; reserved for v2.x).
- The atomic-save tmp path naming (currently
  `/tmp/mast-{file}-{pid}.tmp`) — implementation detail.

## Deprecation policy

If a stable surface needs to change:

1. The new surface ships alongside the old in version `vN.M+1` with
   the old marked deprecated in the changelog.
2. The old surface continues to work for at least 6 months OR until
   the next major version, whichever is later.
3. Removal happens only at a major version bump.

## Verification

Releases from v1.2.0 onward are GPG-signed git tags:

```sh
git tag -v v1.X.Y
# gpg: Good signature from "stax release signer ..."
```

Public key fingerprint: `079261B06444C6A410B3BE363CFCB60243028886`
(also at [`release-signing.gpg.pub`](release-signing.gpg.pub) once
that file is added — currently mast carries GPG-only provenance,
not the cosign double-provenance the substrate-tier projects ship).

## Per-release scope

| Version | Substrate gates                                                | Major additions                                   |
|---------|----------------------------------------------------------------|---------------------------------------------------|
| v0.1.0  | initial buffer + Janet embed                                   | first release                                     |
| v0.1.1  | sandbox capability model + 4 sandbox tests                     | `MAST_SANDBOX_STRICT` env var                     |
| v1.0.0  | production-grade hygiene milestone                             | LICENSE / SECURITY / CONTRIBUTING / CODE_OF_CONDUCT |
| v1.1.0  | file-write buffer ops + atomic save + 12 doctest checks        | save / saveAs / mutation harness 8/10            |
| v1.2.0  | 7200-trial property corpus + buffer-protocol benchmark         | BENCH.md + 16/16 tests + GPG-signed tag           |
