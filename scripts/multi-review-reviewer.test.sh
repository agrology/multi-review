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
#
# The copy lives at <fixture-root>/scripts/ so its ROOT resolves to <fixture-root>, mirroring the
# real bundle layout: the SUT reads ROOT-relative assets (the protocol contract it now inlines
# into skill-less prompts), so a fixture dropped anywhere else would fail on a missing bundle
# rather than on the behavior under test.
FIXROOT="${WORK}/fixture-root"
mkdir -p "${FIXROOT}/scripts" "${FIXROOT}/.agents/skills/multi-review/protocol"
cp "$(cd "$(dirname "$SUT")/.." && pwd)/.agents/skills/multi-review/protocol/multi-review.md" \
   "${FIXROOT}/.agents/skills/multi-review/protocol/multi-review.md" \
  || { echo "FIXTURE SETUP FAILED: cannot stage protocol contract"; exit 1; }
UNHANDLED="${FIXROOT}/scripts/reviewer-unhandled.sh"
awk '{print} /gemini\) echo "gemini\|google\|shell/{print "    ghost)  echo \"ghost|nowhere|shell|ghost-model|no\" ;;"}' \
  "$SUT" > "$UNHANDLED"
grep -q '^    ghost)' "$UNHANDLED" || { echo "FIXTURE SETUP FAILED: ghost arm not inserted"; exit 1; }

# --- resolve: --reviewer is required (no singular env default, no implicit provider) ---
err="$(bash "$SUT" resolve 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 2 ]] && ok "resolve with no --reviewer exits 2" || bad "resolve no-flag rc=$rc (want 2)"
grep -qi 'required' <<<"$err" && ok "resolve no-flag error explains --reviewer is required" \
  || bad "resolve no-flag error unclear: '$err'"

# --- resolve: codex's own default model is overridable (nothing is unoverridable) ---
# Clear MULTI_REVIEW_REVIEWER_MODEL from the inherited env: the default-row assertion below
# must test the built-in default, not a value a developer happens to export in their shell.
out="$(env -u MULTI_REVIEW_REVIEWER_MODEL bash "$SUT" resolve --reviewer codex 2>/dev/null)"; rc=$?
[[ "$rc" == 0 ]] && ok "resolve --reviewer codex exits 0" || bad "resolve rc=$rc (want 0)"
[[ "$out" == "codex|openai|subagent|gpt-5.6-terra|yes" ]] \
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

# --- prompt: skill-less providers get the contract INLINE, never a path (issue #22) ---
# This assertion used to require the prompt to NAME `protocol/multi-review.md`. That encoded
# the bug: the path is rooted at the PLUGIN root, which under a normal install is
# ~/.claude/plugins/cache/... — always outside the reviewed repo. gemini-cli hard-refuses any
# read outside its workspace ("Path not in workspace"), so the one reviewer that is dispatched
# as an external CLI could never open the contract. Replaced deliberately, not weakened: the
# checks below are strictly stronger — the body must actually be present, and no filesystem
# path may stand in for it.
protocol_src="$(cd "$(dirname "$SUT")/.." && pwd)/.agents/skills/multi-review/protocol/multi-review.md"
[[ -f "$protocol_src" ]] || { echo "FIXTURE SETUP FAILED: protocol not at $protocol_src"; exit 1; }
for p in fable gemini; do
  out="$(bash "$SUT" prompt "$D" --reviewer "$p" 2>/dev/null)"
  grep -qiE 'read the protocol contract in full' <<<"$out" \
    && ok "prompt($p) instructs reading the protocol" || bad "prompt($p) lacks the read instruction"
  # (a) no path to the contract file at all — the reviewer must not be sent to the filesystem
  ! grep -qF 'protocol/multi-review.md' <<<"$out" \
    && ok "prompt($p) does not point at an out-of-workspace protocol path" \
    || bad "prompt($p) still hands the reviewer a protocol file path"
  # (b) the operative contract is really inlined — distinctive body lines, not a summary. Two
  # separate sections, so a partial/truncated inline fails.
  grep -qF 'awaiting-secondaries' <<<"$out" && grep -qF 'Copy marker' <<<"$out" \
    && ok "prompt($p) inlines the protocol body" || bad "prompt($p) lacks the inlined protocol body"
  # (c) the whole operative contract, not a prefix: the last section before `## Supersedes`
  # must be present too.
  grep -qF 'Secondaries touch no GitHub' <<<"$out" \
    && ok "prompt($p) inlines through the final operative section" \
    || bad "prompt($p) inline is truncated before the end of the contract"
  # (d) `## Supersedes` is retired-grammar history for repo readers. Inlining it would hand the
  # reviewer `[reviewer:]`/`[concur:]` — grammar it must NOT use. The retired-grammar
  # assertions further down are what enforce this; this one pins the cause.
  ! grep -qF '## Supersedes' <<<"$out" \
    && ok "prompt($p) omits the retired-grammar Supersedes section" \
    || bad "prompt($p) inlined the Supersedes section"
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

# ISSUE #52 — SOLVED. The intermittent macos/bash-3.2 failures here were never about the argv.
# The capture below caught a run where BOTH the reconstructed array and the raw NUL-delimited bytes
# were correct — argv[4] was literally `auto_edit` — while the assertion still failed. So the fault
# was in the assertion, which was written as:
#
#     printf '%s\n' "${appr[@]}" | grep -qx -- 'auto_edit'
#
# `grep -q` exits at the first match; `printf` still has argv[6] — the whole inlined protocol
# prompt — left to write, takes SIGPIPE, and `pipefail` turns that into 141. A SUCCESSFUL match is
# reported as a failure.
#
# It is buffer-sized, which is the entire reason it looked like a flake. The writer only takes
# SIGPIPE if it still has data pending when the reader exits, so the pipe buffer is the threshold:
# 16 KB on macOS, 64 KB on Linux. Measured on /bin/bash 3.2 — <=16 KB: 0/20 failures; 20 KB: 1/20;
# 40 KB: 3/20; 64 KB: 19/20; 100 KB: 20/20. The real gemini prompt is ~15.4 KB, sitting ON the macOS
# boundary, so it flipped on scheduling alone and would have hardened into a permanent failure as
# the inlined protocol text grew.
#
# NOTE FOR THE FUTURE: this hypothesis was recorded as "tested and refuted" and cost five days.
# A small fixture CANNOT refute it — under the buffer size it never reproduces. Reproduce at 100 KB.
#
# argv_has replaces the pipe entirely: no subshell, no reader, nothing to receive SIGPIPE. Exact
# whole-string equality, the same semantics `grep -qx` had.
argv_has() { # <want> <argv...> -> 0 if some element equals <want>
  local want="$1" a; shift
  for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done
  return 1
}

