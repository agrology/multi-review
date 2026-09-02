#!/usr/bin/env bash
# multi-review-star.sh — N-party "star" grammar & convergence (Claude primary + N secondaries).
# Sibling to core.sh/peer.sh; owns ONLY star's grammar/merge/convergence/summary. Subcommands:
#   mode <doc>              -> "star" | (defer: empty, exit 1)
#   resolve-set [--reviewers csv]
#   remember-set --pref-file <path> (--reviewers <csv> | --clear)
#   available
#   open-findings <doc>
#   observations <doc>
#   resolved <doc>          -> "ns-id\tnote\tmodel" per `> [resolved:]` record (issue #88)
#   merge --round N [--quarantined p:reason ...] [--pass <copy> ...] <doc> <copy> ...
#   check-converged <doc>
#   gate-summary <doc> <primary-model-id>
#   round-stats <doc>       -> per-round × per-provider finding counts, trend, dry streaks,
#                              and a converge/re-fan verdict (advisory; pure read)
#   evidence-gaps <doc>     -> high/med findings lacking a "> — evidence:" line (report, not gate)
#   witness-gaps <doc>      -> agrees/resolved records whose "> — witness:" is missing or does not
#                              resolve (report, not gate)
#   refan-check <doc>       -> exit 1 on a CURRENT-round witness gap; run before the re-fan bump
#   blind-check <copy>      -> exit 1 if a SEEDED copy still carries a previous round's
#                              findings/responses (issue #39); the reviewer would not be blind
#   channel-check --seed <seed> <copy> -> exit 1 if a reviewer's findings landed outside the
#                              merged '## Review' channel (issue #32); the turn would merge clean
#   compose-review <doc> <primary-model-id>  -> neutral PR review body (dormant; Task A4)
#   compose-inline <doc>                     -> "path\tstart\tend\tbody" per agreed+anchored
#                                                finding (dormant; Task A4)
set -uo pipefail

die() { echo "multi-review-star: $1" >&2; exit "${2:-1}"; }

# MULTI_REVIEW_FABLE — operator switch for the fable FLOOR (the implicit union), not for fable
# itself. Unset/on reproduces the historical behaviour exactly. off suppresses the floor, so
# fable is included only when a source NAMES it. An unrecognized value is fatal on purpose:
# silently reading it as "on" would restore the in-harness token spend the switch exists to stop,
# with no signal to the operator that their setting did nothing.
_fable_floor_enabled() {            # -> 0 floor applies, 1 suppressed; exits 2 on a bad value
  local v="${MULTI_REVIEW_FABLE:-on}"
  # LC_ALL=C: an unpinned fold has already produced a locale bug in this repo (vendor_of_model).
  v="$(printf '%s' "$v" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$v" in
    on|1|true)   return 0 ;;
    off|0|false) return 1 ;;
    *) die "MULTI_REVIEW_FABLE: unrecognized value '${MULTI_REVIEW_FABLE:-}' (want on|1|true or off|0|false)" 2 ;;
  esac
}

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

# STAR_PASSES — the single source of truth for which namespace prefixes are PASSES (mechanical,
# non-perspective dispatches like crossref) rather than reviewer PROVIDERS. `merge --pass` below
# validates a pass copy's id against this instead of the reviewer registry (spec §0 forbids
# registering a pass as a provider), and Task 6's gate exclusion reads it too — one literal, not
# two that can drift apart. Space-separated, same shape as the roster suffix (STAR_RE's
# `reviewers:` list): [a-z0-9]+ ids.
STAR_PASSES="crossref symcheck"

