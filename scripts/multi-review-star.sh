#!/usr/bin/env bash
# multi-review-star.sh — N-party "star" grammar & convergence (Claude primary + N secondaries).
# Sibling to core.sh/peer.sh; owns ONLY star's grammar/merge/convergence/summary. Subcommands:
#   mode <doc>              -> "star" | (defer: empty, exit 1)
#   resolve-set [--reviewers csv]
#   remember-set --pref-file <path> (--reviewers <csv> | --clear)
#   available
#   open-findings <doc>
#   observations <doc>
#   merge --round N [--quarantined p:reason ...] <doc> <copy> ...
#   check-converged <doc>
#   gate-summary <doc> <primary-model-id>
#   round-stats <doc>       -> per-round × per-provider finding counts, trend, dry streaks,
#                              and a converge/re-fan verdict (advisory; pure read)
#   evidence-gaps <doc>     -> high/med findings lacking a "> — evidence:" line (report, not gate)
#   channel-check --seed <seed> <copy> -> exit 1 if a reviewer's findings landed outside the
#                              merged '## Review' channel (issue #32); the turn would merge clean
#   compose-review <doc> <primary-model-id>  -> neutral PR review body (dormant; Task A4)
#   compose-inline <doc>                     -> "path\tstart\tend\tbody" per agreed+anchored
#                                                finding (dormant; Task A4)
set -uo pipefail

die() { echo "multi-review-star: $1" >&2; exit "${2:-1}"; }

# header region = lines before the first "## " section heading
header_region() { awk '/^## /{ exit } { print }' "$1"; }

# Emit only lines OUTSIDE fenced code blocks (CommonMark ```+, length-aware close; no awk
# interval expressions — macOS awk). Duplicated from multi-review-core.sh for module isolation.
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

# The line where a fence opened but never closed, else empty. An unterminated fence makes
# strip_fences silently drop every line after it — including live findings — so a doc with one
# would parse as "no findings" and could falsely converge. Callers must refuse. (Mirrors
# multi-review-core.sh; duplicated for module isolation.)
unterminated_fence_line() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence=0; fence_len=0 } }
      } else if (ticks >= 3) { infence = 1; fence_len = ticks; open_ln = NR }
    }
    END { if (infence) print open_ln }
  ' "$1"
}

# review_section <file> : lines after the LAST "## Review" heading (the peer-review channel).
# A PR scratch file has ## PR description / ## Diff BEFORE ## Review, and a PR description can
# legally contain "> [finding:...]" blockquotes — so the parser must look ONLY here (r1).
review_section() {
  awk '{ a[NR]=$0 } /^## Review[[:space:]]*$/ { last=NR } END { if (last) for (i=last+1; i<=NR; i++) print a[i] }' "$1"
}

# review_section_start <file> : file line number of the LAST "## Review" heading (0 if none).
# review_section emits the lines AFTER that heading, so a fence at section-relative line N sits at
# file line (start + N) — used to report a real file line, not a section-relative one.
review_section_start() {
  awk '/^## Review[[:space:]]*$/ { last=NR } END { print last+0 }' "$1"
}

# Star mode-hint: value is "star", optionally followed by "· reviewers: <ids>". Anchored to the
# whole comment line so junk after the value is malformed, not silently accepted.
STAR_GREP='<!--[[:space:]]*multi-review-mode:[[:space:]]*star'
# Provider REGISTRY KEYS are short dot/hyphen-free ids (codex/fable/gemini) — deliberately
# distinct from dotted MODEL strings (gemini-pro-latest). So the reviewers list is [a-z0-9 ]+
# (see r8/r9: widening this to dots was reverted — dot-free keys keep the whole id pipeline
# — suffix split, awk matching — injection-free at the root).
STAR_RE='^[[:space:]]*<!--[[:space:]]*multi-review-mode:[[:space:]]*star([[:space:]]*·[[:space:]]*reviewers:[[:space:]]*[a-z0-9 ]+)?[[:space:]]*-->[[:space:]]*$'

cmd_mode() { # <doc> -> "star" or defer (empty, exit 1)
  local doc="${1:?doc}" hdr n line
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  hdr="$(header_region "$doc")"
  n="$(printf '%s\n' "$hdr" | grep -cE "$STAR_GREP" || true)"
  (( n == 0 )) && return 1                       # defer: not star (peer/asymmetric decide)
  (( n == 1 )) || die "multiple star mode hints in header: $doc" 1
  line="$(printf '%s\n' "$hdr" | grep -E "$STAR_GREP" | head -1)"
  [[ "$line" =~ $STAR_RE ]] || die "malformed star mode hint: $doc" 1
  echo "star"
}

# The ONE parser for the durable quarantine record. Canonical shape, written by cmd_merge:
#
#     <!-- star-quarantined: <provider> · <reason> · round <N> -->
#
# <provider> is a registry key ([a-z0-9]+); <reason> may contain spaces ([^·]+); <N> is [0-9]+.
# Emits "<provider><TAB><reason><TAB><round>" per record, in document order.
#
# Every FIELD-reading consumer goes through this (gate-summary's readability list and independence
# scan, round-stats, compose-review) — four independent greps had accumulated, and issue #26 was
# a fifth about to be written. One reader means they cannot drift.
#
# FENCE-AWARE, and deliberately so: a fenced example of the record is documentation, not a live
# quarantine. `_structural_consistency` already strips fences before matching (#17-refix r2 was
# exactly this bug), while gate-summary and round-stats grepped the raw file — so one doc could
# disagree with itself about who was quarantined. Same `review_section | strip_fences` input the
# consistency guard uses, so the two can never diverge again.
#
# NB: `_structural_consistency` guard (d) still consumes RAW record lines, not these fields — it
# hashes them against the manifest, so it needs the byte-exact line. That is a different question
# (integrity, not identity) and correctly stays separate.
_quarantines() { # <doc> -> provider<TAB>reason<TAB>round per record
  # grep and sed MUST agree on what a valid record is. They did not: `[^·]+` accepted a
  # whitespace-only reason that the sed then refused to transform, so the raw comment line fell
  # through the pipeline and was printed verbatim as an entry — and space-split into garbage
  # tokens in the disclosure line. Both now require a non-space in the reason, and the trailing
  # grep is a belt-and-braces guarantee that nothing untransformed can ever escape: a row here is
  # three tab-separated fields or it does not exist.
  review_section "$1" | strip_fences /dev/stdin \
    | grep -oE '^<!-- star-quarantined: [a-z0-9]+ · *[^ ·][^·]* · round [0-9]+ -->' \
    | sed -E 's/^<!-- star-quarantined: ([a-z0-9]+) · *(.*[^ ]) *· round ([0-9]+) -->$/\1'$'\t''\2'$'\t''\3/' \
    | grep -v '^<!--' \
    || true
}

STAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for tests (dependency injection of the reviewer-helper PATH — not a behavior hook).
REVIEWER_SH="${MULTI_REVIEW_REVIEWER_SH:-${STAR_DIR}/multi-review-reviewer.sh}"