# Pins the property, not the incident: a membership check must not depend on how much data follows
# the match. With the old `printf | grep -q` idiom this fails outright at 100 KB (measured 20/20).
big_pad="$(head -c 100000 /dev/zero | tr '\0' 'x')"
pad_argv=(gemini -m gemini-pro-latest --approval-mode auto_edit -p "$big_pad")
argv_has 'auto_edit' "${pad_argv[@]}" \
  && ok "argv membership is independent of payload size (issue #52)" \
  || bad "argv membership failed with a large trailing element — SIGPIPE/pipefail regression (#52)"
argv_has 'no_such_token' "${pad_argv[@]}" \
  && bad "argv membership matched a token that is not present" \
  || ok "argv membership still rejects an absent token"

# The dump stays armed: it is what solved this, and it is the evidence for any future recurrence.
# ${WORK} is a mktemp dir removed by the EXIT trap, so it must be gathered IN ADVANCE of a red run.
argv52_capture() {
  echo "  [#52] parsed elements: ${#appr[@]}"
  local i=0 a
  for a in ${appr[@]+"${appr[@]}"}; do echo "  [#52] argv[$i]=<${a}>"; i=$((i + 1)); done
  echo "  [#52] raw bytes of argv-approval.bin:"
  od -c "${WORK}/argv-approval.bin" 2>&1 | sed 's/^/  [#52] /'
}

argv_has '--approval-mode' "${appr[@]}" \
  && ok "gemini argv carries --approval-mode" \
  || { bad "gemini argv lacks --approval-mode"; argv52_capture; }
argv_has 'auto_edit' "${appr[@]}" \
  && ok "gemini approval mode is auto_edit (edit tools only, not yolo)" \
  || { bad "gemini approval mode is not auto_edit"; argv52_capture; }
argv_has 'yolo' "${appr[@]}" \
  && { bad "gemini argv uses yolo"; argv52_capture; } \
  || ok "gemini argv does NOT use yolo (would auto-approve shell too)"

# --- vendor mapping: bare OpenAI reasoning model ids (codex's own help uses `model="o3"`) ---
for id in o1 o3 o1-preview o3-mini; do
  out="$(bash "$SUT" vendor-of-model "$id" 2>/dev/null)"
  [[ "$out" == "openai" ]] && ok "vendor mapping: '$id' -> openai" \
    || bad "vendor mapping: '$id' unmapped -> '$out'"
done

# --- vendor mapping is CASE-INSENSITIVE (issue #24) ---
# Observed live: `codex` disclosed `gpt-5` in one round and `GPT-5` in the next from IDENTICAL
# dispatches. The lowercase-only patterns made the second unmappable, and verify-vendor escalates
# unmappable to a hard failure — so a correct reviewer was quarantined and its whole round of
# findings discarded, over the capitalisation of its own name. Model self-report is already the
# least stable field in the protocol (#20); keying on its exact casing compounds that.
while IFS='|' read -r id want; do
  out="$(bash "$SUT" vendor-of-model "$id" 2>/dev/null)"
  [[ "$out" == "$want" ]] && ok "vendor mapping: '$id' -> $want (case-insensitive)" \
    || bad "vendor mapping: '$id' -> '$out' (want $want)"
done <<'CASES'
GPT-5|openai
GPT-5.6-Terra|openai
Gpt-5-Codex|openai
O3-Mini|openai
Gemini-2.5-Pro|google
GEMINI|google
Claude-Fable-5|anthropic
Claude-Opus-4-8|anthropic
CLAUDE-SONNET-4-5|anthropic
Fable|anthropic
CASES

# The fold must not depend on the caller's locale (PR#25 gemini-rd1-r1 / fable-rd1-r1, raised
# independently by two vendors). `[:upper:]`/`[:lower:]` are locale-dependent classes by POSIX;
# model ids are ASCII by construction, so the mapping must be identical under any locale a user
# happens to export. NB: the canonical Turkish dotless-i case does NOT reproduce on BSD tr — this
# asserts the invariant directly rather than relying on one locale to expose it.
# Capture `locale -a` ONCE, then test the captured value. Piping it into `grep -q` per locale
# looks equivalent but is not: grep exits on first match, SIGPIPEs `locale`, and under this
# suite's `pipefail` the pipeline reports 141 — so every locale appearing late in the output was
# silently skipped, including tr_TR, leaving this block vacuous exactly where it mattered. Same
# hazard cmd_ensure_skill documents ("capture then test; avoids grep -q SIGPIPE under pipefail").
LOCALES_AVAIL="$(locale -a 2>/dev/null)"
# Candidates are DISCOVERED from the host, not hardcoded (PR#25 gemini-rd2-r1): distros spell the
# charset differently (`en_US.UTF-8` vs `en_US.utf8`), so an exact-name list silently matches
# nothing on those hosts. Prefer Turkish (the canonical hostile case-folding locale), then any
# other non-C locale, and cap the count to keep the suite fast.
LOC_TR="$(printf '%s\n' "$LOCALES_AVAIL" | grep -iE '^tr_TR([.@]|$)' | head -2 || true)"
LOC_OTHER="$(printf '%s\n' "$LOCALES_AVAIL" | grep -iE '^(en_US|de_DE)([.@]|$)' | head -2 || true)"
nonc=0
for L in C POSIX $LOC_TR $LOC_OTHER; do
  [[ -n "$L" ]] || continue
  out="$(LC_ALL="$L" bash "$SUT" vendor-of-model GEMINI 2>/dev/null)"
  [[ "$out" == "google" ]] && ok "vendor mapping: 'GEMINI' -> google under LC_ALL=$L" \
    || bad "vendor mapping: locale $L broke the fold ('GEMINI' -> '$out')"
  out="$(LC_ALL="$L" bash "$SUT" vendor-of-model CLAUDE-OPUS-4-8 2>/dev/null)"
  [[ "$out" == "anthropic" ]] && ok "vendor mapping: 'CLAUDE-OPUS-4-8' -> anthropic under LC_ALL=$L" \
    || bad "vendor mapping: locale $L broke the fold ('CLAUDE-OPUS-4-8' -> '$out')"
  case "$L" in C|POSIX) : ;; *) nonc=$((nonc+1)) ;; esac
done

# A host with NO non-C locale cannot exercise the regression at all: with only C/POSIX the fold
# works whether or not `LC_ALL=C` is pinned, so the loop above would pass vacuously and a future
# removal of the pin would sail through the gate (PR#25 codex-rd2-r1). There is no behavioural
# oracle for a locale pin on a host with one locale, so fall back to asserting the pin is present
# — narrower than a behaviour test, but non-vacuous everywhere, and stated loudly rather than
# skipped silently (this repo's no-silent-caps rule).
if (( nonc > 0 )); then
  ok "locale invariance exercised under ${nonc} non-C locale(s)"
