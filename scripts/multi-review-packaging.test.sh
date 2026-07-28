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
  if grep -nE '(^|[^/A-Za-z_])scripts/multi-review-[a-z-]+\.sh' "$f" \
       | grep -vq 'CLAUDE_PLUGIN_ROOT'; then
    bad "bare scripts/ ref (no \${CLAUDE_PLUGIN_ROOT}) in $(basename "$f")"
  else
    ok "no bare scripts/ refs in $(basename "$f")"
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
  grep -qiE 'degrad|falling back' "$DR" && bad "multi-review.md still documents degrade-to-manual" \
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
  echo "$sec1" | grep -q -- '--reviewers' && ok "§1 extracts --reviewers" \
    || bad "§1 does not extract --reviewers"
  echo "$sec1" | grep -q -- '--attended' && bad "§1 still mentions --attended" \
    || ok "§1 no longer splits --attended"
  echo "$sec1" | grep -qF 'multi-review-pr.sh parse "<positional>"' \
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

echo "packaging: $fails failure(s)"; [[ $fails -eq 0 ]]