# resolve-set [--fable-floor] [--reviewers csv] [--pref-file path]
# Source precedence: --reviewers(non-empty) > MULTI_REVIEW_REVIEWERS(non-empty) > pref-file(non-empty).
# Pref source ONLY: strip literal fable, drop unknown/unavailable ids with a notice (degrade, never
# hard-fail, never rewrite the pref). Flag/env: unknown id is a hard exit-2 usage error.
cmd_resolve_set() {
  local fable_floor=0 csv="" pref_file="" src="" raw="" seen="" id row out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fable-floor) fable_floor=1; shift ;;
      --reviewers)   [[ $# -ge 2 ]] || die "--reviewers requires a value" 2; csv="$2"; shift 2 ;;
      --pref-file)   [[ $# -ge 2 ]] || die "--pref-file requires a value" 2; pref_file="$2"; shift 2 ;;
      # Reject unknown args (parity with remember-set) so a typo'd flag can't silently disable the
      # pref feature instead of surfacing (fable-rd2-r2).
      *) die "resolve-set: unexpected argument: $1" 2 ;;
    esac
  done
  # Every source is comma-OR-space tolerant: `tr ',' ' '` on all three, so a csv env value
  # ("codex,gemini") splits the same as the flag and pref (fable-rd1-r1).
  if [[ -n "$csv" ]]; then
    raw="$(printf '%s' "$csv" | tr ',' ' ')"; src="flag"
  elif [[ -n "${MULTI_REVIEW_REVIEWERS:-}" ]]; then
    raw="$(printf '%s' "${MULTI_REVIEW_REVIEWERS}" | tr ',' ' ')"; src="env"
  elif [[ -n "$pref_file" && -s "$pref_file" ]]; then
    raw="$(tr ',' ' ' < "$pref_file")"; src="pref"
  else
    raw=""; src="none"
  fi
  set -f                               # no globbing: a '*' in the pref/csv must not expand to filenames (fable-rd3-r5)
  for id in $raw; do
    # pref normalization: a hand-added literal fable is never a stored extra (it is floored).
    [[ "$src" == "pref" && "$id" == "fable" ]] && continue
    case " $seen " in *" $id "*) continue ;; esac
    if ! row="$("$REVIEWER_SH" resolve --reviewer "$id" 2>/dev/null)"; then
      if [[ "$src" == "pref" ]]; then
        # Record the dropped id so a duplicate in the pref is skipped, not re-dropped (one notice).
        seen="$seen $id"
        echo "multi-review-star: pref reviewer '$id' unknown — dropping" >&2; continue
      fi
      set +f; die "unknown reviewer provider in set: ${id}" 2
    fi
    if [[ "$src" == "pref" ]] && ! "$REVIEWER_SH" check --reviewer "$id" >/dev/null 2>&1; then
      seen="$seen $id"
      echo "multi-review-star: pref reviewer '$id' unavailable in this repo — dropping (pref unchanged)" >&2
      continue
    fi
    seen="$seen $id"
    out="${out}${row}"$'\n'
  done
  set +f
  if (( fable_floor )); then
    case " $seen " in *" fable "*) : ;; *)
      row="$("$REVIEWER_SH" resolve --reviewer fable 2>/dev/null)" || die "fable unavailable" 2
      out="${out}${row}"$'\n' ;;
    esac
  fi
  [[ -n "$out" ]] || exit 3            # empty set -> not star (legacy path only; unreachable with --fable-floor)
  printf '%s' "$out"
}

cmd_available() {
  local id
  for id in codex fable gemini; do
    if "$REVIEWER_SH" check --reviewer "$id" >/dev/null 2>&1; then
      echo "$id yes"
    else
      echo "$id no"
    fi
  done
}

# _table <doc> : print "id\traiser\tstate\tresponder\tconcern\twhy\tsev\trisk" per finding
# (state: open|agreed|dissent). Parses ONLY the last ## Review section (review_section), fences
# stripped. Verbs are finding|agree|dispute (star has N secondaries + primary, so there is no
# 2-model cap — that is peer.sh's rule). Enforces the self-response guard: a primary must not
# respond to a finding disclosed under its own model id. On any grammar violation, prints an
# error to stderr and exits 2. Pure awk (portable associative arrays); control line + its
# required "> — via" line are consumed as a pair.
_table() { # <doc> -> "id\traiser\tstate\tresponder\tconcern\twhy\tsev\trisk\tevidence" per finding
  local doc="${1:?doc}" ufl rstart
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  ufl="$(review_section "$doc" | unterminated_fence_line /dev/stdin)"
  if [[ -n "$ufl" ]]; then
    rstart="$(review_section_start "$doc")"
    die "unterminated code fence in ## Review (file line $((rstart + ufl))): findings after it are invisible — close the fence" 1
  fi
  review_section "$doc" | strip_fences /dev/stdin | awk '
    function fail(m){ print "multi-review-star: " m > "/dev/stderr"; exit 2 }
    function parse(line,   s, c, rest, b, p) {
      if (line !~ /^> \[(finding|agree|dispute):[A-Za-z0-9_-]+([|][^]]*)?]/) return 0
      s = substr(line, 4)
      c = index(s, ":"); V = substr(s, 1, c-1)
      rest = substr(s, c+1)
      b = index(rest, "]"); I = substr(rest, 1, b-1)
      WHY = substr(rest, b+1); sub(/^ /, "", WHY)
      SEV = ""; p = index(I, "|")
      if (p > 0) { SEV = substr(I, p+1); I = substr(I, 1, p-1) }
      return 1
    }
    {
      line = $0
      if (pend) {
        if (line ~ /^> — via /) {
          m = line; sub(/^> — via[ ]*/, "", m); gsub(/^[ \t]+|[ \t]+$/, "", m)
          if (m == "") fail("missing model id after " pv ":" pi)
          if (pv == "finding") {
            if (psev != "high" && psev != "med" && psev != "low") fail("finding " pi " needs a |high, |med, or |low severity tag")
            if (pi in raiser) fail("duplicate finding id: " pi)
            stripped = pwhy; gsub(/^[ \t]+|[ \t]+$/, "", stripped)
            if (stripped == "") fail("empty concern for finding: " pi)
            raiser[pi] = m; fwhy[pi] = pwhy; fsev[pi] = psev; order[++n] = pi
            awaiting_risk = 1; risk_for = pi        # a finding must be followed by its risk line
          } else {
            if (psev != "") fail("severity tag not allowed on " pv ": " pi)
            if (pi in rverb) fail("multiple responses to finding: " pi)
            rverb[pi] = pv; rmodel[pi] = m; rwhy[pi] = pwhy
          }
          pend = 0; next
        } else {
          fail("control line " pv ":" pi " not followed by a \"> — via <model>\" line")
        }
      }
      if (awaiting_risk) {
        awaiting_risk = 0
        if (line ~ /^> — risk:/) {
          rk = line; sub(/^> — risk:[ ]*/, "", rk); gsub(/[ \t]+$/, "", rk)
          if (rk == "") fail("empty risk for finding: " risk_for)
          frisk[risk_for] = rk; cur_finding = risk_for; next
        } else { fail("finding " risk_for " not followed by a \"> — risk: <risk>\" line") }
      }
      # Optional `> — evidence:` line, credited to the finding whose block we are still inside.
      # cur_finding is cleared by the next control line, so an evidence line sitting after a
      # response cannot retroactively document the finding above it. Never fatal when absent:
      # a missing line must not fail the parse, because that quarantines the whole reviewer turn
      # and discards real findings — the failure mode this project keeps having to undo.
      if (line ~ /^> — evidence:/) {
        if (cur_finding != "") {
          ev = line; sub(/^> — evidence:[ ]*/, "", ev); gsub(/[ \t]+$/, "", ev)
          if (ev != "") fev[cur_finding] = ev
        }
        next
      }
      if (parse(line)) { pv = V; pi = I; pwhy = WHY; psev = SEV; pend = 1; cur_finding = "" }
    }
    END {
      if (pend) fail("control line " pv ":" pi " not followed by a \"> — via <model>\" line")
      if (awaiting_risk) fail("finding " risk_for " not followed by a \"> — risk: <risk>\" line")
      for (id in rverb) if (!(id in raiser)) fail("response to unknown finding id: " id)
      for (i = 1; i <= n; i++) {
        id = order[i]
        if (id in rverb && rmodel[id] == raiser[id]) fail("self-response on finding: " id)
        state = "open"
        if (rverb[id] == "agree") state = "agreed"
        else if (rverb[id] == "dispute") state = "dissent"
        resp = (id in rmodel) ? rmodel[id] : ""
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, raiser[id], state, resp, fwhy[id], rwhy[id], fsev[id], frisk[id], fev[id]
      }
    }
  '
}

cmd_open_findings() { # <doc> -> ids with state==open
  local doc="${1:?doc}" t
  t="$(_table "$doc")" || exit $?
  printf '%s\n' "$t" | awk -F'\t' '$3 == "open" { print $1 }'
}

# cmd_observations <doc> -> observation text per line. A primary observation is a human-gate-only
# note, NOT a finding: `> [observation] <text>` + required `> — via <model>` pair, in ## Review.
# Never parsed by _table (verb set stays finding|agree|dispute) — never enters the manifest,
# never affects check-converged.
# A `> [observation]` line NOT immediately followed by its `> — via <model>` line — including at
# end-of-input — fails loud (stderr message, exit 2), mirroring _table's fail() for findings.
# An undisclosed observation must not silently vanish from the gate summary (Codex peer review).
cmd_observations() { # <doc> -> observation text per line; exit 2 on an undisclosed observation
  local doc="${1:?doc}"
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  review_section "$doc" | strip_fences /dev/stdin | awk '
    function fail(m){ print "multi-review-star: " m > "/dev/stderr"; exit 2 }
    {
      line = $0
      if (pend) {
        if (line ~ /^> — via /) { print ptxt; pend = 0; next }
        else { fail("observation not followed by a \"> — via <model>\" line") }
      }
      if (line ~ /^> \[observation] /) { ptxt = line; sub(/^> \[observation] /, "", ptxt); pend = 1 }
    }
    END { if (pend) fail("observation not followed by a \"> — via <model>\" line") }
  '
}

