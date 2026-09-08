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
# The invocation directory IS the trust anchor (issue #37), so a fixture must be invoked from
# inside the tree it models. Before this, `g` ran from the repo root while the fixture lived in
# $WORK, so the anchor was never the fixture's tree and could not be exercised at all.
g() { ( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="$DD" bash "$SUT" "$1" ) >/dev/null 2>&1; echo $?; }

# This suite is the ONLY one of the 18 that defines no ok()/bad() helpers — it reports inline from
# check(). Every assertion added below is written in the idiom the other 17 use, so define them
# here. Without this, `ok "…"` is an UNDEFINED COMMAND: it returns 127 and the `||` FAIL branch
# fires on the SUCCESS path of every new assertion, no suite can reach `all passed`, and
# mutation-check refuses every probe on a red baseline.
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

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

# ---- issue #37: a doc DIRECTORY that is a symlink must not arm ----------------------------
# The guard rejects a symlinked doc FILE; nothing looked at the directory, so both sides
# canonicalised to the out-of-tree target and containment succeeded legitimately.
OUT="$(mktemp -d)"; trap 'rm -rf "$WORK" "$OUT"' EXIT
printf '# exfil\n' > "${OUT}/2026-01-01-external.md"
mkdir -p "${WORK}/linked"
ln -s "$OUT" "${WORK}/linked/specs"

lg() { ( cd "$WORK" && MULTI_REVIEW_DOC_DIRS="$1" bash "$SUT" "$2" ) >/dev/null 2>&1; echo $?; }

got="$(lg 'linked/specs' 'linked/specs/2026-01-01-external.md')"
[[ "$got" == "3" ]] && ok "#37: a symlinked doc DIRECTORY is refused" \
  || bad "symlinked doc dir armed a file outside the tree (exit $got) — issue #37"

# Trust must not be a property of SPELLING. Attempt 2 denied the relative spelling and armed the
# absolute one, for the same symlink. Both spellings must reach the same verdict.
rel="$(lg 'linked/specs' 'linked/specs/2026-01-01-external.md')"
abs="$(lg "${WORK}/linked/specs" "${WORK}/linked/specs/2026-01-01-external.md")"
[[ "$rel" == "$abs" ]] && ok "spelling: relative and absolute agree on the same symlink ($rel)" \
  || bad "verdict depends on spelling — relative=$rel absolute=$abs (attempt 2)"

# git must NOT be the trust anchor. Attempt 3 used `git rev-parse --show-toplevel`, which
# GIT_WORK_TREE redefines, so an environment variable could move the boundary.
ext="$(mktemp -d)"; mkdir -p "${ext}/docs/specs"
poisoned="$( cd "$WORK" && GIT_WORK_TREE="$ext" GIT_DIR="${ext}/.git" \
             MULTI_REVIEW_DOC_DIRS='linked/specs' bash "$SUT" 'linked/specs/2026-01-01-external.md' \
             >/dev/null 2>&1; echo $? )"
rm -rf "$ext"
[[ "$poisoned" == "3" ]] && ok "anchor: GIT_WORK_TREE/GIT_DIR cannot move the boundary" \
  || bad "GIT_WORK_TREE moved the trust anchor (exit $poisoned) — attempt 3's vector"

# The fix must not OVER-deny: a dir symlinked WITHIN the tree is legitimate and must still arm.
mkdir -p "${WORK}/real-specs"
printf '# in-tree\n' > "${WORK}/real-specs/2026-01-02-inside.md"
ln -s "${WORK}/real-specs" "${WORK}/aliased-specs"
got="$(lg 'aliased-specs' 'aliased-specs/2026-01-02-inside.md')"
[[ "$got" == "0" ]] && ok "in-tree symlinked dir still arms (no over-denial)" \
  || bad "over-denied an in-tree symlinked dir (exit $got)"

# A dir that resolves out of the tree is SKIPPED, not fatal: one bad dir must not veto the rest.
got="$(lg "linked/specs ${SPECS}" "${SPECS}/a.md")"
[[ "$got" == "0" ]] && ok "skip-not-veto: a good dir still arms alongside a bad one" \
  || bad "one out-of-tree dir vetoed a legitimate doc (exit $got)"

# The anchor is `pwd`, which is NOT ours to constrain: a checkout under a path containing a space
# must still contain its own doc dirs. A space-separated `roots` word-splits into two bogus roots
# and the repo refuses every review of itself (codex-rd1-r1).
SPACED="${WORK}/My Repo"; mkdir -p "${SPACED}/docs/specs"
printf '# spaced\n' > "${SPACED}/docs/specs/2026-01-04-spaced.md"
got="$( cd "$SPACED" && MULTI_REVIEW_DOC_DIRS='docs/specs' bash "$SUT" 'docs/specs/2026-01-04-spaced.md' >/dev/null 2>&1; echo $? )"
[[ "$got" == "0" ]] && ok "anchor: a path containing a space still contains its own doc dirs" \
  || bad "an anchor containing a space cannot contain its own doc dirs (exit $got)"