else
  echo "  note: no non-C locale on this host — falling back to a structural check of the pin"
  grep -qE "LC_ALL=C[[:space:]]+tr[[:space:]]+'\[:upper:\]'" "$SUT" \
    && ok "vendor_of_model fold is locale-pinned (structural; no non-C locale to test with)" \
    || bad "vendor_of_model fold is not locale-pinned and no non-C locale exists to prove it"
fi

# Non-regression: case-folding must NOT widen what maps. A genuinely unknown vendor stays
# unmappable in every casing, so verify-vendor still fails closed on it.
for id in llama-3 LLAMA-3 Mistral-Large deepseek-v3 ""; do
  bash "$SUT" vendor-of-model "$id" >/dev/null 2>&1 \
    && bad "vendor mapping: '$id' should be unmappable but resolved" \
    || ok "vendor mapping: '${id:-<empty>}' stays unmappable in any case"
done

# Non-regression: verify-vendor still REJECTS a real cross-vendor mismatch — case-folding must
# not let an anthropic id pass as the openai provider just because the casing now normalises.
MM="${WORK}/mismatch.md"; MMB="${WORK}/mismatch.baseline"
printf '# T\n\n## Review\n' > "$MMB"
{ printf '# T\n\n## Review\n'; printf '> [finding:r1|high] x\n> — via Claude-Opus-4-8\n> — risk: r\n'; } > "$MM"
bash "$SUT" verify-vendor --baseline "$MMB" "$MM" --reviewer codex >/dev/null 2>&1 \
  && bad "verify-vendor admitted an anthropic disclosure for the codex provider" \
  || ok "verify-vendor still rejects a cross-vendor mismatch in mixed case"

# ...and still ADMITS the correct vendor in mixed case (the bug this fixes).
MO="${WORK}/okcase.md"
{ printf '# T\n\n## Review\n'; printf '> [finding:r1|high] x\n> — via GPT-5\n> — risk: r\n'; } > "$MO"
bash "$SUT" verify-vendor --baseline "$MMB" "$MO" --reviewer codex >/dev/null 2>&1 \
  && ok "verify-vendor admits 'GPT-5' for the codex provider (issue #24 repro)" \
  || bad "verify-vendor still quarantines a correctly-vendored uppercase disclosure"

# --- advisory check: gemini (Task 1) ---
# Deterministic env: no ambient GEMINI_* leaking in (this repo's maintainer exports the trust var).
unset GEMINI_API_KEY GEMINI_CLI_TRUST_WORKSPACE
# stub gemini on PATH so `command -v gemini` passes without the real CLI
GBIN="${WORK}/gbin"; mkdir -p "$GBIN"; printf '#!/usr/bin/env bash\necho OK\n' > "$GBIN/gemini"; chmod +x "$GBIN/gemini"
# a temp git repo controls repo_root() + workspace files + HOME(~/.gemini)
GREPO="${WORK}/grepo"; mkdir -p "$GREPO"; ( cd "$GREPO" && git init -q )