provider_of_copy() { # <doc> <copy> -> provider (exact suffix after "<doc>.")
  local doc="$1" copy="$2"
  local p="${copy#${doc}.}"   # exact prefix strip (r8), not ${##*.}
  # validate against the registry rather than a hardcoded list (r8): resolve-set already
  # trusts the registry as the source of truth, so merge must too.
  [[ "$p" != "$copy" ]] || die "copy name does not match <doc>.<provider>: $copy" 2
  "$REVIEWER_SH" resolve --reviewer "$p" >/dev/null 2>&1 \
    || die "copy names an unknown provider '${p}': $copy" 2
  echo "$p"
}

# emit a copy's finding blocks with ids namespaced <id> -> <provider>-rd<N>-<id> on the
# [finding:] line only, preserving |sev; all other lines pass through verbatim.
namespace_blocks() { # <provider> <round> <copy>
  local provider="$1" round="$2" copy="$3"
  review_section "$copy" | strip_fences /dev/stdin | awk -v pfx="${provider}-rd${round}-" '
    /^> \[finding:[A-Za-z0-9_-]+([|][^]]*)?]/ {
      # rewrite only the id token between "finding:" and the first "|" or "]"
      pre = "> [finding:"; s = substr($0, length(pre)+1)
      # s begins with <id>[|sev]] rest...
      i = 1
      while (i <= length(s) && substr(s,i,1) != "|" && substr(s,i,1) != "]") i++
      id = substr(s, 1, i-1); tail = substr(s, i)
      print pre pfx id tail; next
    }
    { print }
  '
}

sha() { shasum -a 256 | cut -d' ' -f1; }   # macOS+Linux; falls back below if absent
if ! command -v shasum >/dev/null 2>&1; then sha() { sha256sum | cut -d' ' -f1; }; fi

# hash of one finding block (the [finding:] line + its > — continuation lines) by ns-id.
# Uses literal index() matching, NOT a concatenated regex (r9): building "^> \[finding:" id ...
# would treat any metachar in id as a pattern. ns-ids are [A-Za-z0-9_-]+ so this is belt-and-
# suspenders, but literal matching is clearer and injection-proof regardless.
finding_block_hash() { # <doc> <ns-id>
  local doc="$1" id="$2"
  review_section "$doc" | strip_fences /dev/stdin | awk -v id="$id" '
    (index($0, "> [finding:" id "|") == 1 || index($0, "> [finding:" id "]") == 1) { grab=1; print; next }
    grab && /^> — / { print; next }
    grab { grab=0 }
  ' | sha
}

# anchor_of <doc> <ns-id> -> "path\tstart\tend" (end may be empty) if that finding's block
# carries a valid "> — at <path>:<lineinfo>" line, else empty output (exit 0) — that's the ABSENT
# case (no "> — at" line at all): the finding falls to the summary, same as always. A PRESENT but
# MALFORMED anchor (empty path, no numeric ":N"/":N-M" suffix, or end<start) is a contract
# violation and hard-fails (exit 2, message to stderr) rather than silently degrading — the same
# fail-loud convention _table itself uses on a malformed finding block. Live in a
# standalone reader — not folded into _table's column contract (brief: keep _table's 8-column
# shape untouched). Block-scoping mirrors finding_block_hash's literal index() match.
anchor_of() { # <doc> <ns-id> -> "path\tstart\tend" or empty; exit 2 on malformed anchor
  local doc="$1" id="$2"
  # Drains its awk to EOF (no early `exit` on the success path) rather than printing and exiting
  # immediately — mirrors finding_block_hash's SIGPIPE-safe pattern. An early exit here would
  # leave review_section/strip_fences writing into a closed pipe once the ## Review section
  # exceeds the OS pipe buffer, and with `pipefail` set that SIGPIPE surfaces as this function's
  # exit status, falsely tripping callers' "contract violation" checks on large-but-valid docs.
  review_section "$doc" | strip_fences /dev/stdin | awk -v id="$id" '
    function fail(m){ print "multi-review-star: " m > "/dev/stderr"; exit 2 }
    (index($0, "> [finding:" id "|") == 1 || index($0, "> [finding:" id "]") == 1) { grab=1; next }
    grab && /^> — at / {
      a = $0; sub(/^> — at[ ]*/, "", a); gsub(/[ \t]+$/, "", a)
      if (match(a, /:[0-9]+(-[0-9]+)?$/)) {
        nums = substr(a, RSTART + 1)
        path = substr(a, 1, RSTART - 1)
        if (path == "") fail("empty path in > — at for finding: " id)
        d = index(nums, "-")
        if (d == 0) { st = nums + 0; en = "" }
        else { st = substr(nums, 1, d - 1) + 0; en = substr(nums, d + 1) + 0 }
        if (en != "" && en < st) fail("> — at end < start for finding: " id)
        out = path "\t" st "\t" en
        grab = 0; next
      }
      fail("malformed > — at anchor for finding " id ": " $0)
    }
    grab && /^> — / { next }
    grab { grab=0 }
    END { if (out != "") print out }
  '
}

cmd_compose_review() { # <doc> <primary-model> -> neutral star review body on stdout
  local doc="${1:?doc}" primary="${2:?primary-model}" t qlist qprov
  t="$(_table "$doc")" || die "cannot compose: contract violation in $doc" 1
  # Quarantines belong in the POSTED review, not just the local gate (issue #26). A review
  # degraded by provider failure otherwise reads as a clean one, and the disclosure line — built
  # from finding raisers — silently omits a provider that was dispatched and died. The human gate
  # exists so a person decides with full information; a quarantine is precisely the signal that
  # the review was thinner than it looks.
  qlist="$(_quarantines "$doc")"
  # Only providers that contributed NOTHING anywhere in the doc get appended to the disclosure.
  # A provider quarantined in one round may have raised findings in another (PR #25's own shape) —
  # it is then already represented there by its raiser model id, and adding "<id> (quarantined)"
  # names the same reviewer twice under a different spelling, inflating the apparent agent count.
  # Contributors are exactly the ns-id prefixes, the same split gate-summary uses.
  local contributed; contributed="$(printf '%s\n' "$t" | awk -F'\t' 'NF{p=$1; sub(/-rd.*/,"",p); print p}' | sort -u)"
  qprov="$(printf '%s' "$qlist" | awk -F'\t' 'NF{print $1}' | sort -u \
           | grep -vxF -f <(printf '%s\n' "$contributed") 2>/dev/null | tr '\n' ' ')"
  # _table columns (tab-separated): id, raiser, state, responder, concern, dwhy, sev, risk.
  # Use awk -F'\t' to avoid bash IFS-whitespace collapsing of adjacent empty tab fields.
  printf '%s\n' "$t" | QLIST="$qlist" QPROV="$qprov" awk -F'\t' -v primary="$primary" '
    function emit(want,   lvl, i, levels) {
      split("high med low", levels, " ")
      for (lvl = 1; lvl <= 3; lvl++)
        for (i = 1; i <= n; i++)
          if (st[i] == want && sv[i] == levels[lvl]) print txt[i]
      print ""
    }
    BEGIN { n=0; agreed_n=0; dissent_n=0; open_n=0; nsec=0 }
    NF < 3 { next }
    {
      id=$1; raiser=$2; state=$3; resp=$4; concern=$5; dwhy=$6; sev=$7; risk=$8
      if (raiser != "" && raiser != primary && !(raiser in secseen)) { secseen[raiser]=1; seclist[++nsec]=raiser }
      emoji = (sev=="high") ? "🔴" : (sev=="med") ? "🟠" : (sev=="low") ? "🟡" : ""
      line = emoji " " sev " — " concern " — risk: " risk
      if (state == "dissent")   line = line " — flagged by " raiser "; " resp " disputes: " dwhy
      else if (state == "open") line = line " — raised by " raiser ", no response yet"
      n++; st[n]=state; sv[n]=sev; txt[n]=line
      if (state == "agreed")       agreed_n++
      else if (state == "dissent") dissent_n++
      else if (state == "open")    open_n++
    }
    END {
      printf "## Multi-review\n\n"
      if (agreed_n == 0 && dissent_n == 0 && open_n == 0) {
        printf "No findings.\n\n"
      } else {
        if (agreed_n  > 0) { printf "**Agreed findings (%d)**\n", agreed_n;  emit("agreed") }
        if (dissent_n > 0) { printf "**Disagreements (%d)**\n",   dissent_n; emit("dissent") }
        if (open_n    > 0) { printf "**Open / unresolved (%d)**\n", open_n;  emit("open") }
      }
      # Quarantined secondaries, from the shared parser (ENVIRON, not -v: reasons contain spaces
      # and the list is newline-separated, which -v cannot carry).
      nq = split(ENVIRON["QLIST"], qrec, "\n")
      shown = 0
      for (i = 1; i <= nq; i++) {
        if (qrec[i] == "") continue
        if (!shown) { printf "**Quarantine events (secondary did not review that round; its findings for that round are excluded)**\n"; shown = 1 }
        split(qrec[i], qf, "\t")
        printf "- %s · %s · round %s\n", qf[1], qf[2], qf[3]
      }
      if (shown) printf "\n"

      # The disclosure must name who was DISPATCHED, not merely who scored. Built from finding
      # raisers alone, it silently narrowed whenever a provider was quarantined.
      models = primary
      for (i = 1; i <= nsec; i++) models = models " + " seclist[i]
      np = split(ENVIRON["QPROV"], qp, " ")
      for (i = 1; i <= np; i++) if (qp[i] != "") models = models " + " qp[i] " (quarantined)"
      printf "———\n🤖 Posted by AI agents (%s) via multi-review star review.\n", models
    }
  '
}

