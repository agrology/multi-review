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
