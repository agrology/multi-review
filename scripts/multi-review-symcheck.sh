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
# The ONE call site for `core.sh sections`, so its failure has ONE guard.
#
# NEVER swallow a core.sh failure. A misset MULTI_REVIEW_CORE_SH, a core.sh without the subcommand,
# or an awk error would otherwise yield zero sections -> `rows` exits 3 "not applicable" ->
# `check` returns 0, and the pass silently self-disables while recording a clean not-applicable at
# the gate. That is exactly the silent-non-run this family of passes exists to close.
#
# Both consumers route through here rather than each carrying its own copy of the guard: two copies
# MASK EACH OTHER under mutation — neutering either leaves the other to fail loudly, so neither can
# be shown load-bearing and both entries read as coverage the behaviour does not have. Observed
# directly: `symcheck/core-failure-is-loud` SURVIVED the sweep for exactly that reason.
_core_sections() { # <doc> <outfile>
  "$CORE_SH" sections "$1" > "$2" 2>"${TMPD}/secs.err" \
    || die "core.sh sections failed for ${1}: $(head -1 "${TMPD}/secs.err")" 1
}

_file_sections() { # <doc> -> the core rows whose span contains a **Files:** line
  local doc="$1" idx start end sid title
  _core_sections "$doc" "${TMPD}/secs"
  while IFS=$'\t' read -r idx start end sid title; do
    [[ -n "$sid" ]] || continue
    if sed -n "${start},${end}p" "$doc" > "${TMPD}/sec.$$" \
       && grep -qE '^\*\*Files:\*\*' <<<"$(strip_fences "${TMPD}/sec.$$")"; then
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

# What the DOCUMENT introduces: every `- Create:` path and every `- Produces:` entry, document-wide.
#
# Document-wide, not section-local, and deliberately so: a later section legitimately calls what an
# earlier one creates, and scoping this per section would make every such call read as a defect.
#
# `- Modify:` is EXCLUDED. A modified file already exists, so the symbols its block touches are
# precisely the ones worth checking — treating it as introduced would suppress the whole point.
_introduces() { # <doc> -> one entry per line
  local doc="$1" idx start end sid title
  # EVERY section, not just the ones that declare **Files:**. A section that declares only
  # `**Interfaces:**` still PRODUCES things later sections legitimately call; scoping this to
  # `_file_sections` would drop those, and every valid call to a contract-only section's interface
  # would then read as a missing repo symbol — the false-positive flood this set exists to prevent.
  # Read the sections into a FILE first. A `|| die` inside a process substitution exits only that
  # subshell, so the failure would be printed and then discarded — the loop would simply see EOF and
  # the caller would carry on with an empty set.
  _core_sections "$doc" "${TMPD}/isecs"
  { while IFS=$'\t' read -r idx start end sid title; do
      [[ -n "$sid" ]] || continue
      sed -n "${start},${end}p" "$doc" > "${TMPD}/int.$$"
      strip_fences "${TMPD}/int.$$" | awk '
        /^\*\*(Files|Interfaces):\*\*/ { inblk = 1; next }
        inblk && /^[[:space:]]*$/      { inblk = 0 }
        # Take the BACKTICKED TOKENS, not the rest of the line. A real `- Produces:` entry is a
        # sentence — this plan\x27s own Task 1 entry runs to several clauses with embedded commas — so
        # capturing the remainder makes the introduces column undelimitable prose instead of a symbol
        # list. Every entry worth checking names its symbol in backticks; the prose around it is
        # commentary. A line with no backticked token contributes nothing.
        inblk && /^- (Create|Produces):/ {
          line = $0
          while (match(line, /`[^`]+`/)) {
            print substr(line, RSTART + 1, RLENGTH - 2)
            line = substr(line, RSTART + RLENGTH)
          }
        }
      '
    done < "${TMPD}/isecs"
    rm -f "${TMPD}/int.$$"
  } | sed 's/^[ \t]*//; s/[ \t]*$//' | sed '/^$/d' | LC_ALL=C sort -u  # sed, not grep -v: an empty set is not a failure
}

cmd_rows() { # <doc>
  [[ $# -ge 1 ]] || die "usage: multi-review-symcheck.sh rows <doc>" 2
  local doc="$1"
  [[ -f "$doc" ]] || die "doc not found: $doc" 2

  # `|| exit $?` on BOTH: `die` inside a command substitution kills only the subshell, so without
  # this the loud failure above is printed and then thrown away, and the pass falls through to
  # "not applicable" — recording a clean non-run at the gate, which is the exact failure this
  # family of passes exists to close.
  local secs; secs="$(_file_sections "$doc")" || exit $?
  local intro; intro="$(_introduces "$doc" | tr '\n' ',' | sed 's/,$//')" || exit $?
  : > "${TMPD}/rows"
  local n=0 idx start end sid title bs be tag
  while IFS=$'\t' read -r idx start end sid title; do
    [[ -n "$sid" ]] || continue
    while IFS=$'\t' read -r bs be tag; do
      [[ -n "$bs" ]] || continue
      n=$((n + 1))
      printf 'B%d\t%s\t%s:%s-%s\t%s\n' "$n" "$sid" "$tag" "$bs" "$be" "$intro" >> "${TMPD}/rows"
    done < <(_blocks_in "$doc" "$start" "$end")
  done <<< "$secs"

  # ONE block is enough. Unlike the crossref pass — where a single section has no pair to check and
  # no earlier section to consume from — a single ready-to-paste block can carry a wrong signature
  # all by itself, which is exactly #89's first exemplar.
  (( n >= 1 )) || die "not applicable: no ready-to-paste code blocks detected" 3
  cat "${TMPD}/rows"
}

# Verdict lines live under the LAST '## Review' heading and outside fences — the same channel
# discipline the finding grammar uses. A PR description can legally contain a '> [symcheck:...]'
# blockquote, and a fenced example of the grammar is documentation, not a verdict.
_review_verdicts() { # <copy> -> the fence-stripped review section
  # The heading scan is itself fence-aware. A copy that QUOTES the review grammar in a fence — which
  # any document about this protocol does — would otherwise move `last` inside that fence and hide
  # every real verdict above it, reporting a complete turn as incomplete.
  strip_fences "$1" > "${TMPD}/rvsrc.$$"
  awk '{ a[NR] = $0 } /^## Review[[:space:]]*$/ { last = NR }
       END { if (last) for (i = last + 1; i <= NR; i++) print a[i] }' "${TMPD}/rvsrc.$$"
  rm -f "${TMPD}/rvsrc.$$"
}

cmd_check() { # <doc> <copy>
  [[ $# -ge 2 ]] || die "usage: multi-review-symcheck.sh check <doc> <copy>" 2
  local doc="$1" copy="$2"
  [[ -f "$doc"  ]] || die "doc not found: $doc" 2
  [[ -f "$copy" ]] || die "copy not found: $copy" 2

  local rows rc=0
  rows="$(cmd_rows "$doc")" || {
    rc=$?
    # Not applicable is not a failure: there was nothing to cover.
    (( rc == 3 )) && return 0
    # EXIT 2, not 1. Exit 1 is a verdict about the REVIEWER's turn, and the command file books it
    # as `0/M rows verdicted` at the gate — so a fault on the CALLER's side (a misset
    # MULTI_REVIEW_CORE_SH, a core.sh broken between dispatch and check) would be recorded durably
    # as an incomplete turn against a copy that may be perfectly complete, with the real fault
    # surviving only in scrollback. Exit 2 is the code the command file already routes to "fix the
    # invocation; nothing is recorded" (fable-rd1-r3, PR #97).
    die "cannot derive rows for $doc" 2
  }
  awk -F'\t' '{ print $1 }' <<< "$rows" | LC_ALL=C sort -u > "${TMPD}/want"

  local rv; rv="$(_review_verdicts "$copy")"

  grep -qE '^>[[:space:]]*\[symcheck\][[:space:]]*—[[:space:]]*via[[:space:]]+[^[:space:]]' <<<"$rv" \
    || die "symcheck table carries no '> [symcheck] — via <model>' disclosure" 1

  printf '%s\n' "$rv" \
    | sed -n 's/^>[[:space:]]*\[symcheck:\([A-Za-z][0-9A-Za-z]*\)|.*/\1/p' \
    | LC_ALL=C sort -u > "${TMPD}/got"

  # ONE verdict per row. The join sorts unique, so two contradictory verdicts for the same row
  # (`B1|ok` and `B1|defect:r1`) would otherwise both be accepted and the turn read as complete.
  local dupes
  dupes="$(printf '%s\n' "$rv" \
    | sed -n 's/^>[[:space:]]*\[symcheck:\([A-Za-z][0-9A-Za-z]*\)|.*/\1/p' \
    | LC_ALL=C sort | uniq -d | tr '\n' ' ')"
  [[ -z "${dupes// /}" ]] || die "more than one verdict for row(s): ${dupes% }" 1

  local missing extra
  missing="$(LC_ALL=C comm -23 "${TMPD}/want" "${TMPD}/got" | tr '\n' ' ')"
  [[ -z "${missing// /}" ]] \
    || die "incomplete turn: no verdict for row(s): ${missing% }" 1
  extra="$(LC_ALL=C comm -13 "${TMPD}/want" "${TMPD}/got" | tr '\n' ' ')"
  [[ -z "${extra// /}" ]] \
    || die "verdict names row(s) that were never emitted: ${extra% }" 1

  # Clause 4: an `ok` must name what it checked. An `ok` naming nothing is byte-identical to a row
  # nobody opened — the hazard the coverage assertion exists to close, one level down. `none` is the
  # verdict for a block that genuinely references nothing, so this stays strict for `ok`.
  local bare
  bare="$(printf '%s\n' "$rv" \
    | sed -n 's/^>[[:space:]]*\[symcheck:\([A-Za-z][0-9A-Za-z]*\)|ok\][[:space:]]*$/\1/p' \
    | tr '\n' ' ')"
  [[ -z "${bare// /}" ]] \
    || die "ok verdict names no symbol for row(s): ${bare% }" 1

  # CLAUSE 5: the verdict token must be one this pass defines. The row-id extraction above accepts
  # any `|<token>]`, so without this a typo'd or invented verdict — `[symcheck:B1|wat]` — counts as
  # coverage and reaches the gate as a complete turn. Coverage that accepts anything is not coverage.
  local badtok
  badtok="$(printf '%s\n' "$rv" \
    | sed -n 's/^>[[:space:]]*\[symcheck:\([A-Za-z][0-9A-Za-z]*\)|\([^]]*\)\].*/\1=\2/p' \
    | awk -F= '$2 != "ok" && $2 != "new" && $2 != "none" && $2 !~ /^defect:/ { print $1 "(" $2 ")" }' \
    | tr '\n' ' ')"
  [[ -z "${badtok// /}" ]] \
    || die "unknown verdict token on row(s): ${badtok% } (expected ok, new, none or defect:<id>)" 1

  # Every defect must name a finding present in the SAME copy. A defect recorded only in the table
  # is a finding that bypasses adjudication and never reaches the human gate's accounting.
  #
  # LITERAL matching, never a built regex: a finding id is agent-authored text, and interpolating it
  # into a regex let `defect:r.` be satisfied by any finding at all. star.sh:586 records this repo
  # being bitten by exactly that.
  # An EMPTY id (`defect:]`) must FAIL rather than be skipped: skipping it lets a defect verdict
  # satisfy coverage while anchoring to nothing, the bypass this clause exists to prevent.
  grep -qE '^>[[:space:]]*\[symcheck:[^|]*\|defect:\]' <<<"$rv" \
    && die "defect verdict names an empty finding id" 1

  local fid
  while IFS= read -r fid; do
    [[ -n "$fid" ]] || continue
    printf '%s\n' "$rv" \
      | sed 's/^>[[:space:]]*/> /' \
      | awk -v want="> [finding:${fid}|" 'index($0, want) == 1 { found = 1 } END { exit !found }' \
      || die "symcheck defect names finding '${fid}', which is not in this copy" 1
  done < <(printf '%s\n' "$rv" | sed -n 's/^>[[:space:]]*\[symcheck:[^|]*|defect:\([^]]*\)\].*/\1/p')
  return 0
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    rows)  cmd_rows "$@" ;;
    check) cmd_check "$@" ;;
    *)     die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
