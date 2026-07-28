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

# a duplicated bad id in the pref drops ONCE, not once per occurrence (dedup on drop; PR#13 fable-rd1-r2)
printf 'bogus,bogus\n' > "$PREF"
err="$(MULTI_REVIEW_REVIEWER_SH="$STUB" bash "$SUT" resolve-set --fable-floor --pref-file "$PREF" 2>&1 >/dev/null)"
n="$(printf '%s\n' "$err" | grep -c "pref reviewer 'bogus'")"
[[ "$n" -eq 1 ]] && ok "pref: duplicate bad id notice deduped (once)" || bad "pref dup-notice count (got $n)"

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

# --- compose-review must carry quarantines into the POSTED review (issue #26) ---------------
# gate-summary reported them; compose-review did not, so a review degraded by provider failure
# read as a clean one on the PR — and the AI-disclosure line, built from finding raisers, silently
# omitted the provider that was dispatched and died. The whole point of the human gate is deciding
# with full information; a quarantine is the signal the review was thinner than it looks.
QDOC="$(mkstar q-compose.md \
  '> [finding:codex-rd1-a|med] a real concern' '> — via gpt-5.6-terra' '> — risk: something' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-5' \
  '<!-- star-quarantined: gemini · dispatch-timeout · round 1 -->')"
body="$(bash "$SUT" compose-review "$QDOC" claude-opus-5 2>/dev/null)"
printf '%s' "$body" | grep -qi 'quarantin' \
  && ok "compose-review: names the quarantined secondary" || bad "compose-review dropped the quarantine: $body"
printf '%s' "$body" | grep -qF 'gemini' \
  && ok "compose-review: quarantine section identifies the provider" || bad "compose-review quarantine lacks provider"
printf '%s' "$body" | grep -qF 'dispatch-timeout' \
  && ok "compose-review: quarantine reason carried through" || bad "compose-review quarantine lacks reason"
# the disclosure line must not silently narrow to only the models that scored
printf '%s' "$body" | tail -2 | grep -qF 'gemini' \
  && ok "compose-review: disclosure names the dispatched-but-quarantined provider" \
  || bad "compose-review disclosure omits a dispatched provider: $(printf '%s' "$body" | tail -2)"

# ADDITIVE: a doc with no quarantines must produce byte-identical output to before this change.
before="$(bash "$SUT" compose-review "$ANCHORED_DOC" claude-opus-4-8 2>/dev/null)"
printf '%s' "$before" | grep -qi 'quarantin' \
  && bad "compose-review: emitted a quarantine section on a doc with none" \
  || ok "compose-review: dormant when there are no quarantines"

# --- a provider quarantined in ONE round may have contributed in another (PR#27) -------------
# PR #25's own shape: fable raised findings in round 1, was quarantined in round 2. The section
# header claimed "did not review; findings excluded" while its findings were listed right above,
# and the disclosure named it twice — once by raiser model, once as "(quarantined)" — overstating
# the agent count. Raised independently by gemini and fable; it is the same misinformation-at-the-
# gate failure #26 set out to remove.
PARTQ="$(mkstar partq.md \
  '> [finding:codex-rd1-a|med] contributed in round 1' '> — via gpt-5.6-terra' '> — risk: r' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-5' \
  '<!-- star-quarantined: codex · dispatch-timeout · round 2 -->')"
body="$(bash "$SUT" compose-review "$PARTQ" claude-opus-5 2>/dev/null)"
disc="$(printf '%s' "$body" | tail -2)"
# The provider contributed, so it is ALREADY represented in the disclosure by its raiser model id
# (gpt-5.6-terra). Appending "codex (quarantined)" names the same reviewer a second time under a
# different string and inflates the apparent agent count — which a bare "codex" occurrence count
# would not catch, since the two spellings differ.
! grep -qF 'codex (quarantined)' <<<"$disc" \
  && ok "compose-review: a contributing provider is not re-listed as quarantined" \
  || bad "compose-review disclosure double-lists a contributing provider: $disc"
! grep -qi 'did not review; findings excluded' <<<"$body" \
  && ok "compose-review: header does not claim findings were excluded when they were not" \
  || bad "compose-review header is false for a partly-quarantined provider: $body"
grep -qF 'round 2' <<<"$body" \
  && ok "compose-review: the quarantine event is still reported with its round" \
  || bad "compose-review lost the quarantine event: $body"

# A provider quarantined in EVERY round it appears (never contributed) must still be disclosed —
# that is the case #26 existed for, and it must not regress while fixing the double-listing.
ALLQ="$(mkstar allq.md \
  '> [finding:codex-rd1-a|med] c' '> — via gpt-5.6-terra' '> — risk: r' \
  '> [agree:codex-rd1-a]' '> — via claude-opus-5' \
  '<!-- star-quarantined: gemini · dispatch-timeout · round 1 -->')"
body="$(bash "$SUT" compose-review "$ALLQ" claude-opus-5 2>/dev/null)"
printf '%s' "$body" | tail -2 | grep -qF 'gemini' \
  && ok "compose-review: a never-contributing quarantined provider is still disclosed" \
  || bad "compose-review dropped a fully-quarantined provider from the disclosure"

