#!/usr/bin/env bash
# multi-review-star.test.sh — star (N-party) grammar, merge, convergence, gate summary.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-star.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkdoc <name> <header-extra-lines...> -> path with H1 + extras + a ## Review section
mkdoc() { local p="${WORK}/$1"; shift; { echo "# Doc"; printf '%s\n' "$@"; echo; echo "## Review"; echo; } > "$p"; echo "$p"; }

# mkstar <name> <review-line...> : a star doc; each arg is emitted verbatim into ## Review.
# Callers pass finished "> [finding:<provider>-rd1-<id>|<sev>] ..." + "> — via ..." + "> — risk: ..."
# + "> [agree:<same-ns-id>]" + "> — via <primary>" blocks. The ns-id prefix (<provider>) is what
# gate-summary reads to learn which secondaries were admitted — no manifest required.
mkstar() { local p="${WORK}/$1"; shift; { echo "# Doc"; echo "<!-- multi-review-mode: star -->"; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; echo "$p"; }

# --- mode ---
# star hint (bare) -> star
D="$(mkdoc star1.md '<!-- multi-review-mode: star -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "star" ]] && ok "mode: bare star hint -> star" || bad "mode star1 (got '$out')"

# star hint with reviewers list -> star
D="$(mkdoc star2.md '<!-- multi-review-mode: star · reviewers: codex gemini -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "star" ]] && ok "mode: star+reviewers -> star" || bad "mode star2 (got '$out')"

# no hint -> defer (empty stdout, non-zero) so peer.sh mode is unaffected
D="$(mkdoc none.md)"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -ne 0 ]] && ok "mode: no hint defers" || bad "mode none leaked (out='$out' rc=$rc)"

# peer-review hint -> defer (not star)
D="$(mkdoc peer.md '<!-- multi-review-mode: peer-review -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ -z "$out" ]] && ok "mode: peer hint defers" || bad "mode peer leaked (got '$out')"

# --- resolve-set ---
# flag beats env; dedup; order preserved
out="$(MULTI_REVIEW_REVIEWERS="fable" bash "$SUT" resolve-set --reviewers codex,gemini,codex 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini " ]] && ok "resolve-set: flag>env, dedup, order" || bad "resolve-set flag (got '$out')"

# env used when no flag
out="$(MULTI_REVIEW_REVIEWERS="gemini fable" bash "$SUT" resolve-set 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "gemini fable " ]] && ok "resolve-set: env set" || bad "resolve-set env (got '$out')"

# unknown id -> exit 2
MULTI_REVIEW_REVIEWERS="codex bogus" bash "$SUT" resolve-set >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "resolve-set: unknown id -> exit 2" || bad "resolve-set unknown exit"

# empty set -> exit 3, no output (not star)
out="$(bash "$SUT" resolve-set 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 3 ]] && ok "resolve-set: empty -> exit 3 not-star" || bad "resolve-set empty (out='$out' rc=$rc)"

# rows are full registry rows
out="$(bash "$SUT" resolve-set --reviewers gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell|"*"|no" ]] && ok "resolve-set: full row" || bad "resolve-set row (got '$out')"

# --reviewers with no value -> usage exit 2, not the empty-set exit 3
bash "$SUT" resolve-set --reviewers >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "resolve-set: --reviewers with no value -> usage exit 2" || bad "resolve-set no-value exit (got $rc)"

# --- reviewer-helper injection seam (Task 1) ---
# A stub helper lets availability tests below be deterministic (no real CLIs on PATH).
STUB="${WORK}/stub-reviewer.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
sub="${1:-}"; shift || true
id=""; while [[ $# -gt 0 ]]; do [[ "$1" == "--reviewer" ]] && { id="${2:-}"; shift 2; continue; }; shift; done
case "$sub" in
  resolve) case "$id" in codex|fable|gemini) echo "${id}|vendor|kind|model|no"; exit 0;; *) exit 1;; esac ;;
  check)   case "$id" in codex|fable) exit 0;; *) exit 1;; esac ;;   # gemini resolves but is unavailable
  *) exit 2 ;;
esac
STUBEOF
chmod +x "$STUB"
# Seam honored: the stub resolves codex to vendor "vendor"; the REAL registry resolves codex to
# "openai". Reading back "vendor" proves resolve-set used the injected stub, not the real helper.
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --reviewers codex 2>/dev/null | cut -d'|' -f2)"
[[ "$out" == "vendor" ]] && ok "seam: MULTI_REVIEW_REVIEWER_SH overrides helper path" || bad "seam override (got '$out')"

# --- resolve-set --pref-file (Task 2) ---
# These "flag+env empty" cases require env genuinely unset; a dev who exports MULTI_REVIEW_REVIEWERS
# would otherwise see env shadow the pref and the tests fail spuriously (fable-rd2-r1).
unset MULTI_REVIEW_REVIEWERS
# pref used only when flag AND env are both empty; result = pref extras + fable (floored)
PREF="${WORK}/reviewers.pref"; printf 'codex\n' > "$PREF"
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex fable " ]] && ok "pref: used when flag+env empty" || bad "pref used (got '$out')"

# flag beats pref
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --reviewers gemini --pref-file "$PREF" 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "gemini fable " ]] && ok "pref: flag beats pref" || bad "pref flag-beats (got '$out')"

# env beats pref (non-empty)
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" MULTI_REVIEW_REVIEWERS="gemini" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "gemini fable " ]] && ok "pref: env beats pref" || bad "pref env-beats (got '$out')"

# empty-string env is treated as unset -> falls through to pref
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" MULTI_REVIEW_REVIEWERS="" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex fable " ]] && ok "pref: empty env is unset, falls to pref" || bad "pref empty-env (got '$out')"

# a CSV env value splits like the flag (fable-rd1-r1) — not one unknown "codex,gemini" token.
# env source is not availability-filtered (that is pref-only), so both ids survive + fable floored.
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" MULTI_REVIEW_REVIEWERS="codex,gemini" bash "$SUT" resolve-set --fable-floor 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini fable " ]] && ok "pref: csv env value splits (not one token)" || bad "csv env split (got '$out')"

