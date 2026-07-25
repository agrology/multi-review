#!/usr/bin/env bash
# multi-review-reviewer.test.sh — reviewer provider registry: resolution, availability,
# prompt emission, reviewer-identity verification.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-reviewer.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# Cleared for the whole suite. It is a documented user-facing override, so an engineer
# running the gate with it exported would otherwise see assertions fail against a CORRECT
# implementation. Tests that exercise the override set it explicitly and locally.
unset MULTI_REVIEW_REVIEWER_MODEL

mkdoc() { # mkdoc <name> <state>; prints path
  local p="${WORK}/$1"
  printf '# T\n\n<!-- multi-review: %s · round 2/10 -->\n' "$2" > "$p"
  echo "$p"
}

# --- Finding 3 fixture: a scratch copy of the SUT with an extra provider ("ghost") registered
# in provider_row but deliberately left unhandled in cmd_check/cmd_command's own case
# statements — reproduces "a provider added to the registry without a matching dispatch arm"
# without needing to touch the real registry. Inserted right after the real `gemini)` arm.
UNHANDLED="${WORK}/reviewer-unhandled.sh"
awk '{print} /gemini\) echo "gemini\|google\|shell/{print "    ghost)  echo \"ghost|nowhere|shell|ghost-model|no\" ;;"}' \
  "$SUT" > "$UNHANDLED"
grep -q '^    ghost)' "$UNHANDLED" || { echo "FIXTURE SETUP FAILED: ghost arm not inserted"; exit 1; }

# --- resolve: --reviewer is required (no singular env default, no implicit provider) ---
err="$(bash "$SUT" resolve 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 2 ]] && ok "resolve with no --reviewer exits 2" || bad "resolve no-flag rc=$rc (want 2)"
grep -qi 'required' <<<"$err" && ok "resolve no-flag error explains --reviewer is required" \
  || bad "resolve no-flag error unclear: '$err'"

# --- resolve: codex's own default model is overridable (nothing is unoverridable) ---
out="$(bash "$SUT" resolve --reviewer codex 2>/dev/null)"; rc=$?
[[ "$rc" == 0 ]] && ok "resolve --reviewer codex exits 0" || bad "resolve rc=$rc (want 0)"
[[ "$out" == "codex|openai|subagent|gpt-5.5|yes" ]] \
  && ok "codex falls back to its documented default model" || bad "codex default row was '$out'"
out="$(MULTI_REVIEW_REVIEWER_MODEL=gpt-9-turbo bash "$SUT" resolve --reviewer codex 2>/dev/null)"
[[ "$out" == "codex|openai|subagent|gpt-9-turbo|yes" ]] \
  && ok "MULTI_REVIEW_REVIEWER_MODEL overrides the codex default" || bad "codex override row was '$out'"

# --- resolve: gemini is shell-kind, google, skill-less, defaulted to the latest pro alias ---
out="$(bash "$SUT" resolve --reviewer gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell|gemini-pro-latest|no" ]] \
  && ok "gemini defaults to gemini-pro-latest (published alias, not a pinned version)" \
  || bad "gemini row was '$out'"

# --- resolve: MULTI_REVIEW_REVIEWER_MODEL pins the model for CLI-backed providers ---
out="$(MULTI_REVIEW_REVIEWER_MODEL=gemini-3-pro bash "$SUT" resolve --reviewer gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell|gemini-3-pro|no" ]] \
  && ok "MULTI_REVIEW_REVIEWER_MODEL pins the gemini model" || bad "pinned row was '$out'"

# --- resolve: unknown provider -> exit 2 with a named reason ---
err="$(bash "$SUT" resolve --reviewer nope 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 2 ]] && ok "unknown provider exits 2" || bad "unknown provider rc=$rc (want 2)"
grep -q 'nope' <<<"$err" && ok "unknown-provider error names the bad id" || bad "error did not name the id: '$err'"

# --- usage: no subcommand -> exit 2 ---
bash "$SUT" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "missing subcommand exits 2" || bad "missing subcommand rc=$rc (want 2)"

# --- usage: a flag with no value is an ERROR, not a silent fallback to the default. ---
# --- (Written as a hang-safe probe: an unguarded `shift 2 || true` parser would spin ---
# --- forever here rather than fail, so the background+kill wrapper turns a hang into ---
# --- a visible failure instead of a stuck suite.)                                     ---
( bash "$SUT" resolve --reviewer >/dev/null 2>&1; echo "$?" > "${WORK}/rc.flag" ) &
probe=$!
( sleep 5; kill -9 "$probe" 2>/dev/null ) & killer=$!
wait "$probe" 2>/dev/null
kill "$killer" 2>/dev/null
rc="$(cat "${WORK}/rc.flag" 2>/dev/null || echo TIMEOUT)"
[[ "$rc" == 2 ]] && ok "--reviewer with no value exits 2" \
  || bad "--reviewer with no value rc=$rc (want 2; TIMEOUT means the arg parser looped)"

# --- Finding 4 regression: the arity-error die must not be followed by a second, ---
# --- contradictory "unknown reviewer provider: " (empty id) message. `resolve_id`'s die ---
# --- runs inside resolve_row's command substitution, so an unguarded caller falls ---
# --- through with id="" and layers a misleading second error on top of the real one. ---
err="$(bash "$SUT" resolve --reviewer 2>&1 >/dev/null)"
[[ "$(grep -c 'requires a value' <<<"$err")" == 1 ]] \
  && ok "resolve --reviewer (no value) reports the arity error exactly once" \
  || bad "arity error line count wrong: '$err'"
