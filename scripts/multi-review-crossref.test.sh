#!/usr/bin/env bash
# multi-review-crossref.test.sh — row derivation and coverage checking for the cross-reference pass.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-crossref.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkdoc <name> <line...> -> path
mkdoc() { local p="${WORK}/$1"; shift; printf '%s\n' "$@" > "$p"; echo "$p"; }

# --- not applicable: a doc with no sectioned structure ---
# Announced, never silent. A pass that quietly does not run is indistinguishable at the gate from
# one that ran and found nothing — the same failure mode the whole design exists to close.
D="$(mkdoc plain.md '# A design' '' 'Some prose.' '' '## Review' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"; rc=$?
[[ $rc == 3 && -z "$out" ]] \
  && ok "rows: unsectioned doc exits 3 with no rows" \
  || bad "rows: unsectioned doc rc=$rc out='$out' (want rc=3, empty)"
err="$(bash "$SUT" rows "$D" 2>&1 >/dev/null)"
grep -qF 'not applicable' <<<"$err" \
  && ok "rows: the not-applicable reason is stated on stderr" \
  || bad "rows: exits 3 without saying why: '$err'"

# --- section detection requires BOTH an ordinal heading and a Files/Interfaces block ---
# The ordinal alone would sweep in prose headings; the block alone would sweep in a preamble.
D="$(mkdoc twosec.md \
  '# Plan' '' \
  '## Overview' '' 'Mentions `scripts/a.sh` but declares nothing.' '' \
  '### Task 1: first' '' '**Files:**' '- Modify: `scripts/a.sh`' '' 'Edit `scripts/a.sh`.' '' \
  '### Task 2: second' '' '**Files:**' '- Modify: `scripts/b.sh`' '' 'Edit `scripts/b.sh`.' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && ok "rows: a two-section doc is applicable" || bad "rows: two-section doc rc=$rc"
n="$(awk -F'\t' '$2=="self"' <<<"$out" | wc -l | tr -d ' ')"
[[ "$n" == 2 ]] && ok "rows: one self row per qualifying section (got $n)" \
  || bad "rows: expected 2 self rows, got $n — a preamble that names a file may have qualified"

# --- a '#' line inside a fenced block is not a heading (spec criterion 11) ---
# Reproduced against a real plan: a bash comment "# --- setup ---" parsed as a depth-1 heading and
# truncated a 416-line task to 33 lines, silently discarding every pair in the rest of its body.
D="$(mkdoc fencedhead.md \
  '# Plan' '' \
  '### Task 1: first' '' '**Files:**' '- Modify: `scripts/a.sh`' '' \
  'Run:' '' '```bash' '# --- setup ---' 'echo hi' '```' '' \
  'Then edit `scripts/shared.sh`.' '' \
  '### Task 2: second' '' '**Files:**' '- Modify: `scripts/shared.sh`' '')"
# NOTE: verified via _sections directly, not via a pair row — pair-row emission is Task 2's
# job and does not exist yet. This still exercises exactly the defect described above: a
# fence-blind _sections would end Task 1's section at line 10 (right before the fake heading);
# fence-aware, it runs through line 16, past "Then edit `scripts/shared.sh`."
secs="$(bash -c 'doc="$1"; source "$0" rows "$doc" >/dev/null 2>&1; _sections "$doc"' "$SUT" "$D")"
e="$(awk -F'\t' '$4=="Task 1"{print $3}' <<<"$secs")"
[[ "$e" -ge 15 ]] \
  && ok "rows: a fenced '#' comment does not truncate its section" \
  || bad "rows: Task 1's section ended at line ${e:-<none>} — heading detection is fence-blind"

# --- section boundaries use heading DEPTH, not the next ordinal heading (spec criterion 12) ---
D="$(mkdoc substep.md \
  '# Plan' '' \
  '### Task 1: has sub-steps' '' '**Files:**' '- Modify: `scripts/a.sh`' '' \
  '#### Step 1: do a thing' '' 'Edit `scripts/shared.sh`.' '' \
  '### Task 2: second' '' '**Files:**' '- Modify: `scripts/shared.sh`' '')"
# NOTE: verified via _sections directly, not via a pair row — pair-row emission is Task 2's
# job and does not exist yet. Depth-blind, Task 1 would end at line 7 (its own Step 1 heading);
# depth-aware, it runs through line 11, past "Edit `scripts/shared.sh`."
secs="$(bash -c 'doc="$1"; source "$0" rows "$doc" >/dev/null 2>&1; _sections "$doc"' "$SUT" "$D")"
e="$(awk -F'\t' '$4=="Task 1"{print $3}' <<<"$secs")"
[[ "$e" -ge 10 ]] \
  && ok "rows: a task runs past its own sub-steps" \
  || bad "rows: the task ended at line ${e:-<none>} — depth is not being used"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
