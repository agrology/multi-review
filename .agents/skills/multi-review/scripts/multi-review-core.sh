#!/usr/bin/env bash
# multi-review-core.sh — deterministic marker read/init logic for multi-review review.
# Subcommands: init <doc> [max] | marker <doc> | resolve-doc | sections <doc> | blocks <doc> [<start> <end>]
# cmd_init is the only writer in this script — its marker write is atomic (temp + mv) and
# preserves the doc's mode. The star protocol (commands/multi-review.md) hand-flips the
# marker directly thereafter, following the protocol.
set -uo pipefail

die() { echo "multi-review-core: $1" >&2; exit "${2:-1}"; }

# Tolerant marker grammar: capture state, round, max without depending on the "·".
MARKER_RE='multi-review:[[:space:]]*([a-z-]+).*round[[:space:]]+([0-9]+)/([0-9]+)'
# A marker is ONLY an HTML-comment line — never a prose mention of "multi-review:".
MARKER_GREP='<!--[[:space:]]*multi-review:'

# Marker detection is scoped to the HEADER region — lines before the first "## " section
# heading. The status marker is always inserted at the top (after the H1), so this finds it
# while ignoring marker-shaped lines deeper in the doc — e.g. a PR-mode scratch embeds the PR
# diff under "## Diff", which can legitimately contain quoted "<!-- multi-review: ... -->".
header_region() { awk '/^## /{ exit } { print }' "$1"; }

read_marker() { # <doc> -> sets MK_STATE MK_ROUND MK_MAX; returns 1 unless EXACTLY one valid marker
  local doc="$1" line n
  n="$(header_region "$doc" | grep -cE "$MARKER_GREP" 2>/dev/null)" || n=0
  (( n == 1 )) || return 1            # 0 = none; >1 = split-brain — reject, don't pick one
  line="$(header_region "$doc" | grep -E "$MARKER_GREP" | head -1)"
  [[ "$line" =~ $MARKER_RE ]] || return 1
  MK_STATE="${BASH_REMATCH[1]}"; MK_ROUND="${BASH_REMATCH[2]}"; MK_MAX="${BASH_REMATCH[3]}"
  case "$MK_STATE" in
    awaiting-reviewer|awaiting-author|awaiting-secondaries|awaiting-primary|converged|exhausted) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_marker() {
  local doc="$1"
  read_marker "$doc" || die "no valid marker in: $doc" 1
  echo "${MK_STATE} ${MK_ROUND} ${MK_MAX}"
}

# Emit only lines OUTSIDE fenced code blocks (``` or longer), so a doc that *documents* the
# protocol — quoting "> [reviewer:...]" inside a code block — isn't parsed as live threads.
# CommonMark fence rules, no awk interval exprs (macOS awk lacks them): an opening fence is a
# line of >=3 backticks (info string allowed); it closes only on a line of >= that many
# backticks with nothing else but spaces.
strip_fences() { # <file>
  awk '
    {
      s = $0
      sub(/^ ? ? ?/, "", s)                 # CommonMark allows up to 3 leading spaces
      ticks = 0
      if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) {
          rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { infence = 0; fence_len = 0; next }   # closing fence
        }
        next                                  # inside fence — drop
      }
      if (ticks >= 3) { infence = 1; fence_len = ticks; next }    # opening fence — drop
      print
    }
  ' "$1"
}

# The line where a fence opened but never closed, else empty. An unterminated fence makes
# strip_fences silently drop EVERY line after it — including live protocol threads — so a doc
# with one would parse as "no open threads" and could falsely converge. Callers must refuse.
unterminated_fence_line() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence = 0; fence_len = 0 } }
      } else if (ticks >= 3) { infence = 1; fence_len = ticks; open_ln = NR }
    }
    END { if (infence) print open_ln }
  ' "$1"
}

preserve_mode() { # <src> <dst> — best-effort: mktemp creates 0600; keep the doc's own mode
  local mode
  mode="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" || return 0
  [[ -n "$mode" ]] && chmod "$mode" "$2" 2>/dev/null
  return 0
}