grep -qi 'unknown reviewer provider' <<<"$err" \
  && bad "resolve --reviewer (no value) ALSO emits the contradictory 'unknown reviewer provider' message: '$err'" \
  || ok "no contradictory 'unknown reviewer provider' message follows the arity error"
[[ "$(wc -l <<<"$err" | tr -d ' ')" == 1 ]] \
  && ok "resolve --reviewer (no value) prints exactly one error line" \
  || bad "expected exactly one error line, got: '$err'"

# --- check: fable always passes (in-harness, zero external dependencies) ---
bash "$SUT" check --reviewer fable >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "check fable exits 0 (no external dependency)" || bad "check fable rc=$rc (want 0)"

# --- check: a CLI-backed provider fails with a non-empty reason when the CLI is absent ---
# Simulating "CLI absent" needs care on two counts, both verified:
#   1. `PATH=<empty> bash …` cannot find `bash` itself (assignments apply to the lookup),
#      so the probe would die with 127 before reaching the SUT. Invoke /bin/bash by
#      absolute path instead.
#   2. A wholly empty PATH also hides the SUT's OWN toolchain (`cut`, used by `field`),
#      so `check` would misbehave for an unrelated reason. Keep /usr/bin:/bin on PATH and
#      rely on the CLIs living elsewhere (e.g. /opt/homebrew/bin).
EMPTY="${WORK}/emptybin"; mkdir -p "$EMPTY"
SANDBOX_PATH="${EMPTY}:/usr/bin:/bin"

for p in gemini codex; do
  if PATH="$SANDBOX_PATH" command -v "$p" >/dev/null 2>&1; then
    # Cannot simulate absence on this machine; say so rather than assert something false.
    ok "SKIP check($p) absence case — $p is installed in a system dir on this machine"
  else
    err="$(PATH="$SANDBOX_PATH" /bin/bash "$SUT" check --reviewer "$p" 2>&1 >/dev/null)"; rc=$?
    [[ "$rc" == 1 ]] && ok "check $p exits 1 when the CLI is absent" || bad "check $p rc=$rc (want 1)"
    [[ -n "$err" ]] && ok "check $p failure reason is non-empty" || bad "check $p reason was empty"
    grep -qi "$p" <<<"$err" && ok "check $p reason names the missing CLI" || bad "reason did not name $p: '$err'"
  fi
done

# --- check: a CLI-backed provider passes when the CLI IS present ---
FAKE="${WORK}/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\nexit 0\n' > "${FAKE}/gemini"; chmod +x "${FAKE}/gemini"
PATH="${FAKE}:$PATH" bash "$SUT" check --reviewer gemini >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "check gemini exits 0 when the CLI is on PATH" || bad "check gemini(present) rc=$rc (want 0)"

# --- check: unknown provider is still a usage error ---
bash "$SUT" check --reviewer nope >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "check with unknown provider exits 2" || bad "check unknown rc=$rc (want 2)"

# --- Finding 3 regression: check fails CLOSED (not "dispatchable") for a provider that is ---
# --- registered but has no matching arm in check's own case statement (uses the "ghost" ---
# --- fixture above) ---
err="$(bash "$UNHANDLED" check --reviewer ghost 2>&1 >/dev/null)"; rc=$?
[[ "$rc" != 0 ]] && ok "check fails closed for a provider unhandled in its own case (rc=$rc)" \
  || bad "check reported dispatchable (rc=0) for an unhandled provider — fails OPEN"
grep -qi 'ghost' <<<"$err" && ok "check's fail-closed error names the unhandled provider" \
  || bad "check's fail-closed error did not name the provider: '$err'"

# --- prompt: codex output is BYTE-IDENTICAL to the pre-change emitter ---
D="$(mkdoc spec.md awaiting-reviewer)"
# Byte-identity is locked against a checked-in golden captured from the original emitter.
# The doc path is normalized to @@DOC@@ because it varies per machine.
new="$(bash "$SUT" prompt "$D" --reviewer codex 2>/dev/null | sed "s|$(cd "$(dirname "$D")" && pwd -P)/$(basename "$D")|@@DOC@@|g")"
golden="$(cat "${DIR}/fixtures/codex-prompt.golden.txt")"
[[ "$new" == "$golden" ]] && ok "codex prompt matches the golden fixture byte-for-byte" \
  || { bad "codex prompt drifted from the golden"; diff <(echo "$golden") <(echo "$new") | head -20; }

# --- prompt: the canonical ABSOLUTE path is the rendezvous, for every provider ---
abs="$(cd "$(dirname "$D")" && pwd -P)/$(basename "$D")"
for p in codex fable gemini; do
  out="$(bash "$SUT" prompt "$D" --reviewer "$p" 2>/dev/null)"
  grep -qF "$abs" <<<"$out" && ok "prompt($p) carries the absolute doc path" \
    || bad "prompt($p) missing the absolute doc path"
done

# --- prompt: skill-bearing provider points at the skill; skill-less ones do NOT ---
out="$(bash "$SUT" prompt "$D" --reviewer codex 2>/dev/null)"
grep -qi 'multi-review skill' <<<"$out" && ok "codex prompt references its skill" || bad "codex skill reference missing"

