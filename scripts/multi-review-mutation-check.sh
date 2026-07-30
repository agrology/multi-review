#!/usr/bin/env bash
# multi-review-mutation-check.sh — prove the suite actually catches the removal of each guard.
#
# WHY THIS EXISTS. A green gate does not mean a guard bites. Twice in this repo a security guard
# shipped with ZERO coverage and was found only by deleting it by hand and noticing the suite stayed
# green (the combined-diff reset and the `+++`-path TAB strips, both added in aa474f6). The same
# class — a verification that reads correctly but cannot fail — has bitten five other times in
# review docs. This script mechanizes the one check that keeps finding it.
#
# Each entry deletes or rewrites ONE line and asserts two things:
#   1. the mutation actually applied  — a `sed` that silently matches nothing is the classic way to
#      "prove" a guard is uncovered when in fact nothing was mutated. Exact full-line equality with
#      a match count makes that a hard error rather than a false result.
#   2. the suite goes RED, and specifically that the NAMED assertion fails — not merely that
#      something somewhere failed. Without the name, a mutation that breaks an unrelated test reads
#      as coverage the guard does not have.
#
# KNOWN LIMIT (fable-rd2-r6, accepted): no per-suite timeout. A mutation that makes a suite HANG
# stalls the sweep with the lock held, and the eventual hard kill is the one path the trap cannot
# cover. `timeout(1)` is not present on macOS, which is a first-class platform here, and a bash
# watchdog is more machinery than the risk warrants — a hung suite is visible and Ctrl-C now exits
# cleanly. Recorded rather than silently tolerated.
#
# Usage: multi-review-mutation-check.sh [--list] [--only <id>]
#   --list        print the table and exit 0
#   --only <id>   run a single mutation
# Exit: 0 all mutations caught; 1 a mutation SURVIVED or was miscredited; 2 usage/setup error.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SELF}/.." && pwd)"
only=""; list=0
while (( $# )); do
  case "$1" in
    # Testability seam for the target preconditions (tracked + clean). Without it the tracked-ness
    # guard is unreachable from a test, which is how it shipped asserted only by a source grep
    # (fable-rd2-r3). Deliberately undocumented in --help; it exists for the suite.
    --check-target)
      _t="${2:?--check-target needs a path}"
      git -C "$ROOT" ls-files --error-unmatch -- "$_t" >/dev/null 2>&1 \
        || { echo "mutation-check: ${_t} is not tracked by git" >&2; exit 3; }
      git -C "$ROOT" diff --quiet -- "$_t" 2>/dev/null \
        || { echo "mutation-check: ${_t} has uncommitted changes" >&2; exit 4; }
      exit 0 ;;
    --list) list=1; shift ;;
    --only) only="${2:?--only needs an id}"; shift 2 ;;
    *) echo "mutation-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fails=0; ran=0

# This script runs the test suites, and one of those suites tests THIS script — which would run the
# suites again, forever. So the runner's own suite is excluded from every gate it runs, and a marker
# is exported so the suite can also refuse to invoke the runner if it is ever reached some other way.
# (Before the baseline check existed the recursion happened to terminate, purely because the
# preferred-suite ordering found its answer before reaching this file. That was luck, not design.)
SELF_SUITE='multi-review-mutation-check.test.sh'
export MULTI_REVIEW_MUTATION_RUNNING=1
if [[ -n "${MULTI_REVIEW_MUTATION_NESTED:-}" ]]; then
  echo "mutation-check: refusing to run inside another mutation run (nesting is always a bug)" >&2
  exit 2
fi
export MULTI_REVIEW_MUTATION_NESTED=1

