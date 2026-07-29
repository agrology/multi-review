#!/usr/bin/env bash
# multi-review-egress-guard.test.sh — path/egress validation, multi-dir.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-egress-guard.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

SPECS="${WORK}/docs/specs"; PLANS="${WORK}/docs/plans"
mkdir -p "$SPECS" "$PLANS"
echo "# spec" > "${SPECS}/a.md"
echo "# plan" > "${PLANS}/b.md"
echo "src"     > "${SPECS}/c.ts"
echo "# out"   > "${WORK}/outside.md"
ln -s "${WORK}/outside.md" "${SPECS}/link.md"
SCRATCH="${WORK}/.multi-review/reviews/o/r"
mkdir -p "$SCRATCH"
echo "# pr review" > "${SCRATCH}/pr-1.md"

# Run FROM the tree under test, with RELATIVE doc dirs — the shape the command actually
# produces (it invokes the guard from the repo root with in-repo paths). The previous setup
# configured ABSOLUTE dirs in a temp tree while cwd was this repo, which is the shape that forced
# an "absolute dirs are exempt" carve-out — and that carve-out reopened a directory-symlink
# escape (codex-rd2-r1). Every assertion below is unchanged; only the invocation is now realistic.
DD="docs/specs docs/plans"
g() { ( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="$DD" bash "$SUT" "$1" >/dev/null 2>&1; echo $? ); }

check() { # check <expected-exit> <desc> <path>
  local got; got="$(g "$3")"
  if [[ "$got" == "$1" ]]; then echo "  ok: $2"
  else echo "  FAIL: $2 — expected exit $1, got $got"; fails=$((fails+1)); fi
}

check 0 "accepts a doc under docs/specs"        "docs/specs/a.md"
check 0 "accepts a doc under docs/plans"        "docs/plans/b.md"
check 3 "rejects a doc outside all dirs"        "outside.md"
check 3 "rejects a non-.md file in a dir"       "docs/specs/c.ts"
check 3 "rejects a symlink inside a dir"        "docs/specs/link.md"
check 3 "rejects ../ traversal escaping dirs"   "docs/specs/../../outside.md"
check 3 "rejects a missing file"                "docs/specs/nope.md"

got="$(g '.multi-review/reviews/o/r/pr-1.md')"
[[ "$got" == "0" ]] && echo "  ok: accepts a scratch file under .multi-review/reviews" \
  || { echo "  FAIL: scratch file should arm — got exit $got"; fails=$((fails+1)); }

# --- a configured dir resolving OUTSIDE the root is skipped, not fatal (fable-rd2-r3) ---
# One symlinked doc dir must not veto every review in the repo — PR-mode scratch files use no
# doc dirs at all and must still arm.
# The target must be OUTSIDE the tree under test — a target inside it is not an escape.
OUTS="$(mktemp -d)"; : > "${OUTS}/2026-01-01-x.md"
trap 'rm -rf "$WORK" "$OUTS"' EXIT
ln -s "$OUTS" "${WORK}/docs/linked"
got="$( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="docs/linked docs/specs" bash "$SUT" docs/specs/a.md >/dev/null 2>&1; echo $? )"
[[ "$got" == "0" ]] && echo "  ok: a bad doc dir is skipped, a good one still arms" \
  || { echo "  FAIL: one bad dir vetoed a valid doc — got $got"; fails=$((fails+1)); }
got="$( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="docs/linked" bash "$SUT" .multi-review/reviews/o/r/pr-1.md >/dev/null 2>&1; echo $? )"
[[ "$got" == "0" ]] && echo "  ok: a bad doc dir does not veto PR-mode scratch" \
  || { echo "  FAIL: bad doc dir vetoed PR mode — got $got"; fails=$((fails+1)); }

# --- the symlink escape is closed for BOTH spellings (codex-rd1-r1, codex-rd2-r1) ---
for spell in "docs/linked" "${WORK}/docs/linked"; do
  got="$( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="$spell" bash "$SUT" docs/linked/2026-01-01-x.md >/dev/null 2>&1; echo $? )"
  [[ "$got" == "3" ]] && echo "  ok: symlinked doc dir denied (spelling: $spell)" \
    || { echo "  FAIL: SYMLINK ESCAPE via '$spell' — got $got"; fails=$((fails+1)); }
done

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
