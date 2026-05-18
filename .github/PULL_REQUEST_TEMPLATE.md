<!--
Pre-merge checks for mast PRs:
- `zig build test --summary all` passes (all 16+ unit tests + 7200+ property cases)
- `zig build doctest` still PASS — README claims match code
- `zig build smoke` round-trips the M-x dispatcher
- If touching sandbox or os/shell: explain why MAST_SANDBOX_STRICT
  invariant is preserved
-->

## Summary

<!-- 1-3 bullets on what changed. -->

## Substrate-gate impact

<!-- Which STATUS.md gate does this advance? -->

## Test plan

- [ ] `zig build test --summary all` passes
- [ ] `zig build doctest` PASS
- [ ] `zig build smoke` round-trips
- [ ] If perf-sensitive: BENCH.md numbers don't regress
- [ ] If sandbox-touching: MAST_SANDBOX_STRICT still denies what it should

## Type of change

- [ ] Bug fix
- [ ] New substrate-gate advance
- [ ] Performance improvement
- [ ] Documentation
- [ ] Build / CI / governance

## Breaking change?

- [ ] Yes — `API_STABILITY.md` lists this surface as stable, needs major bump
- [ ] No

## Tests added

<!-- Even one new property-test case counts. -->