# nothing configured -> exit 0 with the two hints that apply to an unconfigured CLI.
#
# This assertion used to demand the respectGitIgnore hint here too, in a bare repo that ignores
# nothing. That encoded the cry-wolf behavior issue #22 identified: an always-on hint naming only
# a setting is indistinguishable from a false positive, and a real run dismissed it for exactly
# that reason. The hint is now conditional on something actually being unreadable, and is
# asserted where that is true (readability block near the doctor tests). Narrowed deliberately:
# trust and key remain unconditional here because they ARE unconditional prerequisites.
out="$(cd "$GREPO" && HOME="$GREPO/home" PATH="${GBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "check gemini: advisory keeps exit 0" || bad "check gemini exit $rc (want 0)"
grep -qi 'trust' <<<"$out" && grep -qi 'API key' <<<"$out" \
  && ok "check gemini: emits trust+key hints when unconfigured" || bad "gemini hints missing: '$out'"
! grep -qi 'respectGitIgnore' <<<"$out" \
  && ok "check gemini: no gitignore hint in a repo that ignores nothing" \
  || bad "check gemini: gitignore hint fired with nothing ignored: '$out'"

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
rr_tracked="${WORK}/rtracked"; mkdir -p "$rr_tracked"; git -C "$rr_tracked" init -q; mkdir -p "$rr_tracked/.agents/skills/multi-review"
echo x > "$rr_tracked/.agents/skills/multi-review/SKILL.md"; git -C "$rr_tracked" add -f .; git -C "$rr_tracked" -c user.email=t@t -c user.name=t commit -qm s
out="$(cd "$rr_tracked" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"
grep -qi 'drift' <<<"$out" && ok "tracked copy -> drift hint" || bad "no drift hint for tracked copy"

# repo-root resolution: from a SUBDIR with the tracked copy at the root -> still drift hint
mkdir -p "$rr_tracked/sub/dir"
out="$(cd "$rr_tracked/sub/dir" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"
grep -qi 'drift' <<<"$out" && ok "check codex: repo-root resolved from a subdirectory" || bad "codex subdir missed drift hint: '$out'"

# --- Fix 1 regression: an UNTRACKED, non-marker .agents/skills/multi-review copy is exactly the
# --- state ensure-skill refuses forever ("untracked files at … — remove it and re-run"). check
# --- must emit the same remove-and-re-run advisory (still exit 0 — it's advisory, not a gate) so
# --- doctor stops reporting bare "ready" for a codex that is actually quarantined.
rr_untracked="${WORK}/runtracked"; mkdir -p "$rr_untracked"; git -C "$rr_untracked" init -q
mkdir -p "$rr_untracked/.agents/skills/multi-review"
echo x > "$rr_untracked/.agents/skills/multi-review/SKILL.md"   # untracked: never git add'd, no marker
out="$(cd "$rr_untracked" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "check codex: untracked non-marker copy still exits 0 (advisory, not a gate)" \
  || bad "codex untracked-copy rc=$rc (want 0)"
grep -qi 'untracked files' <<<"$out" && grep -qi 'remove it and re-run' <<<"$out" \
  && ok "check codex: untracked non-marker copy emits the remove-and-re-run advisory" \
  || bad "codex untracked-copy missing the remove-and-re-run advisory: '$out'"

# the materialized (marker present) state is the NORMAL auto-provisioned outcome -> no hint at all
rr_marked="${WORK}/rmarked"; mkdir -p "$rr_marked"; git -C "$rr_marked" init -q
mkdir -p "$rr_marked/.agents/skills/multi-review"
echo x > "$rr_marked/.agents/skills/multi-review/SKILL.md"
echo "1.0.0" > "$rr_marked/.agents/skills/multi-review/.multi-review-materialized"
out="$(cd "$rr_marked" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"; rc=$?
[[ "$rc" == 0 && -z "$out" ]] && ok "check codex: materialized (marker present) copy emits no hint" \
  || bad "codex materialized copy unexpectedly hinted (rc=$rc): '$out'"

# --- Fix 2 regression: repo_root() falling back to the plugin's own ROOT (non-git cwd) must NOT
# --- fire EITHER hint — the bundle there is the plugin's own legitimately-tracked source, and the
# --- untracked-copy hint's "remove it" advice would otherwise target the plugin's own bundle.
NOGIT="${WORK}/nogit"; mkdir -p "$NOGIT"
out="$(cd "$NOGIT" && PATH="${CBIN}:$PATH" bash "$SUT" check --reviewer codex 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "check codex: non-git cwd (ROOT fallback) exits 0" || bad "codex non-git-cwd rc=$rc (want 0)"
grep -qiE 'drift|untracked files' <<<"$out" \
  && bad "codex ROOT-fallback wrongly fired a drift/untracked hint: '$out'" \
  || ok "check codex: ROOT fallback suppresses both the drift and untracked-copy hints"

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

# codex git-tracked skill copy present -> check still passes (rc=0, drift is advisory-only per
# cmd_check's own comment), so doctor must show codex READY, not "needs setup" (Finding 1: a
# passing check must never be downgraded by an advisory hint — same rule gemini already gets).
mkdir -p "$DREPO/.agents/skills/multi-review"
echo x > "$DREPO/.agents/skills/multi-review/SKILL.md"
( cd "$DREPO" && git add -f .agents/skills/multi-review && git -c user.email=t@t -c user.name=t commit -qm skill )
out="$(cd "$DREPO" && HOME="$DREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=5 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"
grep -qi 'codex: ready\|✓ codex' <<<"$out" && ok "doctor: codex ready despite tracked-skill drift hint" || bad "doctor codex not ready: '$out'"
grep -qiE '△ codex|codex: needs setup' <<<"$out" && bad "doctor: codex showed 'needs setup' despite a passing check" || ok "doctor: no contradictory codex needs-setup line"
grep -qi 'drift' <<<"$out" && ok "doctor: codex drift advisory still surfaced" || bad "doctor: codex drift advisory missing: '$out'"

# --- readability is reported SEPARATELY from auth (issue #22) ------------------------------
# A green live probe proves auth+trust; it proves nothing about whether gemini-cli's gitignore
# filtering will let the reviewer OPEN the doc. doctor used to let a passing probe suppress
# EVERY static hint, so it printed a bare "✓ gemini: ready" in exactly the repo state where the
# reviewer could not read what it was sent to review.
RREPO="${WORK}/rrepo"; mkdir -p "$RREPO/docs/specs"; ( cd "$RREPO" && git init -q )
printf 'OK\n' > "$RREPO/docs/specs/d.md"
printf '#!/usr/bin/env bash\necho OK\n' > "$DBIN/gemini"; chmod +x "$DBIN/gemini"   # probe passes
# Every `check --reviewer gemini` below MUST run with $DBIN on PATH. Without it these
# assertions silently depend on a real gemini CLI being installed on the machine: they pass on
# a developer box and fail in CI with "gemini CLI not on PATH", which is not what they test.
# (Exactly how they first failed once CI existed.)

# (a) nothing ignored -> no readability hint at all. Precision matters: the OLD hint fired
# unconditionally, which is why a real run read it, checked whether the review copies were
# ignored (they were not), and correctly-but-wrongly concluded it did not apply.
err="$(cd "$RREPO" && HOME="$RREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
! grep -qi 'gitignore\|respectGitIgnore' <<<"$err" \
  && ok "check gemini: no readability hint when nothing is ignored" \
  || bad "check gemini: cried wolf with nothing ignored: '$err'"

# (b) doc dir actually ignored -> hint NAMES the ignored path, not just the setting
printf 'docs/specs/\n' > "$RREPO/.gitignore"
err="$(cd "$RREPO" && HOME="$RREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qF 'docs/specs' <<<"$err" \
  && ok "check gemini: readability hint names the ignored path" \
  || bad "check gemini: hint does not name the unreadable path: '$err'"
grep -qi 'respectGitIgnore' <<<"$err" \
  && ok "check gemini: readability hint still names the fix" \
  || bad "check gemini: hint lost the actionable fix: '$err'"

# (c) doctor must NOT print a bare ready while that blocker stands, and must still say auth is OK
out="$(cd "$RREPO" && HOME="$RREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=5 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"
grep -qE '✓ gemini: ready' <<<"$out" \
  && bad "doctor: printed bare 'ready' for a gemini that cannot read the doc: '$out'" \
  || ok "doctor: no bare 'ready' when the doc is unreadable"
grep -qF 'docs/specs' <<<"$out" \
  && ok "doctor: names the unreadable path" || bad "doctor: readability blocker not named: '$out'"
grep -qi 'auth OK' <<<"$out" \
  && ok "doctor: still reports the auth probe result separately" \
  || bad "doctor: lost the auth signal: '$out'"

# (d) the settings fix clears it — the hint and the doctor downgrade both go away
mkdir -p "$RREPO/.gemini"
printf '{"context":{"fileFiltering":{"respectGitIgnore":false}}}\n' > "$RREPO/.gemini/settings.json"
err="$(cd "$RREPO" && HOME="$RREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
! grep -qi 'respectGitIgnore' <<<"$err" \
  && ok "check gemini: readability hint clears once respectGitIgnore is disabled" \
  || bad "check gemini: hint persists after the fix: '$err'"
out="$(cd "$RREPO" && HOME="$RREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=5 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"
grep -qE '✓ gemini: ready' <<<"$out" \
  && ok "doctor: back to ready once readability is fixed" || bad "doctor: still downgraded after fix: '$out'"

# (d2) gemini-cli merges the USER-scoped ~/.gemini/settings.json over the workspace one, so a
# user-level opt-out makes the docs readable too. Consulting only the workspace file reintroduces
# exactly the cry-wolf false positive this check exists to remove (PR#23 fable-rd1-r1).
rm -f "$RREPO/.gemini/settings.json"
mkdir -p "$RREPO/home/.gemini"
printf '{"context":{"fileFiltering":{"respectGitIgnore":false}}}\n' > "$RREPO/home/.gemini/settings.json"
err="$(cd "$RREPO" && HOME="$RREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
! grep -qi 'respectGitIgnore' <<<"$err" \
  && ok "check gemini: user-scoped ~/.gemini/settings.json clears the readability hint" \
  || bad "check gemini: ignored the user-scoped opt-out: '$err'"
out="$(cd "$RREPO" && HOME="$RREPO/home" MULTI_REVIEW_PROBE_TIMEOUT=5 PATH="${DBIN}:$PATH" bash "$SUT" doctor 2>&1)"
grep -qE '✓ gemini: ready' <<<"$out" \
  && ok "doctor: ready under a user-scoped opt-out" || bad "doctor still downgraded under user-scoped opt-out: '$out'"
rm -rf "$RREPO/home/.gemini"

# (b2) a glob rule that ignores the FILES without ignoring the directory (PR#23 codex-rd2-r1).
# `docs/specs/*.md` leaves `docs/specs/` itself readable, so probing only the directory misses it
# while gemini still refuses the actual review doc.
RGLOB="${WORK}/rglob"; mkdir -p "$RGLOB"; ( cd "$RGLOB" && git init -q )
printf 'docs/specs/*.md\n' > "$RGLOB/.gitignore"
err="$(cd "$RGLOB" && HOME="$RGLOB/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qF 'docs/specs' <<<"$err" \
  && ok "check gemini: catches a glob rule that ignores the docs but not the dir" \
  || bad "check gemini: missed a *.md ignore rule: '$err'"

# (d3) WORKSPACE settings win over user settings (PR#23 fable-rd4-r2). Clearing the blocker when
# EITHER scope says false is wrong: a workspace file that explicitly sets respectGitIgnore:true
# overrides a user-scope false, so gemini still refuses the docs while we would report ready —
# a silently missed warning, the failure mode this check exists to remove.
mkdir -p "$RREPO/home/.gemini" "$RREPO/.gemini"
printf '{"context":{"fileFiltering":{"respectGitIgnore":false}}}\n' > "$RREPO/home/.gemini/settings.json"
printf '{"context":{"fileFiltering":{"respectGitIgnore":true}}}\n'  > "$RREPO/.gemini/settings.json"
err="$(cd "$RREPO" && HOME="$RREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qF 'docs/specs' <<<"$err" \
  && ok "check gemini: a workspace 'true' overrides a user-scope 'false'" \
  || bad "check gemini: user scope wrongly won over workspace: '$err'"
# and the reverse precedence still clears it
printf '{"context":{"fileFiltering":{"respectGitIgnore":false}}}\n' > "$RREPO/.gemini/settings.json"
printf '{"context":{"fileFiltering":{"respectGitIgnore":true}}}\n'  > "$RREPO/home/.gemini/settings.json"
err="$(cd "$RREPO" && HOME="$RREPO/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
! grep -qi 'respectGitIgnore' <<<"$err" \
  && ok "check gemini: a workspace 'false' wins over a user-scope 'true'" \
  || bad "check gemini: workspace false did not win: '$err'"
rm -rf "$RREPO/home/.gemini" "$RREPO/.gemini"

# (f) a doc dir literally named `-n`/`-e` must not be swallowed: `echo "$list"` would eat it as a
# flag and silently report nothing unreadable (PR#23 gemini-rd1-r3).
RDASH="${WORK}/rdash"; mkdir -p "$RDASH"; ( cd "$RDASH" && git init -q )
printf -- '-n/\n' > "$RDASH/.gitignore"
err="$(cd "$RDASH" && HOME="$RDASH/home" MULTI_REVIEW_DOC_DIRS="-n" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qF -- '-n' <<<"$err" \
  && ok "check gemini: a path named -n survives the hint's formatting" \
  || bad "check gemini: echo swallowed the -n path: '$err'"

# (e) PR mode reviews a scratch file under .multi-review/, which the plugin itself gitignores —
# so that path is a readability blocker for gemini even when the doc dirs are clean.
RPR="${WORK}/rpr"; mkdir -p "$RPR"; ( cd "$RPR" && git init -q )
printf '.multi-review/\n' > "$RPR/.gitignore"
err="$(cd "$RPR" && HOME="$RPR/home" PATH="${DBIN}:$PATH" bash "$SUT" check --reviewer gemini 2>&1 >/dev/null)"
grep -qF '.multi-review' <<<"$err" \
  && ok "check gemini: names the gitignored PR scratch dir" \
  || bad "check gemini: missed the PR scratch blocker: '$err'"

# --- issue #50 / codex-rd1-r1: the signal's `> — via` must be ENFORCED, not merely documented ---
# protocol_lines is the guard that catches "added protocol content but no usable disclosure". Its
# pattern matched only tags ending in a COLON, so `> [no-findings]` matched nothing and a bare
# signal passed verify-vendor with exit 0 — the exact vacuity #50 exists to close.
NFB="$(mkdoc nf-base.md awaiting-reviewer)"
printf '\n## Review\n' >> "$NFB"

NFBARE="$(mkdoc nf-bare.md awaiting-author)"
printf '\n## Review\n> [no-findings] reviewed in full; nothing to raise\n' >> "$NFBARE"
bash "$SUT" verify-vendor --baseline "$NFB" "$NFBARE" --reviewer codex >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "verify-vendor: a no-findings signal without '> — via' fails" \
  || bad "a bare [no-findings] with no disclosure passed verify-vendor (issue #50, codex-rd1-r1)"

# ...and a properly disclosed signal still passes — the guard must not reject conforming turns
NFVIA="$(mkdoc nf-via.md awaiting-author)"
printf '\n## Review\n> [no-findings] reviewed in full; nothing to raise\n> — via gpt-5\n' >> "$NFVIA"
bash "$SUT" verify-vendor --baseline "$NFB" "$NFVIA" --reviewer codex >/dev/null 2>&1 \
  && ok "verify-vendor: a disclosed no-findings signal passes" \
  || bad "a conforming signalled-clean turn was rejected"

# ...and the disclosure is now a SUBJECT, so a wrong vendor is caught where it was once vacuous
NFWRONG="$(mkdoc nf-wrong.md awaiting-author)"
printf '\n## Review\n> [no-findings] reviewed in full; nothing to raise\n> — via claude-opus-5[1m]\n' >> "$NFWRONG"
bash "$SUT" verify-vendor --baseline "$NFB" "$NFWRONG" --reviewer codex >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "verify-vendor: a wrong vendor on a signal-only turn is caught" \
  || bad "an anthropic id disclosed by the codex secondary passed on a signal-only turn"

# --- codex-rd2-r1: the key must be NORMALISED, or rewording re-opens a fixed false positive ---
# protocol_lines once did a full-LINE diff and a merely reworded finding registered as new
# protocol content. Normalisation fixed that; an unnormalised tag re-opens the same class.
# Two copies whose signal free-text differs must produce the SAME key.
NFT1="$(mkdoc nf-t1.md awaiting-author)"
printf '\n## Review\n> [no-findings] reviewed in full; nothing to raise\n> — via gpt-5\n' >> "$NFT1"
NFT2="$(mkdoc nf-t2.md awaiting-author)"
printf '\n## Review\n> [no-findings] read it all, nothing worth raising\n> — via gpt-5\n' >> "$NFT2"
k1="$(bash "$SUT" _protocol_lines_for_test "$NFT1" 2>/dev/null || true)"
k2="$(bash "$SUT" _protocol_lines_for_test "$NFT2" 2>/dev/null || true)"
[[ -n "$k1" && "$k1" == "$k2" ]] \
  && ok "protocol_lines: differing signal wording normalises to one key ('$k1')" \
  || bad "no-findings key is not normalised — rewording looks like new protocol content ('$k1' vs '$k2')"
[[ "$k1" == "no-findings:" ]] \
  && ok "protocol_lines: the normalised key is exactly 'no-findings:'" \
  || bad "normalised key is '$k1', expected 'no-findings:'"

# _protocol_lines_for_test with no argument must fail via this file's `die` convention (a
# named, prefixed message on stderr and exit 2), not a raw `set -u` "unbound variable" trap.
pl_err="$(bash "$SUT" _protocol_lines_for_test 2>&1 >/dev/null)"; pl_rc=$?
[[ "$pl_rc" -eq 2 ]] \
  && ok "_protocol_lines_for_test: missing argument exits 2" \
  || bad "_protocol_lines_for_test with no argument exited $pl_rc, expected 2"
[[ "$pl_err" == "multi-review-reviewer: "*"file"* ]] \
  && ok "_protocol_lines_for_test: missing argument reports via die(), not an unbound-variable trap" \
  || bad "_protocol_lines_for_test error was not a die()-style message: '$pl_err'"

# --- path_contains: canonical prefix containment, BOTH sides canonicalized (issue #60) ---
# The one finding from this spec's review (codex-rd1-r1): canonicalizing only the child compares a
# physical path against a logical one, so a symlinked PARENT reports an inside path as outside —
# a false hint on an ordinary same-root review. On macOS /tmp -> /private/tmp makes that the
# default for anything under a temp dir, not an exotic case.

PC="${WORK}/pc"; mkdir -p "$PC/root/sub" "$PC/outside"
ln -sfn "$PC/root" "$PC/rootlink"

bash "$SUT" _path_contains_for_test "$PC/root" "$PC/root/sub"
[[ $? -eq 0 ]] && ok "path_contains: a child inside the parent is contained" \
  || bad "path_contains rejected a genuine child"

bash "$SUT" _path_contains_for_test "$PC/root" "$PC/outside"
[[ $? -ne 0 ]] && ok "path_contains: a sibling directory is not contained" \
  || bad "path_contains accepted a path outside the parent"

bash "$SUT" _path_contains_for_test "$PC/root" "$PC/root"
[[ $? -eq 0 ]] && ok "path_contains: a parent contains itself" \
  || bad "path_contains rejected the parent as its own child"

# the finding, directly: parent given through a SYMLINK, child given physically
bash "$SUT" _path_contains_for_test "$PC/rootlink" "$PC/root/sub"
[[ $? -eq 0 ]] && ok "path_contains: a symlinked parent still contains a physical child" \
  || bad "path_contains failed to canonicalize the parent (issue #60, codex-rd1-r1)"

# and the mirror: child given through a symlink, parent physically
ln -sfn "$PC/root/sub" "$PC/sublink"
bash "$SUT" _path_contains_for_test "$PC/root" "$PC/sublink"
[[ $? -eq 0 ]] && ok "path_contains: a symlinked child still resolves inside the parent" \
  || bad "path_contains failed to canonicalize the child"

# a non-existent side cannot be canonicalized -> NOT contained, so the caller stays silent
bash "$SUT" _path_contains_for_test "$PC/root" "$PC/does-not-exist"
[[ $? -ne 0 ]] && ok "path_contains: an unresolvable child is not contained" \
  || bad "path_contains accepted an unresolvable child"

bash "$SUT" _path_contains_for_test "$PC/does-not-exist" "$PC/root/sub"
[[ $? -ne 0 ]] && ok "path_contains: an unresolvable parent is not contained" \
  || bad "path_contains accepted an unresolvable parent"

# a name-prefix that is NOT a path component must not match (/root vs /rootstuff)
mkdir -p "$PC/rootstuff"
bash "$SUT" _path_contains_for_test "$PC/root" "$PC/rootstuff"
[[ $? -ne 0 ]] && ok "path_contains: a sibling sharing a name prefix is not contained" \
  || bad "path_contains matched on a string prefix rather than a path component"

# --- codex_workspace_root: the companion's workspaceRoot, or empty (issue #60) ---
# Stubbed through HOME + a fake `node` on PATH, the same way the gemini checks stub HOME above.
# This needs neither the real codex plugin nor a real node — CI's tool inventory has no node.

CWS="${WORK}/cws"
CWS_COMP="${CWS}/home/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts"
mkdir -p "$CWS_COMP" "${CWS}/bin" "${CWS}/ws"
: > "${CWS_COMP}/codex-companion.mjs"
# fake node: prints whatever workspaceRoot the test asks for
printf '#!/bin/bash\nprintf '"'"'{"workspaceRoot":"%%s"}\\n'"'"' "$FAKE_WS"\n' > "${CWS}/bin/node"
chmod +x "${CWS}/bin/node"

got="$(HOME="${CWS}/home" FAKE_WS="${CWS}/ws" PATH="${CWS}/bin:$PATH" \
  bash "$SUT" _codex_workspace_root_for_test 2>/dev/null)"
[[ "$got" == "${CWS}/ws" ]] && ok "codex_workspace_root: reads workspaceRoot from the companion" \
  || bad "codex_workspace_root returned '$got', expected '${CWS}/ws'"

# no companion under HOME -> empty, exit 0 (the machine has no codex plugin)
mkdir -p "${CWS}/emptyhome"
got="$(HOME="${CWS}/emptyhome" FAKE_WS="${CWS}/ws" PATH="${CWS}/bin:$PATH" \
  bash "$SUT" _codex_workspace_root_for_test 2>/dev/null)"; rc=$?
[[ -z "$got" && $rc -eq 0 ]] && ok "codex_workspace_root: no companion yields empty, exit 0" \
  || bad "codex_workspace_root with no companion gave '$got' rc=$rc"

# companion present but the runtime fails -> empty, exit 0
printf '#!/bin/bash\nexit 1\n' > "${CWS}/bin/node"; chmod +x "${CWS}/bin/node"
got="$(HOME="${CWS}/home" PATH="${CWS}/bin:$PATH" \
  bash "$SUT" _codex_workspace_root_for_test 2>/dev/null)"; rc=$?
[[ -z "$got" && $rc -eq 0 ]] && ok "codex_workspace_root: a failing companion yields empty, exit 0" \
  || bad "codex_workspace_root with a failing runtime gave '$got' rc=$rc"
# restore the working stub
printf '#!/bin/bash\nprintf '"'"'{"workspaceRoot":"%%s"}\\n'"'"' "$FAKE_WS"\n' > "${CWS}/bin/node"
chmod +x "${CWS}/bin/node"

# no node on PATH at all -> empty, exit 0.
#
# HERMETIC ON PURPOSE (codex-rd1-r1). PATH is a dedicated directory holding ONLY a jq symlink, so
# node is definitively absent and jq definitively present, and the branch exercised is the one the
# assertion names. `PATH=/usr/bin:/bin` would NOT do: GitHub's ubuntu runners ship node in
# /usr/bin, where the real node runs the EMPTY stub companion, prints nothing, jq turns that into
# nothing, and the assertion passes without ever reaching the no-node branch — green for the wrong
# reason, which no later mutation would catch.
#
# `bash` is invoked by absolute path because PATH no longer contains it.
NODELESS="${CWS}/nodeless"; mkdir -p "$NODELESS"
ln -sf "$(command -v jq)" "${NODELESS}/jq"
got="$(HOME="${CWS}/home" PATH="$NODELESS" \
  /bin/bash "$SUT" _codex_workspace_root_for_test 2>/dev/null)"; rc=$?
[[ -z "$got" && $rc -eq 0 ]] && ok "codex_workspace_root: no node yields empty, exit 0" \
  || bad "codex_workspace_root without node gave '$got' rc=$rc"

# the mirror: node present, jq absent -> empty, exit 0. Same hermetic construction.
JQLESS="${CWS}/jqless"; mkdir -p "$JQLESS"
cp "${CWS}/bin/node" "${JQLESS}/node"
got="$(HOME="${CWS}/home" FAKE_WS="${CWS}/ws" PATH="$JQLESS" \
  /bin/bash "$SUT" _codex_workspace_root_for_test 2>/dev/null)"; rc=$?
[[ -z "$got" && $rc -eq 0 ]] && ok "codex_workspace_root: no jq yields empty, exit 0" \
  || bad "codex_workspace_root without jq gave '$got' rc=$rc"

# --- check --doc: the out-of-root preflight hint (issue #60) ---
# The copy must live inside the reviewer's sandbox root. For codex that root is the companion's
# workspaceRoot, which does NOT follow a shell `cd` — the pair the issue originally proposed
# (doc dir vs git toplevel) agrees with itself in the cwd-drift case and would stay silent
# exactly when the hint is needed (spec §2).

CD_="${WORK}/cd"
CD_COMP="${CD_}/home/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts"
mkdir -p "$CD_COMP" "${CD_}/bin" "${CD_}/ws/docs" "${CD_}/elsewhere/docs"
: > "${CD_COMP}/codex-companion.mjs"
printf '#!/bin/bash\nprintf '"'"'{"workspaceRoot":"%%s"}\\n'"'"' "$FAKE_WS"\n' > "${CD_}/bin/node"
chmod +x "${CD_}/bin/node"
printf '#!/bin/bash\n:\n' > "${CD_}/bin/codex"; chmod +x "${CD_}/bin/codex"
printf '#!/bin/bash\necho OK\n' > "${CD_}/bin/gemini"; chmod +x "${CD_}/bin/gemini"
: > "${CD_}/ws/docs/d.md"; : > "${CD_}/elsewhere/docs/d.md"

# (1) doc OUTSIDE the stubbed workspaceRoot -> hint, naming both paths
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/ws" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/elsewhere/docs/d.md" 2>&1 >/dev/null)"; rc=$?
[[ "$out" == *"hint (codex)"* && "$out" == *"outside"* ]] \
  && ok "check --doc: a copy outside codex's sandbox root is hinted" \
  || bad "no out-of-root hint for codex (got: '$out')"
