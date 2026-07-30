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
if git -C "$ROOT" diff --quiet -- "$target" 2>/dev/null; then
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

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
