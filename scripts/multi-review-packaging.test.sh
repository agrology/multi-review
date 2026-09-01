#!/usr/bin/env bash
# multi-review-packaging.test.sh — plugin structure & author-side path relocation.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- manifest exists and is valid JSON with required keys ---
MAN="${ROOT}/.claude-plugin/plugin.json"
if [[ -f "$MAN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["name"], "name"; assert d["version"], "version"' "$MAN" \
      && ok "plugin.json valid JSON with name+version" || bad "plugin.json invalid or missing keys"
  else
    ok "plugin.json present (python3 absent; skipped deep validation)"
  fi
else
  bad "plugin.json missing at .claude-plugin/plugin.json"
fi

# --- commands relocated, old dir gone ---
[[ -f "${ROOT}/commands/multi-review.md" ]]      && ok "commands/multi-review.md present"      || bad "commands/multi-review.md missing"
[[ ! -e "${ROOT}/commands/multi-review-auto.md" ]] && ok "commands/multi-review-auto.md removed (autonomous is the default)" \
  || bad "commands/multi-review-auto.md still present"
[[ ! -d "${ROOT}/.claude/commands" ]]           && ok ".claude/commands removed"             || bad ".claude/commands still present (must be single-source)"

# --- no BARE script refs remain in command markdown ---
f="${ROOT}/commands/multi-review.md"
if [[ -f "$f" ]]; then
  refs="$(grep -nE '(^|[^/A-Za-z_])scripts/multi-review-[a-z-]+\.sh' "$f")"
  if [[ -n "$refs" ]] && grep -vq 'CLAUDE_PLUGIN_ROOT' <<<"$refs"; then
    bad "bare scripts/ ref (no \${CLAUDE_PLUGIN_ROOT}) in $(basename "$f")"
  else
    ok "no bare scripts/ refs in $(basename "$f")"
  fi
fi

# --- codex dispatch must ask for a BACKGROUND companion job ---
# The codex:codex-rescue wrapper forwards to `codex-companion.mjs task` in the FOREGROUND unless
# the dispatch asks otherwise. A real review outlives the harness's 10-minute foreground window,
# so the subagent's turn ends and the detached codex process is torn down before it writes any
# findings: the working copy stays byte-identical to its seed, the per-copy wait times out, and
# the provider is quarantined with no error recorded anywhere (observed live on PR #25 — the
# companion's own job output file was 0 bytes). `--background` returns a managed job id
# immediately and the job survives the caller; the existing marker wait is already the right
# completion signal. This guard is prose-level because the dispatch itself is prose.
f="${ROOT}/commands/multi-review.md"
if [[ -f "$f" ]]; then
  n="$(grep -n 'codex:codex-rescue' "$f" | head -1 | cut -d: -f1)"
  if [[ -z "$n" ]]; then
    bad "no codex:codex-rescue dispatch instruction in $(basename "$f")"
  elif grep -q -- '--background' <<<"$(sed -n "${n},$((n+2))p" "$f")"; then
    ok "codex dispatch requests a background companion job"
  else
    bad "codex dispatch lacks --background — a foreground task is killed at the 10-min window before it writes findings"
  fi
fi

# --- codex dispatch must request a REASONING EFFORT explicitly ---
# codex defaults to `reasoning effort: none` for `gpt-5.6-terra`. Observed live: 32-second review
# turns in which the model never opened the document it was pointed at — it read the skill, the
# protocol contract and repo source, then reported `[no-findings]`. Three consecutive worthless
# clean verdicts came from that pairing, and a clean verdict from a turn that read nothing is
# indistinguishable at the gate from a real one. `--effort` is a runtime control the rescue
# wrapper parses out of the task text exactly like `--model`/`--write`/`--background`
# (codex-companion.mjs `valueOptions`), so requesting it costs nothing but the flag.
# Prose-level for the same reason as the guard above: the dispatch itself is prose.
if [[ -f "$f" ]]; then
  n="$(grep -n 'codex:codex-rescue' "$f" | head -1 | cut -d: -f1)"
  if [[ -z "$n" ]]; then
    bad "no codex:codex-rescue dispatch instruction in $(basename "$f")"
  elif grep -q -- '--effort high' <<<"$(sed -n "${n},$((n+2))p" "$f")"; then
    ok "codex dispatch requests high reasoning effort"
  else
    bad "codex dispatch lacks --effort high — codex defaults to effort none, and a 32s turn reviews the protocol instead of the document"
  fi
fi

# --- scripts self-locate from a FOREIGN cwd (spec §2 regression guard for the plugin move) ---
# multi-review-pr.sh's publish resolves its sibling multi-review-star.sh via
# "$(dirname "$0")", not the caller's cwd — this is the live self-locating call now that
# auto-step.sh (the script this guard used to exercise) is gone (Phase 2 PR-B, B3).
tmpcwd="$(mktemp -d)"
D2="$(mktemp -d)/scratch.md"
cat > "$D2" <<'EOF'
# PR review: SelfLocate

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/1

## Review
EOF
gstub="$(mktemp -d)"
cat > "${gstub}/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
chmod +x "${gstub}/gh"
verdict="$( cd "$tmpcwd" && PATH="${gstub}:$PATH" bash "${ROOT}/scripts/multi-review-pr.sh" publish "$D2" 'test-model' 2>&1 )"
case "$verdict" in
  *'No such file or directory'*) bad "pr.sh publish failed to self-locate multi-review-star.sh from a foreign cwd (got: $verdict)" ;;
  *) ok "pr.sh publish resolves sibling scripts from a foreign cwd (got: $verdict)" ;;
esac
rm -rf "$tmpcwd" "$gstub" "$(dirname "$D2")"

# --- reviewer-set resolution is documented in the command (star-universal) ---
DR="${ROOT}/commands/multi-review.md"
if [[ -f "$DR" ]]; then
  grep -q 'multi-review-reviewer.sh' "$DR" && ok "multi-review.md uses the reviewer registry" \
    || bad "multi-review.md does not reference multi-review-reviewer.sh"
  grep -qF 'resolve-set --fable-floor' "$DR" && ok "resolves the set with the fable floor" \
    || bad "multi-review.md does not resolve-set --fable-floor"
  grep -qi 'attended' "$DR" && bad "multi-review.md still mentions the removed --attended route" \
    || ok "no --attended route (star is autonomous-only)"
  # --session-root must be a PLACEHOLDER, never an inline command substitution (fable-rd1-r1).
  # `--session-root "$(git rev-parse --show-toplevel)"` resolves at check time in whatever cwd the
  # primary is standing in — and the egress guard forces that to be the repo owning the doc, which
  # is precisely where the basis collapses back onto the doc's own root and the hint goes silent.
  # The prose says to capture the value BEFORE changing directory; an inline substitution in the
  # runnable line contradicts it, and an agent copies the runnable line.
  # Asserted POSITIVELY (fable-rd2-r3). Banning the one literal `--session-root "$(git rev-parse`
  # let any other spelling through — `$(pwd)`, the same command unquoted — each reintroducing the
  # identical per-invocation re-resolution with the guard still green. So: require the placeholder
  # verbatim, and reject a substitution in the flag's VALUE position (optional quote, then `$(`).
  #
  # Anchored to the value position, NOT "a substitution anywhere on the line". The first attempt
  # used `--session-root[^`]*(\$\(|`)`, which matched the CLOSING backtick of a markdown code span
  # and failed two perfectly correct lines — including the placeholder line it was meant to bless.
  # The backtick-substitution form is deliberately not covered: it cannot be told apart from a code
  # span here, and it is not a spelling anyone reaches for.
  sr_lines="$(grep -n -- '--session-root' "$DR" || true)"
  if [[ -z "$sr_lines" ]]; then
    bad "multi-review.md no longer documents --session-root at all (the #66 contract vanished)"
  elif ! grep -qF -- '--session-root "<session-root>"' "$DR"; then
    bad "multi-review.md does not pass --session-root as the captured <session-root> placeholder (fable-rd1-r1)"
  elif grep -qE -- '--session-root[[:space:]]*"?\$\(' <<<"$sr_lines"; then
    bad "multi-review.md inlines a command substitution into --session-root — it re-resolves per invocation (fable-rd1-r1/rd2-r3)"
  else
    ok "--session-root is a captured placeholder, and no occurrence inlines a substitution (fable-rd2-r3)"
  fi
  # Guards the PROPERTY (star never hands the loop back to a human mid-review), not the word.
  # A bare 'degrad' ban was a proxy for it, and it became wrong once diff-scoping landed: a
  # round that cannot be scoped degrades to the FULL DOCUMENT and keeps running autonomously,
  # which the spec requires be described as a visible degraded path (§4.6). Widened here to the
  # thing actually removed — degrading or falling back to a manual/attended/two-session flow.
  # The exit-3 CAUSE LIST must name the size guard, or an agent meeting a real exit 3 has no
  # documented entry for it and the next sentence tells it to treat the case as a hard error.
  # Scoped to the enumeration, not the file: a whole-file grep pins "the phrase appears somewhere",
  # and the same phrase family legitimately appears elsewhere in this doc, so the entry could be
  # deleted with the gate still green. The END anchor is asserted rather than non-emptiness --
  # sed '/a/,/b/p' with a missing b prints to EOF, so a non-empty $enum does not prove it bounded.
  enum="$(sed -n '/Exit 3 is not a failure/,/Any other non-zero exit/p' "$DR")"
  if ! grep -q 'Any other non-zero exit' <<<"$enum"; then
    bad "could not bound the exit-3 enumeration in multi-review.md -- anchors moved"
  elif grep -qiE '(not smaller|larger than|no smaller)' <<<"$enum"; then
    ok "the exit-3 enumeration names the size-guard reason"
  else
    bad "the exit-3 enumeration omits the size guard -- a real exit 3 has no documented entry"
  fi
  grep -qiE '(degrad[a-z]*|fall[a-z]* back)[^.]{0,40}(manual|attended|two-session|second session)' "$DR" \
    && bad "multi-review.md still documents degrade-to-manual" \
    || ok "no degrade-to-manual path"
fi

# --- star fan-out dispatches secondaries concurrently and bounds the wait per copy ---
if [[ -f "$DR" ]]; then
  grep -q 'multi-review-wait.sh' "$DR" && ok "fan-out bounds the per-copy wait" \
    || bad "multi-review.md does not bound the per-copy wait"
  grep -qi 'quarantine' "$DR" && ok "a failed secondary is quarantined, not fatal" \
    || bad "multi-review.md does not document quarantine"