# gate_suites -> every suite the gate should run, excluding this script's own suite
gate_suites() {
  local t
  for t in "${ROOT}"/scripts/*.test.sh; do
    [[ "$(basename "$t")" == "$SELF_SUITE" ]] && continue
    printf '%s\n' "$t"
  done
}
# Restore every mutated file no matter how we leave — including INT/TERM. A hard kill (SIGKILL)
# cannot be trapped, so mutations are additionally refused unless the target file is tracked and
# clean, which makes `git checkout -- <file>` a complete recovery.
# ONE RUN AT A TIME. The clean check, backup, mutation and restore are not atomic, so two
# overlapping runs can interleave such that one copies the other's ALREADY-MUTATED file as its
# "original" and then restores that — leaving a security guard deleted in a tree both runs believed
# they had cleaned (codex-rd1-codex-2). A directory is the lock because mkdir is atomic everywhere.
LOCK="${ROOT}/.multi-review-mutation.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "mutation-check: another mutation run holds ${LOCK} — refusing to run concurrently" >&2
  # A SIGKILLed run cannot run its trap, so it leaves BOTH a stale lock and a possibly-mutated file.
  # Telling the user only to delete the lock would have them resume with a guard still absent
  # (codex-rd2-r1), so name the dirty files — that is the part that matters.
  dirty="$(git -C "$ROOT" diff --name-only 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    echo "mutation-check: WARNING — these tracked files are modified and may be a killed run's mutation:" >&2
    printf '  %s\n' $dirty >&2
    echo "mutation-check: restore them (git checkout -- <file>) BEFORE removing the lock." >&2
  else
    echo "mutation-check: the tree is clean; if no run is active, remove that directory." >&2
  fi
  exit 2
fi
BK="$(mktemp -d)" || { rmdir "$LOCK" 2>/dev/null; echo "mutation-check: mktemp failed" >&2; exit 2; }
restore_all() {
  local b f
  for b in "${BK}"/*.bak; do
    [[ -e "$b" ]] || continue
    f="$(cat "${b%.bak}.path")" || continue
    cp "$b" "${ROOT}/${f}"
  done
  rm -rf "$BK"
  rmdir "$LOCK" 2>/dev/null || true
}
# INT/TERM must STOP, not just restore: continuing after Ctrl-C emits verdicts computed against a
# half-restored tree, which look like real results (fable-rd1-r6).
trap restore_all EXIT
trap 'restore_all; exit 130' INT TERM

# gate_catches <expect> [preferred-suite] -> 0 iff some suite went RED and emitted a FAIL line
# containing <expect>. Stops at the first suite that does, because that single suite proves both
# halves of the claim (the gate is red, and the NAMED assertion is the one that failed). A full
# 14-suite sweep per mutation costs over a minute, which would price the check out of local use.
gate_catches() {
  local expect="$1" prefer="${2:-}" t out rc
  local suites=()
  [[ -n "$prefer" && -f "${ROOT}/scripts/${prefer}" ]] && suites+=("${ROOT}/scripts/${prefer}")
  while IFS= read -r t; do
    [[ -n "$prefer" && "$t" == "${ROOT}/scripts/${prefer}" ]] && continue
    suites+=("$t")
  done < <(gate_suites)
  local fails
  for t in "${suites[@]}"; do
    out="$(bash "$t" 2>&1)"; rc=$?
    # A suite that exits 0 cannot credit a guard, even if the word appears in an `ok:` label.
    (( rc == 0 )) && continue
    # REDNESS IS RECORDED FROM THE STATUS, never from the presence of a FAIL: line. A suite that
    # aborts without printing one — a `set -u` unbound variable, a syntax error, any early crash —
    # used to leave the red flag empty, so a SURVIVES-BY-DESIGN entry was certified "survives by
    # design" while the gate was actually red. False assurance inside the tool built to detect false
    # assurance, which is the worst place for it (fable-rd1-r1, reproduced).
    GATE_ANY_RED=1
    fails="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*FAIL:' || true)"
    # Match on a captured string, not through a pipe into `grep -q`: grep -q exits at the first hit
    # and the upstream writer then takes SIGPIPE, which `pipefail` turns into 141 — a genuine catch
    # reported as a survivor. This repo has been bitten by that exact class already (fable-rd1-r7).
    if [[ -n "$fails" ]] && grep -qF "$expect" <<< "$fails"; then
      # The table's suite is AUTHORITATIVE, not an ordering hint. Crediting a match from ANY suite
      # made the check a substring search over every FAIL line in the repo — and `bad` messages
      # interpolate captured output, so an unrelated failure that merely echoes the expect string
      # reads as coverage the guard does not have (fable-rd2-r4). A match from the wrong suite is
      # reported, not credited: the table is what needs correcting.
      if [[ -n "$prefer" && "$(basename "$t")" != "$prefer" ]]; then
        GATE_WRONG_SUITE="$(basename "$t")"
        continue
      fi
      GATE_WITNESS="$(basename "$t")"; return 0
    fi
    if [[ -z "${GATE_RED_OUT:-}" ]]; then
      GATE_RED_OUT="$(head -5 <<< "${fails:-<suite failed with no FAIL: line — crash or abort>}")"
    fi
  done
  return 1
}

# mutate <id> <file-rel> delete|replace <expect-substring> <suite> <old-line> [new-line]
mutate() {
  local id="$1" mode_spec="$3" expect="$4" suite="$5" old="$6" new="${7:-}"
  local rel="$2" mode="${mode_spec%%:*}" nth="${mode_spec#*:}"
  [[ "$nth" == "$mode_spec" ]] && nth=""      # no ":N" suffix -> require exactly one occurrence
  [[ -n "$only" && "$only" != "$id" ]] && return 0
  if (( list )); then printf '%-30s %-38s %-8s %s\n' "$id" "$rel" "$mode" "$suite"; return 0; fi
  ran=$((ran + 1))
  local f="${ROOT}/${rel}"
  if [[ ! -f "$f" ]]; then echo "  ERROR [$id]: no such file: $rel"; fails=$((fails + 1)); return 0; fi
  # Clean-tree precondition. The EXIT trap covers a normal abort or Ctrl-C, but SIGKILL cannot be
  # trapped — requiring the file to be committed-clean first makes `git checkout -- <file>` a
  # complete recovery. (This is not hypothetical: an early version of this script failed to create
  # its backup and left a guard deleted in the working tree; that precondition is what made it a
  # one-command fix instead of a hunt.)
  # TRACKED as well as clean. `git diff --quiet` exits 0 for an UNTRACKED file, so the stated
  # `git checkout --` recovery would not exist for one (fable-rd1-r3, reproduced).
  if ! git -C "$ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    echo "  ERROR [$id]: $rel is not tracked by git — refusing to mutate (no recovery path)"
    fails=$((fails + 1)); return 0
  fi
  if ! git -C "$ROOT" diff --quiet -- "$rel" 2>/dev/null; then
    echo "  ERROR [$id]: $rel has uncommitted changes — refusing to mutate it"; fails=$((fails + 1)); return 0
  fi

  # Exact full-line match count. Not a regex: guard lines are full of awk regexes, backslashes and
  # slashes, and matching them as a pattern is precisely how a mutation silently no-ops and then
  # reports the guard as uncovered.
  local n
  n="$(OLD="$old" awk 'BEGIN{c=0} $0 == ENVIRON["OLD"] {c++} END{print c+0}' "$f")"
  if [[ "$n" == 0 ]]; then
    echo "  ERROR [$id]: the target line is not present in $rel (stale mutation table?)"
    echo "         wanted: $old"; fails=$((fails + 1)); return 0
  fi
  # EXACTLY one, UNLESS the entry names which occurrence. The awk below rewrites every equal line,
  # so with two copies a named test can be failed by the copy the entry did not mean — crediting
  # coverage the intended guard may not have (codex-rd1-codex-1, fable-rd1-r2). Naming the
  # occurrence explicitly (`replace:2`) is not guessing; leaving it implicit is.
  if [[ -z "$nth" && "$n" != 1 ]]; then
    echo "  ERROR [$id]: the target line occurs ${n} times in $rel — name the occurrence, e.g. ${mode}:2"
    fails=$((fails + 1)); return 0
  fi
  if [[ -n "$nth" ]]; then
    if ! [[ "$nth" =~ ^[0-9]+$ ]] || (( nth < 1 || nth > n )); then
      echo "  ERROR [$id]: occurrence '${nth}' out of range (the line occurs ${n} times in $rel)"
      fails=$((fails + 1)); return 0
    fi
  fi

  # Ids carry a '/' for grouping, which is not a filename. Never mutate unless the backup landed.
  local safe="${id//\//_}"
  if ! cp "$f" "${BK}/${safe}.bak"; then
    echo "  ERROR [$id]: could not back up $rel — refusing to mutate"; fails=$((fails + 1)); return 0
  fi
  printf '%s\n' "$rel" > "${BK}/${safe}.path"
  local tmp; tmp="$(mktemp)" || { echo "  ERROR [$id]: mktemp failed"; fails=$((fails+1)); return 0; }
  # ENVIRON, never `awk -v`: -v processes escape sequences, so a line containing `\t` (several
  # guards do) would be matched against a literal TAB and never hit.
  local want="${nth:-1}"
  if [[ "$mode" == delete ]]; then
    OLD="$old" WANT="$want" awk '$0 == ENVIRON["OLD"] { c++; if (c == ENVIRON["WANT"] + 0) next } { print }' "$f" > "$tmp"
  else
    OLD="$old" NEW="$new" WANT="$want" awk \
      '$0 == ENVIRON["OLD"] { c++; if (c == ENVIRON["WANT"] + 0) { print ENVIRON["NEW"]; next } } { print }' "$f" > "$tmp"
  fi
  cp "$tmp" "$f"; rm -f "$tmp"

  # A mutation must not make the file unparseable — that would fail the gate for the wrong reason.
  if ! bash -n "$f" 2>/dev/null; then
    echo "  ERROR [$id]: the mutated file is not valid bash — the gate would fail for the wrong reason"
    cp "${BK}/${safe}.bak" "$f"; fails=$((fails + 1)); return 0
  fi

  GATE_WITNESS=""; GATE_RED_OUT=""; GATE_ANY_RED=0; GATE_WRONG_SUITE=""
  local caught=1
  gate_catches "$expect" "$suite" && caught=0
  cp "${BK}/${safe}.bak" "$f"
  if ! cmp -s "${BK}/${safe}.bak" "$f"; then
    # KEEP the backup: the EXIT trap replays every remaining .bak, so deleting it here would throw
    # away the only automatic retry for the one case that needs it (fable-rd2-r5).
    echo "  ERROR [$id]: restore of $rel did not land — backup kept for the exit-time retry;"
    echo "           if it still differs afterwards, recover with: git checkout -- $rel"
    fails=$((fails + 1)); return 0
  fi
  rm -f "${BK}/${safe}.bak" "${BK}/${safe}.path"

  # Deliberate defense in depth: a line that CANNOT be independently covered because an outer layer
  # already rejects the input reaching it. Recording it as expected-to-survive is the honest entry —
  # dropping it would lose the reason and invite someone to re-add it as a bogus gap, and asserting
  # coverage it cannot have would fail the build forever.
  if [[ "$expect" == SURVIVES-BY-DESIGN ]]; then
    if (( caught == 0 )) || (( GATE_ANY_RED )); then
      echo "  STALE [$id]: expected to survive (redundant behind an outer layer), but the gate went red"
      echo "         either a test now covers it, or the outer layer is gone and this line is now"
      echo "         load-bearing — update the table either way"
      fails=$((fails + 1)); return 0
    fi
    echo "  survives by design [$id] — redundant behind a covered outer layer"; return 0
  fi

  if (( caught == 0 )); then echo "  caught [$id] — ${GATE_WITNESS}"; return 0; fi
  if [[ -n "${GATE_WRONG_SUITE:-}" ]]; then
    echo "  MISCREDITED [$id]: the expectation matched in ${GATE_WRONG_SUITE}, not the table's ${suite}"
    echo "           point the entry at the suite that actually covers it"
    fails=$((fails + 1)); return 0
  fi
  if (( ! GATE_ANY_RED )); then
    echo "  SURVIVED [$id]: gate stayed GREEN with the guard removed — it has NO coverage"
    echo "           $rel: $old"
  else
    echo "  MISCREDITED [$id]: gate went red, but not via the named assertion"
    echo "           expected a FAIL containing: $expect"
    printf '%s\n' "$GATE_RED_OUT" | sed 's/^/           got: /'
  fi
  fails=$((fails + 1))
}

# ------------------------------------------------------------------------------------------------
# The table. Add an entry for every guard a change introduces — that is the repo's standing rule,
# and these entries are the standing proof that "the gate is green" is not the same claim.
#
# `expect` is a substring of the assertion label that MUST fail, so the table records which test
# covers which guard. When a mutation reports MISCREDITED, the honest fix is usually to write the
# missing test, not to relabel the expectation.
# ------------------------------------------------------------------------------------------------
mutations() {

  # #26's false PASS was a leading-zero component read as an octal literal. The `10#` prefixes in
  # semver_gt are DELIBERATELY redundant: `validate` already rejects a leading zero with exit 2, so
  # no such string reaches the comparison, and the script says so at the line itself. Removing them
  # therefore cannot fail the suite, and that is correct — the covered layer is validation
  # (`leading-zero version '1.017.0' rejected`). Recorded rather than omitted so the next person to
  # notice the survival does not file it as a coverage gap, and so that losing the outer layer
  # surfaces here.
  mutate 'version/octal-greater' 'scripts/multi-review-version-check.sh' replace \
    'SURVIVES-BY-DESIGN' 'multi-review-version-check.test.sh' \
    '    (( 10#$av > 10#$bv )) && return 0' \
    '    (( $av > $bv )) && return 0'

  mutate 'version/octal-less' 'scripts/multi-review-version-check.sh' replace \
    'SURVIVES-BY-DESIGN' 'multi-review-version-check.test.sh' \
    '    (( 10#$av < 10#$bv )) && return 1' \
    '    (( $av < $bv )) && return 1'

  # The egress guard's symlinked-FILE rejection. (A symlinked DIRECTORY is issue #37 and is NOT
  # guarded — deliberately absent from this table rather than asserted as caught, since a table
  # entry is a claim that coverage exists.)
  mutate 'egress/symlink-file' 'scripts/multi-review-egress-guard.sh' delete \
    'rejects a symlink inside a dir' 'multi-review-egress-guard.test.sh' \
    '[[ -L "$doc" ]] && die "doc must not be a symlink: $doc" 3'

  # #24: vendor lookup folds case before matching, or a capitalised model id maps to no vendor and
  # verify-vendor escalates unmappable to a hard failure — quarantining a correct reviewer over the
  # capitalisation of its own name.
  mutate 'reviewer/vendor-case-fold' 'scripts/multi-review-reviewer.sh' replace \
    "vendor mapping: 'GPT-5'" 'multi-review-reviewer.test.sh' \
    '  local id; id="$(printf '"'"'%s'"'"' "$1" | LC_ALL=C tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"')"' \
    '  local id; id="$1"'

  # ---- the PR diff window (#40) -------------------------------------------------------------
  # Every guard below was mutation-verified BY HAND while it was written. Tabling them is what makes
  # that permanent: a hand-verified guard with no entry can be silently un-covered by the next edit,
  # which is the exact history that produced this runner.

  # aa474f6's combined-diff resets. A `diff --cc` section has a different column layout, so without
  # a reset its records are counted as added/context lines of the file ABOVE it — every one a
  # forgeable anchor target. One entry per parser: the two must agree or an anchor validates against
  # one view and remaps against the other.
  mutate 'pr/combined-reset-valid-lines' 'scripts/multi-review-pr.sh' delete \
    'combined (diff-valid-lines): --cc records claimed as a.txt lines' 'multi-review-pr.test.sh' \
    '    /^diff --cc |^diff --combined / { inhdr = 0; inhunk = 0; path = ""; next }'

  mutate 'pr/combined-reset-with-text' 'scripts/multi-review-pr.sh' delete \
    'combined (diff-lines-with-text): --cc records claimed as a.txt lines' 'multi-review-pr.test.sh' \
    '    /^diff --cc |^diff --combined / { inhdr = 0; inhunk = 0; p = ""; next }'

  # aa474f6's TAB strips. git appends a TAB to `---`/`+++` when the path contains a space, so an
  # unstripped path matches no anchor and every finding on such a file degrades to the summary.
  mutate 'pr/tab-strip-valid-lines' 'scripts/multi-review-pr.sh' replace \
    'tab-strip (diff-valid-lines): path kept its trailing TAB' 'multi-review-pr.test.sh' \
    '      p = $0; sub(/^\+\+\+ /, "", p); sub(/\t.*$/, "", p)   # git appends a TAB when the path has a space' \
    '      p = $0; sub(/^\+\+\+ /, "", p)'

  mutate 'pr/tab-strip-with-text' 'scripts/multi-review-pr.sh' replace \
    'tab-strip (diff-lines-with-text): path kept its trailing TAB' 'multi-review-pr.test.sh' \
    '      q = $0; sub(/^\+\+\+ /, "", q); sub(/\t.*$/, "", q)   # git appends a TAB when the path has a space' \
    '      q = $0; sub(/^\+\+\+ /, "", q)'

  # The window must match EXACTLY one candidate. Under "first match wins" a decoy heading above the
  # real section takes the window, and `replace-diff` then splices there — deleting the description
  # tail and the previous round's diff.
  mutate 'pr/window-unique-match' 'scripts/multi-review-pr.sh' replace \
    'unique-match: two matching sections were accepted' 'multi-review-pr.test.sh' \
    '  if (( n > 1 )); then' \
    '  if (( 0 )); then'

  # digest() is normative. A non-cryptographic checksum is forgeable, and every soundness claim
  # about the window rests on second-preimage resistance.
  mutate 'pr/window-digest-sha256' 'scripts/multi-review-pr.sh' replace \
    'writer: recorded digest is not the composed body' 'multi-review-pr.test.sh' \
    "_diff_digest() { shasum -a 256 | cut -d' ' -f1; }   # stdin -> sha256; never via \$(...) on the body" \
    "_diff_digest() { cksum | cut -d' ' -f1; }"

  # An unverifiable window must be a distinct status, not an empty result: "no changed lines" and
  # "the parser lost the diff" must not be the same answer.
  # Byte-identical in both parsers, so the occurrence is named rather than guessed.
  mutate 'pr/read-path-status-3-valid-lines' 'scripts/multi-review-pr.sh' replace:1 \
    'no record: read path succeeded with no recorded digest' 'multi-review-pr.test.sh' \
    '  sect="$(_diff_section "$scratch")" || return 3' \
    '  sect="$(_diff_section "$scratch")" || sect=""'

  mutate 'pr/read-path-status-3-with-text' 'scripts/multi-review-pr.sh' replace:2 \
    'record-anchors: returned 0 on an unverifiable window' 'multi-review-pr.test.sh' \
    '  sect="$(_diff_section "$scratch")" || return 3' \
    '  sect="$(_diff_section "$scratch")" || sect=""'

  # The splice runs component-by-component with explicit propagation. A brace group reports only its
  # LAST command's status, so a failing `head` once committed a truncated document with exit 0.
  mutate 'pr/splice-head-propagation' 'scripts/multi-review-pr.sh' replace \
    'splice: a failing head still exited 0' 'multi-review-pr.test.sh' \
    '  ( if (( bstart > 2 )); then head -n "$((bstart - 2))" "$scratch" || exit 1; fi' \
    '  ( if (( bstart > 2 )); then head -n "$((bstart - 2))" "$scratch"; fi'

  # Same swallow in the other writer: an unreadable description produced a document with the PR
  # description missing, and seed then recorded a digest for the truncation.
  mutate 'pr/seed-desc-propagation' 'scripts/multi-review-pr.sh' replace \
    'seed: committed a document despite an unreadable description' 'multi-review-pr.test.sh' \
    '    cat "$descf"                                   || exit 1' \
    '    cat "$descf"'

  # found-but-EMPTY must not look like NOT-FOUND. A blank diff line captured as empty text was read
  # as "not in the diff", nothing was recorded, and the anchor later remapped to a STALE line that
  # `validate-anchor` accepted — posting an agreed finding inline at the wrong place, silently.
  mutate 'pr/blank-anchor-found-status' 'scripts/multi-review-pr.sh' replace \
    'not-found anchor: recorded a bogus record' 'multi-review-pr.test.sh' \
    "     END { exit !found }' <<< \"\$all\"" \
    "     ' <<< \"\$all\""

}

if (( list )); then mutations; exit 0; fi

# Validate --only BEFORE the baseline. Discovering "no such id" after a two-minute full-gate sweep is
# slow and, worse, fragile: any unrelated redness in the environment turns a simple usage error into
# a "gate is already red" refusal, so the caller gets a message about the wrong problem entirely.
if [[ -n "$only" ]]; then
  ids="$( ( list=1; mutations ) | awk '{print $1}' )"
  if ! grep -qxF "$only" <<< "$ids"; then
    echo "mutation-check: no such mutation id: ${only}" >&2
    echo "mutation-check: run --list to see the table; no mutation ran." >&2
    exit 2
  fi
fi

# A GREEN BASELINE IS A PRECONDITION, not a nicety. Every verdict this script reaches is a
# comparison against "the gate passes unmutated": a survivor means the mutation changed nothing, and
# a catch means the mutation broke a named test. On an already-red gate both readings are worthless —
# and worse than worthless, because a red suite makes an expected-to-survive entry look STALE and an
# unrelated failure look like coverage. This is not hypothetical: the first CI run of this script
# reported two spurious STALEs, caused by a suite that failed because the `gemini` CLI was absent.
echo "mutation-check: checking the baseline gate is green before mutating anything"
baseline_red=""
while IFS= read -r t; do
  out="$(bash "$t" 2>&1)" || baseline_red="${baseline_red}
  $(basename "$t"): $(printf '%s\n' "$out" | grep -E '^[[:space:]]*FAIL:' | head -3)"
done < <(gate_suites)
if [[ -n "$baseline_red" ]]; then
  echo "mutation-check: REFUSING to run — the gate is already red, so no mutation verdict is meaningful:${baseline_red}"
  echo "mutation-check: fix the failing suite(s) first, then re-run."
  exit 2
fi
echo "mutation-check: baseline green"

echo "mutation-check: proving each guard's removal is caught by a NAMED assertion"
mutations

echo
if (( ran == 0 )); then
  echo "mutation-check: no mutation ran${only:+ (no such id: $only)}"; exit 2
fi
if (( fails > 0 )); then
  echo "mutation-check: FAILED — ${fails} of ${ran} mutation(s) survived or were miscredited"; exit 1
fi
echo "mutation-check: all ${ran} mutation(s) caught"