cmd_compose_inline() { # <doc> -> "path\tstart\tend\tbody" per agreed+anchored finding
  local doc="${1:?doc}" t
  t="$(_table "$doc")" || die "cannot compose inline: contract violation in $doc" 1
  local rec id raiser state resp concern sev risk anchor path start end body emoji
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    id="$(awk -F'\t' '{print $1}' <<< "$rec")"
    raiser="$(awk -F'\t' '{print $2}' <<< "$rec")"
    state="$(awk -F'\t' '{print $3}' <<< "$rec")"
    resp="$(awk -F'\t' '{print $4}' <<< "$rec")"
    concern="$(awk -F'\t' '{print $5}' <<< "$rec")"
    sev="$(awk -F'\t' '{print $7}' <<< "$rec")"
    risk="$(awk -F'\t' '{print $8}' <<< "$rec")"
    [[ "$state" == "agreed" ]] || continue
    anchor="$(anchor_of "$doc" "$id")" || die "cannot compose inline: contract violation in $doc" 1
    [[ -n "$anchor" ]] || continue
    path="$(awk -F'\t' '{print $1}' <<< "$anchor")"
    start="$(awk -F'\t' '{print $2}' <<< "$anchor")"
    end="$(awk -F'\t' '{print $3}' <<< "$anchor")"
    emoji="🔴"; [[ "$sev" == "med" ]] && emoji="🟠"; [[ "$sev" == "low" ]] && emoji="🟡"
    body="${emoji} ${sev} — ${concern} — risk: ${risk} — 🤖 multi-review star review (${raiser}"
    [[ -n "$resp" ]] && body="${body} + ${resp}"
    body="${body})"
    printf '%s\t%s\t%s\t%s\n' "$path" "$start" "$end" "$body"
  done <<< "$t"
}


