#!/usr/bin/env bash
# multi-review-scope.test.sh — diff-scoped copy construction for round N>=2 (local docs).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-scope.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

mkbase() {
  local p="${WORK}/$1"; shift
  {
    echo "# Doc Title"; echo
    echo "<!-- multi-review: awaiting-secondaries · round 9/5 -->"
    echo "<!-- multi-review-mode: star · reviewers: codex fable -->"; echo
    printf '%s\n' "$@"; echo; echo "## Review"
  } > "$p"
  echo "$p"
}

P="$(mkbase prev1.md '## Alpha' '' 'alpha one' '' '## Beta' '' 'beta one')"
C="$(mkbase curr1.md '## Alpha' '' 'alpha CHANGED' '' '## Beta' '' 'beta one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0 on a scopeable delta" || bad "rc=$rc"
grep -q '^# Doc Title$' <<<"$out" && ok "carries the H1" || bad "no H1"
grep -q '^<!-- multi-review: awaiting-reviewer · round 2/5 -->$' <<<"$out" && ok "fresh copy marker" || bad "copy marker"
grep -q '^<!-- multi-review-mode: star -->$' <<<"$out" && ok "bare mode hint" || bad "mode hint"
[[ "$(grep -c '<!-- multi-review:' <<<"$out")" == "1" ]] && ok "exactly one status marker" || bad "dup marker (D-a)"
grep -q '^## Changes since round 1$' <<<"$out" && ok "diff heading" || bad "no diff heading"
grep -q 'alpha CHANGED' <<<"$out" && ok "emits touched region" || bad "region text missing"
grep -q '^> Unchanged this round, not shown: Beta\.$' <<<"$out" && ok "names untouched region" || bad "untouched not named"
grep -q 'beta one' <<<"$out" && bad "untouched region leaked" || ok "untouched region omitted"
[[ "$(grep -v '^$' <<<"$out" | tail -1)" == "## Review" ]] && ok "ends with an empty ## Review" || bad "## Review not last"

bash "$SUT" local-copy --round 2 --max 5 --prev "${WORK}/nope.md" --curr "$C" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "exit 3 on missing --prev" || bad "missing --prev not exit 3"

P="$(mkbase prev2.md '## Alpha' '' 'alpha one')"
C="$(mkbase curr2.md '## Alpha' '' 'alpha one' '' '```sh' 'echo hi' '```')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^````diff$' <<<"$out" && ok "outer fence widened" || bad "fence not widened"
n="$(grep -c '^````' <<<"$out")"; (( n >= 2 && n % 2 == 0 )) && ok "fences balanced (non-vacuous)" || bad "unbalanced (n=$n)"

P="$(mkbase prev3.md '## Alpha' '' 'alpha one' '' '```' '## NotAHeading' '```' '' '## Beta' '' 'b')"
C="$(mkbase curr3.md '## Alpha' '' 'alpha TWO' '' '```' '## NotAHeading' '```' '' '## Beta' '' 'b')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'NotAHeading' <<<"$out" && ok "fenced heading stays in region" || bad "fenced content lost"
grep -q 'Unchanged this round, not shown:.*NotAHeading' <<<"$out" && bad "phantom region (backticks)" || ok "no phantom (backticks)"

P="$(mkbase prev4.md '## Alpha' '' 'alpha one' '' '~~~' '## TildeHeading' '~~~' '' '## Beta' '' 'b')"
C="$(mkbase curr4.md '## Alpha' '' 'alpha TWO' '' '~~~' '## TildeHeading' '~~~' '' '## Beta' '' 'b')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'Unchanged this round, not shown:.*TildeHeading' <<<"$out" && bad "phantom region (tildes)" || ok "no phantom (tildes)"

P="$(mkbase prev5.md 'Status: draft.' '' '## Alpha' '' 'a')"
C="$(mkbase curr5.md 'Status: FINAL.' '' '## Alpha' '' 'a')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'Status: FINAL\.' <<<"$out" && ok "preamble-only change emitted" || bad "preamble change vanished"
grep -q '^> Unchanged this round, not shown: Alpha\.$' <<<"$out" && ok "sibling named unchanged" || bad "sibling not named"

