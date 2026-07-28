#!/usr/bin/env bash
# multi-review-scope.sh — diff-scoped copies for round N>=2 (issue #29 item 6, Phase A).
# Keeps the cost of a re-fan proportional to what the primary changed, not to the size of the
# document. Subcommands:
#   local-copy --round <N> --max <M> --prev <baseline.rd(N-1)> --curr <baseline.rdN>
#       -> complete scoped copy on stdout
#       -> exit 3 = cannot scope; caller falls back to the full document and relays the reason
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

case "${1:-}" in
  local-copy) shift; cmd_local_copy "$@" ;;
  *) die "usage: multi-review-scope.sh local-copy --round <N> --max <M> --prev <f> --curr <f>" 1 ;;
esac
