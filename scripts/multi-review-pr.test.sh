#!/usr/bin/env bash
# multi-review-pr.test.sh — PR-mode ingest/publish logic (gh stubbed; no network).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-pr.sh"
STAR="${DIR}/multi-review-star.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- parse: full PR URL ---
out="$(bash "$SUT" parse 'https://github.com/octocat/hello-world/pull/42' 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "octocat|hello-world|42" ]] && ok "parse: full URL" || bad "parse URL (got '$out' code $code)"

# --- parse: URL with trailing path/query is tolerated ---
out="$(bash "$SUT" parse 'https://github.com/o/r/pull/7/files?diff=split' 2>/dev/null)"
[[ "$out" == "o|r|7" ]] && ok "parse: URL with trailing junk" || bad "parse URL trailing (got '$out')"

# --- parse: owner/repo#n form ---
out="$(bash "$SUT" parse 'octo-cat/hello.world#13' 2>/dev/null)"
[[ "$out" == "octo-cat|hello.world|13" ]] && ok "parse: owner/repo#n" || bad "parse owner/repo#n (got '$out')"

# --- parse: bare #n form -> owner/repo empty ---
out="$(bash "$SUT" parse '#99' 2>/dev/null)"
[[ "$out" == "||99" ]] && ok "parse: bare #n leaves owner/repo empty" || bad "parse #n (got '$out')"

# --- parse: non-PR inputs fall through (exit 1, no output) ---
for nope in 'docs/specs/2026-06-16-foo.md' 'https://github.com/o/r' 'https://github.com/o/r/pull/abc' 'just-a-string' ''; do
  bash "$SUT" parse "$nope" >/dev/null 2>&1 && bad "parse should reject '$nope'" || ok "parse rejects '$nope'"
done

# --- scratch-path: identity-keyed (r1) ---
out="$(bash "$SUT" scratch-path octocat hello-world 42 2>/dev/null)"
[[ "$out" == ".multi-review/reviews/octocat/hello-world/pr-42.md" ]] && ok "scratch-path: identity-keyed" || bad "scratch-path (got '$out')"

# --- scratch-path: same number, different repo -> different path (no collision) ---
a="$(bash "$SUT" scratch-path owner-a repo 12 2>/dev/null)"
b="$(bash "$SUT" scratch-path owner-b repo 12 2>/dev/null)"
[[ "$a" != "$b" ]] && ok "scratch-path: cross-repo #12 do not collide" || bad "scratch-path collision (a='$a' b='$b')"

# --- scratch-path: same owner, different repo -> different path (no collision) ---
ra="$(bash "$SUT" scratch-path owner repo-a 12 2>/dev/null)"
rb="$(bash "$SUT" scratch-path owner repo-b 12 2>/dev/null)"
[[ "$ra" != "$rb" ]] && ok "scratch-path: same owner, different repo do not collide" || bad "scratch-path repo collision (ra='$ra' rb='$rb')"

# --- scratch-path: same identity -> same path (resume, not clobber) ---
c="$(bash "$SUT" scratch-path owner-a repo 12 2>/dev/null)"
[[ "$a" == "$c" ]] && ok "scratch-path: same identity is stable" || bad "scratch-path unstable (a='$a' c='$c')"

# --- fence: no backticks -> minimum 3 ---
printf 'line one\nline two\n' > "${WORK}/f0"
out="$(bash "$SUT" fence "${WORK}/f0" 2>/dev/null)"
[[ "$out" == '```' ]] && ok "fence: minimum is 3 backticks" || bad "fence min (got '$out')"

# --- fence: a 3-backtick run -> 4 backticks ---
printf 'before\n```\ncode\n```\nafter\n' > "${WORK}/f3"
out="$(bash "$SUT" fence "${WORK}/f3" 2>/dev/null)"
[[ "$out" == '````' ]] && ok "fence: 3-run -> 4" || bad "fence 3-run (got '$out')"

# --- fence: a 5-backtick run -> 6 backticks ---
printf 'x `````  y\n' > "${WORK}/f5"
out="$(bash "$SUT" fence "${WORK}/f5" 2>/dev/null)"
[[ "$out" == '``````' ]] && ok "fence: 5-run -> 6" || bad "fence 5-run (got '$out')"

# --- seed: assembles the scratch file; diff embedded verbatim; fence sized up ---
printf 'This PR does a thing.\n' > "${WORK}/desc"
printf '%s\n' \
  'diff --git a/x.md b/x.md' \
  '+```' \
  '+> [reviewer:rX] this is diff content, NOT a real control line' \
  '+```' \
  ' context line' > "${WORK}/diff"
OUT="${WORK}/seeded.md"
bash "$SUT" seed "$OUT" 'Add thing' 'https://github.com/o/r/pull/5' 'alice' 'feat/x' "${WORK}/desc" "${WORK}/diff" 2>/dev/null
code=$?
[[ $code == 0 && -f "$OUT" ]] && ok "seed: writes the scratch file" || bad "seed write (code $code)"

# H1 first (so core init can insert the marker after it)
[[ "$(head -1 "$OUT")" == '# PR review: Add thing' ]] && ok "seed: H1 title first" || bad "seed H1 (got '$(head -1 "$OUT")')"