P="$(mkbase prev6.md 'Status: draft.' '' '## Alpha' '' 'a one')"
C="$(mkbase curr6.md 'Status: draft.' '' '## Alpha' '' 'a TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Unchanged this round, not shown: preamble\.$' <<<"$out" && ok "untouched preamble named" || bad "untouched preamble not named"

P="$(mkbase prev7.md '## Alpha' '' 'a one' '' '## Beta' '' 'b one' '' '## Gamma' '' 'g one')"
C="$(mkbase curr7.md '## Alpha' '' 'a TWO' '' '## Beta' '' 'b one' '' '## Gamma' '' 'g TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'a TWO' <<<"$out" && grep -q 'g TWO' <<<"$out" && ok "both changed regions emitted" || bad "multi-region incomplete"
grep -q '^> Unchanged this round, not shown: Beta\.$' <<<"$out" && ok "only untouched named" || bad "unchanged list wrong"

P="$(mkbase prev8.md '## Alpha' '' 'a one' '' '## Doomed' '' 'gone soon')"
C="$(mkbase curr8.md '## Alpha' '' 'a one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Removed this round, no longer present: Doomed\.$' <<<"$out" && ok "removed region named" || bad "removed not named"
grep -q 'Unchanged this round, not shown:.*Doomed' <<<"$out" && bad "removed claimed unchanged" || ok "removed not claimed unchanged"

P9="$(mkbase prev9.md '## Alpha' '' 'a one')"
C9="$(mkbase curr9.md '## Alpha' '' 'a TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P9" --curr "$C9" 2>/dev/null)"
grep -q 'Removed this round' <<<"$out" && bad "removed line with nothing removed" || ok "removed line omitted when empty"

bash "$SUT" local-copy --round 2 --max 5 --prev "$P9" --curr "$P9" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "empty delta exit 3" || bad "unchanged doc not exit 3"

PM="${WORK}/mprev.md"; CM="${WORK}/mcurr.md"
{ echo "# Doc Title"; echo; echo "<!-- multi-review: awaiting-secondaries · round 2/5 -->";
  echo "<!-- multi-review-mode: star -->"; echo; echo "## Alpha"; echo; echo "a one";
  echo; echo "## Review"; } > "$PM"
{ echo "# Doc Title"; echo; echo "<!-- multi-review: awaiting-secondaries · round 3/5 -->";
  echo "<!-- multi-review-mode: star -->"; echo; echo "## Alpha"; echo; echo "a one";
  echo; echo "## Review"; } > "$CM"
bash "$SUT" local-copy --round 3 --max 5 --prev "$PM" --curr "$CM" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "marker churn is empty delta" || bad "marker change counted as delta"

P="$(mkbase prevA.md '## Alpha' '' 'a one' '' '## Beta' '' 'b one')"
C="$(mkbase currA.md '## Alpha' '' 'a NEW' '' '## Beta' '' 'b NEW')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'a NEW' <<<"$out" && grep -q 'b NEW' <<<"$out" && ok "rewrite emits every region" || bad "rewrite lost a region"
grep -q 'Unchanged this round' <<<"$out" && bad "rewrite names unchanged" || ok "rewrite: no unchanged list"

P="$(mkbase prevB.md '## Alpha' '' 'keep  double  spaces' '' '## Beta' '' 'b')"
C="$(mkbase currB.md '## Alpha' '' 'keep  double  spaces' 'added line' '' '## Beta' '' 'b')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^keep  double  spaces$' <<<"$out" && ok "region text byte-identical" || bad "region text altered"

# --- an H1 inside a preamble fence survives (gemini-rd1-r1, fable-rd1-r2) ---
P="$(mkbase prevC.md 'Intro prose.' '' '```bash' '# run the thing' 'do_it' '```' '' '## Alpha' '' 'a one')"
C="$(mkbase currC.md 'Intro prose.' '' '```bash' '# run the thing' 'do_it' '```' '' '## Alpha' '' 'a TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Unchanged this round, not shown: preamble\.$' <<<"$out" \
  && ok "header strip: bounded (fenced H1 kept in preamble region)" || bad "preamble mangled"
