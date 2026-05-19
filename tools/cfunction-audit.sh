#!/usr/bin/env bash
# tools/cfunction-audit.sh — host-cfunction regression discipline
#
# Closes residual #10 of docs/SANDBOX_THREAT_MODEL.md §6: "No defense
# against host-side `cfunction` regression."  The convention is that any
# new `janet_def`-registered cfunction in main.zig that performs a
# dangerous syscall (libc.system, libc.popen, libc.exec*, libc.fork)
# MUST consult `sandbox.g_sandbox.has(...)` or delegate to a
# `sandbox.gated_*` function before the syscall.  This script enumerates
# every registered cfunction, classifies its body, and FAILS if it finds
# a body that touches dangerous syscalls without going through the
# capability check.
#
# Run: bash tools/cfunction-audit.sh
# Exit: 0 if clean, 1 if any violation found.
#
# False-positive policy: a cfunction can opt out by including the marker
#   // cfunction-audit-ok: <reason>
# in its body.  The reason is recorded but not parsed.  This is the same
# escape hatch ESLint / golangci-lint use for "yes we know, here's why."

set -euo pipefail

cd "$(dirname "$0")/.."

MAIN="src/main.zig"
SANDBOX="src/sandbox.zig"

if [ ! -f "$MAIN" ] || [ ! -f "$SANDBOX" ]; then
  echo "ERROR: $MAIN or $SANDBOX not found (run from repo root)" >&2
  exit 2
fi

echo "# cfunction sandbox-discipline audit"
echo ""
echo "Source: $MAIN + $SANDBOX"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Patterns that mean "this body calls into the host in a way the sandbox
# capability model is supposed to mediate."
DANGER_RE='libc\.(system|popen|execl|execv|execvp|execvpe|execve|fork)\b'
GATE_RE='(sandbox\.)?g_sandbox\.has\(|sandbox\.gated_'
ESCAPE_RE='cfunction-audit-ok:'

# Extract the list of cfunctions registered via janet_def in main.zig.
# Pattern: janet.janet_wrap_cfunction(<NAME>)
mapfile -t funcs < <(grep -oP 'wrap_cfunction\(\K[a-zA-Z_./]+' "$MAIN" | sort -u)

violations=0
total=0
gated=0
benign=0

# For each cfunction, extract its body and classify.
# Body extraction: find `fn NAME(` in either src file, capture from that
# line to the next top-level `fn ` or `pub fn ` at column 0.
for fn in "${funcs[@]}"; do
  total=$((total + 1))
  # Strip a "sandbox." prefix; the actual fn lives in sandbox.zig.
  raw_fn="${fn#sandbox.}"
  if [ "$fn" != "$raw_fn" ]; then
    src="$SANDBOX"
  else
    src="$MAIN"
  fi

  # awk extracts the body: from "fn NAME(" to the next top-level "fn " or
  # end of file.  We use a state machine: enter on the matching fn line,
  # exit on the next top-level fn/pub fn/test " ... " at column 0.
  body=$(awk -v target="$raw_fn" '
    BEGIN { in_fn = 0 }
    /^(pub )?fn / {
      if (in_fn) { exit }
      # Accept "fn NAME(" or "pub fn NAME("
      line = $0
      if (match(line, /(pub )?fn [a-zA-Z_]+/)) {
        name = substr(line, RSTART, RLENGTH)
        sub(/^(pub )?fn /, "", name)
        if (name == target) { in_fn = 1; print; next }
      }
    }
    in_fn { print }
  ' "$src")

  if [ -z "$body" ]; then
    echo "- \`$fn\` — **WARN**: body not found in $src (audit cannot classify)"
    continue
  fi

  has_danger=0
  has_gate=0
  has_escape=0
  if echo "$body" | grep -qE "$DANGER_RE"; then has_danger=1; fi
  if echo "$body" | grep -qE "$GATE_RE"; then has_gate=1; fi
  if echo "$body" | grep -qE "$ESCAPE_RE"; then has_escape=1; fi

  if [ "$has_danger" -eq 1 ] && [ "$has_gate" -eq 0 ] && [ "$has_escape" -eq 0 ]; then
    violations=$((violations + 1))
    echo "- \`$fn\` — **VIOLATION**: body touches a dangerous syscall (\`$(echo "$body" | grep -oE "$DANGER_RE" | head -1)\`) but no \`sandbox.g_sandbox.has(...)\` check or \`sandbox.gated_*\` delegate is present."
  elif [ "$has_danger" -eq 1 ] && [ "$has_gate" -eq 1 ]; then
    gated=$((gated + 1))
    echo "- \`$fn\` — gated (calls dangerous syscall AND consults capability set)"
  elif [ "$has_danger" -eq 1 ] && [ "$has_escape" -eq 1 ]; then
    benign=$((benign + 1))
    echo "- \`$fn\` — escape-hatch (\`cfunction-audit-ok:\` marker present)"
  else
    benign=$((benign + 1))
    echo "- \`$fn\` — benign (no dangerous syscall in body)"
  fi
done

echo ""
echo "## Summary"
echo ""
echo "- Total cfunctions: $total"
echo "- Gated (dangerous + cap-check): $gated"
echo "- Benign (no dangerous syscall): $benign"
echo "- Violations: $violations"
echo ""

if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations cfunction(s) violate the host-cfunction sandbox discipline." >&2
  echo "Each violation either needs a \`sandbox.g_sandbox.has(...)\` check before the syscall," >&2
  echo "or an explicit \`// cfunction-audit-ok: <reason>\` marker explaining why the gate is unnecessary." >&2
  exit 1
fi

echo "PASS: all $total cfunctions respect the sandbox discipline."
exit 0
