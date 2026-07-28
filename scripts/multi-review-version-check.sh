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
# Usage: multi-review-version-check.sh [base-ref] [head-ref]
#   base-ref  default: origin/main, else main
#   head-ref  the commit to JUDGE. Default is the working tree, which is what a human running the
#             gate means. The pre-push hook passes the sha actually being pushed instead: judging
#             the checkout there is wrong content — an unbumped branch pushed from a bumped
#             checkout produced a FALSE PASS, and an uncommitted manifest edit excused a commit
#             that did not carry it.
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
head="${2:-}"
if [[ -z "$base" ]]; then
  for cand in origin/main main; do
    git rev-parse --verify -q "$cand" >/dev/null 2>&1 && { base="$cand"; break; }
  done
fi
[[ -n "$base" ]] || { note "no base ref (origin/main or main) — cannot compute a delta, skipping"; exit 0; }
git rev-parse --verify -q "$base" >/dev/null 2>&1 || die "base ref not found: $base" 2

[[ -z "$head" ]] || git rev-parse --verify -q "$head" >/dev/null 2>&1 || die "head ref not found: $head" 2

# Tracked-file delta vs the base. --quiet exits 1 when there IS a difference.
# With an explicit head this compares two commits; without one it compares the working tree.
if git diff --quiet "$base" ${head:+"$head"} -- . 2>/dev/null; then
  note "no tracked changes vs ${base}${head:+ (at ${head})} — nothing to bump"
  exit 0
fi

version_at() { # <ref-or-empty> -> version string ("" if unreadable)
  local src
  if [[ -z "$1" ]]; then src="$(cat "$MANIFEST_REL" 2>/dev/null)"
  else src="$(git show "$1:$MANIFEST_REL" 2>/dev/null)"; fi
  # The key must be a WHOLE key, not a suffix of one: an unanchored `.*"version"` would also match
  # `"plugin_version"` and extract the wrong value. Anchoring to line-start instead would have
  # broken compact single-line JSON, so require the preceding character to be a delimiter.
  printf '%s' "$src" \
    | grep -oE '(^|[{,[:space:]])"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' 
}

cur="$(version_at "$head")"
old="$(version_at "$base")"
[[ -n "$cur" ]] || die "cannot read a version from ${MANIFEST_REL}" 2

# Validate the WHOLE string BEFORE comparing. Validating per-component inside the compare loop was
# not equivalent: the loop returns as soon as one component differs, so `1.2` beat `1.1.0` on the
# minor field and never looked at the missing patch, and `1.2.4.0` compared as `1.2.4` with the
# trailing field ignored. A release gate that accepts a version the plugin UI then has to parse is
# worse than no gate.
# LEADING ZEROS ARE REJECTED, per semver, and not merely for spec purity: bash arithmetic treats
# them as octal, which makes them actively dangerous here. `08`/`09` raise "value too great for
# base" so BOTH comparisons read false and a legitimate bump silently fails; and an octal-valid
# string is reinterpreted — base 1.017.0 vs current 1.16.0 compares 16 > 15 and PASSES the gate
# while the plugin UI, comparing decimally, sees a DECREASE and never offers the update. That is a
# false pass in the one check whose whole job is preventing a silent non-release.
semver_valid() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

validate() { # <version> <which>
  semver_valid "$1" && return 0
  # Diagnose by SHAPE, most specific first. The suffix arm used to run before any shape check, so
  # hyphenated garbage ("not-a-version") was reported as "uses a pre-release/build suffix" — the
  # exit code was right but the message sent the operator looking for a suffix that is not there.
  # Only claim a suffix when what precedes it actually is MAJOR.MINOR.PATCH.
  case "$1" in
    *[0-9].[0-9]*[-+]*)
      [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)[-+] ]] \
        && die "$2 version '$1' uses a pre-release/build suffix; this gate compares MAJOR.MINOR.PATCH only" 2 ;;
  esac
  case "$1" in
    0[0-9]*|*.0[0-9]*) die "$2 version '$1' has a leading-zero component; semver forbids it and it would be read as octal" 2 ;;
    *)       die "$2 version '$1' is not MAJOR.MINOR.PATCH" 2 ;;
  esac
}

# Validate the CURRENT version before any early exit. The no-version-at-base path used to return
# success first, so the very first version a manifest carried was never checked at all — and every
# later bump is then compared against an invalid baseline (codex-rd2-r1, gemini-rd2-r2).
validate "$cur" "current"
# No version on the base (the manifest is new here) — any valid current version is an increase.
[[ -n "$old" ]] || { note "no version at ${base} — treating '${cur}' as the first"; exit 0; }
validate "$old" "base ${base}"

# Strictly-greater compare, numeric per component so 1.10.0 > 1.9.0 (a lexical compare gets that
# backwards, and the plugin UI would never offer the update).
semver_gt() { # <a> <b> -> 0 if a > b
  local a="$1" b="$2" i av bv
  for i in 1 2 3; do
    av="$(printf '%s' "$a" | cut -d. -f"$i")"; bv="$(printf '%s' "$b" | cut -d. -f"$i")"
    # 10# explicitly: validation already forbids leading zeros, but this is the line where an
    # octal reinterpretation would silently invert the verdict, so it does not rely on that alone.
    (( 10#$av > 10#$bv )) && return 0
    (( 10#$av < 10#$bv )) && return 1
  done
  return 1                                   # equal is NOT greater
}

if semver_gt "$cur" "$old"; then
  # Name the base COMMIT, not just the ref. This gate compares against a local origin/main it
  # never fetches, so it cannot tell a stale base from a current one — the least it can do is show
  # which commit decided the verdict, rather than hiding the one input the answer depends on.
  note "version ${old} → ${cur} (ok; base ${base} @ $(git rev-parse --short "$base")${head:+, head $(git rev-parse --short "$head")})"
  exit 0
fi

die "this ${head:+push}${head:-branch} changes tracked files but ${MANIFEST_REL} is still ${cur} (base ${base} has ${old}).
    Installed plugins decide whether to update by comparing this version, so shipping without a
    bump leaves every existing install silently on the old code. Raise it before merging." 1