P="$(mkbase prevD.md 'Intro.' '' '```bash' '# keep me' '```' '' '## Alpha' '' 'a')"
C="$(mkbase currD.md 'Intro CHANGED.' '' '```bash' '# keep me' '```' '' '## Alpha' '' 'a')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^# keep me$' <<<"$out" \
  && ok "header strip: fenced H1 emitted verbatim" || bad "fenced H1 stripped (fable-rd1-r2)"

# --- a body with NO "## " section keeps its content H1s (gemini-rd1-r1) ---
P="$(mkbase prevE.md '# Content Heading' '' 'body one')"
C="$(mkbase currE.md '# Content Heading' '' 'body TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
[[ "$(grep -c '^# Content Heading$' <<<"$out")" == "1" ]] \
  && ok "header strip: content H1 kept when body has no H2" || bad "content H1 dropped (gemini-rd1-r1)"

# --- duplicate heading names are distinct regions (codex-rd1-r1, fable-rd1-r3) ---
P="$(mkbase prevF.md '## Details' '' 'first one' '' '## Other' '' 'o' '' '## Details' '' 'second one')"
C="$(mkbase currF.md '## Details' '' 'first CHANGED' '' '## Other' '' 'o' '' '## Details' '' 'second one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'first CHANGED' <<<"$out" && ok "dup names: changed duplicate emitted" || bad "changed dup missing"
grep -q 'second one' <<<"$out" \
  && bad "untouched duplicate leaked (codex-rd1-r1)" || ok "dup names: untouched duplicate omitted"

# --- deleting one of two same-named regions reports it removed (fable-rd1-r3) ---
P="$(mkbase prevG.md '## Details' '' 'first' '' '## Details' '' 'second')"
C="$(mkbase currG.md '## Details' '' 'first')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Removed this round, no longer present: Details\.$' <<<"$out" \
  && ok "dup names: one deleted duplicate reported removed" || bad "duplicate removal not reported"

# --- a wholly emptied body still names what was removed (gemini-rd1-r2) ---
P="$(mkbase prevH.md '## Doomed' '' 'gone')"
C="${WORK}/currH.md"
{ echo "# Doc Title"; echo; echo "<!-- multi-review: awaiting-secondaries · round 9/5 -->";
  echo "<!-- multi-review-mode: star · reviewers: codex fable -->"; echo; echo "## Review"; } > "$C"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Removed this round, no longer present: Doomed\.$' <<<"$out" \
  && ok "empty curr: removed regions still named" || bad "removed list suppressed (gemini-rd1-r2)"

# --- a flag with no value errors instead of hanging (fable-rd1-r1) ---
bash "$SUT" local-copy --round >/dev/null 2>&1 &
pid=$!; sleep 2
if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; bad "flag without value hangs (fable-rd1-r1)"
else wait "$pid"; [[ $? -eq 1 ]] && ok "flag without value exits 1" || bad "wrong exit for valueless flag"; fi

# --- no temp dir is leaked on the exit-3 path (gemini-rd1-r3, fable-rd1-r4) ---
before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
P9b="$(mkbase prevI.md '## Alpha' '' 'a')"
for _ in 1 2 3; do bash "$SUT" local-copy --round 2 --max 5 --prev "$P9b" --curr "$P9b" >/dev/null 2>&1; done
after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
(( after <= before )) && ok "exit 3 leaks no temp dir" || bad "temp dirs leaked ($before -> $after)"

# --- an indented "## " is a heading, per CommonMark (codex-rd1-r2) ---
P="$(mkbase prevJ.md '## Alpha' '' 'a one' '' '   ## Indented' '' 'i one')"
C="$(mkbase currJ.md '## Alpha' '' 'a TWO' '' '   ## Indented' '' 'i one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'Unchanged this round, not shown:.*Indented' <<<"$out" \
  && ok "indent: up to 3 spaces still opens a region (CommonMark)" || bad "indented heading not a region"

