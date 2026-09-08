#!/usr/bin/env bash
# multi-review-egress-guard.sh — refuse to "arm" on any path that is not a real .md
# design doc canonically contained in one of MULTI_REVIEW_DOC_DIRS. Exit: 0 ok, 2 config,
# 3 egress-denied. (Mechanical author-side guarantee; the reviewer contract is separate.)
set -uo pipefail

die() { echo "multi-review-egress-guard: $1" >&2; exit "$2"; }

doc="${1:-}"
[[ -n "$doc" ]] || die "usage: multi-review-egress-guard.sh <doc-path>" 2

# Space-separated by design (word-split below) — individual dirs cannot contain spaces.
# Default MUST stay in sync with DOC_DIRS_DEFAULT in multi-review-core.sh and the loop in
# multi-review-reviewer.sh. Duplicated for module isolation, as elsewhere in this repo.
doc_dirs="${MULTI_REVIEW_DOC_DIRS:-docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans}"

# --- the doc must be a real .md file, not a symlink ---
[[ -e "$doc" ]] || die "doc not found: $doc" 3
[[ -L "$doc" ]] && die "doc must not be a symlink: $doc" 3
[[ -f "$doc" ]] || die "doc is not a regular file: $doc" 3
[[ "$doc" == *.md ]] || die "doc must be a .md design doc: $doc" 3

doc_dir_real="$(cd "$(dirname "$doc")" 2>/dev/null && pwd -P)" || die "cannot resolve doc path: $doc" 3

# --- trust anchor: where a path RESOLVES, never how it was spelled (issue #37) ---
# The anchor is the invocation directory, canonical. git is deliberately NOT consulted: an earlier
# attempt anchored on `git rev-parse --show-toplevel`, which GIT_WORK_TREE and GIT_DIR redefine, so
# an environment variable could move the containment boundary (verified exit 0). Nothing can
# redefine `pwd -P`.
#
# An ARRAY, not a space-separated string. The no-spaces convention covers values the OPERATOR
# configures; it cannot cover `pwd`. A checkout under "/Users/me/My Repo" would word-split into
# two bogus roots and fail to contain its own doc dirs — the repo would refuse every review of
# itself. `roots` always holds at least the anchor, so "${roots[@]}" is safe under `set -u` on
# bash 3.2, where expanding an EMPTY array is a fatal unbound-variable error.
anchor="$(pwd -P)" || die "cannot resolve the invocation directory" 2
roots=("$anchor")

# _inside <path> : true when <path> resolves inside any root.
# `${root%/}` normalises the trailing slash so a root of "/" yields the prefix "/" and matches
# everything — the correct answer at "/", where everything IS inside the tree. Without it the
# pattern is "//*", which matches nothing, and no dir could ever arm.
_inside() {
  local p="$1" root
  for root in "${roots[@]}"; do
    case "${p}/" in "${root%/}/"*) return 0 ;; esac
  done
  return 1
}

# --- canonical containment in ANY USABLE configured dir ---
# A dir that resolves outside every root is SKIPPED with a note, never fatal: one bad dir must not
# veto every review in the repo, including PR-mode reviews that use no doc dirs at all.
# The doc needs no separate check — it is contained in a dir that is itself inside a root, so its
# own containment follows transitively.
contained=0
# .multi-review/reviews is always an allowed arming root (PR-mode scratch files live there).
for d in $doc_dirs .multi-review/reviews; do
  dir_real="$(cd "$d" 2>/dev/null && pwd -P)" || continue
  if ! _inside "$dir_real"; then
    echo "multi-review-egress-guard: note — doc dir '$d' resolves outside the invocation tree ($dir_real); skipping it" >&2
    continue
  fi
  # `${dir_real%/}` for the SAME reason as in `_inside`, and it is a separate comparison that must
  # normalise identically or the two disagree at "/": a configured doc dir of "/" would otherwise
  # build the pattern "//*", match nothing, and contain no doc anywhere.
  case "${doc_dir_real}/" in
    "${dir_real%/}/"*) contained=1; break ;;
  esac
done
(( contained == 1 )) || die "doc is outside MULTI_REVIEW_DOC_DIRS ($doc_dirs): resolves to $doc_dir_real" 3

echo "$doc"
exit 0