# read-path normalization: whitespace, duplicates, a literal 'fable', blank lines
printf '  codex , codex \n\nfable,gemini\n' > "$PREF"
out="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
# gemini resolves but STUB check fails it -> dropped; codex kept; fable floored; literal fable stripped; dup collapsed
[[ "$out" == "codex fable " ]] && ok "pref: normalize (trim/dedup/strip-fable) + drop unavailable" || bad "pref normalize (got '$out')"

# availability drop is non-destructive: pref file unchanged after the run
grep -q 'gemini' "$PREF" && ok "pref: unavailable drop does not rewrite pref" || bad "pref rewritten on drop"

# registry-unknown id in pref degrades (dropped, not exit 2); bad id alone -> fable-only.
# Capture resolve-set's OWN exit (not the trailing pipe's) so the exit-0 assertion is real (fable-rd1-r3).
printf 'bogus\n' > "$PREF"
rows="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>/dev/null)"; rc=$?
out="$(printf '%s' "$rows" | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "fable " && $rc -eq 0 ]] && ok "pref: unknown id degrades to fable-only (exit 0)" || bad "pref unknown-degrade (out='$out' rc=$rc)"

# contrast: unknown id in an EXPLICIT flag still hard-fails exit 2
MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --reviewers bogus --pref-file "$PREF" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "pref: unknown in flag still exit 2" || bad "flag unknown should exit 2"

# absent pref file (the common fresh-repo bare run): -s false -> fable-only, exit 0, no error (fable-rd2-r4)
ABS="${WORK}/does-not-exist.pref"; rm -f "$ABS"
rows="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$ABS" 2>/dev/null)"; rc=$?
out="$(printf '%s' "$rows" | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "fable " && $rc -eq 0 ]] && ok "pref: absent pref file -> fable-only (exit 0)" || bad "pref absent-file (out='$out' rc=$rc)"

# both drop-notice texts are pinned, so Task 5's arm-time relay keys on the shared "pref reviewer
# … dropping" token; a reword can't break the relay unnoticed (fable-rd2-r3, fable-rd3-r1).
# (a) unavailable id (registered but STUB check fails):
printf 'gemini\n' > "$PREF"
err="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q "pref reviewer 'gemini'" && printf '%s' "$err" | grep -qi 'unavailable' && printf '%s' "$err" | grep -qi 'dropping' \
  && ok "pref: unavailable-drop notice pinned (id + 'unavailable' + 'dropping')" || bad "pref unavail-notice text (got '$err')"
# (b) registry-unknown id (STUB resolve fails):
printf 'bogus\n' > "$PREF"
err="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q "pref reviewer 'bogus'" && printf '%s' "$err" | grep -qi 'unknown' && printf '%s' "$err" | grep -qi 'dropping' \
  && ok "pref: unknown-drop notice pinned (id + 'unknown' + 'dropping')" || bad "pref unknown-notice text (got '$err')"

# unknown flag is rejected (parity with remember-set), not silently swallowed (fable-rd2-r2)
MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --bogus-flag >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "resolve-set: unknown flag -> exit 2" || bad "resolve-set unknown flag not rejected"

# --- resolve-set --fable-floor (Phase 2, dormant) ---
# named set gains fable, appended last, deduped
out="$(bash "$SUT" resolve-set --fable-floor --reviewers codex,gemini 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini fable " ]] && ok "fable-floor: appends fable last" || bad "fable-floor named (got '$out')"

# explicit fable is not duplicated
out="$(bash "$SUT" resolve-set --fable-floor --reviewers codex,fable 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex fable " ]] && ok "fable-floor: no dup when named" || bad "fable-floor dup (got '$out')"

# empty named set -> {fable}, and NOT exit 3
out="$(bash "$SUT" resolve-set --fable-floor 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"; rc=$?
[[ "$out" == "fable " && $rc -eq 0 ]] && ok "fable-floor: empty -> {fable}, exit 0" || bad "fable-floor empty (got '$out' rc=$rc)"

# WITHOUT the flag, empty still exits 3 (legacy detection unbroken)
bash "$SUT" resolve-set >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "resolve-set: no flag, empty still exit 3" || bad "legacy exit3 broke"

# WITHOUT the flag, NAMED resolution byte-unchanged (r3: the shared fn was edited — prove no perturbation)
out="$(bash "$SUT" resolve-set --reviewers codex,gemini,codex 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini " ]] && ok "resolve-set: no-flag named unchanged" || bad "no-flag named regressed (got '$out')"

# --- available ---
out="$(bash "$SUT" available 2>/dev/null)"
# fable has no external prereq, so it must always be dispatchable
echo "$out" | grep -qE '^fable yes$' && ok "available: fable yes" || bad "available fable (got '$out')"
# all three providers listed, in registry order
ids="$(echo "$out" | cut -d' ' -f1 | tr '\n' ' ')"
[[ "$ids" == "codex fable gemini " ]] && ok "available: lists all three in order" || bad "available order (got '$ids')"

# --- _table / open-findings ---
# helper: build a star doc body after ## Review
mkrev() { local p="${WORK}/$1"; shift; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; echo "$p"; }

# open finding (no response) is open
D="$(mkrev open.md '> [finding:codex-rd1-r1|high] missing validation' '> — via gpt-5.5' '> — risk: rce')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "codex-rd1-r1 " ]] && ok "open-findings: unresponded is open" || bad "star open (got '$out')"

# agreed + disputed are NOT open (primary responds; different model from the secondary)
D="$(mkrev settled.md \
  '> [finding:codex-rd1-r1|high] a' '> — via gpt-5.5' '> — risk: r' '>' '> [agree:codex-rd1-r1]' '> — via claude-opus-4-8' \
  '' '> [finding:gemini-rd1-r1|med] b' '> — via gemini' '> — risk: r' '>' '> [dispute:gemini-rd1-r1] no' '> — via claude-opus-4-8')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "" ]] && ok "open-findings: agree/dispute settle" || bad "star settled (got '$out')"