# --- a FENCED "## Review" after the real one does not mis-truncate the body (fable-rd2-r7) ---
PK="${WORK}/prevK.md"; CK="${WORK}/currK.md"
for f in "$PK" "$CK"; do
  { echo "# Doc Title"; echo; echo "<!-- multi-review: awaiting-secondaries · round 9/5 -->"; echo
    echo "## Alpha"; echo; echo "alpha PLACEHOLDER"; echo
    echo "## Review"; echo; echo '```'; echo "## Review"; echo '```'; } > "$f"
done
perl -pi -e 's/alpha PLACEHOLDER/alpha one/' "$PK"; perl -pi -e 's/alpha PLACEHOLDER/alpha TWO/' "$CK"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$PK" --curr "$CK" 2>/dev/null)"
grep -q 'alpha TWO' <<<"$out" \
  && ok "truncation: fenced ## Review after the real one is ignored" || bad "body mis-truncated (fable-rd2-r7)"

# --- an INDENTED "## Review" still truncates, matching _regions (gemini-rd2-r3) ---
PL="${WORK}/prevL.md"; CL="${WORK}/currL.md"
for f in "$PL" "$CL"; do
  { echo "# Doc Title"; echo; echo "## Alpha"; echo; echo "alpha PLACEHOLDER"; echo; echo "  ## Review"; } > "$f"
done
perl -pi -e 's/alpha PLACEHOLDER/alpha one/' "$PL"; perl -pi -e 's/alpha PLACEHOLDER/alpha TWO/' "$CL"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$PL" --curr "$CL" 2>/dev/null)"
grep -q 'Unchanged this round, not shown:.*Review' <<<"$out" \
  && bad "indented ## Review became a region (gemini-rd2-r3)" || ok "truncation: indented ## Review truncates"

# --- _h1 ignores a "# " line inside a fence (gemini-rd2-r1) ---
PM2="${WORK}/prevM.md"; CM2="${WORK}/currM.md"
for f in "$PM2" "$CM2"; do
  { echo '```'; echo "# not the title"; echo '```'; echo; echo "# Real Title"; echo
    echo "## Alpha"; echo; echo "alpha PLACEHOLDER"; echo; echo "## Review"; } > "$f"
done
perl -pi -e 's/alpha PLACEHOLDER/alpha one/' "$PM2"; perl -pi -e 's/alpha PLACEHOLDER/alpha TWO/' "$CM2"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$PM2" --curr "$CM2" 2>/dev/null)"
[[ "$(head -1 <<<"$out")" == "# Real Title" ]] \
  && ok "_h1: fenced '# ' is not the title" || bad "_h1 took a fenced comment (gemini-rd2-r1)"

# --- the emitted diff shows no line from a region declared "not shown" (fable-rd2-r3) ---
P="$(mkbase prevN.md '## Alpha' '' 'a one' '' '## Beta' '' 'b one')"
C="$(mkbase currN.md '## Alpha' '' 'a TWO' '' '## Beta' '' 'b one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
awk '/^````diff$/,/^````$/' <<<"$out" | grep -q '## Beta' \
  && bad "diff leaks an untouched region heading (fable-rd2-r3)" || ok "diff: no untouched-region context"

# --- removed regions are listed in document order (gemini-rd2-r2, fable-rd2-r9) ---
P="$(mkbase prevO.md '## Zeta' '' 'z' '' '## Alpha' '' 'a' '' '## Mid' '' 'm')"
C="$(mkbase currO.md '## Mid' '' 'm CHANGED')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Removed this round, no longer present: Zeta, Alpha\.$' <<<"$out" \
  && ok "removed: listed in document order" || bad "removed order not deterministic ($(grep 'Removed this' <<<"$out"))"

