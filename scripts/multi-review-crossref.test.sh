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
# The same regression, through the pair channel: the channel a real document actually exercises.
# A fence-blind _sections truncates Task 1's section before it reaches `scripts/shared.sh`, so no
# pair row is ever emitted for it — checking _sections alone would miss that failure mode.
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
awk -F'\t' '$2=="pair" && $4=="scripts/shared.sh"' <<<"$out" | grep -q . \
  && ok "rows: fence-aware heading detection yields a pair row for scripts/shared.sh" \
  || bad "rows: no pair row for scripts/shared.sh — fence-blind heading detection truncated the section"

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
# The same regression, through the pair channel: the channel a real document actually exercises.
# A depth-blind _sections ends Task 1 at its own Step 1 heading, before it reaches
# `scripts/shared.sh`, so no pair row is ever emitted for it.
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
awk -F'\t' '$2=="pair" && $4=="scripts/shared.sh"' <<<"$out" | grep -q . \
  && ok "rows: depth-based section boundaries yield a pair row for scripts/shared.sh" \
  || bad "rows: no pair row for scripts/shared.sh — depth-blind boundaries truncated the section"

# --- P-rows come from declared UNION named, never declarations alone ---
#
# THIS IS THE REGRESSION TEST FOR THE UNION RULE (spec criterion 10). #90 measured six Files
# entries with no corresponding step in a single document: declarations are routinely wrong, and
# the section that failed to declare a file is the section least likely to have thought about who
# else touches it. A pair set built from declarations alone inherits that error exactly where it
# matters. A declaration-only implementation passes every other test in this plan and fails here.
D="$(mkdoc union.md \
  '# Plan' '' \
  '### Task 1: rewrites a line it never declares' '' \
  '**Files:**' '- Modify: `scripts/star.sh`' '' \
  'Step 7 also rewrites the entry in `scripts/mutation-check.sh`.' '' \
  '### Task 4: declares the file Task 1 quietly touched' '' \
  '**Files:**' '- Modify: `scripts/mutation-check.sh`' '' \
  'Add the new entries.' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
awk -F'\t' '$2=="pair" && $4=="scripts/mutation-check.sh"' <<<"$out" | grep -q . \
  && ok "rows: a pair is generated when only ONE side declared the shared file" \
  || bad "rows: no pair row for scripts/mutation-check.sh — the union rule is not in effect, and this repo's own shipped defect would survive"
n="$(awk -F'\t' '$2=="pair"' <<<"$out" | wc -l | tr -d ' ')"
[[ "$n" == 1 ]] && ok "rows: exactly one pair row (got $n)" \
  || bad "rows: expected 1 pair row, got $n — scripts/star.sh is named by one section only and must not pair"

# A path inside a fenced block is illustrative output, not a file the section touches.
D="$(mkdoc fenced.md \
  '# Plan' '' \
  '### Task 1: real' '' '**Files:**' '- Modify: `scripts/real.sh`' '' \
  'Expected output:' '' '```' 'wrote scripts/fenced-only.sh' '```' '' \
  '### Task 2: also real' '' '**Files:**' '- Modify: `scripts/other.sh`' '' \
  'Mentions `scripts/fenced-only.sh` in prose.' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
awk -F'\t' '$2=="pair"' <<<"$out" | grep -q . \
  && bad "rows: a path inside a fenced block manufactured a pair" \
  || ok "rows: fenced-block paths do not manufacture pairs"

# --- the fixture reproduces the shipped defect, and the pass must catch it ---
# Kept as a fixture rather than pointed at the real plan document: /docs/superpowers/ is
# gitignored (.gitignore:11), so a test reading it would pass here and be broken in CI and in
# every fresh clone — an unfalsifiable check, which is the class this design exists to close.
F="${DIR}/fixtures/crossref-plan-sample.md"
if [[ ! -f "$F" ]]; then
  bad "fixture missing: $F"
else
  out="$(bash "$SUT" rows "$F" 2>/dev/null)"
  awk -F'\t' '$2=="pair" && $4=="scripts/multi-review-mutation-check.sh"' <<<"$out" | grep -q . \
    && ok "rows: the fixture's named-only/declared-only pair is generated" \
    || bad "rows: the union pair is absent — a declaration-only pair set would ship"
  # Task 3: awk -F'\t' '$2=="iface"' <<<"$out" | grep -q . \
  # Task 3:   && ok "rows: the fixture yields an interface row" \
  # Task 3:   || bad "rows: no iface row from the fixture (expected once Task 3 lands)"
fi

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