# --- a malformed quarantine record must fail loud, not corrupt the posted review (PR#27) -----
# grep accepted a whitespace-only reason ([^·]+ matches a lone space) while sed required a
# non-space, so the raw comment line fell through untransformed — printed verbatim as an entry
# and space-split into garbage "(quarantined)" tokens in the disclosure.
BLANKQ="${WORK}/blank-reason.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  echo '> [finding:codex-rd1-a|med] c'; echo '> — via gpt-5.6-terra'; echo '> — risk: r'
  echo '> [agree:codex-rd1-a]'; echo '> — via claude-opus-5'
  echo '<!-- star-quarantined: gemini ·   · round 1 -->'
} > "$BLANKQ"
body="$(bash "$SUT" compose-review "$BLANKQ" claude-opus-5 2>&1)"
! grep -qF '<!-- star-quarantined' <<<"$body" \
  && ok "compose-review: never emits a raw record line into the body" \
  || bad "compose-review leaked an untransformed record: $body"
! grep -qE '\-\-> \(quarantined\)|star-quarantined: \(quarantined\)' <<<"$body" \
  && ok "compose-review: a malformed record cannot shred the disclosure line" \
  || bad "compose-review disclosure corrupted by a malformed record: $body"

# ...and merge refuses to WRITE one, so the malformed record cannot reach a doc in the first place.
# Self-contained: mkbase is defined further down this file, and a call before its definition
# silently fails — which made an earlier revision of this very assertion pass vacuously.
MB="${WORK}/mb.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo; } > "$MB"
mkcopy "${MB}.codex" '> [finding:r1|high] a' '> — via gpt-5.6-terra' '> — risk: r'
bash "$SUT" merge --round 1 --quarantined "gemini:   " "$MB" "${MB}.codex" >/dev/null 2>&1 \
  && bad "merge accepted a blank quarantine reason" \
  || ok "merge: refuses a blank quarantine reason at the source"

# merge must validate the PROVIDER too (PR#27 fable-rd2-r2). Validating only the reason left a
# hole in the same shape as the bug it fixed: a provider outside [a-z0-9]+ (or a --quarantined arg
# with no colon, which makes the whole string the "reason" and passes the non-blank check) writes
# a record every _quarantines reader silently drops — re-opening #26's invisibility through the
# unvalidated field.
# A NEWLINE in the reason (PR#27, found independently by codex, gemini AND fable) passed all four
# checks and wrote a two-line record no reader can parse — caught only by the POST-merge
# self-check, which reports "missing or tampered" and leaves the corrupted doc in place. That is
# the same shape as the hole this validation closed, so it must die before anything is written.
for badq in "Gemini:timeout" "gem ini:timeout" "noColonAtAll" ":timeout" "$(printf 'gemini:timed\nout')" "$(printf 'gemini:timed\tout')"; do
  MP="${WORK}/mp$RANDOM.md"
  { echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo; } > "$MP"
  MP_BEFORE="$(shasum "$MP" | cut -d' ' -f1)"
  mkcopy "${MP}.codex" '> [finding:r1|high] a' '> — via gpt-5.6-terra' '> — risk: r'
  bash "$SUT" merge --round 1 --quarantined "$badq" "$MP" "${MP}.codex" >/dev/null 2>&1 \
    && bad "merge accepted a malformed --quarantined arg: '$badq'" \
    || ok "merge: rejects malformed --quarantined '$(printf '%s' "$badq" | tr '\n\t' '~~')'"
  # "Before writing anything" must mean the DOC too, not just the manifest (PR#27 codex-rd4-r1).
  # Validation used to run in the record-writing loop, which is AFTER the findings block is
  # appended — so a malformed arg left a mutated doc with no manifest: a partial merge a retry
  # would duplicate. The earlier version of this assertion checked only the manifest and passed.
  [[ ! -f "${MP}.manifest" ]] \
    && ok "merge: refuses without leaving a manifest" \
    || bad "merge wrote a manifest despite refusing: ${MP}.manifest exists"
  [[ "$(shasum "$MP" | cut -d' ' -f1)" == "$MP_BEFORE" ]] \
    && ok "merge: refuses without mutating the doc" \
    || bad "merge mutated the doc despite refusing: $MP"
done
# a well-formed one still works
MP="${WORK}/mpok.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo; } > "$MP"
mkcopy "${MP}.codex" '> [finding:r1|high] a' '> — via gpt-5.6-terra' '> — risk: r'
bash "$SUT" merge --round 1 --quarantined "gemini:dispatch timed out" "$MP" "${MP}.codex" >/dev/null 2>&1 \
  && ok "merge: still accepts a well-formed quarantine" || bad "merge rejected a valid quarantine"
[[ "$(bash "$SUT" gate-summary "$MP" claude-opus-5 2>/dev/null | grep -c 'gemini · dispatch timed out')" -ge 1 ]] \
  && ok "merge: a valid multi-word reason survives round-trip to the readers" \
  || bad "valid quarantine did not round-trip"

# --- the quarantine record has ONE parser, and it is fence-aware (issue #26) -----------------
# A fenced EXAMPLE of the record is documentation, not a live quarantine. verify/check-converged
# already strip fences before matching; gate-summary and round-stats grepped the raw file, so the
# same doc disagreed with itself. Routing every reader through one helper is what makes that
# impossible rather than merely fixed-for-now.
FENCEQ="${WORK}/fenced-quarantine.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  echo '> [finding:codex-rd1-a|med] real concern'; echo '> — via gpt-5.6-terra'; echo '> — risk: r'
  echo '> [agree:codex-rd1-a]'; echo '> — via claude-opus-5'
  echo '```'
  echo '<!-- star-quarantined: fable · THIS-IS-DOCUMENTATION · round 1 -->'
  echo '```'
} > "$FENCEQ"
for sub in compose-review gate-summary; do
  out="$(bash "$SUT" "$sub" "$FENCEQ" claude-opus-5 2>/dev/null)"
  ! grep -qF 'THIS-IS-DOCUMENTATION' <<<"$out" \
    && ok "${sub}: a fenced quarantine example is not treated as a live record" \
    || bad "${sub}: fenced example counted as a real quarantine"
