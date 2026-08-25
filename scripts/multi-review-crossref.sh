#!/usr/bin/env bash
# multi-review-crossref.sh — mechanically derived cross-reference rows for a multi-section
# document, and the coverage check over a reviewer's verdicts (issue #90).
#
#   rows  <doc>          -> "<row-id>\t<kind>\t<subject>\t<detail>" per row; exit 3 = not applicable
#   check <doc> <copy>   -> exit 1 if coverage is incomplete or a verdict is unanchored
#
# WHY THE ROWS ARE DERIVED HERE AND NOT BY THE REVIEWER. A reviewer that chooses its own rows
# cannot be checked for coverage: a pair nobody looked at and a pair checked and found clean are
# the same bytes. That is the hazard the `[no-findings]` signal closes for a whole turn, and it
# would reopen per-row. The worklist is the contract; the reviewer only returns verdicts.
set -uo pipefail

die() { echo "multi-review-crossref: $1" >&2; exit "${2:-1}"; }

# Fence-stripping, duplicated from star.sh for module isolation (same rationale as
# unterminated_fence_line there). A path inside a fenced code block is illustrative, not a file the
# section touches, so counting it would manufacture pairs out of sample output.
strip_fences() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence=0; fence_len=0; next } }
        next
      }
      if (ticks >= 3) { infence = 1; fence_len = ticks; next }
      print
    }
  ' "$1"
}

# A SECTION is a heading whose text starts with a section keyword and an ordinal, AND which
# declares a Files/Interfaces block before the next such heading. BOTH halves are required: the
# ordinal alone sweeps in prose headings ("Task lists we rejected"), and the block alone sweeps in
# a document preamble that happens to mention files.
_sections() { # <doc> -> "idx\tstart\tend\tshort-id\ttitle"
  awk '
    # FENCE STATE FIRST, and headings only outside a fence. A shell comment such as
    # "# --- setup ---" inside a fenced block is not a heading; treating it as one truncates the
    # enclosing section and silently drops every pair its remaining body would produce. Reproduced
    # against a real plan document: it cut a 416-line task down to 33 lines.
    { lines[NR] = $0
      fs = $0; sub(/^ ? ? ?/, "", fs); tk = 0; if (match(fs, /^`+/)) tk = RLENGTH
      if (infence) {
        if (tk >= flen) { rest = substr(fs, tk + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence = 0; flen = 0 } }
        next
      } else if (tk >= 3) { infence = 1; flen = tk; next }
    }
    /^#+[ \t]+/ {
      match($0, /^#+/); d = RLENGTH
      t = $0; sub(/^#+[ \t]+/, "", t)
      hn++; ahl[hn] = NR; ad[hn] = d           # every heading, for the depth-based end below
      if (t ~ /^(Task|Step|Phase)[ \t]+[0-9]+/ || t ~ /^[0-9]+\./) { n++; hl[n] = NR; ht[n] = t; hd[n] = d }
    }
    END {
      for (i = 1; i <= n; i++) {
        # END AT THE NEXT HEADING OF EQUAL-OR-SHALLOWER DEPTH, never at the next ordinal heading:
        # "Task N" and "Step N" both match the ordinal pattern, so the naive rule ends a task at
        # its own first step.
        e = NR
        for (q = 1; q <= hn; q++) if (ahl[q] > hl[i] && ad[q] <= hd[i]) { e = ahl[q] - 1; break }
        has = 0
        for (j = hl[i]; j <= e; j++) if (lines[j] ~ /^\*\*(Files|Interfaces):\*\*/) has = 1
        if (!has) continue
        sid = ht[i]
        if (match(sid, /^(Task|Step|Phase)[ \t]+[0-9]+/)) sid = substr(sid, RSTART, RLENGTH)
        else if (match(sid, /^[0-9]+/))                   sid = substr(sid, RSTART, RLENGTH)
        gsub(/[ \t]+/, " ", sid)
        print ++k "\t" hl[i] "\t" e "\t" sid "\t" ht[i]
      }
    }
  ' "$1"
}

cmd_rows() { # <doc>
  local doc="${1:?usage: multi-review-crossref.sh rows <doc>}" secs nsec
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  secs="$(_sections "$doc")"
  nsec="$(printf '%s' "$secs" | grep -c . || true)"
  # TWO, not one. A single section has no pair to check and no earlier section to consume from, so
  # its only rows would be self-consistency ones — real, but not worth a dispatch on their own.
  (( nsec >= 2 )) || die "not applicable: no sectioned structure detected (${nsec} qualifying section(s))" 3
  local n=0 sid
  while IFS=$'\t' read -r _idx _start _end sid _title; do
    [[ -n "$sid" ]] || continue
    n=$((n + 1))
    printf 'S%d\tself\t%s\tdeclared Files vs files named in steps\n' "$n" "$sid"
  done <<< "$secs"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    rows)  cmd_rows "$@" ;;
    *)     die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