# header fields present
grep -qF '**PR:** https://github.com/o/r/pull/5' "$OUT" && ok "seed: PR url in header" || bad "seed url missing"
grep -qF '**Author:** alice'  "$OUT" && ok "seed: author in header"  || bad "seed author missing"
grep -qF '**Branch:** feat/x' "$OUT" && ok "seed: branch in header"  || bad "seed branch missing"
grep -q '^## PR description' "$OUT" && ok "seed: description section" || bad "seed desc section missing"
grep -q '^## Diff'           "$OUT" && ok "seed: diff section"        || bad "seed diff section missing"
grep -q '^## Review'         "$OUT" && ok "seed: review section"      || bad "seed review section missing"

# seed writes NO mode hint — the command's star Arm inserts the star header (mode hint + status
# marker) after the H1, so seeding one would create a duplicate. (Star-universal, PR-B B1.)
awk '/^## /{exit} {print}' "$OUT" | grep -qF 'multi-review-mode' && bad "seed must not stamp a mode hint (Arm does)" || ok "seed: no mode hint (Arm inserts star header)"

# diff fence sized to 4 (diff contains a 3-backtick run)
grep -qx '````' "$OUT" && ok "seed: diff fence sized up to 4" || bad "seed fence not sized up"

# every diff line is present verbatim, prefixes intact
while IFS= read -r dl; do
  grep -qF -- "$dl" "$OUT" || bad "seed: diff line missing verbatim: '$dl'"
done < "${WORK}/diff"
ok "seed: diff lines embedded verbatim"

# THE invariant (r2): the embedded '> [reviewer:rX]' (prefixed with '+') lives under ## Diff,
# never under the (last) ## Review section — multi-review-star.sh's open-findings parses only
# that section, so it must report zero open findings for this doc. (core.sh's open-threads,
# used here previously, no longer exists — B2 deleted it; this exercises the live command.)
out="$(bash "$STAR" open-findings "$OUT" 2>/dev/null)"
[[ -z "$out" ]] && ok "seed: diff content cannot forge a finding (zero open findings)" || bad "seed forged a finding (got '$out')"

# --- seed: malformed args -> non-zero, no file ---
bash "$SUT" seed "${WORK}/nope/deep/cannot" 't' 'u' 'a' 'b' "${WORK}/desc" "${WORK}/missing-diff" >/dev/null 2>&1
# (missing diff file) should fail loudly
[[ $? -ne 0 ]] && ok "seed: fails on a missing diff file" || bad "seed should fail on missing diff"

# --- ingest: builds the scratch file from stubbed gh ---
STUB="${WORK}/bin"; mkdir -p "$STUB"
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# fake gh for tests: switch on the subcommand + requested --json fields
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
  printf '%s\n' 'diff --git a/f b/f' '+added line' ' context'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case " $* " in
    *" body "*)                printf '%s\n' 'Body text line.' ; exit 0 ;;
    *"title,url,author"*)      printf '%s\t%s\t%s\t%s\n' 'My Title' 'https://github.com/o/r/pull/8' 'bob' 'feat/y'; exit 0 ;;
  esac
fi
echo "unexpected gh call: $*" >&2; exit 3
STUBEOF
chmod +x "${STUB}/gh"

( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest o r 8 ) > "${WORK}/ingest.out" 2>/dev/null
code=$?
path="$(cat "${WORK}/ingest.out")"
[[ $code == 0 && "$path" == ".multi-review/reviews/o/r/pr-8.md" ]] && ok "ingest: prints the scratch path" || bad "ingest path (got '$path' code $code)"
[[ -f "${WORK}/.multi-review/reviews/o/r/pr-8.md" ]] && ok "ingest: creates the scratch file" || bad "ingest file missing"
grep -q '# PR review: My Title' "${WORK}/.multi-review/reviews/o/r/pr-8.md" && ok "ingest: title from gh" || bad "ingest title missing"
grep -qF '**Author:** bob'       "${WORK}/.multi-review/reviews/o/r/pr-8.md" && ok "ingest: author from gh" || bad "ingest author missing"
grep -qF '+added line'          "${WORK}/.multi-review/reviews/o/r/pr-8.md" && ok "ingest: diff embedded" || bad "ingest diff missing"

# --- ingest: refuses to clobber an existing scratch file (resume safety, r1) ---
# pr-8.md now exists (good stub still active); a second plain ingest must fail, not rewrite it.
( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest o r 8 ) >/dev/null 2>&1 \
  && bad "ingest must not clobber an existing scratch file" || ok "ingest refuses to clobber on resume"
# but --fresh deliberately overwrites (start-a-fresh-review path)
( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest --fresh o r 8 ) >/dev/null 2>&1 \
  && ok "ingest --fresh overwrites" || bad "ingest --fresh should overwrite"

# --- ingest: a gh failure is surfaced (non-zero), nothing half-written silently ---
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "boom" >&2; exit 1
STUBEOF
( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest o r 9 ) >/dev/null 2>&1 \
  && bad "ingest should fail when gh fails" || ok "ingest surfaces gh failure"