# --- prompt: skill-less providers get an ACTIONABLE read-then-act instruction, ---
# --- not merely a path (a bare path would satisfy a substring check and be useless) ---
for p in fable gemini; do
  out="$(bash "$SUT" prompt "$D" --reviewer "$p" 2>/dev/null)"
  grep -qiE 'read the protocol contract in full' <<<"$out" \
    && ok "prompt($p) instructs reading the protocol" || bad "prompt($p) lacks the read instruction"
  grep -qF 'protocol/multi-review.md' <<<"$out" \
    && ok "prompt($p) names the protocol file" || bad "prompt($p) lacks the protocol path"
  # No reference to a skill ANYWHERE in a skill-less prompt — not just the exact phrase
  # "multi-review skill". The shared body used to say "the protocol your skill defines",
  # which a narrower check would have missed while the reviewer got contradictory orders.
  # Word-boundary match (not a bare substring): the real bundled protocol doc necessarily
  # lives under .agents/skills/multi-review/... (Claude Code's skill-discovery layout), so a
  # bare 'skill' substring check would false-positive on that legitimate path segment while
  # still catching any actual prose reference such as "your skill" or "skill-less".
  ! grep -qiE '\bskill\b' <<<"$out" \
    && ok "prompt($p) contains no skill reference at all" || bad "prompt($p) still mentions a skill it lacks"
  grep -qi 'protocol contract you just read' <<<"$out" \
    && ok "prompt($p) points the reviewer at the contract it was told to read" \
    || bad "prompt($p) does not name the protocol contract as the mode authority"
done

# --- prompt: never hardcodes the RETIRED asymmetric/peer-review grammar (superseded by star) ---
for p in codex fable gemini; do
  out="$(bash "$SUT" prompt "$D" --reviewer "$p" 2>/dev/null)"
  ! grep -qF '[reviewer:' <<<"$out" && ! grep -qF '[concur:' <<<"$out" \
    && ok "prompt($p) does not hardcode retired mode grammar" || bad "prompt($p) hardcodes retired mode grammar"
done

# --- prompt: star is the ONE review model — no mode to detect, no asymmetric/peer-review wording ---
for p in codex fable gemini; do
  out="$(bash "$SUT" prompt "$D" --reviewer "$p" 2>/dev/null)"
  ! grep -qiE 'asymmetric|peer-review|determine which mode' <<<"$out" \
    && ok "prompt($p) has no asymmetric/peer-review/mode-detection wording" \
    || bad "prompt($p) still references a retired review mode: $(grep -oiE 'asymmetric|peer-review|determine which mode' <<<"$out")"
done

# --- prompt: the star finding grammar is stated unconditionally — severity + risk required on ---
# --- EVERY finding, no local-doc-vs-PR distinction (this is the fix for the whole-branch-review ---
# --- finding: the old prompt gated the sev/risk requirement on "peer-review (PR) mode", which ---
# --- contradicts multi-review-star.sh's _table, which hard-fails ANY finding missing either) ---
for p in codex fable gemini; do
  out="$(bash "$SUT" prompt "$D" --reviewer "$p" 2>/dev/null)"
  grep -qF '[finding:<id>|<sev>]' <<<"$out" \
    && ok "prompt($p) states the star finding grammar" || bad "prompt($p) missing the star finding grammar"
  grep -qF '`> — risk:' <<<"$out" \
    && ok "prompt($p) requires the risk line" || bad "prompt($p) missing the required risk line"
  grep -qi 'required on' <<<"$out" && grep -qi 'every finding' <<<"$out" \
    && ok "prompt($p) requires severity unconditionally on every finding" \
    || bad "prompt($p) does not require severity on every finding"
  grep -qiE 'no mode to.?detect' <<<"$out" \
    && ok "prompt($p) states there is no mode to detect" || bad "prompt($p) doesn't say there is no mode to detect"
done

# --- prompt: usage errors and read-only guarantee ---
bash "$SUT" prompt >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "prompt with no doc exits 2" || bad "prompt no-arg rc=$rc (want 2)"
bash "$SUT" prompt "${WORK}/nope.md" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "prompt with a missing doc exits 2" || bad "prompt missing-doc rc=$rc (want 2)"
before="$(cat "$D")"
bash "$SUT" prompt "$D" --reviewer gemini >/dev/null 2>&1
[[ "$(cat "$D")" == "$before" ]] && ok "prompt does not touch the doc" || bad "prompt modified the doc"

# --- command: refuses subagent-kind providers (they need the Agent tool, not a shell) ---
for p in codex fable; do
  err="$(bash "$SUT" command "$D" --reviewer "$p" 2>&1 >/dev/null)"; rc=$?
  [[ "$rc" == 2 ]] && ok "command refuses subagent-kind provider $p" || bad "command($p) rc=$rc (want 2)"
  [[ -n "$err" ]] && ok "command($p) refusal has a reason" || bad "command($p) refusal reason empty"
done

# --- command: shell-kind emits argv whose first element is the CLI ---
# --- A command substitution CANNOT carry NUL bytes — bash drops or truncates them, so ---
# --- `out="$(… command …)"` would silently destroy the delimiters and the assertion    ---
# --- could pass while testing nothing. Redirect to a file and read one NUL-terminated  ---
# --- field instead.                                                                     ---
bash "$SUT" command "$D" --reviewer gemini > "${WORK}/argv.bin" 2>/dev/null
first=""; IFS= read -r -d '' first < "${WORK}/argv.bin"
[[ "$first" == "gemini" ]] && ok "command(gemini) argv[0] is the gemini CLI" || bad "argv[0] was '$first'"
# the raw stream really is NUL-delimited (guards against a space-joined regression)
nuls="$(tr -dc '\0' < "${WORK}/argv.bin" | wc -c | tr -d ' ')"
[[ "$nuls" == "7" ]] && ok "argv stream carries exactly 7 NUL delimiters (gemini -m M --approval-mode auto_edit -p P)" || bad "NUL count was '$nuls' (want 7)"