# THREE distinct models is fine (no 2-model cap): 2 secondaries + primary
D="$(mkrev threemodels.md \
  '> [finding:codex-rd1-r1|high] a' '> — via gpt-5.5' '> — risk: r' '>' '> [agree:codex-rd1-r1]' '> — via claude-opus-4-8' \
  '' '> [finding:gemini-rd1-r1|low] b' '> — via gemini' '> — risk: r' '>' '> [agree:gemini-rd1-r1]' '> — via claude-opus-4-8')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && ok "open-findings: 3 models allowed (no cap)" || bad "star 3-model cap leaked in"

# missing via -> hard error
D="$(mkrev nodisc.md '> [finding:codex-rd1-r1|high] a')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing via should hard-error" || ok "open-findings: missing via hard-errors"

# bad severity -> hard error
D="$(mkrev badsev.md '> [finding:codex-rd1-r1|urgent] a' '> — via gemini' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "bad severity should hard-error" || ok "open-findings: bad severity hard-errors"

# finding whose via line is the LAST line (no risk line follows) -> hard error (r6: END must guard awaiting_risk)
D="$(mkrev norisk_eof.md '> [finding:codex-rd1-r1|high] a' '> — via gemini')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing risk at EOF should hard-error" || ok "open-findings: missing risk at EOF hard-errors"

# duplicate finding id -> hard error
D="$(mkrev dupe.md '> [finding:codex-rd1-r1|high] a' '> — via gemini' '> — risk: r' '' '> [finding:codex-rd1-r1|high] b' '> — via gemini' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "dup id should hard-error" || ok "open-findings: duplicate id hard-errors"

# --- merge: namespacing ---
# build a raw secondary copy (finding ids are un-namespaced, as a secondary emits them)
mkcopy() { local p="$1"; shift; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; }

BASE="${WORK}/m1.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo; } > "$BASE"
mkcopy "${BASE}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
mkcopy "${BASE}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
bash "$SUT" merge --round 1 "$BASE" "${BASE}.codex" "${BASE}.gemini" >/dev/null 2>&1

# both r1s land namespaced, no collision
grep -q '^> \[finding:codex-rd1-r1|high\] alpha$'  "$BASE" && ok "merge: codex-rd1-r1 present" || bad "merge codex ns"
grep -q '^> \[finding:gemini-rd1-r1|med\] beta$'   "$BASE" && ok "merge: gemini-rd1-r1 present" || bad "merge gemini ns"
# severity preserved, not dropped or doubled
grep -q '|high|' "$BASE" && bad "merge: severity doubled" || ok "merge: no doubled severity"
# continuation lines carried verbatim
grep -q '^> — risk: ra$' "$BASE" && grep -q '^> — via gpt-5.5$' "$BASE" && ok "merge: block continuation lines preserved" || bad "merge continuation lost"

# round 2 with same raw id -> no cross-round collision
mkcopy "${BASE}.codex" '> [finding:r1|low] gamma' '> — via gpt-5.5' '> — risk: rc'
bash "$SUT" merge --round 2 "$BASE" "${BASE}.codex" >/dev/null 2>&1
grep -q '^> \[finding:codex-rd2-r1|low\] gamma$' "$BASE" && ok "merge: codex-rd2-r1 (no cross-round collision)" || bad "merge round2 ns"
grep -q '^> \[finding:codex-rd1-r1|high\] alpha$' "$BASE" && ok "merge: round1 finding still intact" || bad "merge clobbered round1"

# byte-safety: finding text containing a literal backslash-escape must survive merge verbatim (r11)
BASE3="${WORK}/m3.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$BASE3"
mkcopy "${BASE3}.codex" '> [finding:r1|high] path C:\notreal\test' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$BASE3" "${BASE3}.codex" >/dev/null 2>&1
grep -qF 'C:\notreal\test' "$BASE3" && ok "merge: literal backslash-escape survives verbatim (r11)" || bad "merge mangled backslash-escape text"

# unregistered provider -> hard error, doc left untouched (not silently corrupted)
BASEQ="${WORK}/mbad.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$BASEQ"
mkcopy "${BASEQ}.bogus" '> [finding:r1|high] x' '> — via m' '> — risk: r'
before="$(shasum "$BASEQ" | cut -d' ' -f1)"
bash "$SUT" merge --round 1 "$BASEQ" "${BASEQ}.bogus" >/dev/null 2>&1; rc=$?
after="$(shasum "$BASEQ" | cut -d' ' -f1)"
[[ $rc -ne 0 && "$before" == "$after" ]] && ok "merge: unregistered provider -> nonzero exit, doc untouched" || bad "merge bad-provider (rc=$rc)"

# --- merge: manifest + quarantine ---
BASE2="${WORK}/m2.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$BASE2"
mkcopy "${BASE2}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 --quarantined gemini:identity-fail "$BASE2" "${BASE2}.codex" >/dev/null 2>&1

# out-of-band manifest exists and lists the finding + quarantine
[[ -f "${BASE2}.manifest" ]] && ok "merge: out-of-band manifest written" || bad "merge no manifest file"
grep -q 'codex-rd1-r1=' "${BASE2}.manifest" && ok "merge: manifest binds finding hash" || bad "merge manifest finding"
grep -q 'gemini-rd1=' "${BASE2}.manifest" && ok "merge: manifest binds quarantine hash" || bad "merge manifest quarantine"

# durable quarantine record in the doc
grep -q '^<!-- star-quarantined: gemini · identity-fail · round 1 -->$' "$BASE2" && ok "merge: durable quarantine record" || bad "merge quarantine record"
# in-doc human-readable mirror
grep -q '<!-- star-findings: .*codex-rd1-r1=' "$BASE2" && ok "merge: in-doc manifest mirror" || bad "merge mirror"

# --- check-converged ---
mkconv() {  # -> a merged doc with primary responses + converged marker + manifest
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" >/dev/null 2>&1
  # primary responds + converge
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$base"
  # flip marker to converged (author-side)
  sed -i.bak 's/awaiting-primary/converged/' "$base" && rm -f "${base}.bak"
  echo "$base"
}