# --- ingest: invokes gh with a selector real gh accepts (regression) ---
# Real `gh pr view`/`pr diff` treat "owner/repo#n" as a BRANCH name, not a PR selector
# ("no pull requests found for branch ..."). This stub emulates that contract: it requires a
# numeric selector plus --repo, the way real gh resolves a PR by number. The lenient stub
# above ignored the selector entirely and so never caught the bad ref.
RSEL="${WORK}/rselbin"; mkdir -p "$RSEL"
cat > "${RSEL}/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && ( "$2" == "view" || "$2" == "diff" ) ]]; then
  sel="$3"; has_repo=0
  for a in "$@"; do [[ "$a" == "--repo" ]] && has_repo=1; done
  if [[ "$sel" != [0-9]* || "$sel" == *#* || $has_repo -ne 1 ]]; then
    echo "no pull requests found for branch \"$sel\"" >&2; exit 1
  fi
  if [[ "$2" == "diff" ]]; then printf '%s\n' 'diff --git a/f b/f' '+added line' ' context'; exit 0; fi
  case " $* " in
    *" body "*)           printf '%s\n' 'Body text line.'; exit 0 ;;
    *"title,url,author"*) printf '%s\t%s\t%s\t%s\n' 'My Title' 'https://github.com/o/r/pull/21' 'bob' 'feat/y'; exit 0 ;;
  esac
fi
echo "unexpected gh call: $*" >&2; exit 3
STUBEOF
chmod +x "${RSEL}/gh"
( cd "$WORK" && PATH="${RSEL}:$PATH" bash "$SUT" ingest o r 21 ) >/dev/null 2>&1 \
  && ok "ingest: uses a gh selector real gh accepts (number + --repo)" \
  || bad "ingest builds an unusable gh selector (owner/repo#n is a branch, not a PR)"

# --- ingest: success path exits cleanly under set -u (no stale-trap noise) ---
# The cleanup trap references the function-local tmpd; if it fires at script EXIT after the
# function returns, tmpd is out of scope and `set -u` prints "unbound variable" to stderr.
errf="${WORK}/ingest-stderr.txt"
( cd "$WORK" && PATH="${RSEL}:$PATH" bash "$SUT" ingest o r 31 ) >/dev/null 2>"$errf"
grep -q 'unbound variable' "$errf" \
  && bad "ingest leaks 'unbound variable' from the EXIT trap (got: $(cat "$errf"))" \
  || ok "ingest: success path exits cleanly under set -u"

# --- resolve-repo: owner|repo from the current repo (stubbed gh) ---
RSTUB="${WORK}/rbin"; mkdir -p "$RSTUB"
cat > "${RSTUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$1" == "repo" && "$2" == "view" ]] && { echo "octocat/hello-world"; exit 0; }
echo "unexpected gh call: $*" >&2; exit 3
STUBEOF
chmod +x "${RSTUB}/gh"
out="$( PATH="${RSTUB}:$PATH" bash "$SUT" resolve-repo 2>/dev/null )"
[[ "$out" == "octocat|hello-world" ]] && ok "resolve-repo: owner|repo" || bad "resolve-repo (got '$out')"

# --- resolve-repo: gh failure is surfaced ---
cat > "${RSTUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
PATH="${RSTUB}:$PATH" bash "$SUT" resolve-repo >/dev/null 2>&1 \
  && bad "resolve-repo should fail when gh fails" || ok "resolve-repo surfaces gh failure"

# --- publish: reads the PR url from the scratch HEADER (works on resume; GHE-safe) ---
# A scratch file as seed() writes it (plus the star Arm header) + a ## Review section with no
# findings, so publish takes the zero-inline-comments path: one plain `gh pr review --comment`.
CRP="${WORK}/scratch-with-header.md"
cat > "$CRP" <<'EOF'
# PR review: Demo

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8
- **Author:** alice
- **Branch:** feat/x

## PR description

Stuff.

## Review
EOF

PSTUB="${WORK}/pbin"; mkdir -p "$PSTUB"
CALLLOG="${WORK}/gh-calls.log"; : > "$CALLLOG"
cat > "${PSTUB}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLLOG}"
# capture the --body-file contents for assertion
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/posted-body.txt"
  prev="\$a"
done
exit 0
STUBEOF
chmod +x "${PSTUB}/gh"

PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRP" 'Claude Opus 4.8 (claude-opus-4-8)' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish: succeeds" || bad "publish code $code"
[[ "$(wc -l < "$CALLLOG")" -eq 1 ]] && ok "publish: exactly one gh call" || bad "publish made $(wc -l < "$CALLLOG") gh calls"
grep -q 'pr review https://github.com/o/r/pull/8 --comment --body-file' "$CALLLOG" \
  && ok "publish: posts neutral --comment to the header's PR url" || bad "publish gh args (got: $(cat "$CALLLOG"))"
grep -qF '🤖 Posted by AI agents' "${WORK}/posted-body.txt" \
  && ok "publish: body is the composed star review" || bad "publish body wrong (got: $(cat "${WORK}/posted-body.txt"))"
# never approve / request-changes
grep -qE -- '--approve|--request-changes' "$CALLLOG" && bad "publish must not approve/request-changes" || ok "publish: neutral only"

# --- publish: uses the ACTUAL header url (e.g. GitHub Enterprise host), not a reconstructed one ---
CRG="${WORK}/scratch-ghe.md"
cat > "$CRG" <<'EOF'
# PR review: GHE

<!-- multi-review-mode: star -->
- **PR:** https://github.example.com/o/r/pull/9

## Review
EOF
: > "$CALLLOG"
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRG" 'm' >/dev/null 2>&1
grep -q 'pr review https://github.example.com/o/r/pull/9 --comment --body-file' "$CALLLOG" \
  && ok "publish: uses the header url verbatim (GHE/resume-safe)" || bad "publish reconstructed wrong url (got: $(cat "$CALLLOG"))"

