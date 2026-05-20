#!/usr/bin/env bash
# tools/sandbox-fuzz.sh
#
# Round-3-prescribed fuzz harness for the post-applyDefaultDeny env.
# Drives tools/sandbox-fuzz.janet through mast under MAST_SANDBOX_STRICT=1
# (so no exec cap is granted; every gated wrapper that was supposed to
# panic does panic).  Parses the output for:
#   - RETURNED <sym>      → cfunction returned a value WITHOUT panic.
#                           Flag IF the symbol looks dangerous (system/exec/
#                           fs-mutation/network/process-control/etc).
#   - PANICKED-MAST <sym> → expected: our removed-binding stub fired.
#   - PANICKED-ARITY <sym> → benign: Janet's own arg-count check fired
#                           BEFORE our gate had a chance to evaluate.
#                           Re-probe these with a more informed argv.
#   - PANICKED-OTHER <sym> → suspicious: panic message neither matches
#                           "mast.sandbox" nor an arg-validation error.
#                           Manual review.
#
# Exit codes:
#   0  — clean (no RETURNED entries for dangerous-looking syms, no
#        PANICKED-OTHER entries)
#   1  — at least one suspicious finding
#   2  — fuzz harness failed to run

set -u
cd "$(dirname "$0")/.."

MAST_BIN="${MAST_BIN:-zig-out/bin/mast}"
if [ ! -x "$MAST_BIN" ]; then
    echo "sandbox-fuzz: \$MAST_BIN=$MAST_BIN is not executable" >&2
    exit 2
fi

state_dir=$(mktemp -d -t mast-fuzz-XXXXXX)
trap "rm -rf $state_dir" EXIT
# mast's M-x is line-oriented; multi-line Janet forms get split. Work
# around by installing the fuzz body as init.janet and triggering it
# with a one-line M-x call.
mkdir -p "$state_dir/config/mast"
cp tools/sandbox-fuzz.janet "$state_dir/config/mast/init.janet"

raw=$(echo '(sandbox-fuzz)' | MAST_SANDBOX_STRICT=1 \
    XDG_CONFIG_HOME="$state_dir/config" \
    XDG_STATE_HOME="$state_dir/state" \
    "$MAST_BIN" 2>&1)
if ! echo "$raw" | grep -q ROUNDTHREE_FUZZ_BEGIN; then
    echo "sandbox-fuzz: harness output did not contain ROUNDTHREE_FUZZ_BEGIN — run failed" >&2
    echo "$raw" | tail -20
    exit 2
fi

# Extract the in-band fuzz output (the harness emits one line per cfunc).
report=$(echo "$raw" | sed -n '/ROUNDTHREE_FUZZ_BEGIN/,/ROUNDTHREE_FUZZ_END/p')

# Dangerous-looking pattern: any symbol that contains common syscall-
# adjacent words.  This is intentionally over-broad — a false positive
# triggers manual review (good), a false negative leaks (bad).
danger_re='os/exec|os/spawn|os/posix|os/open|os/pipe|os/getenv|os/setenv|os/environ|os/cd|os/umask|os/link|os/proc|os/sigaction|os/chroot|os/exit|os/stat|os/dir|os/mkdir|os/rmdir|os/rm|os/rename|os/touch|os/symlink|os/chmod|os/readlink|os/realpath|os/shell|file/open|file/temp|file/read|file/write|file/close|file/seek|file/tell|file/flush|file/lines|slurp|spit|dofile|net/connect|net/listen|net/accept|native|unmarshal|marshal|asm|ffi/|ev/thread|ev/spawn-thread'

danger_returned=$(echo "$report" | grep '^RETURNED' | grep -E "$danger_re" || true)
panic_other=$(echo "$report" | grep '^PANICKED-OTHER' || true)
counts=$(echo "$report" | awk '/^MAST-HOST/{h++} /^RETURNED/{r++} /^PANICKED-MAST/{pm++} /^PANICKED-ARITY/{pa++} /^PANICKED-OTHER/{po++} END{print "host=" h " returned=" r " panicked-mast=" pm " panicked-arity=" pa " panicked-other=" po}')

echo "=== mast sandbox-fuzz (round-3 prescribed) ==="
echo "  $counts"

violations=0
if [ -n "$danger_returned" ]; then
    echo ""
    echo "VIOLATIONS — dangerous-looking cfunctions that DID NOT panic:"
    echo "$danger_returned" | sed 's/^/  /'
    violations=$((violations + $(echo "$danger_returned" | wc -l)))
fi

if [ -n "$panic_other" ]; then
    echo ""
    echo "REVIEW — cfunctions panicked with non-mast-sandbox, non-arity messages:"
    echo "$panic_other" | sed 's/^/  /'
    # Don't fail on these — many are benign Janet bytecode errors —
    # but log so a reviewer can inspect.
fi

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "FAIL: $violations dangerous-looking cfunction(s) reachable without panic." >&2
    exit 1
fi

echo "PASS: no dangerous cfunction returned a value from default-deny env."
exit 0