[[ $rc -eq 0 ]] && ok "check --doc: the out-of-root hint does not change the exit status" \
  || bad "check exited $rc on the out-of-root hint — it must stay advisory"

# (2) doc INSIDE the stubbed root -> silence. Success criterion 2: a normal review adds no output.
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/ws" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/ws/docs/d.md" 2>&1 >/dev/null)"
[[ "$out" != *"outside"* ]] && ok "check --doc: a copy inside the sandbox root is not hinted" \
  || bad "a same-root copy produced a false out-of-root hint (got: '$out')"

# (3) no companion under HOME -> unknown root -> silence, exit 0
mkdir -p "${CD_}/nohome"
out="$(HOME="${CD_}/nohome" FAKE_WS="${CD_}/ws" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/elsewhere/docs/d.md" 2>&1 >/dev/null)"; rc=$?
[[ "$out" != *"outside"* && $rc -eq 0 ]] \
  && ok "check --doc: an unknown codex root stays silent" \
  || bad "check hinted with no companion installed (out='$out' rc=$rc)"

# (4) companion present, runtime fails -> unknown root -> silence, exit 0
printf '#!/bin/bash\nexit 1\n' > "${CD_}/bin/node"; chmod +x "${CD_}/bin/node"
out="$(HOME="${CD_}/home" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/elsewhere/docs/d.md" 2>&1 >/dev/null)"; rc=$?
[[ "$out" != *"outside"* && $rc -eq 0 ]] \
  && ok "check --doc: a failing companion stays silent" \
  || bad "check hinted when the companion failed (out='$out' rc=$rc)"
