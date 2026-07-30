#!/usr/bin/env bash
# multi-review-scope.sh — diff-scoped copies for round N>=2 (issue #29 item 6).
# Keeps the cost of a re-fan proportional to what CHANGED, not to the size of the artifact.
# Subcommands:
#   local-copy --round <N> --max <M> --prev <baseline.rd(N-1)> --curr <baseline.rdN>
#       -> scoped copy of a local doc: the delta plus the full text of every region it touches
#   pr-copy    --round <N> --max <M> --since <sha> --merge-base-prev <sha> \
#              --head <sha> --merge-base <sha> <repo-root>
#       -> scoped copy of a PR round: what the author pushed since the previous round, as a
#          `git diff -W -U10` delta — hunks extended to their enclosing function, NO whole-file
#          text (emitting each touched file in full cost 48-412% of the round it replaced)
#
# Both print a complete copy on stdout, and both use:
#       exit 3 = cannot scope; caller falls back to the full artifact and relays the reason
#       exit 1 = usage error
# Exit 3 is distinct from failure so the caller degrades deliberately rather than by swallowing
# an error — the same reason verify-vendor distinguishes "unmappable" from "mismatch".
set -uo pipefail
SCOPE_TMP=""
cleanup() { [[ -n "$SCOPE_TMP" ]] && rm -rf "$SCOPE_TMP"; return 0; }
trap cleanup EXIT
die()    { echo "multi-review-scope: $1" >&2; exit "${2:-1}"; }
cannot() { echo "multi-review-scope: cannot scope — $1" >&2; exit 3; }

