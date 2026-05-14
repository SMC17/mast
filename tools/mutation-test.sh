#!/usr/bin/env bash
# mast / tools / mutation-test.sh
#
# Stylized mutation-testing harness. Targets the capability-check logic
# in src/sandbox.zig (the load-bearing security claim) + the case-
# insensitive env-var parser + buffer.zig boundary logic.
#
# A SURVIVOR on a sandbox capability check = a real correctness gap in
# the capability mechanism. That would be a security-grade finding.

set -euo pipefail
cd "$(dirname "$0")/.."

declare -a SRC_FILES=("src/sandbox.zig" "src/buffer.zig")
declare -A BACKUPS=()
for f in "${SRC_FILES[@]}"; do
  BACKUPS["$f"]=$(mktemp)
  cp "$f" "${BACKUPS[$f]}"
done
trap 'for f in "${SRC_FILES[@]}"; do cp "${BACKUPS[$f]}" "$f"; rm -f "${BACKUPS[$f]}"; done' EXIT

declare -a MUTATIONS=(
  # ─── Capability check (the load-bearing security claim) ───────────────────
  # Both gated_os_shell and gated_stax_bash use the same `!g_sandbox.has(.exec)` pattern.
  # Apply via replace_all but use a more specific match.
  "M01 (sandbox): capability check sense flip — replace_all (DENY-by-default broken everywhere)|src/sandbox.zig|s,if (!g_sandbox.has(.exec)),if (g_sandbox.has(.exec)),g"
  "M03 (sandbox): os/shell argc < 1 -> argc <= 1 (off-by-one)|src/sandbox.zig|s|if (argc < 1) {|if (argc <= 1) {|"
  "M04 (sandbox): stax-bash argc != 1 -> argc == 1 (sense flip)|src/sandbox.zig|s|if (argc != 1) {|if (argc == 1) {|"

  # ─── env-var parser (case-insensitive strictModeFromEnv-style) ────────────
  "M05 (sandbox): empty-val empty-return == 0 -> != 0 (accept non-empty as empty)|src/sandbox.zig|s|if (val.len == 0) return false|if (val.len != 0) return false|"
  "M06 (sandbox): a.len != b.len return-false -> sense flip|src/sandbox.zig|s|if (a.len != b.len) return false|if (a.len == b.len) return false|"
  "M07 (sandbox): A-Z upper-range >= -> > (off-by-one at A)|src/sandbox.zig|s|if (ca >= 'A' and ca <= 'Z')|if (ca > 'A' and ca <= 'Z')|"

  # ─── buffer.zig — file IO + line counting boundaries ──────────────────────
  "M08 (buffer): fd-check < 0 -> <= 0 (treat 0 as failure — wrong, 0 is stdin)|src/buffer.zig|s|if (fd < 0) return error.OpenFailed|if (fd <= 0) return error.OpenFailed|"
  "M09 (buffer): rc <= 0 break (read loop) -> rc < 0 (silently skip empty reads)|src/buffer.zig|s|if (rc <= 0) break|if (rc < 0) break|"
  "M10 (buffer): mark-out-of-range > -> >= (off-by-one at end-of-buffer)|src/buffer.zig|s|if (self.mark > copy.len) self.mark = copy.len|if (self.mark >= copy.len) self.mark = copy.len|"
  "M11 (buffer): line-count empty-trailing-newline > -> >= (off-by-one)|src/buffer.zig|s|if (self.contents.len > 0 and self.contents\\[self.contents.len - 1\\] != '\\\\n')|if (self.contents.len >= 0 and self.contents[self.contents.len - 1] != '\\n')|"
)

n_total=${#MUTATIONS[@]}
n_killed=0
n_survived=0
declare -a SURVIVORS=()

echo "=== mast mutation testing ==="
echo "operators: $n_total"

for mutation in "${MUTATIONS[@]}"; do
  desc="${mutation%%|*}"
  rest="${mutation#*|}"
  target_file="${rest%%|*}"
  sed_expr="${rest#*|}"

  for f in "${SRC_FILES[@]}"; do cp "${BACKUPS[$f]}" "$f"; done
  sed -i "$sed_expr" "$target_file" 2>/dev/null || true

  if cmp -s "${BACKUPS[$target_file]}" "$target_file"; then
    echo "  SKIPPED   $desc (sed no-op)"
    n_total=$((n_total - 1))
    continue
  fi

  if zig build test >/dev/null 2>&1; then
    n_survived=$((n_survived + 1))
    SURVIVORS+=("$desc")
    echo "  SURVIVED  $desc"
  else
    n_killed=$((n_killed + 1))
    echo "  KILLED    $desc"
  fi
done

for f in "${SRC_FILES[@]}"; do cp "${BACKUPS[$f]}" "$f"; done

echo
echo "=== summary ==="
echo "  total effective: $n_total"
echo "  killed:          $n_killed"
echo "  survived:        $n_survived"
if [ "$n_total" -gt 0 ]; then
  score=$(awk -v k="$n_killed" -v t="$n_total" 'BEGIN{printf "%.1f", k/t*100}')
  echo "  mutation score:  $score%"
fi
if [ "$n_survived" -gt 0 ]; then
  echo
  echo "Survivors:"
  for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
  exit 1
fi
exit 0