# happy path: converged
D="$(mkconv conv-ok.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: coverage+integrity pass" || bad "check-converged happy"

# missing response -> fail (delete the agree block)
D="$(mkconv conv-noresp.md)"; grep -v 'agree:codex-rd1-r1' "$D" > "$D.x" && mv "$D.x" "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "no-response should fail" || ok "check-converged: missing response fails"

# softened text (id intact) -> fail (r14)
D="$(mkconv conv-soft.md)"; sed -i.bak 's/alpha/ALPHA-softened/' "$D" && rm -f "${D}.bak"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "softened text should fail" || ok "check-converged: softened text fails (r14)"

# --- erasure r9: GRAMMAR-VALID clean erasure, catchable ONLY by guard (b) ---
# A naive erasure (deleting just the [finding:] line) leaves its `[agree:]` response
# orphaned, so _table's "response to unknown finding id" dies BEFORE guard (b) ever runs
# (the early `t="$(_table "$doc")" || exit 1`) — that version of this test had no teeth.
# Build a doc with TWO findings (from two providers, so ids don't collide), respond to
# both, converge, and confirm it passes first — THEN erase one finding's entire block
# (the [finding:] line + its "> — via"/"> — risk:" continuation lines) AND its response
# block (the [agree:] line + its "> — via" line) together, so the remaining doc is still
# grammar-valid (no orphan) with one finding+response — but the manifest still lists both
# ns-ids, so only guard (b)'s present-set == manifest-set check can catch it.
mkconv2() {  # -> merged doc w/ 2 findings (codex, gemini), both agreed, converged marker
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  mkcopy "${base}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" "${base}.gemini" >/dev/null 2>&1
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; echo '> [agree:gemini-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$base"
  sed -i.bak 's/awaiting-primary/converged/' "$base" && rm -f "${base}.bak"
  echo "$base"
}

D="$(mkconv2 conv-del.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: 2-finding doc converges (sanity)" || bad "check-converged: 2-finding sanity should pass"

# clean grammar-valid erasure of gemini-rd1-r1's finding block + its agree response
awk '
  /^> \[finding:gemini-rd1-r1/ { skip=2; next }
  /^> \[agree:gemini-rd1-r1\]/ { skip=1; next }
  skip > 0 { skip--; next }
  { print }
' "$D" > "$D.x" && mv "$D.x" "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "clean erasure should fail (r9/guard-b)" || ok "check-converged: clean erasure fails (r9, guard-b)"

# --- c1: single consistent primary ---
# Coverage (guard a) requires one response per finding, and _table's self-response guard
# already blocks a finding's own raiser from answering it -- but neither pins ALL responses to
# ONE consistent identity. Build a 2-finding doc (like mkconv2) where each finding is answered
# by a DIFFERENT non-raiser model -- this must NOT converge (one primary must reason about
# every finding). mkconv2's happy-path test above is the companion: both findings answered by
# the SAME primary (claude-opus-4-8) there, and it passes.
mkconv_multiprimary() {  # -> merged doc w/ 2 findings, agreed by TWO DIFFERENT responder models
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  mkcopy "${base}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" "${base}.gemini" >/dev/null 2>&1
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; echo '> [agree:gemini-rd1-r1]'; echo '> — via claude-sonnet-5'; } >> "$base"
  sed -i.bak 's/awaiting-primary/converged/' "$base" && rm -f "${base}.bak"
  echo "$base"
}
D="$(mkconv_multiprimary conv-multiprimary.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "two different responder models should fail (c1)" || ok "check-converged: two different responder models fails (c1)"

# --- injection r9: extra [finding:] whose ns-id is NOT in the manifest ---
# Fully grammar-valid and fully responded (so coverage passes and _table is clean) — the
# only thing wrong is that this ns-id was never merged, so it's absent from the manifest.
# present-set now has an id the manifest lacks -> guard (b) (with guard (c)'s "id must be
# in manifest to look up `want`" as a natural backstop for the reverse direction).
D="$(mkconv conv-inject.md)"
{
  echo '> [finding:bogus-rd1-r1|high] injected finding'
  echo '> — via gpt-5.5'
  echo '> — risk: rx'
  echo '> [agree:bogus-rd1-r1]'
  echo '> — via claude-opus-4-8'
} >> "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "injected finding should fail" || ok "check-converged: injection fails (r9, guard-b)"

# --- short-circuit negatives (cheap contract locks) ---
# merged but NOT converged (marker still awaiting-primary) -> fail, before any guard runs
mkconv_noflip() {  # like mkconv but does NOT flip the marker to converged
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" >/dev/null 2>&1
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$base"
  echo "$base"
}
D="$(mkconv_noflip conv-notconverged.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "non-converged marker should fail" || ok "check-converged: marker not converged fails"

# no <doc>.manifest (bare star doc, never merged) -> fail on the early manifest-presence guard
D="${WORK}/conv-nomanifest.md"
{
  echo "# Doc"; echo '<!-- multi-review: converged · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'
  echo; echo "## Review"; echo
  echo '> [finding:codex-rd1-r1|high] a'; echo '> — via gpt-5.5'; echo '> — risk: r'
  echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'
} > "$D"
[[ ! -f "${D}.manifest" ]] || bad "test setup: manifest unexpectedly exists for $D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "missing manifest should fail" || ok "check-converged: no manifest fails"

# deleted quarantine record + its mirror, doc-only -> still fail (r16)
Q="${WORK}/conv-q.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$Q"
mkcopy "${Q}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 --quarantined gemini:idfail "$Q" "${Q}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$Q"
sed -i.bak 's/awaiting-primary/converged/' "$Q" && rm -f "${Q}.bak"
# converges WITH the quarantine intact
bash "$SUT" check-converged "$Q" >/dev/null 2>&1 && ok "check-converged: converges with quarantine intact" || bad "check-converged q-intact"
# tamper the quarantine REASON (record present but text changed) -> fail (r5)
sed -i.bak 's/· idfail ·/· benign-reason ·/' "$Q" && rm -f "${Q}.bak"
bash "$SUT" check-converged "$Q" >/dev/null 2>&1 && bad "tampered quarantine reason should fail" || ok "check-converged: tampered quarantine reason fails (r5)"
# now delete the quarantine record from the doc only (manifest retains it)
grep -v 'star-quarantined: gemini' "$Q" > "$Q.x" && mv "$Q.x" "$Q"
bash "$SUT" check-converged "$Q" >/dev/null 2>&1 && bad "hidden quarantine should fail" || ok "check-converged: hidden quarantine fails (r15/r16)"

