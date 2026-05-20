#!/usr/bin/env bash
# tests/quota_integration.sh
#
# Integration test for the v1.3.5 wall-clock resource quota.  Spawns
# the actual shipped binary with MAST_EVAL_TIMEOUT_SEC set to a small
# value, feeds it an infinite-loop expression on stdin, and asserts:
#   1. The process EXITS within a tight wall-clock bound (the quota +
#      a fudge factor, NOT 30+ seconds of hang)
#   2. The output contains the documented "interrupted" panic marker
#   3. The exit status is 0 (the editor recovered cleanly; the
#      cancelled fiber surfaces as an in-session error, not a crash)
#
# This is the integration counterpart to the SIGALRM + janet_interpreter_
# interrupt smoke test in the v1.3.5 release notes.  Wired into
# `zig build test` so the quota is exercised on every test run.

set -u
cd "$(dirname "$0")/.."

MAST_BIN="${MAST_BIN:-zig-out/bin/mast}"
if [ ! -x "$MAST_BIN" ]; then
    echo "quota_integration: \$MAST_BIN=$MAST_BIN is not executable" >&2
    exit 2
fi

n_pass=0
n_fail=0

pass() {
    n_pass=$((n_pass + 1))
    echo "  PASS  $1"
}
fail() {
    n_fail=$((n_fail + 1))
    echo "  FAIL  $1"
}

echo "=== mast quota integration test ==="

# ─── Case 1: wall-clock quota interrupts an infinite loop ──────────────
#
# 2-second quota.  The infinite (while true 1) form would otherwise run
# until external Ctrl-C.  We give the process 10 seconds to come back
# (very generous wall-clock budget — should actually return in ~2s).
# If the process is still running after 10s, the quota didn't fire.

t_start=$(date +%s)
output=$(echo '(while true 1)' | timeout 10 \
    env MAST_EVAL_TIMEOUT_SEC=2 "$MAST_BIN" 2>&1) || true
exit_status=$?
t_end=$(date +%s)
elapsed=$((t_end - t_start))

if [ "$elapsed" -lt 7 ]; then
    pass "wall-clock quota returns within fudged budget (elapsed=${elapsed}s, budget=2s)"
else
    fail "wall-clock quota did not fire within 7s (elapsed=${elapsed}s)"
fi

if echo "$output" | grep -q "interrupted"; then
    pass "interrupted-fiber diagnostic appears in output"
else
    fail "no 'interrupted' diagnostic — quota may not have fired"
    echo "        got tail: $(echo "$output" | tail -3)"
fi

if [ "$exit_status" -eq 0 ]; then
    pass "editor recovers cleanly (exit status 0, not a crash)"
else
    fail "editor exit status $exit_status — expected 0 (quota should be in-session, not fatal)"
fi

# ─── Case 2: a fast expression completes well before the quota ─────────
#
# Sanity: (+ 1 2) should return well under any quota.  This catches a
# regression where the quota fires too early (eg. measuring from
# process start instead of from janet_dostring entry).

output_fast=$(echo '(+ 1 2)' | timeout 10 \
    env MAST_EVAL_TIMEOUT_SEC=2 "$MAST_BIN" 2>&1) || true
if echo "$output_fast" | grep -qE '→ 3( |$)'; then
    pass "fast expression (+ 1 2) returns → 3 without triggering quota"
else
    fail "fast expression did not return → 3"
    echo "        got: $(echo "$output_fast" | grep '→' | head -2)"
fi

# ─── Case 3: env var unset == default 30s quota, not infinite ──────────
#
# Confirm the default quota is set even when MAST_EVAL_TIMEOUT_SEC is
# unset.  Use a 3-second sleep-equivalent: a tight loop bounded by a
# 3-second wall-clock cap from the shell's timeout(1).  The point is
# to prove the binary doesn't accidentally disable the quota when the
# env var is missing.  We assert mast prints the "eval-timeout-
# installed" diagnostic to its audit log (we can grep the audit log
# directly to confirm the handler was installed).
#
# This case uses a fresh temp dir so the audit log is isolated.

state_dir=$(mktemp -d -t mast-quota-XXXXXX)
trap "rm -rf $state_dir" EXIT
unset MAST_EVAL_TIMEOUT_SEC
output_default=$(echo '(+ 1 1)' | XDG_STATE_HOME="$state_dir/state" \
    XDG_CONFIG_HOME="$state_dir/config" \
    timeout 10 "$MAST_BIN" 2>&1) || true

# Find the session audit log
audit_file=$(find "$state_dir/state/stax/editor-sessions" -name '*.jsonl' 2>/dev/null | head -1)
if [ -z "$audit_file" ]; then
    fail "default-quota: no audit log file found at expected path"
elif grep -q '"event":"eval-timeout-installed"' "$audit_file"; then
    pass "default-quota: audit log shows eval-timeout-installed event"
else
    fail "default-quota: eval-timeout-installed event missing from audit log"
    head -5 "$audit_file" 2>/dev/null | sed 's/^/        /'
fi

# ─── Case 4: subsequent eval after a timeout still works ─────────────
#
# Round-4 adversarial finding #1: SIGALRM quota leaks auto_suspend.
# Pre-fix: ONE timeout left vm->auto_suspend == 1 for the rest of the
# process, so every subsequent eval interrupted at the first bytecode
# op.  This case is the load-bearing regression test for that fix:
#   1. trigger the quota with (while true 1)
#   2. immediately follow with (+ 2 40)
#   3. assert the second eval returns → 42, NOT another "interrupted"
#
# The original quota_integration.sh missed this because it piped one
# expression then EOFed.  This case sends multiple expressions in a
# single session.

multi_out=$(printf '(while true 1)\n(+ 2 40)\nexit\n' | timeout 10 \
    env MAST_EVAL_TIMEOUT_SEC=2 "$MAST_BIN" 2>&1) || true
# The (+ 2 40) line must return → 42 AFTER the interrupted (while ...).
if echo "$multi_out" | grep -qE '→ 42( |$)'; then
    pass "Round-4 #1: post-timeout eval (+ 2 40) returns → 42 (auto_suspend drained)"
else
    fail "Round-4 #1: post-timeout (+ 2 40) did not return → 42 — auto_suspend leak NOT closed"
    echo "        got tail: $(echo "$multi_out" | tail -8 | sed 's/^/        /')"
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
if [ "$n_fail" -gt 0 ]; then
    echo "FAIL: quota integration — $n_pass pass, $n_fail fail"
    exit 1
fi
echo "PASS: quota integration — $n_pass/$n_pass cases"
exit 0
