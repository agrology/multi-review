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

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