# round-2 cumulative reproducibility: merge round 1, respond, merge round 2 (a second finding)
# against the SAME doc so the manifest is cumulative, respond to it, converge, and assert the
# stored hashes still reproduce on the final multi-round doc.
D2="${WORK}/conv-r2.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/3 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$D2"
mkcopy "${D2}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 "$D2" "${D2}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$D2"
mkcopy "${D2}.codex" '> [finding:r1|med] beta-round2' '> — via gpt-5.5' '> — risk: rb'
bash "$SUT" merge --round 2 "$D2" "${D2}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd2-r1]'; echo '> — via claude-opus-4-8'; } >> "$D2"
sed -i.bak 's/awaiting-primary/converged/' "$D2" && rm -f "${D2}.bak"
bash "$SUT" check-converged "$D2" >/dev/null 2>&1 && ok "check-converged: round-2 cumulative reproducibility passes" || bad "check-converged round-2 cumulative"

# --- round-qualified quarantine key: SAME provider quarantined in round 1 AND round 2 ---
# The durable in-doc record is round-qualified ("round ${N}"), so the manifest key must be
# too — a provider-only key would collide across rounds (the guard would keep re-matching
# round 1's record for round 2's manifest entry, and a valid converged review would wrongly
# fail). gemini is quarantined in both rounds with different reasons so the two in-doc
# records (and hashes) differ.
D3="${WORK}/conv-quarantine-r2.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/3 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$D3"
mkcopy "${D3}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 --quarantined gemini:round1-reason "$D3" "${D3}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$D3"
mkcopy "${D3}.codex" '> [finding:r1|med] beta-round2' '> — via gpt-5.5' '> — risk: rb'
bash "$SUT" merge --round 2 --quarantined gemini:round2-reason "$D3" "${D3}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd2-r1]'; echo '> — via claude-opus-4-8'; } >> "$D3"
sed -i.bak 's/awaiting-primary/converged/' "$D3" && rm -f "${D3}.bak"
bash "$SUT" check-converged "$D3" >/dev/null 2>&1 && ok "check-converged: same provider quarantined both rounds passes" || bad "check-converged: repeat-quarantine same provider (round-qualify bug)"

# --- gate-summary ---
G="${WORK}/gate.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$G"
{
  echo '> [finding:codex-rd1-r1|high] sql injection'; echo '> — via gpt-5.5'; echo '> — risk: rce'
  echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'
  echo '> [finding:gemini-rd1-r1|low] nit naming'; echo '> — via gemini'; echo '> — risk: minor'
  echo '> [dispute:gemini-rd1-r1] style pref, not a bug'; echo '> — via claude-opus-4-8'
  echo '<!-- star-quarantined: fable · identity-fail · round 1 -->'
} >> "$G"
before="$(shasum "$G" | cut -d' ' -f1)"
out="$(bash "$SUT" gate-summary "$G" claude-opus-4-8 2>/dev/null)"
after="$(shasum "$G" | cut -d' ' -f1)"

# ratio line first and correct
echo "$out" | head -1 | grep -qE 'agreed with 1 .*DISPUTED 1 .*of 2 across' && ok "gate-summary: ratio first" || bad "gate ratio (got: $(echo "$out" | head -1))"
# dispute shown with the disputed finding text + reason
echo "$out" | grep -q 'nit naming' && echo "$out" | grep -q 'style pref' && ok "gate-summary: dispute detail" || bad "gate dispute detail"
# quarantine named
echo "$out" | grep -q 'fable' && ok "gate-summary: quarantine named" || bad "gate quarantine"
# pure read — doc unchanged
[[ "$before" == "$after" ]] && ok "gate-summary: does not mutate doc" || bad "gate mutated doc"

# --- gate-summary --flag-independence (opt-in; without it, output is byte-identical) ---
# CODEX_DOC: one agreed cross-vendor (codex) finding; primary is anthropic (claude-opus-4-8)
CODEX_DOC="$(mkstar codexdoc.md \
  '> [finding:codex-rd1-a|med] cross-vendor concern' '> — via gpt-5.5' '> — risk: some risk' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8')"
# FABLE_ONLY_DOC: one agreed same-vendor (fable) finding; primary anthropic
FABLE_ONLY_DOC="$(mkstar fabledoc.md \
  '> [finding:fable-rd1-a|low] same-vendor concern' '> — via claude-fable-5' '> — risk: some risk' \
  '> [agree:fable-rd1-a]' '> — via claude-opus-4-8')"

# fable-only review, anthropic primary -> independence warning printed
out="$(bash "$SUT" gate-summary "$FABLE_ONLY_DOC" claude-opus-4-8 --flag-independence 2>/dev/null)"
printf '%s' "$out" | grep -q "no independent cross-vendor perspective" && ok "independence: fable-only warns" || bad "independence fable-only"

# codex admitted -> no warning
out="$(bash "$SUT" gate-summary "$CODEX_DOC" claude-opus-4-8 --flag-independence 2>/dev/null)"
printf '%s' "$out" | grep -q "no independent cross-vendor perspective" && bad "independence codex should be silent" || ok "independence: codex silent"

# without the flag -> no independence line at all
a="$(bash "$SUT" gate-summary "$FABLE_ONLY_DOC" claude-opus-4-8 2>/dev/null)"
printf '%s' "$a" | grep -q "cross-vendor" && bad "independence leaked without flag" || ok "independence: opt-in only"