# ============================== Phase B: pr-copy ==============================
# A throwaway git repo so the guards can be exercised without a network or a real PR.
GR="${WORK}/repo"; mkdir -p "$GR"
( cd "$GR" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'line one\nline two\n' > f.txt && git add f.txt && git commit -qm base ) >/dev/null 2>&1
BASE="$(cd "$GR" && git rev-parse HEAD)"
# The r1 commit adds bulk so the whole-PR payload (BASE..H2) clears the round-2 delta with margin,
# or the never-worse guard trips this happy path on an unrelated fixture edit (fable-rd2-r5).
# Placement matters: the filler must land in the BASE..H1 leg AND >10 lines from the r2 hunk at the
# end of the file, otherwise -W -U10 pulls it into the scoped payload too and no margin appears.
( cd "$GR" && { printf 'line one\nline CHANGED\n'; seq 1 40 | sed 's/^/pad_/'; } > f.txt \
  && git commit -qam r1 ) >/dev/null 2>&1
H1="$(cd "$GR" && git rev-parse HEAD)"
( cd "$GR" && { printf 'line one\nline CHANGED\n'; seq 1 40 | sed 's/^/pad_/'; \
    printf 'line added\n'; } > f.txt && git commit -qam r2 ) >/dev/null 2>&1
H2="$(cd "$GR" && git rev-parse HEAD)"

# --- happy path: the delta between two heads, plus the touched file's text at the head ---
out="$(bash "$SUT" pr-copy --round 2 --max 5 --since "$H1" --merge-base-prev "$BASE" \
        --head "$H2" --merge-base "$BASE" "$GR" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "pr-copy: exits 0 on a scopeable delta" || bad "pr-copy rc=$rc"
grep -q '^## Changes since round 1$' <<<"$out" && ok "pr-copy: diff heading" || bad "pr-copy no diff heading"
grep -q 'line added' <<<"$out" && ok "pr-copy: emits the delta" || bad "pr-copy delta missing"
grep -q '^<!-- multi-review: awaiting-reviewer · round 2/5 -->$' <<<"$out" \
  && ok "pr-copy: writes a copy marker" || bad "pr-copy marker missing"
[[ "$(grep -v '^$' <<<"$out" | tail -1)" == "## Review" ]] \
  && ok "pr-copy: ends with an empty ## Review" || bad "pr-copy ## Review not last"

# --- exit 3: unresolvable --since ---
bash "$SUT" pr-copy --round 2 --max 5 --since deadbeefdeadbeef --merge-base-prev "$BASE" \
  --head "$H2" --merge-base "$BASE" "$GR" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "pr-copy: exit 3 on unresolvable --since" || bad "unresolvable --since not exit 3"

# --- exit 3: unresolvable --head (the fork case, once the fetch has failed) ---
bash "$SUT" pr-copy --round 2 --max 5 --since "$H1" --merge-base-prev "$BASE" \
  --head deadbeefdeadbeef --merge-base "$BASE" "$GR" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "pr-copy: exit 3 on unresolvable --head" || bad "unresolvable --head not exit 3"

# --- exit 3: the merge-base MOVED between rounds (a forward merge or a rebase) ---
bash "$SUT" pr-copy --round 2 --max 5 --since "$H1" --merge-base-prev "$BASE" \
  --head "$H2" --merge-base "$H1" "$GR" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "pr-copy: exit 3 when the merge-base moved" || bad "moved merge-base not exit 3"

# --- exit 3: an UNKNOWN merge-base ("-") is a cannot-scope, not a silent pass ---
bash "$SUT" pr-copy --round 2 --max 5 --since "$H1" --merge-base-prev - \
  --head "$H2" --merge-base - "$GR" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "pr-copy: exit 3 on an unknown merge-base" || bad "unknown merge-base not exit 3"

# --- exit 3: --since is NOT an ancestor of --head (amend / force-push on the same base) ---
( cd "$GR" && git checkout -q -b side "$H1" && printf 'line one\nline AMENDED\n' > f.txt \
  && git commit -qam amended ) >/dev/null 2>&1
AMEND="$(cd "$GR" && git rev-parse HEAD)"
( cd "$GR" && git checkout -q - ) >/dev/null 2>&1
# H2 is not an ancestor of AMEND, and the merge-base did not move — only ancestry catches this
bash "$SUT" pr-copy --round 3 --max 5 --since "$H2" --merge-base-prev "$BASE" \
  --head "$AMEND" --merge-base "$BASE" "$GR" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "pr-copy: exit 3 on a rewritten history (non-ancestor)" \
  || bad "non-ancestor --since not exit 3 — the amend/force-push case"

