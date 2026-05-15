#!/usr/bin/env bash
# mast / tools / doctest.sh
#
# Documentation tests — verify that the README's executable claims
# actually hold against the shipped binary. A passing doctest run means:
#
#   1. The documented build steps (`zig build`, `zig build test`) exist.
#   2. The documented binary surface (`./zig-out/bin/mast --help`,
#      `M-x help`, `M-x pid`, `M-x exit`) actually works.
#   3. The documented Janet fall-through quickstart (`M-x (+ 1 2)` → `3`)
#      computes the documented answer.
#   4. The documented `MAST_SANDBOX_STRICT=1` strict-mode behaviour is
#      observable in the production binary — delegated to the existing
#      tests/strict_mode_integration.sh (5 cases, runs them all).
#   5. The example `examples/init.janet` referenced in the README
#      parses cleanly when loaded as the user init file (i.e. no
#      "init.janet eval error" diagnostic appears on startup).
#
# WHY: mast's README is unusually rich — sandbox semantics, env-var
# parser, M-x verbs, Janet fall-through. The cost of README/code drift
# is high (a new contributor copy-pastes the documented incantation,
# it silently does something else, trust dies). This script makes the
# README a load-bearing artifact that `zig build doctest` gates.
#
# Wired into build.zig as `zig build doctest`. Depends on the install
# step (b.getInstallStep) so the binary is present before checks run.

set -u
cd "$(dirname "$0")/.."

# ─── Result accumulator ────────────────────────────────────────────────────
n_pass=0
n_fail=0
declare -a FAILURES=()

pass() {
    n_pass=$((n_pass + 1))
    echo "  PASS  $1"
}
fail() {
    n_fail=$((n_fail + 1))
    FAILURES+=("$1")
    echo "  FAIL  $1"
}

# ─── Locate the binary ─────────────────────────────────────────────────────
MAST_BIN="${MAST_BIN:-zig-out/bin/mast}"
if [ ! -x "$MAST_BIN" ]; then
    echo "doctest: \$MAST_BIN=$MAST_BIN is not executable — run 'zig build' first" >&2
    exit 2
fi

# ─── Hermetic XDG dirs so user state / config never bleeds into checks ─────
state_dir="$(mktemp -d -t mast-doctest-XXXXXX)"
trap 'rm -rf "$state_dir"' EXIT
export XDG_STATE_HOME="$state_dir/state"
export XDG_CONFIG_HOME="$state_dir/config"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"

echo "=== mast doctest ==="
echo "  binary: $MAST_BIN"
echo "  state:  $state_dir"

# ─── Check 1: README documents 'zig build' — default step exists ───────────
#
# README §Build:
#   zig build -Doptimize=ReleaseSmall
#
# The default step is always present (`install`); we just confirm
# `zig build --help` parses and lists it. If `zig build --help` returns
# non-zero, the build.zig is broken and the README's primary instruction
# is non-executable.
if zig build --help >/dev/null 2>&1; then
    pass "README §Build: 'zig build' is a valid invocation"
else
    fail "README §Build: 'zig build --help' failed — build.zig broken"
fi

# ─── Check 2: README documents 'zig build test' — `test` step exists ───────
#
# CHANGELOG §1.1.0 names `zig build test` as a documented public step
# and the test step is what the existing 8 unit + 5 integration cases
# hang off. Drift here means CI's test invocation no longer matches the
# documented one.
if zig build --help 2>&1 | grep -qE '^\s+test\b'; then
    pass "README/CHANGELOG documents 'zig build test' step"
else
    fail "build step 'test' is missing from 'zig build --help'"
fi

# ─── Check 3: README documents `./zig-out/bin/mast --help` ─────────────────
#
# README §Run shows `./zig-out/bin/mast --help` as the discovery
# affordance. The binary must accept `--help` AND emit the documented
# "usage: mast [file]" line. If we change the CLI shape without
# updating the README, this fires.
help_out=$("$MAST_BIN" --help 2>&1 || true)
if echo "$help_out" | grep -q "^usage: mast"; then
    pass "README §Run: 'mast --help' prints 'usage: mast …'"
else
    fail "README §Run: 'mast --help' did not print 'usage: mast …'"
    echo "        got: $(echo "$help_out" | head -3)"
fi

# ─── Check 4: README documents `M-x help` and `M-x pid` and `M-x exit` ─────
#
# Three of the four most-prominently-documented M-x verbs. We feed them
# in via stdin (the same way the README tells the user to use them) and
# confirm:
#   - M-x help     → "Built-in M-x commands:" appears
#   - M-x pid      → "→ <integer>" appears
#   - M-x exit     → process terminates cleanly (no hang)
verb_out=$(printf 'M-x help\nM-x pid\nM-x exit\n' | "$MAST_BIN" 2>&1)
if echo "$verb_out" | grep -q "Built-in M-x commands:"; then
    pass "README §Run: 'M-x help' lists built-in commands"
else
    fail "'M-x help' did not list built-in commands"
fi
if echo "$verb_out" | grep -qE '→ [0-9]+'; then
    pass "README §Run: 'M-x pid' prints an integer PID"
else
    fail "'M-x pid' did not print an integer PID"
fi
if echo "$verb_out" | grep -q "exiting"; then
    pass "README §Run: 'M-x exit' terminates cleanly"
else
    fail "'M-x exit' did not produce an 'exiting' diagnostic"
fi

