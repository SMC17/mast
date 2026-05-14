# Contributing to mast

Thanks for considering a contribution. mast is intentionally small at v0.1 — the substrate is meant to be readable end-to-end in an hour — so the clearest contribution paths are focused.

## What's most useful right now

1. **Platform smoke tests.** Try `zig build -Doptimize=ReleaseSmall` on Linux distros other than Arch / Ubuntu, on FreeBSD, on a Raspberry Pi 5, on M-series macOS. Open an issue with the build log and any patches needed.
2. **Buffer-protocol refinements.** See `docs/buffer-protocol.md` for the v0.1 contract. Missing primitives (e.g. write-back for `:file` buffers, async `subscribe`, region selection) are tracked in issues with the `protocol` label.
3. **Built-in `M-x` commands that compose with other local CLIs.** Anything callable from a shell can be wrapped as a built-in via the same pattern as `stax-search` / `stax-dashboard`. Pull requests welcome.
4. **A TUI renderer for v0.2.** [vaxis](https://github.com/rockorager/libvaxis) is the leading candidate in the Zig ecosystem. Bring receipts — a working prototype on a branch is more valuable than a design doc.
5. **Doc fixes.** Typos, broken cross-references, unclear examples — open a PR directly.

## What's NOT useful right now

- Refactors that don't change observable behavior. The codebase is small enough that style preferences are decided by the existing code.
- Plugin-marketplace proposals. Extensibility ships through Janet, not a centralized registry. This is a v0.1 commitment, not a TODO.
- Replacing Janet with another extensibility language. The decision memo at `docs/EXTENSIBILITY_LANGUAGE.md` documents why Janet won; arguments for replacement need to engage with that memo's criteria.

## Process

- Fork → branch → PR. Keep PRs small and focused.
- Each PR must pass the CI in `.github/workflows/ci.yml` (Linux x86_64 + macOS arm64 build + smoke).
- If your PR adds a new built-in command, add a CI assertion for it.
- Update `CHANGELOG.md` under `[Unreleased]` for any user-visible change. The maintainer cuts the version on release.
- New contributors get credit in the CHANGELOG release notes.

## License

By contributing, you agree that your contribution is licensed under AGPL-3.0-or-later, the same license as the project. The vendored Janet runtime stays under its original MIT license at `vendored/janet/LICENSE`.

## Code of Conduct

Be civil. Substantive disagreement is welcome and load-bearing. Personal attacks, harassment, and bad-faith argumentation are not. Maintainer judgment is final on what crosses the line.