cmd_init() { # <doc> [max] — insert the round-1 marker after the H1 if absent (idempotent)
  local doc="$1" max="${2:-10}" tmp marker n
  { [[ "$max" =~ ^[0-9]+$ ]] && (( max >= 1 )); } \
    || die "max rounds must be a positive integer, got '${max}'" 2
  n="$(header_region "$doc" | grep -cE "$MARKER_GREP" 2>/dev/null)" || n=0
  (( n > 1 )) && die "doc already has multiple markers (corrupt): $doc" 1
  if (( n == 1 )); then
    # Exactly one marker-like comment exists — only idempotent if it actually parses.
    read_marker "$doc" || die "doc has a malformed multi-review marker: $doc" 1
    return 0                          # already armed — idempotent
  fi
  marker="<!-- multi-review: awaiting-reviewer · round 1/${max} -->"
  # Assumes the doc is H1-first (the spec/plan convention here): the marker goes after line 1.
  # A doc opening with YAML frontmatter would get the marker inside the `---` block — not a
  # supported input (all design docs in this workflow start with `# Title`).
  tmp="$(mktemp "${doc}.tmp.XXXXXX")" || die "cannot create temp file for: $doc" 1
  preserve_mode "$doc" "$tmp"
  if awk -v m="$marker" 'NR==1 { print; print ""; print m; next } { print }' "$doc" > "$tmp" && mv "$tmp" "$doc"; then
    # Verify, don't assume: an empty doc makes the NR==1 insert a silent no-op.
    read_marker "$doc" || die "init produced no valid marker (empty doc?): $doc" 1
    return 0
  fi
  rm -f "$tmp"                       # never leave a stale temp behind
  die "failed to insert marker into: $doc" 1
}


# ---- doc resolution (issue #35) -----------------------------------------------------------
# The default covers BOTH common layouts. `docs/specs docs/plans` alone did not match the
# superpowers skills — which write to docs/superpowers/{specs,plans} and are this plugin's most
# natural upstream — so every such repo hit the egress guard once, and a repo with BOTH layouts
# could silently resolve a stale doc from the configured pair while the real work sat unsearched.
DOC_DIRS_DEFAULT='docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans'