# ─── Check 5: README documents `M-x (+ 1 2)` → `3` (Janet fall-through) ────
#
# README:
#   M-x (+ 1 2)
#     → 3
#
# This is the README's only executable Janet quickstart claim — if it
# drifts, every "extend mast with Janet" walkthrough in the README is
# suspect. We feed exactly the line the README shows and grep for the
# documented arrow + answer.
janet_out=$(printf 'M-x (+ 1 2)\nM-x exit\n' | "$MAST_BIN" 2>&1)
if echo "$janet_out" | grep -qE '→ 3( |$)'; then
    pass "README quickstart: 'M-x (+ 1 2)' evaluates to → 3"
else
    fail "README quickstart 'M-x (+ 1 2)' did not produce → 3"
    echo "        got: $(echo "$janet_out" | grep '→' | head -2)"
fi

# ─── Check 6: README §Extending — examples/init.janet parses cleanly ──────
#
# README §Extending — `init.janet` references `examples/init.janet` as
# the starter file and shows two forms (`hello`, `buffer-info`) that the
# user is told will be available at the M-x prompt. We:
#   (a) confirm examples/init.janet exists,
#   (b) install it as XDG_CONFIG_HOME/mast/init.janet,
#   (c) start mast and confirm:
#       - the startup banner reports it loaded,
#       - no Janet parse-error diagnostic appears,
#       - (hello "world") returns "hello, world" at the M-x prompt
#         (this is the exact form the README shows).
if [ ! -f "examples/init.janet" ]; then
    fail "README §Extending references examples/init.janet but file missing"
else
    mkdir -p "$XDG_CONFIG_HOME/mast"
    cp examples/init.janet "$XDG_CONFIG_HOME/mast/init.janet"
    init_out=$(printf 'M-x (hello "world")\nM-x exit\n' | "$MAST_BIN" 2>&1)
    if echo "$init_out" | grep -q "init.janet loaded from"; then
        pass "README §Extending: examples/init.janet loads on startup"
    else
        fail "examples/init.janet did not produce 'init.janet loaded from' banner"
    fi
    if echo "$init_out" | grep -qE 'init\.janet (eval|parse) error'; then
        fail "examples/init.janet emitted a Janet parse/eval error on load"
    else
        pass "examples/init.janet parses without error"
    fi
    if echo "$init_out" | grep -q '→ hello, world'; then
        pass "README §Extending: '(hello \"world\")' → 'hello, world'"
    else
        fail "(hello \"world\") did not produce → hello, world"
        echo "        got: $(echo "$init_out" | grep '→' | head -2)"
    fi
    # Clean up so subsequent checks (which expect no init.janet) see
    # the same fresh-VM posture as the unit tests.
    rm -f "$XDG_CONFIG_HOME/mast/init.janet"
fi

# ─── Check 7: MAST_SANDBOX_STRICT=1 strict-mode behaviour ──────────────────
#
# README §Security/Sandbox — `MAST_SANDBOX_STRICT` documents:
#   MAST_SANDBOX_STRICT=1 ./zig-out/bin/mast
#   M-x stax-dashboard
#     → error: mast.sandbox: stax-bash denied — capability `exec` not granted
#
# The existing tests/strict_mode_integration.sh covers all five
# documented behaviours (truthy `1`, truthy `true`, unset, falsy `0`,
# plus the deny diagnostic on both `os/shell` and `stax-bash`). We
# delegate to it rather than duplicating — running the canonical
# integration script IS the README claim verification, and
# divergence between this script and that one would be drift in a
# direction we don't want.
echo "  -- delegating to tests/strict_mode_integration.sh --"
if MAST_BIN="$MAST_BIN" bash tests/strict_mode_integration.sh > "$state_dir/strict_out" 2>&1; then
    if grep -q "PASS: MAST_SANDBOX_STRICT integration — 5/5 cases" "$state_dir/strict_out"; then
        pass "README §Security/Sandbox: MAST_SANDBOX_STRICT 5/5 integration cases"
    else
        fail "strict_mode_integration.sh ran but did not report 5/5"
        sed 's/^/        /' "$state_dir/strict_out" | tail -20
    fi
else
    fail "tests/strict_mode_integration.sh exited non-zero"
    sed 's/^/        /' "$state_dir/strict_out" | tail -20
fi

# ─── Check 8: README explicitly cites `M-x stax-search` under strict ──────
#
# README §Security/Sandbox lists stax-search among the verbs that
# "fail loudly with `denied capability: exec`" under strict mode.
# strict_mode_integration.sh proves os/shell + stax-bash; it does NOT
# directly exercise the `M-x stax-search` user-facing surface. Cover
# that gap here.
#
# DRIFT NOTE: README §Run shows `M-x stax-search "query here"` — i.e.
# with a quoted multi-word arg. The current parse_mx_line() in
# src/main.zig splits on whitespace before any quote-aware handling,
# so `"query` becomes its own positional arg and the resulting Janet
# fall-through parse-errors on the unterminated string literal. The
# load-bearing claim in §Security/Sandbox is "stax-search is gated
# under strict mode", not "M-x supports quoted args", so we exercise
# the deny path with an unquoted single-word arg. If you want to
# preserve the quoted form, either teach parse_mx_line() about quotes
# or change the README example to use a single-word query.
stax_search_out=$(printf 'M-x stax-search hello\nM-x exit\n' \
    | MAST_SANDBOX_STRICT=1 "$MAST_BIN" 2>&1)
if echo "$stax_search_out" | grep -q "capability .exec. not granted"; then
    pass "README §Security/Sandbox: 'M-x stax-search' denied under strict mode"
else
    fail "'M-x stax-search' under MAST_SANDBOX_STRICT=1 did not emit deny diagnostic"
    echo "        got: $(echo "$stax_search_out" | tail -5)"
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== summary ==="
echo "  pass: $n_pass"
echo "  fail: $n_fail"
if [ "$n_fail" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