done
out="$(bash "$SUT" round-stats "$FENCEQ" 2>/dev/null)"
! grep -qE 'fable q' <<<"$out" \
  && ok "round-stats: a fenced quarantine example is not treated as a live record" \
  || bad "round-stats: fenced example counted as a real quarantine: $out"

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

# --- remember-set --clear + env-shadow guard (Task 4) ---
# --clear deletes an existing pref
printf 'codex,gemini\n' > "$RS"
bash "$SUT" remember-set --pref-file "$RS" --clear >/dev/null 2>&1
[[ ! -e "$RS" ]] && ok "remember-set --clear: deletes pref" || bad "clear did not delete"

# --clear on absent pref is success (idempotent)
bash "$SUT" remember-set --pref-file "$RS" --clear >/dev/null 2>&1
[[ $? -eq 0 && ! -e "$RS" ]] && ok "remember-set --clear: idempotent on absent" || bad "clear absent not idempotent"

# --clear and --reviewers are mutually exclusive (keyed on flag presence, not value)
bash "$SUT" remember-set --pref-file "$RS" --clear --reviewers codex >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "remember-set: --clear + --reviewers exit 2" || bad "clear+reviewers not exit 2"
# even --clear --reviewers "" (empty value) is rejected — presence, not emptiness (codex-rd1-r3)
printf 'codex\n' > "$RS"
bash "$SUT" remember-set --pref-file "$RS" --clear --reviewers "" >/dev/null 2>&1
[[ $? -eq 2 && "$(cat "$RS")" == "codex" ]] && ok "remember-set: --clear --reviewers '' exit 2, pref untouched" || bad "clear+empty-reviewers not rejected"

# env-shadow guard: non-empty env -> --reviewers is a no-op, existing pref untouched
printf 'codex\n' > "$RS"
MULTI_REVIEW_REVIEWERS="gemini" bash "$SUT" remember-set --pref-file "$RS" --reviewers codex,gemini 2>/dev/null
[[ "$(cat "$RS")" == "codex" ]] && ok "remember-set: env set -> write no-op (pref untouched)" || bad "env-shadow wrote anyway (got '$(cat "$RS")')"

# env-shadow guard emits a stderr notice
err="$(MULTI_REVIEW_REVIEWERS="gemini" bash "$SUT" remember-set --pref-file "$RS" --reviewers codex 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'MULTI_REVIEW_REVIEWERS' && ok "remember-set: env-shadow stderr notice" || bad "env-shadow no notice (got '$err')"

# empty-string env does NOT trip the guard -> write proceeds
printf 'codex\n' > "$RS"
MULTI_REVIEW_REVIEWERS="" bash "$SUT" remember-set --pref-file "$RS" --reviewers gemini >/dev/null 2>&1
[[ "$(cat "$RS")" == "gemini" ]] && ok "remember-set: empty env does not trip guard" || bad "empty env tripped guard (got '$(cat "$RS")')"

# --clear ignores the env-shadow guard (clears even when env is set)
printf 'codex\n' > "$RS"
MULTI_REVIEW_REVIEWERS="gemini" bash "$SUT" remember-set --pref-file "$RS" --clear >/dev/null 2>&1
[[ ! -e "$RS" ]] && ok "remember-set --clear: ignores env guard" || bad "clear blocked by env guard"

# ============================================================================
# verify subcommand + merge self-check (issue #16): doc↔manifest inconsistency
# must fail loud at the handoff, not accumulate silently to the terminal gate.
# ============================================================================
mkbase() { { echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo; } > "$1"; }

VB="${WORK}/vfy.md"; mkbase "$VB"
mkcopy "${VB}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
mkcopy "${VB}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
bash "$SUT" merge --round 1 "$VB" "${VB}.codex" "${VB}.gemini" >/dev/null 2>&1

# clean merged doc verifies
bash "$SUT" verify "$VB" >/dev/null 2>&1 && ok "verify: clean merged doc passes" || bad "verify rejected a clean doc"

# dropped finding (doc missing an id the manifest lists) -> fail
cp "$VB" "${VB}.bak"
grep -v -e '\[finding:gemini-rd1-r1' -e '^> — via gemini$' -e '^> — risk: rb$' "${VB}.bak" > "$VB"
bash "$SUT" verify "$VB" >/dev/null 2>&1 && bad "verify missed a dropped finding" || ok "verify: detects a dropped finding (doc≠manifest id-set)"
cp "${VB}.bak" "$VB"

# tampered finding block (same id, changed text) -> hash mismatch -> fail
cp "$VB" "${VB}.bak"
sed 's/alpha/ALPHA-TAMPERED/' "${VB}.bak" > "$VB"
bash "$SUT" verify "$VB" >/dev/null 2>&1 && bad "verify missed a tampered finding block" || ok "verify: detects a tampered finding block (hash mismatch)"
cp "${VB}.bak" "$VB"

