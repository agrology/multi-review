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

TMPD="$(mktemp -d)" || die "cannot create a scratch dir" 2
trap 'rm -rf "$TMPD"' EXIT

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

# A path token: backticked, and either containing a '/' or ending in a known source extension.
# Trailing ":123" / ":1-9" line specs are stripped — `path:12` and `path` are the same file.
_paths_in() { # <text-on-stdin> -> one path per line
  awk '
    {
      s = $0
      while (match(s, /`[^`]+`/)) {
        tok = substr(s, RSTART + 1, RLENGTH - 2)
        s   = substr(s, RSTART + RLENGTH)
        sub(/:[0-9]+(-[0-9]+)?$/, "", tok)
        if (tok ~ /\// || tok ~ /\.(sh|bash|md|py|ts|tsx|js|json|yml|yaml|txt)$/) print tok
      }
    }
  ' | LC_ALL=C sort -u
}

# Declared: the paths inside the section's **Files:** block only — from the block header to the
# next blank-line-terminated bold block or the section end.
_files_declared() { # <doc> <start> <end>
  sed -n "${2},${3}p" "$1" \
    | awk '/^\*\*Files:\*\*/ { inblk = 1; next } inblk && /^[[:space:]]*$/ { inblk = 0 } inblk' \
    | _paths_in
}

# Named: every path token in the section, fences stripped. Deliberately WIDER than declared — the
# union of the two is what makes a pair set trustworthy when the Files block is wrong, which #90
# measured happening six times in one document.
_files_named() { # <doc> <start> <end>
  sed -n "${2},${3}p" "$1" > "${TMPD}/sec.$$"
  strip_fences "${TMPD}/sec.$$" | _paths_in
  rm -f "${TMPD}/sec.$$"
}

# Entries under **Interfaces:** whose bullet starts with the given kind. The bullet text after
# "Consumes:"/"Produces:" is kept verbatim — it is what the reviewer reads.
_iface_lines() { # <doc> <start> <end> <Consumes|Produces>
  sed -n "${2},${3}p" "$1" \
    | awk -v kind="$4" '
        /^\*\*Interfaces:\*\*/ { inblk = 1; next }
        inblk && /^[[:space:]]*$/ { inblk = 0 }
        inblk && $0 ~ ("^- " kind ":") {
          line = $0; sub("^- " kind ":[ \t]*", "", line)
          if (line != "") print line
        }
      '
}

cmd_rows() { # <doc>
  [[ $# -ge 1 ]] || die "usage: multi-review-crossref.sh rows <doc>" 2
  local doc="$1" secs nsec
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

  # One file list per section, indexed by position, built once: the pair loop is O(n^2) over
  # sections and re-deriving inside it would re-read the document for every pair.
  #
  # _files_declared is arithmetically dead TODAY (M3, final review, ruling R14: keep it, record
  # it): `declared ⊆ named` holds unconditionally, because _files_named scans the WHOLE section —
  # including the **Files:** block declared paths live in — so every declared path is already a
  # named one. Deleting `_files_declared` from this union leaves the suite fully green. It stays
  # in the union anyway, because that containment is not a law of the interface, only a fact about
  # today's _files_named: the moment _files_named is narrowed (e.g. to skip the Files block itself,
  # to stop double-counting a path already declared) the two sets stop being nested and this half
  # starts doing real work again. Recorded as SURVIVES-BY-DESIGN in the mutation table (§11) rather
  # than omitted, so losing that outer containment surfaces as a failure instead of silently
  # reintroducing the union bug #90 exists to close.
  local i=0 sids=""
  while IFS=$'\t' read -r _idx start end sid _title; do
    [[ -n "$sid" ]] || continue
    i=$((i + 1))
    { _files_declared "$doc" "$start" "$end"; _files_named "$doc" "$start" "$end"; } \
      | LC_ALL=C sort -u > "${TMPD}/files.${i}"
    sids="${sids}${sid}"$'\n'
  done <<< "$secs"

  local a b pn=0 sid_a sid_b shared
  for (( a = 1; a < i; a++ )); do
    sid_a="$(printf '%s' "$sids" | sed -n "${a}p")"
    for (( b = a + 1; b <= i; b++ )); do
      sid_b="$(printf '%s' "$sids" | sed -n "${b}p")"
      shared="$(LC_ALL=C comm -12 "${TMPD}/files.${a}" "${TMPD}/files.${b}")"
      [[ -n "$shared" ]] || continue
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        pn=$((pn + 1))
        printf 'P%d\tpair\t%s | %s\t%s\n' "$pn" "$sid_a" "$sid_b" "$f"
      done <<< "$shared"
    done
  done

  local inum=0 entry
  while IFS=$'\t' read -r _idx start end sid _title; do
    [[ -n "$sid" ]] || continue
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      inum=$((inum + 1))
      printf 'I%d\tiface\t%s\tconsumes: %s\n' "$inum" "$sid" "$entry"
    done < <(_iface_lines "$doc" "$start" "$end" Consumes)
  done <<< "$secs"
}

# Verdict lines live under the LAST '## Review' heading and outside fences — the same channel
# discipline the finding grammar uses. A PR description can legally contain a '> [crossref:...]'
# blockquote, and a fenced example of the grammar is documentation, not a verdict.
_review_verdicts() { # <copy> -> the fence-stripped review section
  awk '{ a[NR] = $0 } /^## Review[[:space:]]*$/ { last = NR }
       END { if (last) for (i = last + 1; i <= NR; i++) print a[i] }' "$1" > "${TMPD}/rv.$$"
  strip_fences "${TMPD}/rv.$$"
  rm -f "${TMPD}/rv.$$"
}

cmd_check() { # <doc> <copy> [--rows <file>]
  local doc="" copy="" rowsfile="" pos=0
  while (( $# )); do
    case "$1" in
      --rows) (( $# >= 2 )) || die "--rows requires a value" 2; rowsfile="$2"; shift 2 ;;
      *) case $pos in
           0) doc="$1" ;;
           1) copy="$1" ;;
           *) die "unexpected argument: $1" 2 ;;
         esac
         pos=$((pos + 1)); shift ;;
    esac
  done
  [[ -n "$doc" && -n "$copy" ]] || die "usage: multi-review-crossref.sh check <doc> <copy> [--rows <file>]" 2
  [[ -f "$doc"  ]] || die "doc not found: $doc" 2
  [[ -f "$copy" ]] || die "copy not found: $copy" 2

  # The worklist to judge against is the one the pass was DISPATCHED with, when the caller can
  # name it (issue #95). Re-deriving from the doc compares the verdicts against a row set that may
  # no longer be the one anybody was given: the primary's job between dispatch and check is to
  # agree with findings and EDIT the document, and an edit that adds a section changes the derived
  # rows, so rows the pass never saw surface as missing verdicts. Reproduced live on the first real
  # document the pass ran against — 25/25 against the dispatched baseline, INCOMPLETE against the
  # edited doc. An INCOMPLETE at the gate is meant to mean "the pass skipped rows"; there it meant
  # "the author did their job".
  #
  # A supplied file is authoritative and is never quietly abandoned: a MISSING one is a usage error
  # rather than a fallback to re-derivation, because falling back would reintroduce the defect at
  # exactly the moment the caller believed it was pinned. An EMPTY one is a contract error for the
  # same reason `rows` itself refuses to emit one — it means truncation, and treating it as "no
  # rows to cover" would report a turn that verdicted nothing as fully covered.
  local rows rc=0
  if [[ -n "$rowsfile" ]]; then
    [[ -f "$rowsfile" ]] || die "rows file not found: $rowsfile" 2
    [[ -s "$rowsfile" ]] || die "rows file is empty: $rowsfile" 2
    awk -F'\t' 'NF { print $1 }' "$rowsfile" | LC_ALL=C sort -u > "${TMPD}/want"
  else
    rows="$(cmd_rows "$doc")" || {
      rc=$?
      # Not applicable is not a failure: there was nothing to cover.
      (( rc == 3 )) && return 0
      die "cannot derive rows for $doc" 1
    }
    awk -F'\t' '{ print $1 }' <<< "$rows" | LC_ALL=C sort -u > "${TMPD}/want"
  fi

  local rv; rv="$(_review_verdicts "$copy")"

  printf '%s\n' "$rv" | grep -qE '^>[[:space:]]*\[crossref\][[:space:]]*—[[:space:]]*via[[:space:]]+[^[:space:]]' \
    || die "crossref table carries no '> [crossref] — via <model>' disclosure" 1

  printf '%s\n' "$rv" \
    | sed -n 's/^>[[:space:]]*\[crossref:\([A-Za-z][0-9A-Za-z]*\)|.*/\1/p' \
    | LC_ALL=C sort -u > "${TMPD}/got"

  local missing extra
  missing="$(LC_ALL=C comm -23 "${TMPD}/want" "${TMPD}/got" | tr '\n' ' ')"
  [[ -z "${missing// /}" ]] \
    || die "incomplete turn: no verdict for row(s): ${missing% }" 1
  extra="$(LC_ALL=C comm -13 "${TMPD}/want" "${TMPD}/got" | tr '\n' ' ')"
  [[ -z "${extra// /}" ]] \
    || die "verdict names row(s) that were never emitted: ${extra% }" 1

  # Every defect must name a finding present in the SAME copy. A defect recorded only in the table
  # is a finding that bypasses adjudication and never reaches the human gate's accounting.
  #
  # Uses literal index() matching, NOT a concatenated regex (star.sh:586, same rationale): building
  # "^> \[finding:" fid "|" as a regex would let any metacharacter in fid match unintended text —
  # "r." would match the literal finding id "rX" via the '.' wildcard.
  local fid
  while IFS= read -r fid; do
    [[ -n "$fid" ]] || continue
    printf '%s\n' "$rv" | awk -v fid="$fid" '
      index($0, "> [finding:" fid "|") == 1 { f = 1; exit }
      END { exit !f }
    ' || die "crossref defect names finding '${fid}', which is not in this copy" 1
  done < <(printf '%s\n' "$rv" | sed -n 's/^>[[:space:]]*\[crossref:[^|]*|defect:\([^]]*\)\].*/\1/p')
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