printf '#!/bin/bash\nprintf '"'"'{"workspaceRoot":"%%s"}\\n'"'"' "$FAKE_WS"\n' > "${CD_}/bin/node"
chmod +x "${CD_}/bin/node"

# (5) --doc omitted -> no out-of-root hint at all. This pins the `doctor` path, which has no doc.
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/ws" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex 2>&1 >/dev/null)"; rc=$?
[[ "$out" != *"outside"* && $rc -eq 0 ]] \
  && ok "check: without --doc there is no out-of-root hint" \
  || bad "check emitted an out-of-root hint with no --doc (out='$out' rc=$rc)"

# (6) root reported but NON-EXISTENT -> unresolvable -> silence (not a hint on everything)
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/no-such-dir" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/ws/docs/d.md" 2>&1 >/dev/null)"; rc=$?
[[ "$out" != *"outside"* && $rc -eq 0 ]] \
  && ok "check --doc: a root that does not resolve stays silent" \
  || bad "check hinted on an unresolvable root (out='$out' rc=$rc)"

# (7) SYMLINKED root, doc physically inside it -> silence (issue #60, codex-rd1-r1)
ln -sfn "${CD_}/ws" "${CD_}/wslink"
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/wslink" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/ws/docs/d.md" 2>&1 >/dev/null)"
[[ "$out" != *"outside"* ]] \
  && ok "check --doc: a symlinked sandbox root does not produce a false hint" \
  || bad "a symlinked root produced a false out-of-root hint (issue #60, codex-rd1-r1)"