# _dated_docs <dir> : "<basename>\t<path>" for dated .md files DIRECTLY under <dir>.
_dated_docs() {
  local d="$1" f b
  [[ -d "$d" ]] || return 0
  for f in "$d"/*.md; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")"
    case "$b" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) printf '%s\t%s\n' "$b" "$f" ;;
    esac
  done
}

# resolve-doc : print the newest dated doc under MULTI_REVIEW_DOC_DIRS, or fail INFORMATIVELY.
# Failing informatively is the point (#35 failure mode 2): the chosen doc is always legitimately
# inside the configured dirs, so the egress guard can never catch a wrong-doc resolution. Naming
# what was searched — and any UNSEARCHED sibling that holds dated docs — is what turns a silent
# wrong answer into an obvious misconfiguration.
cmd_resolve_doc() {
  local dirs="${MULTI_REVIEW_DOC_DIRS:-$DOC_DIRS_DEFAULT}" d
  local all; all="$(mktemp)" || die "mktemp failed" 2
  for d in $dirs; do _dated_docs "$d"; done | LC_ALL=C sort -r > "$all"

  local n; n="$(grep -c . "$all" || true)"
  if (( n == 0 )); then
    rm -f "$all"
    die "no dated (YYYY-MM-DD-*.md) docs under MULTI_REVIEW_DOC_DIRS ($dirs)$(_sibling_hint "$dirs") — pass an explicit path" 1
  fi

  local first second fb sb
  first="$(head -1 "$all")"; second="$(sed -n '2p' "$all")"
  fb="${first%%$'\t'*}"; sb="${second%%$'\t'*}"
  rm -f "$all"
  if [[ -n "$second" && "${fb:0:10}" == "${sb:0:10}" ]]; then
    die "ambiguous: two docs share the newest date prefix (${fb:0:10}) — ${fb} and ${sb}; pass an explicit path" 1
  fi

  # Warn on the SUCCESS path too. This is #35's failure mode 2 and the only place it can be
  # caught: the chosen doc is legitimately inside the configured dirs, so the egress guard sees
  # nothing wrong, and a bare run would silently review a stale doc while the real work sits in
  # an unsearched sibling. Louder when that sibling's newest is NEWER than what we picked.
  local hint newest_sib
  hint="$(_sibling_hint "$dirs")"
  if [[ -n "$hint" ]]; then
    newest_sib="$(_newest_unsearched "$dirs")"
    # Decide "newer" with the SAME collation the sorts used. `[[ > ]]` honours the caller's
    # locale, so the WARNING/note choice could disagree with the ordering the pick came from
    # (fable-rd1-r2).
    local sb2; sb2="${newest_sib%%$'\t'*}"
    if [[ -n "$newest_sib" ]] \
       && [[ "$(printf '%s\n%s\n' "$fb" "$sb2" | LC_ALL=C sort -r | head -1)" == "$sb2" ]] \
       && [[ "$sb2" != "$fb" ]]; then
      echo "multi-review-core: WARNING — resolved ${first#*$'\t'}, but a NEWER dated doc exists in a directory that was not searched: ${newest_sib#*$'\t'}. Set MULTI_REVIEW_DOC_DIRS or pass an explicit path." >&2
    else
      echo "multi-review-core: note — dated docs also exist in directories that were not searched: ${hint##*: }" >&2
    fi
  fi
  printf '%s\n' "${first#*$'\t'}"
}

# _is_searched <candidate-dir> <searched-dirs> : 0 when the candidate is INSIDE (or equal to) a
# searched dir, comparing canonical paths. A literal string match made `docs/specs/`, `./docs/specs`
# or a nested `docs/specs/archive/` read as "NOT searched" and fire a false alarm on every run
# (fable-rd1-r1, fable-rd1-r6) — and the command prose tells the primary to relay that as a
# misconfiguration.
# _in_tree <dir> : 0 when <dir> RESOLVES inside the working tree. This is a REPORTING guard —
# it keeps an advisory hint from naming out-of-tree paths — NOT an arming decision, so it
# deliberately uses `pwd -P` and never `git rev-parse`: an inherited GIT_WORK_TREE can redefine
# what git calls the root (codex-rd3-r1), and no hint is worth that dependency.
# `-L` on the last component was not enough — a symlink one level up (or `docs` itself) is
# walked straight through by the globs (codex-rd2-r2, fable-rd2-r1).
_in_tree() {
  local cand="$1" cr root
  cr="$(cd "$cand" 2>/dev/null && pwd -P)" || return 1
  root="$(pwd -P)" || return 1
  case "${cr}/" in "${root}/"*) return 0 ;; esac
  return 1
}

_is_searched() {
  local cand="$1" dirs="$2" d cr sr
  cr="$(cd "$cand" 2>/dev/null && pwd -P)" || return 1
  for d in $dirs; do
    sr="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    case "${cr}/" in "${sr}/"*) return 0 ;; esac
  done
  return 1
}

# _newest_unsearched <searched-dirs> : "<basename>\t<path>" of the newest dated doc in a
# plausible sibling that was NOT searched, else empty.
_newest_unsearched() {
  local d
  { for d in docs/*/ docs/*/*/; do
      [[ -d "$d" ]] || continue
      d="${d%/}"
      _in_tree "$d" || continue
      _is_searched "$d" "$1" && continue
      _dated_docs "$d"
    done; } | LC_ALL=C sort -r | head -1
}

# _sibling_hint <searched-dirs> : ", but <dir> holds dated docs and is NOT searched" when a
# plausible sibling under docs/ has dated docs. Bounded to docs/*/ and docs/*/*/ — enough to
# spot the superpowers layout and its neighbours without a repo-wide walk.
_sibling_hint() {
  local d hits=""
  for d in docs/*/ docs/*/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    _in_tree "$d" || continue
    _is_searched "$d" "$1" && continue
    [[ -n "$(_dated_docs "$d")" ]] || continue
    hits="${hits}${hits:+, }${d}"
  done
  [[ -n "$hits" ]] && printf '; NOT searched but holds dated docs: %s' "$hits"
  return 0
}

