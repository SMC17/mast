#!/usr/bin/env bash
# strict_mode_integration.sh — end-to-end test that
# MAST_SANDBOX_STRICT=1 makes deny-by-default observable in the
# production binary.
#
# Wired into `zig build test` via build.zig. Reads $MAST_BIN for the
# binary path (set by the build script).
#
# What this proves: feeding (os/shell ...) and (stax-bash ...) to a
# strict-mode session produces the standard
#   "denied — capability `exec` not granted"
# diagnostic on stderr, and the session-startup banner names the env
# var. That moves the sandbox posture from "mechanism proven in
# sandbox.zig unit tests on a fresh VM" to "deny-by-default
# observable in the production binary".

set -u
# NOTE: not using `set -e`; the binary is EXPECTED to emit non-zero
# exit-status lines (status=1 from the denied Janet form) and the
# pipeline can return non-zero in normal operation.

bin="${MAST_BIN:-}"
if [ -z "$bin" ]; then
    echo "strict_mode_integration.sh: \$MAST_BIN is unset (run via 'zig build test')" >&2
    exit 2
fi
if [ ! -x "$bin" ]; then
    echo "strict_mode_integration.sh: \$MAST_BIN=$bin is not an executable file" >&2
    exit 2
fi

# Hermetic state dir so the test doesn't pollute ~/.local/state/stax/.
state_dir="$(mktemp -d -t mast-strict-it-XXXXXX)"
trap 'rm -rf "$state_dir"' EXIT
export XDG_STATE_HOME="$state_dir"
# Use a per-test XDG_CONFIG_HOME pointing at an empty dir to keep the
# user's init.janet out of the test path.
export XDG_CONFIG_HOME="$state_dir"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ─── Case 1: strict=1, os/shell ─────────────────────────────────────────
out=$(printf '(os/shell "true")\nM-x exit\n' | MAST_SANDBOX_STRICT=1 "$bin" 2>&1)
echo "── case 1: MAST_SANDBOX_STRICT=1 + (os/shell \"true\") ──"
echo "$out"
echo "$out" | grep -q "MAST_SANDBOX_STRICT enabled" || fail "strict-mode banner missing"
echo "$out" | grep -q "os/shell denied" || fail "os/shell deny message missing"
echo "$out" | grep -q "capability .exec. not granted" || fail "exec-cap-not-granted message missing"

# ─── Case 2: strict=1, stax-bash ────────────────────────────────────────
out=$(printf '(stax-bash "true")\nM-x exit\n' | MAST_SANDBOX_STRICT=1 "$bin" 2>&1)
echo "── case 2: MAST_SANDBOX_STRICT=1 + (stax-bash \"true\") ──"
echo "$out"
echo "$out" | grep -q "stax-bash denied" || fail "stax-bash deny message missing"
echo "$out" | grep -q "capability .exec. not granted" || fail "exec-cap-not-granted message missing"

# ─── Case 3: strict=true (alternate truthy value) ───────────────────────
out=$(printf '(os/shell "true")\nM-x exit\n' | MAST_SANDBOX_STRICT=true "$bin" 2>&1)
echo "── case 3: MAST_SANDBOX_STRICT=true + (os/shell \"true\") ──"
echo "$out" | grep -q "os/shell denied" || fail "MAST_SANDBOX_STRICT=true did not enable strict mode"

# ─── Case 4: strict unset → exec auto-granted (regression guard) ────────
unset MAST_SANDBOX_STRICT
out=$(printf '(os/shell "true")\nM-x exit\n' | "$bin" 2>&1)
echo "── case 4: MAST_SANDBOX_STRICT unset + (os/shell \"true\") ──"
echo "$out"
echo "$out" | grep -q "MAST_SANDBOX_STRICT enabled" && fail "strict-mode banner appeared with MAST_SANDBOX_STRICT unset"
echo "$out" | grep -q "capability .exec. not granted" && fail "default mode should grant exec but did not"

# ─── Case 5: strict=0 → exec auto-granted (parser regression guard) ─────
out=$(printf '(os/shell "true")\nM-x exit\n' | MAST_SANDBOX_STRICT=0 "$bin" 2>&1)
echo "── case 5: MAST_SANDBOX_STRICT=0 + (os/shell \"true\") ──"
echo "$out" | grep -q "capability .exec. not granted" && fail "MAST_SANDBOX_STRICT=0 should NOT enable strict mode"

echo ""
echo "PASS: MAST_SANDBOX_STRICT integration — 5/5 cases"