# --- command: NUL round-trip through the BASH 3.2-SAFE consumer, with a spaced path ---
# --- and a prompt containing newlines and quotes. Run under /bin/bash (3.2 on macOS) so a ---
# --- bash 4+ construct cannot silently re-enter the shell-kind caller.                    ---
SPACED="${WORK}/Work Projects"; mkdir -p "$SPACED"
DS="${SPACED}/spec doc.md"
printf '# T\n\n<!-- multi-review: awaiting-reviewer · round 2/10 -->\n' > "$DS"
cat > "${WORK}/consume.sh" <<'CONSUMER'
#!/bin/bash
SUT="$1"; DOC="$2"
argv=()
while IFS= read -r -d '' a; do argv+=("$a"); done < <(bash "$SUT" command "$DOC" --reviewer gemini)
echo "count=${#argv[@]}"
i=0; for a in "${argv[@]}"; do i=$((i+1)); printf 'ARG%s<%s>\n' "$i" "$a"; done
CONSUMER
rt="$(/bin/bash "${WORK}/consume.sh" "$SUT" "$DS" 2>/dev/null)"; rc=$?
[[ "$rc" == 0 ]] && ok "NUL argv round-trip runs under /bin/bash (3.2-safe)" || bad "3.2 consumer rc=$rc"
grep -q '^count=7$' <<<"$rt" && ok "round-trip yields exactly 7 argv elements" || bad "argv count wrong: $(grep '^count=' <<<"$rt")"
grep -qF "${DS}" <<<"$rt" && ok "spaced doc path survives the round-trip intact" || bad "spaced path mangled in round-trip"
grep -qF 'Do ONE reviewer turn' <<<"$rt" && ok "multi-line prompt survives as one argv element" || bad "prompt element mangled"
grep -qF '`> — via <your-model-id>`' <<<"$rt" && ok "quote/backtick characters survive intact" || bad "quote characters mangled"

# --- command: usage errors ---
bash "$SUT" command >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "command with no doc exits 2" || bad "command no-arg rc=$rc (want 2)"
bash "$SUT" command "${WORK}/nope.md" --reviewer gemini >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "command with a missing doc exits 2" || bad "command missing-doc rc=$rc (want 2)"

# --- Finding 3 regression: command fails CLOSED (not silently empty argv) for a shell-kind ---
# --- provider that is registered but has no matching arm in command's own case statement ---
# --- (uses the "ghost" fixture above; ghost is registered as shell-kind so it clears the ---
# --- subagent-kind refusal above and reaches the unhandled case arm). ---
err="$(bash "$UNHANDLED" command "$D" --reviewer ghost 2>&1 >/dev/null)"; rc=$?
[[ "$rc" != 0 ]] && ok "command fails closed for a provider unhandled in its own case (rc=$rc)" \
  || bad "command exited 0 (silently empty argv) for an unhandled provider — fails OPEN"
grep -qi 'ghost' <<<"$err" && ok "command's fail-closed error names the unhandled provider" \
  || bad "command's fail-closed error did not name the provider: '$err'"

