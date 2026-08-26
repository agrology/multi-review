#!/usr/bin/env bash
# multi-review-symcheck.sh — a mechanically derived worklist of the code blocks a document ships,
# and the coverage check over an agent's verdicts (issue #89).
#
#   rows  <doc>          -> "<row-id>\t<section>\t<lang>:<start>-<end>\t<introduces>"; exit 3 = n/a
#   check <doc> <copy>   -> exit 1 if coverage is incomplete or a verdict is unanchored
#
# WHY THE ROWS ARE DERIVED HERE AND NOT BY THE AGENT. An agent that chooses its own rows cannot be
# checked for coverage: a block nobody opened and a block checked and found clean are the same
# bytes. The worklist is the contract; the agent only returns verdicts.
#
# WHY THIS NEEDS NO CHANGE TO REVIEWER SCOPE. The pass runs in-harness as a subagent of the primary,
# whose harness already has the repository. The sandboxed secondaries are the ones without it, and
# they are asked for nothing new. Reviewer scope discipline (CLAUDE.md:359-361, SKILL.md:89-94) is
# untouched by this module.
set -uo pipefail

die() { echo "multi-review-symcheck: $1" >&2; exit "${2:-1}"; }

SYM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_SH="${MULTI_REVIEW_CORE_SH:-${SYM_DIR}/multi-review-core.sh}"

TMPD="$(mktemp -d)" || die "cannot create a scratch dir" 2
trap 'rm -rf "$TMPD"' EXIT

# Fence-stripping, duplicated from multi-review-core.sh for module isolation (house style here:
# star.sh:47, star.sh:66, crossref.sh:22 all do the same). A fenced example of the verdict grammar
# is documentation, not a verdict — and a fenced `**Files:**` is illustration, not a declaration.
strip_fences() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      tk = 0; fc = ""
      if (match(s, /^`+/))      { tk = RLENGTH; fc = "`" }
      else if (match(s, /^~+/)) { tk = RLENGTH; fc = "~" }
      if (infence) {
        if (fc == fchar && tk >= flen) { rest = substr(s, tk + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence = 0; flen = 0; fchar = "" } }
        next
      }
      if (tk >= 3) { infence = 1; flen = tk; fchar = fc; next }
      print
    }
  ' "$1"
}

# Sections that declare **Files:** specifically. `core.sh sections` qualifies on Files OR
# Interfaces, which is right for a general parser: a section declaring only interfaces is describing
# a contract, not shipping code, so its fenced blocks are illustration. That distinction is this
# pass's rule, so this pass applies it.
_file_sections() { # <doc> -> the core rows whose span contains a **Files:** line
  local doc="$1" idx start end sid title
  # NEVER swallow a core.sh failure. A misset MULTI_REVIEW_CORE_SH, a core.sh without the
  # subcommand, or an awk error would otherwise yield zero sections -> `rows` exits 3 "not
  # applicable" -> `check` returns 0, and the pass silently self-disables while recording a clean
  # not-applicable at the gate. That is exactly the silent-non-run this family of passes exists to
  # close, so it fails loudly instead.
  "$CORE_SH" sections "$doc" > "${TMPD}/secs" 2>"${TMPD}/secs.err" \
    || die "core.sh sections failed for ${doc}: $(head -1 "${TMPD}/secs.err")" 1
  while IFS=$'\t' read -r idx start end sid title; do
    [[ -n "$sid" ]] || continue
    if sed -n "${start},${end}p" "$doc" > "${TMPD}/sec.$$" \
       && strip_fences "${TMPD}/sec.$$" | grep -qE '^\*\*Files:\*\*'; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$start" "$end" "$sid" "$title"
    fi
  done < "${TMPD}/secs"
}

# Fenced blocks with their line ranges and language tag, within one span. Emits
# "<start>\t<end>\t<lang>"; <lang> is "-" for an untagged block. A block that never closes is
# emitted ending at the span end — an unterminated fence is itself worth a verdict, and dropping it
# would silently shrink the worklist.
_blocks_in() { # <doc> <start> <end>
  sed -n "${2},${3}p" "$1" | awk -v base="$2" '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; fc = ""
      if (match(s, /^`+/))      { ticks = RLENGTH; fc = "`" }
      else if (match(s, /^~+/)) { ticks = RLENGTH; fc = "~" }
      if (infence) {
        if (fc == fchar && ticks >= flen) {
          rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { print bstart "\t" (base + NR - 1) "\t" btag; infence = 0; flen = 0; fchar = "" }
        }
        next
      }
      if (ticks >= 3) {
        infence = 1; flen = ticks; fchar = fc
        btag = substr(s, ticks + 1); gsub(/[ \t]/, "", btag)
        if (btag == "") btag = "-"
        bstart = base + NR - 1
      }
    }
    END { if (infence) print bstart "\t" (base + NR - 1) "\t" btag }
  '
}

cmd_rows() { # <doc>
  [[ $# -ge 1 ]] || die "usage: multi-review-symcheck.sh rows <doc>" 2
  local doc="$1"
  [[ -f "$doc" ]] || die "doc not found: $doc" 2

  local secs; secs="$(_file_sections "$doc")"
  : > "${TMPD}/rows"
  local n=0 idx start end sid title bs be tag
  while IFS=$'\t' read -r idx start end sid title; do
    [[ -n "$sid" ]] || continue
    while IFS=$'\t' read -r bs be tag; do
      [[ -n "$bs" ]] || continue
      n=$((n + 1))
      printf 'B%d\t%s\t%s:%s-%s\t\n' "$n" "$sid" "$tag" "$bs" "$be" >> "${TMPD}/rows"
    done < <(_blocks_in "$doc" "$start" "$end")
  done <<< "$secs"

  # ONE block is enough. Unlike the crossref pass — where a single section has no pair to check and
  # no earlier section to consume from — a single ready-to-paste block can carry a wrong signature
  # all by itself, which is exactly #89's first exemplar.
  (( n >= 1 )) || die "not applicable: no ready-to-paste code blocks detected" 3
  cat "${TMPD}/rows"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    rows)  cmd_rows "$@" ;;
    *)     die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
