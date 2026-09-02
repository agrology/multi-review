#!/usr/bin/env bash
# multi-review-planlint.sh — mechanical check of the mutation entries a document ships in its
# fenced code, against the document's own code and the repository it targets (spec Part B).
#
#   check <doc> [--repo <root>]  -> "<id>\t<verdict>\t<detail>" per entry, summary on stderr
#     exit 3  not applicable — no `mutate` invocation in fenced code outside ## Review; announced
#     exit 0  every row `ok`
#     exit 1  at least one row is not `ok` (`unparsed` included — an entry the lint cannot read
#             is an entry it cannot vouch for)
#     exit 2  usage/infra error
#
# WHY. A fix adds a guard, the guard gets an entry, the entry names a target line — and the
# round-1 fix that moved the line leaves the entry pointing at text that exists nowhere. Three
# secondaries independently spent a round on exactly that (codex-rd2-r1,
# gemini-rd2-mutation-target-mismatch, fable-rd2-r2 in the 2026-08-13 plan review). A grep finds it
# in under a second, and BEFORE anyone is dispatched is where a mechanical finding belongs.
#
# NEVER EVALS THE DOCUMENT. The entries are bash and the obvious parser is bash. This script does
# not use it: a conservative tokenizer reads single-quoted words, double-quoted words and bare
# words. Inside double quotes a `\` before `$`, a backtick, `"` or `\` yields that character, and
# before anything else a literal backslash plus that character (bash's own rule); a BARE `$` or
# backtick is refused. Anything else makes the row `unparsed`. A reviewed document is untrusted
# input here exactly as a PR body is to the PR helpers.
set -uo pipefail

