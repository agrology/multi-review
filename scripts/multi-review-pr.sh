#!/usr/bin/env bash
# multi-review-pr.sh — GitHub-PR ingest/publish wrapper around the file-coordination protocol.
# The coordination engine (core/wait) is unchanged; this only seeds a local scratch
# file from a PR and, after the human gate, posts ONE neutral review back. Subcommands:
#   parse <arg>                      -> "owner|repo|number" (owner/repo empty for "#n"); exit 1 if not a PR ref
#   resolve-repo                     -> "owner|repo" for the current repo (gh)
#   scratch-path <owner> <repo> <n>  -> .multi-review/reviews/<owner>/<repo>/pr-<n>.md
#   fence <file>                     -> backtick fence >= 3 and longer than the file's longest run
#   seed <out> <title> <url> <author> <branch> <desc-file> <diff-file>
#   ingest <owner> <repo> <n>        -> fetch via gh, write scratch file, print its path
#   publish <scratch> <model>        -> compose via multi-review-star.sh and post one neutral PR review via gh
#   diff-valid-lines <scratch>       -> "path\tline" for every added/context (RIGHT-side) line in ## Diff
#   validate-anchor <scratch> <path> <start> [end] -> exit 0 iff path is changed and all lines are in the diff
#   record-diff <scratch> <body-file> -> record the sha256 of a composed diff-section body (writers only)
#   diff-span <scratch>              -> "<body-start> <body-end>" of the VERIFIED diff window; exit 3 if unverifiable
set -uo pipefail

die() { echo "multi-review-pr: $1" >&2; exit "${2:-1}"; }

