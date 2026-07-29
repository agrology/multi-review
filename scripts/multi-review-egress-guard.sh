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

# --- canonical containment in ANY configured dir ---
contained=0
# .multi-review/reviews is always an allowed arming root (PR-mode scratch files live there).
root_real="$(pwd -P)" || die "cannot resolve the invocation root" 2
for d in $doc_dirs .multi-review/reviews; do
  dir_real="$(cd "$d" 2>/dev/null && pwd -P)" || continue
  # A RELATIVE configured dir must be a real subdirectory, not reached through a symlink.
  # Containment canonicalises BOTH sides, so a symlinked `docs/superpowers/specs` matches its own
  # out-of-tree target and an external file arms cleanly — rejecting the doc symlink never
  # covered this, because the escape is via the DIRECTORY (codex-rd1-r1, CLAUDE.md §3).
  # Pre-existing (a symlinked docs/specs escapes identically on main), but widening the default
  # made it reachable with no configuration at all, so it is closed here rather than flagged.
  # An ABSOLUTE dir is an explicit operator choice and is left alone.
  if [[ "$d" != /* ]]; then
    lexical="${root_real}/${d#./}"; lexical="${lexical%/}"
    [[ "$dir_real" == "$lexical" ]] || die "configured doc dir '$d' resolves through a symlink to $dir_real — refusing to arm" 3
  fi
  case "${doc_dir_real}/" in
    "${dir_real}/"*) contained=1; break ;;
  esac
done
(( contained == 1 )) || die "doc is outside MULTI_REVIEW_DOC_DIRS ($doc_dirs): resolves to $doc_dir_real" 3

echo "$doc"
exit 0