# orphaned response (grammar violation) -> fail
cp "$VB" "${VB}.bak"
printf '\n> [agree:no-such-finding]\n> — via primary-model\n' >> "$VB"
bash "$SUT" verify "$VB" >/dev/null 2>&1 && bad "verify missed an orphaned response" || ok "verify: detects an orphaned response (grammar)"
cp "${VB}.bak" "$VB"

# malformed/fused footer (star-findings prefix lost) -> fail
cp "$VB" "${VB}.bak"
sed 's/^<!-- star-findings: /> — via x/' "${VB}.bak" > "$VB"
bash "$SUT" verify "$VB" >/dev/null 2>&1 && bad "verify missed a malformed footer" || ok "verify: detects a malformed/fused footer"
cp "${VB}.bak" "$VB"; rm -f "${VB}.bak"

# merge refuses to build on an already-inconsistent doc (start self-check) — this is the
# guard that would have caught issue #16 at the next round instead of at the gate.
MB="${WORK}/mchk.md"; mkbase "$MB"
mkcopy "${MB}.codex" '> [finding:r1|high] one' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$MB" "${MB}.codex" >/dev/null 2>&1
# corrupt: drop the round-1 finding block from the doc (manifest still lists it)
grep -v -e '\[finding:codex-rd1-r1' -e '^> — via gpt-5.5$' -e '^> — risk: r$' "$MB" > "${MB}.t" && mv "${MB}.t" "$MB"
mkcopy "${MB}.codex" '> [finding:r1|low] two' '> — via gpt-5.5' '> — risk: r'
before="$(shasum "$MB" | cut -d' ' -f1)"
bash "$SUT" merge --round 2 "$MB" "${MB}.codex" >/dev/null 2>&1; rc=$?
after="$(shasum "$MB" | cut -d' ' -f1)"
[[ $rc -ne 0 && "$before" == "$after" ]] && ok "merge: refuses to build on an inconsistent doc (start self-check)" || bad "merge built on a corrupted doc (rc=$rc)"

# a clean multi-round merge still succeeds end-to-end (self-checks don't break the happy path)
CB="${WORK}/mok.md"; mkbase "$CB"
mkcopy "${CB}.codex" '> [finding:r1|high] a' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$CB" "${CB}.codex" >/dev/null 2>&1
mkcopy "${CB}.codex" '> [finding:r1|low] b' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 2 "$CB" "${CB}.codex" >/dev/null 2>&1 \
  && bash "$SUT" verify "$CB" >/dev/null 2>&1 \
  && ok "merge: clean 2-round merge passes self-checks + verify" || bad "self-check broke the happy path"