# --- publish: a scratch with no "- **PR:**" header fails clearly (don't post to a guessed url) ---
NOPRURL="${WORK}/no-pr-url.md"
cat > "$NOPRURL" <<'EOF'
# PR review: NoUrl

<!-- multi-review-mode: star -->

## Review
EOF
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$NOPRURL" 'm' >/dev/null 2>&1 \
  && bad "publish should fail when the scratch has no PR url header" || ok "publish fails when no PR url in scratch"

# --- publish: a non-star doc (no mode hint) is rejected — publish is star-only now ---
NOTSTAR="${WORK}/not-star.md"
cat > "$NOTSTAR" <<'EOF'
# PR review: NotStar

- **PR:** https://github.com/o/r/pull/8

## Review
EOF
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$NOTSTAR" 'm' >/dev/null 2>&1 \
  && bad "publish should refuse a scratch with no star mode hint" || ok "publish: refuses a non-star doc"

# --- publish: a gh failure is surfaced ---
cat > "${PSTUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRP" 'x' >/dev/null 2>&1 \
  && bad "publish should fail when gh fails" || ok "publish surfaces gh failure"

# --- diff-valid-lines / validate-anchor (Task 3) ---
DV="${WORK}/diffscratch.md"
cat > "$DV" <<'EOF'
# PR review: D

- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 context one
+added two
 context three
diff --git a/bar.sh b/bar.sh
--- a/bar.sh
+++ b/bar.sh
@@ -10,1 +10,2 @@
 ctx ten
