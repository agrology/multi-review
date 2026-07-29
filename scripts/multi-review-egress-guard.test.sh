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

DD="${SPECS} ${PLANS}"
g() { MULTI_REVIEW_DOC_DIRS="$DD" bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }

check() { # check <expected-exit> <desc> <path>
  local got; got="$(g "$3")"
  if [[ "$got" == "$1" ]]; then echo "  ok: $2"
  else echo "  FAIL: $2 — expected exit $1, got $got"; fails=$((fails+1)); fi
}

check 0 "accepts a doc under docs/specs"        "${SPECS}/a.md"
check 0 "accepts a doc under docs/plans"        "${PLANS}/b.md"
check 3 "rejects a doc outside all dirs"        "${WORK}/outside.md"
check 3 "rejects a non-.md file in a dir"       "${SPECS}/c.ts"
check 3 "rejects a symlink inside a dir"        "${SPECS}/link.md"
check 3 "rejects ../ traversal escaping dirs"   "${SPECS}/../../outside.md"
check 3 "rejects a missing file"                "${SPECS}/nope.md"

gw() { ( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="$DD" bash "$SUT" "$1" >/dev/null 2>&1; echo $? ); }
got="$(gw '.multi-review/reviews/o/r/pr-1.md')"
[[ "$got" == "0" ]] && echo "  ok: accepts a scratch file under .multi-review/reviews" \
  || { echo "  FAIL: scratch file should arm — got exit $got"; fails=$((fails+1)); }

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