# --- --session-root: the basis the DISPATCHED reviewer actually inherits (issue #66) ----------
# #60 assumed the companion's workspaceRoot does not follow a shell `cd`. It does: queried from the
# repo root it returns the repo root, from /tmp it returns /private/tmp — it reports wherever the
# HELPER is standing. So the hint went silent in exactly the directory the egress guard forces the
# primary into (the repo owning the doc), while the dispatched subagent inherits the SESSION cwd and
# is rooted elsewhere. A cwd-sensitive query cannot learn the session root, so the skill passes it.

# (S1) THE TRAP. The companion reports the doc's own repo — what it returns when the helper runs
# there — so today's basis says "contained" and stays silent. --session-root names the root the
# subagent will really get, which does NOT contain the doc, so the hint must fire.
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/elsewhere" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/elsewhere/docs/d.md" \
  --session-root "${CD_}/ws" 2>&1 >/dev/null)"; rc=$?
[[ "$out" == *"hint (codex)"* && "$out" == *"outside"* ]] \
  && ok "check --session-root: hints when the SESSION root cannot reach the doc (issue #66)" \
  || bad "check --session-root stayed silent on the #66 trap (out='$out' rc=$rc)"
[[ $rc -eq 0 ]] && ok "check --session-root: the hint stays advisory" \
  || bad "check --session-root exited $rc — the hint must not gate dispatch"