# FABLE_QUARANTINED_CODEX_DOC: only same-vendor (fable) admitted, but a cross-vendor (codex)
# secondary was attempted and quarantined -> distinct "attempted but quarantined" message
# naming codex, not the generic same-vendor-only warning.
FABLE_QUARANTINED_CODEX_DOC="$(mkstar fabledoc-qcodex.md \
  '> [finding:fable-rd1-a|low] same-vendor concern' '> — via claude-fable-5' '> — risk: some risk' \
  '> [agree:fable-rd1-a]' '> — via claude-opus-4-8' \
  '<!-- star-quarantined: codex · identity-fail · round 1 -->')"
out="$(bash "$SUT" gate-summary "$FABLE_QUARANTINED_CODEX_DOC" claude-opus-4-8 --flag-independence 2>/dev/null)"
printf '%s' "$out" | grep -q "attempted but quarantined" && printf '%s' "$out" | grep -q "codex" \
  && ok "independence: attempted-but-quarantined names codex" || bad "independence attempted-but-quarantined"

# unknown/typo'd trailing arg must FAIL LOUD, not silently disable the flag (g1, Codex PR#10 review)
bash "$SUT" gate-summary "$FABLE_ONLY_DOC" claude-opus-4-8 --flag-independance >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "gate-summary: unknown arg fails loud" || bad "gate-summary swallowed unknown arg (typo'd flag)"

## --- observations (Task A3) ---
# a doc with one agreed finding + a primary observation
D="$(mkstar obs.md \
  '> [finding:codex-rd1-a|med] a concern' '> — via gpt-5.5' '> — risk: some risk' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8' \
  '> [observation] secondaries all missed the retry cap' '> — via claude-opus-4-8')"
# the observation is NOT a finding: the sole finding is agreed, so there is no open finding
[[ -z "$(bash "$SUT" open-findings "$D" 2>/dev/null)" ]] && ok "observations: not counted as a finding" || bad "observation leaked as finding"
# observations lists it
out="$(bash "$SUT" observations "$D" 2>/dev/null)"; rc=$?
[[ "$out" == "secondaries all missed the retry cap" && $rc -eq 0 ]] && ok "observations: listed" || bad "observations list (got '$out' rc=$rc)"
# gate-summary shows it under the observations heading
# (capture first, then grep the captured string — piping bash "$SUT" ... | grep -q directly
# races under `set -o pipefail`: grep -q exits the instant it matches this early-ish line,
# closing the pipe while the multi-process writer is still emitting later lines, so the
# writer dies with SIGPIPE (141) and pipefail promotes that over grep's 0 — same class of
# bug as `yes | head -1` under pipefail. Same capture-then-grep idiom used everywhere else
# in this file.)
out="$(bash "$SUT" gate-summary "$D" claude-opus-4-8 2>/dev/null)"; rc=$?
printf '%s' "$out" | grep -q "Primary observations (human-gate only)" && [[ $rc -eq 0 ]] \
  && ok "observations: in gate-summary" || bad "observations gate-summary (rc=$rc)"

# an observation added to an otherwise-converged doc must not affect check-converged
D="$(mkconv conv-with-obs.md)"
{ echo '> [observation] a note for the human gate'; echo '> — via claude-opus-4-8'; } >> "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: observation does not block convergence" || bad "check-converged: observation broke convergence"
[[ -z "$(bash "$SUT" open-findings "$D" 2>/dev/null)" ]] && ok "observations: open-findings still empty alongside observation" || bad "observations: leaked into open-findings"

# a doc with NO observations -> gate-summary output byte-identical to before (dormant/additive)
out_noobs="$(bash "$SUT" gate-summary "$G" claude-opus-4-8 2>/dev/null)"; rc=$?
printf '%s' "$out_noobs" | grep -q "Primary observations" && bad "observations heading leaked with no observations" || ok "observations: heading absent when no observations (dormant)"
[[ $rc -eq 0 ]] && ok "gate-summary: exits 0 on a normal doc with no observations" || bad "gate-summary rc on no-observations doc ($rc)"

## --- observations: fail loud on missing disclosure (Codex peer-review finding #1) ---
# A "> [observation]" line NOT immediately followed by a "> — via " line must fail loud
# (stderr message + non-zero exit), mirroring _table's fail() for findings — it must not
# silently vanish (rc=0, no output, no error), which is what cmd_observations used to do.

# mid-doc: the observation is followed by SOME other line that is not a via line.
D="$(mkstar obs-badmid.md \
  '> [observation] a note missing its disclosure line' \
  '> not a via line at all')"
out="$(bash "$SUT" observations "$D" 2>/dev/null)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "observations: mid-doc missing via fails loud (no output)" \
  || bad "observations mid-doc missing via (rc=$rc out='$out')"
err="$(bash "$SUT" observations "$D" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -qi 'not followed by' && ok "observations: mid-doc stderr is fail-loud" \
  || bad "observations mid-doc stderr (got '$err')"

# end-of-doc: the observation is the LAST line of ## Review — no via line follows at all.
D="$(mkstar obs-badend.md \
  '> [observation] a trailing note with no disclosure line')"
out="$(bash "$SUT" observations "$D" 2>/dev/null)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "observations: end-of-doc missing via fails loud (no output)" \
  || bad "observations end-of-doc missing via (rc=$rc out='$out')"
err="$(bash "$SUT" observations "$D" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -qi 'not followed by' && ok "observations: end-of-doc stderr is fail-loud" \
  || bad "observations end-of-doc stderr (got '$err')"

# a well-formed observation is unaffected by the fail-loud change (belt-and-suspenders re-check)
D="$(mkstar obs-good2.md \
  '> [observation] a properly disclosed note' '> — via claude-opus-4-8')"
out="$(bash "$SUT" observations "$D" 2>/dev/null)"; rc=$?
[[ "$out" == "a properly disclosed note" && $rc -eq 0 ]] \
  && ok "observations: well-formed still passes after fail-loud fix" \
  || bad "observations well-formed regressed (out='$out' rc=$rc)"