die() { echo "multi-review-planlint: $1" >&2; exit "${2:-1}"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_SH="${MULTI_REVIEW_CORE_SH:-${SELF_DIR}/multi-review-core.sh}"
TMPD="$(mktemp -d)" || die "cannot create a scratch dir" 2
trap 'rm -rf "$TMPD"' EXIT

# Lines BEFORE the last "## Review" heading that sits OUTSIDE a fenced block — the body the
# primary edits, never the channel the findings live in. The whole document when there is none.
# Fence-aware on purpose: a plan quoting a review fixture carries a fenced "## Review", and a raw
# scan truncates the body there — every entry after it silently un-linted (found by running this
# lint over its own plan). The fence ranges come from `core.sh blocks`, the one tracker this
# family shares — a private copy here would mask the shared one under mutation (fable-rd2-r7).
_pre_review() { # <doc>
  "$CORE_SH" blocks "$1" > "${TMPD}/doc.blocks" 2>"${TMPD}/blocks.err" \
    || die "core.sh blocks failed: $(head -1 "${TMPD}/blocks.err")" 2
  # FILENAME, never `NR == FNR`: with an EMPTY ranges file awk starts the doc at NR == FNR == 1
  # and would read every document line as a range.
  awk -F'\t' 'FILENAME == ARGV[1] { for (i = $1; i <= $2; i++) fenced[i] = 1; next }
       { a[FNR] = $0; if (!(FNR in fenced) && $0 ~ /^## Review[[:space:]]*$/) last = FNR }
       END { n = (last ? last - 1 : FNR); for (i = 1; i <= n; i++) print a[i] }' "${TMPD}/doc.blocks" "$1"
}

# A PR scratch names itself: pr.sh writes `- **PR:** <url>` into the header region (the lines
# before the first "## ") and reads it back from there to publish. Keying on that, not on a bare
# "## Diff" heading, keeps a local plan with a real Diff section lintable (fable-rd2-r3).
_is_pr_scratch() { # <doc> -> 0 when the header carries the PR identity line
  local hdr; hdr="$(awk '/^## /{ exit } { print }' "$1")"
  grep -qE '^- \*\*PR:\*\* ' <<<"$hdr"
}

# The bodies of every fenced block in <pre-file>, concatenated, fence lines dropped. An
# unterminated block has no closing fence to drop, so its last line is kept. A block whose info
# string carries the word `fixture` (e.g. ````markdown fixture) is QUOTED material — a stale entry
# shown on purpose — and is skipped, so a document can reproduce a broken entry without being
# blocked from every fan-out by it (fable-rd1-r2).
_code() { # <pre-file>
  local pre="$1" s e lang last closer
  "$CORE_SH" blocks "$pre" > "${TMPD}/blocks" 2>"${TMPD}/blocks.err" \
    || die "core.sh blocks failed: $(head -1 "${TMPD}/blocks.err")" 2
  last="$(wc -l < "$pre" | tr -d ' ')"
  while IFS=$'\t' read -r s e lang; do
    [[ -n "$s" ]] || continue
    [[ "$lang" == *fixture* ]] && continue
    closer="$(sed -n "${e}p" "$pre")"
    if (( e == last )) && ! grep -qE '^ {0,3}(`{3,}|~{3,})[[:space:]]*$' <<<"$closer"; then
      sed -n "$((s + 1)),${e}p" "$pre"
    elif (( e > s + 1 )); then
      sed -n "$((s + 1)),$((e - 1))p" "$pre"
    fi
  done < "${TMPD}/blocks"
}

# Join backslash-continued lines and keep the statements that start with `mutate`, each prefixed
# by the code-file line range it was joined from — so the caller can EXCLUDE those lines from the
# corpus the entries are checked against. Without that exclusion an entry's own expect-substring
# is found inside the entry itself, and `label-missing` can never fire.
_statements() { # <code-file> -> "<start>\t<end>\t<statement>"
  awk '
    { line = $0
      if (buf != "") { sub(/^[ \t]+/, "", line); buf = buf " " line } else { buf = line; bstart = NR }
      if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
      s = buf; buf = ""; sub(/^[ \t]+/, "", s)
      if (s ~ /^mutate[ \t]/) print bstart "\t" NR "\t" s
    }
    END { if (buf != "") { s = buf; sub(/^[ \t]+/, "", s); if (s ~ /^mutate[ \t]/) print bstart "\t" NR "\t" s } }
  ' "$1"
}

# Tokenize each statement WITHOUT a shell. Output per statement, fields separated by \037 (a
# target line may legitimately contain a TAB, so TSV is the wrong separator here):
#   <k>\037<id>\037<rel>\037<mode>\037<expect>\037<suite>\037<old>\037<new>
#   <k>\037<id>\037UNPARSED\037<reason>
_parse() { # <statements-file>
  awk '
    function tokenize(s, toks,   n, i, L, c, d, j, cur, inw) {
      n = 0; i = 1; L = length(s); cur = ""; inw = 0
      while (i <= L) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t") { if (inw) { toks[++n] = cur; cur = ""; inw = 0 } i++; continue }
        if (c == "\047") {                                   # single quotes: no escapes at all
          j = index(substr(s, i + 1), "\047"); if (j == 0) return -1
          cur = cur substr(s, i + 1, j - 1); inw = 1; i += j + 1; continue
        }
        # Double quotes, the rule bash itself uses: \" \\ \$ \` collapse to that one character,
        # any other backslash is a literal backslash plus the character, and a bare $ or ` is
        # refused as a live substitution.
        if (c == "\"") {
          i++
          while (i <= L) {
            c = substr(s, i, 1)
            if (c == "\\") { d = substr(s, i + 1, 1)
              if (d == "\"" || d == "\\" || d == "$" || d == "`") { cur = cur d; i += 2; continue }
              cur = cur "\\" d; i += 2; continue }
            if (c == "$" || c == "`") return -1              # a live substitution: refuse
            if (c == "\"") break
            cur = cur c; i++
          }
          if (i > L) return -1
          inw = 1; i++; continue
        }
        if (c == "$" || c == "`" || c == "\\" || c == "#") return -1
        cur = cur c; inw = 1; i++
      }
      if (inw) toks[++n] = cur
      return n
    }
    {
      k++; delete toks
      n = tokenize($0, toks)
      rawid = $2; gsub(/[\047"]/, "", rawid); if (rawid == "") rawid = "entry-" k
      if (n < 0) { print k "\037" rawid "\037UNPARSED\037quoting outside the conservative grammar (a bare $, backtick, #, or escape)"; next }
      if (toks[1] != "mutate") { print k "\037" rawid "\037UNPARSED\037not a mutate statement"; next }
      mode = toks[4]; sub(/:[0-9]+$/, "", mode)
      if (mode == "delete"  && n == 7) { print k "\037" toks[2] "\037" toks[3] "\037" mode "\037" toks[5] "\037" toks[6] "\037" toks[7] "\037"; next }
      if (mode == "replace" && n == 8) { print k "\037" toks[2] "\037" toks[3] "\037" mode "\037" toks[5] "\037" toks[6] "\037" toks[7] "\037" toks[8]; next }
      print k "\037" rawid "\037UNPARSED\037" (n - 1) " argument(s) for mode \047" toks[4] "\047 (want 6 for delete, 7 for replace)"
    }
  ' "$1"
}

# Exact full-line presence — the same matcher the mutation runner uses, for the same reason: a
# regex match is how a mutation silently no-ops.
_line_present() { # <line> <file>
  OLD="$1" awk '$0 == ENVIRON["OLD"] { f = 1; exit } END { exit !f }' "$2"
}

cmd_check() {
  local doc="" repo=""
  while (( $# )); do
    case "$1" in
      # A bare `--repo` must exit 2 like every other usage error, not through `${2:?}` — that is
      # bash's own non-interactive abort, status 1, indistinguishable from a lint defect to a
      # caller branching on the exit code (codex-rd1-r2).
      --repo) [[ $# -ge 2 ]] || die "usage: multi-review-planlint.sh check <doc> [--repo <root>] — --repo needs a path" 2; repo="$2"; shift 2 ;;
      -*) die "unknown argument: $1" 2 ;;
      *) [[ -z "$doc" ]] || die "usage: multi-review-planlint.sh check <doc> [--repo <root>]" 2; doc="$1"; shift ;;
    esac
  done
  [[ -n "$doc" ]] || die "usage: multi-review-planlint.sh check <doc> [--repo <root>]" 2
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  [[ -n "$repo" ]] || repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [[ -d "$repo" ]] || die "repo root is not a directory: $repo" 2

  # A PR scratch is not shipped code: its ## Diff is the author's change, with `+`/`-`/` ` prefixes
  # that make a context-line `mutate` parse and its edited continuation lines `unparsed` — an exit
  # 1 the primary is forbidden to fix, since the diff is read-only (fable-rd1-r1). The real table
  # is covered there by --verify-table in CI.
  _is_pr_scratch "$doc" \
    && die "not applicable: a PR scratch ships no code of its own; the real table is checked by --verify-table in CI" 3
  _pre_review "$doc" > "${TMPD}/pre"
  _code "${TMPD}/pre" > "${TMPD}/code"
  _statements "${TMPD}/code" > "${TMPD}/stmts"
  grep -q . "${TMPD}/stmts" || die "not applicable: no mutate invocation in the document's fenced code" 3
  # The corpus the entries are checked against is the shipped code MINUS the entries themselves.
  awk -F'\t' 'NR == FNR { for (i = $1; i <= $2; i++) drop[i] = 1; next } !(FNR in drop)' \
    "${TMPD}/stmts" "${TMPD}/code" > "${TMPD}/corpus"
  cut -f3- "${TMPD}/stmts" | _parse /dev/stdin > "${TMPD}/rows"
  awk -F'\037' '$3 != "UNPARSED" { print $2 }' "${TMPD}/rows" | LC_ALL=C sort | uniq -d > "${TMPD}/dups"

  local k id rel mode expect suite old total=0 bad=0 v detail
  # `new` is read to keep the record aligned; the lint has nothing to check about a replacement.
  # shellcheck disable=SC2034
  while IFS=$'\037' read -r k id rel mode expect suite old new; do
    [[ -n "$k" ]] || continue
    total=$((total + 1)); v=ok; detail=""
    if [[ "$rel" == "UNPARSED" ]]; then
      v=unparsed; detail="$mode"
    # Both fields are joined onto ${repo} and read below, so an absolute path or a `..` segment
    # would have the reviewed document choose a file outside the repository. Wrapping both in
    # slashes makes a `..` PATH SEGMENT match without also rejecting a name like `a..b`.
    elif [[ "/${rel}/${suite}/" == */../* || "$rel" == /* || "$suite" == /* ]]; then
      v=unparsed; detail="file-rel/suite must be a relative path inside the repo"
    elif grep -qFx -- "$id" "${TMPD}/dups"; then
      v=duplicate-id; detail="the id appears more than once in the document"
    elif ! _line_present "$old" "${TMPD}/corpus" \
         && ! { [[ -f "${repo}/${rel}" ]] && _line_present "$old" "${repo}/${rel}"; }; then
      v=target-missing; detail="old-line occurs neither in the document's fenced code (outside the entries) nor in ${rel}"
    elif [[ "$expect" != "SURVIVES-BY-DESIGN" ]] \
         && ! grep -qF -- "$expect" "${TMPD}/corpus" \
         && ! { [[ -f "${repo}/scripts/${suite}" ]] && grep -qF -- "$expect" "${repo}/scripts/${suite}"; }; then
      v=label-missing; detail="expect-substring occurs neither in the document's fenced code nor in scripts/${suite}"
    fi
    [[ "$v" == ok ]] || bad=$((bad + 1))
    printf '%s\t%s\t%s\n' "$id" "$v" "$detail"
  done < "${TMPD}/rows"
  echo "multi-review-planlint: ${total} entries checked, ${bad} defect(s)" >&2
  (( bad == 0 ))
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    check) cmd_check "$@" ;;
    *)     die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