# --- empty delta (head unchanged since the previous round) is a converge signal, exit 3 ---
bash "$SUT" pr-copy --round 2 --max 5 --since "$H2" --merge-base-prev "$BASE" \
  --head "$H2" --merge-base "$BASE" "$GR" >/dev/null 2>&1
[[ $? -eq 3 ]] && ok "pr-copy: exit 3 on an empty delta" || bad "empty delta not exit 3"

# --- Q2: the copy carries the DELTA WITH FUNCTION CONTEXT, and no whole-file text ---
# Fixture geometry is load-bearing and two obvious versions are vacuous:
#   * git writes the enclosing funcname into the @@ header with OR without -W, so asserting on
#     "target_fn" passes under a bare -U10 and pins nothing. Assert on a CONTEXT line at the top
#     of the function body (inner_pad_1) instead — only -W reaches it.
#   * -W -U10 still applies 10 lines of context PAST the function start, so the over-reach probe
#     needs the preceding function to be more than 10 lines away (hence head_pad_1..20).
( cd "$GR" && { echo 'header_untouched() {'; \
    for i in $(seq 1 20); do echo "  head_pad_$i"; done; \
    echo '}'; echo; \
    echo 'target_fn() {'; \
    for i in $(seq 1 20); do echo "  inner_pad_$i"; done; \
    echo '  echo before'; \
    echo '}'; echo; \
    for i in $(seq 1 60); do echo "trailing_filler_$i"; done; } > big.sh \
  && git add big.sh && git commit -qm addbig ) >/dev/null 2>&1
BIG1="$(cd "$GR" && git rev-parse HEAD)"
( cd "$GR" && sed 's/echo before/echo AFTER/' big.sh > big.tmp && mv big.tmp big.sh \
  && git commit -qam changebig ) >/dev/null 2>&1
BIG2="$(cd "$GR" && git rev-parse HEAD)"

# Guard the fixture itself: if -U10 already reaches inner_pad_1, the -W assertion below is vacuous.
u10=$(cd "$GR" && git diff -U10 "$BIG1" "$BIG2" | grep -c 'inner_pad_1$')
[[ "$u10" -eq 0 ]] && ok "fixture: a bare -U10 cannot reach inner_pad_1 (so the -W test bites)" \
  || bad "fixture does not distinguish -W from -U10 (inner_pad_1 already in -U10)"

out="$(bash "$SUT" pr-copy --round 2 --max 5 --since "$BIG1" --merge-base-prev "$BASE" \
        --head "$BIG2" --merge-base "$BASE" "$GR" 2>/dev/null)"
grep -q 'echo AFTER' <<<"$out" && ok "pr-copy: emits the changed line" || bad "changed line missing"
grep -q 'trailing_filler_60' <<<"$out" && bad "pr-copy emitted untouched file text (Q2 regression)" \
  || ok "pr-copy: no whole-file text — the untouched tail is absent"
grep -q '^### big\.sh$' <<<"$out" && bad "pr-copy still emits per-file text headings" \
  || ok "pr-copy: no ### <path> file-text heading"
grep -q 'inner_pad_1$' <<<"$out" && ok "pr-copy: -W reaches the top of the enclosing function" \
  || bad "no function context — -W not applied (a bare -U10 cannot reach inner_pad_1)"
grep -q 'head_pad_1$' <<<"$out" && bad "-W over-reached into the preceding function" \
  || ok "pr-copy: function context stops at the enclosing function"

# --- diff.external must NOT reach the copy: git diff is porcelain and honours it, so a
# difftastic/delta user would otherwise be shipped driver output as "what the author pushed",
# exit 0, with the size guard comparing that output (fable-rd1-r4, reproduced).
( cd "$GR" && git config diff.external 'echo EXTERNAL-DIFF-RAN' ) >/dev/null 2>&1
out="$(bash "$SUT" pr-copy --round 2 --max 5 --since "$H1" --merge-base-prev "$BASE" \
        --head "$H2" --merge-base "$BASE" "$GR" 2>/dev/null)"