# The reviewer ROSTER, off the star mode hint: who was dispatched, independent of who raised a
# finding. gate-summary needs this because "provider that raised a finding" is not "provider that
# reviewed" — they diverge exactly when a reviewer is clean (issue #59).
#
# Four cases, deliberately distinct (codex-rd2-r1, codex-rd1-r1). Returning empty for a MALFORMED
# hint would trade garbage output for silently-missing output, and nothing else would catch it:
# cmd_mode is the only caller that validates the hint, and neither cmd_round_stats nor the gate
# path calls it.
#   no STAR_GREP line at all -> empty  (legitimate: a doc armed before the suffix existed)
#   more than one STAR_GREP line -> die (ambiguous; cmd_mode rejects it too)
#   STAR_GREP line failing STAR_RE -> die (malformed)
#   STAR_RE match -> the reviewers suffix, one id per line (itself possibly empty)
#
# The count guard mirrors cmd_mode below on purpose: this helper is the ONLY validation the
# round-stats and gate paths get, so anything cmd_mode rejects it must reject too. Taking the
# first of two hints would also silently pick one of two rosters (codex-rd1-r1).
_roster() { # <doc> -> provider ids, one per line
  local doc="${1:?doc}" hdr n line sfx
  hdr="$(header_region "$doc")"
  n="$(printf '%s\n' "$hdr" | grep -cE "$STAR_GREP" || true)"
  (( n == 0 )) && return 0
  (( n == 1 )) || die "multiple star mode hints in header: ${doc}" 1
  line="$(printf '%s\n' "$hdr" | grep -E "$STAR_GREP" | head -1)"
  [[ "$line" =~ $STAR_RE ]] || die "malformed star mode hint in ${doc}: ${line}" 1
  sfx="${BASH_REMATCH[1]}"
  [[ -n "$sfx" ]] || return 0
  # STAR_RE pins the suffix to [a-z0-9 ]+, so word-splitting it cannot glob or inject.
  # shellcheck disable=SC2086
  printf '%s\n' ${sfx#*reviewers:}
}

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

# _crossref_coverage <doc> -> "not applicable" | "N/M rows verdicted", or empty if the
# cross-reference pass never recorded a durable line for this doc. One line per round, written
# by commands/multi-review.md step 8 alongside the round's quarantine records (#90); the gate
# shows the LAST one, same "most recent round wins" read the rest of gate-summary uses.
_crossref_coverage() { # <doc> -> "not applicable" | "N/M rows verdicted"
  review_section "$1" | strip_fences /dev/stdin \
    | grep -oE '^> \[crossref-coverage: (not applicable|[0-9]+/[0-9]+ rows verdicted)\]' \
    | sed -E 's/^> \[crossref-coverage: (.*)\]$/\1/' \
    | tail -1
}

# _symcheck_coverage <doc> — the symbol-check pass's durable line (#89), read exactly the way
# _crossref_coverage reads its own. Separate function rather than a parameterised one: the
# crossref reader carries a passing mutation entry, and rewriting it to take a prefix would move
# that line for no behavioural gain (plan Deviation 1's reasoning, applied to the gate).
_symcheck_coverage() { # <doc> -> "not applicable" | "N/M rows verdicted"
  review_section "$1" | strip_fences /dev/stdin \
    | grep -oE '^> \[symcheck-coverage: (not applicable|[0-9]+/[0-9]+ rows verdicted)\]' \
    | sed -E 's/^> \[symcheck-coverage: (.*)\]$/\1/' \
    | tail -1
}

STAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for tests (dependency injection of the reviewer-helper PATH — not a behavior hook).
REVIEWER_SH="${MULTI_REVIEW_REVIEWER_SH:-${STAR_DIR}/multi-review-reviewer.sh}"

# Emitted only when MULTI_REVIEW_FABLE=off left the set empty. Reasons are the reviewer helper's
# own `check` stderr — the same strings `doctor` prints — so this never invents a diagnosis it
# cannot stand behind, and it stays correct as provider readiness rules change.
_no_secondaries_notice() {
  local id reason
  echo "multi-review-star: no secondaries available." >&2
  echo "  fable is disabled (MULTI_REVIEW_FABLE=${MULTI_REVIEW_FABLE:-})" >&2
  # ROSTER DUPLICATION: this list must stay in step with the one `doctor` walks in
  # multi-review-reviewer.sh. Adding a provider without updating both makes THIS diagnosis
  # silently incomplete — the operator is told why two providers are unusable and never hears
  # about the third. Left as a literal rather than refactored to a shared roster: extracting one
  # is a change to the registry's public surface, out of scope here, and the duplication predates
  # this function.
  # Report BOTH states. Listing only broken providers is useless in the dominant case — the
  # operator exported off and ran bare while a provider sat installed and merely unnamed, and a
  # refusal that mentions nothing gives them nothing to act on.
  for id in codex gemini; do
    if reason="$("$REVIEWER_SH" check --reviewer "$id" 2>&1 >/dev/null)"; then
      echo "  • ${id}: available — add --reviewers ${id}" >&2
    else
      echo "  ✗ ${id}: ${reason:-unavailable}" >&2
    fi
  done
  echo "" >&2
  echo "A star review needs at least one independent secondary. Either:" >&2
  echo "  --reviewers <id>          name an available provider" >&2
  echo "  MULTI_REVIEW_FABLE=on     re-enable fable (spends Claude tokens)" >&2
}

# The one machine-readable drop line, in the grammar `commands/multi-review.md` binds to
# `--quarantined <id>:<reason>` — mirroring the shell dispatch branch's `DISPATCH-FAILED <id>`.
#
# NORMALIZATION IS LOAD-BEARING, not cosmetic. `merge` validates a quarantine reason and DIES on
# anything it cannot store as one field of a one-line record: the whole `[:cntrl:]` class (not just
# newline and tab — CR and ESC reach here from a CLI writing to a pipe), the `·` field separator,
# and an empty reason. `check` stderr is routinely multi-line — gemini emits three hint lines today
# — so an unnormalized reason would abort the very merge this line exists to reach.
#
# It is a SEPARATE function because there are two consumers, and the second one is easy to miss:
# the emitter below, and the `refuse` accumulator in the refusal path. `refuse` is a newline-
# delimited, tab-separated record list, so a raw multi-line reason stored there does not merely
# look untidy — its embedded newlines ARE record separators, and the reader in Step 8 parses each
# continuation line as a new `<id>\t<reason>` pair. The refusal then names reviewers that do not
# exist and drops the real reasons (codex-rd1-r2, gemini-rd1-r1). Normalize at every boundary that
# stores or prints a reason; never store what `check` handed you.
# `·` is stripped with sed, NOT `tr -d`. `tr` operates on BYTES, and `·` is two bytes (0xC2 0xB7),
# so `tr -d '·'` deletes those bytes wherever they appear — including as parts of OTHER characters.
# Verified: `printf 'cost is £5' | tr -d '·'` strips the 0xC2 from `£` and leaves a lone 0xA3, an
# invalid UTF-8 sequence in the recorded reason. Any provider stderr carrying non-ASCII text hits
# this (fable-rd3-r3). Substituting a space also keeps words apart rather than fusing them.
# `LC_ALL=C` IS NOT COSMETIC EITHER. Under a UTF-8 locale — `LANG=en_US.UTF-8`, what this repo's
# machine and CI actually run — BSD `tr` and `sed` treat an invalid UTF-8 byte in the input as a
# fatal error: they print `tr: Illegal byte sequence` and STOP, so everything after the first bad
# byte is silently dropped. Provider stderr is arbitrary bytes, so this is reachable. Reproduced:
# the pipeline on `gemini failed: cost \243 5 exceeded\nhint: raise the cap` returns just
# `gemini failed: cost` — the visibility record loses its tail, which is the one thing this whole
# feature exists to produce (fable-rd4-r1). Under `LC_ALL=C` the same input returns the full
# collapsed line, `·` still strips (sed matches the 0xC2 0xB7 byte pair), and `£` still survives.
_norm_reason() { # <raw-reason> -> one clean line on stdout, never empty
  local r
  r="$(printf '%s' "${1:-}" | LC_ALL=C tr '[:cntrl:]' ' ' | LC_ALL=C sed 's/·/ /g; s/  */ /g; s/^ *//; s/ *$//')"
  printf '%s' "${r:-unavailable}"
}

_undispatchable() { # <id> <raw-reason>
  echo "multi-review-star: UNDISPATCHABLE ${1}: $(_norm_reason "${2:-}")" >&2
}

# resolve-set [--fable-floor] [--reviewers csv] [--pref-file path] [--allow-missing] [--resume]
# Source precedence: --reviewers(non-empty) > MULTI_REVIEW_REVIEWERS(non-empty) > pref-file(non-empty).
#
# TWO ORTHOGONAL RULES (the round-1 design fused them and reintroduced the defect it was closing):
#   VISIBILITY is unconditional — every dropped reviewer, every source, every reason, emits
#     `UNDISPATCHABLE <id>: <reason>`. No source is exempt and no flag suppresses it.
#   REFUSAL is conditional — only a FRESH ASK (flag/prose or env) refuses, with exit 4.
#     `pref` is a remembered convenience and `resume` is an in-flight roster: both proceed.
cmd_resolve_set() {
  local fable_floor=0 csv="" pref_file="" src="" raw="" seen="" id row out=""
  local allow_missing=0 resume=0 refuse="" why=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fable-floor) fable_floor=1; shift ;;
      --reviewers)   [[ $# -ge 2 ]] || die "--reviewers requires a value" 2; csv="$2"; shift 2 ;;
      --pref-file)   [[ $# -ge 2 ]] || die "--pref-file requires a value" 2; pref_file="$2"; shift 2 ;;
      # Downgrades a REFUSAL to a proceed. It does not touch visibility, because nothing does.
      --allow-missing) allow_missing=1; shift ;;
      # The caller declares an in-flight roster. resolve-set cannot infer it — `--reviewers` looks
      # identical whether the ids came from the engineer or from the doc header — and without it a
      # provider that went missing between sessions would exit 4 on every resume, making the review
      # permanently unresumable.
      --resume)        resume=1; shift ;;
      # Reject unknown args (parity with remember-set) so a typo'd flag can't silently disable the
      # pref feature instead of surfacing (fable-rd2-r2).
      *) die "resolve-set: unexpected argument: $1" 2 ;;
    esac
  done
  # `--resume` DECLARES the in-flight roster; resolve-set cannot infer one. Reject it without a
  # roster rather than proceeding, because the fall-through was SILENT and inverted the flag's
  # purpose: `src` became "resume" only inside the `[[ -n "$csv" ]]` branch below, so `--resume`
  # with an empty value dropped through to env -> pref -> floor as an ordinary fresh ask — and a
  # fresh ask REFUSES an undispatchable reviewer with exit 4, the exact outcome `--resume` exists
  # to prevent. Reachable from the command's own resume path whenever a doc header carries no
  # `reviewers:` suffix, which `_roster` treats as legitimate (fable-rd1-r2, #91).
  # TEST THE VALUE THE WAY THE CODE CONSUMES IT — after the same `tr ',' ' '` separator
  # normalization applied below — never by enumerating raw characters. Three holes shipped here
  # doing the latter: `-z "$csv"` missed whitespace-only (fable-rd1-r1), and the whitespace trim
  # that replaced it missed comma-only (codex-rd2-r1), each reproduced at rc=0 with a silent
  # fable-only roster. A fourth separator nobody has thought of cannot open a fourth hole, because
  # the check now asks the only question that matters: after normalization, is there an id left?
  local _resume_ids
  _resume_ids="$(printf '%s' "$csv" | tr ',' ' ')"
  if (( resume )) && [[ -z "${_resume_ids//[[:space:]]/}" ]]; then
    die "resolve-set: --resume requires --reviewers <ids> (it declares the in-flight roster and cannot infer one; a doc header with no 'reviewers:' suffix must be resumed by naming the set explicitly)" 2
  fi
  # Validate BEFORE any source selection, and regardless of --fable-floor: a typo'd value must
  # fail on every path, not only the one that happens to consult the floor.
  local floor_on=1
  _fable_floor_enabled || floor_on=0
  # Every source is comma-OR-space tolerant: `tr ',' ' '` on all three, so a csv env value
  # ("codex,gemini") splits the same as the flag and pref (fable-rd1-r1).
  if [[ -n "$csv" ]]; then
    raw="$(printf '%s' "$csv" | tr ',' ' ')"
    if (( resume )); then src="resume"; else src="flag"; fi
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
      # `resume` joins `pref` here: a roster naming a provider a later plugin version removed would
      # otherwise be unresumable through this gate — the same hole the source row closes, one step
      # earlier (fable-rd2-r5). Both are LOUD, because visibility never depends on the source: left
      # quiet, the id stays in the roster, is never quarantined, and `roster − quarantined` counts a
      # reviewer that never spoke (codex-rd3-r1, gemini-rd3-r1, fable-rd3-r4).
      if [[ "$src" == "pref" || "$src" == "resume" ]]; then
        seen="$seen $id"
        echo "multi-review-star: ${src} reviewer '$id' unknown — dropping" >&2
        _undispatchable "$id" "unknown reviewer id"
        continue
      fi
      set +f; die "unknown reviewer provider in set: ${id}" 2
    fi
    # AVAILABILITY IS CHECKED FOR EVERY SOURCE, not just the pref (issue #73). This gate used to
    # read `[[ "$src" == "pref" ]] && ! check`, so a reviewer named on the flag, in prose, or via
    # MULTI_REVIEW_REVIEWERS was only looked up in the registry — never probed. Reproduced: with
    # no gemini CLI installed, `check --reviewer gemini` exits 1 while `resolve-set --reviewers
    # gemini` returned `gemini|google|shell|...` and exit 0, so the run armed, dispatched a binary
    # that does not exist, and paid a full wait bound before quarantining it. #73 reports the same
    # shape for codex and attributes it to the missing dispatch agent; the agent is one instance,
    # and this is the hole.
    #
    # Visibility first, unconditionally: whatever we decide to DO about this reviewer, the fact
    # that it is not being dispatched is recorded the same way every time.
    if ! why="$("$REVIEWER_SH" check --reviewer "$id" 2>&1 >/dev/null)"; then
      seen="$seen $id"
      _undispatchable "$id" "$why"
      case "$src" in
        pref)   echo "multi-review-star: pref reviewer '$id' unavailable in this repo — dropping (pref unchanged)" >&2 ;;
        resume) echo "multi-review-star: roster reviewer '$id' is not dispatchable here — dropping (the review stays resumable)" >&2 ;;
        *)
          # A FRESH ASK. Refusing costs one re-run; proceeding costs a review the engineer did not
          # ask for and cannot see. Accumulate rather than dying here, so ONE message names every
          # unusable reviewer instead of revealing them one re-run at a time (fable-rd1-r4).
          if (( allow_missing )); then
            echo "multi-review-star: reviewer '$id' is not dispatchable here — proceeding without it (--allow-missing)" >&2
          else
            # NORMALIZE BEFORE STORING. `refuse` is newline-delimited and tab-separated, so a raw
            # multi-line `$why` would inject record boundaries and Step 8 would read each hint
            # line as another reviewer (codex-rd1-r2, gemini-rd1-r1). gemini emits three hint lines
            # today, so this is the common case, not the edge one.
            # On its OWN line, not inlined into the assignment below: the assignment already
            # carries `$'\t'` and `$'\n'`, and a mutation entry has to quote its target literally.
            why="$(_norm_reason "$why")"
            # $src carries the record's SOURCE ("flag" or "env" — the only two that reach here) so
            # the refusal below can name it. Without this the message reads "named for this run"
            # regardless of where the id actually came from — wrong when it was an exported
            # MULTI_REVIEW_REVIEWERS the operator never typed and cannot reach from the text
            # (ENGINEER DECISION).
            refuse="${refuse}${id}"$'\t'"${src}"$'\t'"${why}"$'\n'
          fi ;;
      esac
      continue
    fi
    seen="$seen $id"
    out="${out}${row}"$'\n'
  done
  set +f
  # After the loop, so the message is complete. The reason is printed inline: it is what `check`
  # already told us, and sending the engineer to a second command for information this one had is
  # what made the old notice easy to ignore.
  if [[ -n "$refuse" ]]; then
    {
      echo "multi-review-star: reviewer(s) for this run are not dispatchable here:"
      printf '%s' "$refuse" | while IFS="$(printf '\t')" read -r rid rsrc rwhy; do
        [[ -n "$rid" ]] || continue
        # src -> what the operator would type/set to reach this reviewer: "env" is the only
        # non-flag fresh-ask source, so everything else (just "flag") names --reviewers.
        case "$rsrc" in
          env) rlabel="MULTI_REVIEW_REVIEWERS" ;;
          *)   rlabel="--reviewers" ;;
        esac
        echo "  ${rid} (from ${rlabel}): ${rwhy}"
      done
      echo "Fix them, or re-run with --allow-missing to proceed without them."
    } >&2
    exit 4
  fi
  # floor_on comes from MULTI_REVIEW_FABLE. The floor is the IMPLICIT union only — a fable named
  # by flag/env/prose was already resolved by the loop above and is untouched here.
  if (( fable_floor && floor_on )); then
    case " $seen " in *" fable "*) : ;; *)
      row="$("$REVIEWER_SH" resolve --reviewer fable 2>/dev/null)" || die "fable unavailable" 2
      out="${out}${row}"$'\n' ;;
    esac
  fi
  # Empty set. Two distinct causes, and they must not be conflated: the LEGACY no-floor path
  # (a caller that never asked for a floor) stays quiet as before, while a set emptied BY the
  # switch gets the operator a diagnosis. Same exit code — the caller's routing is unchanged.
  if [[ -z "$out" ]]; then
    (( fable_floor && ! floor_on )) && _no_secondaries_notice
    exit 3
  fi
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
_table() { # <doc> -> "id\traiser\tstate\tresponder\tconcern\twhy\tsev\trisk\tevidence\twitness" per finding
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
            rverb[pi] = pv; rmodel[pi] = m; rwhy[pi] = pwhy; cur_response = pi
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
      # Optional `> — witness:` line (spec 2026-09-01 A1), credited to the RESPONSE whose block we
      # are still inside — never to a finding. Any control-shaped line clears it, so a witness
      # written after a [resolved:] or [observation] block cannot credit the agree above it. Never
      # fatal when absent, for the same reason the evidence line is not.
      if (line ~ /^> \[/) cur_response = ""
      if (line ~ /^> — witness:/) {
        if (cur_response != "") {
          w = line; sub(/^> — witness:[ ]*/, "", w); gsub(/[ \t]+$/, "", w)
          if (w != "") rwit[cur_response] = w
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
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, raiser[id], state, resp, fwhy[id], rwhy[id], fsev[id], frisk[id], fev[id], rwit[id]
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
cmd_observations() { # <doc> -> "text<TAB>model" per observation; exit 2 on an undisclosed observation
  local doc="${1:?doc}"
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  review_section "$doc" | strip_fences /dev/stdin | awk '
    function fail(m){ print "multi-review-star: " m > "/dev/stderr"; exit 2 }
    {
      line = $0
      if (pend) {
        # The match requires a NON-SPACE after "via " (PR #65, codex-rd1-r1). A bare "> — via "
        # used to match, strip to an empty model, and publish "— via " with nothing after it:
        # agent-authored content reaching a human with no model named, which is the one thing
        # CLAUDE.md section 8 requires. A model-less disclosure is no disclosure, so it takes the
        # same fail() path as a missing via line. The trailing sub() keeps stray spaces after a
        # real model out of the published line.
        if (line ~ /^> — via [^[:space:]]/) { via = line; sub(/^> — via[[:space:]]+/, "", via); sub(/[[:space:]]+$/, "", via); print ptxt "\t" via; pend = 0; next }
        else { fail("observation not followed by a \"> — via <model>\" line") }
      }
      if (line ~ /^> \[observation] /) { ptxt = line; sub(/^> \[observation] /, "", ptxt); pend = 1 }
    }
    END { if (pend) fail("observation not followed by a \"> — via <model>\" line") }
  '
}

# cmd_resolved <doc> -> "ns-id\tnote\tmodel" per resolved record; exit 2 on a contract violation.
#
# `> [resolved:<ns-id>] <note>` + `> — via <model>` (issue #88). A finding the primary AGREED with
# in an earlier round and has since verified fixed at the current head. Without it, compose-review
# republishes every agreed finding as currently-open — including the ones the author fixed between
# rounds, which is most of them — and the review reads to its author as "you fixed nothing".
#
# It is an ANNOTATION, not a response verb: _table's verb set stays finding|agree|dispute, so the
# one-response rule, coverage convergence and the manifest are untouched, and a doc with no
# resolved records renders exactly as before. Same shape [observation] uses (#63), and it lives
# outside _table for the same reason.
#
# Undisclosed or empty records fail loud rather than being dropped: a claim that a defect is fixed
# is agent-authored content a human acts on, so it names its model or it is a contract violation.
cmd_resolved() { # <doc> -> "ns-id\tnote\tmodel\twitness" per record
  local doc="${1:?doc}" raw t
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  raw="$(review_section "$doc" | strip_fences /dev/stdin | awk '
    function fail(m){ print "multi-review-star: " m > "/dev/stderr"; exit 2 }
    {
      line = $0
      if (pend) {
        # Same NON-SPACE requirement the observation reader uses (PR #65): a bare "> — via " would
        # otherwise strip to an empty model and publish a disclosure naming nobody.
        if (line ~ /^> — via [^[:space:]]/) {
          via = line; sub(/^> — via[[:space:]]+/, "", via); sub(/[[:space:]]+$/, "", via)
          recs[++nr] = pid "\t" ptxt "\t" via; wit[nr] = ""; wfor = nr; pend = 0; next
        }
        else { fail("resolved record " pid " not followed by a \"> — via <model>\" line") }
      }
      # Optional `> — witness:` on the record just closed (spec 2026-09-01 A1); cleared by any
      # control-shaped line so it can never credit a record it does not follow.
      if (line ~ /^> \[/) wfor = 0
      if (line ~ /^> — witness:/) {
        if (wfor) { w = line; sub(/^> — witness:[ ]*/, "", w); gsub(/[ \t]+$/, "", w); if (w != "") wit[wfor] = w }
        next
      }
      if (line ~ /^> \[resolved:[A-Za-z0-9_-]+]/) {
        s = substr(line, 13)                      # after the literal "> [resolved:"
        b = index(s, "]")
        pid = substr(s, 1, b - 1)
        # A literal TAB in the note is NORMALISED, not tolerated: the record is emitted as TSV, so
        # an un-normalised tab makes the model field 4 — and the self-resolve check below then
        # compares a fragment of the NOTE against the raiser and passes anything. Reproduced live
        # on the first version of this reader: gpt-5.5 closing a finding gpt-5.5 raised, rc=0, and
        # the published note truncated at the tab.
        ptxt = substr(s, b + 1); sub(/^ /, "", ptxt); gsub(/\t/, " ", ptxt); sub(/[[:space:]]+$/, "", ptxt)
        if (ptxt == "") fail("empty note on resolved record: " pid)
        pend = 1
      }
    }
    END {
      if (pend) fail("resolved record " pid " not followed by a \"> — via <model>\" line")
      for (i = 1; i <= nr; i++) print recs[i] "\t" wit[i]
    }
  ')" || return 2
  [[ -n "$raw" ]] || return 0                     # dormant: no records, nothing to cross-check

  # Cross-checks against the adjudicated table. All four fail CLOSED — a contradictory record must
  # never render, because every one of them publishes something false to the author.
  t="$(_table "$doc")" || return 2
  # The round this document is currently in, read from its own state marker. Empty when the doc
  # carries no marker — a file that is not under a live review (a unit fixture, a hand-built
  # example), where "which round is this" has no answer and the check below stands down.
  #
  # A MALFORMED marker is NOT that case (codex-rd2-r1). `core.sh marker` exits 1 for both, so an
  # unchecked read leaves cur empty and the round check silently stands down on a live review —
  # the one place it must not. Distinguish them by whether a marker line exists at all, and
  # refuse rather than degrade when one does but will not parse.
  local cur_round=""
  cur_round="$("${STAR_DIR}/multi-review-core.sh" marker "$doc" 2>/dev/null | awk '{print $2}')" || cur_round=""
  if [[ -z "$cur_round" ]] && grep -q '^<!-- multi-review:' "$doc"; then
    die "cannot read the review round: ${doc} carries a state marker that does not parse — a resolved record cannot be checked against an unreadable round" 2
  fi
  printf '%s\n' "$raw" | TBL="$t" awk -F'\t' -v cur="${cur_round:-}" '
    function fail(m){ print "multi-review-star: " m > "/dev/stderr"; exit 2 }
    BEGIN {
      nr = split(ENVIRON["TBL"], rows, "\n")
      for (i = 1; i <= nr; i++) {
        if (rows[i] == "") continue
        split(rows[i], f, "\t")
        state[f[1]] = f[3]; raiser[f[1]] = f[2]
      }
    }
    {
      id = $1
      if (!(id in state)) fail("resolved record names an unknown finding id: " id)
      if (state[id] != "agreed") fail("resolved record on a finding the review did not agree with (" state[id] "): " id)
      if (id in seen) fail("duplicate resolved record for finding: " id)
      # Mirrors _table self-response guard: the party that raised a finding is not the party that
      # gets to certify it closed.
      if ($3 == raiser[id]) fail("self-resolve: the raiser of " id " cannot record it fixed")
      # EARLIER ROUND ONLY (fable-rd1-r4 + codex-rd1-r1, raised independently by two vendors).
      # A record describes a fix the author pushed BETWEEN rounds; on a CURRENT-round finding
      # there was no between, so the claim cannot be true. Publishing it drops the item from the
      # worklist AND suppresses its inline comment — issue #88 harm, exactly inverted. The rule
      # was documented and enforced by nothing, which is the shape this repo keeps having to fix.
      # Round is the FIRST "-rd<n>" in the ns-id, the same parse _structural_consistency uses:
      # robust to a hyphenated provider and to a later "-rd<n>" inside a namespaced id.
      if (cur != "" && match(id, /-rd[0-9]+/)) {
        rd = substr(id, RSTART + 3, RLENGTH - 3) + 0
        if (rd + 0 >= cur + 0) fail("resolved record on a round-" rd " finding while the review is in round " cur " — only an EARLIER round can have been fixed since: " id)
      }
      seen[id] = 1
      print
    }
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

# pass_id_of_copy <doc> <copy> -> pass id (exact suffix after "<doc>.", same extraction as
# provider_of_copy) — but validated against STAR_PASSES, NOT the reviewer registry. A pass (e.g.
# crossref) is deliberately not a registered provider (spec §0), so `merge --pass` must not route
# it through provider_of_copy's registry check.
pass_id_of_copy() {
  local doc="$1" copy="$2"
  local p="${copy#${doc}.}"   # exact prefix strip, same rationale as provider_of_copy (r8)
  local known
  [[ "$p" != "$copy" ]] || die "copy name does not match <doc>.<pass>: $copy" 2
  for known in $STAR_PASSES; do
    [[ "$p" == "$known" ]] && { echo "$p"; return 0; }
  done
  die "copy names an unknown pass '${p}': $copy (known: ${STAR_PASSES})" 2
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
  local doc="${1:?doc}" primary="${2:?primary-model}" t qlist qprov obs
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
  # Primary observations belong in the POSTED review, not just the local gate (issue #63) — the
  # same defect #26 fixed one signal over. In PR mode the primary never edits the diff, so an
  # observation is its only channel for a defect it found itself, and publishing is how that
  # reaches the author who has to fix it.
  #
  # The `|| die` is the guard, and it is the whole guard (codex-rd1-r1). This script sets
  # `set -uo pipefail`, so a pipeline propagates the first non-zero status rather than its last
  # command's — piping through `tr`/`cat` would NOT swallow the refusal here. What swallows it is
  # having no status check at all, which is exactly what shipped in #59: that line was
  # `hintp="$(_roster "$doc" | tr '\n' ' ')"` with nothing testing `$?`, so the die printed to
  # stderr and the caller carried on. Without `|| die` the same happens here and the review posts
  # silently missing an observation.
  obs="$(cmd_observations "$doc")" || die "cannot compose: contract violation in $doc" 1

  # Findings agreed in an earlier round and since fixed (issue #88). Same `|| die` reasoning as the
  # line above: an unchecked status here would publish a review whose open list silently includes
  # work the author already did. Dormant when there are none.
  local rsv; rsv="$(cmd_resolved "$doc")" || die "cannot compose: contract violation in $doc" 1

  # _table columns (tab-separated): id, raiser, state, responder, concern, dwhy, sev, risk.
  # Use awk -F'\t' to avoid bash IFS-whitespace collapsing of adjacent empty tab fields.
  printf '%s\n' "$t" | OBS="$obs" QLIST="$qlist" QPROV="$qprov" RSV="$rsv" awk -F'\t' -v primary="$primary" '
    function emit(want,   lvl, i, levels) {
      split("high med low", levels, " ")
      for (lvl = 1; lvl <= 3; lvl++)
        for (i = 1; i <= n; i++)
          if (st[i] == want && sv[i] == levels[lvl]) print txt[i]
      print ""
    }
    BEGIN {
      n=0; agreed_n=0; dissent_n=0; open_n=0; fixed_n=0; nsec=0
      nr = split(ENVIRON["RSV"], rrec, "\n")
      for (ri = 1; ri <= nr; ri++) {
        if (rrec[ri] == "") continue
        split(rrec[ri], rf, "\t")
        rnote[rf[1]] = rf[2]
      }
    }
    NF < 3 { next }
    {
      id=$1; raiser=$2; state=$3; resp=$4; concern=$5; dwhy=$6; sev=$7; risk=$8
      if (raiser != "" && raiser != primary && !(raiser in secseen)) { secseen[raiser]=1; seclist[++nsec]=raiser }
      emoji = (sev=="high") ? "🔴" : (sev=="med") ? "🟠" : (sev=="low") ? "🟡" : ""
      line = emoji " " sev " — " concern " — risk: " risk
      if (state == "dissent")   line = line " — flagged by " raiser "; " resp " disputes: " dwhy
      else if (state == "open") line = line " — raised by " raiser ", no response yet"
      # An agreed finding with a resolved record is NOT part of the open worklist. Leaving it in
      # the agreed list is the whole of issue #88: it tells the author to fix what they fixed.
      # cmd_resolved has already refused any record whose finding is not agreed, so the state
      # test here cannot admit a disputed or unanswered one.
      else if (state == "agreed" && (id in rnote)) { state = "fixed"; line = line " — ✅ " rnote[id] }
      n++; st[n]=state; sv[n]=sev; txt[n]=line
      if (state == "agreed")       agreed_n++
      else if (state == "dissent") dissent_n++
      else if (state == "open")    open_n++
      else if (state == "fixed")   fixed_n++
    }
    END {
      printf "## Multi-review\n\n"
      if (agreed_n == 0 && dissent_n == 0 && open_n == 0 && fixed_n == 0) {
        printf "No findings.\n\n"
      } else {
        if (agreed_n  > 0) { printf "**Agreed findings (%d)**\n", agreed_n;  emit("agreed") }
        if (dissent_n > 0) { printf "**Disagreements (%d)**\n",   dissent_n; emit("dissent") }
        if (open_n    > 0) { printf "**Open / unresolved (%d)**\n", open_n;  emit("open") }
        # Last among the finding sections: what the author still has to act on comes first, and
        # what the review is reporting closed is confirmation rather than work.
        if (fixed_n   > 0) { printf "**Fixed during review (%d)**\n", fixed_n; emit("fixed") }
      }
      # Primary observations (issue #63). Each line carries its OWN via (codex-rd1-r1): nothing
      # restricts [observation] to the primary — cmd_observations requires a via line and never
      # compares it to anyone — so a heading asserting authorship could publish a note written by
      # a secondary as though the primary had raised it. Per-line attribution is true whoever
      # wrote it, and CLAUDE.md section 8 wants agent-authored content posted to a human to name
      # its model anyway.
      #
      # NB: no apostrophes in this block. The whole awk program is a single-quoted shell string,
      # so one apostrophe here terminates it and the script stops parsing.
      no = split(ENVIRON["OBS"], orec, "\n")
      oshown = 0
      for (i = 1; i <= no; i++) {
        if (orec[i] == "") continue
        if (!oshown) { printf "**Primary observations (raised directly by an agent, not adjudicated as findings)**\n"; oshown = 1 }
        split(orec[i], of, "\t")
        printf "- %s — via %s\n", of[1], of[2]
      }
      if (oshown) printf "\n"

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

cmd_compose_inline() { # <doc> -> "path\tstart\tend\tbody" per agreed+anchored+unresolved finding
  local doc="${1:?doc}" t rsv_ids
  t="$(_table "$doc")" || die "cannot compose inline: contract violation in $doc" 1
  # Findings recorded fixed (issue #88) get no inline comment. Two reasons, either sufficient: a
  # comment on code the author has already fixed is noise, and after a `refresh` the anchor may no
  # longer land on a changed line at all, so the remap would either fail or point somewhere new.
  rsv_ids="$(cmd_resolved "$doc" | awk -F"\t" 'NF{print $1}')" || die "cannot compose inline: contract violation in $doc" 1
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
    grep -qxF "$id" <<<"$rsv_ids" && continue
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
      --seed)
        (( $# >= 2 )) || die "--seed requires a value" 2
        base="$2"; shift 2 ;;
      # --baseline is REFUSED, not aliased: passing <doc>.baseline for a scoped round-N copy
      # reproduces the exact false negative this check exists to prevent, and an alias makes
      # that silent (codex-rd2-r1, fable-rd2-r1).
      --baseline)
        die "channel-check takes --seed (the copy AS DISPATCHED), not --baseline: a scoped round-N copy differenced against the full baseline hides misplaced findings" 2 ;;
      *) [[ -n "$copy" ]] || copy="$1"; shift ;;
    esac
  done
  [[ -n "$base" ]] || die "channel-check requires --seed <copy-as-dispatched>" 2
  [[ -f "$base" ]] || die "seed not found: $base" 2
  [[ -n "$copy" && -f "$copy" ]] || die "copy not found: ${copy:-<unset>}" 2

  local sa sv ca cv sn cn sprim cprim added_total added_visible signalled stray added_primary
  sa="$(mktemp)" && sv="$(mktemp)" && ca="$(mktemp)" && cv="$(mktemp)" && sn="$(mktemp)" && cn="$(mktemp)" \
    && sprim="$(mktemp)" && cprim="$(mktemp)" \
    || die "cannot create temp files for channel-check" 2
  # ALL finding lines anywhere in the file...
  # LC_ALL=C so sort/comm agree byte-wise regardless of the caller's locale.
  grep '^> \[finding:' "$base" 2>/dev/null | LC_ALL=C sort > "$sa" || true
  grep '^> \[finding:' "$copy" 2>/dev/null | LC_ALL=C sort > "$ca" || true
  # ...versus exactly what MERGE will ingest: the last ## Review section, fences stripped.
  review_section "$base" | strip_fences /dev/stdin | grep '^> \[finding:' 2>/dev/null | LC_ALL=C sort > "$sv" || true
  review_section "$copy" | strip_fences /dev/stdin | grep '^> \[finding:' 2>/dev/null | LC_ALL=C sort > "$cv" || true
  # ...and the no-findings signal itself, same fence-stripped review-section idiom as $sv/$cv.
  # codex-rd1-r1 (PR #58): matched EXACTLY, `]` and nothing else. The signal carries no id, so
  # unlike `finding:`/`agree:` the shared `[]:]` class is wrong for it — under that class a
  # malformed `[no-findings: …]` beside REAL findings read as a contradiction and quarantined the
  # turn, destroying its good findings (fable-rd2-r4's harm, inverted). Scoped to THIS guard on
  # purpose: blind-check and protocol_lines are permissive in the fail-CLOSED direction (more
  # copies re-seeded, more lines required to carry a disclosure), so narrowing them would loosen
  # them instead.
  review_section "$base" | strip_fences /dev/stdin | grep '^> \[no-findings]' 2>/dev/null | LC_ALL=C sort > "$sn" || true
  review_section "$copy" | strip_fences /dev/stdin | grep '^> \[no-findings]' 2>/dev/null | LC_ALL=C sort > "$cn" || true
  # ...and every PRIMARY-ONLY marker, same fence-stripped review-section idiom: any doc about this
  # protocol legitimately shows a FENCED example of the grammar, and the doc most likely to be
  # reviewed by this protocol is a doc about it. Review-section scoping also keeps a PR scratch
  # safe, whose `## PR description` and `## Diff` quote the grammar above the review channel.
  #
  # `[observation]` is matched EXACTLY — `]` and nothing else — NOT through the `[]:]` class the
  # id-bearing markers use. It carries no id, so under that class a malformed `[observation: …]`
  # beside real findings would refuse a turn that must be admitted: fable-rd2-r4 harm, the same way
  # it bit `[no-findings]` (see star/channel-check-signal-strict).
  review_section "$base" | strip_fences /dev/stdin | grep -E '^> \[(agree|dispute|resolved):|^> \[observation]' 2>/dev/null | LC_ALL=C sort > "$sprim" || true
  review_section "$copy" | strip_fences /dev/stdin | grep -E '^> \[(agree|dispute|resolved):|^> \[observation]' 2>/dev/null | LC_ALL=C sort > "$cprim" || true

  # Compare ADDITIONS (comm), not net counts: a net count lets a reviewer that deletes a
  # pre-existing line offset one misplaced finding of its own back to zero (fable-rd1-r5).
  added_total="$(LC_ALL=C comm -13 "$sa" "$ca" | grep -c '^> \[finding:' || true)"
  added_visible="$(LC_ALL=C comm -13 "$sv" "$cv" | grep -c '^> \[finding:' || true)"
  # Issue #50 (design §3 rule 3). Judged the same way: additions relative to the SEED, not
  # presence anywhere in the copy — a reviewer is never blamed for a `[no-findings]` line it
  # inherited (e.g. a stale prior round) rather than claimed itself.
  # Count the additions themselves. The captures above already restricted these files to signal
  # lines, so re-matching the tag here would put the pattern in TWO places — and a mutation in
  # either one would be masked by the other, leaving both individually untestable.
  signalled="$(LC_ALL=C comm -13 "$sn" "$cn" | grep -c '^' || true)"

  # A reviewer must never author a PRIMARY-ONLY control line (issue #103; the `resolved` arm was
  # PR #102 fable-rd1-r1). blind-check protects only the SEED direction — it runs before dispatch —
  # and nothing examined what a copy came BACK with: `namespace_blocks` copies a returned review
  # section verbatim, rewriting `[finding:` ids and nothing else. Reproduced: a round-2 copy
  # carrying `> [resolved:codex-rd1-a]` under its own via merged with rc=0, landed in the doc, and
  # was accepted by cmd_resolved — publishing another provider is finding as fixed under the
  # primary own review. `[agree:]` takes the identical path, and there it is worse: convergence is
  # COVERAGE, so a secondary supplying the one required response can close a finding it was never
  # meant to adjudicate, and check-converged passes.
  #
  # Judged as ADDITIONS relative to the seed, not presence anywhere in the copy, so a reviewer is
  # never blamed for a line it inherited. Nothing legitimate carries one: blind-check refuses a
  # seed containing any of these markers, which is the same property from the other side.
  added_primary="$(LC_ALL=C comm -13 "$sprim" "$cprim" | grep -c '^' || true)"
  rm -f "$sa" "$sv" "$ca" "$cv" "$sn" "$cn" "$sprim" "$cprim"

  if (( added_primary > 0 )); then
    die "the copy authored ${added_primary} primary-only control line(s) — '[agree:', '[dispute:', '[resolved:' and '[observation]' belong to the PRIMARY, never to a reviewer. Merging would let a secondary adjudicate or close a finding under the primary's own review." 1
  fi

  # Issue #50. The signal and real findings are mutually exclusive: a reviewer cannot have
  # nothing to raise while raising things. A copy carrying both is self-contradictory, and the
  # ambiguity is not harmless — merge would ingest the findings while the signal tells the gate
  # the turn was clean. Checked here rather than at merge so the copy is still attributable to
  # ONE provider and the natural remedy (quarantine that secondary) is still available.
  if (( signalled > 0 && added_total > 0 )); then
    die "the copy claims '[no-findings]' while adding ${added_total} finding(s) — a turn cannot be both clean and raising concerns. Merging would ingest the findings while the gate reports the turn as clean." 1
  fi

  # Issue #42. Zero RECOGNISED additions makes the comparison above vacuous: a copy whose
  # findings are indented (` > [finding:`) matches neither grep, so added_total and
  # added_visible are both 0 and the turn scores as clean while merge ingests nothing. Before
  # accepting a zero as a genuine "found nothing", assert the copy is still SHAPED like the
  # document that was dispatched — a reviewer is contracted to append under `## Review`, never
  # to reformat. Scoped to the zero case deliberately: when findings DID land, a heading change
  # is not worth destroying them over (same rationale as the partial case below).
  if (( added_total == 0 )); then
    local seed_h copy_h
    seed_h="$(grep -c '^## ' "$base" || true)"
    copy_h="$(grep -c '^## ' "$copy" || true)"
    if (( seed_h != copy_h )) || ! grep -q '^## Review[[:space:]]*$' "$copy"; then
      die "the copy's heading structure changed (seed has ${seed_h} '## ' heading(s), copy has ${copy_h}); a reformatted copy loses its whole turn silently. Merging would record this turn as clean." 1
    fi

    # Issue #46. Everything above has established that this copy is SHAPED right and simply
    # contributed no findings. That is legitimate only if the reviewer positively said so: since
    # #50, a conforming secondary with nothing to raise emits `> [no-findings]`. A turn that adds
    # neither findings nor that signal is a NON-RESPONSE — the marker was flipped without the
    # document being reviewed — and merging it would record the turn as clean while gate-summary
    # counted this provider as an independent secondary.
    #
    # Judged on ADDITIONS (`signalled`, computed above), never presence: a signal inherited from a
    # stale seed is not this reviewer's claim. Ordered AFTER the structural check on purpose, but
    # that check (#42) only catches a heading-STRUCTURE change (a '## ' count mismatch, or a
    # missing '## Review'). A copy that indents only its own appended finding lines, leaving
    # headings untouched, passes #42 and lands here instead — where it reads identically to a turn
    # that never opened the document, even though the better remedy for THAT shape is a re-dispatch
    # with formatting guidance, not a quarantine.
    if (( signalled == 0 )); then
      die "the copy adds no findings and no '> [no-findings]' signal — this turn is a non-response, not a reviewed-and-clean turn. Merging would record it as clean and the gate would count this provider as an independent secondary." 1
    fi
    return 0
  fi

  (( added_total <= added_visible )) && return 0
  stray=$(( added_total - added_visible ))

  # Quarantine ONLY when NOTHING reached the channel. That is #32's shape and is unambiguous:
  # the turn merges as clean while contributing nothing. When some findings DID land, the stray
  # lines are more likely quotation — a reviewer citing the grammar inside a fence as evidence —
  # and quarantining the whole turn for that would destroy good findings, which is the same harm
  # #32 causes, inverted (fable-rd2-r4). Warn instead and let the round proceed.
  if (( added_visible > 0 )); then
    echo "multi-review-star: note — ${stray} of ${added_total} added finding line(s) are outside what merge ingests (likely quoted examples); ${added_visible} will merge normally" >&2
    return 0
  fi

  local why="an earlier or fenced '## Review' captured them"
  grep -q '^## Review[[:space:]]*$' "$copy" \
    || why="the copy has NO '## Review' heading, so nothing could reach the channel"
  die "NONE of the reviewer's ${added_total} finding(s) reached what merge ingests (${why}). Merging would record this turn as clean." 1
}

# blind-check <copy> — is this seeded copy actually BLIND? (issue #39)
#
# Reviewer independence is the property the star model rests on — "a secondary never sees another
# secondary's findings or the primary's responses". Producing the blind copies is the one step of
# the loop with no script behind it and no check after it: the primary truncates the baseline after
# the last '## Review' by hand, per round, per provider.
#
# The failure is silent in exactly the direction that matters. Get the truncation wrong and the
# "blind" copy still carries the previous round's findings and the primary's responses — so the
# secondary reviews a document that tells it what everyone else already said, and nothing
# downstream notices: merge accepts the copy, verify passes, check-converged passes, and
# gate-summary reports N INDEPENDENT secondaries. Every other trust property in this protocol has a
# mechanical check (verify-vendor, channel-check, the manifest self-check); this one had none.
#
# FENCES ARE NOT RECORDS. Any doc about this protocol legitimately shows the grammar inside a code
# block — this repo's own docs do — so a fenced example must not make a copy unseedable. Same
# fence-aware rule the rest of the file already applies to live records.
cmd_blind_check() { # <copy> -> 0 blind, 1 carries a prior round (offenders on stderr), 2 usage
  local copy="${1:-}" live records footer
  [[ -n "$copy" ]] || die "blind-check requires a copy path" 2
  [[ -f "$copy" ]] || die "copy not found: $copy" 2

  live="$(strip_fences "$copy")"
  # Every control line a previous round leaves behind: a secondary's findings, and the primary's
  # responses/observations/resolutions. Any one of them means this copy is not blind. A leaked
  # `[resolved:]` is strictly worse than a bare `[agree:]` — it names a defect AND tells the
  # secondary the primary already closed it (issue #88).
  records="$(printf '%s\n' "$live" | grep -E '^> \[(finding|agree|dispute|observation|resolved|no-findings)[]:]' || true)"
  # The footer mirrors the merged manifest, so its presence alone proves the copy was merged into.
  # ANCHORED to the footer's real shape — a whole line, opening at column 1 and closing on the same
  # line — the way merge and _structural_consistency already count it. An unanchored substring also
  # matched PROSE naming the footer in inline backticks, which strip_fences cannot help with because
  # it is live text (#68). That false positive lands on exactly the reviews most likely to run this:
  # a PR whose description documents the protocol. It is the worst failure for an independence
  # guard, because the instructed remedy — re-seed from the baseline — reproduces the same bytes and
  # fails again, leaving overriding the guard by hand as the only way forward.
  footer="$(printf '%s\n' "$live" | grep -E '^<!-- star-findings: .*-->$' || true)"

  if [[ -n "$records" || -n "$footer" ]]; then
    echo "multi-review-star: NOT BLIND — ${copy} carries a previous round; a secondary handed this would see what others already said:" >&2
    [[ -n "$records" ]] && printf '%s\n' "$records" | sed 's/^/  /' >&2
    [[ -n "$footer" ]] && printf '%s\n' "$footer" | sed 's/^/  /' >&2
    echo "Re-seed it from the baseline, truncating after the LAST '## Review' outside any fence." >&2
    return 1
  fi
  return 0
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
  # resolved records (#88) — the same cross-checks the composers apply, run from the one place
  # verify, merge and check-converged all share, so a contradictory record fails at the handoff
  # instead of first surfacing when the review is being published.
  cmd_resolved "$doc" >/dev/null || { echo "multi-review-star: verify: undisclosed or contradictory [resolved:] record" >&2; return 1; }
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

# check-primary-id <doc> <primary-model-id> -> 0 usable · 3 collides · 2 usage
#
# The self-response guard in `_table` is parse-fatal BY DESIGN, but it fires only once the
# colliding response is ALREADY in the doc — and `_table` underlies `_structural_consistency`, so
# at that point merge's pre-check, `verify`, `gate-summary`, `round-stats` and `compose-review`
# all fail too. The review is then stuck in both directions: the primary cannot respond without
# tripping the guard, and cannot converge without responding. Recovery means hand-editing the doc
# or disclosing a false id, and neither is something a protocol should require.
#
# So this is the cheap pre-check the command's prose used to ask for and nothing enforced. Run it
# BEFORE writing the first response of a primary turn; a refusal costs one line of output, the
# collision costs the review.
#
# The trigger is a SUPPORTED configuration, not operator error: `fable` is a selectable session
# model, so a fable-powered primary discloses exactly the string its floor secondary does.
#
# Reads the RAISER's disclosure only — the `> — via` line immediately following a `> [finding:` —
# never just any `> — via` in the doc. The primary's own responses carry one too, and matching
# those would refuse every round after the first.
cmd_check_primary_id() { # <doc> <primary-model-id>
  local doc="${1:-}" pid="${2:-}"
  [[ -n "$doc" ]] || die "usage: multi-review-star.sh check-primary-id <doc> <primary-model-id>" 2
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  [[ -n "$pid" ]] || die "check-primary-id requires a primary model id" 2
  local hit
  hit="$(review_section "$doc" | awk -v pid="$pid" '
    /^> \[finding:/ { want = 1; next }
    want && /^> — via / {
      v = $0; sub(/^> — via[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v == pid) { print v; exit }
      want = 0; next
    }
    /^> \[/ { want = 0 }
  ')"
  [[ -z "$hit" ]] || die "primary model id '${pid}' is the SAME model id a secondary disclosed when raising a finding in this doc. The self-response guard is parse-fatal, so responding under it would leave the review unparseable and unrecoverable without a hand edit. Disclose a distinguishing id (e.g. '${pid} (primary)') before writing any response." 3
  return 0
}

# Staging cleanup for cmd_merge (#107). A GLOBAL, not a local: the EXIT trap runs while the
# function frame is unwinding, where a local is no longer reliably readable — and `rm -f ""` with an
# unset value would resolve ".manifest" against the CWD, so the emptiness check is load-bearing.
_STAR_MERGE_STAGE=""
_star_merge_stage_clean() {
  if [[ -n "${_STAR_MERGE_STAGE:-}" ]]; then
    rm -f "$_STAR_MERGE_STAGE" "${_STAR_MERGE_STAGE}.manifest"
  fi
}

cmd_merge() {
  local round="" doc="" copies=() quarantined=() passes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --round) [[ $# -ge 2 ]] || die "--round requires a value" 2; round="$2"; shift 2 ;;
      --quarantined) [[ $# -ge 2 ]] || die "--quarantined requires a value" 2; quarantined+=("$2"); shift 2 ;;
      --pass) [[ $# -ge 2 ]] || die "--pass requires a value" 2; passes+=("$2"); shift 2 ;;
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

  # --pass gets no dedicated up-front loop like --quarantined above: --quarantined NEEDS one
  # because its own record-writing loop runs AFTER the doc is mutated (the comment above explains
  # why). A --pass copy's existence/id check instead happens inline in the SAME copy-building loop
  # ordinary copies already use below (provider_of_copy is validated there too, with no separate
  # early pass) — that loop runs entirely BEFORE the doc is touched, so inline is already "before
  # the doc is touched"; a second, earlier loop would only re-validate the same thing.

  # Refuse to merge onto a doc already inconsistent with its manifest — fail loud at THIS
  # handoff rather than compounding the corruption into later rounds (issue #16). Round 1 has
  # no manifest yet, so this is a no-op there.
  if [[ -f "${doc}.manifest" ]]; then
    _structural_consistency "$doc" \
      || die "merge: refusing to merge — '$doc' is inconsistent with its manifest (run: $(basename "$0") verify '$doc')" 1
  else
    # No manifest is normal for round 1 — and was a corrupting trap for any later round (#57).
    # The terminal gate used to delete <doc>.manifest, so resuming a converged review to re-review
    # a follow-up push skipped this pre-check entirely: merge appended the round, rebuilt the
    # manifest from THAT ROUND ALONE, and only then failed the self-check — which back then ran
    # after the write, leaving the doc mutated and disagreeing with its manifest (#107 moved that
    # check ahead of the commit; this guard still earns its place by naming the real cause).
    # The doc's own footers say whether a round was ever merged here, so decide BEFORE the first
    # write (the same rule the --quarantined validation above follows).
    #
    # Footers counted on the FENCE-STRIPPED review section: a doc about this protocol legitimately
    # shows a footer inside a code block (this repo's own docs do), and that must not make round 1
    # unmergeable. An UNTERMINATED fence hides every line after it from strip_fences, which would
    # hide real footers and reduce this guard to a no-op — so refuse rather than guess, the same
    # call _table makes for the same reason.
    local ufl rstart nfoot
    ufl="$(review_section "$doc" | unterminated_fence_line /dev/stdin)"
    if [[ -n "$ufl" ]]; then
      rstart="$(review_section_start "$doc")"
      die "merge: unterminated code fence in ## Review (file line $((rstart + ufl))): cannot tell whether a round was already merged here — close the fence" 1
    fi
    nfoot="$(review_section "$doc" | strip_fences /dev/stdin | grep -cE '^<!-- star-findings: .*-->$')"
    [[ "$nfoot" -eq 0 ]] || die "merge: '${doc}' carries ${nfoot} already-merged round(s) but '${doc}.manifest' is missing — refusing to merge onto rounds it cannot verify. Restore the manifest, or rebuild it from the doc's '<!-- star-findings: -->' footers (one 'finding <id>=<hash>' line per entry, every round, in document order) and re-run" 1
  fi

  # Zero admitted copies is a REACHABLE state, not an impossible one: a default (fable-only) run
  # whose single secondary hits the wait bound quarantines it and arrives here with a reason and
  # nothing to merge. Refuse deliberately and by name.
  #
  # Without this, bash 3.2 — the version CI pins and these scripts claim to support — aborts on
  # the expansion below with a raw `copies[@]: unbound variable` (3.2 treats `local copies=()` as
  # unset rather than empty). The operator sees a bash error instead of a reason, and the round's
  # quarantine record is never written: the one round that provably produced nothing is also the
  # one whose evidence is lost. Bash 5 prints nothing at all and iterates zero times, so this
  # never surfaced there — the 3.2 leg of the gate is what makes it visible.
  #
  # The sibling quarantine loops use "${quarantined[@]:-}" for the same 3.2 reason; here that
  # idiom alone is not enough, because it yields one EMPTY element that would then be reported as
  # `copy not found: `. The count check is what makes the refusal say the true thing.
  if (( ${#copies[@]} == 0 )); then
    die "merge: no admitted copies for round ${round} — a round with nothing to merge is the all-quarantined anomaly stop: surface every quarantine reason and stop, do not merge" 2
  fi

  local block="" copy provider
  for copy in "${copies[@]}"; do
    [[ -f "$copy" ]] || die "merge: copy not found: $copy" 1
    provider="$(provider_of_copy "$doc" "$copy")" || exit $?
    block="${block}$(namespace_blocks "$provider" "$round" "$copy")"$'\n'
  done
  # --pass copies use the SAME namespace_blocks path ordinary copies use, validated against
  # STAR_PASSES (pass_id_of_copy) rather than the reviewer registry — see comment above.
  for copy in "${passes[@]:-}"; do
    [[ -z "$copy" ]] && continue
    [[ -f "$copy" ]] || die "merge: pass copy not found: $copy" 1
    provider="$(pass_id_of_copy "$doc" "$copy")" || exit $?
    block="${block}$(namespace_blocks "$provider" "$round" "$copy")"$'\n'
  done

  # Stage the ENTIRE merge, self-check the staged pair, and commit only on success (#107).
  # The self-check used to run after the write, so a turn that failed it had already been committed
  # to both <doc> and <doc>.manifest. That is expensive to undo: the manifest hashes each finding
  # block, so repairing the doc alone still fails verify — the round has to be rolled out of BOTH
  # files by hand. Staging costs one copy of the doc and turns that into "fix the turn and re-run".
  #
  # Staged BESIDE the doc rather than in $TMPDIR: same directory means same filesystem, so each
  # commit below is a rename, not a copy that can tear halfway.
  #
  # Pass $block via the ENVIRONMENT (ENVIRON[]) — NOT `awk -v add=...`, which escape-processes C
  # sequences and would turn a literal "\n"/"\t"/"\\" in a finding's text into a real newline/tab,
  # corrupting the byte-verbatim guarantee (and then hashing the corrupted form). ENVIRON values
  # are not escape-processed. (r11)
  local stage; stage="$(mktemp "${doc}.merge.XXXXXX")" || die "cannot create staging file for: $doc" 1
  # Global, not the local above: the trap fires while the function frame is unwinding, where a
  # local is no longer reliably readable. Left armed after the commit on purpose — by then the
  # staged paths no longer exist, so the cleanup is a no-op, and any later exit stays covered.
  _STAR_MERGE_STAGE="$stage"
  trap _star_merge_stage_clean EXIT
  ADD_BLOCK="$block" awk '
    { lines[NR]=$0; if ($0 ~ /^## Review[[:space:]]*$/) last=NR }
    END {
      for (i=1;i<=NR;i++) {
        print lines[i]
        if (i==last) { print ""; printf "%s", ENVIRON["ADD_BLOCK"] }
      }
    }
  ' "$doc" > "$stage" || die "merge: failed to stage $doc" 1

  # collect the ns-ids just merged THIS round — read them from $block (the content appended
  # this round), NOT by grepping the whole doc for a "-rd${round}-" substring. A substring grep
  # is unanchored and would falsely re-match a prior-round id whose own text happens to contain
  # "-rd${round}-" (e.g. a secondary that named a finding "bug-rd2-fix" → "codex-rd1-bug-rd2-fix"
  # matches round 2). Sourcing from $block is unambiguous — those are exactly this round's blocks.
  local nsids id line mirror="" qline
  nsids="$(printf '%s' "$block" \
    | grep -oE '^> \[finding:[^]|]+' | sed -E 's/^> \[finding://' || true)"
  : > "${stage}.manifest" || true
  # cumulative: preserve prior manifest lines. Read from the LIVE manifest — it is the state this
  # round builds on and is not written again until the commit below.
  [[ -f "${doc}.manifest" ]] && cat "${doc}.manifest" >> "${stage}.manifest"
  for id in $nsids; do
    # hashed against the STAGED doc: that is the content being adjudicated, and the live doc does
    # not yet contain this round's blocks.
    line="${id}=$(finding_block_hash "$stage" "$id")"
    echo "finding ${line}" >> "${stage}.manifest"
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
    printf '%s\n' "$qline" >> "$stage"         # durable record
    echo "quarantine ${qprovider}-rd${round}=$(printf '%s' "$qline" | sha)" >> "${stage}.manifest"
    qmirror="${qmirror}${qprovider}=$(printf '%s' "$qline" | sha) "
  done

  # in-doc human-readable mirror (NOT trusted for integrity — see check-converged)
  printf '<!-- star-findings: %s; quarantined: %s -->\n' "${mirror% }" "${qmirror% }" >> "$stage"

  # Pre-commit self-check: the staged doc + manifest must be mutually consistent (issue #16).
  # Nothing has been written to the review yet, so a failure here costs the operator a re-run and
  # not a two-file rollback. The message says so: "left in place for diagnosis" was the honest
  # description when the write had already happened, and would be a lie now.
  #
  # Do NOT answer a failure here by rolling the doc back instead: an earlier attempt at that was
  # itself a data-loss hazard (#17), which is why the write used to be left in place. Staging
  # sidesteps the choice — there is nothing written to undo.
  _structural_consistency "$stage" \
    || die "merge: refusing to write — the merge would leave '$doc' inconsistent with its manifest; BOTH are unchanged. Fix the turn (see the diagnosis above) and re-run the same round" 1

  # Commit. Two renames cannot be made atomic together, but either half landing alone is a
  # doc/manifest mismatch that verify reports loudly — the same failure mode as before, and now
  # only reachable through a rename failure rather than through any malformed turn.
  mv "$stage" "$doc" || die "merge: failed to commit the staged doc for '$doc'" 1
  mv "${stage}.manifest" "${doc}.manifest" \
    || die "merge: staged doc committed but its manifest did not — run: $(basename "$0") verify '$doc'" 1
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

  # Issue #59. Who REVIEWED, not who raised a finding — those diverge exactly when a reviewer is
  # clean, and using the latter as a proxy reported a genuinely cross-vendor review as an echo
  # chamber. Derived here, once, and used for BOTH the secondary count and the independence check
  # below, so there is one notion of "admitted" rather than two.
  #
  #   admitted = (finding-raisers ∪ (roster − quarantined)) − STAR_PASSES
  #
  # The bracketing is load-bearing (codex-rd1-r1). Quarantine is ROUND-SCOPED — a later round does
  # not shrink the set (commands/multi-review.md:232) and _quarantines emits one record per
  # provider per round — so subtracting from the whole union would drop a provider whose round-1
  # findings are sitting in this very document. A provider that raised an admitted finding is
  # admitted by observation; only the roster term is filtered.
  #
  # The STAR_PASSES subtraction is separate and comes last (spec criterion 9): a pass (e.g.
  # crossref) namespaces its findings through the SAME raiser mechanism a provider uses, so it
  # would otherwise count as a secondary and skew the independence check. Its findings are NOT
  # removed from $t — only its raiser identity is excluded from this admitted set, so the pass's
  # findings still appear and still count in the ratio/agreed/dispute output below.
  #
  # The `|| die` is what makes _roster's refusal reach here. NOT the absence of a pipe: this
  # script sets `pipefail` (:23), so a pipeline propagates the first non-zero status and piping
  # would not have swallowed it. The original defect was that nothing tested `$?` at all. The
  # normalising filter runs as a second step so the status is checked before it is reshaped.
  local ga_roster ga_raisers ga_quar ga_rmq admitted nsec
  ga_roster="$(_roster "$doc")" || die "gate-summary: malformed roster in ${doc}" 1
  ga_roster="$(printf '%s\n' "$ga_roster" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u || true)"
  ga_raisers="$(printf '%s\n' "$t" | awk -F'\t' 'NF{p=$1; sub(/-rd.*/,"",p); print p}' | LC_ALL=C sort -u)"
  ga_quar="$(_quarantines "$doc" | awk -F'\t' 'NF{print $1}' | LC_ALL=C sort -u)"
  ga_rmq="$(LC_ALL=C comm -23 <(printf '%s\n' "$ga_roster" | grep -v '^$' || true) \
                              <(printf '%s\n' "$ga_quar"   | grep -v '^$' || true))"
  admitted="$(printf '%s\n%s\n' "$ga_raisers" "$ga_rmq" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u || true)"
  local ga_pass
  for ga_pass in $STAR_PASSES; do
    admitted="$(printf '%s\n' "$admitted" | grep -vFx "$ga_pass" || true)"
  done
  nsec="$(printf '%s\n' "$admitted" | grep -c . || true)"

  # ratio + disputes + agreed, from the table
  printf '%s\n' "$t" | awk -F'\t' -v nsec="$nsec" '
    function emit(want,   lvl,i,levels){ split("high med low",levels," ");
      for(lvl=1;lvl<=3;lvl++) for(i=1;i<=n;i++) if(st[i]==want && sv[i]==levels[lvl]) print txt[i] }
    NF { n++; id[n]=$1; raiser[n]=$2; st[n]=$3; resp[n]=$4; concern[n]=$5; why[n]=$6; sv[n]=$7; risk[n]=$8
      if($3=="agreed")a++; else if($3=="dissent")d++
      emoji=(sv[n]=="high")?"🔴":(sv[n]=="med")?"🟠":"🟡"
      if($3=="dissent") txt[n]=emoji " " sv[n] " — " concern[n] " (via " raiser[n] ") — primary disputes: " why[n]
      else txt[n]=emoji " " sv[n] " — " concern[n] " (via " raiser[n] ")"
    }
    END {
      # nsec is the ADMITTED count computed in shell (issue #59) — not a count of finding
      # prefixes, which is blind to a reviewer that reviewed and raised nothing.
      printf "Primary agreed with %d findings, DISPUTED %d (of %d across %d secondaries).\n\n", a+0, d+0, n+0, nsec+0
      if(d>0){ print "Disputes (high→low):"; emit("dissent"); print "" }
    }'

  # Findings agreed earlier and recorded fixed since (issue #88). The gate is where a human decides
  # whether to publish, and "10 of these 12 are already fixed" changes that decision — so the claim
  # is shown here BEFORE the publish, not only inside the composed comment. It is a primary claim
  # and is labelled as one: nothing can mechanically verify that a prose finding was fixed, so the
  # human gate is the only thing standing behind it. Dormant when there are none.
  local rsv rsv_n
  rsv="$(cmd_resolved "$doc")" || die "gate-summary: contract violation in $doc" 1
  rsv_n="$(printf '%s\n' "$rsv" | grep -c . || true)"
  if [[ "$rsv_n" -gt 0 ]]; then
    echo "Of those agreed, ${rsv_n} recorded fixed since (primary claim, not mechanically verified):"
    printf '%s\n' "$rsv" | awk -F'\t' 'NF{ printf "  - %s — %s (via %s)\n", $1, $2, $3 }'
    echo
  fi

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

  # cross-reference pass coverage (#90), readability channel — the durable per-round line, via
  # the shared parser. Three renderings so "not applicable", "complete" and "incomplete" cannot
  # be confused: an unchecked relation must be visible at the gate, not silent. Dormant (no line
  # printed) when the pass never recorded anything for this doc.
  local xr; xr="$(_crossref_coverage "$doc")"
  if [[ -n "$xr" ]]; then
    if [[ "$xr" == "not applicable" ]]; then
      echo "Cross-reference pass: not applicable (no sectioned structure)"
    elif [[ "$xr" =~ ^([0-9]+)/([0-9]+)\ rows\ verdicted$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
        echo "Cross-reference pass: ${xr}"
      else
        echo "Cross-reference pass: ${xr} — INCOMPLETE"
      fi
    fi
    echo
  else
    # No durable line. Silence used to mean two different things — the doc had no sectioned
    # structure and nobody recorded anything, OR the primary skipped the crossref wiring — so a
    # review that never ran the pass produced a gate summary byte-identical to one from before
    # the feature shipped (issue #96). Spec section 6 calls the announcement REQUIRED; that was
    # enforced by prose alone, which is the class of guarantee `[no-findings]` exists to replace.
    #
    # Derive applicability here instead of trusting the record. Only the EXIT CODE is used, never
    # the rows: this runs on the final doc, which by now carries every merged finding, so a count
    # derived here would be the same unreliable re-derivation issue #95 is about. Applicability is
    # stable under merging — findings are quote lines under `## Review`, not sections.
    "${STAR_DIR}/multi-review-crossref.sh" rows "$doc" >/dev/null 2>&1
    case $? in
      3) : ;;   # not applicable: nothing was ever expected, stay dormant (the PR-scratch case)
      0) echo "Cross-reference pass: NO RECORD — the pass was applicable and nothing was recorded"; echo ;;
      *) echo "Cross-reference pass: applicability could not be determined — treat as unrecorded"; echo ;;
    esac
  fi

  # symbol-check pass coverage (#89), same three renderings and the same dormancy rule as the
  # cross-reference block above. Rendered BESIDE it, never folded into it: crossref's behaviour is
  # unchanged by this work (spec criterion 12).
  local sx; sx="$(_symcheck_coverage "$doc")"
  if [[ -n "$sx" ]]; then
    if [[ "$sx" == "not applicable" ]]; then
      echo "Symbol-check pass: not applicable (no ready-to-paste code blocks)"
    elif [[ "$sx" =~ ^([0-9]+)/([0-9]+)\ rows\ verdicted$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
        echo "Symbol-check pass: ${sx}"
      else
        echo "Symbol-check pass: ${sx} — INCOMPLETE"
      fi
    fi
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
    printf '%s\n' "$obs" | while IFS=$'\t' read -r otext ovia; do echo "  - ${otext} (via ${ovia})"; done
    echo
  fi

  echo "———"
  echo "🤖 Star review gate summary — primary ${primary}. Human gate decides; nothing auto-merges."

  if (( flag_independence )); then
    # Admitted providers are derived above from the document's own roster and quarantine records —
    # still no manifest sidecar, so gate-summary stays standalone over just <doc>
    # <primary-model-id>. Reusing `admitted` rather than re-deriving keeps one notion of who
    # counted (issue #59).
    local pvendor admitted_xvendor=0 p v q_xvendor qp qv
    pvendor="$("$REVIEWER_SH" vendor-of-model "$primary" 2>/dev/null || echo unknown)"
    for p in $admitted; do
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
  # `reviewers:` list off the mode hint, via the shared helper — same roster gate-summary reads,
  # so the two functions cannot disagree about who reviewed (issue #59). The helper also validates
  # the hint, which the old inline `grep -o` did not.
  #
  # The `|| die` is what makes the helper's refusal reach here, and it is the whole guard. NOT the
  # absence of a pipe: this script sets `pipefail` (:23), so a pipeline propagates the first
  # non-zero status — piping through `tr` would not have swallowed it. What swallowed it before
  # #59 was having no status check at all: the line read `hintp="$(_roster "$doc" | tr …)"` with
  # nothing testing `$?`, so the die printed to stderr while this function carried on with an
  # empty roster and printed a wrong verdict. The newline->space join the awk below expects is a
  # SECOND step, after the status has been checked.
  hintp="$(_roster "$doc")" || die "round-stats: malformed roster in ${doc}" 1
  hintp="$(printf '%s' "$hintp" | tr '\n' ' ')"

  # quar/hintp go through the ENVIRONMENT, not `awk -v`: -v values cannot contain a literal
  # newline (two quarantine records in one doc made awk die "newline in string"), and -v also
  # escape-processes backslashes. Same reason cmd_merge passes its block via ENVIRON.
  printf '%s\n' "$t" | RS_QUAR="$quar" RS_HINTP="$hintp" RS_PASSES="$STAR_PASSES" \
    awk -F'\t' -v rounds="$round" -v maxr="$max" '
    BEGIN {
      nq = split(ENVIRON["RS_QUAR"], ql, "\n")
      for (i = 1; i <= nq; i++) {
        if (ql[i] == "") continue
        split(ql[i], q, " "); Q[q[1] SUBSEP (q[2]+0)] = 1; provs[q[1]] = 1
      }
      np = split(ENVIRON["RS_HINTP"], hp, " ")
      for (i = 1; i <= np; i++) if (hp[i] != "") provs[hp[i]] = 1
      # STAR_PASSES (issue #90, final review B3) — mirrors gate-summary excluding a pass raiser
      # identity from the ADMITTED set. NB: no apostrophes in this comment or below — this awk
      # program is single-quoted in the shell and one ends it mid-flight. Without this exclusion a
      # merged pass (e.g. crossref) reads here as its own provider: it gets a column, inflates
      # tot[r], drives the trend glyph and dry streak, and can steer the converge/re-fan verdict
      # the primary reads at the gate.
      npa = split(ENVIRON["RS_PASSES"], pa, " ")
      for (i = 1; i <= npa; i++) if (pa[i] != "") PASSES[pa[i]] = 1
    }
    NF {
      # provider is the ns-id prefix before "-rd"; round is the digits that follow it. Same
      # split gate-summary uses, so the two can never disagree about who raised what.
      split($1, pp, "-rd")
      p = pp[1]; r = pp[2]; sub(/-.*/, "", r)
      if (p == "" || r+0 < 1) next
      if (p in PASSES) next
      C[p SUBSEP (r+0)]++; provs[p] = 1
      # Severity, per round. Column 7 of _table has always carried it; the verdict below counted
      # findings and never looked (issue #47 item 5). Findings are not fungible: a stale docstring
      # and a false certificate are one each.
      if ($7 == "high") HI[r+0]++
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
        # Issue #38. This used to read "re-fan — round 1, no trend yet", so the only QUANTITATIVE
        # signal in the loop argued against the protocol on every single review: one round IS the
        # default (docs/multi-review.md), and a primary deferring to the number re-fanned every
        # time — the standing behaviour issue #29 set out to end. "No trend yet" is true and is
        # not a reason to spend another fan-out; the triggers are named so a primary that SHOULD
        # re-fan still knows when. NB: no apostrophes anywhere in this awk program — it is
        # single-quoted in the shell and one ends the program mid-flight (this comment did it).
        v = "converge — round 1 is the default; re-fan only if you agreed to a non-trivial high, your edits introduced new logic no reviewer has seen, or the engineer asked for depth"
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
      # A converge verdict computed from COUNTS must not stay silent about the SEVERITY of what
      # the final round raised. Demonstrated (#47 item 5): two `low` -> two `high` reads as "flat"
      # and is advised to stop, while two `low` -> one `high` reads as "decaying" and is advised
      # to continue — the count drove both, and the round that ESCALATED is the one told to stop.
      #
      # This appends rather than overrides. Whether to re-fan is the primary'"'"'s call and the
      # triggers above still govern it (one round is the default, #29); what the verdict owes the
      # reader is not to present a round that raised new highs as if it were saturation.
      if (v ~ /^converge/ && HI[rounds+0] > 0)
        v = v "; round " rounds " raised " HI[rounds+0] " new high-severity finding(s) — weigh those at the gate before treating this as saturation"
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

# ---- fix witnesses (spec 2026-09-01, Part A) -----------------------------------------------------
# A `> — witness:` line on an [agree:] or [resolved:] names, in backticks, what goes red if the fix
# is wrong. Every backticked token must RESOLVE: for a local doc, in the body outside ## Review; for
# a PR scratch, in an ADDED line of ## Diff — the author's push is the fix, so a witness that is not
# in the push is not a witness for it. Flavor is read from the document, never from a flag.

_doc_flavor() { # <doc> -> "pr" when the header carries pr.sh's own `- **PR:** <url>` identity line, else "local"
  # The header region, not a bare "## Diff" heading: a local plan may legitimately carry a Diff
  # section, and pr.sh both writes this line at ingest and reads it back to publish (fable-rd2-r3).
  if grep -qE '^- \*\*PR:\*\* ' <<<"$(header_region "$1")"; then echo pr; else echo local; fi
}

_witness_corpus() { # <doc> <outfile> — the text a witness token must occur in
  if [[ "$(_doc_flavor "$1")" == pr ]]; then
    # A raw scan is right here: every line of a hunk carries a `+`/`-`/` ` sign, so no "## " line
    # can occur inside the diff, and the section ends at the first real heading after it.
    awk '/^## Diff[[:space:]]*$/ { d = 1; next } d && /^## / { d = 0 } d && /^\+/ && !/^\+\+\+ / { print substr($0, 2) }' "$1" > "$2"
  else
    # The body is everything before the review section — the SAME boundary `_table` reads
    # (review_section_start), so corpus and table can never disagree about where the channel
    # begins. That helper's raw scan is a pre-existing limit (a fenced "## Review" inside the
    # review section moves both), not one this branch could fix alone.
    local n; n="$(review_section_start "$1")"
    if (( n > 0 )); then head -n "$((n - 1))" "$1" > "$2"; else cat "$1" > "$2"; fi
  fi
}

# _witness_verdict <kind> <witness> <corpus-file> -> ok | none | missing | unresolved:<token> | on-dispute
_witness_verdict() {
  local kind="$1" w="$2" corpus="$3" rest tok found=0
  [[ "$kind" != dispute ]] || { echo on-dispute; return 0; }     # a dispute changes nothing
  [[ -n "$w" ]] || { echo missing; return 0; }
  case "$w" in none|none\ *) echo none; return 0 ;; esac         # a recorded decision, like SURVIVES-BY-DESIGN
  rest="$w"
  while [[ "$rest" == *\`*\`* ]]; do
    rest="${rest#*\`}"; tok="${rest%%\`*}"; rest="${rest#*\`}"; found=1
    # An EMPTY token (a bare ``) must not resolve: `grep -F ""` matches any non-empty corpus, so
    # a witness naming nothing would pass the gate by naming nothing (codex-rd1-r1).
    [[ -n "$tok" ]] || { echo "unresolved:(empty-token)"; return 0; }
    grep -qF -- "$tok" "$corpus" || { echo "unresolved:${tok}"; return 0; }
  done
  if (( found )); then echo ok; else echo "unresolved:(no-backticked-token)"; fi
}

# _witnesses <doc> -> "id\tkind\tverdict\twitness" for every agree, every resolved record, and every
# dispute that (wrongly) carries a witness. kind is agree | resolved | dispute.
#
# PR flavor: an agree's witness is structurally impossible at agree time — the primary never edits
# the diff, so the fix is the author's FUTURE push and no token can sit in the CURRENT ## Diff.
# There the witness belongs on the [resolved:] record; an agree without one is not a gap, and an
# agree that carries one is still checked (fable-rd1-r5).
_witnesses() {
  local doc="$1" t rsv corpus id kind w pr=0
  t="$(_table "$doc")" || return 2
  rsv="$(cmd_resolved "$doc")" || return 2
  corpus="$(mktemp)" || die "mktemp failed" 2
  _witness_corpus "$doc" "$corpus"
  [[ "$(_doc_flavor "$doc")" != pr ]] || pr=1
  { printf '%s\n' "$t"   | awk -F'\t' -v pr="$pr" 'NF && $3 == "agreed" && (pr == 0 || $10 != "") { print $1 "\tagree\t" $10 }
                                       NF && $3 == "dissent" && $10 != "" { print $1 "\tdispute\t" $10 }'
    printf '%s\n' "$rsv" | awk -F'\t' 'NF { print $1 "\tresolved\t" $4 }'
  } | while IFS=$'\t' read -r id kind w; do
    [[ -n "$id" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$id" "$kind" "$(_witness_verdict "$kind" "$w" "$corpus")" "$w"
  done
  rm -f "$corpus"
}

cmd_witness_gaps() { # <doc> -> "<ns-id>\t<round>\t<verdict>" per gap; a report, exit 0 on any readable doc
  local doc="${1:?doc}" wt
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  wt="$(_witnesses "$doc")" || die "witness-gaps: contract violation in $doc" 1
  # TAB-separated: a verdict carries the offending token verbatim, which may contain spaces.
  printf '%s\n' "$wt" | awk -F'\t' 'NF && $3 != "ok" && $3 != "none" {
    rd = "?"; if (match($1, /-rd[0-9]+/)) rd = substr($1, RSTART + 3, RLENGTH - 3)
    print $1 "\t" rd "\t" $3 }'
}

# refan-check <doc> -> 0 no current-round witness gap · 1 gaps (listed on stderr) · 2 usage
# Runs BEFORE the marker bump, like verify: the current round is read from the marker at call time,
# so after the bump every current-round gap reads as an earlier-round one and this passes vacuously.
# Current-round AGREES are those on findings whose id carries the current round (a finding is
# adjudicated in the round it merges). EVERY resolved record counts: a record names an earlier-round
# finding by rule, so its own round cannot be read from the id — and it is a primary claim the
# primary owns regardless of when it was written.
cmd_refan_check() {
  local doc="${1:?doc}" cur wt gaps
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  cur="$("${STAR_DIR}/multi-review-core.sh" marker "$doc" 2>/dev/null | awk '{print $2}')" || cur=""
  [[ -n "$cur" ]] || die "refan-check: ${doc} carries no readable state marker — the current round cannot be determined" 2
  wt="$(_witnesses "$doc")" || die "refan-check: contract violation in $doc" 1
  # Agrees and resolved records only: a witness on a DISPUTE is a grammar slip the gate reports
  # (`on-dispute`), never a reason to hold a re-fan — a dispute changes nothing (codex-rd2-r1).
  gaps="$(printf '%s\n' "$wt" | awk -F'\t' -v cur="$cur" 'NF && $3 != "ok" && $3 != "none" && $2 != "dispute" {
    rd = -1; if (match($1, /-rd[0-9]+/)) rd = substr($1, RSTART + 3, RLENGTH - 3) + 0
    if ($2 == "resolved" || rd == cur + 0) print $1 " " $2 " " $3 }')"
  if [[ -n "$gaps" ]]; then
    echo "multi-review-star: refan-check: round ${cur} has fix-witness gaps — add a \"> — witness:\" line (or \"> — witness: none — <why>\") to each before re-fanning:" >&2
    printf '%s\n' "$gaps" | sed 's/^/  /' >&2
    return 1
  fi
  echo "refan-check: ${doc} — no current-round witness gap (round ${cur})"
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
    resolved) cmd_resolved "$@" ;;
    check-primary-id) cmd_check_primary_id "$@" ;;
    merge) cmd_merge "$@" ;;
    verify) cmd_verify "$@" ;;
    check-converged) cmd_check_converged "$@" ;;
    gate-summary) cmd_gate_summary "$@" ;;
    round-stats) cmd_round_stats "$@" ;;
    evidence-gaps) cmd_evidence_gaps "$@" ;;
    witness-gaps) cmd_witness_gaps "$@" ;;
    refan-check) cmd_refan_check "$@" ;;
    channel-check) cmd_channel_check "$@" ;;
    blind-check) cmd_blind_check "$@" ;;
    compose-review) cmd_compose_review "$@" ;;
    compose-inline) cmd_compose_inline "$@" ;;
    # Test-only accessor. _roster has no CLI surface, but its empty-vs-die split (issue #59,
    # codex-rd2-r1) is a contract: asserting it only through gate-summary's output cannot tell an
    # empty roster from an ignored one. Underscore-prefixed and undocumented on purpose.
    _roster_for_test) _roster "$@" ;;
    # Same rationale: the witness column is a contract later consumers read by index.
    _table_for_test) _table "$@" ;;
    *)    die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