# (#17 gemini-r1/fable-r1, HIGH) the "; quarantined:" literal in a finding's text OR a fenced diff
# must NOT false-positive the footer check — otherwise the tool cannot review its own PR.
FP="${WORK}/fp.md"; mkbase "$FP"
mkcopy "${FP}.codex" '> [finding:r1|med] the footer check must ignore the "; quarantined:" tail written here' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$FP" "${FP}.codex" >/dev/null 2>&1 \
  && ok "merge: a finding whose text contains '; quarantined:' merges (no self-check false-positive)" \
  || bad "merge false-positived on a legit '; quarantined:' in finding text (#17 r1)"
printf '\n```\n+  grep -n "; quarantined:" "$doc"\n```\n' >> "$FP"   # a fenced diff carrying the sentinel
bash "$SUT" verify "$FP" >/dev/null 2>&1 \
  && ok "verify: '; quarantined:' in finding text / fenced diff does NOT false-positive (#17 r1)" \
  || bad "verify false-positived on a legit '; quarantined:' mention (#17 r1)"

# (#17 codex-r1/fable-r2, MED) verify validates manifest quarantine records like check-converged (d)
QV="${WORK}/qv.md"; mkbase "$QV"
mkcopy "${QV}.codex" '> [finding:r1|high] a' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 --quarantined gemini:identity-fail "$QV" "${QV}.codex" >/dev/null 2>&1
bash "$SUT" verify "$QV" >/dev/null 2>&1 && ok "verify: clean doc with a quarantine record passes" || bad "verify rejected a clean quarantined doc"
cp "$QV" "${QV}.bak"
grep -v '^<!-- star-quarantined:' "${QV}.bak" > "$QV"
bash "$SUT" verify "$QV" >/dev/null 2>&1 && bad "verify missed a deleted quarantine record" || ok "verify: detects a deleted quarantine record (#17 codex-r1/fable-r2)"
sed 's/identity-fail/tampered-reason/' "${QV}.bak" > "$QV"
bash "$SUT" verify "$QV" >/dev/null 2>&1 && bad "verify missed a tampered quarantine record" || ok "verify: detects a tampered quarantine record"
rm -f "${QV}.bak"

# (#17 fable-r3, LOW) a deleted/truncated footer is caught by the count, not the (now-gone) tail grep
FD="${WORK}/fd.md"; mkbase "$FD"
mkcopy "${FD}.codex" '> [finding:r1|med] x' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$FD" "${FD}.codex" >/dev/null 2>&1
grep -v '^<!-- star-findings:' "$FD" > "${FD}.t" && mv "${FD}.t" "$FD"
bash "$SUT" verify "$FD" >/dev/null 2>&1 && bad "verify missed a deleted footer" || ok "verify: detects a deleted footer via count (#17 fable-r3)"

# (#17-refix gemini-r1/fable-r1, HIGH) a finding whose ORIGINAL id contains a "-rd<n>" substring
# (namespaced to e.g. codex-rd1-guard-rd2) must not be mis-parsed as a later round by the
# footer-count check — the round is parsed anchored to the provider prefix, not greedily.
NR="${WORK}/nr.md"; mkbase "$NR"
mkcopy "${NR}.codex" '> [finding:guard-rd2|med] this original id contains a -rd2 substring' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$NR" "${NR}.codex" >/dev/null 2>&1 \
  && bash "$SUT" verify "$NR" >/dev/null 2>&1 \
  && ok "verify: a finding id with nested '-rdN' is not mis-parsed as a later round (#17-refix r1)" \
  || bad "footer-count mis-parsed a nested '-rdN' id — greedy regex regressed (#17-refix r1)"

# (#17-refix fable-r2, MED) a fenced column-0 star-quarantined example (earlier in the doc) must
# NOT shadow the real appended record — check(6) is scoped through review_section/strip_fences.
QS="${WORK}/qs.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; \
  echo '```'; echo '<!-- star-quarantined: gemini · SPOOFED-DIFFERENT-TEXT · round 1 -->'; echo '```'; echo; \
  echo "## Review"; echo; } > "$QS"
mkcopy "${QS}.codex" '> [finding:r1|high] a' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 --quarantined gemini:identity-fail "$QS" "${QS}.codex" >/dev/null 2>&1 \
  && bash "$SUT" verify "$QS" >/dev/null 2>&1 \
  && ok "verify: a fenced star-quarantined example does not shadow the real record (#17-refix r2)" \
  || bad "check(6) fence-blind: a fenced quarantine example shadowed the real record (#17-refix r2)"

# (#17-refix2 codex-r1/fable-r1, HIGH) verify and check-converged must AGREE — they now share ONE
# structural helper. A fenced star-quarantined look-alike EARLIER in the doc must not make the gate
# reject a doc the handoff accepts (before the refactor, verify's quarantine check was fence-scoped
# but check-converged's guard (d) was not → a doc could pass verify yet never converge).
DV="${WORK}/dv.md"
{ echo "# Doc"; echo '<!-- multi-review: converged · round 1/1 -->'; \
  echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; \
  echo '```'; echo '<!-- star-quarantined: gemini · SPOOF-EARLIER · round 1 -->'; echo '```'; echo; \
  echo "## Review"; echo; } > "$DV"
mkcopy "${DV}.codex" '> [finding:r1|high] a' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 --quarantined gemini:identity-fail "$DV" "${DV}.codex" >/dev/null 2>&1
printf '\n> [agree:codex-rd1-r1] ok\n> — via primary-x\n' >> "$DV"
dv_v=$(bash "$SUT" verify "$DV" >/dev/null 2>&1; echo $?)
dv_c=$(bash "$SUT" check-converged "$DV" >/dev/null 2>&1; echo $?)
[[ "$dv_v" == "0" && "$dv_c" == "0" ]] \
  && ok "verify and check-converged agree on a fenced-quarantine doc — no divergence (#17-refix2)" \
  || bad "verify/check-converged diverge on a fenced-quarantine doc (verify=$dv_v check-converged=$dv_c)"

# (#17-refix3 fable-r1, HIGH) fail CLOSED, not open: an id in the manifest that is outside _table's
# grammar (e.g. contains '.') is invisible to open-findings/coverage/gate, so the consistency check
# must reject it (present-ids sourced from _table, not a raw grep) rather than let it silently pass.
FO="${WORK}/fo.md"; mkbase "$FO"
mkcopy "${FO}.codex" '> [finding:r1|high] a' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$FO" "${FO}.codex" >/dev/null 2>&1
printf '\n> [finding:codex-rd1-r.2|high] this id has a dot — invisible to _table\n> — via x\n> — risk: r\n' >> "$FO"
echo 'finding codex-rd1-r.2=deadbeefdeadbeef' >> "${FO}.manifest"
bash "$SUT" verify "$FO" >/dev/null 2>&1 \
  && bad "verify FAILED OPEN: an ungrammatical manifest id passed (#17-refix3 r1)" \
  || ok "verify: fails closed on a manifest id invisible to _table's grammar (#17-refix3 r1)"

# --- round-stats (issue #22) ---------------------------------------------------------------
# The re-fan rule was "re-fan while the previous round produced >=1 new admitted finding". That
# can never terminate, because the protocol REQUIRES the primary to address agreed findings in
# the doc body between rounds — so round N+1 reviews prose written during round N. In the run
# that produced issue #22 the per-round totals went 9,3,3,3,3: the rate flattened instead of
# decaying, and the review ran to MULTI_REVIEW_MAX_ROUNDS. round-stats exposes the trend (and
# per-provider dry streaks) so the primary can stop on evidence. Pure read, no new state: every
# number comes from the doc's own ns-ids (<provider>-rd<N>-<id>).

# fnd <provider> <round> <id> -> one finding block (3 lines) on stdout
fnd() { printf '> [finding:%s-rd%s-%s|low] concern %s%s\n> — via %s-model\n> — risk: r\n' "$1" "$2" "$3" "$3" "$1" "$1"; }

# RS_FLAT reproduces the issue's shape exactly: rd1=9 (codex 1, fable 5, gemini 3),
# rd2=3 (0,2,1), rd3=3 (0,1,2). The rate decays once, then goes flat.
RS="${WORK}/rs-flat.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 3/5 -->'
  echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo
  fnd codex 1 a; for i in a b c d e; do fnd fable 1 "$i"; done; for i in a b c; do fnd gemini 1 "$i"; done
  for i in a b; do fnd fable 2 "$i"; done; fnd gemini 2 a
  fnd fable 3 a; for i in a b; do fnd gemini 3 "$i"; done
} > "$RS"

out="$(bash "$SUT" round-stats "$RS" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "round-stats: exits 0 on a well-formed doc" || bad "round-stats rc=$rc: '$out'"
grep -qE '^rd1 .*codex 1.*fable 5.*gemini 3.*= 9' <<<"$out" \
  && ok "round-stats: round 1 per-provider counts and total" || bad "round-stats rd1 wrong: '$out'"
grep -qE '^rd2 .*codex 0.*fable 2.*gemini 1.*= 3' <<<"$out" \
  && ok "round-stats: round 2 counts a provider that found nothing as 0" || bad "round-stats rd2 wrong: '$out'"
grep -qE '^rd3 .*= 3' <<<"$out" && ok "round-stats: round 3 total" || bad "round-stats rd3 wrong: '$out'"
# the trend, not just the count — this is the whole point
grep -qE '^rd2 .*decaying' <<<"$out" && ok "round-stats: marks a decaying round" || bad "round-stats no decay marker: '$out'"
grep -qE '^rd3 .*flat' <<<"$out" && ok "round-stats: marks the flat round" || bad "round-stats no flat marker: '$out'"
grep -qE '^verdict: converge' <<<"$out" \
  && ok "round-stats: flat rate -> converge verdict" || bad "round-stats verdict not converge: '$out'"
# per-provider dry streak (issue #22 part 2): codex found nothing in rounds 2 and 3
grep -qE '^dry-streak:.*codex 2' <<<"$out" \
  && ok "round-stats: reports codex's 2-round dry streak" || bad "round-stats dry streak missing: '$out'"
# pure read
before="$(shasum "$RS" | cut -d' ' -f1)"; bash "$SUT" round-stats "$RS" >/dev/null 2>&1
[[ "$before" == "$(shasum "$RS" | cut -d' ' -f1)" ]] && ok "round-stats: does not mutate the doc" || bad "round-stats mutated the doc"

# still decaying -> re-fan (the rule must not stop a review that is still finding new ground)
RSD="${WORK}/rs-decay.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c d e; do fnd fable 1 "$i"; done
  fnd fable 2 a
} > "$RSD"
out="$(bash "$SUT" round-stats "$RSD" 2>&1)"
grep -qE '^verdict: re-fan' <<<"$out" && ok "round-stats: decaying rate -> re-fan verdict" || bad "round-stats should re-fan: '$out'"

