#!/usr/bin/env bash
# multi-review-version-check.sh — refuse to ship a change to main without a version bump.
#
# The plugin is distributed through Claude Code's plugin UI, which decides whether to offer an
# update by comparing `.claude-plugin/plugin.json`'s `version`. A change that lands on main
# without bumping it is invisible to every installed copy: users keep running the old code and
# nothing tells them otherwise. The gate is therefore not cosmetic — it is the only signal
# downstream installs get.
#
# Contract: if this branch changes any TRACKED file relative to the base branch, the version must
# be strictly greater than the base's (semver, numeric per-component).
#
# Usage: multi-review-version-check.sh [base-ref]      (default: origin/main, else main)
# Exit: 0 ok / nothing to check, 1 missing-or-non-increasing bump, 2 usage or malformed version.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SELF}/.." && pwd)"
MANIFEST_REL=".claude-plugin/plugin.json"

die() { echo "version-check: $1" >&2; exit "${2:-1}"; }
note() { echo "version-check: $1"; }

cd "$ROOT" 2>/dev/null || die "cannot enter repo root: $ROOT" 2
git rev-parse --git-dir >/dev/null 2>&1 || { note "not a git repo — nothing to enforce"; exit 0; }

# Base ref: explicit arg, else origin/main, else a local main. A clone with neither (a shallow CI
# checkout, a fresh init) cannot compute a delta — say so and pass, rather than failing a repo
# that simply has nothing to compare against. Silence here would read as approval.
base="${1:-}"
if [[ -z "$base" ]]; then
  for cand in origin/main main; do
    git rev-parse --verify -q "$cand" >/dev/null 2>&1 && { base="$cand"; break; }
  done
fi
[[ -n "$base" ]] || { note "no base ref (origin/main or main) — cannot compute a delta, skipping"; exit 0; }
git rev-parse --verify -q "$base" >/dev/null 2>&1 || die "base ref not found: $base" 2

# Tracked-file delta vs the base. --quiet exits 1 when there IS a difference.
if git diff --quiet "$base" -- . 2>/dev/null; then
  note "no tracked changes vs ${base} — nothing to bump"
  exit 0
fi

version_at() { # <ref-or-empty> -> version string ("" if unreadable)
  local src
  if [[ -z "$1" ]]; then src="$(cat "$MANIFEST_REL" 2>/dev/null)"
  else src="$(git show "$1:$MANIFEST_REL" 2>/dev/null)"; fi
  printf '%s' "$src" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

cur="$(version_at "")"
old="$(version_at "$base")"
[[ -n "$cur" ]] || die "cannot read a version from ${MANIFEST_REL}" 2
# No version on the base (the manifest is new here) — any current version is an increase.
[[ -n "$old" ]] || { note "no version at ${base} — treating '${cur}' as the first"; exit 0; }

# Validate the WHOLE string BEFORE comparing. Validating per-component inside the compare loop was
# not equivalent: the loop returns as soon as one component differs, so `1.2` beat `1.1.0` on the
# minor field and never looked at the missing patch, and `1.2.4.0` compared as `1.2.4` with the
# trailing field ignored. A release gate that accepts a version the plugin UI then has to parse is
# worse than no gate.
semver_valid() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

for v in "$old:base ${base}" "$cur:current"; do
  ver="${v%%:*}"; which="${v#*:}"
  semver_valid "$ver" && continue
  case "$ver" in
    *-*|*+*) die "${which} version '${ver}' uses a pre-release/build suffix; this gate compares MAJOR.MINOR.PATCH only" 2 ;;
    *)       die "${which} version '${ver}' is not MAJOR.MINOR.PATCH" 2 ;;
  esac
done

# Strictly-greater compare, numeric per component so 1.10.0 > 1.9.0 (a lexical compare gets that
# backwards, and the plugin UI would never offer the update).
semver_gt() { # <a> <b> -> 0 if a > b
  local a="$1" b="$2" i av bv
  for i in 1 2 3; do
    av="$(printf '%s' "$a" | cut -d. -f"$i")"; bv="$(printf '%s' "$b" | cut -d. -f"$i")"
    (( av > bv )) && return 0
    (( av < bv )) && return 1
  done
  return 1                                   # equal is NOT greater
}

if semver_gt "$cur" "$old"; then
  # Name the base COMMIT, not just the ref. This gate compares against a local origin/main it
  # never fetches, so it cannot tell a stale base from a current one — the least it can do is show
  # which commit decided the verdict, rather than hiding the one input the answer depends on.
  note "version ${old} → ${cur} (ok; base ${base} @ $(git rev-parse --short "$base"))"
  exit 0
fi

die "this branch changes tracked files but ${MANIFEST_REL} is still ${cur} (base ${base} has ${old}).
    Installed plugins decide whether to update by comparing this version, so shipping without a
    bump leaves every existing install silently on the old code. Raise it before merging." 1