fi

# --- §1 extracts --reviewers (only) and classifies on the positional, not raw $ARGUMENTS ---
if [[ -f "$DR" ]]; then
  sec1="$(awk '/^## 1\. Resolve the argument/{flag=1} flag{print} flag && /^## 2\./{exit}' "$DR")"
  grep -q -- '--reviewers' <<<"$sec1" && ok "§1 extracts --reviewers" \
    || bad "§1 does not extract --reviewers"
  grep -q -- '--attended' <<<"$sec1" && bad "§1 still mentions --attended" \
    || ok "§1 no longer splits --attended"
  grep -qF 'multi-review-pr.sh parse "<positional>"' <<<"$sec1" \
    && ok "PR classification runs on the positional, not raw \$ARGUMENTS" \
    || bad "PR classification does not run on <positional>"
  grep -qF 'multi-review-pr.sh parse "$ARGUMENTS"' "$DR" \
    && bad "PR classification still runs on the raw \$ARGUMENTS" \
    || ok "no PR classification call runs on the raw \$ARGUMENTS"
fi

# --- identity is verified per copy; the gate carries the cross-vendor independence flag ---
if [[ -f "$DR" ]]; then
  grep -q 'verify-vendor' "$DR" && ok "multi-review.md runs verify-vendor" \
    || bad "multi-review.md never runs verify-vendor"
  grep -q -- '--baseline' "$DR" && ok "multi-review.md passes a baseline snapshot" \
    || bad "multi-review.md does not pass --baseline"
  grep -qF 'gate-summary "<doc>" "<primary-model-id>" --flag-independence' "$DR" \
    && ok "the human gate carries the cross-vendor independence flag" \
    || bad "gate-summary is not run with --flag-independence at the gate"
  # the set is resolved in §2 (resume + fresh checks) and carried — not re-resolved per round
  [[ "$(grep -cF 'multi-review-star.sh resolve-set' "$DR")" -le 2 ]] \
    && ok "resolve-set is invoked at most twice (resume + fresh), not per-round" \
    || bad "resolve-set appears too often — the loop may re-resolve mid-run"
  grep -qE 'multi-review-(watch|auto-step)\.sh|open-threads|author-done' "$DR" \
    && bad "multi-review.md still references a removed single-reviewer helper" \
    || ok "no references to removed watch/auto-step/asymmetric helpers"
fi

# --- the baseline snapshot is taken in Fan-out, before dispatching secondaries ---
if [[ -f "$DR" ]]; then
  cp_line="$(grep -nF 'Copy `<doc>` to `<doc>.baseline`' "$DR" | head -1 | cut -d: -f1)"
  dispatch_line="$(grep -nF 'Dispatch every secondary' "$DR" | head -1 | cut -d: -f1)"
  gate_line="$(grep -nF '### Terminal gate' "$DR" | head -1 | cut -d: -f1)"
  if [[ -n "$cp_line" && -n "$dispatch_line" && -n "$gate_line" \
        && "$cp_line" -lt "$dispatch_line" && "$dispatch_line" -lt "$gate_line" ]]; then
    ok "baseline snapshot precedes secondary dispatch"
  else
    bad "baseline/dispatch ordering wrong (cp=$cp_line dispatch=$dispatch_line gate=$gate_line)"
  fi
  # The primary turn must state WHEN it re-fans. This used to pin the phrase "adaptive
  # re-fan-out"; issue #29 made one round the default and re-fan conditional, so the phrase went
  # away while the contract it guarded got stricter. Pin the contract instead of the wording:
  # a stated default, and a named trigger for going again.
  grep -qiE 'one round is the default' "$DR" \
    && ok "primary turn states the one-round default" \
    || bad "multi-review.md does not state the one-round default"
  grep -qiE 're-fan only if' "$DR" \
    && ok "primary turn names the re-fan triggers" \
    || bad "multi-review.md does not say when re-fanning is allowed"
fi

# --- no dangling references to the removed /multi-review-auto command ---
# Removing a command is only done when nothing still points at it; a stale pointer in the
# protocol contract is worse than the command itself, since that file ships to reviewer agents.
# Scans TRACKED files only: docs/plans and docs/specs are gitignored design history that
# legitimately records the command as it was, and rewriting that history would falsify the
# record rather than fix a pointer.
hits="$( cd "$ROOT" && git ls-files -z 2>/dev/null \
         | xargs -0 grep -lE "multi-review-auto([^-]|$)" 2>/dev/null \
         | grep -v '^scripts/multi-review-packaging.test.sh$' || true )"
[[ -z "$hits" ]] && ok "no dangling /multi-review-auto references in tracked files" \
  || bad "stale /multi-review-auto references in: ${hits//$'\n'/ }"