_body() {
  awk '
    {
      a[NR] = $0
      s = $0; sub(/^ ? ? ?/, "", s)
      run = 0; ch = ""
      if (match(s, /^`+/))      { run = RLENGTH; ch = "`" }
      else if (match(s, /^~+/)) { run = RLENGTH; ch = "~" }
      if (infence) {
        if (ch == fence_ch && run >= fence_len) {
          rest = substr(s, run + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { infence = 0; fence_len = 0; fence_ch = "" }
        }
        next
      }
      if (run >= 3) { infence = 1; fence_len = run; fence_ch = ch; next }
      if (s ~ /^## Review[[:space:]]*$/) last = NR
    }
    END { n = (last ? last - 1 : NR); for (i = 1; i <= n; i++) print a[i] }
  ' "$1" | awk '
    !done {
      if ($0 ~ /^[[:space:]]*$/) { print; next }
      if (!h1seen && $0 ~ /^# /) { h1seen = 1; next }
      if ($0 ~ /^[[:space:]]*<!--[[:space:]]*multi-review/) { next }
      done = 1
    }
    { print }
  ' | awk '
    { b[NR] = $0 }
    END {
      s = 1; while (s <= NR && b[s] ~ /^[[:space:]]*$/) s++
      e = NR; while (e >= s && b[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print b[i]
    }
  '
}

_h1() {
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      run = 0; ch = ""
      if (match(s, /^`+/))      { run = RLENGTH; ch = "`" }
      else if (match(s, /^~+/)) { run = RLENGTH; ch = "~" }
      if (infence) {
        if (ch == fence_ch && run >= fence_len) {
          rest = substr(s, run + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { infence = 0; fence_len = 0; fence_ch = "" }
        }
        next
      }
      if (run >= 3) { infence = 1; fence_len = run; fence_ch = ch; next }
      if (s ~ /^## /) { exit }
      if (s ~ /^# /)  { print; exit }
    }
  ' "$1"
}

_fence_for() {
  local longest n
  longest="$(grep -oE '`+' "$1" 2>/dev/null | awk '{ if (length > m) m = length } END { print m + 0 }')"
  n=$(( longest + 1 )); (( n < 3 )) && n=3
  printf '%*s' "$n" '' | tr ' ' '`'
}

_regions() {
  awk '
    {
      last = NR
      s = $0; sub(/^ ? ? ?/, "", s)
      run = 0; ch = ""
      if (match(s, /^`+/))      { run = RLENGTH; ch = "`" }
      else if (match(s, /^~+/)) { run = RLENGTH; ch = "~" }
      if (infence) {
        if (ch == fence_ch && run >= fence_len) {
          rest = substr(s, run + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { infence = 0; fence_len = 0; fence_ch = "" }
        }
        next
      }
      if (run >= 3) { infence = 1; fence_len = run; fence_ch = ch; next }
      if (s ~ /^## /) { nh++; hline[nh] = NR; hname[nh] = substr(s, 4) }
    }
    END {
      if (nh == 0) { if (last) print 1 "\t" last "\t" "preamble"; exit }
      if (hline[1] > 1) print 1 "\t" (hline[1] - 1) "\t" "preamble"
      for (i = 1; i <= nh; i++) {
        end = (i < nh) ? hline[i+1] - 1 : last
        print hline[i] "\t" end "\t" hname[i]
      }
    }
  ' "$1"
}

_touched() {
  local tmp="$1"
  _regions "$tmp/curr" > "$tmp/regions.curr"
  diff -U0 "$tmp/prev" "$tmp/curr" | awk '
    /^@@ / { n = substr($3, 2); split(n, a, ","); c = (a[2] == "") ? 1 : a[2] + 0
             s = a[1] + 0; if (s < 1) s = 1
             if (c > 0) print s "\t" (s + c - 1); else print s "\t" s }
  ' > "$tmp/ranges.new"
  awk -F'\t' -v rf="$tmp/regions.curr" '
    BEGIN { while ((getline ln < rf) > 0) { n++; split(ln, f, "\t"); rs[n]=f[1]; re[n]=f[2] } }
    { for (i = 1; i <= n; i++) if ($1 <= re[i] && $2 >= rs[i]) hit[i] = 1 }
    END { for (i = 1; i <= n; i++) if (hit[i]) print rs[i] }
  ' "$tmp/ranges.new"
}

_removed() {
  local tmp="$1"
  _regions "$tmp/prev" > "$tmp/regions.prev"
  awk -F'\t' -v curr="$tmp/regions.curr" '
    BEGIN { while ((getline line < curr) > 0) { split(line, f, "\t"); c[f[3]]++ } }
    { p[$3]++; if (!(  $3 in seen)) { seen[$3] = 1; ord[++k] = $3 } }
    END { for (i = 1; i <= k; i++) { nme = ord[i]; d = p[nme] - c[nme]; while (d-- > 0) print nme } }
  ' "$tmp/regions.prev"
}

_emit_names() {
  local tmp="$1" un rm
  _touched "$tmp" > "$tmp/touched"
  un="$(awk -F'\t' -v tf="$tmp/touched" '
        BEGIN { while ((getline ln < tf) > 0) t[ln] = 1 }
        !($1 in t) { printf "%s%s", sep, $3; sep = ", " }
      ' "$tmp/regions.curr")"
  rm="$(_removed "$tmp" | awk '{ printf "%s%s", sep, $0; sep = ", " }')"
  [[ -n "$un" ]] && printf '> Unchanged this round, not shown: %s.\n' "$un"
  [[ -n "$rm" ]] && printf '> Removed this round, no longer present: %s.\n' "$rm"
  return 0
}

_emit_diff() {
  local tmp="$1" round="$2" fence
  diff -U0 -L "round $((round - 1))" -L "round $round" "$tmp/prev" "$tmp/curr" > "$tmp/diff"
  fence="$(_fence_for "$tmp/diff")"
  printf '%sdiff\n' "$fence"
  cat "$tmp/diff"
  printf '%s\n' "$fence"
  return 0
}

_emit_regions() {
  local tmp="$1"
  awk -F'\t' -v tf="$tmp/touched" '
    BEGIN { while ((getline ln < tf) > 0) t[ln] = 1 }
    ($1 in t) { print $1 "\t" $2 }
  ' "$tmp/regions.curr" | while IFS=$'\t' read -r s e; do
    sed -n "${s},${e}p" "$tmp/curr"
    echo
  done
}

# Never-worse guard. A scoped copy that costs at least as much as the artifact it replaces has no
# argument for itself under any goal this feature states, so it degrades (exit 3) and says both
# sizes. This is a GUARD, not a knob: the threshold IS the thing being replaced, so there is
# nothing to configure and no threshold to tune.
#
# It exists because the failure it catches was reproduced twice on shipped code — `pr-copy` cost
# 48-412% of the round it replaced (spec §11 Q2), and `local-copy` emitted a 37,373-byte copy to
# replace a 36,585-byte document during this feature's own review, exit 0, nothing warned.
#
# Callers compare PAYLOAD to PAYLOAD. The ~308 bytes of copy boilerplate exist on both sides of
# the real comparison, so charging only the scoped side for them inverts the verdict on small
# artifacts (measured: 441 vs 143 on this suite's own fixture). Each call site names its basis.
# Byte counts are stripped of BSD `wc` padding by the caller so the message reads cleanly.
_payload_guard() { # <scoped-bytes> <full-bytes>
  (( $1 < $2 )) || cannot "scoped copy is not smaller than the artifact it replaces ($1 B vs $2 B)"
  return 0
}

cmd_local_copy() {
  local round="" max="" prev="" curr=""
  while (( $# )); do
    case "$1" in
      --round|--max|--prev|--curr)
        # Guard BEFORE shifting: bash leaves the positionals untouched when the shift count
        # exceeds $#, so a bare "--round" would spin this loop forever (fable-rd1-r1).
        (( $# >= 2 )) || die "missing value for $1" 1
        case "$1" in
          --round) round="$2" ;;
          --max)   max="$2"   ;;
          --prev)  prev="$2"  ;;
          --curr)  curr="$2"  ;;
        esac
        shift 2 ;;
      *) die "unknown argument: $1" 1 ;;
    esac
  done
  [[ "$round" =~ ^[0-9]+$ ]] || die "--round must be a number" 1
  [[ "$max"   =~ ^[0-9]+$ ]] || die "--max must be a number" 1
  (( round >= 2 )) || die "--round must be >= 2 (round 1 is never scoped)" 1
  [[ -n "$curr" && -f "$curr" ]] || die "--curr not found: ${curr:-<unset>}" 1
  [[ -n "$prev" && -f "$prev" ]] || cannot "no retained baseline for round $((round - 1)): ${prev:-<unset>}"

  local tmp; tmp="$(mktemp -d)" || die "cannot create temp dir" 1
  SCOPE_TMP="$tmp"

  _body "$prev" > "$tmp/prev"
  _body "$curr" > "$tmp/curr"

  if diff -q "$tmp/prev" "$tmp/curr" >/dev/null 2>&1; then
    cannot "empty delta — nothing changed since round $((round - 1))"
  fi

  local h1; h1="$(_h1 "$curr")"

  printf '%s\n\n' "$h1"
  printf '<!-- multi-review: awaiting-reviewer · round %s/%s -->\n' "$round" "$max"
  printf '<!-- multi-review-mode: star -->\n\n'
  printf '> SCOPED ROUND. You are reviewing what changed since round %s, not the whole document.\n' \
    "$((round - 1))"
  _emit_names "$tmp"
  printf '\n## Changes since round %s\n\n' "$((round - 1))"
  _emit_diff "$tmp" "$round"
  printf '\n'
  _emit_regions "$tmp"
  printf '## Review\n\n'
}

cmd_pr_copy() {
  local round="" max="" since="" mb_prev="" head="" mb="" root=""
  while (( $# )); do
    case "$1" in
      --round|--max|--since|--merge-base-prev|--head|--merge-base)
        (( $# >= 2 )) || die "missing value for $1" 1
        case "$1" in
          --round)            round="$2"   ;;
          --max)              max="$2"     ;;
          --since)            since="$2"   ;;
          --merge-base-prev)  mb_prev="$2" ;;
          --head)             head="$2"    ;;
          --merge-base)       mb="$2"      ;;
        esac
        shift 2 ;;
      -*) die "unknown argument: $1" 1 ;;
      *)  root="$1"; shift ;;
    esac
  done
  [[ "$round" =~ ^[0-9]+$ ]] || die "--round must be a number" 1
  [[ "$max"   =~ ^[0-9]+$ ]] || die "--max must be a number" 1
  (( round >= 2 )) || die "--round must be >= 2 (round 1 is never scoped)" 1
  [[ -n "$since" && -n "$head" ]] || die "--since and --head are required" 1
  [[ -n "$root" && -d "$root" ]] || die "repo root not found: ${root:-<unset>}" 1

  # An unknown merge-base ("-", recorded when pr.sh could not compute one) is a cannot-scope,
  # never a silent pass: without it the forward-merge guard below cannot be evaluated at all.
  [[ "$mb_prev" == "-" || "$mb" == "-" || -z "$mb_prev" || -z "$mb" ]] \
    && cannot "merge-base unknown for one of the rounds — cannot tell a response delta from an absorbed upstream"

  # The merge-base MOVED: the branch absorbed upstream between rounds (a forward merge, which
  # this repo's own working agreement mandates every couple of days, or a rebase). `git diff
  # A..B` is a TREE comparison, so scoping here would hand reviewers the entire upstream delta
  # presented as "what the author pushed in response".
  [[ "$mb_prev" == "$mb" ]] \
    || cannot "merge-base moved between rounds ($mb_prev -> $mb) — the branch absorbed upstream"

  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || cannot "not a git repository: $root"
  git -C "$root" cat-file -e "${since}^{commit}" 2>/dev/null \
    || cannot "previous head is not resolvable locally: $since"
  git -C "$root" cat-file -e "${head}^{commit}" 2>/dev/null \
    || cannot "head is not resolvable locally: $head"

  # Ancestry is the load-bearing guard, and the two above do not imply it: an --amend or a
  # squash-and-force-push onto the SAME base leaves the old commit resolvable and moves no
  # merge-base, so only ancestry distinguishes "commits added on top" from "history rewritten".
  git -C "$root" merge-base --is-ancestor "$since" "$head" 2>/dev/null \
    || cannot "previous head is not an ancestor of the current head — history was rewritten"

  local tmp; tmp="$(mktemp -d)" || die "cannot create temp dir" 1
  SCOPE_TMP="$tmp"

  # -W extends each hunk to its enclosing function; -U10 is the floor where git finds no funcname
  # boundary, so this is never worse than fixed context. Whole-file text was the pre-amendment
  # rule (spec §11 Q2) and cost 48-412% of the round it replaced: its cost scaled with the SIZE OF
  # THE FILES TOUCHED rather than with the size of the change, which is the dependency §2 of the
  # spec exists to remove.
  # --no-ext-diff: `git diff` is porcelain and honours `diff.external`, so a difftastic/delta
  # user would otherwise have the driver's output shipped as "what the author pushed" — exit 0,
  # not a unified diff, and the size guard comparing driver output. Reproduced.
  git -C "$root" diff --no-ext-diff -W -U10 "$since" "$head" > "$tmp/diff" 2>/dev/null \
    || cannot "git diff failed between $since and $head"
  [[ -s "$tmp/diff" ]] || cannot "empty delta — nothing was pushed since round $((round - 1))"

  # basis: scoped diff payload vs whole-PR diff payload (both raw `git diff`, boilerplate cancels).
  # Excluding the scratch's description and review channel from the full side makes this guard
  # STRICTER, never looser. Evaluated before any output, so exit 3 prints nothing on stdout.
  git -C "$root" diff --no-ext-diff "$mb" "$head" > "$tmp/full" 2>/dev/null \
    || cannot "git diff failed between $mb and $head"
  local scoped_bytes full_bytes
  scoped_bytes="$(wc -c < "$tmp/diff" | tr -d ' ')"
  full_bytes="$(wc -c < "$tmp/full" | tr -d ' ')"
  _payload_guard "$scoped_bytes" "$full_bytes"

  printf '# PR review — scoped round %s\n\n' "$round"
  printf '<!-- multi-review: awaiting-reviewer · round %s/%s -->\n' "$round" "$max"
  printf '<!-- multi-review-mode: star -->\n\n'
  printf '> SCOPED ROUND. You are reviewing what the author pushed since round %s, not the whole PR.\n' \
    "$((round - 1))"
  printf '> Files not shown are untouched by this delta.\n\n'
  printf '## Changes since round %s\n\n' "$((round - 1))"
  local fence; fence="$(_fence_for "$tmp/diff")"
  printf '%sdiff\n' "$fence"; cat "$tmp/diff"; printf '%s\n\n' "$fence"

  printf '## Review\n\n'
}

case "${1:-}" in
  local-copy) shift; cmd_local_copy "$@" ;;
  pr-copy)    shift; cmd_pr_copy "$@" ;;
  *) die "usage: multi-review-scope.sh local-copy --round <N> --max <M> --prev <f> --curr <f>
       multi-review-scope.sh pr-copy --round <N> --max <M> --since <sha> --merge-base-prev <sha> --head <sha> --merge-base <sha> <repo-root>" 1 ;;
esac