grep -q 'EXTERNAL-DIFF-RAN' <<<"$out" && bad "pr-copy shipped external diff driver output" \
  || ok "pr-copy: --no-ext-diff — an external diff driver cannot reach the copy"
grep -q 'line added' <<<"$out" && ok "pr-copy: still a real unified diff under diff.external" \
  || bad "pr-copy produced no usable diff with diff.external set"
( cd "$GR" && git config --unset diff.external ) >/dev/null 2>&1

# ===================== A2: the never-worse guard (both subcommands) =====================
# A revert-shaped round 2: the author backs out most of what round 1 did, so the whole-PR diff
# shrinks toward empty while the round-2 delta is the entire revert. Realistic ("back this out")
# and it genuinely loses, which a rigged fixture would not.
( cd "$GR" && seq 1 100 | sed 's/^/orig_line_/' > w.txt && git add w.txt \
  && git commit -qm wbase ) >/dev/null 2>&1
WBASE="$(cd "$GR" && git rev-parse HEAD)"
( cd "$GR" && awk 'NR>=30 && NR<=69 {print "rd1_changed_" NR; next} {print}' w.txt > t \
  && mv t w.txt && git commit -qam wrd1 ) >/dev/null 2>&1
WIDE1="$(cd "$GR" && git rev-parse HEAD)"
( cd "$GR" && awk 'NR>=30 && NR<=67 {print "orig_line_" NR; next} {print}' w.txt > t \
  && mv t w.txt && git commit -qam wrd2 ) >/dev/null 2>&1
WIDE2="$(cd "$GR" && git rev-parse HEAD)"

# Prove the fixture LOSES before asserting on the guard, or the guard test passes vacuously.
sp=$(cd "$GR" && git diff -W -U10 "$WIDE1" "$WIDE2" | wc -c | tr -d ' ')
fp=$(cd "$GR" && git diff "$WBASE" "$WIDE2" | wc -c | tr -d ' ')
(( sp >= fp )) && ok "guard fixture: the scoped payload really is not smaller ($sp vs $fp)" \
  || bad "guard fixture does not lose ($sp vs $fp) — the guard test would pass vacuously"

err="$(bash "$SUT" pr-copy --round 2 --max 5 --since "$WIDE1" --merge-base-prev "$WBASE" \
        --head "$WIDE2" --merge-base "$WBASE" "$GR" 2>&1 >/dev/null)"; rc=$?
[[ $rc -eq 3 ]] && ok "pr-copy: exit 3 when the scoped copy is not smaller" \
  || bad "no never-worse guard on pr-copy (rc=$rc)"
grep -qE '[0-9]+ B.*[0-9]+ B' <<<"$err" && ok "pr-copy: the notice names both byte counts" \
  || bad "guard notice does not name both sizes: $err"

# Nothing half-composed reaches stdout on the exit-3 path (the guard runs BEFORE composition).
sout="$(bash "$SUT" pr-copy --round 2 --max 5 --since "$WIDE1" --merge-base-prev "$WBASE" \
        --head "$WIDE2" --merge-base "$WBASE" "$GR" 2>/dev/null)"
[[ -z "$sout" ]] && ok "pr-copy: exit-3 path emits nothing on stdout" \
  || bad "half-composed copy leaked to stdout"

# The happy-path fixture must clear the guard with MARGIN, or an unrelated future edit to it
# trips the size guard and the failure message talks about copy size (fable-rd2-r5).
hsp=$(cd "$GR" && git diff -W -U10 "$H1" "$H2" | wc -c | tr -d ' ')
hfp=$(cd "$GR" && git diff "$BASE" "$H2" | wc -c | tr -d ' ')
(( hfp > hsp * 2 )) && ok "happy-path fixture clears the guard with margin ($hsp vs $hfp)" \
  || bad "happy-path fixture margin too thin ($hsp vs $hfp) — an unrelated edit will trip the guard"

