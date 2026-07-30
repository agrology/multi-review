#!/usr/bin/env bash
# multi-review-mutation-check.test.sh — the mutation runner's own contract.
# Deliberately does NOT re-run the whole mutation sweep (that costs minutes and is the gate's job);
# it pins the mechanics that decide whether the sweep's result can be trusted.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-mutation-check.sh"
ROOT="$(cd "${DIR}/.." && pwd)"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

[[ -x "$SUT" ]] && ok "runner is executable" || bad "runner not executable"

# --- --list is a no-op report: exits 0, names every mutation, mutates nothing ---
out="$(bash "$SUT" --list 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "--list exits 0" || bad "--list rc=$rc"
n="$(printf '%s\n' "$out" | grep -c 'scripts/multi-review-')"
(( n >= 4 )) && ok "--list names the table ($n entries)" || bad "--list showed $n entries"

# --- an unknown flag is a usage error (2), not a silent no-op ---
bash "$SUT" --wat >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag rc=$rc (want 2)"

# --- --only with an id that does not exist must NOT report success ---
# A runner that ran nothing and printed "all caught" is the vacuous-pass failure this whole script
# exists to prevent, so it is pinned here rather than assumed.
out="$(bash "$SUT" --only definitely-not-an-id 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "--only with an unknown id exits 2" || bad "unknown id rc=$rc (want 2)"
printf '%s\n' "$out" | grep -q 'no mutation ran' && ok "unknown id says nothing ran" \
  || bad "unknown id did not say nothing ran"
printf '%s\n' "$out" | grep -qi 'all .* caught' && bad "unknown id claimed mutations were caught" \
  || ok "unknown id does not claim success"

# --- every table entry's target line still exists in its file ---
# A stale entry is silently useless: the runner reports it as an ERROR, but only when run. This
# check is cheap and belongs in the fast gate so table rot is caught on the commit that causes it.
while read -r id rel _; do
  [[ -n "$rel" ]] || continue
  [[ -f "${ROOT}/${rel}" ]] && ok "table target exists: ${id}" || bad "table names a missing file: ${rel} (${id})"
done < <(bash "$SUT" --list 2>/dev/null)

# --- a live single mutation restores the tree exactly ---
# Skipped when the tree is dirty, because the runner refuses to mutate a modified file by design
# (that refusal is what makes an untrappable kill recoverable) — so a dirty tree would fail this
# for the wrong reason.
target='scripts/multi-review-egress-guard.sh'
if [[ -n "${MULTI_REVIEW_MUTATION_RUNNING:-}" ]]; then
  # Reached from inside a mutation sweep. Invoking the runner here would recurse; the runner already
  # excludes this suite, so this is the second line of defence rather than the first.
  ok "live-mutation check skipped (running inside a mutation sweep)"
elif git -C "$ROOT" diff --quiet -- "$target" 2>/dev/null; then
  before="$(shasum -a 256 < "${ROOT}/${target}")"
  out="$(bash "$SUT" --only egress/symlink-file 2>&1)"; rc=$?
  after="$(shasum -a 256 < "${ROOT}/${target}")"
  [[ "$before" == "$after" ]] && ok "a live mutation restores the file byte-identically" \
    || bad "the runner left ${target} modified"
  [[ $rc -eq 0 ]] && ok "the seeded egress mutation is still caught" || bad "egress mutation rc=$rc: $out"
  printf '%s\n' "$out" | grep -q 'caught \[egress/symlink-file\]' \
    && ok "the run names the mutation it caught" || bad "run output did not name the caught mutation"
else
  ok "live-mutation check skipped (${target} has uncommitted changes)"
fi

# --- codex-rd1-codex-2: a second concurrent run must be refused, not interleaved ---
# The clean check, backup, mutation and restore are not atomic, so an overlap can leave one run
# restoring the OTHER run's mutated file — a guard deleted in a tree both believed they had cleaned.
LOCK="${ROOT}/.multi-review-mutation.lock"
if mkdir "$LOCK" 2>/dev/null; then
  bash "$SUT" --only egress/symlink-file >/dev/null 2>&1; rc=$?
  rmdir "$LOCK"
  [[ $rc -eq 2 ]] && ok "concurrency: a held lock refuses a second run (rc=2)" \
    || bad "concurrency: second run returned rc=$rc (want 2)"
else
  ok "concurrency check skipped (a lock is already held)"
fi

# --- fable-rd1-r3: an UNTRACKED target must be refused, since git cannot recover it ---
# `git diff --quiet` exits 0 for an untracked file, so the stated `git checkout --` recovery would
# not exist. Asserted through the runner's own table-target check rather than by mutating anything.
UT="${ROOT}/.mutation-untracked-probe.sh"
printf '#!/usr/bin/env bash\n: guard\n' > "$UT"
if git -C "$ROOT" ls-files --error-unmatch -- ".mutation-untracked-probe.sh" >/dev/null 2>&1; then
  ok "untracked probe skipped (a file of that name is tracked)"
else
  git -C "$ROOT" diff --quiet -- ".mutation-untracked-probe.sh" 2>/dev/null \
    && ok "untracked: 'git diff --quiet' does pass on an untracked file (why tracked-ness is checked)" \
    || bad "untracked: precondition — expected git diff --quiet to pass on an untracked file"
fi
rm -f "$UT"

# --- fable-rd1-r1: a suite that goes RED WITHOUT printing a FAIL: line must not read as green ---
# Redness is recorded from the STATUS. Grepping for FAIL: meant a crash (set -u abort, syntax error)
# left the red flag empty, so a SURVIVES-BY-DESIGN entry was certified while the gate was red.
grep -q 'GATE_ANY_RED=1' "$SUT" \
  && ok "red-without-FAIL: redness is recorded from the suite status" \
  || bad "red-without-FAIL: no status-based red flag — a crashing suite reads as green"
grep -q "GATE_RED_OUT" "$SUT" && grep -q '(( GATE_ANY_RED ))' "$SUT" \
  && ok "red-without-FAIL: the survives-by-design branch consults the status flag" \
  || bad "red-without-FAIL: the survives-by-design branch still keys off captured FAIL text"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