# --- marketplace.json: self-hosted catalog shape, anti-impersonation, github source ---
MKT="${ROOT}/.claude-plugin/marketplace.json"
if [[ -f "$MKT" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MKT" <<'PY' && ok "marketplace.json shape + name + github source" || bad "marketplace.json failed shape/name/source checks"
import json, re, sys
mkt = json.load(open(sys.argv[1], encoding="utf-8"))
# required top-level + types
assert isinstance(mkt.get("name"), str) and mkt["name"], "top-level name"
assert isinstance(mkt.get("description"), str) and mkt["description"], "top-level description (discoverability metadata)"
owner = mkt.get("owner")
assert isinstance(owner, dict) and isinstance(owner.get("name"), str) and owner["name"], "owner.name non-empty"
plugins = mkt.get("plugins")
assert isinstance(plugins, list) and plugins, "plugins non-empty array"
# name: not reserved, no impersonation, no whitespace, kebab-case
name = mkt["name"]
RESERVED = {
  "claude-code-marketplace","claude-code-plugins","claude-plugins-official",
  "claude-plugins-community","claude-community","anthropic-marketplace",
  "anthropic-plugins","agent-skills","anthropic-agent-skills",
  "knowledge-work-plugins","life-sciences","claude-for-legal",
  "claude-for-financial-services","financial-services-plugins",
  "first-party-plugins","healthcare",
}
assert name not in RESERVED, "reserved name"
assert "anthropic" not in name and not name.startswith("claude") and not name.startswith("official-claude"), "impersonation pattern"
assert not re.search(r"\s", name), "whitespace in name"
assert re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name), "kebab-case name"
# every entry has a name + source
for p in plugins:
    assert isinstance(p.get("name"), str) and p["name"], "entry name"
    assert p.get("source") is not None, "entry source"
# the multi-review entry's source is the documented github object
entry = next((p for p in plugins if p.get("name") == "multi-review"), None)
assert entry is not None, "multi-review entry present"
src = entry["source"]
assert isinstance(src, dict) and src.get("source") == "github" and src.get("repo") == "agrology/multi-review", "source is github object for agrology/multi-review"
# discoverability metadata present (byte-exact equality with plugin.json is enforced in Task 2's guard)
assert isinstance(entry.get("description"), str) and entry["description"], "entry description non-empty"
assert isinstance(entry.get("keywords"), list) and entry["keywords"], "entry keywords non-empty array"
PY
  else
    ok "marketplace.json present (python3 absent; skipped deep validation)"
  fi
else
  bad "marketplace.json missing at .claude-plugin/marketplace.json"
fi

# --- cross-manifest sync: marketplace entry ↔ plugin.json cannot drift ---
if [[ -f "$MKT" && -f "$MAN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MKT" "$MAN" <<'PY' && ok "marketplace↔plugin sync (name/description/keywords) + repository=homepage" || bad "cross-manifest sync failed"
import json, sys
mkt = json.load(open(sys.argv[1], encoding="utf-8"))
plug = json.load(open(sys.argv[2], encoding="utf-8"))
# select the entry by equality against plugin.json's name (not a hardcoded literal)
entry = next((p for p in mkt["plugins"] if p.get("name") == plug.get("name")), None)
assert entry is not None, "an entry's name equals plugin.json name"
assert entry.get("description") == plug.get("description"), "description drift between manifests"
ek, pk = entry.get("keywords"), plug.get("keywords")
assert isinstance(ek, list) and isinstance(pk, list), "keywords present as arrays in both manifests"
assert sorted(ek) == sorted(pk), "keywords drift between manifests (order-insensitive)"
CANON = "https://github.com/agrology/multi-review"
assert plug.get("repository") == CANON, "plugin.json repository != canonical URL"
assert plug.get("homepage") == CANON, "plugin.json homepage != canonical URL"
# entry source repo also points at the canonical repo (catches a drifted source)
assert entry["source"].get("repo") == "agrology/multi-review", "entry source repo != agrology/multi-review"
PY
  else
    ok "cross-manifest sync (python3 absent; skipped)"
  fi
else
  bad "cross-manifest sync could not run — marketplace.json or plugin.json missing (this is a FAILURE, not a skip)"
fi

# --- doc↔code sync: a documented DEFAULT cannot drift from the constant it describes (#44) ---
# This suite had no temp dir (it makes them ad hoc and leaks them); the fixtures below need one
# that is cleaned up, so declare it here with the first EXIT trap in the file.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

DOCCHK="${ROOT}/scripts/multi-review-docs-check.sh"
[[ -x "$DOCCHK" ]] && ok "docs-check: present and executable" || bad "docs-check missing/not executable: $DOCCHK"

# (a) the real repo must be in sync — this is the guard itself
bash "$DOCCHK" "$ROOT" >/dev/null 2>&1 \
  && ok "doc↔code: every documented MULTI_REVIEW_DOC_DIRS default matches DOC_DIRS_DEFAULT" \
  || bad "doc↔code default drift in this repo (run scripts/multi-review-docs-check.sh)"

# A guard whose failure path is never exercised is indistinguishable from one that cannot fail —
# the defect class #44 IS. (b)-(d) run it against synthetic roots so each outcome is demonstrated.
mkroot() {                      # mkroot <dir> <documented-default> [<code-default>]
  local d="$1" doc="$2" code="${3:-docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans}"
  mkdir -p "$d/scripts" "$d/docs" "$d/.agents/skills/multi-review/protocol" "$d/commands"
  printf "DOC_DIRS_DEFAULT='%s'\n" "$code" > "$d/scripts/multi-review-core.sh"
  local f
  for f in README.md docs/multi-review.md \
           .agents/skills/multi-review/protocol/multi-review.md commands/multi-review.md; do
    # NB: backticks are literal inside single quotes — do NOT backslash-escape them here. Doing so
    # writes a literal backslash into the fixture, the pattern then matches nothing, and the drift
    # test passes for the WRONG reason (blind rather than drifted). Caught by assertion (b).
    printf 'x `MULTI_REVIEW_DOC_DIRS` (default `%s`) y\n' "$doc" > "$d/$f"
  done
}

# (b) aligned fixture -> pass
FX="${WORK}/fx-ok"; mkroot "$FX" "docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans"
bash "$DOCCHK" "$FX" >/dev/null 2>&1 \
  && ok "docs-check: an aligned tree passes" || bad "docs-check false-positived on an aligned tree"

# (c) drifted fixture -> fail, and NAME the offending site (this is #44's exact shape)
FX2="${WORK}/fx-drift"; mkroot "$FX2" "docs/specs docs/plans"
bash "$DOCCHK" "$FX2" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "docs-check: a stale documented default FAILS" \
  || bad "docs-check passed a doc that contradicts the code (#44 would recur)"
msg="$(bash "$DOCCHK" "$FX2" 2>&1 >/dev/null)"
[[ "$msg" == *"docs/multi-review.md"* && "$msg" == *"documents"* ]] \
  && ok "docs-check: names the drifted file and both values" \
  || bad "docs-check failure is not actionable ('$msg')"

# (d) prose the pattern cannot see -> BLIND, not clean. Without this the guard silently degrades
# to asserting nothing the moment someone reflows a sentence or renames the variable.
# Assert exit 1 EXACTLY, not merely nonzero: exit 2 means "cannot run" (missing python3, bad root),
# which would credit this assertion without the floor ever executing — passing for the wrong reason.
FX3="${WORK}/fx-blind"; mkroot "$FX3" "docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans"
for f in README.md docs/multi-review.md \
         .agents/skills/multi-review/protocol/multi-review.md commands/multi-review.md; do
  echo 'the default is documented in prose the regex cannot match' > "$FX3/$f"
done
bash "$DOCCHK" "$FX3" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "docs-check: matching nothing is a drift FAILURE (exit 1, blind not clean)" \
  || bad "docs-check did not exit 1 on a fully blind tree"

# (e) ONE site blind while the others still match. An aggregate floor passes this — the total
# clears the bar and the rephrased file hides behind its neighbours. The per-file floor must not.
FX4="${WORK}/fx-blind-one"; mkroot "$FX4" "docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans"
echo 'this copy describes the default only in prose no pattern matches' \
  > "$FX4/.agents/skills/multi-review/protocol/multi-review.md"
bash "$DOCCHK" "$FX4" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "docs-check: a SINGLE blind site fails (per-file floor, not aggregate)" \
  || bad "one site went blind and the aggregate total hid it — #44 recurs in the guard itself"
msg="$(bash "$DOCCHK" "$FX4" 2>&1 >/dev/null)"
[[ "$msg" == *".agents/skills/multi-review/protocol/multi-review.md"* && "$msg" == *"BLIND"* ]] \
  && ok "docs-check: names WHICH site went blind" || bad "blind site not named ('$msg')"

# (f) a listed doc that does not exist. Silently skipping it would let deleting a doc disable its
# coverage — the guard would report clean while one of the four sites stopped being checked at all.
FX5="${WORK}/fx-missing"; mkroot "$FX5" "docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans"
rm -f "$FX5/docs/multi-review.md"
bash "$DOCCHK" "$FX5" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "docs-check: a MISSING listed doc fails" \
  || bad "docs-check passed with a listed doc absent — deleting a doc silently drops its coverage"
msg="$(bash "$DOCCHK" "$FX5" 2>&1 >/dev/null)"
[[ "$msg" == *"MISSING FILE"* ]] && ok "docs-check: names the missing file" \
  || bad "missing-file failure not named ('$msg')"

# (g) the ENV-TABLE-ROW form, exercised on its own. Every fixture above writes only the prose
# form, so the second pattern had no coverage at all — and the per-file floor cannot supply it,
# because it counts hits per FILE, not per FORM: README's prose hit keeps the file non-blind while
# the table row silently stops being checked. That is this guard's own defect class, reintroduced
# by the fix for it. The drifted row here sits in a README whose prose site is ALIGNED, so only a
# working table pattern can catch it.
FX6="${WORK}/fx-table"; mkroot "$FX6" "docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans"
printf 'x `MULTI_REVIEW_DOC_DIRS` (default `docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans`) y\n| `MULTI_REVIEW_DOC_DIRS` | `docs/specs docs/plans` | meaning |\n' \
  > "$FX6/README.md"
bash "$DOCCHK" "$FX6" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "docs-check: a drifted ENV-TABLE row fails even when the prose site is aligned" \
  || bad "the table-row pattern is not exercised — it can be lost silently"
msg="$(bash "$DOCCHK" "$FX6" 2>&1 >/dev/null)"
[[ "$msg" == *"documents 'docs/specs docs/plans'"* ]] \
  && ok "docs-check: reports the table row's own drifted value" \
  || bad "table-row drift not reported with its value ('$msg')"

# ...and the mirror case: an ALIGNED table row must not be mistaken for drift.
FX7="${WORK}/fx-table-ok"; mkroot "$FX7" "docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans"
printf 'x `MULTI_REVIEW_DOC_DIRS` (default `docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans`) y\n| `MULTI_REVIEW_DOC_DIRS` | `docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans` | meaning |\n' \
  > "$FX7/README.md"
bash "$DOCCHK" "$FX7" >/dev/null 2>&1 \
  && ok "docs-check: an aligned table row passes" || bad "false positive on an aligned table row"

# --- the repo's OWN memory files must teach the live grammar, not a retired one ---
#
# CLAUDE.md and AGENTS.md are auto-loaded into every agent working in this repo — including a
# dispatched secondary, whose whole turn is then shaped by them. `emit_prompt` deliberately cuts
# the contract at `## Supersedes` so a reviewer is never offered the retired grammars
# (multi-review-reviewer.test.sh guards that on the prompt side); a memory file that re-offers
# them defeats it from the other direction. A reviewer that complies writes lines `merge` cannot
# read, `channel-check` scores the turn as a non-response, and the whole turn is quarantined —
# with a reason that describes the symptom, not the cause.
#
# The retired grammars are named in docs/multi-review.md's `## Supersedes`: the asymmetric
# single-reviewer pair (`[reviewer:]` / `[author: resolved:]`) and the two-agent peer-review
# pair (`[concur:]` / `[withdraw:]`, and the `peer-review` mode hint that selected them).
#
# Extracted as a function so the detection can be exercised against a SYNTHETIC section as well as
# the real files. Asserting only against the real files makes the check unfalsifiable in practice:
# it passes because those files are currently correct, not because it can detect a bad one.
retired_grammar_in() { # <section-text> -> offending tokens, space-joined (empty = clean)
  { grep -oE '\[(reviewer|author: resolved|concur|withdraw):|peer-review' <<<"$1"
    # A `[finding:` with NO `|<sev>` part is the RETIRED peer spelling, and `[finding:` alone
    # cannot be banned because the live grammar uses it too (codex-rd2-r1 on PR #76). The
    # character class stops at `]` or `|`, so `[finding:r1]` matches and
    # `[finding:<id>|<sev>]` does not. This one is consequential rather than cosmetic: a
    # severity-less finding is a HARD parse error (`finding r1 needs a |high, |med, or |low
    # severity tag`, exit 2), so a reviewer following that instruction destroys its own turn.
    grep -oE '\[finding:[^]|]*\]' <<<"$1"
  } 2>/dev/null | sort -u | tr '\n' ' '
}

# The detector must FIRE on a section that teaches the retired severity-less form while still
# mentioning the live one — the shape that slips past a "does it name the live grammar" check,
# because both that assertion and the banned-verb assertion pass.
_synthetic="Leave concerns as \`> [finding:r1] concern\` lines. The parser expects [finding:<id>|<sev>]."
if [[ -n "$(retired_grammar_in "$_synthetic")" ]]; then
  ok "retired-grammar detector fires on a severity-less [finding:] that also names the live form"
else
  bad "retired-grammar detector misses a severity-less [finding:] — a complying reviewer hard-fails the parser (codex-rd2-r1)"
fi
# ...and must NOT fire on the live grammar alone, or it fails every correct document.
if [[ -z "$(retired_grammar_in 'Append \`> [finding:<id>|<sev>] <concern>\` under ## Review.')" ]]; then
  ok "retired-grammar detector accepts the live [finding:<id>|<sev>] form"
else
  bad "retired-grammar detector rejects the LIVE grammar — it would fail a correct memory file"
fi

for mf in CLAUDE.md AGENTS.md; do
  f="${ROOT}/${mf}"
  if [[ ! -f "$f" ]]; then bad "${mf} missing"; continue; fi
  # Scope to the reviewer-role section: the rest of the file may legitimately discuss history.
  sec="$(awk '/^### Multi-review \(reviewer role\)/{on=1} on{print} on && /^### How this repo applies/{exit}' "$f")"
  if [[ -z "$sec" ]]; then bad "${mf}: no '### Multi-review (reviewer role)' section to check"; continue; fi
  retired="$(retired_grammar_in "$sec")"
  [[ -z "$retired" ]] \
    && ok "${mf}: reviewer role teaches no retired grammar" \
    || bad "${mf}: reviewer role instructs retired grammar (${retired}) — a complying reviewer is quarantined as a non-response"
  grep -qF '[finding:<id>|<sev>]' <<<"$sec" \
    && ok "${mf}: reviewer role names the live finding grammar" \
    || bad "${mf}: reviewer role does not name the live '[finding:<id>|<sev>]' grammar"
  grep -qF '[no-findings]' <<<"$sec" \
    && ok "${mf}: reviewer role names the no-findings signal" \
    || bad "${mf}: reviewer role omits [no-findings] — a silent clean turn is quarantined"
done

# --- the dispatched reviewer is told to ignore repo memory files ---
# Independence is the point of the star, and a target repo's CLAUDE.md/AGENTS.md is the author's
# standing instruction set — context the topology never accounted for. The prompt must say the
# inlined contract is complete, or a reviewer weighs the author's own words while reviewing them.
D="$(mktemp -d)"; printf '# D\n\n<!-- multi-review: awaiting-reviewer -->\n\n## Review\n' > "$D/d.md"
for p in fable codex gemini; do
  out="$(bash "${ROOT}/scripts/multi-review-reviewer.sh" prompt "$D/d.md" --reviewer "$p" 2>/dev/null)"
  grep -qiE 'CLAUDE\.md|AGENTS\.md|memory file' <<<"$out" \
    && ok "prompt($p) tells the reviewer to ignore repo memory files" \
    || bad "prompt($p) never mentions repo memory files — an injected CLAUDE.md silently outranks the contract"
done
rm -rf "$D"
# --- #66 wiring: one root, captured before anything can move the cwd ---
#
# Both halves shipped broken and were found by re-reading the file, not by a test.
DR="${ROOT}/commands/multi-review.md"
if [[ -f "$DR" ]]; then
  # (a) ensure-skill must take the CAPTURED session root. An inline substitution resolves in
  # whatever cwd the primary is standing in, and by fan-out the egress guard has pushed it into
  # the repo that owns the doc — while the dispatched subagent inherits the SESSION cwd. The two
  # differ in exactly the cross-repo case #66 is about, and the bundle then materializes into a
  # repo the reviewer never sees.
  es="$(grep -n -A 6 'Provision each secondary' "$DR" | grep -- '--repo' || true)"
  if [[ -z "$es" ]]; then
    bad "no 'ensure-skill --repo' instruction found in the fan-out step"
  elif grep -qE -- '--repo[[:space:]]*"?\$\(' <<<"$es"; then
    bad "ensure-skill --repo inlines a command substitution — it re-resolves in the guard-forced cwd, not the session root (#66)"
  elif grep -qF -- '--repo "<session-root>"' <<<"$es"; then
    ok "ensure-skill --repo uses the captured <session-root>"
  else
    bad "ensure-skill --repo does not pass the captured <session-root> placeholder: ${es}"
  fi

  # (b) the capture must come BEFORE the egress guard. The guard resolves MULTI_REVIEW_DOC_DIRS
  # relative to the cwd, so on a cross-repo doc it refuses until the primary moves — and after the
  # move `git rev-parse` returns the doc's repo. Capturing later yields the wrong value silently,
  # which is the bug --session-root exists to fix. Ordering IS the guarantee here.
  cap_ln="$(grep -n 'Capture the session root FIRST' "$DR" | head -1 | cut -d: -f1)"
  eg_ln="$(grep -n 'multi-review-egress-guard.sh "<doc>"' "$DR" | head -1 | cut -d: -f1)"
  if [[ -z "$cap_ln" || -z "$eg_ln" ]]; then
    bad "cannot locate both the session-root capture and the egress guard in $(basename "$DR")"
  elif (( cap_ln < eg_ln )); then
    ok "session root is captured before the egress guard can force a directory change"
  else
    bad "session-root capture (line ${cap_ln}) comes AFTER the egress guard (line ${eg_ln}) — by then the original cwd is gone and the captured value is the doc's repo (#66)"
  fi

  # (c) the model-id collision must be a GATE, not a caution. Prose alone is what let a supported
  # configuration (a fable-powered primary) brick a review with no mechanical defense.
  if grep -qF 'check-primary-id "<doc>" "<primary-model-id>"' "$DR"; then
    ok "the primary turn runs check-primary-id before writing a response"
  else
    bad "the primary turn does not run check-primary-id — the collision deadlock is defended by prose only"
  fi
fi

# --- the exit-8 retry path must carry a FINITE budget (codex-rd1-r1 on PR #78) ---
#
# Exit 8 means "the reviewer is still writing", and the correct response is to wait again rather
# than quarantine a turn in progress. But this command is AUTONOMOUS by default: an autonomous
# primary has no patience to run out, so "re-run as many times as you are willing to spend" is not
# a stopping rule. Without a number, a copy that changes on every poll keeps returning 8 and the
# round never reaches verification or a deliberate quarantine.
f="${ROOT}/commands/multi-review.md"
if [[ -f "$f" ]]; then
  # The exit-8 bullet plus the following few lines, where the budget must live.
  n="$(grep -n '\*\*Exit 8\*\*' "$f" | head -1 | cut -d: -f1)"
  if [[ -z "$n" ]]; then
    bad "no exit-8 branch documented in $(basename "$f")"
  else
    blk="$(sed -n "${n},$((n+8))p" "$f")"
    if grep -qE 'at most [0-9]+|no more than [0-9]+|up to [0-9]+ (more )?(re-?run|retr|wait)' <<<"$blk"; then
      ok "exit-8 retry carries a finite budget"
    else
      bad "exit-8 retry has no finite budget — an autonomous primary can re-wait forever and the round never resolves"
    fi
    grep -qiE 'willing to spend|your patience' <<<"$blk" \
      && bad "exit-8 retry still bounds itself by the primary's patience, which an autonomous run does not have" \
      || ok "exit-8 retry is not bounded by operator patience"
  fi
fi

# --- the shell (gemini) dispatch must pin its launch cwd (G2, the other half of #66) ---
#
# gemini-cli's workspace is the cwd of the process at LAUNCH, and it refuses reads and writes
# outside it. The shell branch set no directory, so the workspace was whatever cwd that Bash call
# happened to have — which is the same check-cwd-vs-dispatch-cwd drift #66 fixed for codex, and
# which this file used to DOCUMENT for gemini instead of closing.
DR="${ROOT}/commands/multi-review.md"
if [[ -f "$DR" ]]; then
  n="$(grep -n '\*\*`shell`\*\*' "$DR" | head -1 | cut -d: -f1)"
  ne="$(awk -v s="$n" 'NR>s && /^5\. \*\*/ {print NR; exit}' "$DR")"
  if [[ -z "$n" || -z "$ne" ]]; then
    bad "cannot delimit the shell-kind dispatch branch in $(basename "$DR")"
  else
    # Bounded by the NEXT numbered step, not a line offset. This window was 22, then 30, and each
    # time an edit pushed its target onto the last row where the next insertion would silently end
    # coverage (fable-rd2-r5). A structural bound cannot drift that way.
    blk="$(sed -n "${n},$((ne-1))p" "$DR")"
    grep -qE 'cd "<session-root>"' <<<"$blk" \
      && ok "shell dispatch pins its launch cwd to <session-root>" \
      || bad "shell dispatch sets no cwd — gemini's workspace is then whatever directory the call inherits (G2/#66)"
  fi
  # ...and the file must stop claiming the gap it no longer has.
  grep -qiE 'only the codex arm consumes' "$DR" \
    && bad "multi-review.md still says only codex consumes --session-root — stale now that the gemini arm does too" \
    || ok "no stale 'only codex consumes --session-root' claim"
fi

# --- the empty-argv guard must DO something a primary can act on ---
#
# The guard's action shipped as `{ : quarantine <id> "…"; }`. It reads like an instruction, but `:`
# is bash's null builtin: a primary that transcribes the block verbatim — which is exactly what the
# block is for — runs a no-op. No quarantine is recorded, dispatch is (correctly) skipped, and the
# provider's absence resurfaces at step 5 as exit 9, reported as `no turn taken` — the reason for a
# reviewer that declined, not one that was never launched. The block must emit an observable signal,
# and the prose must bind that signal to a quarantine record.
DR="${ROOT}/commands/multi-review.md"
if [[ -f "$DR" ]]; then
  n="$(grep -n '\*\*`shell`\*\*' "$DR" | head -1 | cut -d: -f1)"
  ne="$(awk -v s="$n" 'NR>s && /^5\. \*\*/ {print NR; exit}' "$DR")"
  if [[ -z "$n" || -z "$ne" ]]; then
    bad "cannot delimit the shell-kind dispatch branch in $(basename "$DR")"
  else
    blk="$(sed -n "${n},$((ne-1))p" "$DR")"
    # The empty-argv guard is the `||` arm; the dispatch line is the `&&` arm. Only the former.
    eg="$(grep -F '${#argv[@]}' <<<"$blk" | grep -F '||' || true)"
    if [[ -z "$eg" ]]; then
      bad "shell dispatch has no empty-argv guard — \"\${argv[@]}\" on a zero-element array is fatal under set -u on bash 3.2"
    elif grep -qE '\|\|[[:space:]]*\{?[[:space:]]*:[[:space:]]' <<<"$eg"; then
      bad "the empty-argv guard's action is the ':' null builtin — transcribed verbatim it does nothing, and the miss resurfaces at step 5 as 'no turn taken'"
    elif grep -qF 'DISPATCH-FAILED' <<<"$eg"; then
      ok "the empty-argv guard emits an observable DISPATCH-FAILED signal"
    else
      bad "the empty-argv guard takes no observable action: ${eg}"
    fi
    # ...and the signal must be wired to the quarantine path, or it is just output nobody consumes.
    win="$(sed -n "${n},$((ne-1))p" "$DR")"
    if grep -qF 'DISPATCH-FAILED' <<<"$win" && grep -qF -- '--quarantined' <<<"$win"; then
      ok "the DISPATCH-FAILED signal is bound to a --quarantined record"
    else
      bad "nothing tells the primary what to DO with an un-dispatchable shell reviewer — the signal never reaches the quarantine path"
    fi
  fi
fi

# --- a CRASHED shell reviewer must be distinguishable from a SLOW one (G3) ---
#
# The shell branch consulted neither exit code nor stderr. A gemini that died on launch — bad flag,
# expired auth, exhausted quota — left a copy byte-identical to its seed, which is byte-identical to
# what a reviewer still thinking produces. The primary then spent the grace re-run and the whole
# retry budget re-waiting on a dead process, and quarantined it as `no turn taken`: the reason for a
# reviewer that read the doc and declined. The cause was on the process's own stderr the entire time.
DR="${ROOT}/commands/multi-review.md"
if [[ -f "$DR" ]]; then
  # Bound both windows by DOCUMENT STRUCTURE, not by a line offset. Two fixed offsets in a row
  # (22, then 30) ended up with the target sitting on the window's last row, where the next
  # insertion silently ends the guard's coverage — fable-rd2-r5 caught the second one. A window
  # that runs to the next numbered step cannot drift that way.
  n="$(grep -n '\*\*`shell`\*\*' "$DR" | head -1 | cut -d: -f1)"
  ne="$(awk -v s="$n" 'NR>s && /^5\. \*\*/ {print NR; exit}' "$DR")"
  if [[ -z "$n" || -z "$ne" ]]; then
    bad "cannot delimit the shell-kind dispatch branch in $(basename "$DR")"
  else
    blk="$(sed -n "${n},$((ne-1))p" "$DR")"
    # (a) the dispatch must capture what the process said. Assert it on the DISPATCH LINE, not
    # anywhere in the block: the status line below also names the log, so a block-wide grep stays
    # green with the redirect deleted and proves nothing. Name it `*.multi-review.log`, which
    # .gitignore already covers — a new artifact shape would leak into every consuming repo.
    dl="$(grep -F 'cd "<session-root>"' <<<"$blk" || true)"
    if [[ -z "$dl" ]]; then
      bad "cannot find the shell dispatch line to check its redirect"
    elif grep -qE '>[[:space:]]*"<doc>\.<id>\.multi-review\.log"' <<<"$dl" && grep -qF '2>&1' <<<"$dl"; then
      ok "shell dispatch captures the reviewer's output to a log"
    else
      bad "shell dispatch discards the reviewer's stdout/stderr — a crash leaves no trace and reads as slowness (G3)"
    fi
    # (b) ...and its EXIT STATUS, written so it is findable AS A LINE. A bare `echo` appends onto
    # whatever the process last wrote, and a process that dies mid-write leaves no trailing
    # newline — producing `quota exceededmulti-review: dispatch exited 1`, which no line-anchored
    # read finds. That disarms the detection in precisely the crash it was built for; both
    # secondaries found it independently on PR #84 (codex-rd1-r1 / fable-rd1-r2).
    sl="$(grep -F '>>"<doc>.<id>.multi-review.log"' <<<"$blk" || true)"
    if [[ -z "$sl" ]] || ! grep -qF 'dispatch exited' <<<"$sl"; then
      bad "shell dispatch records no exit status — the log cannot say whether the process died or merely warned (G3)"
    elif grep -qE '^[[:space:]]*echo ' <<<"$sl"; then
      bad "the exit status is appended with a bare echo — a process dying without a trailing newline glues it onto the last output line and the status stops being findable as a line"
    elif grep -qF "printf \"\\n" <<<"$sl" || grep -qF "printf '\\n" <<<"$sl"; then
      ok "the exit status is written line-anchored (printf with a leading newline)"
    else
      bad "the exit status is not guaranteed to start on its own line: ${sl}"
    fi
    # (c) the stale-log removal must NOT live in the dispatch block. That block runs as a
    # background task, so a removal inside it races the primary's own pre-wait read of the same
    # file — the fix for fable-rd1-r4 relocated the race instead of closing it (fable-rd2-r1).
    if grep -qE '^[[:space:]]*rm -f "<doc>\.<id>\.multi-review\.log"' <<<"$blk"; then
      bad "the stale-log removal sits inside the backgrounded dispatch — it races the pre-wait read it exists to prevent"
    else
      ok "the stale-log removal is not inside the backgrounded dispatch"
    fi
  fi

  # (d) ...it lives in the SEEDING step instead, which the primary runs synchronously before any
  # reviewer is dispatched, so nothing can race it.
  sd="$(grep -n 'snapshot each copy as' "$DR" | head -1 | cut -d: -f1)"
  # Bounded by the step that follows it, not an offset. A fixed window here would re-seed the
  # exact class this file just converted away from — flagged as fable-rd3-r3.
  sde="$(awk -v s="$sd" 'NR>s && /Then prove the copy is BLIND/ {print NR; exit}' "$DR")"
  if [[ -z "$sd" || -z "$sde" ]]; then
    bad "cannot delimit the seed-snapshot step in $(basename "$DR")"
  elif grep -qF 'rm -f "<doc>.<id>.multi-review.log"' <<<"$(sed -n "${sd},$((sde-1))p" "$DR")"; then
    ok "the previous round's dispatch log is cleared synchronously, in the seeding step"
  else
    bad "nothing clears the previous round's dispatch log before dispatch — a pre-wait read can quarantine a just-launched reviewer on round N-1's status line"
  fi

  # (e) the log has to be CONSULTED, or it is evidence nobody reads. The bound-hit decision is
  # where `no turn taken` gets chosen over `the process died`.
  w="$(grep -n 'Bound the wait, per copy' "$DR" | head -1 | cut -d: -f1)"
  we="$(awk -v s="$w" 'NR>s && /^6\. \*\*/ {print NR; exit}' "$DR")"
  if [[ -z "$w" || -z "$we" ]]; then
    bad "cannot delimit the wait step in $(basename "$DR")"
  else
    wblk="$(sed -n "${w},$((we-1))p" "$DR")"
    # Match the INSTRUCTION to read it, not merely the filename appearing somewhere in the window.
    # The quarantine-reason line below also names the log, so a bare filename grep here stays green
    # with the read instruction deleted — it SURVIVED the mutation sweep exactly that way.
    if grep -qE 'read `<doc>\.<id>\.multi-review\.log`' <<<"$wblk"; then
      ok "a bound hit consults the dispatch log before choosing a quarantine reason"
    else
      bad "the wait step never reads the dispatch log — a dead reviewer still consumes the full retry budget and is reported as 'no turn taken' (G3)"
    fi
    # (f) the sentinel search must take the LAST match. The log is verbatim CLI output, and a
    # reviewer echoing this protocol's own text reproduces the string — which in this repo's
    # self-reviews is not hypothetical, the reviewed material contains it (fable-rd2-r4).
    if grep -qiF 'final non-empty line' <<<"$wblk"; then
      ok "the status counts only as the log's final non-empty line"
    else
      bad "the status is accepted from anywhere in the log — while the reviewer is still alive the real status does not exist yet, so echoed protocol text is the last match and a live reviewer reads as exited"
    fi
    # (g) a FLIPPED MARKER OUTRANKS the status. A CLI can write its turn, flip, and only then die
    # (teardown, or a post-edit call that exhausts a quota). Quarantining on the status alone
    # discards a completed turn and every finding in it — strictly worse than the bug the log
    # fixes, and reachable the moment the log exists (fable-rd1-r1).
    if grep -qF 'Marker says `awaiting-author`' <<<"$wblk" && grep -qF 'never quarantine' <<<"$wblk"; then
      ok "a flipped marker outranks a non-zero dispatch status"
    else
      bad "a reviewer that finished its turn and then died is quarantined on its exit status alone, discarding a completed turn and its findings"
    fi
    # (h) a copy that CHANGED before dying must not be re-waited, and must not be discarded. The
    # exit-8 retry path assumes the reviewer is "demonstrably alive and still writing", which the
    # status disproves; and this state is byte-identical to the rc-zero one the doc calls
    # recoverable, so the exit code must not decide their opposite fates (fable-rd2-r2/r3).
    if grep -qF 'copy CHANGED since its seed' <<<"$wblk" && grep -qF 'Do **not** re-wait' <<<"$wblk"; then
      ok "a copy that wrote findings then died is recovered, not re-waited and not discarded"
    else
      bad "a reviewer that wrote findings then died is re-waited on a dead process and its partial findings discarded"
    fi
    # (i) the quarantine reason must NAME the log, not copy it. Reasons are recorded durably in the
    # doc and rendered at the gate; the log is gitignored and local. The line most likely to sit at
    # the end of a failed dispatch is an auth error — the one most likely to carry a credential
    # (fable-rd1-r3).
    if grep -qF 'do not paste its text into the reason' <<<"$wblk"; then
      ok "the quarantine reason names the log rather than copying its text"
    else
      bad "the quarantine reason pastes log text into a durably-recorded field — an auth error there carries a credential out of the gitignored log and into the doc and gate"
    fi
  fi
fi

# --- loud undispatchable reviewer: the command must bind resolve-set's new contract ------------
CMD="${ROOT}/commands/multi-review.md"

grep -q -- '`--allow-missing`' "$CMD" \
  && ok "command: --allow-missing is documented" || bad "command: --allow-missing absent"

# §1 must EXTRACT it, or `/multi-review <doc> --allow-missing` folds the flag into the doc path
n="$(grep -n 'Extract `--reviewers`' "$CMD" | head -1 | cut -d: -f1)"
[[ -n "$n" ]] && grep -q -- '--allow-missing' <<<"$(sed -n "${n}p" "$CMD")" \
  && ok "command: §1 extracts --allow-missing alongside --reviewers" \
  || bad "command: §1 does not extract --allow-missing (line $n)"

# The resume rebuild must pass --resume, or a review goes unresumable on exit 4.
#
# ANCHOR ON THE PART STEP 4 DOES NOT TOUCH. The obvious anchor — the whole pre-edit call string
# `resolve-set --fable-floor --reviewers <ids,comma,joined>` — is exactly what Step 4 rewrites, by
# inserting `--resume` between `--fable-floor` and `--reviewers`. So the grep matches BEFORE the
# implementation and never again: `n` comes back empty and the guard reports
# `resume rebuild lacks --resume (line )` — with the empty line number — permanently red at GREEN.
# Reproduced by applying Step 4's substitution to a copy of the command file and re-running the
# grep (gemini-rd2-test-anchor-mismatch, fable-rd2-r1). `<ids,comma,joined>` is the stable part.
n="$(grep -n '<ids,comma,joined>' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: resume-rebuild anchor '<ids,comma,joined>' not found — the guard's anchor is gone"
else
  grep -q -- 'resolve-set' <<<"$(sed -n "${n}p" "$CMD")" \
    && grep -q -- '--resume' <<<"$(sed -n "${n}p" "$CMD")" \
    && ok "command: the resume rebuild passes --resume" \
    || bad "command: resume rebuild lacks --resume (line $n): $(sed -n "${n}p" "$CMD")"
fi

# The resume branch is the one path a dropped reviewer PROCEEDS by design (`--resume` proceeds
# where a fresh ask would refuse), which makes it the one path where silently skipping the
# quarantine-binding rule is most damaging. Step 2's bullet list carries that rule, and the resume
# branch bypasses step 2 entirely ("Go to §3") — so the rebuild's OWN block must repeat it.
#
# ANCHORED TO THE RESUME-REBUILD LINE'S IMMEDIATE BLOCK, NOT A FILE-WIDE GREP. A file-wide
# `grep -q 'UNDISPATCHABLE' "$CMD"` already passes today — the string appears elsewhere in the doc
# (step 2's own bullet) — so it would stay green even with this branch's block silent on the rule.
n="$(grep -n '<ids,comma,joined>' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: resume-rebuild anchor '<ids,comma,joined>' not found — the guard's anchor is gone"
else
  grep -q 'UNDISPATCHABLE' <<<"$(sed -n "${n},$((n+3))p" "$CMD")" \
    && ok "command: the resume-rebuild block captures UNDISPATCHABLE lines" \
    || bad "command: resume-rebuild block never mentions UNDISPATCHABLE — the quarantine-binding rule routes past this path"
fi

# EXTRACTING the flag is not FORWARDING it. §2's fresh-request call is the only place --allow-missing
# reaches resolve-set, and resolve-set is the only thing that acts on it — so without this the
# engineer types the documented opt-out, §1 dutifully parses it off the positional, and the run
# still exits 4 with the flag sitting in a variable nobody passes on (codex-rd1-r1).
n="$(grep -n 'resolve-set --fable-floor --pref-file' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: §2 invocation anchor not found — the guard's window is gone"
else
  # END THE WINDOW BEFORE THE EXIT-CODE BULLETS. Step 6 writes "Re-run with \`--allow-missing\`"
  # into §2's Exit-4 bullet, and those bullets live inside the SAME numbered step as the invocation
  # — verified against the real file: anchor at line 128, next numbered step at 156, `- **Exit N**`
  # bullets in between. A window reaching them is satisfied by Step 6's prose alone, so the guard
  # would pass with Step 5's forwarding edit reverted: a later step feeding an earlier guard the
  # string it greps for, which is precisely the class round 2 caught (fable-rd3-r2).
  ne="$(awk -v s="$n" 'NR>s && (/^ *- \*\*Exit/ || /^[0-9]+\. / || /^#### / || /^### / || /^## /) {print NR; exit}' "$CMD")"
  # No terminator at all -> bound at EOF rather than routing to `bad`, so a structural collapse
  # never reads as a prose failure (gemini-rd3-r1; same rule as the roster guard below).
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  grep -q -- '--allow-missing' <<<"$(sed -n "${n},$((ne-1))p" "$CMD")" \
    && ok "command: §2 forwards --allow-missing to resolve-set" \
    || bad "command: --allow-missing is extracted but never forwarded (window ${n}..$((ne-1)))"
fi

grep -q 'Exit 4' "$CMD" && ok "command: exit 4 is routed" || bad "command: exit 4 unrouted"
grep -q 'UNDISPATCHABLE' "$CMD" \
  && ok "command: the UNDISPATCHABLE binding is documented" || bad "command: no UNDISPATCHABLE binding"

# the roster must be asked-for ∪ floor, not the resolved set — a resolved-only roster drops a
# quarantined provider out of `admitted` accounting AND drops a clean floored fable out of it too
#
# Window bounds must be checked, not assumed. If the anchor moves, `n` comes back empty and
# `awk -v s=""` compares against a string; if no following heading exists, `ne` is empty and
# `$((ne-1))` is `-1`, so `sed -n "n,-1p"` errors out and the guard reports `bad` for a structural
# reason rather than the prose it checks (fable-rd1-r8). Bound to EOF when no heading follows, and
# fail loudly when the anchor itself is gone — a guard whose window collapsed must not read as a
# prose failure.
# ANCHOR ON 'multi-review-mode: star', NOT 'reviewers: <ids>'. The latter also matches §2 step 1's
# unrelated "Read the `reviewers: <ids>` suffix off that header line" (pre-existing, outside this
# task's edits) — earlier in the file, so `head -1` locks onto it and the window closes at the next
# `- **` bullet inside §2, long before reaching §3's roster line. That anchor is permanently
# unsatisfiable no matter what §3 says: the window it opens never contains the roster prose.
n="$(grep -n 'multi-review-mode: star' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: roster anchor 'multi-review-mode: star' not found — the guard's window is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /^ *- \*\*|^#### |^### / {print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"   # no following heading -> bound at EOF
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -q 'UNDISPATCHABLE' <<<"$blk" \
    && ok "command: the roster includes ids dropped as UNDISPATCHABLE" \
    || bad "command: roster is still the resolved set only"
fi

# --- the macOS locale-pin job must PIN the locale it depends on ---
# `star/undispatchable-reason-locale-pinned` expects `caught` on Darwin because BSD tr/sed abort on
# an invalid UTF-8 byte UNDER A UTF-8 LOCALE. That precondition is the runner's ambient locale, and
# nothing pinned it: under a C/POSIX environment the un-pinned pipeline passes the byte through
# intact, the mutation is behaviourally inert, the named assertion stays green, and the entry
# reports SURVIVED — the job fails for a reason that has nothing to do with the code.
# It passed only because macos-latest happens to default to UTF-8 (fable-rd1-r1 on PR #91).
W="${ROOT}/.github/workflows/gate.yml"
if [[ ! -f "$W" ]]; then
  bad "gate.yml missing"
else
  n="$(grep -n 'mutation-macos-locale:' "$W" | head -1 | cut -d: -f1)"
  if [[ -z "$n" ]]; then
    bad "gate.yml: the mutation-macos-locale job is gone — the Darwin arm has no CI proof again"
  else
    ne="$(awk -v s="$n" 'NR>s && /^  [a-z]/ {print NR; exit}' "$W")"
    [[ -n "$ne" ]] || ne="$(( $(wc -l < "$W") + 1 ))"
    blk="$(sed -n "${n},$((ne-1))p" "$W")"
    # LC_ALL SPECIFICALLY, not "LC_ALL or LANG". The alternation made this guard unfalsifiable:
    # with both pinned, deleting LC_ALL still matched LANG and the assertion stayed green — the
    # mutation sweep reported `ci/macos-locale-job-pinned` SURVIVED, which is how it was found.
    grep -qE '^[[:space:]]*LC_ALL:' <<<"$(grep -vE '^[[:space:]]*#' <<<"$blk")" \
      && ok "gate.yml: the macos locale-pin job pins LC_ALL" \
      || bad "gate.yml: the macos locale-pin job pins no LC_ALL — its 'caught' expectation rides on the runner's ambient locale, and goes SURVIVED under C/POSIX"
    # STRIP COMMENTS FIRST. The job's own comment explains the UTF-8 precondition, so a bare
    # grep for UTF-8 over the block matches the prose and passes with no pin present at all —
    # verified: it reported ok while the job pinned nothing.
    pin="$(grep -vE '^[[:space:]]*#' <<<"$blk" | grep -E '^[[:space:]]*LC_ALL:')"
    grep -qE 'UTF-8' <<<"$pin" \
      && ok "gate.yml: the pinned locale is a UTF-8 one" \
      || bad "gate.yml: the job pins a locale that is not UTF-8 — the mutation is inert without it"
  fi
fi


# --- the crossref pass must be dispatched, announced, and excluded from the secondary count ---
CMD="${ROOT}/commands/multi-review.md"
n="$(grep -n 'multi-review-crossref.sh rows' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: the crossref row derivation is never invoked"
else
  # WINDOWED to the crossref step only (through the line before the NEXT top-level numbered
  # step), not a fixed +12 or a file-wide grep. A file-wide/fixed-window match is satisfied by
  # text that lives ANYWHERE else in the doc — including the blockquote this same step records —
  # so a guard phrased that way can go green while the actual instruction it names was deleted
  # (round 1, F1/F5: reviewed on the most capable model, verified by deleting the real trigger
  # lines and watching these stay green under the old phrasing).
  ne="$(awk -v s="$n" 'NR>s && /^9\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"

  # Matches ONLY the exit-3 prose trigger ("State that out loud"), not the
  # `> [crossref-coverage: not applicable]` blockquote the same branch also writes — the two are
  # asserted separately below, and this one must go red on its own when the prose is deleted.
  grep -qF 'State that out loud' <<<"$blk" \
    && ok "command: the not-applicable case is announced" \
    || bad "command: exit 3 is not announced — a pass that silently does not run reads as a clean one"

  # Round 2, F9: the not-applicable STATE must actually be recorded, symmetric with the <M>/<M>
  # and <N>/<M> guards below. This guard was present before round 1's F1/F3 restructuring and got
  # dropped, unreplaced, when that restructuring landed — the suite stayed green the whole time,
  # which is the exact failure class this feature exists to catch. Pattern is the bracketed
  # blockquote text, NOT a bare 'not applicable' (that also matches the prose trigger above, which
  # is what made the ORIGINAL F1 guard vacuous) — count confirmed 1 in the current file.
  grep -qF 'crossref-coverage: not applicable]' <<<"$blk" \
    && ok "command: the not-applicable coverage state is recorded" \
    || bad "command: the not-applicable coverage state is never recorded — an exit-3 round announces the fact in prose but leaves no durable line for the gate, so Task 6 has nothing to render for this state"

  # NOTE: this window now spans steps 2-8 (the pass's pieces are dispatched/seeded/waited on
  # inside the round-1 fan-out proper, by design — see the three placement-specific guards
  # below), so this assertion only proves the check is invoked SOMEWHERE in the fan-out, not
  # that it still lives in one contiguous "crossref step". Placement of the dispatch, the seed,
  # and the wait each have their OWN windowed guard below; this one is deliberately weaker now,
  # and its message says so.
  grep -qF 'multi-review-crossref.sh check' <<<"$blk" \
    && ok "command: the coverage check is invoked somewhere in the fan-out" \
    || bad "command: the crossref copy is never coverage-checked anywhere in the fan-out"

  # Split from a single 'rows verdicted]' pattern (round 1, F3): that pattern is satisfied by
  # EITHER the complete or the incomplete line alone, so deleting just one of them left it green.
  grep -qF '<M>/<M> rows verdicted]' <<<"$blk" \
    && ok "command: the complete-coverage (N/N) state is recorded" \
    || bad "command: the complete-coverage crossref-coverage state is never recorded — a fully-verdicted turn leaves no durable count for the gate"
  grep -qF '<N>/<M> rows verdicted]' <<<"$blk" \
    && ok "command: the incomplete-coverage (N/M) state is recorded" \
    || bad "command: the incomplete-coverage crossref-coverage state is never recorded — a partially-verdicted turn leaves no durable count for the gate"

  # Round 1, F2: `check` exits 1 for FOUR distinct reviewer-side failures (missing verdicts,
  # missing disclosure, a verdict naming an unemitted row, a defect naming an absent finding),
  # and every one of them must still be recorded — not routed into the "usage/infra, nothing
  # recorded" bucket that exit 2 alone owns.
  # `**Exit 1** →`, NOT a bare 'Exit 1': the bare form is a substring of 'Exit 10' (the wait's own
  # exit code, mentioned two paragraphs above in the same window) and stays green regardless of
  # whether this branch exists — caught live while writing this guard.
  grep -qF '**Exit 1** →' <<<"$blk" \
    && ok "command: check's exit 1 is handled as its own branch, distinct from a usage error" \
    || bad "command: check's exit 1 (a reviewer-side failure) is not distinguished from exit 2 (a usage error) — every non-incomplete-turn exit-1 reason falls into 'nothing is recorded for it'"

  # Round 1, F4: an incomplete crossref turn must be reported, never quarantined — the rows it
  # DID verdict still count. Inverting this single line to "and quarantine the pass" left the
  # suite green before this guard existed.
  grep -qF 'Do NOT quarantine anything for it' <<<"$blk" \
    && ok "command: an incomplete crossref turn is reported without being quarantined" \
    || bad "command: nothing says an incomplete crossref turn must NOT be quarantined — the rows it DID verdict could be silently discarded"
fi

# --- fix round 1, F1: the pass's seed/dispatch/wait are now INSIDE the round-1 fan-out proper
# (steps 2, 4, 5), not a self-contained "crossref step" — the big window above proves the check
# still runs SOMEWHERE, but nothing proved the seed/dispatch/wait survived the move. Each got its
# own guard, windowed to the exact step it now lives in, so deleting any one of the three reds on
# its own without needing to delete the others.

# the exit-0 seeding (`<doc>.crossref` + `<doc>.crossref.seed`) must live in step 2.
n="$(grep -nF 'Derive the crossref worklist here too' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: step 2's crossref-worklist derivation is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /^3\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qF '<doc>.crossref.seed' <<<"$blk" \
    && ok "command: the crossref pass is seeded (incl. .seed) in step 2" \
    || bad "command: step 2 no longer seeds <doc>.crossref/<doc>.crossref.seed — the pass would have no copy to dispatch in step 4"
fi

# the dispatch (the actual Agent task text) must live in step 4, with the secondaries.
n="$(grep -nF 'If step 2 derived a crossref worklist' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: step 4's crossref dispatch is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /^5\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qF 'prompt "<doc>.crossref" --crossref' <<<"$blk" \
    && ok "command: the crossref pass is actually dispatched in step 4, alongside the secondaries" \
    || bad "command: step 4 no longer dispatches <doc>.crossref — its copy would never get a turn"
fi

# the wait-with-the-secondaries paragraph must live in step 5.
n="$(grep -nF 'Wait on the crossref pass here too' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: step 5's crossref wait is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /^6\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qF '<doc>.crossref.seed' <<<"$blk" \
    && ok "command: step 5 waits on the crossref pass with the secondaries" \
    || bad "command: step 5 no longer waits on <doc>.crossref — merge could run before the pass ever writes anything"
fi

# WINDOWED to step 2's CROSSREF paragraph. A file-wide `grep -n 'is not a secondary' | head -1` was
# satisfied by the SYMCHECK paragraph (#89) that now follows this one — delete crossref's sentence
# and the guard stayed green on symcheck's. Caught by the full sweep as
# `command/crossref-not-a-secondary` SURVIVED; the same window end is why the round-1-only guard
# below needed it too.
n="$(grep -nF 'Derive the crossref worklist here too' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: step 2's crossref-worklist derivation is gone"
else
  ne="$(awk -v s="$n" 'NR>s && (/^3\. / || /Derive the symcheck worklist here too/){print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qF 'is not a secondary' <<<"$blk" \
    && ok "command: the pass is excluded from the secondary count" \
    || bad "command: nothing says the crossref pass is not a secondary — it would inflate the roster and skew the independence warning"
fi

# --- final review, B4: commands/multi-review.md must say the crossref pass runs ROUND 1 ONLY,
# matching docs/multi-review.md ("dispatched alongside the secondaries in round 1") and spec §7
# ("This also means the pass costs one dispatch per review, not one per round"). Two shipped files
# disagreed on this in the same branch — nothing checked it. Windowed to step 2's crossref
# paragraph, the same style as the other step-scoped guards above.
n="$(grep -nF 'Derive the crossref worklist here too' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: step 2's crossref-worklist derivation is gone"
else
  # Window ends at the SYMCHECK paragraph too, not just at step 3: that paragraph also says
  # "ROUND 1 ONLY", so a window running to step 3 stayed green with crossref's own statement
  # deleted (full sweep: `command/crossref-round-1-only` SURVIVED).
  ne="$(awk -v s="$n" 'NR>s && (/^3\. / || /Derive the symcheck worklist here too/){print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qiE 'round 1 only' <<<"$blk" \
    && ok "command: step 2 states the crossref pass is round 1 only" \
    || bad "command: step 2 never says the crossref pass is round 1 only (spec §7: one dispatch per review, not one per round)"
  grep -qiF 'every round' <<<"$blk" \
    && bad "command: step 2 still says the crossref worklist is derived every round — contradicts docs/multi-review.md and spec §7 (R13: round 1 only)" \
    || ok "command: step 2 does not say the crossref worklist is derived every round"
fi

# --- Task 7: the crossref pass's defects must actually reach adjudication ---------------------
# Spec §0 claimed the pass's findings "merge through the existing finding channel" with no other
# change needed. False as written (see task-7-brief.md): merge dies on `<doc>.crossref` unless
# given --pass, which bypasses the reviewer-registry check a bare `<doc>` positional would fail.
# ($CMD is already set above, to the same path — no need to re-assign it.)

# merge must be invoked with --pass "<doc>.crossref" — windowed to the Merge step only (through
# the line before step 8), the same style as the crossref-step window above.
n="$(grep -nF '**Merge.**' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: the Merge step ('**Merge.**') is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /^8\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qF -- '--pass "<doc>.crossref"' <<<"$blk" \
    && ok "command: merge is invoked with --pass \"<doc>.crossref\"" \
    || bad "command: merge is never given --pass \"<doc>.crossref\" — the pass's findings are derived and checked but never reach the merged doc"
fi

# the crossref copy must be explicitly exempted from verify-vendor — windowed to the Verify
# identity step only (through the line before step 7).
#
# fix round 1, F2: the ORIGINAL guard required 'not run through' AND 'verify-vendor' as two
# independent greps over the same window. `verify-vendor` alone has FOUR matches in this window
# (two of them the PRE-EXISTING ordinary-copy verify-vendor invocation, unrelated to the crossref
# exemption), so that half of the conjunct is inert — only 'not run through' ever does any work.
# Proof: rewriting the exemption sentence to name `channel-check` instead of `verify-vendor` left
# this guard green (the exemption was gone, but 'verify-vendor' was still present two paragraphs
# up). Fixed by matching the pair as ONE phrase, normalized across the markdown line-wrap between
# "through" and the backtick (`tr` collapses the block to one line first, so a rewrap can't break
# this the way it broke nothing here yet).
n="$(grep -nF 'Verify identity, per copy' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: the Verify identity step is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /^7\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  norm="$(tr '\n' ' ' <<<"$blk" | tr -s ' ')"
  grep -qF 'not run through `verify-vendor`' <<<"$norm" \
    && ok "command: the crossref copy is explicitly exempted from verify-vendor" \
    || bad "command: nothing says the crossref pass skips verify-vendor — a later editor could 'fix' this into checking a pass that has no vendor to verify"
fi

# the terminal gate must release the crossref pass's working files — stated by purpose (R10), not
# a fourth enumerated entry a future working-file kind can miss the same way twice already.
#
# fix round 1, F4: a bare 'crossref' grep from "### Terminal gate" to EOF is falsifiable TODAY,
# but is vacuous by construction against any future 'crossref' mention anywhere after that
# heading (e.g. in Guardrails, below it) — it would never again test the release rule
# specifically. Windowed to the release-rule PARAGRAPH itself (between "human gate" and the
# `<doc>.manifest` carve-out that follows it), and asserting the two file shapes that paragraph
# actually names (`<doc>.crossref.seed` — the provider-or-pass shape; `<doc>.crossref.rows` — the
# one shape that does not fit that pattern and needed naming explicitly).
n="$(grep -nF 'This is the **human gate**:' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: the Terminal gate's human-gate paragraph is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /\*\*Keep `<doc>\.manifest`\.\*\*/{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  # `<doc>.<pass>.rows`, not `<doc>.crossref.rows`: once a SECOND pass exists (#89's symcheck) an
  # enumerated worklist entry is exactly the shape that silently stops covering the next one, which
  # is the failure the paragraph's own prose warns about. Assert the by-purpose shape instead.
  grep -qF '<doc>.crossref.seed' <<<"$blk" && grep -qF '<doc>.<pass>.rows' <<<"$blk" \
    && ok "command: the terminal gate's release rule covers every pass's working files" \
    || bad "command: the terminal gate's release-rule paragraph never names <doc>.crossref.seed/<doc>.<pass>.rows — a pass's working files are never released (R10)"
fi


# --- the symcheck pass must be derived, dispatched, merged, checked and announced ---
# Patterns are the SYMCHECK-prefixed forms, never the bare `<M>/<M> rows verdicted]` the plan
# sketched: that one now has two matches in this file (crossref writes the same shape), so it is
# satisfied by the crossref line alone and would stay green with the whole symcheck branch
# deleted. Counts confirmed 1 each in the current file, and each guard verified by deleting only
# the symcheck line it names.
n="$(grep -n 'multi-review-symcheck.sh rows' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: the symcheck row derivation is never invoked"
else
  ne="$(awk -v s="$n" 'NR>s && /^9\. /{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  grep -qF 'prompt "<doc>.symcheck" --symcheck' <<<"$blk" \
    && ok "command: the symcheck pass is dispatched" \
    || bad "command: nothing dispatches the symcheck pass — rows are derived and never used"
  # `--` before the pattern: without it grep reads `--pass ...` as an option and aborts.
  grep -qF -- '--pass "<doc>.symcheck"' <<<"$blk" \
    && ok "command: the symcheck copy is merged as a pass" \
    || bad "command: the symcheck copy is never merged — its defects reach nothing"
  grep -qF 'multi-review-symcheck.sh check' <<<"$blk" \
    && ok "command: the symcheck coverage check is run" \
    || bad "command: the symcheck copy is never coverage-checked"
  grep -qF 'symcheck-coverage: not applicable]' <<<"$blk" \
    && ok "command: the not-applicable symcheck state is recorded" \
    || bad "command: an exit-3 symcheck round leaves no durable line, so the gate has nothing to render"
  grep -qF 'symcheck-coverage: <M>/<M> rows verdicted]' <<<"$blk" \
    && ok "command: the complete symcheck state is recorded" \
    || bad "command: the complete symcheck coverage state is never recorded"
  grep -qF 'symcheck-coverage: <N>/<M> rows verdicted]' <<<"$blk" \
    && ok "command: the incomplete symcheck state is recorded" \
    || bad "command: the incomplete symcheck coverage state is never recorded"
  grep -qF 'Wait on the symcheck pass here too' <<<"$blk" \
    && ok "command: the symcheck copy is waited on with the secondaries" \
    || bad "command: nothing waits on <doc>.symcheck — merge could run before the pass writes anything"
fi
grep -qF 'symcheck pass is not a secondary' "$CMD" \
  && ok "command: the symcheck pass is excluded from the secondary count" \
  || bad "command: nothing says the symcheck pass is not a secondary — it would inflate the roster"


# --- the symcheck pass must say it runs ROUND 1 ONLY (fable-rd1-r2) ---
# That sentence sat in a GAP between two windows and was covered by neither: the symcheck block
# below windows from the `rows` invocation onward, which starts after it, and the crossref
# round-1-only guard's window now ENDS at this paragraph (it had to, or the symcheck copy of the
# phrase kept crossref's own guard green). So it could be deleted with the full gate green, and the
# command would then instruct deriving and dispatching the pass on scoped round-N copies — which
# carry only the edited hunks, not the document's shipped blocks.
n="$(grep -nF 'Derive the symcheck worklist here too' "$CMD" | head -1 | cut -d: -f1)"
if [[ -z "$n" ]]; then
  bad "command: step 2's symcheck-worklist derivation paragraph is gone"
else
  ne="$(awk -v s="$n" 'NR>s && /multi-review-symcheck\.sh rows/{print NR; exit}' "$CMD")"
  [[ -n "$ne" ]] || ne="$(( $(wc -l < "$CMD") + 1 ))"
  blk="$(sed -n "${n},$((ne-1))p" "$CMD")"
  # TWO exact patterns, each unique in this window (counts confirmed 1 and 1), never a bare
  # `round 1 only`: that phrase occurs TWICE here — the directive, and the prose clause "for the
  # same reason the crossref pass is round 1 only" — so a case-insensitive match on it stays green
  # with the directive deleted. Caught by mutating this guard's own target before trusting it.
  # The directive and the skip instruction are separate clauses, so they get separate assertions
  # and separate mutation entries.
  grep -qF ', ROUND 1 ONLY**' <<<"$blk" \
    && ok "command: step 2 states the symcheck pass is round 1 only" \
    || bad "command: step 2 never says the symcheck pass is round 1 only — it would be derived and dispatched on scoped round-N copies"
  grep -qF 'skip this sub-step entirely' <<<"$blk" \
    && ok "command: step 2 says to skip the symcheck derivation on round N >= 2" \
    || bad "command: step 2 never says to skip the symcheck derivation on a later round — steps 4/5/7/8 would act on a stale worklist"
  grep -qiF 'every round' <<<"$blk" \
    && bad "command: step 2 says the symcheck worklist is derived every round — contradicts round-1-only" \
    || ok "command: step 2 does not say the symcheck worklist is derived every round"
fi

# --- the re-fan branch must run `verify` BEFORE bumping the marker (fable-rd2-r1) ---
# cmd_resolved's earlier-round check reads the round from the marker AT CALL TIME, so a
# `[resolved:]` record written against a current-round finding is only visible while the marker
# still names the round it was written in. Bump first and it reads as an earlier-round record and
# passes every later consumer. Converging catches it; re-fanning is the path that does not, so
# scheduling this check is what makes the guard reachable on that path at all.
RFV="${ROOT}/commands/multi-review.md"
n="$(grep -n 'Edit the marker directly' "$RFV" | head -1 | cut -d: -f1)"
if [[ -n "$n" ]] && grep -q 'verify.*BEFORE you touch the marker' <<<"$(sed -n "1,${n}p" "$RFV" | tail -16)"; then
  ok "command: the re-fan branch runs verify before the marker bump"
else
  bad "command: nothing schedules verify before the marker bump — the earlier-round guard is unreachable on the re-fan path (fable-rd2-r1)"
fi

# --- step 8 must pin `crossref check` to the dispatched worklist (issue #95) ---
# The --rows plumbing is inert unless the caller passes it, and the failure is quiet: check simply
# re-derives, and a complete turn reports INCOMPLETE at the gate after the primary edits the doc.
XRC="${ROOT}/commands/multi-review.md"
# EVERY invocation must carry --rows, not merely the first one found (fable-rd2-r3). Pinning to
# `head -1` meant any earlier mention added later — prose, a prompt template — silently re-targets
# the window, so the real step-8 call could lose --rows with this guard still green.
# The occurrence count is asserted too: zero matches would otherwise pass the loop vacuously,
# which is the same shape as a guard that cannot fail.
xrc_n=0; xrc_missing=0
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  xrc_n=$((xrc_n + 1))
  grep -q -- '--rows' <<<"$(sed -n "${n},$((n+2))p" "$XRC")" || xrc_missing=$((xrc_missing + 1))
done < <(grep -n 'multi-review-crossref.sh check' "$XRC" | cut -d: -f1)
if (( xrc_n > 0 )) && (( xrc_missing == 0 )); then
  ok "command: every crossref check invocation is pinned to the dispatched rows file ($xrc_n found)"
else
  bad "command: crossref check is not passed --rows — it re-derives, and an author edit turns a complete turn into INCOMPLETE (#95) (found=$xrc_n missing=$xrc_missing)"
fi
# --- the re-fan triggers must stay bounded (issue #106) ---
# Both rules are prose, so packaging is the only thing that can notice them being dropped. The
# failure they prevent is not a crash: it is a review that runs nine rounds without ever finding a
# `high`, because the new-logic trigger is satisfied by construction after every productive round.
RFB="${ROOT}/commands/multi-review.md"
grep -q 'new-logic trigger fires AT MOST ONCE per review' "$RFB" \
  && ok "command: the new-logic re-fan trigger is bounded to one use per review" \
  || bad "command: the new-logic re-fan trigger is unbounded — it is a tautology, so the loop it guards has no fixed point (#106)"
grep -q 'From round 3, re-fan only for a .med. or higher' "$RFB" \
  && ok "command: later rounds carry a med-or-higher re-fan floor" \
  || bad "command: no severity floor on later rounds — low-severity churn alone can re-fan indefinitely (#106)"
# The `high` trigger must stay UNbounded: a non-trivial fix to a high is the one case where
# re-review reliably earns its cost, and bounding it would trade the loop's cost for its value.
grep -q 'high. trigger is deliberately NOT bounded' "$RFB" \
  && ok "command: the high-severity re-fan trigger is explicitly left unbounded" \
  || bad "command: the high trigger's exemption is not stated — a later edit will bound it along with the others (#106)"

# --- issue #47 §1/§3/§4: three prose rules, so packaging is the only thing that can see them go ---

# §1 — a fix about whether a CHECK CAN FAIL must demonstrate the failure. A check that cannot fail
# is indistinguishable from a passing one by inspection, which is why re-reading keeps missing it.
D47="${ROOT}/commands/multi-review.md"
grep -q 'must demonstrate the failure, not assert it' "$D47" \
  && ok "command: a fix about a check must demonstrate the failure, not assert it" \
  || bad "command: nothing requires a check-related fix to be demonstrated — 'I added a test' passes inspection whether or not the test can fail (#47 §1)"

# §4 — a broken provider is not a dry one. The never-drop rule protects a reviewer that REVIEWED
# and found nothing; it was never meant to keep paying a wait bound for one that cannot run.
grep -q 'BROKEN provider is not a dry one' "$D47" \
  && ok "command: a provider failing identically twice stops being dispatched" \
  || bad "command: no bound on re-dispatching a deterministically broken provider — every round buys a guaranteed no-op (#47 §4)"
# ...and it must stay in the roster, or the gate stops showing it was asked for at all
grep -q 'Keep it in the roster and keep recording its' "$D47" \
  && ok "command: a stopped provider stays in the roster and keeps being recorded" \
  || bad "command: a stopped provider is dropped from the roster — gate-summary then hides it instead of showing it quarantined (#47 §4)"

# §3 — severity is consequence, not confidence. Checked in the REVIEWER PROMPT, which is what a
# secondary actually reads; the protocol doc restating it is not what reaches the turn.
P47="${ROOT}/scripts/multi-review-reviewer.sh"
grep -q 'Severity is CONSEQUENCE IF TRUE' "$P47" \
  && ok "prompt: severity is defined as consequence, not confidence" \
  || bad "prompt: severity still reads as confidence — an ungroundable but catastrophic finding gets filed low, where the primary may defer it (#47 §3)"


# --- issue #110: nothing may pipe into an early-exiting matcher under `pipefail` ---
# `grep -q` exits on its FIRST match, closing the pipe while the producer is still writing; the
# producer dies of SIGPIPE and `set -o pipefail` (every script here sets it) reports the pipeline
# as 141. That status IS the assertion in a suite and IS control flow in a script, so a correct
# check goes false intermittently — measured at 3 failures in 400 runs of a real assertion on an
# idle machine, and worse under load. Feed the matcher a herestring instead: no pipe, nothing to
# signal, and the producer always runs to completion. `||` is not a pipe, so it is not matched;
# quoted lines are excluded because the mutation table holds source excerpts as DATA, not as
# pipelines this shell ever runs.
sigpipe_sq="'"; sigpipe_hits=""; sigpipe_n=0
for f in "${ROOT}"/scripts/*.sh; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    sigpipe_n=$((sigpipe_n + 1))
    [[ $sigpipe_n -le 3 ]] && sigpipe_hits="${sigpipe_hits} $(basename "$f"):${hit%%:*}"
  done < <(grep -nE '(^|[^|&>])\|[[:space:]]*grep +-[a-zA-Z]*q' "$f" \
             | grep -vE "^[0-9]+:[[:space:]]*(#|${sigpipe_sq}|\")")
done
[[ $sigpipe_n -eq 0 ]] \
  && ok "no pipeline feeds grep -q under pipefail (SIGPIPE cannot fake a failed check)" \
  || bad "${sigpipe_n} pipeline(s) feed grep -q under pipefail — SIGPIPE (141) reads as a failed check (#110), e.g.${sigpipe_hits}"

echo "packaging: $fails failure(s)"; [[ $fails -eq 0 ]]
