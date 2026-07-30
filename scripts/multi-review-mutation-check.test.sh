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
grep -q 'no mutation ran' <<< "$out" && ok "unknown id says nothing ran" \
  || bad "unknown id did not say nothing ran: '$out'"
grep -qi 'all .* caught' <<< "$out" && bad "unknown id claimed mutations were caught" \
  || ok "unknown id does not claim success"
# ...and it must NOT have paid for a full baseline sweep to say so. An unknown id is a usage error,
# and answering it behind a two-minute gate run also lets unrelated redness answer with the wrong
# message ("the gate is already red") instead of "no such id".
grep -q 'baseline' <<< "$out" && bad "unknown id ran the baseline sweep before rejecting the id" \
  || ok "unknown id is rejected without running the baseline"

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
  if grep -q 'REFUSING to run' <<< "$out"; then
    # The runner declined because the environment's gate is red for reasons unrelated to this test.
    # ALL three assertions must be skipped, not just the two whose variables were reset — leaving
    # the third to run turned the promised skip into a bogus failure (fable-rd2-r1).
    ok "live-mutation check skipped (baseline not green in this environment)"
  else
    [[ "$before" == "$after" ]] && ok "a live mutation restores the file byte-identically" \
      || bad "the runner left ${target} modified"
    [[ $rc -eq 0 ]] && ok "the seeded egress mutation is still caught" || bad "egress mutation rc=$rc: $out"
    grep -q 'caught \[egress/symlink-file\]' <<< "$out" \
      && ok "the run names the mutation it caught" || bad "run output did not name the caught mutation"
  fi
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

# --- fable-rd1-r1, asserted through BEHAVIOUR: a suite that goes RED without printing a FAIL: line
# must not read as green. The first version of this test grepped the implementation, which both
# reviewers pointed out would stay green under a reverted fix (codex-rd2-r2, fable-rd2-r2) — the
# very vacuous-verification class this runner exists to catch, in its own regression test.
#
# So: plant a real suite that exits non-zero and prints NOTHING, then run a SURVIVES-BY-DESIGN entry.
# With redness read from the status it must report STALE; with redness read from FAIL: text it would
# report "survives by design" while the gate is red.
PROBE="${ROOT}/scripts/zzz-mutation-crash-probe.test.sh"
if [[ -e "$PROBE" ]]; then
  bad "crash-probe: ${PROBE} already exists — refusing to overwrite"
elif [[ -n "${MULTI_REVIEW_MUTATION_RUNNING:-}" ]]; then
  ok "crash-probe skipped (running inside a mutation sweep)"
else
  # The probe must be GREEN at baseline and fail ONLY while the mutation is applied — otherwise it
  # exercises the baseline loop (which reads the status directly) instead of gate_catches' redness
  # accounting, which is the thing under test. So it keys off the guard the mutation removes, and
  # fails SILENTLY: no `FAIL:` line, which is precisely the case that used to read as green.
  cat > "$PROBE" <<'PROBEEOF'
#!/usr/bin/env bash
# test scaffolding — planted and removed by multi-review-mutation-check.test.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q '10#\$av > 10#\$bv' "${ROOT}/scripts/multi-review-version-check.sh" || exit 1
echo "  ok: crash probe sees the guard"
PROBEEOF
  out="$(bash "$SUT" --only version/octal-greater 2>&1)"; rc=$?
  rm -f "$PROBE"
  # version/octal-greater is a SURVIVES-BY-DESIGN entry. The probe makes the gate genuinely red
  # while it is applied, so the correct verdict is STALE. Reading redness from FAIL: text instead of
  # the exit status finds nothing, and certifies "survives by design" against a red gate.
  if grep -q 'STALE' <<< "$out"; then
    ok "crash-probe: a silently-failing suite makes a survives-by-design entry STALE"
  else
    bad "crash-probe: silent failure was not seen as red (rc=$rc): $(tr '\n' '|' <<< "$out" | cut -c1-200)"
  fi
  grep -q 'survives by design' <<< "$out" \
    && bad "crash-probe: certified 'survives by design' while the gate was red" \
    || ok "crash-probe: did not certify a red gate as survives-by-design"
fi

# --- fable-rd1-r3, asserted through the RUNNER rather than through git's semantics ---
# The first version only pinned that `git diff --quiet` passes on an untracked file, which proves
# nothing about the guard: deleting it left the gate green (fable-rd2-r3).
UT="${ROOT}/zzz-mutation-untracked-probe.sh"
if [[ -e "$UT" ]]; then
  bad "untracked-probe: ${UT} already exists — refusing to overwrite"
else
  printf '#!/usr/bin/env bash\n: guard\n' > "$UT"
  bash "$SUT" --check-target "zzz-mutation-untracked-probe.sh" >/dev/null 2>&1; rc=$?
  rm -f "$UT"
  [[ $rc -eq 3 ]] && ok "untracked target is refused by the runner (rc=3)" \
    || bad "untracked target accepted by the runner (rc=$rc) — no git recovery would exist"
fi
# rc 3 = untracked, rc 4 = tracked but dirty. Only the FIRST is what this guard decides; whether the
# working tree happens to be clean right now is environmental, so asserting rc 0 would make the test
# fail during ordinary development rather than on a regression.
bash "$SUT" --check-target "scripts/multi-review-mutation-check.sh" >/dev/null 2>&1; rc=$?
[[ $rc -ne 3 ]] && ok "a tracked target is not rejected as untracked (rc=$rc)" \
  || bad "a tracked target was reported untracked"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