# --- command: model-pin branch (MULTI_REVIEW_REVIEWER_MODEL set) ---
# When MULTI_REVIEW_REVIEWER_MODEL is set, the argv includes -m <model> flags.
MULTI_REVIEW_REVIEWER_MODEL=gemini-3-pro bash "$SUT" command "$D" --reviewer gemini > "${WORK}/argv-pinned.bin" 2>/dev/null
argv_pinned=()
while IFS= read -r -d '' a; do argv_pinned+=("$a"); done < "${WORK}/argv-pinned.bin"
[[ ${#argv_pinned[@]} -eq 7 ]] && ok "command(gemini, model-pinned) emits exactly 7 argv elements" \
  || bad "argv element count was ${#argv_pinned[@]} (want 7)"
[[ "${argv_pinned[0]}" == "gemini" ]] && ok "pinned argv[0] is the gemini CLI" || bad "pinned argv[0] was '${argv_pinned[0]}'"
[[ "${argv_pinned[1]}" == "-m" ]] && ok "pinned argv[1] is -m flag" || bad "pinned argv[1] was '${argv_pinned[1]}'"
[[ "${argv_pinned[2]}" == "gemini-3-pro" ]] && ok "pinned argv[2] is the model" || bad "pinned argv[2] was '${argv_pinned[2]}'"
nuls_pinned="$(tr -dc '\0' < "${WORK}/argv-pinned.bin" | wc -c | tr -d ' ')"
[[ "$nuls_pinned" == "7" ]] && ok "pinned argv stream carries exactly 7 NUL terminators (7 elements)" \
  || bad "pinned NUL count was '$nuls_pinned' (want 7)"

# --- vendor-of-model: exposes the vendor table directly ---
out="$(bash "$SUT" vendor-of-model claude-opus-4-8 2>/dev/null)"; [[ "$out" == "anthropic" ]] && ok "vendor-of-model: claude->anthropic" || bad "vendor-of-model claude (got '$out')"
out="$(bash "$SUT" vendor-of-model gpt-5.5 2>/dev/null)"; [[ "$out" == "openai" ]] && ok "vendor-of-model: gpt->openai" || bad "vendor-of-model gpt (got '$out')"

# --- verify-vendor fixtures: <base> is the pre-dispatch snapshot, <doc> the post-turn file ---
mkpair() { # mkpair <name> <base-extra-lines> <new-extra-lines>; prints "base|doc"
  local b="${WORK}/$1.base.md" d="${WORK}/$1.doc.md"
  printf '# T\n\n<!-- multi-review: awaiting-reviewer · round 2/10 -->\n\n%b' "$2" > "$b"
  printf '# T\n\n<!-- multi-review: awaiting-author · round 2/10 -->\n\n%b%b' "$2" "$3" > "$d"
  echo "${b}|${d}"
}

# in-vendor but NOT exact-id: provider codex pinned to gpt-5.5, reviewer discloses gpt-5-codex
P="$(mkpair invendor '' '> [reviewer:r1] x\n> — via gpt-5-codex\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor passes in-vendor non-exact id (gpt-5.5 -> gpt-5-codex)" \
  || bad "verify-vendor in-vendor rc=$rc (want 0)"

# out-of-vendor: provider codex, reviewer discloses a Claude id (the real observed drift)
P="$(mkpair drift '' '> [reviewer:r1] x\n> — via claude-sonnet-4-6\n')"
err="$(bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor fails on out-of-vendor drift" || bad "verify-vendor drift rc=$rc (want 1)"
grep -qF 'claude-sonnet-4-6' <<<"$err" && ok "drift error names the offending id" || bad "offending id not named: '$err'"

# NO author-id exemption: a new line carrying the AUTHOR's own id must still FAIL for codex
P="$(mkpair authorid '' '> [reviewer:r1] x\n> — via claude-opus-4-8\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor fails on a new line bearing the author's own id" \
  || bad "author-id exemption leaked back in (rc=$rc, want 1)"

# lawful mid-review provider switch: OLD gpt lines in the baseline are ignored;
# only the NEW gemini line is judged, against provider gemini
P="$(mkpair switch '> [reviewer:r1] old\n> — via gpt-5-codex\n' '> [reviewer:r2] new\n> — via gemini-3-pro\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer gemini >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor ignores pre-existing out-of-vendor lines (lawful switch)" \
  || bad "lawful provider switch was flagged as drift (rc=$rc, want 0)"

# REPEATED id: baseline already contains gpt-5-codex; the turn adds ANOTHER one while the
# provider is gemini. A unique-set diff would report nothing and pass — this must FAIL.
P="$(mkpair repeat '> [reviewer:r1] old\n> — via gpt-5-codex\n' '> [reviewer:r2] new\n> — via gpt-5-codex\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer gemini >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor catches a REPEATED out-of-vendor id (multiset diff)" \
  || bad "repeated out-of-vendor id slipped through (rc=$rc, want 1) — set diff instead of multiset?"

# an UNMAPPABLE new id is a MISMATCH, not a pass
P="$(mkpair unmappable '' '> [reviewer:r1] x\n> — via mystery-model\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor treats an unmappable id as a mismatch" || bad "unmappable id passed (rc=$rc, want 1)"

# no new disclosures at all -> nothing to judge -> pass
P="$(mkpair nonew '> [reviewer:r1] old\n> — via gpt-5-codex\n' '')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor passes when the turn added no disclosures" || bad "no-new-lines rc=$rc (want 0)"

# fenced examples are NOT protocol lines (documentation must not trip the check)
P="$(mkpair fenced '' '```text\n> — via claude-sonnet-4-6\n```\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor ignores disclosure-shaped lines inside fenced blocks" \
  || bad "fenced example tripped the check (rc=$rc, want 0)"

# --baseline is REQUIRED: absence is a usage error, never a silent whole-doc scan
P="$(mkpair nobase '' '> [reviewer:r1] x\n> — via gpt-5-codex\n')"
bash "$SUT" verify-vendor "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "verify-vendor without --baseline exits 2" || bad "missing --baseline rc=$rc (want 2)"
bash "$SUT" verify-vendor --baseline "${WORK}/nope.md" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "verify-vendor with a missing baseline file exits 2" || bad "bad baseline rc=$rc (want 2)"

# --- security fix: verify-vendor fence handling must match multi-review-core.sh, and a turn ---
# --- that adds findings with no usable disclosure must fail, not pass silently ---

# FINDING 1 case A: an unterminated fence must fail closed (die 1), not silently swallow every
# line after it — including the disclosure that would have failed the identity check.
P="$(mkpair unterminated-fence '' '```\n> [reviewer:r1] x\n> — via claude-sonnet-4-6\n')"
err="$(bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor fails closed on an unterminated fence" \
  || bad "unterminated fence rc=$rc (want 1)"
grep -qi 'unterminated' <<<"$err" && ok "unterminated-fence error names the problem" || bad "error unclear: '$err'"

# FINDING 1 case G: a 4-space-indented ``` is NOT a fence per CommonMark (matches
# multi-review-core.sh's strip_fences, which would report r1 as a LIVE open thread here) — the
# enclosed disclosure must stay VISIBLE and be judged normally, so the out-of-vendor id inside
# it is a real mismatch, not a hidden pass.
P="$(mkpair indented-fence '' '    ```\n> [reviewer:r1] x\n> — via claude-sonnet-4-6\n    ```\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor treats a 4-space-indented fence as NOT a fence (disclosure judged)" \
  || bad "indented-fence rc=$rc (want 1) — naive parity toggle swallowed the disclosure?"

# Regression: a WELL-FORMED, unindented fence (marker line AND disclosure both inside) must
# still be ignored entirely — the fence-rule fix must not turn this into a false mismatch or a
# false "findings, no disclosure" failure.
P="$(mkpair wellformed-fence '' '```text\n> [reviewer:r1] x\n> — via claude-sonnet-4-6\n```\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor still ignores a well-formed fenced example (no regression)" \
  || bad "well-formed fence regressed (rc=$rc, want 0)"

# FINDING 2: a turn that adds protocol comments but ZERO usable disclosures must fail, not pass
# silently — omitting a disclosure must not be an easier bypass than faking one.
P="$(mkpair no-disclosure '' '> [reviewer:r1] x\n')"
err="$(bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor fails when the turn adds findings with no disclosure at all" \
  || bad "no-disclosure rc=$rc (want 1)"
[[ -n "$err" ]] && ok "no-disclosure failure has a reason" || bad "no-disclosure reason was empty"

# FINDING 2 variant: an ASCII hyphen ('> - via ...') is not the required em dash — this must be
# judged the same as "no disclosure", not accepted as one.
P="$(mkpair ascii-hyphen '' '> [reviewer:r1] x\n> - via claude-sonnet-4-6\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor rejects an ASCII-hyphen '- via' as a fake disclosure" \
  || bad "ascii-hyphen rc=$rc (want 1)"

# FINDING 2 variant: an en dash ('–', U+2013) is not the required em dash ('—', U+2014).
P="$(mkpair endash '' '> [reviewer:r1] x\n> – via claude-sonnet-4-6\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor rejects an en-dash '– via' as a fake disclosure" \
  || bad "en-dash rc=$rc (want 1)"

# FINDING 2 variant: '> — via' with an empty id is not a usable disclosure.
P="$(mkpair emptyid '' '> [reviewer:r1] x\n> — via \n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor rejects '> — via' with an empty id" \
  || bad "empty-id rc=$rc (want 1)"

# --- FALSE POSITIVE fix: protocol_lines did a full-LINE diff, so rewording an existing
# --- protocol line's prose (same identity, same disclosure) was counted as a NEWLY ADDED
# --- protocol comment and failed the "no usable disclosure" check even though nothing new
# --- was added. The diff must be on the line's IDENTITY KEY (role:id), not the full text.
RB="${WORK}/reword.base.md"; RD="${WORK}/reword.doc.md"
printf '# T\n\n<!-- multi-review: awaiting-reviewer · round 2/10 -->\n\n> [reviewer:r1] typo\n> — via gpt-5-codex\n' > "$RB"
printf '# T\n\n<!-- multi-review: awaiting-author · round 2/10 -->\n\n> [reviewer:r1] typo fixed\n> — via gpt-5-codex\n' > "$RD"
bash "$SUT" verify-vendor --baseline "$RB" "$RD" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor passes when an existing finding's prose is merely reworded" \
  || bad "reworded-prose false positive (rc=$rc, want 0)"

# Same identity-key fix: a bare trailing space added to an existing protocol line (same
# identity, same disclosure) must not read as a new protocol comment either.
SB="${WORK}/trailspace.base.md"; SD="${WORK}/trailspace.doc.md"
printf '# T\n\n<!-- multi-review: awaiting-reviewer · round 2/10 -->\n\n> [reviewer:r1] typo\n> — via gpt-5-codex\n' > "$SB"
printf '# T\n\n<!-- multi-review: awaiting-author · round 2/10 -->\n\n> [reviewer:r1] typo \n> — via gpt-5-codex\n' > "$SD"
bash "$SUT" verify-vendor --baseline "$SB" "$SD" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "verify-vendor passes when a trailing space is added to an existing protocol line" \
  || bad "trailing-space false positive (rc=$rc, want 0)"

# Non-regression: a GENUINELY NEW protocol comment (new id) with no usable disclosure must
# still fail — the identity-key fix must not swallow real undisclosed additions.
P="$(mkpair newfinding-nodisc '> [reviewer:r1] x\n> — via gpt-5-codex\n' '> [reviewer:r2] y\n')"
bash "$SUT" verify-vendor --baseline "${P%|*}" "${P#*|}" --reviewer codex >/dev/null 2>&1; rc=$?
[[ "$rc" == 1 ]] && ok "verify-vendor still fails on a genuinely new undisclosed protocol comment" \
  || bad "new undisclosed comment slipped through (rc=$rc, want 1)"

# --- vendor mapping accepts the BARE provider-family ids some CLIs disclose ---
# Gemini CLI discloses `gemini` (no version suffix); a `gemini-*`-only pattern leaves that
# unmappable, and verify-vendor treats unmappable as a mismatch — so the whole route fails.
for id in gemini gemini-3-pro gemini-2.5-flash; do
  out="$(bash "$SUT" vendor-of-model "$id" 2>/dev/null)"
  [[ "$out" == "google" ]] && ok "vendor mapping: '$id' -> google" \
    || bad "vendor mapping: '$id' unmapped -> '$out'"
done

# --- gemini argv must carry an edit-approval flag (the analogue of codex --write) ---
# Without it, `gemini -p` runs non-interactively with approval mode `default`, i.e. "prompt
# for approval" — and with nobody to prompt, file-modification tools are disabled. Observed
# live: the reviewer emitted its findings as TEXT and never touched the doc, so the marker
# never flipped. auto_edit (not yolo) approves edit tools only, never shell.
bash "$SUT" command "$D" --reviewer gemini > "${WORK}/argv-approval.bin" 2>/dev/null
appr=(); while IFS= read -r -d '' a; do appr+=("$a"); done < "${WORK}/argv-approval.bin"
printf '%s\n' "${appr[@]}" | grep -qx -- '--approval-mode' \
  && ok "gemini argv carries --approval-mode" || bad "gemini argv lacks --approval-mode"
printf '%s\n' "${appr[@]}" | grep -qx -- 'auto_edit' \
  && ok "gemini approval mode is auto_edit (edit tools only, not yolo)" \
  || bad "gemini approval mode is not auto_edit: ${appr[*]}"
! printf '%s\n' "${appr[@]}" | grep -qx -- 'yolo' \
  && ok "gemini argv does NOT use yolo (would auto-approve shell too)" || bad "gemini argv uses yolo"

# --- vendor mapping: bare OpenAI reasoning model ids (codex's own help uses `model="o3"`) ---
for id in o1 o3 o1-preview o3-mini; do
  out="$(bash "$SUT" vendor-of-model "$id" 2>/dev/null)"
  [[ "$out" == "openai" ]] && ok "vendor mapping: '$id' -> openai" \
    || bad "vendor mapping: '$id' unmapped -> '$out'"
done

# --- advisory check: gemini (Task 1) ---
# Deterministic env: no ambient GEMINI_* leaking in (this repo's maintainer exports the trust var).
unset GEMINI_API_KEY GEMINI_CLI_TRUST_WORKSPACE
# stub gemini on PATH so `command -v gemini` passes without the real CLI
GBIN="${WORK}/gbin"; mkdir -p "$GBIN"; printf '#!/usr/bin/env bash\necho OK\n' > "$GBIN/gemini"; chmod +x "$GBIN/gemini"
# a temp git repo controls repo_root() + workspace files + HOME(~/.gemini)
GREPO="${WORK}/grepo"; mkdir -p "$GREPO"; ( cd "$GREPO" && git init -q )

# nothing configured -> exit 0 with all three hints
out="$(cd "$GREPO" && HOME="$GREPO/home" PATH="${GBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "check gemini: advisory keeps exit 0" || bad "check gemini exit $rc (want 0)"
grep -qi 'trust' <<<"$out" && grep -qi 'API key' <<<"$out" && grep -qi 'respectGitIgnore' <<<"$out" \
  && ok "check gemini: emits trust+key+gitignore hints when unconfigured" || bad "gemini hints missing: '$out'"

# fully configured -> exit 0, NO hints
mkdir -p "$GREPO/home/.gemini" && printf 'GEMINI_API_KEY=fake-secret-value\n' > "$GREPO/home/.gemini/.env"
mkdir -p "$GREPO/.gemini" && printf '{"context":{"fileFiltering":{"respectGitIgnore":false}}}\n' > "$GREPO/.gemini/settings.json"
out="$(cd "$GREPO" && HOME="$GREPO/home" GEMINI_CLI_TRUST_WORKSPACE=true PATH="${GBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "check gemini: no hints when fully configured" || bad "gemini configured had hints: '$out'"

# whitespace-tolerant gitignore match: spaces/newlines still detected -> no gitignore hint
printf '{\n  "context": {\n    "fileFiltering": { "respectGitIgnore" : false }\n  }\n}\n' > "$GREPO/.gemini/settings.json"
out="$(cd "$GREPO" && HOME="$GREPO/home" GEMINI_CLI_TRUST_WORKSPACE=true PATH="${GBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qi 'respectGitIgnore' <<<"$out" && bad "gitignore hint fired despite valid (spaced) setting" || ok "check gemini: gitignore match is whitespace-tolerant"

# key in a workspace .env (not ~/.gemini) also counts -> no key hint
rm -f "$GREPO/home/.gemini/.env"; printf 'GEMINI_API_KEY=fake-secret-value\n' > "$GREPO/.env"
out="$(cd "$GREPO" && HOME="$GREPO/home" GEMINI_CLI_TRUST_WORKSPACE=true PATH="${GBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qi 'API key' <<<"$out" && bad "key hint fired despite workspace .env" || ok "check gemini: workspace .env counts as a key source"

# hints NEVER print the secret value
grep -qF 'fake-secret-value' <<<"$out" && bad "check leaked the key value" || ok "check gemini: no secret value in output"

# CLI absent -> hard gate exit 1 (unchanged)
( cd "$GREPO" && HOME="$GREPO/home" PATH="/usr/bin:/bin" bash "$SUT" check --reviewer gemini >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && ok "check gemini: CLI absent still exit 1" || bad "gemini absent rc=$rc (want 1)"

# fable arm is unchanged: exit 0 with NO output (doctor's "fable ready" rests on this — fable-rd1-r1)
out="$(bash "$SUT" check --reviewer fable 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "check fable: exit 0, no output (unchanged)" || bad "check fable rc=$rc out='$out'"

# --- advisory check: codex skill dir (Task 4) ---
CBIN="${WORK}/cbin"; mkdir -p "$CBIN"; printf '#!/usr/bin/env bash\n:\n' > "$CBIN/codex"; chmod +x "$CBIN/codex"
CREPO="${WORK}/crepo"; mkdir -p "$CREPO"; ( cd "$CREPO" && git init -q )

# no skill dir: ready, no hint about copying
out="$(cd "$CREPO" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "codex check ready with no pre-copied skill" || bad "codex check rc=$rc"
grep -qi 'copy .*\.agents/skills' <<<"$out" && bad "obsolete copy hint still emitted" || ok "no obsolete copy hint"

# a tracked copy: drift advisory
rr_tracked="$(mktemp -d)"; git -C "$rr_tracked" init -q; mkdir -p "$rr_tracked/.agents/skills/multi-review"
echo x > "$rr_tracked/.agents/skills/multi-review/SKILL.md"; git -C "$rr_tracked" add -f .; git -C "$rr_tracked" -c user.email=t@t -c user.name=t commit -qm s
out="$(cd "$rr_tracked" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"
grep -qi 'drift' <<<"$out" && ok "tracked copy -> drift hint" || bad "no drift hint for tracked copy"

# repo-root resolution: from a SUBDIR with the tracked copy at the root -> still drift hint
mkdir -p "$rr_tracked/sub/dir"
out="$(cd "$rr_tracked/sub/dir" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"
grep -qi 'drift' <<<"$out" && ok "check codex: repo-root resolved from a subdirectory" || bad "codex subdir missed drift hint: '$out'"

# CLI absent -> exit 1 (unchanged)
( cd "$CREPO" && PATH="/usr/bin:/bin" bash "$SUT" check --reviewer codex >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && ok "check codex: CLI absent still exit 1" || bad "codex absent rc=$rc (want 1)"

# --- command: opt-in gemini auto-trust (Task 3) ---
unset MULTI_REVIEW_GEMINI_AUTOTRUST         # the default-argv case must not inherit an ambient value
DAT="${WORK}/at.md"; printf '# d\n' > "$DAT"
# default (unset) -> argv[0] gemini, 7 NULs (byte-identical to today)
bash "$SUT" command "$DAT" --reviewer gemini > "${WORK}/at0.bin" 2>/dev/null
first=""; IFS= read -r -d '' first < "${WORK}/at0.bin"
n0="$(tr -dc '\0' < "${WORK}/at0.bin" | wc -c | tr -d ' ')"
[[ "$first" == "gemini" && "$n0" == "7" ]] && ok "command gemini: default argv unchanged (gemini, 7 NUL)" || bad "default argv first='$first' nul=$n0"

# autotrust=1 -> argv prefixed with env GEMINI_CLI_TRUST_WORKSPACE=true, 9 NULs
MULTI_REVIEW_GEMINI_AUTOTRUST=1 bash "$SUT" command "$DAT" --reviewer gemini > "${WORK}/at1.bin" 2>/dev/null
argv=(); while IFS= read -r -d '' a; do argv+=("$a"); done < "${WORK}/at1.bin"
n1="$(tr -dc '\0' < "${WORK}/at1.bin" | wc -c | tr -d ' ')"
[[ "${argv[0]}" == "env" && "${argv[1]}" == "GEMINI_CLI_TRUST_WORKSPACE=true" && "${argv[2]}" == "gemini" && "$n1" == "9" ]] \
  && ok "command gemini: autotrust=1 prefixes 'env GEMINI_CLI_TRUST_WORKSPACE=true'" || bad "autotrust argv: ${argv[0]}/${argv[1]}/${argv[2]} nul=$n1"

# autotrust set to something other than 1 -> unchanged
MULTI_REVIEW_GEMINI_AUTOTRUST=yes bash "$SUT" command "$DAT" --reviewer gemini > "${WORK}/at2.bin" 2>/dev/null
first=""; IFS= read -r -d '' first < "${WORK}/at2.bin"
[[ "$first" == "gemini" ]] && ok "command gemini: autotrust!=1 leaves argv unchanged" || bad "autotrust!=1 first='$first'"

# --- doctor (Task 4) ---
unset GEMINI_API_KEY GEMINI_CLI_TRUST_WORKSPACE MULTI_REVIEW_GEMINI_AUTOTRUST
DREPO="${WORK}/drepo"; mkdir -p "$DREPO"; ( cd "$DREPO" && git init -q )
# stub gemini that replies instantly (probe -> OK) and codex present
DBIN="${WORK}/dbin"; mkdir -p "$DBIN"
printf '#!/usr/bin/env bash\necho OK\n' > "$DBIN/gemini"; chmod +x "$DBIN/gemini"
printf '#!/usr/bin/env bash\n:\n' > "$DBIN/codex"; chmod +x "$DBIN/codex"

# report EXITS 0 even with unconfigured providers, and lists every provider
out="$(cd "$DREPO" && HOME="$DREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "doctor: exits 0 even with unconfigured providers (report, not gate)" || bad "doctor rc=$rc (want 0)"
grep -q 'gemini' <<<"$out" && grep -q 'codex' <<<"$out" && grep -q 'fable' <<<"$out" \
  && ok "doctor: lists every provider" || bad "doctor missing a provider: '$out'"
grep -qi 'fable.*ready\|✓ fable' <<<"$out" && ok "doctor: fable shows ready" || bad "doctor fable line: '$out'"
# gemini probe is AUTHORITATIVE: even fully unconfigured, a PASSING probe -> ready, static hints
# suppressed (no contradictory "needs setup" for gemini) — codex-rd1-r2, fable-rd1-r5.
grep -qi 'gemini: ready' <<<"$out" && ok "doctor: passing probe -> gemini ready despite static hints" || bad "doctor gemini not ready: '$out'"
grep -qiE '△ gemini|gemini: needs setup' <<<"$out" && bad "doctor: gemini showed 'needs setup' despite a passing probe" || ok "doctor: no contradictory gemini needs-setup line"

# probe FAILS + unconfigured -> ✗ gemini with static hints shown as 'likely cause'
printf '#!/usr/bin/env bash\nexit 1\n' > "$DBIN/gemini"; chmod +x "$DBIN/gemini"
out="$(cd "$DREPO" && HOME="$DREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=5 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"
grep -qi 'likely cause' <<<"$out" && grep -qi 'trust\|API key' <<<"$out" \
  && ok "doctor: failing probe surfaces static hints as likely cause" || bad "doctor no likely-cause: '$out'"

# a slow stub + tiny timeout -> probe reports timed out, doctor still exits 0 (no hang)
printf '#!/usr/bin/env bash\nsleep 3\n' > "$DBIN/gemini"; chmod +x "$DBIN/gemini"
out="$(cd "$DREPO" && HOME="$DREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=1 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -qi 'timed out' <<<"$out" && ok "doctor: probe honors the bounded timeout (no hang)" || bad "doctor timeout (rc=$rc): '$out'"
# probe output is never echoed (redaction): stub prints a marker; doctor must not surface it
printf '#!/usr/bin/env bash\necho SENSITIVE_PROBE_STDOUT; exit 1\n' > "$DBIN/gemini"; chmod +x "$DBIN/gemini"
out="$(cd "$DREPO" && HOME="$DREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=5 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"
grep -qF 'SENSITIVE_PROBE_STDOUT' <<<"$out" && bad "doctor leaked raw probe output" || ok "doctor: probe output is redacted on failure"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