+added eleven
```

## Review

> [finding:f1] x
> — via gpt-5-codex
EOF

vl="$(bash "$SUT" diff-valid-lines "$DV" 2>/dev/null)"
printf '%s\n' "$vl" | grep -qF 'foo.sh	1' && ok "diff-valid-lines: foo context line 1" || bad "diff-valid-lines foo:1 (got: $vl)"
printf '%s\n' "$vl" | grep -qF 'foo.sh	2' && ok "diff-valid-lines: foo added line 2" || bad "diff-valid-lines foo:2"
printf '%s\n' "$vl" | grep -qF 'foo.sh	3' && ok "diff-valid-lines: foo context line 3" || bad "diff-valid-lines foo:3"
printf '%s\n' "$vl" | grep -qF 'bar.sh	11' && ok "diff-valid-lines: bar added line 11" || bad "diff-valid-lines bar:11"

bash "$SUT" validate-anchor "$DV" foo.sh 2     && ok "validate-anchor: valid single line" || bad "validate-anchor foo:2 should pass"
bash "$SUT" validate-anchor "$DV" foo.sh 1 3   && ok "validate-anchor: valid range" || bad "validate-anchor foo:1-3 should pass"
bash "$SUT" validate-anchor "$DV" foo.sh 99    && bad "validate-anchor off-diff should fail" || ok "validate-anchor: off-diff line fails"
bash "$SUT" validate-anchor "$DV" nope.sh 2    && bad "validate-anchor unknown path should fail" || ok "validate-anchor: unknown path fails"
bash "$SUT" validate-anchor "$DV" foo.sh 2 99  && bad "validate-anchor range partly off-diff should fail" || ok "validate-anchor: range partly off-diff fails"
bash "$SUT" validate-anchor "$DV" foo.sh 5 2   && bad "validate-anchor end<start should fail" || ok "validate-anchor: end<start fails"

# --- publish: inline comments via gh api (Task 4) ---
ASTUB="${WORK}/abin"; mkdir -p "$ASTUB"
ACALLS="${WORK}/gh-api-calls.log"; : > "$ACALLS"
cat > "${ASTUB}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${ACALLS}"
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--input" ]] && cp "\$a" "${WORK}/api-payload.json"
  [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/posted-body.txt"
  prev="\$a"
done
exit 0
STUBEOF
chmod +x "${ASTUB}/gh"

AIN="${WORK}/inline-scratch.md"
cat > "$AIN" <<'EOF'
# PR review: Inline

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:f1|high] anchored on a real changed line
> — via gpt-5-codex
> — risk: r
> — at foo.sh:2
>
> [agree:f1]
> — via claude-opus-4-8
EOF
: > "$ACALLS"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$AIN" 'claude-opus-4-8' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish-inline: succeeds" || bad "publish-inline code $code"
grep -q 'api .*repos/o/r/pulls/8/reviews' "$ACALLS" && ok "publish-inline: posts via gh api reviews" || bad "publish-inline gh api call (got: $(cat "$ACALLS"))"
grep -q 'pr review' "$ACALLS" && bad "publish-inline should not use pr review when inline succeeds" || ok "publish-inline: single review via api"
# payload shape
jq -e '.event == "COMMENT"' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: event COMMENT" || bad "publish-inline event"
jq -e '.comments | length == 1' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: one inline comment" || bad "publish-inline comment count"
jq -e '.comments[0].path == "foo.sh" and .comments[0].line == 2 and .comments[0].side == "RIGHT"' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: comment anchored RIGHT line 2" || bad "publish-inline comment fields"
jq -e '.body | contains("Commented inline")' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: summary notes inline count" || bad "publish-inline summary note"

# --- publish: invalid anchor degrades to summary, still posts ---
ABAD="${WORK}/inline-bad.md"
cat > "$ABAD" <<'EOF'
# PR review: InlineBad

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:f1|high] anchored OFF the diff (line 999)
> — via gpt-5-codex
> — risk: r
> — at foo.sh:999
>
> [agree:f1]
> — via claude-opus-4-8
EOF
: > "$ACALLS"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$ABAD" 'claude-opus-4-8' >/dev/null 2>&1
# no valid inline comments -> falls back to the plain pr review path
grep -q 'pr review https://github.com/o/r/pull/8 --comment' "$ACALLS" && ok "publish-degrade: posts summary via pr review" || bad "publish-degrade fallback (got: $(cat "$ACALLS"))"
grep -qF 'anchored OFF the diff' "${WORK}/posted-body.txt" && ok "publish-degrade: degraded finding still in summary" || bad "publish-degrade summary body"

# --- publish: gh api rejection retries summary-only via pr review ---
RSTUB2="${WORK}/rejbin"; mkdir -p "$RSTUB2"
RCALLS="${WORK}/gh-rej-calls.log"; : > "$RCALLS"
cat > "${RSTUB2}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${RCALLS}"
if [[ "\$1" == "api" ]]; then echo "422 Unprocessable Entity" >&2; exit 1; fi
prev=""
for a in "\$@"; do [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/retry-body.txt"; prev="\$a"; done
exit 0
STUBEOF
chmod +x "${RSTUB2}/gh"
: > "$RCALLS"
PATH="${RSTUB2}:$PATH" bash "$SUT" publish "$AIN" 'claude-opus-4-8' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish-retry: succeeds after api rejection" || bad "publish-retry code $code"
grep -q '^api ' "$RCALLS" && grep -q 'pr review .* --comment' "$RCALLS" && ok "publish-retry: api then pr review fallback" || bad "publish-retry sequence (got: $(cat "$RCALLS"))"

# --- publish: MIXED valid + invalid anchors — one inline, one degraded (Task 4, r2) ---
AMIX="${WORK}/inline-mixed.md"
cat > "$AMIX" <<'EOF'
# PR review: Mixed

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:f1|high] valid anchor on a changed line
> — via gpt-5-codex
> — risk: r
> — at foo.sh:2
>
> [agree:f1]
> — via claude-opus-4-8
>
> [finding:f2|med] anchor off the diff degrades to summary
> — via gpt-5-codex
> — risk: r
> — at foo.sh:999
>
> [agree:f2]
> — via claude-opus-4-8
EOF
: > "$ACALLS"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$AMIX" 'claude-opus-4-8' >/dev/null 2>&1
grep -q 'api .*repos/o/r/pulls/8/reviews' "$ACALLS" && ok "publish-mixed: posts via gh api (one valid inline)" || bad "publish-mixed api call (got: $(cat "$ACALLS"))"
jq -e '.comments | length == 1' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: exactly one inline comment" || bad "publish-mixed comment count"
jq -e '.comments[0].line == 2' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: inline is the valid finding" || bad "publish-mixed inline line"
jq -e '.body | contains("Commented inline (1)")' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: body notes inline count" || bad "publish-mixed inline note"
jq -e '.body | contains("Could not place inline")' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: body has degraded section" || bad "publish-mixed degraded section"
jq -e '.body | contains("anchor off the diff degrades to summary")' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: degraded finding text in body" || bad "publish-mixed degraded text"
jq -e '(.body | contains("anchor off the diff degrades to summary — ð¤")) | not' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: degraded line has no disclosure footer" || bad "publish-mixed degraded footer not stripped"

# --- publish: a malformed anchor FAILS the post (contract violation), never degrades (Task 4, r1) ---
# Needs an [agree:] response: star's compose-inline only calls anchor_of() (which validates the
# "> — at" line and hard-fails on malformed input) for agreed findings — an unresponded (open)
# finding is never anchor-checked, so this must be agreed to actually exercise the failure path.
AMAL="${WORK}/inline-malformed.md"
cat > "$AMAL" <<'EOF'
# PR review: Malformed

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8

## Review

> [finding:f1|high] malformed anchor — no line number
> — via gpt-5-codex
> — risk: r
> — at foo.sh
>
> [agree:f1]
> — via claude-opus-4-8
EOF
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$AMAL" 'claude-opus-4-8' >/dev/null 2>&1 \
  && bad "publish should FAIL on a malformed-anchor contract violation, not post" \
  || ok "publish-malformed: contract violation fails the post (no silent degrade)"

# --- publish: star mode dispatches through the star composer + cmd_post_review's posting
# path — the live (only) publish path now that peer/asymmetric are retired (B3). ---
STARSCRATCH="${WORK}/star-scratch.md"
cat > "$STARSCRATCH" <<'EOF'
# PR review: Star

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:codex-rd1-a|high] anchored star concern
> — via gpt-5.5
> — risk: some risk
> — at foo.sh:2
> [agree:codex-rd1-a]
> — via claude-opus-4-8
EOF
: > "$ACALLS"; rm -f "${WORK}/api-payload.json" "${WORK}/posted-body.txt"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$STARSCRATCH" 'claude-opus-4-8' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish-star: succeeds" || bad "publish-star code $code"
[[ "$(wc -l < "$ACALLS")" -eq 1 ]] && ok "publish-star: exactly one gh call" || bad "publish-star made $(wc -l < "$ACALLS") gh calls"
grep -q 'api .*repos/o/r/pulls/8/reviews' "$ACALLS" && ok "publish-star: posts via gh api reviews (inline path)" || bad "publish-star gh api call (got: $(cat "$ACALLS"))"
jq -e '.comments | length == 1' "${WORK}/api-payload.json" >/dev/null && ok "publish-star: one inline comment" || bad "publish-star comment count"
jq -e '.comments[0].path == "foo.sh" and .comments[0].line == 2' "${WORK}/api-payload.json" >/dev/null && ok "publish-star: inline anchored to foo.sh:2" || bad "publish-star inline fields"
jq -e '.body | contains("multi-review star review")' "${WORK}/api-payload.json" >/dev/null && ok "publish-star: body carries the star composer's disclosure" || bad "publish-star body missing star disclosure (got: $(cat "${WORK}/api-payload.json"))"
# Read .body as text and check it with bash, rather than `jq -e '... | contains(...)' | not` —
# the inverted jq form is vacuous: a jq runtime error (e.g. a missing/null .body) also exits
# non-zero, same as a genuine "does not contain" result, so a broken payload would silently
# read as "ok" instead of failing loud.
star_body="$(jq -r '.body // empty' "${WORK}/api-payload.json")"
if [[ -z "$star_body" ]]; then
  bad "publish-star: could not read .body from the api payload"
elif [[ "$star_body" == *'Addressed ('* ]]; then
  bad "publish-star used the asymmetric compose"
else
  ok "publish-star: not the asymmetric compose"
fi

# ============================== Phase B: head records ==============================
# mkscratch <name> -> a seeded scratch file with a diff and an empty ## Review
mkscratch() {
  local p="${WORK}/$1"
  printf 'body text\n' > "${WORK}/d.desc"
  printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-old\n+new\n' > "${WORK}/d.diff"
  bash "$SUT" seed "$p" "T" "https://github.com/o/r/pull/9" "auth" "br" "${WORK}/d.desc" "${WORK}/d.diff"
  echo "$p"
}

# --- record-head writes a record readable by head-record ---
SC="$(mkscratch s1.md)"
bash "$SUT" record-head "$SC" 1 aaaa1111 bbbb2222 2>/dev/null
out="$(bash "$SUT" head-record "$SC" 1 2>/dev/null)"
[[ "$out" == "aaaa1111|bbbb2222" ]] && ok "record-head: round-trips head|merge-base" || bad "head record round-trip (got '$out')"

# --- the record lives in the HEADER region, above the first '## ' heading ---
recln="$(grep -n 'multi-review-pr-head' "$SC" | head -1 | cut -d: -f1)"
firsth="$(grep -n '^## ' "$SC" | head -1 | cut -d: -f1)"
(( recln < firsth )) && ok "record-head: record sits in the header region" || bad "record outside header (rec=$recln first##=$firsth)"

# --- records ACCUMULATE; an earlier round is never overwritten ---
bash "$SUT" record-head "$SC" 2 cccc3333 bbbb2222 2>/dev/null
r1="$(bash "$SUT" head-record "$SC" 1 2>/dev/null)"
r2="$(bash "$SUT" head-record "$SC" 2 2>/dev/null)"
[[ "$r1" == "aaaa1111|bbbb2222" && "$r2" == "cccc3333|bbbb2222" ]] \
  && ok "record-head: rounds accumulate independently" || bad "records clobbered (r1='$r1' r2='$r2')"

# --- head-record for a round with no record fails, and prints nothing ---
out="$(bash "$SUT" head-record "$SC" 7 2>/dev/null)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "head-record: absent round fails loud" || bad "absent round leaked (rc=$rc out='$out')"

# --- re-recording the SAME round is refused (a round's record is immutable) ---
bash "$SUT" record-head "$SC" 1 dddd4444 bbbb2222 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "record-head: refuses to overwrite a round" || bad "round record was overwritten"

# --- replace-diff swaps ## Diff and preserves ## Review byte-identical ---
SC2="$(mkscratch s2.md)"
printf '> [finding:codex-rd1-r1|low] a finding\n> — via gpt-5\n> — risk: r\n' >> "$SC2"
before_review="$(awk '/^## Review$/{f=1} f' "$SC2")"
printf 'diff --git a/g.txt b/g.txt\n--- a/g.txt\n+++ b/g.txt\n@@ -1 +1 @@\n-p\n+q\n' > "${WORK}/d2.diff"
bash "$SUT" replace-diff "$SC2" "${WORK}/d2.diff" 2>/dev/null
after_review="$(awk '/^## Review$/{f=1} f' "$SC2")"
[[ "$before_review" == "$after_review" ]] && ok "replace-diff: ## Review survives byte-identical" || bad "## Review altered by replace-diff"
grep -q 'g.txt' "$SC2" && ok "replace-diff: new diff is present" || bad "new diff missing"
grep -q 'f.txt' "$SC2" && bad "old diff survived replace-diff" || ok "replace-diff: old diff replaced"

# --- replace-diff preserves the PR header (url/author/branch) ---
grep -q '^- \*\*PR:\*\* https://github.com/o/r/pull/9$' "$SC2" \
  && ok "replace-diff: PR header preserved" || bad "PR header lost"

# --- replace-diff recomputes the fence for content carrying a 3-backtick run ---
SC3="$(mkscratch s3.md)"
printf 'diff --git a/h.md b/h.md\n--- a/h.md\n+++ b/h.md\n@@ -1 +1,2 @@\n-x\n+```\n' > "${WORK}/d3.diff"
bash "$SUT" replace-diff "$SC3" "${WORK}/d3.diff" 2>/dev/null
awk '/^## Diff$/{f=1;next} f&&/^`{4,}$/{n++} END{exit !(n>=2)}' "$SC3" \
  && ok "replace-diff: fence widened past content" || bad "replace-diff fence not widened"