cmd_parse() { # <arg> -> "owner|repo|number"; exit 1 if not a PR ref
  local arg="${1:-}" o r n
  [[ -n "$arg" ]] || return 1
  if [[ "$arg" =~ ^https?://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+) ]]; then
    o="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"
  elif [[ "$arg" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([0-9]+)$ ]]; then
    o="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"
  elif [[ "$arg" =~ ^#([0-9]+)$ ]]; then
    o=""; r=""; n="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '%s|%s|%s\n' "$o" "$r" "$n"
}

cmd_fence() { # <file> -> backtick fence: max(3, longest backtick run + 1)
  local file="${1:?file}" longest n
  longest="$(grep -oE '`+' "$file" 2>/dev/null | awk '{ if (length > m) m = length } END { print m + 0 }' || true)"
  n=$(( longest + 1 ))
  (( n < 3 )) && n=3
  printf '%*s\n' "$n" '' | tr ' ' '`'
}

cmd_seed() { # <out> <title> <url> <author> <branch> <desc-file> <diff-file>
  local out="${1:?out}" title="${2:-}" url="${3:-}" author="${4:-}" branch="${5:-}" descf="${6:?desc}" difff="${7:?diff}"
  [[ -f "$descf" ]] || die "description file not found: $descf" 1
  [[ -f "$difff" ]] || die "diff file not found: $difff" 1
  mkdir -p "$(dirname "$out")" || die "cannot create dir for: $out" 1
  local fence; fence="$(cmd_fence "$difff")"
  # Compose the diff-section body ONCE, into a file, so the bytes recorded and the bytes written are
  # the same bytes. The body is everything between the "## Diff" heading and the next "## " heading,
  # trailing blank line included — that is what a reader will digest, so it is what is recorded.
  local bodyf; bodyf="$(mktemp)" || die "mktemp failed" 1
  { printf '\n%s\n' "$fence"; cat "$difff"; printf '\n%s\n\n' "$fence"; } > "$bodyf" \
    || { rm -f "$bodyf"; die "cannot compose the diff body" 1; }
  # Record before the document exists: a crash here leaves no scratch, so `ingest` proceeds
  # normally next time rather than finding a scratch it refuses to clobber.
  cmd_record_diff "$out" "$bodyf" || { rm -f "$bodyf"; die "cannot record the diff digest" 1; }
  {
    printf '# PR review: %s\n\n' "$title"
    printf -- '- **PR:** %s\n'     "$url"
    printf -- '- **Author:** %s\n' "$author"
    printf -- '- **Branch:** %s\n\n' "$branch"
    printf '## PR description\n\n'
    cat "$descf"
    printf '\n\n## Diff\n'
    cat "$bodyf"
    printf '## Review\n'
  } > "$out" || { rm -f "$bodyf"; die "cannot write scratch file: $out" 1; }
  rm -f "$bodyf"
}

cmd_publish() { # <scratch> <model> -> post ONE neutral review via gh (star-only)
  local scratch="${1:?scratch}" model="${2:?model}" url tmp
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  # The PR url comes from the scratch file's own "- **PR:** <url>" header (written by seed from
  # `gh pr view`). Reading it here — rather than taking it as an argument — keeps publish correct
  # on resume (when the command skipped ingest) and uses the real host (e.g. GitHub Enterprise),
  # never a reconstructed github.com guess.
  url="$(grep -m1 -E '^- \*\*PR:\*\* ' "$scratch" | sed -E 's/^- \*\*PR:\*\* //')"
  [[ -n "$url" ]] || die "no PR url in scratch header ('- **PR:** ...'): $scratch" 1
  tmp="$(mktemp)" || die "mktemp failed" 1
  local dir; dir="$(cd "$(dirname "$0")" && pwd)"
  "${dir}/multi-review-star.sh" mode "$scratch" > /dev/null || die "not a star review doc: $scratch" 1
  if ! "${dir}/multi-review-star.sh" compose-review "$scratch" "$model" > "$tmp"; then
    rm -f "$tmp"; die "failed to compose star review body" 1
  fi
  cmd_post_review "$scratch" "$url" "$tmp" "$dir" "multi-review-star.sh"
  rm -f "$tmp"
}

cmd_post_review() { # <scratch> <url> <summary-file> <script-dir> [inline-script] — post summary + inline comments
  local scratch="${1:?scratch}" url="${2:?url}" summaryf="${3:?summary}" dir="${4:?dir}"
  local inline_script="${5:-multi-review-star.sh}"
  local host o r n
  if [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    host="${BASH_REMATCH[1]}"; o="${BASH_REMATCH[2]}"; r="${BASH_REMATCH[3]}"; n="${BASH_REMATCH[4]}"
  else
    die "cannot parse PR url for gh api: $url" 1
  fi

  # Gather inline records, split into valid (objects) and degraded (summary text).
  # Capture compose-inline's output AND status FIRST. A process substitution
  # (`done < <(...)`) hides the producer's exit code, so a contract-violation in
  # compose-inline would be swallowed and publish would proceed as if there were zero inline
  # records — silently posting a degraded/summary review for a malformed doc. Capturing the
  # status makes the inline path independently fail-loud, not reliant on compose-review's
  # earlier gate. A malformed doc MUST fail the post, never degrade.
  local carr inline_n=0 degraded="" degraded_n=0 path start end body concern_only inline_records rec
  carr="$(mktemp)" || die "mktemp failed" 1
  if ! inline_records="$("${dir}/${inline_script}" compose-inline "$scratch")"; then
    rm -f "$carr"; die "failed to compose inline records for $scratch (contract violation)" 1
  fi
  # compose-inline emits "path\tstart\tend\tbody" (TSV, 4 fields; end may be empty).
  # Bash `read` with IFS=$'\t' collapses consecutive tabs (tab is an IFS-whitespace char),
  # so an empty 3rd field is skipped and body lands in `end`. Use awk to split each record
  # into exactly 4 tab-separated fields, preserving the empty end field.
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    path="$(awk -F'\t' '{print $1}' <<< "$rec")"
    start="$(awk -F'\t' '{print $2}' <<< "$rec")"
    end="$(awk -F'\t' '{print $3}' <<< "$rec")"
    body="$(awk -F'\t' '{print $4}' <<< "$rec")"
    [[ -n "$path" ]] || continue
    # Re-resolve the anchor by CONTENT before validating. A no-op unless a refresh replaced the
    # diff under this finding; when one did, this follows the anchored line to its new number
    # instead of trusting a number that now points somewhere else. A line that vanished or went
    # ambiguous fails here and the finding degrades to the summary — deliberately, rather than
    # posting inline at a plausible-looking wrong place.
    local rstart rend orig_start="$start" orig_end="$end"
    if rstart="$(cmd_remap_anchor "$scratch" "$path" "$start" 2>/dev/null)"; then
      if [[ -n "$end" && "$end" != "$start" ]]; then
        # Remap the END independently. Recreating it as rstart+(end-start) assumes the range's
        # span survived, but an insertion or deletion INSIDE a surviving range changes its true
        # end — so the comment would cover unrelated lines (codex-rd1-r2). If the end cannot be
        # re-resolved, the whole anchor degrades to the summary rather than guessing its extent.
        if rend="$(cmd_remap_anchor "$scratch" "$path" "$end" 2>/dev/null)" && (( rend >= rstart )); then
          start="$rstart"; end="$rend"
        else
          start=""; end=""
        fi
      else
        start="$rstart"; end="$rstart"
      fi
    else
      start=""; end=""
    fi
    if [[ -n "$start" ]] && cmd_validate_anchor "$scratch" "$path" "$start" "${end:-$start}"; then
      if [[ -z "$end" || "$end" == "$start" ]]; then
        jq -n --arg path "$path" --argjson line "$start" --arg body "$body" \
          '{path:$path, line:$line, side:"RIGHT", body:$body}' >> "$carr"
      else
        jq -n --arg path "$path" --argjson sl "$start" --argjson line "$end" --arg body "$body" \
          '{path:$path, start_line:$sl, start_side:"RIGHT", line:$line, side:"RIGHT", body:$body}' >> "$carr"
      fi
      inline_n=$(( inline_n + 1 ))
    else
      concern_only="${body%% — 🤖 *}"
      # Report the ORIGINAL anchor: a failed remap clears start/end, and printing those
      # would render "- path: — concern" with no location at all (fable-rd2-r6).
      degraded+="- ${path}:${orig_start}${orig_end:+-${orig_end}} — ${concern_only}"$'\n'
      degraded_n=$(( degraded_n + 1 ))
    fi
  done <<< "$inline_records"

  # Zero valid inline comments -> existing behavior (byte-identical for anchor-free docs).
  if (( inline_n == 0 )); then
    rm -f "$carr"
    if gh pr review "$url" --comment --body-file "$summaryf"; then
      echo "posted review to ${url}"; return 0
    fi
    die "gh pr review failed for ${url}" 1
  fi

  # Build the summary body: note inline + degraded above the composed review.
  local bodyf
  bodyf="$(mktemp)" || { rm -f "$carr"; die "mktemp failed" 1; }
  {
    printf '**Commented inline (%d)**\n' "$inline_n"
    if (( degraded_n > 0 )); then
      printf '\n**Could not place inline (%d)**\n%s' "$degraded_n" "$degraded"
    fi
    printf '\n'
    cat "$summaryf"
  } > "$bodyf"

  local payload
  payload="$(mktemp)" || { rm -f "$carr" "$bodyf"; die "mktemp failed" 1; }
  jq -s --rawfile body "$bodyf" '{event:"COMMENT", body:$body, comments:.}' "$carr" > "$payload"

  if gh api --hostname "$host" --method POST "repos/${o}/${r}/pulls/${n}/reviews" --input "$payload"; then
    rm -f "$carr" "$bodyf" "$payload"
    echo "posted review with ${inline_n} inline comment(s) to ${url}"; return 0
  fi

  # API rejected the whole review (e.g. a mis-parsed hunk). Retry once, summary-only.
  rm -f "$carr" "$bodyf" "$payload"
  if gh pr review "$url" --comment --body-file "$summaryf"; then
    echo "inline post rejected; posted summary-only review to ${url}" >&2; return 0
  fi
  die "gh api reviews and the summary-only retry both failed for ${url}" 1
}

cmd_resolve_repo() { # -> "owner|repo" for the current repo's default remote
  local nwo
  nwo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" || die "cannot resolve current repo via gh" 1
  [[ "$nwo" == */* ]] || die "unexpected repo identity from gh: ${nwo}" 1
  printf '%s|%s\n' "${nwo%%/*}" "${nwo#*/}"
}

cmd_ingest() { # [--fresh] <owner> <repo> <number> -> writes scratch file, prints its path
  local fresh=0
  [[ "${1:-}" == "--fresh" ]] && { fresh=1; shift; }
  local o="${1:?owner}" r="${2:?repo}" n="${3:?number}"
  # gh resolves a PR by NUMBER scoped with --repo. The "owner/repo#n" form is read as a branch
  # name ("no pull requests found for branch ..."), so select by number and pass --repo.
  local ref="$n" repo="${o}/${r}"
  local out; out="$(cmd_scratch_path "$o" "$r" "$n")"
  # Resume safety (r1): never clobber an existing scratch file. The command flow re-ingests
  # only when the file is absent (or the engineer explicitly chose a fresh review -> --fresh).
  if [[ -e "$out" && $fresh -eq 0 ]]; then
    die "scratch file exists (resume, do not re-ingest): ${out} — pass --fresh to overwrite" 1
  fi
  local tmpd; tmpd="$(mktemp -d)" || die "mktemp failed" 1
  # cleanup even if cmd_seed die()s on a write failure. ${tmpd:-} so the EXIT trap is safe
  # under `set -u` once the function has returned and the local is out of scope.
  trap 'rm -rf "${tmpd:-}"' EXIT INT TERM
  local meta descf="${tmpd}/desc" difff="${tmpd}/diff"
  # NOTE: title is single-line on GitHub; the @tsv split tolerates that (no embedded tabs).
  if ! meta="$(gh pr view "$ref" --repo "$repo" --json title,url,author,headRefName --jq '[.title,.url,.author.login,.headRefName] | @tsv')"; then
    rm -rf "$tmpd"; die "gh pr view failed for ${repo}#${ref}" 1
  fi
  if ! gh pr view "$ref" --repo "$repo" --json body --jq '.body' > "$descf"; then
    rm -rf "$tmpd"; die "gh pr view (body) failed for ${repo}#${ref}" 1
  fi
  if ! gh pr diff "$ref" --repo "$repo" > "$difff"; then
    rm -rf "$tmpd"; die "gh pr diff failed for ${repo}#${ref}" 1
  fi
  local title url author branch
  IFS=$'\t' read -r title url author branch <<< "$meta"
  cmd_seed "$out" "$title" "$url" "$author" "$branch" "$descf" "$difff"
  # Record the round-1 head/merge-base. The record is an INPUT to the first `refresh`, not only
  # an output of it — without this, PR scoping has no `since` revision and cannot start at all.
  local hb hsha hmb
  hb="$(_head_and_merge_base "$repo" "$ref" "$n")"
  IFS='|' read -r hsha hmb <<< "$hb"
  [[ -n "$hsha" ]] && cmd_record_head "$out" 1 "$hsha" "$hmb"
  rm -rf "$tmpd"
  echo "$out"
}

cmd_scratch_path() { # <owner> <repo> <number>
  local o="${1:?owner}" r="${2:?repo}" n="${3:?number}"
  printf '.multi-review/reviews/%s/%s/pr-%s.md\n' "$o" "$r" "$n"
}

# ---- the diff window is a RECORDED FACT, not a text bound -------------------------------------
# Three earlier attempts bounded this window by heading text and each drew a `high`: the LAST
# "## Diff" anywhere was steerable from BELOW (a heading in the review channel, which
# `namespace_blocks` copies at column 0), bounding at the FIRST "## Review" was steerable from
# ABOVE (the PR description closes the window before the real heading), and neither was
# fence-aware, so a benign fenced layout example in the description emptied the window and made
# `replace-diff` splice INTO the description. The scratch has NO trusted region — title,
# description and diff are all author-written — so no bound over its free text can be sound.
#
# So the window is not located by text at all. The two writers that ever compose it (`seed`,
# `replace-diff`) digest the exact bytes they composed and record the digest in the sidecar; a
# reader accepts the ONE "## Diff" section whose body matches a recorded digest. Enumeration is a
# reader-only operation: a writer has no digest to select a candidate with, so an enumerating
# writer would fall back to text order and record a decoy's digest as ground truth.
# See docs/specs/2026-07-30-pr-diff-window-invariant.md.

_diff_digest() { shasum -a 256 | cut -d' ' -f1; }   # stdin -> sha256; never via $(...) on the body

cmd_record_diff() { # <scratch> <body-file> — record the digest of the body the CALLER composed
  local scratch="${1:?scratch}" bodyf="${2:?body-file}" d rf
  [[ -f "$bodyf" ]] || die "diff body file not found: $bodyf" 1
  d="$(_diff_digest < "$bodyf")" || die "cannot digest the diff body" 1
  [[ -n "$d" ]] || die "empty digest for the diff body" 1
  rf="$(_records_path "$scratch")"
  mkdir -p "$(dirname "$rf")" || die "cannot create dir for: $rf" 1
  # Records ACCUMULATE, append-only, like the head records in the same sidecar. Nothing is ever
  # replaced, so "last wins" never has to be defined, and `replace-diff` can append BEFORE its
  # rename — leaving no crash window in which neither the old nor the new body matches a record.
  printf '<!-- multi-review-pr-diff: %s -->\n' "$d" >> "$rf" || die "cannot write diff record: $rf" 1
}

_locate_diff() { # <scratch> -> "<body-start> <body-end>"; exit 3 if not EXACTLY one match
  local scratch="${1:?scratch}" rf recs s e d n=0 got=""
  rf="$(_records_path "$scratch")"
  recs="$(grep -oE 'multi-review-pr-diff: [0-9a-f]{64}' "$rf" 2>/dev/null | awk '{print $2}')"
  if [[ -z "$recs" ]]; then
    echo "multi-review-pr: no recorded diff digest for ${scratch} — the diff window cannot be verified" >&2
    return 3
  fi
  # Candidate spans: each "## Diff" heading to the line before the next "## " (or EOF). A "## Diff"
  # cannot be forged INSIDE a real diff — every hunk line carries a +/-/space prefix — so the real
  # section always extracts correctly even when the document also contains decoys. The digest, not
  # the position, decides which candidate is the window, which is why fence-awareness is moot here.
  while read -r s e; do
    d="$(awk -v s="$s" -v e="$e" 'NR >= s && NR <= e' "$scratch" | _diff_digest)"
    if printf '%s\n' "$recs" | grep -qxF "$d"; then n=$((n + 1)); got="$s $e"; fi
  done < <(awk '
    /^## / {
      if (h) { print (h + 1) " " (NR - 1); h = 0 }
      if ($0 ~ /^## Diff[[:space:]]*$/) h = NR
      next
    }
    END { if (h) print (h + 1) " " NR }
  ' "$scratch")
  if (( n == 0 )); then
    echo "multi-review-pr: no '## Diff' section in ${scratch} matches a recorded digest — refusing to guess the diff window" >&2
    return 3
  fi
  # Never "first match wins": under that rule a decoy above the real section takes the window and
  # `replace-diff` splices there, deleting the description tail and the real diff (codex-rd1-r1).
  if (( n > 1 )); then
    echo "multi-review-pr: ${n} '## Diff' sections in ${scratch} match a recorded digest — ambiguous diff window, refusing" >&2
    return 3
  fi
  printf '%s\n' "$got"
}

cmd_diff_span() { # <scratch> -> "<body-start> <body-end>" for the verified window
  local scratch="${1:?scratch}"
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  _locate_diff "$scratch"
}

_diff_section() { # <scratch> -> ONLY the verified diff body; exit 3 if it cannot be verified
  local span
  span="$(_locate_diff "$1")" || return $?
  awk -v s="${span%% *}" -v e="${span##* }" 'NR >= s && NR <= e' "$1"
}

cmd_diff_valid_lines() { # <scratch> -> "path\tnewline" for added/context (RIGHT-side) lines
  local scratch="${1:?scratch}" sect
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  # Status 3, not an empty result: "no changed lines" and "the parser lost the diff" must not be
  # indistinguishable. Callers degrade the anchor to the summary; the review still posts.
  sect="$(_diff_section "$scratch")" || return 3
  printf '%s\n' "$sect" | awk '
    # A "+++ " line declares a path ONLY in the header region between "diff --git" and the first
    # "@@" (fable-rd1-r2). Inside a hunk it is CONTENT: an added line whose text is "++ b/x"
    # renders as "+++ b/x", and honouring it there let a malicious push steer an agreed finding
    # inline to an attacker-chosen path:line. "diff --git" cannot be forged as hunk content for
    # the same reason "## Diff" cannot — hunk lines are always prefixed.
    /^diff --git / { inhdr = 1; inhunk = 0; path = ""; next }
    # A combined diff (`diff --cc`, `@@@` hunks) has a different column layout; without an explicit
    # reset its records were accepted as added/context lines of the PREVIOUS file (codex-rd2-r1).
    /^diff --cc |^diff --combined / { inhdr = 0; inhunk = 0; path = ""; next }
    /^@@@/ { inhdr = 0; inhunk = 0; path = ""; next }
    /^@@ / {
      inhdr = 0; inhunk = 1
      if (match($0, /\+[0-9]+/)) newline = substr($0, RSTART + 1, RLENGTH - 1) + 0
      next
    }
    /^`+[[:space:]]*$/ { next }
    inhdr && /^--- / { next }
    inhdr && /^\+\+\+ / {
      p = $0; sub(/^\+\+\+ /, "", p); sub(/\t.*$/, "", p)   # git appends a TAB when the path has a space
      if (p == "/dev/null") { path = "" } else { sub(/^b\//, "", p); path = p }
      next
    }
    !inhunk { next }
    path == "" || newline == 0 { next }
    /^\+/ { print path "\t" newline; newline++; next }
    /^ /  { print path "\t" newline; newline++; next }
    /^-/  { next }
  '
}

cmd_validate_anchor() { # <scratch> <path> <start> [end] -> exit 0 if every line is in the diff
  local scratch="${1:?scratch}" path="${2:?path}" start="${3:?start}" end="${4:-${3}}" valid
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 1
  (( end >= start )) || return 1
  valid="$(cmd_diff_valid_lines "$scratch")" || return 1
  printf '%s\n' "$valid" | awk -F'\t' -v p="$path" -v s="$start" -v e="$end" '
    $1 == p { have[$2] = 1 }
    END { for (i = s; i <= e; i++) if (!(i in have)) exit 1; exit 0 }
  '
}

# ---- Phase B: per-round head records ----------------------------------------------------
# A scoped PR round needs to know what the head and merge-base were at the PREVIOUS round, so
# each round's pair is recorded durably in the scratch header. Records ACCUMULATE and are
# immutable: publish reads them to decide whether an anchor is still resolvable, so silently
# rewriting one would change the meaning of an already-merged finding.
#
# Shape mirrors the quarantine line, and therefore parses with the same kind of reader:
#   <!-- multi-review-pr-head: <head-sha> · merge-base <sha> · round <N> -->
#
# "merge-base", NOT the base branch tip: the tip advances on every unrelated merge to the base
# branch (so an equality guard would degrade every round), while the merge-base moves only when
# the PR branch actually absorbs upstream — which is exactly the case a scoped delta must refuse.

# Control records live in a SIDECAR, never in the scratch. There is no region of the scratch
# that is safe to hold them: the diff legitimately contains record lines (this repo's own PRs
# do), the PR description is author-written, and so is the TITLE — which seed embeds verbatim as
# line 1, inside what a "header region" rule would call trusted (fable-rd2-r1). Any in-document
# scheme is a parsing problem over attacker-influenced text. A sidecar removes the class: the
# file is written only by this script, so nothing a PR author controls can ever appear in it.
# Same pattern the manifest already uses.
_records_path() { printf '%s.records\n' "$1"; }

cmd_head_record() { # <scratch> <round> -> "head|merge-base"; exit 1 if this round has no record
  local scratch="${1:?scratch}" round="${2:?round}" line
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  [[ "$round" =~ ^[0-9]+$ ]] || die "round must be a number" 1
  while IFS= read -r line; do
    [[ "$line" =~ multi-review-pr-head:[[:space:]]*([^[:space:]]+)[[:space:]]*·[[:space:]]*merge-base[[:space:]]+([^[:space:]]+)[[:space:]]*·[[:space:]]*round[[:space:]]+([0-9]+) ]] || continue
    if (( ${BASH_REMATCH[3]} == round )); then
      printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0
    fi
  done < <(grep -F 'multi-review-pr-head' "$(_records_path "$scratch")" 2>/dev/null)
  return 1
}

cmd_record_head() { # <scratch> <round> <head-sha> <merge-base-sha>
  local scratch="${1:?scratch}" round="${2:?round}" head="${3:?head}" mb="${4:?merge-base}"
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  [[ "$round" =~ ^[0-9]+$ ]] || die "round must be a number" 1
  cmd_head_record "$scratch" "$round" >/dev/null 2>&1 \
    && die "head record already exists for round ${round} (records are immutable)" 1
  local rf; rf="$(_records_path "$scratch")"
  printf '<!-- multi-review-pr-head: %s · merge-base %s · round %s -->\n' "$head" "$mb" "$round" \
    >> "$rf" || die "cannot write head record: $rf" 1
}

cmd_replace_diff() { # <scratch> <diff-file> — swap ## Diff, preserve everything else
  local scratch="${1:?scratch}" difff="${2:?diff-file}"
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  [[ -f "$difff"   ]] || die "diff file not found: $difff" 1
  # The window comes from the shared locator, never from a heading search — that search is what
  # three attempts got wrong in three directions. A window that cannot be VERIFIED is not written
  # to: silently destroying the description and the previous round's diff is far worse than a
  # stalled refresh the engineer can see.
  local span
  span="$(_locate_diff "$scratch")" \
    || die "cannot verify the diff window in ${scratch} — refusing to write (see the reason above)" 1
  local bstart="${span%% *}" bend="${span##* }"
  local fence; fence="$(cmd_fence "$difff")"
  local bodyf; bodyf="$(mktemp)" || die "mktemp failed" 1
  { printf '\n%s\n' "$fence"; cat "$difff"; printf '%s\n\n' "$fence"; } > "$bodyf" \
    || { rm -f "$bodyf"; die "cannot compose the diff body" 1; }
  # Append the record BEFORE the rename. Records accumulate and a reader matches against ANY of
  # them, so neither crash window is unrecoverable: before the rename the old body still matches
  # the old record, after it the new body matches the new one. Recording after the rename would
  # leave a document no record matches, wedging every later read and write with nothing to run.
  cmd_record_diff "$scratch" "$bodyf" || { rm -f "$bodyf"; die "cannot record the diff digest" 1; }
  local tmp; tmp="$(mktemp)" || { rm -f "$bodyf"; die "mktemp failed" 1; }
  # Splice on the located span, so every byte outside the body — description, header, and the whole
  # review channel from its heading on — is carried through untouched.
  {
    head -n $((bstart - 2)) "$scratch"
    printf '## Diff\n'
    cat "$bodyf"
    tail -n +$((bend + 1)) "$scratch"
  } > "$tmp" || { rm -f "$tmp" "$bodyf"; die "cannot write replacement diff" 1; }
  mv "$tmp" "$scratch" || { rm -f "$tmp" "$bodyf"; die "cannot update: $scratch" 1; }
  rm -f "$bodyf"
}

# _head_and_merge_base <repo> <ref> <number> -> "head|merge-base"
# merge-base is "-" when it cannot be computed locally (no git repo, unfetchable fork head, base
# branch not present). "-" is a RECORDED UNKNOWN, not a silent zero: pr-copy treats it as a
# cannot-scope condition and the round degrades to the full document with that reason, which is
# strictly better than recording nothing and leaving the first refresh with no `since` to read.
_head_and_merge_base() {
  local repo="${1:?repo}" ref="${2:?ref}" number="${3:?number}" meta head base mb=""
  meta="$(gh pr view "$ref" --repo "$repo" --json headRefOid,baseRefName \
            --jq '[.headRefOid,.baseRefName] | @tsv' 2>/dev/null)" || { printf '|-\n'; return 0; }
  IFS=$'\t' read -r head base <<< "$meta"
  [[ -n "$head" ]] || { printf '|-\n'; return 0; }
  # Only consult `origin` when it actually is this PR's base repo. Otherwise the merge-base is
  # computed against an unrelated history (moving between rounds purely via a fetch, and
  # producing a misleading "branch absorbed upstream" reason) and the fetch writes into an
  # unrelated object store (fable-rd1-r4).
  # EXACT owner/repo match on the URL's path, not a substring: `o/r` matches inside
  # `.../o/r2.git`, and `o/ba` matches across the slash in `.../foo/bar.git`, so a substring test
  # re-admits the very failure it was added to prevent (codex-rd2-r2, fable-rd2-r2).
  local origin_url="" origin_slug=""
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  origin_slug="$(printf '%s' "$origin_url" | sed -E 's#^[^:]+://[^/]+/##; s#^[^:]+:##; s#\.git$##; s#/+$##')"
  if [[ "$origin_slug" != "$repo" ]]; then
    printf '%s|-\n' "$head"; return 0
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    # A fork PR's head is not in the local object store; GitHub exposes it on the BASE repo as
    # refs/pull/<n>/head, so fetch that rather than degrading (the alternative disables scoping
    # for essentially every external contribution).
    git cat-file -e "${head}^{commit}" 2>/dev/null \
      || git fetch -q origin "refs/pull/${number}/head" 2>/dev/null || true
    mb="$(git merge-base "origin/${base}" "$head" 2>/dev/null)" \
      || mb="$(git merge-base "$base" "$head" 2>/dev/null)" || mb=""
  fi
  printf '%s|%s\n' "$head" "${mb:--}"
}

cmd_refresh() { # <scratch> <round> — re-fetch the diff at the current head for a new round
  local scratch="${1:?scratch}" round="${2:?round}" url o r n
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  [[ "$round" =~ ^[0-9]+$ ]] || die "round must be a number" 1
  url="$(grep -m1 -E '^- \*\*PR:\*\* ' "$scratch" | sed -E 's/^- \*\*PR:\*\* //')"
  [[ -n "$url" ]] || die "no PR url in scratch header ('- **PR:** ...'): $scratch" 1
  # Refuse an already-recorded round UP FRONT. Discovering it at record-head time is too late:
  # record-anchors and replace-diff have already run, poisoning every shifted anchor before the
  # immutability check fires (fable-rd2-r4).
  cmd_head_record "$scratch" "$round" >/dev/null 2>&1 \
    && die "round ${round} already refreshed (records are immutable) — use the next round number" 1
  local parsed; parsed="$(cmd_parse "$url")" || die "cannot parse PR url from scratch: $url" 1
  IFS='|' read -r o r n <<< "$parsed"
  [[ -n "$o" && -n "$r" && -n "$n" ]] || die "incomplete PR ref from scratch url: $url" 1
  local tmpd; tmpd="$(mktemp -d)" || die "mktemp failed" 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" RETURN
  # Resolve the head BEFORE and AFTER fetching the diff. `gh pr diff` and the head query are two
  # separate GitHub reads; a push in between yields the old diff recorded against the new sha, so
  # later anchors would be validated against a revision the diff never showed (codex-rd1-r1).
  # Refusing is correct here: the caller re-runs and gets a consistent pair.
  local hb head mb head_after
  hb="$(_head_and_merge_base "${o}/${r}" "$n" "$n")"
  IFS='|' read -r head mb <<< "$hb"
  [[ -n "$head" ]] || die "could not resolve the PR head sha for ${o}/${r}#${n}" 1
  gh pr diff "$n" --repo "${o}/${r}" > "${tmpd}/diff" \
    || die "gh pr diff failed for ${o}/${r}#${n}" 1
  head_after="$(gh pr view "$n" --repo "${o}/${r}" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)"
  # Fail CLOSED: an unreadable confirm cannot distinguish "unchanged" from "moved", and skipping
  # the check on error would silently drop the guard the comment claims (fable-rd2-r5).
  [[ -n "$head_after" ]] \
    || die "could not re-confirm the PR head after fetching the diff — re-run refresh for round ${round}" 1
  [[ "$head_after" == "$head" ]] \
    || die "the PR moved during refresh (${head} -> ${head_after}) — re-run refresh for round ${round}" 1
  # Order matters (fable-rd1-r5). Anchors MUST be captured while the old diff is still present.
  # The head record is written LAST, after the swap succeeds: it is immutable, so writing it
  # first would wedge the round on any later failure — re-running refresh would die on the
  # immutability check with no exit-3 fallback and no documented recovery. record-anchors is
  # idempotent for keys it already holds. A retry for the SAME round is refused up front (above),
  # because after a diff swap re-running would poison shifted anchors rather than no-op.
  cmd_record_anchors "$scratch"
  cmd_replace_diff "$scratch" "${tmpd}/diff"
  cmd_record_head "$scratch" "$round" "$head" "$mb"
  echo "$scratch"
}

# ---- Phase B: anchor survival across a refresh -------------------------------------------
# `refresh` replaces ## Diff under findings that were anchored against the OLD one, so their
# RIGHT-side line numbers stop meaning anything. Left alone, a stale number either lands on no
# changed line (degrading to the summary with no notice) or — worse — lands on a DIFFERENT
# changed line and posts an agreed finding inline at the wrong place, which looks authoritative.
#
# Fix: capture the anchored line's TEXT while the old diff is still present, then re-resolve it
# by content at publish. Line numbers are not carried forward; the line's content is the
# identity, which is the only thing that stays meaningful once a fix commit renumbers the file.
#
# Deliberately head-equality's alternative: "post inline only if the finding's round head equals
# the publish head" would demote EVERY earlier-round anchor the moment the author pushes, and
# round 1 is where the serious findings are.
#
# This lives in pr.sh, not merge: it is only reachable once a refresh happens, so the manifest,
# the finding hashes, coverage and check-converged stay untouched.

_anchor_line_text() { # <scratch> <path> <line> -> the RIGHT-side line's text, or empty
  local scratch="$1" path="$2" line="$3"
  cmd_diff_lines_with_text "$scratch" | awk -F'\t' -v p="$path" -v l="$line" \
    '$1 == p && $2 == l { sub(/^[^\t]*\t[^\t]*\t/, ""); print; exit }'
}

cmd_diff_lines_with_text() { # <scratch> -> "path\tnewline\ttext" for RIGHT-side diff lines
  local scratch="${1:?scratch}" sect
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  # Same containments as cmd_diff_valid_lines, over the same verified window from the same shared
  # _diff_section — the two parsers must agree about what counts as a diff line, or an anchor can
  # validate against one view and remap against the other.
  sect="$(_diff_section "$scratch")" || return 3
  printf '%s\n' "$sect" | awk '
    /^diff --git / { inhdr = 1; inhunk = 0; p = ""; next }
    /^diff --cc |^diff --combined / { inhdr = 0; inhunk = 0; p = ""; next }
    /^@@@/ { inhdr = 0; inhunk = 0; p = ""; next }
    /^@@ / {
      inhdr = 0; inhunk = 1
      n = substr($3, 2); split(n, a, ","); ln = a[1] + 0
      next
    }
    /^`+[[:space:]]*$/ { next }
    inhdr && /^--- / { next }
    inhdr && /^\+\+\+ / {
      q = $0; sub(/^\+\+\+ /, "", q); sub(/\t.*$/, "", q)   # git appends a TAB when the path has a space
      if (q == "/dev/null") { p = "" } else { sub(/^b\//, "", q); p = q }
      next
    }
    !inhunk { next }
    p == "" || ln == 0 { next }
    /^\+/ { print p "\t" ln "\t" substr($0, 2); ln++; next }
    /^ /  { print p "\t" ln "\t" substr($0, 2); ln++; next }
    /^-/  { next }
  '
}

_poison_anchor() { # <scratch> <path> <line> — mark a reused key ambiguous
  local scratch="$1" path="$2" ln="$3" rf tmp
  rf="$(_records_path "$scratch")"; [[ -f "$rf" ]] || return 0
  tmp="$(mktemp)" || die "mktemp failed" 1
  awk -v k="multi-review-pr-anchor: ${path}:${ln} " '
    index($0, k) && !done { sub(/· [0-9a-f-]+ -->/, "· - -->"); done = 1 }
    { print }
  ' "$rf" > "$tmp" || { rm -f "$tmp"; die "cannot poison anchor record" 1; }
  mv "$tmp" "$rf" || { rm -f "$tmp"; die "cannot update: $rf" 1; }
}

cmd_record_anchors() { # <scratch> — capture each anchor's line text BEFORE the diff is replaced
  local scratch="${1:?scratch}" line path ln text anchor ends ep prior
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  local recs=""
  while IFS= read -r line; do
    [[ "$line" =~ ^\>[[:space:]]*—[[:space:]]*at[[:space:]]+([^:[:space:]]+):([0-9]+)(-([0-9]+))? ]] || continue
    path="${BASH_REMATCH[1]}"
    # A RANGE anchor needs BOTH endpoints recorded: publish re-resolves start and end
    # independently, and an end with no record would silently no-op to its stale number.
    ends="${BASH_REMATCH[4]:-}"
    for ep in "${BASH_REMATCH[2]}" ${ends:+$ends}; do
      ln="$ep"
      text="$(_anchor_line_text "$scratch" "$path" "$ln")"
      [[ -n "$text" ]] || continue
      anchor="$(printf '%s' "$text" | shasum | cut -d' ' -f1)"
      # The key is path:line, but two findings from DIFFERENT rounds can anchor the same
      # path:line at different content. Silently keeping the first would remap the second to the
      # first's line (fable-rd1-r2). Same text -> keep one; different text -> poison the key with
      # "-", which remap treats as unresolvable so that finding degrades to the summary.
      prior="$(grep -F "multi-review-pr-anchor: ${path}:${ln} " "$(_records_path "$scratch")" 2>/dev/null | head -1)"
      if [[ -n "$prior" ]]; then
        [[ "$prior" == *" ${anchor} "* ]] || _poison_anchor "$scratch" "$path" "$ln"
        continue
      fi
      case "$recs" in
        *"multi-review-pr-anchor: ${path}:${ln} "*) continue ;;
      esac
      recs="${recs}<!-- multi-review-pr-anchor: ${path}:${ln} · ${anchor} -->"$'\n'""
    done
    # Discover anchors ONLY in the review channel — the text after the LAST "## Review".
    # Scanning the whole scratch let the UNTRUSTED PR description plant anchor records
    # (codex-rd2-r1, fable-rd2-r3). The review section is the protocol's own channel, written by
    # secondaries under the trust contract, not by the PR author.
  done < <(awk '{a[NR]=$0} /^## Review[[:space:]]*$/{last=NR}
                END{ for (i=last+1; i<=NR; i++) print a[i] }' "$scratch" 2>/dev/null \
           | grep -E '^>[[:space:]]*—[[:space:]]*at[[:space:]]' 2>/dev/null)
  [[ -n "$recs" ]] || return 0
  printf '%s' "$recs" >> "$(_records_path "$scratch")" || die "cannot write anchor records" 1
}

cmd_remap_anchor() { # <scratch> <path> <line> -> the line's CURRENT number, or exit 1
  local scratch="${1:?scratch}" path="${2:?path}" ln="${3:?line}" rec want hits
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  rec="$(grep -F "multi-review-pr-anchor: ${path}:${ln} " "$(_records_path "$scratch")" 2>/dev/null | head -1)"
  # No record means no refresh has replaced the diff under this anchor — the number still means
  # what it meant, so remapping is a no-op rather than a failure.
  [[ -n "$rec" ]] || { printf '%s\n' "$ln"; return 0; }
  [[ "$rec" == *"· - -->"* ]] && return 1     # key reused with different content -> summary
  [[ "$rec" =~ ·[[:space:]]*([0-9a-f]+)[[:space:]]*--\> ]] || return 1
  want="${BASH_REMATCH[1]}"
  hits="$(cmd_diff_lines_with_text "$scratch" | awk -F'\t' -v p="$path" '
            $1 == p { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); print $2 "\t" t }' \
          | while IFS=$'\t' read -r n t; do
              [[ "$(printf '%s' "$t" | shasum | cut -d' ' -f1)" == "$want" ]] && printf '%s\n' "$n"
            done)"
  local count; count="$(printf '%s\n' "$hits" | grep -c '[0-9]' || true)"
  (( count == 1 )) || return 1     # gone, or ambiguous -> caller degrades to the summary
  printf '%s\n' "$hits" | grep '[0-9]' | head -1
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    parse)        cmd_parse "$@" ;;
    refresh)      cmd_refresh "$@" ;;
    record-anchors) cmd_record_anchors "$@" ;;
    remap-anchor)   cmd_remap_anchor "$@" ;;
    diff-lines-with-text) cmd_diff_lines_with_text "$@" ;;
    record-head)  cmd_record_head "$@" ;;
    head-record)  cmd_head_record "$@" ;;
    record-diff)  cmd_record_diff "$@" ;;
    diff-span)    cmd_diff_span "$@" ;;
    replace-diff) cmd_replace_diff "$@" ;;
    fence)        cmd_fence "$@" ;;
    seed)         cmd_seed "$@" ;;
    ingest)       cmd_ingest "$@" ;;
    resolve-repo) cmd_resolve_repo "$@" ;;
    scratch-path) cmd_scratch_path "$@" ;;
    publish)      cmd_publish "$@" ;;
    diff-valid-lines) cmd_diff_valid_lines "$@" ;;
    validate-anchor)  cmd_validate_anchor "$@" ;;
    *) die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
