#!/usr/bin/env bash
# multi-review-ensure-skill.test.sh — codex reviewer skill provisioning.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-reviewer.sh"
PLUGIN="$(cd "${DIR}/.." && pwd -P)"
SKILL_REL=".agents/skills/multi-review"
MARKER=".multi-review-materialized"
fails=0; WORK="$(mktemp -d)"
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }
# Summary via EXIT trap so blocks appended by later tasks are always counted.
trap 'rm -rf "$WORK"; echo; if [[ $fails -eq 0 ]]; then echo PASS; else echo "FAIL ($fails)"; fi; exit $(( fails==0 ? 0 : 1 ))' EXIT
newrepo() { local p; p="$(mktemp -d "${WORK}/repo.XXXXXX")"; git -C "$p" init -q; \
  git -C "$p" config user.email t@t.co; git -C "$p" config user.name t; echo "$p"; }

# --- skill-less providers: exit 0, create nothing ---
for prov in fable gemini; do
  r="$(newrepo)"
  ( cd "$r" && bash "$SUT" ensure-skill --reviewer "$prov" ); rc=$?
  [[ "$rc" == 0 ]] && ok "$prov ensure-skill exits 0" || bad "$prov rc=$rc (want 0)"
  [[ ! -e "$r/.agents" ]] && ok "$prov creates no .agents" || bad "$prov created .agents"
done

# --- argument validation (exit 2) ---
r="$(newrepo)"
( cd "$r" && bash "$SUT" ensure-skill --reviewer nope ) 2>/dev/null; [[ $? == 2 ]] && ok "unknown provider -> 2" || bad "unknown not 2"
( cd "$r" && bash "$SUT" ensure-skill ) 2>/dev/null; [[ $? == 2 ]] && ok "missing --reviewer -> 2" || bad "missing --reviewer not 2"
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex --repo ) 2>/dev/null; [[ $? == 2 ]] && ok "--repo no value -> 2" || bad "--repo no value not 2"

# helper: a throwaway clone of the plugin so src==dst can be exercised safely
plugin_clone() { local c; c="$(mktemp -d "${WORK}/plug.XXXXXX")"; rm -rf "$c"; \
  git clone -q --local "$PLUGIN" "$c"; echo "$c"; }

# --- src==dst (inside a *disposable clone* of the plugin) is a no-op; bundle untouched ---
c="$(plugin_clone)"
( cd "$c" && bash "$c/scripts/multi-review-reviewer.sh" ensure-skill --reviewer codex ); rc=$?
[[ "$rc" == 0 ]] && ok "src==dst (clone) exits 0" || bad "src==dst rc=$rc"
[[ ! -f "$c/$SKILL_REL/$MARKER" ]] && ok "clone bundle not marker-stamped" || bad "clobbered clone bundle"

# --- a git-tracked copy is left untouched (no-op) ---
r="$(newrepo)"; mkdir -p "$r/$SKILL_REL"; echo MINE > "$r/$SKILL_REL/SKILL.md"
git -C "$r" add -f "$SKILL_REL/SKILL.md"; git -C "$r" commit -qm seed
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex ); rc=$?
[[ "$rc" == 0 && "$(cat "$r/$SKILL_REL/SKILL.md")" == MINE ]] && ok "tracked copy untouched" || bad "tracked modified (rc=$rc)"

# --- an untracked non-marker dir is REFUSED (exit 1), not deleted ---
r="$(newrepo)"; mkdir -p "$r/$SKILL_REL"; echo WIP > "$r/$SKILL_REL/mywork.txt"
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex ) 2>/dev/null; rc=$?
[[ "$rc" == 1 ]] && ok "untracked non-marker -> 1" || bad "refuse rc=$rc (want 1)"
[[ -f "$r/$SKILL_REL/mywork.txt" ]] && ok "user's untracked file preserved" || bad "DESTROYED user file"

# --- symlinked .agents escaping the repo is REFUSED ---
r="$(newrepo)"; outside="$(mktemp -d "${WORK}/outside.XXXXXX")"; ln -s "$outside" "$r/.agents"
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex ) 2>/dev/null; rc=$?
[[ "$rc" == 1 ]] && ok "symlinked .agents escape refused" || bad "escape rc=$rc (want 1)"
[[ ! -e "$outside/skills/multi-review" ]] && ok "nothing written outside repo" || bad "wrote outside repo"
