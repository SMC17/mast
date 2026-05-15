# BENCH.md — mast buffer protocol throughput

Honest throughput measurements for the buffer-as-protocol primitive.
The buffer is the load-bearing surface every editor and agent
operation runs through, so its performance characteristics are the
ceiling for the editor as a whole.

The reproduction recipe is at the bottom — readers must be able to
re-run the bench, per the audit discipline.

## TL;DR

On a 5-year-old laptop (Intel i7-1065G7 @ 1.3 GHz, ReleaseFast,
MONOTONIC timing), the buffer primitive operates at:

| Operation              | Throughput        | ns/op  | Notes                          |
|------------------------|-------------------|-------:|--------------------------------|
| `fromBytes` (16 B)     | 19.5 M ops/sec    |     51 | constructor, smallest case     |
| `fromBytes` (4 KB)     | 11.4 M ops/sec    |     87 | typical agent stdout line      |
| `fromBytes` (64 KB)    | 26 K ops/sec      |  37944 | large agent output             |
| `append` (small × 10)  | 23.4 M /sec       |     42 | per-keystroke-class latency    |
| `append` (small × 100) | 12.4 M /sec       |     80 | line-editing burst             |
| `append` (small ×1000) | 3.4 M /sec        |    295 | long-document growth           |
| `setContents` (16 B)   | 27 M ops/sec      |     37 | atomic replacement small       |
| `setContents` (4 KB)   | 16.8 M ops/sec    |     59 | replace at agent-output size   |
| `setContents` (64 KB)  | 21 K ops/sec      |  47036 | replace at large-file size     |
| `save` (16 B)          | 42.8 K ops/sec    |  23362 | atomic write-to-disk small     |
| `save` (4 KB)          | 45.3 K ops/sec    |  22072 | atomic write typical           |
| `save` (64 KB)         | 22.4 K ops/sec    |  44560 | atomic write at large size     |

Numbers from `zig build bench-buffer -Doptimize=ReleaseFast` on
2026-05-15. Raw output in `bench/results/2026-05-15.out`.

## What these numbers mean

### `fromBytes` is the constructor

Every time the editor wraps a piece of memory in a Buffer, it pays
this cost. At 16 bytes it's 51ns (one allocation + one `memcpy` +
struct init). At 64 KB it's 37µs, dominated by the `memcpy`. For an
editor that creates one buffer per UI event, 19.5M/sec is far above
the budget — buffer construction is not a bottleneck.

### `append` is the keystroke path

For a keystroke-class operation (1-byte append), the budget is
roughly one screen frame (~16 ms at 60 Hz). At 42ns per append we
can do **381 000 keystrokes per frame** before the buffer itself
becomes the bottleneck. Realistically, the renderer + Janet
dispatch + IPC will limit us first.

### `setContents` is the replace path

Replacing the buffer contents is what `M-x` commands that produce
new output do (e.g., re-running a search). At 16 KB the operation
takes 18 µs — well within the perceptual budget.

### `save` is the bottleneck

Disk writes are 3-5 orders of magnitude slower than memory ops.
~22 µs per save at 16-4096 B is dominated by the `fsync` →
`rename` syscall sequence, which is the price of atomic writes.
Throwing more CPU at it doesn't help — the bottleneck is the
journal commit. If a user does 10 saves per second they will
experience zero perceptible lag.

## Honest scope

These numbers are:

- **Single-threaded.** No background buffer-flush thread.
- **No PGO, no LTO.** Stock `-Doptimize=ReleaseFast`.
- **One CPU.** Intel i7-1065G7 (Ice Lake, 4C/8T, 1.3 GHz base /
  3.9 GHz boost). Apple Silicon and Zen 5 will move the absolute
  numbers but the operation-shape ranking will hold.
- **One filesystem.** ext4 on NVMe. ZFS / btrfs / network FS will
  have different `save` characteristics (the in-memory ops are
  filesystem-independent).
- **Synthetic loads.** Real editor sessions have non-random byte
  patterns (mostly ASCII source code); the timing differences from
  random bytes are within the noise floor.

These numbers are NOT:

- A claim that mast is faster than VSCode, Emacs, or Vim. None of
  those publish comparable bench results; ad-hoc comparisons
  would be apples-to-oranges and we don't do those.
- A claim that mast is "production-ready at editor scale." The
  buffer is one of N primitives; the editor as a whole needs more
  work (see [STATUS.md](STATUS.md) for the honest pre-1.0 posture).

## Reproducing

```sh
git clone https://github.com/SMC17/mast
cd mast
zig build bench-buffer -Doptimize=ReleaseFast 2> bench-output.txt
cat bench-output.txt
```

Expected format per line:
```
bench=<op> [size=N | chunks_per_buf=N] iters=N total_ns=N ns_per_op=N ops_per_sec=N
```

## What's next

Future bench surfaces that should land:

- **Janet dispatch** — measure the overhead of `M-x` dispatch
  through the Janet runtime vs a direct Zig call.
- **File watcher subscribe** — measure the inotify-driven buffer
  update latency for the `subscribe` channel.
- **Concurrent buffers** — many buffers open simultaneously,
  measure the steady-state allocator pressure.

None of these are blockers for v0.1. They are next-frontier moves
that prove the substrate scales beyond the single-buffer case.
