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
grep -q '^> Unchanged this round: Beta\.$' <<<"$out" && ok "names untouched region" || bad "untouched not named"
# RETIRED (#86): "the untouched region's text is absent" was true only while whole regions were
# emitted. A bounded context window can spill across a heading into a region that did not change,
# so the copy no longer promises absence — and the notice no longer claims it (asserted in Phase C).
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
grep -q 'Unchanged this round:.*NotAHeading' <<<"$out" && bad "phantom region (backticks)" || ok "no phantom (backticks)"

P="$(mkbase prev4.md '## Alpha' '' 'alpha one' '' '~~~' '## TildeHeading' '~~~' '' '## Beta' '' 'b')"
C="$(mkbase curr4.md '## Alpha' '' 'alpha TWO' '' '~~~' '## TildeHeading' '~~~' '' '## Beta' '' 'b')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'Unchanged this round:.*TildeHeading' <<<"$out" && bad "phantom region (tildes)" || ok "no phantom (tildes)"

P="$(mkbase prev5.md 'Status: draft.' '' '## Alpha' '' 'a')"
C="$(mkbase curr5.md 'Status: FINAL.' '' '## Alpha' '' 'a')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'Status: FINAL\.' <<<"$out" && ok "preamble-only change emitted" || bad "preamble change vanished"
grep -q '^> Unchanged this round: Alpha\.$' <<<"$out" && ok "sibling named unchanged" || bad "sibling not named"

P="$(mkbase prev6.md 'Status: draft.' '' '## Alpha' '' 'a one')"
C="$(mkbase curr6.md 'Status: draft.' '' '## Alpha' '' 'a TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Unchanged this round: preamble\.$' <<<"$out" && ok "untouched preamble named" || bad "untouched preamble not named"

P="$(mkbase prev7.md '## Alpha' '' 'a one' '' '## Beta' '' 'b one' '' '## Gamma' '' 'g one')"
C="$(mkbase curr7.md '## Alpha' '' 'a TWO' '' '## Beta' '' 'b one' '' '## Gamma' '' 'g TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'a TWO' <<<"$out" && grep -q 'g TWO' <<<"$out" && ok "both changed regions emitted" || bad "multi-region incomplete"
grep -q '^> Unchanged this round: Beta\.$' <<<"$out" && ok "only untouched named" || bad "unchanged list wrong"

P="$(mkbase prev8.md '## Alpha' '' 'a one' '' '## Doomed' '' 'gone soon')"
C="$(mkbase curr8.md '## Alpha' '' 'a one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Removed this round, no longer present: Doomed\.$' <<<"$out" && ok "removed region named" || bad "removed not named"
grep -q 'Unchanged this round:.*Doomed' <<<"$out" && bad "removed claimed unchanged" || ok "removed not claimed unchanged"

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
# Emitted text is now diff lines, so it carries a one-character context/add marker. What the
# assertion pins is unchanged: the text after that marker is byte-identical, doubled spaces and all.
grep -q '^[ +]keep  double  spaces$' <<<"$out" && ok "region text byte-identical" || bad "region text altered"

# --- an H1 inside a preamble fence survives (gemini-rd1-r1, fable-rd1-r2) ---
P="$(mkbase prevC.md 'Intro prose.' '' '```bash' '# run the thing' 'do_it' '```' '' '## Alpha' '' 'a one')"
C="$(mkbase currC.md 'Intro prose.' '' '```bash' '# run the thing' 'do_it' '```' '' '## Alpha' '' 'a TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^> Unchanged this round: preamble\.$' <<<"$out" \
  && ok "header strip: bounded (fenced H1 kept in preamble region)" || bad "preamble mangled"
P="$(mkbase prevD.md 'Intro.' '' '```bash' '# keep me' '```' '' '## Alpha' '' 'a')"
C="$(mkbase currD.md 'Intro CHANGED.' '' '```bash' '# keep me' '```' '' '## Alpha' '' 'a')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q '^[ +]# keep me$' <<<"$out" \
  && ok "header strip: fenced H1 emitted verbatim" || bad "fenced H1 stripped (fable-rd1-r2)"