# A SECTION is a heading whose text starts with a section keyword and an ordinal, AND which declares
# a Files/Interfaces block before its own end. Both halves are required: the ordinal alone sweeps in
# prose headings, the block alone sweeps in a preamble that happens to mention files.
#
# Exposed as a SUBCOMMAND rather than a sourced function because that is how this repo shares across
# modules (see star.sh's calls to `core.sh marker`). multi-review-crossref.sh keeps its own private
# copy deliberately — moving lines that carry passing mutation entries would risk STALE for no
# behavioural gain.
cmd_sections() { # <doc> -> "idx\tstart\tend\tshort-id\ttitle"
  [[ $# -ge 1 ]] || die "usage: multi-review-core.sh sections <doc>" 2
  [[ -f "$1" ]] || die "sections: doc not found: $1" 2
  awk '
    # FENCE STATE FIRST, and headings only outside a fence. A shell comment such as
    # "# --- setup ---" inside a fenced block is not a heading; treating it as one truncates the
    # enclosing section and silently drops the rest of its body.
    # A fence opens with THREE OR MORE backticks or tildes, and closes only with the same
    # character, at least as long (CommonMark). Tildes are not decorative here: a doc nests a block
    # by using a longer or different outer fence, which is exactly what a plan quoting a fixture
    # does, and a backtick-only parser reads that content as live document structure.
    { fs = $0; sub(/^ ? ? ?/, "", fs)
      tk = 0; fc = ""
      if (match(fs, /^`+/))      { tk = RLENGTH; fc = "`" }
      else if (match(fs, /^~+/)) { tk = RLENGTH; fc = "~" }
      # RECORD ONLY UNFENCED LINES. The `has` scan below reads lines[] raw, so a fenced
      # `**Files:**` in an illustrative block would qualify a section that ships no code — and a
      # fenced `- Create:` would inflate the introduces set, suppressing the very missing-symbol
      # defect this pass exists to catch. Verdict parsing strips fences for this reason; derivation
      # must too.
      if (infence) {
        lines[NR] = ""
        if (fc == fchar && tk >= flen) { rest = substr(fs, tk + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence = 0; flen = 0; fchar = "" } }
        next
      } else if (tk >= 3) { infence = 1; flen = tk; fchar = fc; lines[NR] = ""; next }
      lines[NR] = $0
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
        # "Task N" and "Step N" both match the ordinal pattern, so the naive rule ends a task at its
        # own first step.
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

# Fenced blocks with their line ranges and language tag, within one span of the document. Emits
# "<start>\t<end>\t<lang>" in ABSOLUTE document lines; <lang> is "-" for an untagged block. A block
# that never closes is emitted ending at the span end — an unterminated fence is itself worth a
# verdict, and dropping it would silently shrink a worklist.
#
# A fence closes only with the SAME character, at least as long (CommonMark): a ``` line inside a
# ~~~ block is content. Shared here because two consumers need it — symcheck's rows and the plan
# lint's code extraction — and a second private copy would mask the first under mutation.
cmd_blocks() { # <doc> [<start> <end>]
  [[ $# -ge 1 ]] || die "usage: multi-review-core.sh blocks <doc> [<start> <end>]" 2
  [[ -f "$1" ]] || die "blocks: doc not found: $1" 2
  local doc="$1" start="${2:-1}" end="${3:-}"
  [[ -n "$end" ]] || end="$(wc -l < "$doc" | tr -d ' ')"
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || die "blocks: start and end must be line numbers, got '${start}' '${end}'" 2
  sed -n "${start},${end}p" "$doc" | awk -v base="$start" '
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

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    marker) cmd_marker "$@" ;;
    init)   cmd_init "$@" ;;
    resolve-doc) cmd_resolve_doc "$@" ;;
    sections)     cmd_sections "$@" ;;
    blocks)       cmd_blocks "$@" ;;
    *)      die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
