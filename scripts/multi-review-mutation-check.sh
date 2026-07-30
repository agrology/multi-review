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
    --list) list=1; shift ;;
    --only) only="${2:?--only needs an id}"; shift 2 ;;
    *) echo "mutation-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fails=0; ran=0
# Restore every mutated file no matter how we leave — including INT/TERM. A hard kill (SIGKILL)
# cannot be trapped, so mutations are additionally refused unless the target file is tracked and
# clean, which makes `git checkout -- <file>` a complete recovery.
BK="$(mktemp -d)" || { echo "mutation-check: mktemp failed" >&2; exit 2; }
restore_all() {
  local b f
  for b in "${BK}"/*.bak; do
    [[ -e "$b" ]] || continue
    f="$(cat "${b%.bak}.path")" || continue
    cp "$b" "${ROOT}/${f}"
  done
  rm -rf "$BK"
}
trap restore_all EXIT INT TERM

# gate_catches <expect> [preferred-suite] -> 0 iff some suite went RED and emitted a FAIL line
# containing <expect>. Stops at the first suite that does, because that single suite proves both
# halves of the claim (the gate is red, and the NAMED assertion is the one that failed). A full
# 14-suite sweep per mutation costs over a minute, which would price the check out of local use.
gate_catches() {
  local expect="$1" prefer="${2:-}" t out rc
  local suites=()
  [[ -n "$prefer" && -f "${ROOT}/scripts/${prefer}" ]] && suites+=("${ROOT}/scripts/${prefer}")
  for t in "${ROOT}"/scripts/*.test.sh; do
    [[ -n "$prefer" && "$t" == "${ROOT}/scripts/${prefer}" ]] && continue
    suites+=("$t")
  done
  for t in "${suites[@]}"; do
    out="$(bash "$t" 2>&1)"; rc=$?
    # A suite that exits 0 cannot credit a guard, even if the word appears in an `ok:` label.
    (( rc == 0 )) && continue
    if printf '%s\n' "$out" | grep -E '^[[:space:]]*FAIL:' | grep -qF "$expect"; then
      GATE_WITNESS="$(basename "$t")"; return 0
    fi
    # Red for some other reason: remember it, so a MISCREDITED report can show what did fail.
    [[ -z "${GATE_RED_OUT:-}" ]] && GATE_RED_OUT="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*FAIL:' | head -5)"
  done
  return 1
}

# mutate <id> <file-rel> delete|replace <expect-substring> <suite> <old-line> [new-line]
mutate() {
  local id="$1" rel="$2" mode="$3" expect="$4" suite="$5" old="$6" new="${7:-}"
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

  # Ids carry a '/' for grouping, which is not a filename. Never mutate unless the backup landed.
  local safe="${id//\//_}"
  if ! cp "$f" "${BK}/${safe}.bak"; then
    echo "  ERROR [$id]: could not back up $rel — refusing to mutate"; fails=$((fails + 1)); return 0
  fi
  printf '%s\n' "$rel" > "${BK}/${safe}.path"
  local tmp; tmp="$(mktemp)" || { echo "  ERROR [$id]: mktemp failed"; fails=$((fails+1)); return 0; }
  # ENVIRON, never `awk -v`: -v processes escape sequences, so a line containing `\t` (several
  # guards do) would be matched against a literal TAB and never hit.
  if [[ "$mode" == delete ]]; then
    OLD="$old" awk '$0 == ENVIRON["OLD"] { next } { print }' "$f" > "$tmp"
  else
    OLD="$old" NEW="$new" awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$f" > "$tmp"
  fi
  cp "$tmp" "$f"; rm -f "$tmp"

  # A mutation must not make the file unparseable — that would fail the gate for the wrong reason.
  if ! bash -n "$f" 2>/dev/null; then
    echo "  ERROR [$id]: the mutated file is not valid bash — the gate would fail for the wrong reason"
    cp "${BK}/${safe}.bak" "$f"; fails=$((fails + 1)); return 0
  fi

  GATE_WITNESS=""; GATE_RED_OUT=""
  local caught=1
  gate_catches "$expect" "$suite" && caught=0
  cp "${BK}/${safe}.bak" "$f"; rm -f "${BK}/${safe}.bak" "${BK}/${safe}.path"

  # Deliberate defense in depth: a line that CANNOT be independently covered because an outer layer
  # already rejects the input reaching it. Recording it as expected-to-survive is the honest entry —
  # dropping it would lose the reason and invite someone to re-add it as a bogus gap, and asserting
  # coverage it cannot have would fail the build forever.
  if [[ "$expect" == SURVIVES-BY-DESIGN ]]; then
    if (( caught == 0 )) || [[ -n "$GATE_RED_OUT" ]]; then
      echo "  STALE [$id]: expected to survive (redundant behind an outer layer), but the gate went red"
      echo "         either a test now covers it, or the outer layer is gone and this line is now"
      echo "         load-bearing — update the table either way"
      fails=$((fails + 1)); return 0
    fi
    echo "  survives by design [$id] — redundant behind a covered outer layer"; return 0
  fi

  if (( caught == 0 )); then echo "  caught [$id] — ${GATE_WITNESS}"; return 0; fi
  if [[ -z "$GATE_RED_OUT" ]]; then
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
}

if (( list )); then mutations; exit 0; fi

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