# --- local-copy never-worse guard, above a size floor (issues #41, #74) ---
#
# local-copy carries the same guard pr-copy has, but only once the artifact it would replace is at
# least LOCAL_GUARD_FLOOR_B (1 KiB). The floor is what makes the guard landable: every composition
# fixture in this file is a 2-section document with 1 section touched — §4.6's "primary rewrote
# everything" row, where scoping genuinely cannot win — so an unfloored guard fires on all ~30 of
# them. Below the floor the absolute waste is bounded by ~1 KiB, which is noise beside the ~15 KB
# contract every dispatch already carries, and diff-format overhead dominates any real signal.
#
# Three assertions, because the guard has three distinct behaviours and only one of them is the bug:
# it must FIRE above the floor, stay SILENT below it, and not over-fire on a genuine win.

# (1) fires: a >=1 KiB artifact whose scoped copy is not smaller. This is issue #74's shape —
# measured live at 102% and 106% on real documents, exit 0, nothing warned.
P9="$(mkbase prevw.md '## A' '' 'x')"
C9="$(mkbase currw.md '## A' '' 'x' '' '## B' '' "$(seq 1 400 | tr '\n' ' ')")"
lc_full=$(wc -c < "$C9" | tr -d ' ')
(( lc_full >= 1024 )) && ok "local-copy: losing fixture is above the floor (${lc_full} B)" \
  || bad "losing fixture is only ${lc_full} B — below the floor, so it cannot exercise the guard"
lc_err="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P9" --curr "$C9" 2>&1 >/dev/null)"
lc_rc=$?   # capture BEFORE the test, or the failure branch reports the [[ ]]'s own status (always 1)
[[ $lc_rc -eq 3 ]] && ok "local-copy: exit 3 when the scoped copy is not smaller" \
  || bad "local-copy emitted a copy no smaller than the artifact it replaces (rc=$lc_rc) — issue #74"
grep -qE '[0-9]+ B.*[0-9]+ B' <<<"$lc_err" && ok "local-copy: the notice names both byte counts" \
  || bad "local-copy guard notice does not name both sizes: $lc_err"
# Nothing half-composed reaches stdout: the copy is composed to a temp file and only cat'd once the
# guard clears, so a caller redirecting stdout never receives a copy the guard rejected.
lc_sout="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P9" --curr "$C9" 2>/dev/null)"
[[ -z "$lc_sout" ]] && ok "local-copy: exit-3 path emits nothing on stdout" \
  || bad "half-composed local copy leaked to stdout"

# (2) silent below the floor: the same losing shape, small. This is the regime every composition
# assertion above runs in, and it must stay exit 0 or those ~30 assertions stop being reachable.
P8="$(mkbase prevf.md '## A' '' 'x')"
C8="$(mkbase currf.md '## A' '' 'x' '' '## B' '' 'y')"
sm_full=$(wc -c < "$C8" | tr -d ' ')
bash "$SUT" local-copy --round 2 --max 5 --prev "$P8" --curr "$C8" >/dev/null 2>&1
sm_rc=$?
(( sm_full < 1024 )) && [[ $sm_rc -eq 0 ]] \
  && ok "local-copy: below the floor (${sm_full} B) the guard stays out of the way" \
  || bad "floor exemption broke (size=${sm_full} B, rc=$sm_rc) — the composition fixtures above are now unreachable"

# (3) does not over-fire: a >=1 KiB artifact with a genuinely small edit must still scope.
BULK="$(seq 1 400 | tr '\n' ' ')"
P7="$(mkbase prevg.md '## A' '' 'alpha one' '' '## B' '' "$BULK")"
C7="$(mkbase currg.md '## A' '' 'alpha CHANGED' '' '## B' '' "$BULK")"
win_out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P7" --curr "$C7" 2>/dev/null)"
win_rc=$?
win_full=$(wc -c < "$C7" | tr -d ' '); win_scoped=${#win_out}
{ [[ $win_rc -eq 0 ]] && (( win_scoped < win_full )); } \
  && ok "local-copy: a real win still scopes (${win_scoped} B vs ${win_full} B)" \
  || bad "guard over-fires on a genuine win (rc=$win_rc, ${win_scoped} B vs ${win_full} B)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