# --- refresh: a scratch with no PR url fails loud, and does not touch the file ---
SC4="$(mkscratch s4.md)"
perl -ni -e 'print unless /^- \*\*PR:\*\* /' "$SC4"
sum_before="$(shasum "$SC4" | cut -d' ' -f1)"
bash "$SUT" refresh "$SC4" 2 >/dev/null 2>&1; rc=$?
sum_after="$(shasum "$SC4" | cut -d' ' -f1)"
[[ $rc -ne 0 && "$sum_before" == "$sum_after" ]] \
  && ok "refresh: no PR url fails loud, scratch untouched" || bad "refresh mangled a url-less scratch (rc=$rc)"

# --- refresh: a non-numeric round is rejected before any network call ---
SC5="$(mkscratch s5.md)"
bash "$SUT" refresh "$SC5" notanumber >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "refresh: non-numeric round rejected" || bad "refresh accepted a bad round"

# ============================== Phase B: anchor remapping ==============================
# mkanchored <name> -> scratch whose diff has 3 added lines in f.txt and one anchored finding
mkanchored() {
  local p="${WORK}/$1"
  printf 'body\n' > "${WORK}/a.desc"
  printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,3 @@\n+alpha\n+bravo\n+charlie\n' > "${WORK}/a.diff"
  bash "$SUT" seed "$p" "T" "https://github.com/o/r/pull/9" "auth" "br" "${WORK}/a.desc" "${WORK}/a.diff"
  {
    printf '> [finding:codex-rd1-r1|med] concern\n> — via gpt-5\n> — risk: r\n> — at f.txt:2\n'
    printf '> [agree:codex-rd1-r1]\n> — via claude-opus-5\n'
  } >> "$p"
  echo "$p"
}