# channel-check --seed <copy-as-dispatched> <copy> — did the reviewer's findings reach the channel?
#
# Issue #32. `merge` reads only the text after the LAST "## Review", so a reviewer that appends
# under an EARLIER one — e.g. a `## Review` inside a fenced example, which any doc about this
# protocol legitimately contains — has its entire turn silently discarded. Nothing catches it
# today: verify-vendor passes, merge exits 0, `verify` reports the doc consistent, no quarantine
# is recorded, and gate-summary shows the provider as admitted with zero findings, which is
# indistinguishable from a reviewer that genuinely found nothing.
#
# Two things this must get right, both found by review of the first attempt:
#
#   * Compare against the copy AS DISPATCHED (its seed), NOT `<doc>.baseline`. From round 2 a
#     copy may be a SCOPED reduction, so baseline lines absent from it deflate the additions and
#     each absent `> [finding:` example silently absorbs one misplaced finding — which made the
#     first version miss #32's own motivating incident (codex, round 2, fenced grammar examples).
#   * Count what MERGE actually ingests — `review_section | strip_fences` — not raw lines after
#     the heading. A turn written inside a fence AFTER the real heading is stripped by merge and
#     would otherwise pass.
#
# Additions are compared with `comm`, not by net count, so deleting a pre-existing finding line
# cannot offset a misplaced one back to zero.
cmd_channel_check() {
  local base="" copy=""
  while (( $# )); do
    case "$1" in
      --baseline|--seed)
        (( $# >= 2 )) || die "$1 requires a value" 2
        base="$2"; shift 2 ;;
      *) [[ -n "$copy" ]] || copy="$1"; shift ;;
    esac
  done
  [[ -n "$base" ]] || die "channel-check requires --seed <copy-as-dispatched>" 2
  [[ -f "$base" ]] || die "seed not found: $base" 2
  [[ -n "$copy" && -f "$copy" ]] || die "copy not found: ${copy:-<unset>}" 2

  local sa sv ca cv added_total added_visible stray
  sa="$(mktemp)"; sv="$(mktemp)"; ca="$(mktemp)"; cv="$(mktemp)"
  # ALL finding lines anywhere in the file...
  grep '^> \[finding:' "$base" 2>/dev/null | sort > "$sa" || true
  grep '^> \[finding:' "$copy" 2>/dev/null | sort > "$ca" || true
  # ...versus exactly what MERGE will ingest: the last ## Review section, fences stripped.
  review_section "$base" | strip_fences /dev/stdin | grep '^> \[finding:' 2>/dev/null | sort > "$sv" || true
  review_section "$copy" | strip_fences /dev/stdin | grep '^> \[finding:' 2>/dev/null | sort > "$cv" || true

  # Compare ADDITIONS (comm), not net counts: a net count lets a reviewer that deletes a
  # pre-existing line offset one misplaced finding of its own back to zero (fable-rd1-r5).
  added_total="$(comm -13 "$sa" "$ca" | grep -c '^> \[finding:' || true)"
  added_visible="$(comm -13 "$sv" "$cv" | grep -c '^> \[finding:' || true)"
  rm -f "$sa" "$sv" "$ca" "$cv"

  (( added_total <= added_visible )) && return 0
  stray=$(( added_total - added_visible ))
  local why="an earlier or fenced '## Review' captured them"
  grep -q '^## Review[[:space:]]*$' "$copy" \
    || why="the copy has NO '## Review' heading, so nothing could reach the channel"
  die "reviewer added ${added_total} finding(s) but only ${added_visible} are in what merge ingests — ${stray} landed outside it (${why}). Merging would record this turn as clean." 1
}

# --- doc↔manifest consistency (issue #16) ----------------------------------
# Returns 0 iff the doc is internally well-formed AND matches its .manifest;
# nonzero with a specific stderr message otherwise. Reused by the `verify`
# subcommand and as a self-check at both ends of `merge`, so operator- or
# merge-introduced corruption fails loud at the handoff instead of accumulating
# silently to the terminal gate. Does NOT require convergence/coverage — open
# findings (no response yet) are a normal mid-review state.
_structural_consistency() { # <doc> -> 0 consistent, 1 + stderr otherwise
  local doc="$1"
  [[ -f "$doc" ]] || { echo "multi-review-star: verify: doc not found: $doc" >&2; return 1; }
  # grammar — catches a finding split from its > — via/risk lines and a response to an unknown
  # finding id (issue #16 symptoms 1 & 3-orphan). Capture the parsed table: it is the AUTHORITATIVE
  # list of findings the rest of the tool (open-findings, coverage, gate-summary) can see.
  local tbl; tbl="$(_table "$doc")" || return 1
  # a merged doc always has a manifest.
  [[ -f "${doc}.manifest" ]] || { echo "multi-review-star: verify: no manifest (never merged): ${doc}.manifest" >&2; return 1; }

  # Fence-stripped review section, computed once and reused by the footer/quarantine checks so they
  # never grep raw doc content (a fenced diff / prose look-alike must not be seen as a live record).
  local review; review="$(review_section "$doc" | strip_fences /dev/stdin)"

  # (b) finding-id set: compare the _table-PARSED ids (NOT a raw grep) against the manifest. A raw
  #     grep accepts an id outside _table's [A-Za-z0-9_-] grammar that the manifest records but
  #     _table cannot see — recorded-yet-unadjudicated, invisible to open-findings/coverage/gate —
  #     which would let the terminal gate fail OPEN (#17-refix3 high). Sourcing present-ids from
  #     _table makes such an id a manifest/doc mismatch → fail closed.
  local present manifest_ids
  present="$(printf '%s\n' "$tbl" | awk -F'\t' 'NF{print $1}' | sort -u)"
  manifest_ids="$(awk '$1=="finding"{sub(/=.*/,"",$2); print $2}' "${doc}.manifest" | sort -u)"
  if [[ "$present" != "$manifest_ids" ]]; then
    echo "multi-review-star: verify: doc findings do not match manifest (a round may have been dropped or added):" >&2
    comm -3 <(printf '%s\n' "$present") <(printf '%s\n' "$manifest_ids") \
      | awk -F'\t' 'NF==2{print "  manifest-only: " $2} NF==1{print "  doc-only: " $1}' >&2
    return 1
  fi
  # (c) each present finding's block bytes are unchanged since merge.
  local id want got
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    want="$(awk -v i="$id" '$1=="finding" && index($2, i"=")==1 {sub(/^[^=]*=/,"",$2); print $2}' "${doc}.manifest")"
    got="$(finding_block_hash "$doc" "$id")"
    [[ "$want" == "$got" ]] || { echo "multi-review-star: verify: finding block changed since merge: $id" >&2; return 1; }
  done <<< "$present"
  # footer shape (best-effort). The footer is an UNTRUSTED mirror — real integrity is the manifest
  # checks above and (d) below — so this is a cheap shape guard for the fused/truncated/deleted
  # footer corruption, NOT a complete footer-integrity check (a count-preserving swap or a dry
  # round's footer deletion is out of scope; #17 codex-r1). Count well-formed footers vs the
  # highest manifest round; do NOT grep for the "; quarantined:" sentinel (it appears legitimately
  # in finding text / a fenced diff; #17 r1). Round parsed with match(/-rd[0-9]+/) — the FIRST
  # "-rd<n>" — robust to a hyphenated provider (#17 gemini) and to a later "-rd<n>" substring in a
  # namespaced id (e.g. codex-rd1-guard-rd2; #17 fable/gemini); a greedy or [^-]*-anchored parse
  # mis-read the round and could false-fail or (via a spoofed "-rd0") bypass this guard.
  local nfooters nrounds
  nfooters="$(printf '%s\n' "$review" | grep -cE '^<!-- star-findings: .*-->$')"
  nrounds="$(awk '$1=="finding" || $1=="quarantine" { if (match($2, /-rd[0-9]+/)) print substr($2, RSTART+3, RLENGTH-3)+0 }' "${doc}.manifest" | sort -un | tail -1)"
  nrounds="${nrounds:-0}"
  if [[ "$nfooters" -lt "$nrounds" ]]; then
    echo "multi-review-star: verify: $nfooters well-formed footers but $nrounds rounds merged — a footer is fused, truncated, or deleted" >&2
    return 1
  fi
  # (d) quarantine records: every manifest quarantine entry must have a matching durable record in
  # the (fence-stripped) review section, unchanged. Matched by HASH-MEMBERSHIP: accept iff SOME
  # star-quarantined line hashes to the manifest hash. This can neither be shadowed by a fenced /
  # different-text look-alike (fences stripped, and a spoof won't hash-match; #17 r2) nor fooled by
  # ordering (no head -1). Same helper the terminal gate uses (guard (d)) — one implementation, so
  # handoff and gate can never diverge (#17: they did, and that was a bug).
  local qentry qkey qwant qok qline
  while IFS= read -r qentry; do
    [[ -z "$qentry" ]] && continue
    qkey="${qentry%%=*}"; qwant="${qentry#*=}"; qok=0
    while IFS= read -r qline; do
      [[ -z "$qline" ]] && continue
      [[ "$(printf '%s' "$qline" | sha)" == "$qwant" ]] && { qok=1; break; }
    done < <(printf '%s\n' "$review" | grep -E '^<!-- star-quarantined: ')
    [[ "$qok" == "1" ]] || { echo "multi-review-star: verify: quarantine record missing or tampered for ${qkey}" >&2; return 1; }
  done < <(awk '$1=="quarantine"{print $2}' "${doc}.manifest")
  return 0
}

cmd_verify() { # <doc> -> 0 + summary if consistent; else nonzero (message on stderr)
  local doc="${1:?doc}"
  _structural_consistency "$doc" || exit 1
  local nf; nf="$(awk '$1=="finding"{c++} END{print c+0}' "${doc}.manifest")"
  echo "verify: ${doc} consistent — ${nf} findings, doc matches manifest"
}

cmd_merge() {
  local round="" doc="" copies=() quarantined=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --round) [[ $# -ge 2 ]] || die "--round requires a value" 2; round="$2"; shift 2 ;;
      --quarantined) [[ $# -ge 2 ]] || die "--quarantined requires a value" 2; quarantined+=("$2"); shift 2 ;;
      *) if [[ -z "$doc" ]]; then doc="$1"; else copies+=("$1"); fi; shift ;;
    esac
  done
  [[ "$round" =~ ^[0-9]+$ ]] || die "--round <N> required (integer)" 2
  [[ -n "$doc" && -f "$doc" ]] || die "merge: doc not found: ${doc:-<none>}" 1

  # Validate every --quarantined arg NOW, before the doc is touched. Validating it later — in the
  # loop that writes the records — meant a malformed arg died AFTER the findings block had already
  # been appended, leaving a mutated doc with no manifest: a partial merge that a retry would
  # duplicate. "Fail loud at the source" has to mean before the first write, not before the last.
  #
  # The grammar these guard is the record's own: a provider outside [a-z0-9]+, an arg with no
  # colon (which makes the whole string the "reason" and sails past a non-blank check), a blank
  # reason, a `·` (the field separator), or any control character (the record is ONE line) each
  # produce a record every _quarantines reader silently drops — re-opening #26's invisibility
  # through whichever field was left unchecked.
  local _q _qp _qr
  for _q in "${quarantined[@]:-}"; do
    [[ -z "$_q" ]] && continue
    [[ "$_q" == *:* ]] || die "merge: --quarantined must be <provider>:<reason>, got '${_q}'" 2
    _qp="${_q%%:*}"; _qr="${_q#*:}"
    [[ "$_qp" =~ ^[a-z0-9]+$ ]] \
      || die "merge: quarantine provider '${_qp}' must match [a-z0-9]+ (the record grammar); a record with any other provider is silently unreadable" 2
    [[ -n "${_qr//[[:space:]]/}" ]] || die "merge: quarantine reason for '${_qp}' is empty — give a reason" 2
    [[ "$_qr" != *·* ]] || die "merge: quarantine reason for '${_qp}' must not contain '·' (the field separator)" 2
    [[ "$_qr" =~ ^[^[:cntrl:]]+$ ]] \
      || die "merge: quarantine reason for '${_qp}' contains a control character (newline/tab); the record is one line" 2
  done

  # Refuse to merge onto a doc already inconsistent with its manifest — fail loud at THIS
  # handoff rather than compounding the corruption into later rounds (issue #16). Round 1 has
  # no manifest yet, so this is a no-op there.
  if [[ -f "${doc}.manifest" ]]; then
    _structural_consistency "$doc" \
      || die "merge: refusing to merge — '$doc' is inconsistent with its manifest (run: $(basename "$0") verify '$doc')" 1
  fi

  local block="" copy provider
  for copy in "${copies[@]}"; do
    [[ -f "$copy" ]] || die "merge: copy not found: $copy" 1
    provider="$(provider_of_copy "$doc" "$copy")" || exit $?
    block="${block}$(namespace_blocks "$provider" "$round" "$copy")"$'\n'
  done

  # append the namespaced blocks after the LAST "## Review" heading. Pass $block via the
  # ENVIRONMENT (ENVIRON[]) — NOT `awk -v add=...`, which escape-processes C sequences and would
  # turn a literal "\n"/"\t"/"\\" in a finding's text into a real newline/tab, corrupting the
  # byte-verbatim guarantee (and then hashing the corrupted form). ENVIRON values are not
  # escape-processed. (r11)
  local tmp; tmp="$(mktemp "${doc}.tmp.XXXXXX")" || die "cannot create temp for: $doc" 1
  ADD_BLOCK="$block" awk '
    { lines[NR]=$0; if ($0 ~ /^## Review[[:space:]]*$/) last=NR }
    END {
      for (i=1;i<=NR;i++) {
        print lines[i]
        if (i==last) { print ""; printf "%s", ENVIRON["ADD_BLOCK"] }
      }
    }
  ' "$doc" > "$tmp" && mv "$tmp" "$doc" || { rm -f "$tmp"; die "merge: failed to write $doc" 1; }

  # collect the ns-ids just merged THIS round — read them from $block (the content appended
  # this round), NOT by grepping the whole doc for a "-rd${round}-" substring. A substring grep
  # is unanchored and would falsely re-match a prior-round id whose own text happens to contain
  # "-rd${round}-" (e.g. a secondary that named a finding "bug-rd2-fix" → "codex-rd1-bug-rd2-fix"
  # matches round 2). Sourcing from $block is unambiguous — those are exactly this round's blocks.
  local nsids id line mirror="" qline
  nsids="$(printf '%s' "$block" \
    | grep -oE '^> \[finding:[^]|]+' | sed -E 's/^> \[finding://' || true)"
  : > "${doc}.manifest.tmp" || true
  # cumulative: preserve prior manifest lines
  [[ -f "${doc}.manifest" ]] && cat "${doc}.manifest" >> "${doc}.manifest.tmp"
  for id in $nsids; do
    line="${id}=$(finding_block_hash "$doc" "$id")"
    echo "finding ${line}" >> "${doc}.manifest.tmp"
    mirror="${mirror}${line} "
  done

  # quarantine records (durable in-doc) + manifest binding. Manifest key is round-qualified
  # (<provider>-rd<round>): the durable in-doc record already is ("round ${round}"), and the
  # SAME provider can be quarantined in more than one round, each with its own record — a
  # provider-only key would collide across rounds in guard (d) (see cmd_check_converged).
  local qprovider qreason qmirror=""
  for q in "${quarantined[@]:-}"; do
    [[ -z "$q" ]] && continue
    qprovider="${q%%:*}"; qreason="${q#*:}"
    # Canonical quarantine-record format (parsed by check-converged guard (d), the gate-summary
    # readability list, and the independence scan): "star-quarantined: <provider> · <reason> ·
    # round <N>". <provider> is a registry key ([a-z0-9]+); <reason> may contain spaces ([^·]+);
    # <N> is [0-9]+. Every reader keys off this exact shape — keep them in step if it changes.
    qline="<!-- star-quarantined: ${qprovider} · ${qreason} · round ${round} -->"
    printf '%s\n' "$qline" >> "$doc"           # durable record
    echo "quarantine ${qprovider}-rd${round}=$(printf '%s' "$qline" | sha)" >> "${doc}.manifest.tmp"
    qmirror="${qmirror}${qprovider}=$(printf '%s' "$qline" | sha) "
  done
  mv "${doc}.manifest.tmp" "${doc}.manifest"

  # in-doc human-readable mirror (NOT trusted for integrity — see check-converged)
  printf '<!-- star-findings: %s; quarantined: %s -->\n' "${mirror% }" "${qmirror% }" >> "$doc"

  # Post-merge self-check: the doc + manifest we just wrote must be mutually consistent (issue #16).
  # This can only fail on a genuine merge bug (a correct merge writes a consistent doc), so — like
  # the terminal gate's own guardrail — we FAIL LOUD and leave the doc as-is for diagnosis rather
  # than rolling back (an earlier rollback attempt was itself a data-loss hazard; #17). The pre-check
  # already prevents building on pre-existing corruption.
  _structural_consistency "$doc" \
    || die "merge: post-merge self-check failed for '$doc' — the merge produced an inconsistent state; left in place for diagnosis" 1
}

cmd_check_converged() {
  local doc="${1:?doc}" mstate t
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  [[ -f "${doc}.manifest" ]] || exit 1     # no manifest -> never merged -> not converged

  # marker must be converged (delegate to core.sh's reader)
  mstate="$("${STAR_DIR}/multi-review-core.sh" marker "$doc" 2>/dev/null | awk '{print $1}')"
  [[ "$mstate" == "converged" ]] || exit 1

  # Structural consistency — the SAME helper the handoff self-check (verify/merge) uses: grammar,
  # finding id-set, per-finding block hashes, footer shape, and quarantine-record integrity. One
  # implementation, so the terminal gate and the handoff can never diverge (#17: they did — verify's
  # quarantine check got fence-scoped while this one didn't — and that was a bug). Silent: this
  # command signals only via exit code.
  _structural_consistency "$doc" >/dev/null 2>&1 || exit 1

  # parse the table for the convergence-only checks below (grammar already validated above)
  t="$(_table "$doc")" || exit 1

  # (a) coverage: every finding has exactly one response (state != open)
  printf '%s\n' "$t" | awk -F'\t' '$3 == "open" { exit 1 }' || exit 1

  # (e) single primary (c1): every response must come from the SAME model. Guard (a) already
  #     requires one response per finding and _table's self-response guard already blocks a
  #     finding's own raiser from answering it — but neither pins all responses to ONE
  #     consistent identity, so finding A could be answered by model X and finding B by a
  #     different model Y (both non-raisers) and still "converge". Collect the distinct
  #     non-empty responder ids (column 4) across all findings; more than one -> not converged.
  #     Zero is fine (zero findings -> zero responders; coverage already forbids a partial mix).
  local distinct_responders
  distinct_responders="$(printf '%s\n' "$t" | awk -F'\t' 'NF>=4 && $4!="" {print $4}' | sort -u | grep -c .)"
  [[ "$distinct_responders" -le 1 ]] || exit 1

  exit 0
}

cmd_gate_summary() {
  local doc="${1:?doc}" primary="${2:?primary-model-id}" t flag_independence=0
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flag-independence) flag_independence=1; shift ;;
      *) die "gate-summary: unknown argument: $1" 2 ;;
    esac
  done
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  t="$(_table "$doc")" || die "gate-summary: contract violation in $doc" 1

  # ratio + disputes + agreed, from the table
  printf '%s\n' "$t" | awk -F'\t' '
    function emit(want,   lvl,i,levels){ split("high med low",levels," ");
      for(lvl=1;lvl<=3;lvl++) for(i=1;i<=n;i++) if(st[i]==want && sv[i]==levels[lvl]) print txt[i] }
    { n++; id[n]=$1; raiser[n]=$2; st[n]=$3; resp[n]=$4; concern[n]=$5; why[n]=$6; sv[n]=$7; risk[n]=$8
      if($3=="agreed")a++; else if($3=="dissent")d++
      emoji=(sv[n]=="high")?"🔴":(sv[n]=="med")?"🟠":"🟡"
      if($3=="dissent") txt[n]=emoji " " sv[n] " — " concern[n] " (via " raiser[n] ") — primary disputes: " why[n]
      else txt[n]=emoji " " sv[n] " — " concern[n] " (via " raiser[n] ")"
      # count SECONDARIES (providers), not model strings (r10): the provider is the ns-id prefix
      # before "-rd" (ids are <provider>-rd<N>-<rawid>). raiser is the model, which can collide.
      split($1, pp, "-rd"); secs[pp[1]]=1
    }
    END {
      ns=0; for(s in secs)ns++
      printf "Primary agreed with %d findings, DISPUTED %d (of %d across %d secondaries).\n\n", a+0, d+0, n+0, ns
      if(d>0){ print "Disputes (high→low):"; emit("dissent"); print "" }
    }'

  # Evidentiary quality of the review, not just its findings. A `high`/`med` claim with no stated
  # mechanism is the shape that was consistently speculative (issue #29), and the gate is where a
  # human decides how much weight the review deserves — so the count belongs here rather than
  # only in the primary's own turn. Dormant when there is nothing to report.
  local egaps; egaps="$(cmd_evidence_gaps "$doc" 2>/dev/null)"
  if [[ -n "$egaps" ]]; then
    echo "Findings asserting high/med severity without evidence ($(printf '%s\n' "$egaps" | grep -c .)):"
    printf '%s\n' "$egaps" | awk 'NF{ printf "  - %s (%s)\n", $1, $2 }'
    echo
  fi

  # quarantined secondaries (readability channel: the in-doc records, via the shared parser)
  local qlist; qlist="$(_quarantines "$doc")"
  if [[ -n "$qlist" ]]; then
    echo "Quarantined secondaries (findings excluded):"
    printf '%s\n' "$qlist" | awk -F'\t' 'NF{ printf "  - %s · %s · round %s\n", $1, $2, $3 }'
    echo
  fi

  # agreed findings, compactly
  printf '%s\n' "$t" | awk -F'\t' '
    $3=="agreed"{ printf "  agreed: %s — %s (via %s)\n", $7, $5, $2 }'

  # primary observations (human-gate only): never a finding, never affects convergence — dormant
  # (no heading printed) when the doc has none, so gate-summary is byte-identical without them.
  local obs
  obs="$(cmd_observations "$doc")" || die "gate-summary: contract violation in $doc" 1
  if [[ -n "$obs" ]]; then
    echo "Primary observations (human-gate only):"
    printf '%s\n' "$obs" | while IFS= read -r line; do echo "  - $line"; done
    echo
  fi

  echo "———"
  echo "🤖 Star review gate summary — primary ${primary}. Human gate decides; nothing auto-merges."

  if (( flag_independence )); then
    # Admitted providers come from the DOCUMENT's finding ns-id prefixes (same
    # <provider>-rd<N>-<id> split the awk summary above already uses for secs[]) — not a
    # manifest sidecar — so gate-summary stays standalone over just <doc> <primary-model-id>.
    local admitted_providers pvendor admitted_xvendor=0 p v q_xvendor qp qv
    admitted_providers="$(printf '%s\n' "$t" | awk -F'\t' 'NF{p=$1; sub(/-rd.*/,"",p); print p}' | sort -u)"
    pvendor="$("$REVIEWER_SH" vendor-of-model "$primary" 2>/dev/null || echo unknown)"
    for p in $admitted_providers; do
      v="$("$REVIEWER_SH" resolve --reviewer "$p" 2>/dev/null | cut -d'|' -f2)"
      [[ -n "$v" && "$v" != "$pvendor" ]] && admitted_xvendor=1
    done
    if (( ! admitted_xvendor )); then
      q_xvendor="$(_quarantines "$doc" | cut -f1 | sort -u \
        | while read -r qp; do [[ -z "$qp" ]] && continue; qv="$("$REVIEWER_SH" resolve --reviewer "$qp" 2>/dev/null | cut -d'|' -f2)"; [[ -n "$qv" && "$qv" != "$pvendor" ]] && echo "$qp"; done | head -1)"
      if [[ -n "$q_xvendor" ]]; then
        echo "⚠ Independence: a cross-vendor secondary (${q_xvendor}) was attempted but quarantined — this run has no independent cross-vendor perspective."
      else
        echo "⚠ Independence: reviewed only by same-vendor secondaries — no independent cross-vendor perspective this run. Add --reviewers codex (or gemini) for architectural independence."
      fi
    fi
  fi
}

# round-stats — per-round × per-provider admitted-finding counts, the trend between rounds, and
# per-provider dry streaks. A PURE READ: every number comes from the doc's own ns-ids
# (<provider>-rd<N>-<id>) plus its durable quarantine records. No new state, no manifest.
#
# Why a trend and not just a count (issue #22). The re-fan rule was "re-fan while the previous
# round produced ≥1 new admitted finding", i.e. loop-until-dry. Loop-until-dry terminates only if
# the reviewed artifact holds still. This one does not: the primary turn REQUIRES addressing each
# agreed finding in the doc body before the next fan-out, so round N+1 reviews prose written
# during round N. Every round supplies fresh, never-reviewed text; the rate can flatten instead of
# decaying, and a dry round is not reachable by construction — only the ceiling is. Observed over
# five rounds on one design doc: 9, 3, 3, 3, 3. Surfacing the trend lets the primary stop on
# evidence instead of grinding to MULTI_REVIEW_MAX_ROUNDS.
#
# The round count comes from the MARKER, not from the highest round seen in the ns-ids: a round in
# which every secondary found nothing merges no findings and is therefore invisible in the doc.
# Sourcing it from the ids would silently drop exactly the round that means "converge".
#
# Provider columns are the union of the mode hint's `reviewers:` list, providers that raised a
# finding, and providers with a quarantine record. A provider that was in the set, was never
# quarantined, and found nothing in ANY round is visible only via the hint — outside that, the
# doc holds no record it ran.
cmd_round_stats() {
  local doc="${1:?doc}" marker state round max t quar hintp
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  marker="$("${STAR_DIR}/multi-review-core.sh" marker "$doc" 2>/dev/null)" \
    || die "no valid multi-review marker in: $doc" 1
  state="$(awk '{print $1}' <<<"$marker")"
  round="$(awk '{print $2}' <<<"$marker")"; max="$(awk '{print $3}' <<<"$marker")"

  # The state is not decoration — a verdict is only meaningful once the round's findings are
  # merged. On `awaiting-secondaries` the current round has fanned out but merged nothing, so it
  # carries no ns-ids; reading that as a zero count produced a confident
  # "converge — round N went dry" for a round still in flight. Refuse loudly instead.
  case "$state" in
    awaiting-primary|converged|exhausted) : ;;
    *) die "round-stats needs a merged round: marker says '${state}' (round ${round} is still in flight — nothing merged yet). Run it in the primary turn, after merge." 1 ;;
  esac
  t="$(_table "$doc")" || die "round-stats: contract violation in $doc" 1

  # Shared parser (fence-aware) -> the "provider round" pairs this awk expects.
  quar="$(_quarantines "$doc" | awk -F'\t' 'NF{print $1, $3}')"
  # `reviewers:` list off the mode hint; `[^-]*` stops at the `-->` (provider ids are [a-z0-9]).
  hintp="$(header_region "$doc" | grep -o 'reviewers:[^-]*' | head -1 | sed 's/reviewers://' || true)"

  # quar/hintp go through the ENVIRONMENT, not `awk -v`: -v values cannot contain a literal
  # newline (two quarantine records in one doc made awk die "newline in string"), and -v also
  # escape-processes backslashes. Same reason cmd_merge passes its block via ENVIRON.
  printf '%s\n' "$t" | RS_QUAR="$quar" RS_HINTP="$hintp" awk -F'\t' -v rounds="$round" -v maxr="$max" '
    BEGIN {
      nq = split(ENVIRON["RS_QUAR"], ql, "\n")
      for (i = 1; i <= nq; i++) {
        if (ql[i] == "") continue
        split(ql[i], q, " "); Q[q[1] SUBSEP (q[2]+0)] = 1; provs[q[1]] = 1
      }
      np = split(ENVIRON["RS_HINTP"], hp, " ")
      for (i = 1; i <= np; i++) if (hp[i] != "") provs[hp[i]] = 1
    }
    NF {
      # provider is the ns-id prefix before "-rd"; round is the digits that follow it. Same
      # split gate-summary uses, so the two can never disagree about who raised what.
      split($1, pp, "-rd")
      p = pp[1]; r = pp[2]; sub(/-.*/, "", r)
      if (p == "" || r+0 < 1) next
      C[p SUBSEP (r+0)]++; provs[p] = 1
    }
    END {
      n = 0; for (p in provs) sorted[++n] = p
      for (i = 2; i <= n; i++) { v = sorted[i]; j = i - 1
        while (j >= 1 && sorted[j] > v) { sorted[j+1] = sorted[j]; j-- }
        sorted[j+1] = v }

      # Per round: raw admitted total, and how many providers were admitted at all.
      for (r = 1; r <= rounds; r++) {
        tot[r] = 0; nadm[r] = 0
        for (i = 1; i <= n; i++) {
          p = sorted[i]
          if ((p SUBSEP r) in Q) continue
          nadm[r]++; tot[r] += C[p SUBSEP r] + 0
        }
      }

      # The trend must compare LIKE WITH LIKE. Raw totals move with the admitted-provider set, so
      # a single quarantine can make a still-decaying review read as flat or rising. Compare only
      # the providers admitted in BOTH of the two rounds being compared.
      # Was anyone silenced in the FINAL round? That, not the comparison window, is what makes a
      # dry reading partial — and unlike cmp_partial it is defined for round 1 too.
      qcur = 0
      for (i = 1; i <= n; i++) if ((sorted[i] SUBSEP rounds) in Q) qcur = 1

      cmp_ok = 0; cmp_prev = 0; cmp_last = 0; cmp_partial = 0
      if (rounds >= 2) {
        for (i = 1; i <= n; i++) {
          p = sorted[i]
          if ((p SUBSEP rounds) in Q || (p SUBSEP (rounds-1)) in Q) { cmp_partial = 1; continue }
          cmp_ok = 1
          cmp_prev += C[p SUBSEP (rounds-1)] + 0
          cmp_last += C[p SUBSEP rounds] + 0
        }
      }

      for (r = 1; r <= rounds; r++) {
        line = "rd" r
        for (i = 1; i <= n; i++) {
          p = sorted[i]
          if ((p SUBSEP r) in Q) line = line "  " p " q"      # never spoke — not a zero
          else line = line "  " p " " (C[p SUBSEP r] + 0)
        }
        line = line "  = " tot[r]
        if (r >= 2) {
          # The glyph is the row headline at the gate, so it must rest on the SAME basis as the
          # verdict: the providers admitted in both compared rounds. Comparing raw totals here
          # printed `↑ rising` directly above `verdict: re-fan — still decaying` whenever a
          # quarantine moved the denominator.
          sp = 0; sl = 0; any = 0
          for (i = 1; i <= n; i++) {
            p = sorted[i]
            if ((p SUBSEP r) in Q || (p SUBSEP (r-1)) in Q) continue
            any = 1; sp += C[p SUBSEP (r-1)] + 0; sl += C[p SUBSEP r] + 0
          }
          # Dryness and direction are different questions. DRY means nothing was admitted at
          # all, which is the raw total; DIRECTION is only meaningful on the comparable subset.
          # Keying dryness off the subset printed `✗ dry` on a round that plainly found things,
          # whenever a provider quarantined in r-1 returned in r (subset -> 0, raw > 0).
          if (nadm[r] == 0)      line = line "  ‼ all-quarantined"
          else if (tot[r] == 0)  line = line "  ✗ dry"
          else if (!any)         line = line "  ? no comparable provider"
          else if (sl < sp)      line = line "  ↓ decaying"
          else if (sl == sp)     line = line "  → flat"
          else                   line = line "  ↑ rising"
        }
        print line
      }

      # Per-provider dry streak: consecutive MOST RECENT rounds with zero findings. A quarantined
      # round breaks the streak rather than extending it — the provider never got to speak, so it
      # is no evidence of saturation, and counting it would advise dropping a reviewer that was
      # merely broken that round.
      streaks = ""
      for (i = 1; i <= n; i++) {
        p = sorted[i]; s = 0
        for (r = rounds; r >= 1; r--) {
          if ((p SUBSEP r) in Q) break
          if (C[p SUBSEP r] + 0 > 0) break
          s++
        }
        if (s >= 2) streaks = streaks "  " p " " s
      }
      if (streaks != "") print "dry-streak:" streaks

      if (rounds >= 2 && cmp_partial && cmp_ok)
        print "note: trend computed on the providers admitted in BOTH rounds " (rounds-1) " and " rounds " (" cmp_prev " → " cmp_last "); a quarantine changed the raw totals, which are not comparable"

      if (nadm[rounds] == 0)
        v = "stop — every secondary was quarantined in round " rounds "; nobody reviewed, so this is absence of evidence, not a dry round (protocol anomaly stop)"
      else if (rounds + 0 >= maxr + 0)
        v = "converge — round ceiling " maxr " reached"
      else if (tot[rounds] == 0 && qcur)
        v = "converge — round " rounds " went dry for every ADMITTED provider, but some were quarantined and never spoke; treat the dry reading as partial and check the quarantine reasons at the gate"
      else if (tot[rounds] == 0)
        v = "converge — round " rounds " went dry"
      else if (rounds + 0 < 2)
        v = "re-fan — round 1, no trend yet"
      else if (!cmp_ok)
        v = "re-fan — no provider was admitted in both rounds " (rounds-1) " and " rounds ", so there is no comparable trend"
      else if (cmp_last < cmp_prev)
        v = "re-fan — the finding rate is still decaying (" cmp_prev " → " cmp_last ")"
      else if (cmp_last == cmp_prev)
        v = "converge — the finding rate went flat at round " rounds " (" cmp_prev " → " cmp_last ")"
      else
        # A RISE is not saturation. It usually means the between-round edits made by the primary
        # introduced new problems, so it stops the loop for a different reason than a plateau and
        # the human gate should be able to tell the two apart. NB: no apostrophes in this awk
        # program — it is single-quoted in the shell, and one would terminate it.
        v = "converge — the finding rate ROSE at round " rounds " (" cmp_prev " → " cmp_last "); the new findings most likely concern the between-round edits, not the original doc — review them at the gate"
      print "verdict: " v
    }'
}

# evidence-gaps — high/med findings that assert a defect without stating how it is known.
#
# Measured across four reviews (issue #29): what separated the findings worth acting on from the
# speculative ones was a demonstrated failure MECHANISM, not the vendor or the severity tag. So
# `high`/`med` carry `> — evidence:`; `low` need not.
#
# Deliberately a REPORT, not a gate. Rejecting an undocumented finding at parse time would fail
# the whole reviewer turn and throw away its real findings with the weak ones — the same
# lose-a-round failure this project has had to undo repeatedly. The primary sees the gaps and
# adjudicates them (a claim with no demonstrated failure mode is disputable); the human sees them
# at the gate. Neither is silent, and neither is destructive.
cmd_evidence_gaps() { # <doc> -> "<ns-id> <sev>" per undocumented high/med finding
  local doc="${1:?doc}" t
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  t="$(_table "$doc")" || die "evidence-gaps: contract violation in $doc" 1
  printf '%s\n' "$t" | awk -F'\t' 'NF && ($7=="high" || $7=="med") && $9=="" { print $1, $7 }'
}

# remember-set --pref-file <path> (--reviewers <csv> | --clear)
# Persist (or revoke) the user's explicit extra-reviewer choice. --reviewers: registry-validate
# (NOT availability — the read path in resolve-set handles availability), strip fable, dedup,
# full-replace; an explicitly-empty set -> no-op; a non-empty MULTI_REVIEW_REVIEWERS shadows the
# pref so the write is a no-op + notice. --clear: delete the pref (deliberate revoke), ignoring the
# env guard. Exactly one of --reviewers/--clear is required (codex-rd1-r2/r3).
cmd_remember_set() {
  local pref="" csv="" have_reviewers=0 clear=0 id seen="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pref-file) [[ $# -ge 2 ]] || die "--pref-file requires a value" 2; pref="$2"; shift 2 ;;
      --reviewers) [[ $# -ge 2 ]] || die "--reviewers requires a value" 2; csv="$2"; have_reviewers=1; shift 2 ;;
      --clear)     clear=1; shift ;;
      *) die "remember-set: unexpected argument: $1" 2 ;;
    esac
  done
  [[ -n "$pref" ]] || die "remember-set requires --pref-file <path>" 2
  # Exactly one of --reviewers / --clear, keyed on flag PRESENCE (not csv value) so that both
  # "neither given" and "--clear --reviewers ''" are rejected (codex-rd1-r2, codex-rd1-r3).
  (( have_reviewers + clear == 1 )) \
    || die "remember-set requires exactly one of --reviewers <csv> or --clear" 2
  if (( clear )); then
    rm -f "$pref"                      # deliberate revoke; ignores the env guard by design
    return 0
  fi
  # Env-shadow guard: a non-empty MULTI_REVIEW_REVIEWERS shadows the pref on every later bare run,
  # so writing it would be a dead write. "Set" = non-empty (an exported "" is treated as unset).
  if [[ -n "${MULTI_REVIEW_REVIEWERS:-}" ]]; then
    echo "multi-review-star: MULTI_REVIEW_REVIEWERS is set — it shadows the remembered combo on bare runs; not writing pref (unset it to use the pref)" >&2
    return 0
  fi
  set -f                               # no globbing on a '*' in the csv (fable-rd3-r5)
  for id in $(printf '%s' "$csv" | tr ',' ' '); do
    [[ "$id" == "fable" ]] && continue
    case " $seen " in *" $id "*) continue ;; esac
    "$REVIEWER_SH" resolve --reviewer "$id" >/dev/null 2>&1 \
      || { set +f; die "remember-set: unknown reviewer provider: ${id}" 2; }
    seen="$seen $id"; out="${out}${id},"
  done
  set +f
  out="${out%,}"
  [[ -n "$out" ]] || return 0          # empty extras -> no-op: never create or truncate
  mkdir -p "$(dirname "$pref")"
  printf '%s\n' "$out" > "$pref"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    mode) cmd_mode "$@" ;;
    resolve-set) cmd_resolve_set "$@" ;;
    remember-set) cmd_remember_set "$@" ;;
    available) cmd_available "$@" ;;
    open-findings) cmd_open_findings "$@" ;;
    observations) cmd_observations "$@" ;;
    merge) cmd_merge "$@" ;;
    verify) cmd_verify "$@" ;;
    check-converged) cmd_check_converged "$@" ;;
    gate-summary) cmd_gate_summary "$@" ;;
    round-stats) cmd_round_stats "$@" ;;
    evidence-gaps) cmd_evidence_gaps "$@" ;;
    channel-check) cmd_channel_check "$@" ;;
    compose-review) cmd_compose_review "$@" ;;
    compose-inline) cmd_compose_inline "$@" ;;
    *)    die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