# --- a body with NO "## " section keeps its content H1s (gemini-rd1-r1) ---
P="$(mkbase prevE.md '# Content Heading' '' 'body one')"
C="$(mkbase currE.md '# Content Heading' '' 'body TWO')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
[[ "$(grep -c '^[ +]# Content Heading$' <<<"$out")" == "1" ]] \
  && ok "header strip: content H1 kept when body has no H2" || bad "content H1 dropped (gemini-rd1-r1)"

# --- duplicate heading names are distinct regions (codex-rd1-r1, fable-rd1-r3) ---
P="$(mkbase prevF.md '## Details' '' 'first one' '' '## Other' '' 'o' '' '## Details' '' 'second one')"
C="$(mkbase currF.md '## Details' '' 'first CHANGED' '' '## Other' '' 'o' '' '## Details' '' 'second one')"
out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P" --curr "$C" 2>/dev/null)"
grep -q 'first CHANGED' <<<"$out" && ok "dup names: changed duplicate emitted" || bad "changed dup missing"
# RETIRED (#86), same reason as the Beta absence assertion above: bounded context may show an
# untouched duplicate's text. What still matters — that duplicates are DISTINCT regions and only
# the changed one counts as touched — is pinned by the unchanged-list and removed-list assertions.

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
grep -q 'Unchanged this round:.*Indented' <<<"$out" \
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
grep -q 'Unchanged this round:.*Review' <<<"$out" \
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

# RETIRED (#86): fable-rd2-r3 asserted that the diff shows no line from a region declared "not
# shown". The copy no longer makes that claim, so there is nothing left to violate.
#
# It was also DEAD on arrival and never could have failed: it scanned between four-backtick fences
# (`^````diff$`), but `_fence_for` emits three backticks for a fixture containing none, so the awk
# range matched nothing and the grep ran against an empty string. Verified against the unmodified
# script before this change, not inferred. What it meant to protect — that context does not run
# away from the hunk — is now pinned positively, and non-vacuously, by the bounded-context
# assertions in Phase C (local-copy `pad50`) and Phase B (pr-copy `fn_pad_400`).

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
# RETIRED (#86): -W extended every hunk to its enclosing function, which cost the size of the
# FUNCTION rather than the size of the change — 6.32x the whole-PR payload on a real doc-heavy
# round and 1.50x on a bash-heavy one, so the never-worse guard refused both. inner_pad_1 sits 20
# lines above the edit, so its ABSENCE is what proves the context window is bounded.
grep -q 'inner_pad_1$' <<<"$out" && bad "whole-function context is back — the hunk reached inner_pad_1" \
  || ok "pr-copy: context is bounded, not extended to the enclosing function"
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

# --- #86: a small edit inside a LARGE function must still scope ---------------------------
# The shape that made every round after the first pay full price. The PR's whole payload is modest,
# but the round delta lands inside a long function; extending the hunk to that function cost more
# than the entire PR diff it was meant to replace, so the never-worse guard refused the round and
# the fan-out fell back to full copies. Reproduced on PR #84 round 2 (112,914 B scoped against a
# 17,860 B whole-PR payload) and on #113 round 2 (227,096 B against 151,697 B).
( cd "$GR" && { echo 'huge_fn() {'; seq 1 800 | sed 's/^/  fn_pad_/'; echo '}'; } > huge.sh   && seq 1 200 | sed 's/^/bulk_/' > bulk.txt && git add huge.sh bulk.txt   && git commit -qm hugebase ) >/dev/null 2>&1
HB0="$(cd "$GR" && git rev-parse HEAD)"
# Round 1 pushed a wide change, so the whole-PR payload is genuinely large.
( cd "$GR" && sed 's/^  fn_pad_5$/  fn_pad_5_R1/' huge.sh > t && mv t huge.sh   && seq 1 200 | sed 's/^/bulk_R1_/' > bulk.txt && git commit -qam hugerd1 ) >/dev/null 2>&1
HB1="$(cd "$GR" && git rev-parse HEAD)"
# Round 2 pushed one line, deep inside the function.
( cd "$GR" && sed 's/^  fn_pad_700$/  fn_pad_700_R2/' huge.sh > t && mv t huge.sh   && git commit -qam hugerd2 ) >/dev/null 2>&1
HB2="$(cd "$GR" && git rev-parse HEAD)"