# --- with no recorded anchors, remap is a no-op (nothing refreshed yet) ---
SA="$(mkanchored a1.md)"
out="$(bash "$SUT" remap-anchor "$SA" f.txt 2 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$out" == "2" ]] && ok "remap-anchor: no-op before any refresh" || bad "remap no-op (rc=$rc out='$out')"

# --- record-anchors captures the text the anchor points at TODAY ---
bash "$SUT" record-anchors "$SA" 2>/dev/null
grep -q 'multi-review-pr-anchor: f.txt:2' "$SA" && ok "record-anchors: records the anchored line" \
  || bad "no anchor record written"

# --- after the diff shifts, the anchor remaps to the line's NEW number ---
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,5 @@\n+zero\n+one\n+alpha\n+bravo\n+charlie\n' > "${WORK}/a2.diff"
bash "$SUT" replace-diff "$SA" "${WORK}/a2.diff" 2>/dev/null
out="$(bash "$SUT" remap-anchor "$SA" f.txt 2 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$out" == "4" ]] && ok "remap-anchor: follows the line to its new number" \
  || bad "remap did not follow the line (rc=$rc out='$out')"

# --- a line that no longer exists does NOT remap (degrades to the summary) ---
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,2 @@\n+zero\n+one\n' > "${WORK}/a3.diff"
bash "$SUT" replace-diff "$SA" "${WORK}/a3.diff" 2>/dev/null
bash "$SUT" remap-anchor "$SA" f.txt 2 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "remap-anchor: vanished line fails (-> summary)" || bad "vanished line still remapped"

# --- an AMBIGUOUS match (same text twice) does not remap ---
SB="$(mkanchored a4.md)"
bash "$SUT" record-anchors "$SB" 2>/dev/null
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,3 @@\n+bravo\n+x\n+bravo\n' > "${WORK}/a5.diff"
bash "$SUT" replace-diff "$SB" "${WORK}/a5.diff" 2>/dev/null
bash "$SUT" remap-anchor "$SB" f.txt 2 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "remap-anchor: ambiguous match fails (-> summary)" || bad "ambiguous match remapped"

# --- the match is scoped to the anchor's own PATH ---
SC6="$(mkanchored a6.md)"
bash "$SUT" record-anchors "$SC6" 2>/dev/null
printf 'diff --git a/other.txt b/other.txt\n--- a/other.txt\n+++ b/other.txt\n@@ -0,0 +1,1 @@\n+bravo\n' > "${WORK}/a7.diff"
bash "$SUT" replace-diff "$SC6" "${WORK}/a7.diff" 2>/dev/null
bash "$SUT" remap-anchor "$SC6" f.txt 2 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "remap-anchor: identical line in another file is not a match" \
  || bad "anchor jumped to a different file"