# (S2) --session-root is AUTHORITATIVE, not merely additional: a doc inside it stays silent even
# when the companion reports a root that excludes the doc. Without this the flag could only ever
# add false positives to the very path #60 already covers.
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/elsewhere" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/ws/docs/d.md" \
  --session-root "${CD_}/ws" 2>&1 >/dev/null)"
[[ "$out" != *"outside"* ]] \
  && ok "check --session-root: overrides the companion's cwd-derived root" \
  || bad "check --session-root did not override the companion root (out='$out')"

# (S3) the hint must name the SESSION root, since that is the value the primary can act on.
# Compared in CANONICAL form: the hint canonicalises both sides (so a symlinked root does not read
# as a mismatch), and on macOS the fixture's own /var/folders path resolves to /private/var/...
CD_WS_C="$(cd "${CD_}/ws" && pwd -P)"
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/elsewhere" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/elsewhere/docs/d.md" \
  --session-root "${CD_}/ws" 2>&1 >/dev/null)"
[[ "$out" == *"${CD_WS_C}"* ]] \
  && ok "check --session-root: the hint names the session root" \
  || bad "the hint did not name the session root (want '${CD_WS_C}', out='$out')"

# (S4) an UNRESOLVABLE --session-root is silence, not a hint on everything — same rule the
# companion path already follows for an unknown root. Failing open here beats warning on every doc.
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/elsewhere" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/elsewhere/docs/d.md" \
  --session-root "${CD_}/no-such-session-root" 2>&1 >/dev/null)"; rc=$?
[[ "$out" != *"outside"* && $rc -eq 0 ]] \
  && ok "check --session-root: an unresolvable session root stays silent" \
  || bad "check hinted on an unresolvable --session-root (out='$out' rc=$rc)"

# (S5) a flag with no value is a usage error, never a silent fallback to the old basis — the same
# explicit-arity rule --doc and --repo follow.
HOME="${CD_}/home" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/ws/docs/d.md" --session-root >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "check --session-root: a missing value exits 2" \
  || bad "check --session-root with no value did not exit 2"

# (S6) an EXPLICITLY EMPTY value must fail the same way (fable-rd1-r3). Treating "" as "not
# supplied" sends the basis silently back to the companion — the very thing this flag exists to
# replace — and the caller's capture is exactly where an empty value comes from: `git rev-parse
# --show-toplevel` prints nothing when the cwd is not a repo. So the one plausible resolution
# failure would degrade to the pre-fix silence, which is the failure mode with no signal.
HOME="${CD_}/home" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer codex --doc "${CD_}/ws/docs/d.md" --session-root "" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "check --session-root: an EMPTY value exits 2, not a silent fallback (fable-rd1-r3)" \
  || bad "check --session-root '' silently fell back to the companion basis"

# (8) gemini uses repo_root(), NOT the codex companion: a doc outside the cwd repo is hinted
GD="${CD_}/grepo"; mkdir -p "$GD"; ( cd "$GD" && git init -q . )
out="$(cd "$GD" && HOME="${CD_}/home" FAKE_WS="${CD_}/ws" GEMINI_CLI_TRUST_WORKSPACE=true \
  PATH="${CD_}/bin:$PATH" bash "$SUT" check --reviewer gemini --doc "${CD_}/elsewhere/docs/d.md" 2>&1 >/dev/null)"; rc=$?
[[ "$out" == *"hint (gemini)"* && "$out" == *"outside"* && $rc -eq 0 ]] \
  && ok "check --doc: gemini hints on a doc outside its workspace" \
  || bad "no out-of-root hint for gemini (out='$out' rc=$rc)"

# (9) ...and gemini does NOT consult the codex root: a doc inside the CWD repo is silent even
# though it sits outside the stubbed codex workspaceRoot.
mkdir -p "$GD/docs"; : > "$GD/docs/d.md"
out="$(cd "$GD" && HOME="${CD_}/home" FAKE_WS="${CD_}/ws" GEMINI_CLI_TRUST_WORKSPACE=true \
  PATH="${CD_}/bin:$PATH" bash "$SUT" check --reviewer gemini --doc "$GD/docs/d.md" 2>&1 >/dev/null)"
[[ "$out" != *"outside"* ]] \
  && ok "check --doc: gemini judges against the repo root, not codex's sandbox" \
  || bad "gemini consulted the codex workspace root (got: '$out')"

# (10) fable never hints, whatever the doc
out="$(HOME="${CD_}/home" FAKE_WS="${CD_}/ws" PATH="${CD_}/bin:$PATH" \
  bash "$SUT" check --reviewer fable --doc "${CD_}/elsewhere/docs/d.md" 2>&1 >/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 0 ]] && ok "check --doc: fable is in-harness and never hints" \
  || bad "fable produced output (out='$out' rc=$rc)"

# (11) --doc with no value is a usage error, matching --reviewer's arity contract
HOME="${CD_}/home" PATH="${CD_}/bin:$PATH" bash "$SUT" check --reviewer codex --doc >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "check: --doc with no value exits 2" \
  || bad "--doc with no value did not exit 2"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