# Prove the fixture actually exhibits the bug before asserting the fix, or the assertion below
# cannot fail: whole-function context must LOSE here, and a bounded window must WIN.
hb_full=$(cd "$GR" && git diff --no-ext-diff --no-textconv "$HB0" "$HB2" | wc -c | tr -d ' ')
hb_w=$(cd "$GR" && git diff --no-ext-diff --no-textconv -W -U10 "$HB1" "$HB2" | wc -c | tr -d ' ')
(( hb_w >= hb_full ))   && ok "fixture: whole-function context really does lose here (${hb_w} B vs ${hb_full} B)"   || bad "fixture does not reproduce #86 (${hb_w} B vs ${hb_full} B) — the assertion below is vacuous"

hb_out="$(bash "$SUT" pr-copy --round 2 --max 5 --since "$HB1" --merge-base-prev "$HB0" \
           --head "$HB2" --merge-base "$HB0" "$GR" 2>/dev/null)"; hb_rc=$?
{ [[ $hb_rc -eq 0 ]] && (( ${#hb_out} < hb_full )); } \
  && ok "pr-copy: a small edit inside a large function still scopes (${#hb_out} B vs ${hb_full} B)" \
  || bad "pr-copy cannot scope an edit inside a large function (rc=$hb_rc, ${#hb_out} B vs ${hb_full} B) — issue #86"
grep -q '^+  fn_pad_700_R2$' <<<"$hb_out" && ok "pr-copy: the pushed line is in the copy" \
  || bad "the pushed line is missing from the scoped copy"
{ [[ -n "$hb_out" ]] && ! grep -q 'fn_pad_400$' <<<"$hb_out"; } \
  && ok "pr-copy: context stops well short of the function's bounds" \
  || bad "context reached 300 lines from the edit (or the copy is empty)"

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
sp=$(cd "$GR" && git diff -U10 "$WIDE1" "$WIDE2" | wc -c | tr -d ' ')
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

# The guard's FULL side must be the artifact the exit-3 fallback actually emits, not `--curr`
# itself (codex-rd2-r1). `--curr` is a baseline and carries a DOC header
# (`awaiting-secondaries`, plus the `reviewers:` suffix); the fallback re-seeds and rewrites that
# to a COPY header (`awaiting-reviewer`, bare mode hint), which is 23 B shorter. Measuring the
# longer one makes the guard permissive by exactly that margin: a scoped copy up to 23 B LARGER
# than the real fallback still passes, which is the case the guard exists to reject.
fb="${WORK}/fallback.md"
awk -v m="<!-- multi-review: awaiting-reviewer · round 2/5 -->" '
  /^<!-- multi-review: / { print m; next }
  /^<!-- multi-review-mode: star/ { print "<!-- multi-review-mode: star -->"; next }
  { print }' "$C9" > "$fb"
fb_b=$(wc -c < "$fb" | tr -d ' '); curr_b=$(wc -c < "$C9" | tr -d ' ')
(( fb_b < curr_b )) \
  && ok "guard basis: the fallback (${fb_b} B) really is smaller than --curr (${curr_b} B)" \
  || bad "fixture cannot distinguish the two bases (${fb_b} vs ${curr_b}) — the assertion below is vacuous"
reported="$(sed -E 's/.*\(([0-9]+) B vs ([0-9]+) B\).*/\2/' <<<"$lc_err")"
[[ "$reported" == "$fb_b" ]] \
  && ok "guard measures against the fallback copy (${reported} B), not --curr" \
  || bad "guard measured ${reported} B — that is --curr (${curr_b} B), not the fallback the round would actually use (${fb_b} B)"

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
# The bulk sits more than 20 lines from the edit, so the context window cannot reach it. Under
# whole-region emission the distance was irrelevant (the bulk was simply in an untouched region);
# under a bounded window it is the whole point, so the fixture states it explicitly.
BULK="$(seq 1 400 | tr '\n' ' ')"
FILL86="$(seq 1 25 | sed 's/^/fill/')"
# shellcheck disable=SC2086  # deliberate word splitting: 25 bare filler lines
P7="$(mkbase prevg.md '## A' '' 'alpha one' $FILL86 '' '## B' '' "$BULK")"
# shellcheck disable=SC2086
C7="$(mkbase currg.md '## A' '' 'alpha CHANGED' $FILL86 '' '## B' '' "$BULK")"
win_out="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P7" --curr "$C7" 2>/dev/null)"
win_rc=$?
win_full=$(wc -c < "$C7" | tr -d ' '); win_scoped=${#win_out}
{ [[ $win_rc -eq 0 ]] && (( win_scoped < win_full )); } \
  && ok "local-copy: a real win still scopes (${win_scoped} B vs ${win_full} B)" \
  || bad "guard over-fires on a genuine win (rc=$win_rc, ${win_scoped} B vs ${win_full} B)"

# ====================== Phase C: bounded context (issue #86) ======================
# The scoped copy carries changed hunks plus a bounded context window — NOT the whole enclosing
# unit. Emitting whole units made the copy cost the size of what it TOUCHED rather than the size of
# what CHANGED, which is the dependency this feature exists to remove: measured on four real round
# transitions of a retained review, every one came out LARGER than the artifact it replaced
# (1.03x-1.26x), and the never-worse guard refused all four. Region granularity is not the
# mechanism — at `###` the touched regions still covered 60-91% of the document.

BULK86=$(seq 1 400 | sed 's/^/pad/')
# shellcheck disable=SC2086  # deliberate word splitting: 400 bare words, one per line
P86="$(mkbase prev86.md '## Big' '' $BULK86 '' '## Small' '' 'small one')"
# shellcheck disable=SC2086
# shellcheck disable=SC2046  # deliberate word splitting: same 400 bare words, one line changed
C86="$(mkbase curr86.md '## Big' '' $(sed 's/^pad200$/pad200CHANGED/' <<<"$BULK86") '' '## Small' '' 'small one')"

art86=$(wc -c < "$C86" | tr -d ' ')
(( art86 >= 1024 )) && ok "fixture: the #86 doc is above the guard floor (${art86} B)" \
  || bad "#86 fixture is only ${art86} B — below the floor, so it cannot exercise the economics"

out86="$(bash "$SUT" local-copy --round 2 --max 5 --prev "$P86" --curr "$C86" 2>/dev/null)"
rc86=$?
scoped86=${#out86}
{ [[ $rc86 -eq 0 ]] && (( scoped86 < art86 )); } \
  && ok "local-copy: a small edit inside a large region still scopes (${scoped86} B vs ${art86} B)" \
  || bad "local-copy cannot scope a large touched region (rc=$rc86, ${scoped86} B vs ${art86} B) — issue #86"

grep -q '^+pad200CHANGED$' <<<"$out86" && ok "local-copy: the changed line is in the copy" \
  || bad "changed line missing from the scoped copy"
grep -q '^ pad185$' <<<"$out86" && ok "local-copy: context reaches 15 lines from the change" \
  || bad "no surrounding context — a bare hunk is not reviewable"
# Absence assertions are gated on a NON-EMPTY copy: exit 3 emits nothing, and an absence checked
# against an empty string passes without being able to fail.
{ [[ -n "$out86" ]] && ! grep -q '^ pad50$' <<<"$out86"; } \
  && ok "local-copy: context is bounded, not the whole enclosing region" \
  || bad "context is unbounded (or the copy is empty) — it reached 150 lines from the change"

# The notice must not promise what a bounded window cannot deliver. Whole-region emission made
# "not shown" true by construction; a context window can spill across a heading into a region that
# did not change, so the copy would claim a region is absent while showing its text. The claim
# narrows to what stays true: the region did not change this round.
grep -q '^> Unchanged this round: Small\.$' <<<"$out86" \
  && ok "local-copy: names the unchanged region without claiming it is absent" \
  || bad "unchanged notice missing or still claims 'not shown' (a bounded window cannot promise that)"
{ [[ -n "$out86" ]] && ! grep -q 'not shown' <<<"$out86"; } \
  && ok "local-copy: no 'not shown' claim anywhere in the copy" \
  || bad "copy still claims unchanged regions are 'not shown' (or the copy is empty)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