# round 1 only -> re-fan (no trend yet; one round is never evidence of convergence)
RS1="${WORK}/rs-one.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; fnd fable 1 a
} > "$RS1"
out="$(bash "$SUT" round-stats "$RS1" 2>&1)"
grep -qE '^verdict: re-fan' <<<"$out" && ok "round-stats: single round -> re-fan (no trend yet)" || bad "round-stats round1: '$out'"

# a genuinely DRY round is invisible in the ns-ids (nothing merged), so the round count must come
# from the MARKER, not from the highest round seen in findings — otherwise a dry round silently
# reads as "the review is still on round 2" and the loop never learns it went dry.
RSDRY="${WORK}/rs-dry.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 3/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c; do fnd fable 1 "$i"; done
  fnd fable 2 a
} > "$RSDRY"
out="$(bash "$SUT" round-stats "$RSDRY" 2>&1)"
grep -qE '^rd3 .*= 0' <<<"$out" && ok "round-stats: a dry round is reported as 0, not omitted" || bad "round-stats dropped the dry round: '$out'"
grep -qE '^verdict: converge.*dry' <<<"$out" && ok "round-stats: dry round -> converge verdict" || bad "round-stats dry verdict: '$out'"

# ceiling reached -> converge regardless of trend (the cost bound still binds)
RSMAX="${WORK}/rs-max.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/2 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c d e; do fnd fable 1 "$i"; done
  fnd fable 2 a
} > "$RSMAX"
out="$(bash "$SUT" round-stats "$RSMAX" 2>&1)"
grep -qE '^verdict: converge.*ceiling' <<<"$out" \
  && ok "round-stats: round ceiling -> converge even while decaying" || bad "round-stats ceiling: '$out'"

# a quarantined round is NOT evidence of dryness — the provider never got to speak. Counting it
# as a dry round would advise dropping a reviewer that was actually broken that round.
RSQ="${WORK}/rs-q.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  fnd fable 1 a; fnd codex 1 a
  fnd fable 2 a
  echo '<!-- star-quarantined: codex · dispatch-timeout · round 2 -->'
} > "$RSQ"
out="$(bash "$SUT" round-stats "$RSQ" 2>&1)"
grep -qE '^rd2 .*codex q' <<<"$out" \
  && ok "round-stats: a quarantined round shows q, not 0" || bad "round-stats quarantine not marked: '$out'"
! grep -qE '^dry-streak:.*codex' <<<"$out" \
  && ok "round-stats: a quarantined round does not count toward a dry streak" \
  || bad "round-stats miscounted a quarantine as dry: '$out'"