# ============================== PR #33 review: regressions ==============================
# mkselfref <name> — a scratch whose DIFF legitimately contains a record line, as this repo's
# own PRs do, plus a PR description containing a forged one.
mkselfref() {
  local p="${WORK}/$1"
  printf 'Look at this record: <!-- multi-review-pr-head: eeee5555 · merge-base ffff6666 · round 2 -->\n' > "${WORK}/sr.desc"
  printf 'diff --git a/x.sh b/x.sh\n--- a/x.sh\n+++ b/x.sh\n@@ -0,0 +1,1 @@\n+# <!-- multi-review-pr-head: abc123 · merge-base def456 · round 1 -->\n' > "${WORK}/sr.diff"
  bash "$SUT" seed "$p" "T" "https://github.com/o/r/pull/1" "a" "b" "${WORK}/sr.desc" "${WORK}/sr.diff"
  echo "$p"
}

# --- fable-rd1-r1: a record line inside ## Diff must not become the placement anchor ---
SR="$(mkselfref sr1.md)"
bash "$SUT" record-head "$SR" 1 HEAD111 MB222 2>/dev/null
hdr_end="$(grep -n '^## ' "$SR" | head -1 | cut -d: -f1)"
recln="$(grep -n 'multi-review-pr-head: HEAD111' "$SR" | head -1 | cut -d: -f1)"
[[ -n "$recln" ]] && (( recln < hdr_end )) \
  && ok "self-referential PR: record lands in the header, not inside ## Diff" \
  || bad "record escaped the header (rec=${recln:-none} first##=$hdr_end)"

# --- ...and it survives a replace-diff ---
printf 'diff --git a/y.sh b/y.sh\n--- a/y.sh\n+++ b/y.sh\n@@ -0,0 +1,1 @@\n+ok\n' > "${WORK}/sr2.diff"
bash "$SUT" replace-diff "$SR" "${WORK}/sr2.diff" 2>/dev/null
out="$(bash "$SUT" head-record "$SR" 1 2>/dev/null)"
[[ "$out" == "HEAD111|MB222" ]] && ok "self-referential PR: record survives replace-diff" \
  || bad "record destroyed by replace-diff (got '$out')"

# --- fable-rd1-r3: a forged record in untrusted PR text is NOT readable ---
SR2="$(mkselfref sr3.md)"
bash "$SUT" head-record "$SR2" 2 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "forged record in the PR description is not honored" \
  || bad "untrusted PR text forged a readable head record"

# --- ...and it does not wedge record-head via the immutability check ---
bash "$SUT" record-head "$SR2" 2 REAL222 REALMB 2>/dev/null
out="$(bash "$SUT" head-record "$SR2" 2 2>/dev/null)"
[[ "$out" == "REAL222|REALMB" ]] && ok "forged record does not block a real one" \
  || bad "forged record wedged record-head (got '$out')"

# --- fable-rd1-r2: a path:line key reused with DIFFERENT content degrades, never mis-remaps ---
SD="${WORK}/dup.md"
printf 'body\n' > "${WORK}/dp.desc"
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,2 @@\n+alpha\n+bravo\n' > "${WORK}/dp.diff"
bash "$SUT" seed "$SD" T "https://github.com/o/r/pull/2" a b "${WORK}/dp.desc" "${WORK}/dp.diff"
printf '> [finding:codex-rd1-r1|low] one\n> — via gpt-5\n> — risk: r\n> — at f.txt:2\n' >> "$SD"
bash "$SUT" record-anchors "$SD" 2>/dev/null           # f.txt:2 == "bravo"
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,3 @@\n+zulu\n+yankee\n+bravo\n' > "${WORK}/dp2.diff"
bash "$SUT" replace-diff "$SD" "${WORK}/dp2.diff" 2>/dev/null
printf '> [finding:fable-rd2-r1|low] two\n> — via claude-fable-5\n> — risk: r\n> — at f.txt:2\n' >> "$SD"
bash "$SUT" record-anchors "$SD" 2>/dev/null           # f.txt:2 now "yankee" -> key poisoned
bash "$SUT" remap-anchor "$SD" f.txt 2 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "reused anchor key with different content degrades to the summary" \
  || bad "colliding anchor key still remapped (fable-rd1-r2)"

# --- codex-rd1-r2: a RANGE anchor records both endpoints ---
SG="${WORK}/rng.md"
printf 'body\n' > "${WORK}/rg.desc"
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,4 @@\n+aa\n+bb\n+cc\n+dd\n' > "${WORK}/rg.diff"
bash "$SUT" seed "$SG" T "https://github.com/o/r/pull/3" a b "${WORK}/rg.desc" "${WORK}/rg.diff"
printf '> [finding:codex-rd1-r1|low] r\n> — via gpt-5\n> — risk: r\n> — at f.txt:2-4\n' >> "$SG"
bash "$SUT" record-anchors "$SG" 2>/dev/null
n="$(grep -c 'multi-review-pr-anchor: f.txt:' "$SG")"
(( n == 2 )) && ok "range anchor: both endpoints recorded" || bad "range endpoints not recorded (n=$n)"

# --- ...and the end remaps independently of the old span ---
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,6 @@\n+zz\n+aa\n+bb\n+NEW\n+cc\n+dd\n' > "${WORK}/rg2.diff"
bash "$SUT" replace-diff "$SG" "${WORK}/rg2.diff" 2>/dev/null
rs="$(bash "$SUT" remap-anchor "$SG" f.txt 2 2>/dev/null)"
re="$(bash "$SUT" remap-anchor "$SG" f.txt 4 2>/dev/null)"
[[ "$rs" == "3" && "$re" == "6" ]] \
  && ok "range anchor: end remaps independently (span grew 2->3)" \
  || bad "range end not independently remapped (start=$rs end=$re)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
