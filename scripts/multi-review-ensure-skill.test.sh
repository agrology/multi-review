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

# --- fresh repo: materialized, marker + in-dir .gitignore, git-invisible ---
r="$(newrepo)"
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex ); rc=$?
[[ "$rc" == 0 ]] && ok "codex materialize exits 0" || bad "materialize rc=$rc"
[[ -f "$r/$SKILL_REL/SKILL.md" && -f "$r/$SKILL_REL/$MARKER" && -f "$r/$SKILL_REL/.gitignore" ]] \
  && ok "bundle + marker + .gitignore present" || bad "materialized bundle incomplete"
[[ -z "$(git -C "$r" status --porcelain)" ]] && ok "git status clean" || bad "git sees bundle: $(git -C "$r" status --porcelain | head -1)"
# exclude entry present exactly once, idempotent across a second run
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex )
excl="$r/$(git -C "$r" rev-parse --git-path info/exclude)"
m="$(grep -Fxc -- '/.agents/skills/multi-review/' "$excl" 2>/dev/null || true)"; m="${m:-0}"
[[ "$m" == 1 ]] && ok "exclude entry exactly once" || bad "exclude count=$m (want 1)"

# --- refresh removes a stale file ---
echo stale > "$r/$SKILL_REL/STALE"; ( cd "$r" && bash "$SUT" ensure-skill --reviewer codex )
[[ ! -e "$r/$SKILL_REL/STALE" ]] && ok "refresh drops stale file" || bad "stale survived"

# --- atomic: a copy failure leaves the prior bundle intact ---
r="$(newrepo)"; ( cd "$r" && bash "$SUT" ensure-skill --reviewer codex )   # prior good bundle
fakebin="$(mktemp -d "${WORK}/fakebin.XXXXXX")"; printf '#!/bin/sh\nexit 1\n' > "$fakebin/cp"; chmod +x "$fakebin/cp"
( cd "$r" && PATH="$fakebin:$PATH" bash "$SUT" ensure-skill --reviewer codex ) 2>/dev/null; rc=$?
[[ "$rc" == 1 ]] && ok "copy failure -> exit 1" || bad "copy-fail rc=$rc (want 1)"
[[ -f "$r/$SKILL_REL/SKILL.md" && -f "$r/$SKILL_REL/$MARKER" ]] && ok "prior bundle intact after copy failure" || bad "bundle lost on copy failure"

# --- exclude write is best-effort: a read-only .git/info still succeeds via the in-dir .gitignore ---
r="$(newrepo)"; chmod -w "$r/.git/info" 2>/dev/null || true
( cd "$r" && bash "$SUT" ensure-skill --reviewer codex ); rc=$?
chmod +w "$r/.git/info" 2>/dev/null || true
[[ "$rc" == 0 && -f "$r/$SKILL_REL/.gitignore" ]] \
  && ok "unwritable .git/info: still succeeds via in-dir .gitignore" || bad "read-only .git/info broke provisioning (rc=$rc)"