# a RISING rate is not the same signal as a flat one (PR#23 gemini-rd1-r2, fable-rd1-r3): both
# stop the loop, but a rise can mean the primary's own edits introduced regressions, which the
# human gate should be able to tell from mere saturation.
RSUP="${WORK}/rs-rising.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 3/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c d e f g h i; do fnd fable 1 "$i"; done
  for i in a b c d e f g; do fnd fable 2 "$i"; done
  for i in a b c d e f g h i; do fnd fable 3 "$i"; done
} > "$RSUP"
out="$(bash "$SUT" round-stats "$RSUP" 2>&1)"
grep -qE '^rd3 .*rising' <<<"$out" && ok "round-stats: marks a rising round distinctly" || bad "round-stats rising not labeled: '$out'"
! grep -qE '^rd3 .*flat' <<<"$out" && ok "round-stats: a rising round is not labeled flat" || bad "round-stats called a rise flat: '$out'"
if grep -qE '^verdict: converge' <<<"$out" && grep -qiE '^verdict:.*(rose|rising)' <<<"$out"; then
  ok "round-stats: verdict distinguishes a rise from a plateau"
else
  bad "round-stats verdict conflates rise with flat: '$(grep '^verdict:' <<<"$out")'"
fi

# round-stats must refuse to render a verdict on an IN-FLIGHT round (PR#23 fable-rd1-r2). Called
# on `awaiting-secondaries`, round N has fanned out but not merged, so it has no ns-ids yet — the
# old code read that as zero and printed a confident "converge — round N went dry".
RSIF="${WORK}/rs-inflight.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-secondaries · round 2/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c; do fnd fable 1 "$i"; done
} > "$RSIF"
out="$(bash "$SUT" round-stats "$RSIF" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "round-stats: in-flight round exits non-zero" || bad "round-stats accepted an in-flight round (rc=$rc)"
! grep -qE '^verdict: (converge|re-fan)' <<<"$out" \
  && ok "round-stats: emits no verdict for an in-flight round" \
  || bad "round-stats gave a confident verdict mid-round: '$out'"
grep -qi 'awaiting-secondaries\|in flight\|not merged' <<<"$out" \
  && ok "round-stats: names why it refused" || bad "round-stats refusal unexplained: '$out'"

# the states where a verdict IS meaningful still work
for st in awaiting-primary converged exhausted; do
  RSOK="${WORK}/rs-${st}.md"
  { echo "# Doc"; echo "<!-- multi-review: ${st} · round 2/5 -->"
    echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
    for i in a b c; do fnd fable 1 "$i"; done; fnd fable 2 a
  } > "$RSOK"
  bash "$SUT" round-stats "$RSOK" >/dev/null 2>&1 \
    && ok "round-stats: accepts state ${st}" || bad "round-stats rejected valid state ${st}"
done

# The trend must compare LIKE WITH LIKE (PR#23 fable-rd2-r2). Raw round totals move with the
# admitted-provider set, so a quarantine alone can make a still-decaying review look flat or
# rising. Demonstrated on this PR's own smoke data: rd2 excluded a quarantined codex (7) while
# rd3 included codex's 3 (9) — on the providers admitted in BOTH rounds the rate went 7 → 6,
# still decaying. The verdict must be computed on that comparable subset.
RSQD="${WORK}/rs-qdenom.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 3/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  fnd codex 1 a; fnd codex 1 b; for i in a b c d e; do fnd fable 1 "$i"; done; fnd gemini 1 a; fnd gemini 1 b
  for i in a b c d; do fnd fable 2 "$i"; done; for i in a b c; do fnd gemini 2 "$i"; done
  for i in a b c; do fnd codex 3 "$i"; done; for i in a b c; do fnd fable 3 "$i"; done; for i in a b c; do fnd gemini 3 "$i"; done
  echo '<!-- star-quarantined: codex · dispatch-timeout · round 2 -->'
} > "$RSQD"
out="$(bash "$SUT" round-stats "$RSQD" 2>&1)"
# raw totals: rd2 = 7 (codex quarantined), rd3 = 9. Comparable subset (fable+gemini): 7 -> 6.
grep -qE '^verdict: re-fan' <<<"$out" \
  && ok "round-stats: trend ignores a quarantine-shifted denominator" \
  || bad "round-stats verdict was a denominator artifact: '$(grep '^verdict:' <<<"$out")'"
grep -qiE 'comparable|admitted in both' <<<"$out" \
  && ok "round-stats: says the trend used a comparable subset" \
  || bad "round-stats did not disclose the subset basis: '$out'"

# The per-row GLYPH must agree with the verdict (PR#23 codex-rd3-r1 + fable-rd3-r2, raised
# independently by two vendors). The verdict compares the comparable subset while the glyph
# compared raw totals, so the same table could print `↑ rising` directly above
# `verdict: re-fan — still decaying`. The glyph is the row's headline signal at the gate.
out="$(bash "$SUT" round-stats "$RSQD" 2>&1)"
if grep -qE '^rd3 .*rising' <<<"$out" && grep -qE '^verdict: re-fan' <<<"$out"; then
  bad "round-stats: glyph contradicts the verdict: '$(grep -E '^rd3|^verdict:' <<<"$out" | tr '\n' '|')'"
else
  ok "round-stats: row glyph and verdict agree under a quarantine"
fi
grep -qE '^rd3 .*decaying' <<<"$out" \
  && ok "round-stats: glyph uses the comparable subset too" \
  || bad "round-stats rd3 glyph not decaying: '$(grep '^rd3' <<<"$out")'"