# gate-summary must not silently swallow a malformed observation either — the whole point of
# the fix is that it must not silently vanish from the gate summary, so gate-summary fails
# loud too rather than quietly proceeding without it.
D="$(mkstar obsgate-bad.md \
  '> [observation] gate summary should not swallow this' \
  '> not a via line')"
bash "$SUT" gate-summary "$D" claude-opus-4-8 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "gate-summary: malformed observation fails loud (not silently dropped)" \
  || bad "gate-summary malformed observation swallowed"

## --- compose-review / compose-inline (Task A4, dormant PR-publish composers) ---
# one agreed ANCHORED finding + one agreed UN-anchored finding
ANCHORED_DOC="$(mkstar anchored.md \
  '> [finding:codex-rd1-a|high] anchored concern' '> — via gpt-5.5' '> — risk: some risk' '> — at scripts/foo.sh:42' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8' \
  '> [finding:codex-rd1-b|low] un-anchored concern' '> — via gpt-5.5' '> — risk: some risk' \
  '> [agree:codex-rd1-b]' '> — via claude-opus-4-8')"

# compose-inline emits exactly the anchored agreed finding as TSV (end col empty for a single line)
out="$(bash "$SUT" compose-inline "$ANCHORED_DOC" 2>/dev/null)"
printf '%s\n' "$out" | grep -qE '^scripts/foo\.sh'$'\t''42'$'\t'$'\t' && ok "compose-inline: anchored agreed -> TSV" || bad "compose-inline tsv (got '$out')"
[[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ]] && ok "compose-inline: exactly one record" || bad "compose-inline record count (got '$out')"
# un-anchored agreed finding is NOT in inline output
printf '%s\n' "$out" | grep -q "un-anchored concern" && bad "compose-inline leaked un-anchored" || ok "compose-inline: un-anchored excluded"
# body carries the disclosure + concern text
printf '%s\n' "$out" | grep -qF 'anchored concern — risk: some risk — 🤖 multi-review star review (gpt-5.5 + claude-opus-4-8)' && ok "compose-inline: body + disclosure" || bad "compose-inline body (got '$out')"

# compose-review includes both agreed findings + disclosure footer
body="$(bash "$SUT" compose-review "$ANCHORED_DOC" claude-opus-4-8 2>/dev/null)"
printf '%s' "$body" | grep -q "AI agent" && ok "compose-review: disclosure present" || bad "compose-review disclosure"
printf '%s' "$body" | grep -q "anchored concern" && printf '%s' "$body" | grep -q "un-anchored concern" \
  && ok "compose-review: both agreed findings listed" || bad "compose-review missing a finding (got: $body)"
printf '%s' "$body" | grep -qF 'claude-opus-4-8' && ok "compose-review: primary named in footer" || bad "compose-review footer missing primary"

# a range anchor emits start+end
RANGE_DOC="$(mkstar range.md \
  '> [finding:codex-rd1-a|med] ranged concern' '> — via gpt-5.5' '> — risk: r' '> — at scripts/bar.sh:10-12' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8')"
out="$(bash "$SUT" compose-inline "$RANGE_DOC" 2>/dev/null)"
printf '%s\n' "$out" | grep -qF 'scripts/bar.sh	10	12	' && ok "compose-inline: range start+end" || bad "compose-inline range (got '$out')"

# a disputed anchored finding is NOT inline (only agreed ships inline)
DISPUTE_DOC="$(mkstar dispute.md \
  '> [finding:codex-rd1-a|high] disputed concern' '> — via gpt-5.5' '> — risk: r' '> — at scripts/baz.sh:1' \
  '> [dispute:codex-rd1-a] no' '> — via claude-opus-4-8')"
out="$(bash "$SUT" compose-inline "$DISPUTE_DOC" 2>/dev/null)"
[[ -z "$out" ]] && ok "compose-inline: disputed anchored finding excluded" || bad "compose-inline leaked dispute (got '$out')"

# an open (unresponded) anchored finding is NOT inline
OPEN_DOC="$(mkstar openanchor.md \
  '> [finding:codex-rd1-a|high] open concern' '> — via gpt-5.5' '> — risk: r' '> — at scripts/qux.sh:1')"
out="$(bash "$SUT" compose-inline "$OPEN_DOC" 2>/dev/null)"
[[ -z "$out" ]] && ok "compose-inline: open anchored finding excluded" || bad "compose-inline leaked open (got '$out')"

## --- malformed anchor: PRESENT-but-malformed hard-fails; ABSENT falls to summary (fix for the
## silent-degrade finding). Same fail-loud convention _table uses on a malformed finding block.

# (a) ABSENT anchor (no "> — at" line at all) -> compose-inline still succeeds (exit 0) and
# simply omits the finding from inline output — this is the behavior that must be PRESERVED.
ABSENT_ANCHOR_DOC="$(mkstar absentanchor.md \
  '> [finding:codex-rd1-a|low] no anchor at all' '> — via gpt-5.5' '> — risk: r' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8')"
out="$(bash "$SUT" compose-inline "$ABSENT_ANCHOR_DOC" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "compose-inline: absent anchor -> exit 0, falls to summary" || bad "compose-inline absent anchor (rc=$rc out='$out')"

# (b) PRESENT-but-MALFORMED anchors -> compose-inline hard-fails (exit non-zero, contract
# violation to stderr) instead of silently dropping the finding to the summary.
EMPTYPATH_DOC="$(mkstar emptypath.md \
  '> [finding:codex-rd1-a|high] bad anchor - empty path' '> — via gpt-5.5' '> — risk: r' '> — at :42' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8')"
bash "$SUT" compose-inline "$EMPTYPATH_DOC" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "compose-inline: empty-path anchor hard-fails" || bad "compose-inline empty-path anchor did not fail"

NONNUMERIC_DOC="$(mkstar nonnumeric.md \
  '> [finding:codex-rd1-a|high] bad anchor - non-numeric suffix' '> — via gpt-5.5' '> — risk: r' '> — at scripts/foo.sh:abc' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8')"