# An ANCESTOR of the invocation tree is not usable as a configured doc dir, and "/" is the extreme
# case. codex-rd1-r2 asked for `MULTI_REVIEW_DOC_DIRS=/` to contain an absolute doc; implementing
# the rule showed that would be a containment hole rather than a fix — "/" contains every path on
# the machine, so accepting it as a doc dir re-opens exactly what #37 closes. The skip is the rule
# working. "/" remains usable as an explicit ALLOW-ROOT, where the operator has vouched for it.
got="$( cd "$WORK" && MULTI_REVIEW_DOC_DIRS='/' bash "$SUT" "${SPECS}/a.md" >/dev/null 2>&1; echo $? )"
[[ "$got" == "3" ]] && ok "an ancestor doc dir (/) is skipped, not silently trusted" \
  || bad "configured doc dir / was trusted — every path on the machine is armable (exit $got)"

# The doc-dir comparison needs the SAME trailing-slash normalisation as `_inside`, and this is the
# one reachable case: invoked FROM "/" with "/" configured, the dir survives `_inside` (it is the
# anchor), so the second comparison decides. Un-normalised it builds "//*", matches nothing, and a
# legitimate absolute doc is denied. Contrived, but it is what makes the normalisation testable
# rather than a line asserted to matter and never exercised.
got="$( cd / && MULTI_REVIEW_DOC_DIRS='/' bash "$SUT" "${SPECS}/a.md" >/dev/null 2>&1; echo $? )"
[[ "$got" == "0" ]] && ok "anchored at /, a doc dir of / still contains an absolute doc" \
  || bad "doc-dir comparison mishandles / — the second comparison is not normalised (exit $got)"

# ---- MULTI_REVIEW_ALLOW_ROOTS: trust is DECLARED, never inferred -------------------------
# The worktree case (issue #37 item 2): in a linked worktree, docs/superpowers/plans is gitignored
# and therefore absent, and symlinking it to the main checkout is the natural fix. The rule above
# denies it; an operator re-admits it by vouching for the target root.
ar() { ( cd "$WORK" && MULTI_REVIEW_ALLOW_ROOTS="$1" MULTI_REVIEW_DOC_DIRS="$2" bash "$SUT" "$3" ) >/dev/null 2>&1; echo $?; }

# The root is given by a SYMLINKED spelling on purpose. A raw-string allowlist (no
# canonicalisation) would not match the canonical dir, so this assertion is the one that goes red
# when the canonicalisation is removed — which is what makes the mutation entry creditable.
# Spelling it as "$OUT" instead would still pass under the raw mutant on Linux, where mktemp -d is
# already canonical, and would fail a DIFFERENT assertion on macOS, where /var/folders resolves to
# /private/var/folders — SURVIVED on one platform, MISCREDITED on the other.
ln -s "$OUT" "${WORK}/alias-root"
got="$(ar "${WORK}/alias-root" 'linked/specs' 'linked/specs/2026-01-01-external.md')"
[[ "$got" == "0" ]] && ok "allow-roots: a symlinked spelling of a root still admits (canonicalised)" \
  || bad "allowlisted root did not re-admit via a symlinked spelling (exit $got)"

# An entry that does not resolve is noted and dropped — never fatal, or a stale entry in a shell
# profile would break every review in every repo.
got="$(ar "${WORK}/no-such-root" "$SPECS" "${SPECS}/a.md")"
[[ "$got" == "0" ]] && ok "allow-roots: an unresolvable entry is dropped, not fatal" \
  || bad "an unresolvable allow-root was fatal (exit $got)"

# No quotes in either message: the FAIL text is a mutation-entry expect substring, and a
# backslash-escaped quote is not the byte sequence a static table check looks for.
got="$(ar '/' 'linked/specs' 'linked/specs/2026-01-01-external.md')"
[[ "$got" == "0" ]] && ok "allow-roots: root / admits everything (slash normalised)" \
  || bad "allow-root / did not admit an out-of-tree dir (exit $got)"

# Containment stays CANONICAL under an allowlist: vouching for a root admits what resolves inside
# it, not a path that merely looks like it.
sibling="$(mktemp -d)"; printf '# other\n' > "${sibling}/2026-01-03-other.md"
mkdir -p "${WORK}/sib"; ln -s "$sibling" "${WORK}/sib/specs"
got="$(ar "$OUT" 'sib/specs' 'sib/specs/2026-01-03-other.md')"
rm -rf "$sibling"
[[ "$got" == "3" ]] && ok "allow-roots: vouching for one root does not admit a different one" \
  || bad "an allowlisted root admitted an unrelated tree (exit $got)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