# A PARTIALLY-quarantined round with zero admitted findings is not saturation either (PR#23
# fable-rd3-r1): the unheard providers are absence of evidence, exactly as in the all-quarantined
# case. The dry verdict must carry that caveat rather than converging silently.
RSPQ="${WORK}/rs-partialq.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/5 -->'
  echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo
  for i in a b c; do fnd fable 1 "$i"; done; fnd codex 1 a; fnd gemini 1 a
  echo '<!-- star-quarantined: codex · dispatch-timeout · round 2 -->'
  echo '<!-- star-quarantined: gemini · dispatch-timeout · round 2 -->'
} > "$RSPQ"
out="$(bash "$SUT" round-stats "$RSPQ" 2>&1)"
grep -qE '^verdict:' <<<"$out" && grep -qiE 'quarantin' <<<"$(grep '^verdict:' <<<"$out")" \
  && ok "round-stats: a partially-quarantined dry round is caveated" \
  || bad "round-stats converged on a partial quarantine with no caveat: '$(grep '^verdict:' <<<"$out")'"

# An ALL-quarantined round is not a dry round (PR#23 fable-rd2-r1): nobody spoke, so a zero total
# is absence of evidence, not evidence of saturation. The code already treats quarantine that way
# for dry streaks; the round total and verdict must agree.
RSAQ="${WORK}/rs-allq.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c; do fnd fable 1 "$i"; done; fnd codex 1 a
  echo '<!-- star-quarantined: fable · dispatch-timeout · round 2 -->'
  echo '<!-- star-quarantined: codex · dispatch-timeout · round 2 -->'
} > "$RSAQ"
out="$(bash "$SUT" round-stats "$RSAQ" 2>&1)"
! grep -qE '^rd2 .*dry' <<<"$out" \
  && ok "round-stats: an all-quarantined round is not labeled dry" \
  || bad "round-stats called an all-quarantined round dry: '$out'"
! grep -qE '^verdict: converge.*dry' <<<"$out" \
  && ok "round-stats: no went-dry verdict when nobody spoke" \
  || bad "round-stats converged on an all-quarantined round: '$(grep '^verdict:' <<<"$out")'"

# Glyph and verdict must agree on what DRY means (PR#23 fable-rd4-r1). The round-3 fix put the
# trend DIRECTION on the comparable subset but left dryness split: the glyph fired on the subset
# sum, the verdict on the raw admitted total. A provider quarantined in r-1 returning in r with
# findings drove the subset to zero while the round plainly found things — printing `✗ dry` above
# a re-fan verdict. Dryness is "nothing was admitted at all" (raw); direction is the subset.
RSDG="${WORK}/rs-dryglyph.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/5 -->'
  echo '<!-- multi-review-mode: star · reviewers: codex -->'; echo; echo "## Review"; echo
  fnd fable 1 a; fnd fable 1 b
  for i in a b c; do fnd codex 2 "$i"; done
  echo '<!-- star-quarantined: codex · dispatch-timeout · round 1 -->'
} > "$RSDG"
out="$(bash "$SUT" round-stats "$RSDG" 2>&1)"
! grep -qE '^rd2 .*dry' <<<"$out" \
  && ok "round-stats: a round with admitted findings is never glyphed dry" \
  || bad "round-stats glyphed a non-empty round dry: '$(grep '^rd2' <<<"$out")'"

# The dry caveat must key on a quarantine in THIS round, not on the two-round comparison window
# (PR#23 gemini-rd4-r1) — otherwise a round-1 dry round can never be caveated at all, and a
# quarantine in the PREVIOUS round wrongly caveats a cleanly-dry current one.
RSD1="${WORK}/rs-dry-round1.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/5 -->'
  echo '<!-- multi-review-mode: star · reviewers: codex -->'; echo; echo "## Review"; echo
  echo '<!-- star-quarantined: codex · dispatch-timeout · round 1 -->'
} > "$RSD1"
out="$(bash "$SUT" round-stats "$RSD1" 2>&1)"
grep -qiE '^verdict:.*quarantin' <<<"$out" \
  && ok "round-stats: a round-1 dry round with a quarantine is caveated" \
  || bad "round-stats round-1 dry not caveated: '$(grep '^verdict:' <<<"$out")'"

RSD2="${WORK}/rs-dry-clean.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 3/5 -->'
  echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo
  for i in a b c; do fnd fable 1 "$i"; done
  fnd fable 2 a
  echo '<!-- star-quarantined: fable · dispatch-timeout · round 1 -->'
} > "$RSD2"
out="$(bash "$SUT" round-stats "$RSD2" 2>&1)"
if grep -qE '^verdict: converge' <<<"$out" && ! grep -qiE '^verdict:.*quarantin' <<<"$out"; then
  ok "round-stats: a cleanly-dry round is not caveated by an older quarantine"
else
  bad "round-stats caveated a clean dry round: '$(grep '^verdict:' <<<"$out")'"
fi

# missing doc / missing marker fail loud rather than reporting a confident empty table
bash "$SUT" round-stats "${WORK}/nope.md" >/dev/null 2>&1 \
  && bad "round-stats accepted a missing doc" || ok "round-stats: missing doc fails loud"
RSNM="${WORK}/rs-nomarker.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; fnd fable 1 a; } > "$RSNM"
bash "$SUT" round-stats "$RSNM" >/dev/null 2>&1 \
  && bad "round-stats accepted a doc with no marker" || ok "round-stats: missing marker fails loud"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