bash "$SUT" compose-inline "$NONNUMERIC_DOC" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "compose-inline: non-numeric-suffix anchor hard-fails" || bad "compose-inline non-numeric anchor did not fail"

ENDLTSTART_DOC="$(mkstar endltstart.md \
  '> [finding:codex-rd1-a|high] bad anchor - end < start' '> — via gpt-5.5' '> — risk: r' '> — at scripts/foo.sh:10-5' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8')"
bash "$SUT" compose-inline "$ENDLTSTART_DOC" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "compose-inline: end<start anchor hard-fails" || bad "compose-inline end<start anchor did not fail"

# stderr carries a contract-violation message (fail-loud), not silence
err="$(bash "$SUT" compose-inline "$EMPTYPATH_DOC" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -qi "contract violation" && ok "compose-inline: malformed anchor stderr is fail-loud" || bad "compose-inline malformed anchor stderr (got '$err')"

## --- anchor_of SIGPIPE false-failure on large docs (finding #1) ---
# anchor_of's success branch used to `print ...; exit` the moment it found the anchor, without
# draining review_section/strip_fences to EOF. Once the ## Review section exceeds the OS pipe
# buffer (~16KB on macOS), the upstream stages are still writing when awk exits, they take
# SIGPIPE, and with `pipefail` set that surfaces as anchor_of's own exit status — falsely
# tripping cmd_compose_inline's "contract violation" die() on a perfectly valid, merely large,
# doc. Build a >32KB ## Review section with the target anchored+agreed finding near the TOP
# (so it's found early and awk would exit long before the padding below it is drained) and pad
# with many additional finding/response blocks past the pipe-buffer threshold.
BIGARGS=(
  '> [finding:codex-rd1-a|high] anchored concern near top' '> — via gpt-5.5' '> — risk: some risk' '> — at scripts/foo.sh:42' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-4-8'
)
for i in $(seq 1 400); do
  BIGARGS+=(
    "> [finding:pad-rd1-p${i}|low] padding finding number ${i} with extra filler text to grow the section past typical OS pipe buffers"
    '> — via gpt-5.5'
    "> — risk: padding risk ${i}"
    "> [agree:pad-rd1-p${i}]"
    '> — via claude-opus-4-8'
  )
done
BIG_DOC="$(mkstar biganchor.md "${BIGARGS[@]}")"
[[ "$(awk '/^## Review/{f=1;next} f' "$BIG_DOC" | wc -c)" -gt 32768 ]] || bad "test setup: big doc review section not >32KB"
out="$(bash "$SUT" compose-inline "$BIG_DOC" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "compose-inline: large (>32KB) anchored doc exits 0 (no SIGPIPE false-failure)" \
  || bad "compose-inline large doc rc (got $rc)"
printf '%s\n' "$out" | grep -qE '^scripts/foo\.sh'$'\t''42'$'\t'$'\t' \
  && ok "compose-inline: large doc still emits the anchored finding's TSV" \
  || bad "compose-inline large doc tsv (got '$out')"

# --- remember-set --reviewers (Task 3) ---
# Write tests need env genuinely unset: once Task 4's env-shadow guard exists, an exported
# MULTI_REVIEW_REVIEWERS would turn every write into a no-op and fail these (fable-rd2-r1).
unset MULTI_REVIEW_REVIEWERS
RS="${WORK}/rs.pref"; rm -f "$RS"
# writes normalized csv and creates the parent dir
RS2="${WORK}/nested/deep/rs.pref"
bash "$SUT" remember-set --pref-file "$RS2" --reviewers codex,gemini >/dev/null 2>&1
[[ "$(cat "$RS2" 2>/dev/null)" == "codex,gemini" ]] && ok "remember-set: writes csv + creates dir" || bad "remember-set write (got '$(cat "$RS2" 2>/dev/null)')"

# strips fable + dedups
bash "$SUT" remember-set --pref-file "$RS" --reviewers fable,codex,codex,gemini >/dev/null 2>&1
[[ "$(cat "$RS")" == "codex,gemini" ]] && ok "remember-set: strips fable + dedups" || bad "remember-set strip (got '$(cat "$RS")')"

# registry-unknown id -> exit 2, pref untouched
printf 'codex\n' > "$RS"
bash "$SUT" remember-set --pref-file "$RS" --reviewers codex,bogus >/dev/null 2>&1
rc=$?; [[ $rc -eq 2 && "$(cat "$RS")" == "codex" ]] && ok "remember-set: unknown id exit 2, pref untouched" || bad "remember-set unknown (rc=$rc, pref='$(cat "$RS")')"

# empty extras (fable-only after stripping) -> no-op, existing file unchanged
printf 'codex\n' > "$RS"
bash "$SUT" remember-set --pref-file "$RS" --reviewers fable >/dev/null 2>&1
[[ "$(cat "$RS")" == "codex" ]] && ok "remember-set: empty extras is no-op (unchanged)" || bad "remember-set empty no-op (got '$(cat "$RS")')"

# empty extras with no pre-existing file -> no file created
RS3="${WORK}/none.pref"; rm -f "$RS3"
bash "$SUT" remember-set --pref-file "$RS3" --reviewers "" >/dev/null 2>&1
[[ ! -e "$RS3" ]] && ok "remember-set: empty extras creates nothing" || bad "remember-set empty created a file"

# overwrite is a full replace, not a merge
printf 'codex,gemini\n' > "$RS"
bash "$SUT" remember-set --pref-file "$RS" --reviewers codex >/dev/null 2>&1
[[ "$(cat "$RS")" == "codex" ]] && ok "remember-set: overwrite replaces (no merge)" || bad "remember-set overwrite (got '$(cat "$RS")')"

# OMITTING --reviewers entirely is a usage error (distinct from an explicit empty set)
printf 'codex\n' > "$RS"
bash "$SUT" remember-set --pref-file "$RS" >/dev/null 2>&1
rc=$?; [[ $rc -eq 2 && "$(cat "$RS")" == "codex" ]] && ok "remember-set: omitted --reviewers is exit 2" || bad "remember-set omit (rc=$rc, pref='$(cat "$RS")')"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
