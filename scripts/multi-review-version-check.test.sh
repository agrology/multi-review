#!/usr/bin/env bash
# multi-review-version-check.test.sh — the plugin-version gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-version-check.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# A scratch repo carrying a copy of the SUT at the same repo-relative path, so its ROOT resolves
# to the scratch repo rather than this one.
newrepo() { # <version> -> repo path with a committed manifest on main
  local r="${WORK}/r$RANDOM$RANDOM" v="$1"
  mkdir -p "$r/scripts" "$r/.claude-plugin"
  cp "$SUT" "$r/scripts/"
  printf '{\n  "name": "multi-review",\n  "version": "%s"\n}\n' "$v" > "$r/.claude-plugin/plugin.json"
  echo base > "$r/file.txt"
  ( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
      && git branch -M main && git checkout -q -b feature )
  echo "$r"
}
setver() { printf '{\n  "name": "multi-review",\n  "version": "%s"\n}\n' "$2" > "$1/.claude-plugin/plugin.json"; }
run() { ( cd "$1" && bash scripts/multi-review-version-check.sh "${2:-main}" 2>&1 ); }

# --- no tracked changes -> nothing to enforce ---
r="$(newrepo 1.1.0)"
out="$(run "$r")"; rc=$?
[[ $rc -eq 0 ]] && grep -qi 'nothing to bump' <<<"$out" \
  && ok "clean branch: passes with an explicit no-op reason" || bad "clean branch (rc=$rc): $out"

# --- changed a tracked file, version untouched -> FAIL (the whole point) ---
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 1 ]] && ok "changed + no bump: exits 1" || bad "changed + no bump rc=$rc (want 1): $out"
grep -qi 'still 1.1.0' <<<"$out" && ok "failure names the unchanged version" || bad "failure message unclear: $out"
grep -qi 'update' <<<"$out" && ok "failure explains the downstream consequence" || bad "failure lacks rationale: $out"

# --- changed + bumped -> pass ---
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"; setver "$r" 1.2.0
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 0 ]] && grep -q '1.1.0 → 1.2.0' <<<"$out" \
  && ok "changed + bumped: passes and reports the transition" || bad "changed + bumped (rc=$rc): $out"

# --- a DECREASE is not a bump: installed copies would never see the update ---
r="$(newrepo 1.2.0)"
echo changed > "$r/file.txt"; setver "$r" 1.1.0
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 1 ]] && ok "version decrease: rejected" || bad "version decrease accepted (rc=$rc): $out"

# --- numeric compare, not string: 1.10.0 > 1.9.0 (a string compare gets this backwards) ---
r="$(newrepo 1.9.0)"
echo changed > "$r/file.txt"; setver "$r" 1.10.0
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 0 ]] && ok "1.9.0 -> 1.10.0 accepted (numeric, not lexical)" || bad "numeric compare wrong (rc=$rc): $out"
# ...and the reverse is a decrease
r="$(newrepo 1.10.0)"
echo changed > "$r/file.txt"; setver "$r" 1.9.0
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 1 ]] && ok "1.10.0 -> 1.9.0 rejected (numeric, not lexical)" || bad "lexical compare let a decrease through: $out"

# --- patch-level bump is enough ---
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"; setver "$r" 1.1.1
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
[[ "$(run "$r" >/dev/null 2>&1; echo $?)" == "0" ]] && ok "patch bump accepted" || bad "patch bump rejected"

# --- malformed version -> exit 2 (usage/config), never a silent pass ---
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"; setver "$r" "not-a-version"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 2 ]] && ok "malformed version: exits 2, not a pass" || bad "malformed version rc=$rc (want 2): $out"

# --- no base ref -> loud skip, not a silent pass (an unverifiable state must say so) ---
r="${WORK}/nobase"; mkdir -p "$r/scripts" "$r/.claude-plugin"; cp "$SUT" "$r/scripts/"
printf '{"name":"multi-review","version":"1.0.0"}\n' > "$r/.claude-plugin/plugin.json"
( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && git branch -M other )
out="$(cd "$r" && bash scripts/multi-review-version-check.sh 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -qi 'skipping' <<<"$out" \
  && ok "no base ref: passes but says why" || bad "no-base handling (rc=$rc): $out"

# --- not a git repo -> pass with a reason (a tarball install must not fail the gate) ---
r="${WORK}/nogit"; mkdir -p "$r/scripts" "$r/.claude-plugin"; cp "$SUT" "$r/scripts/"
printf '{"name":"multi-review","version":"1.0.0"}\n' > "$r/.claude-plugin/plugin.json"
out="$(cd "$r" && bash scripts/multi-review-version-check.sh 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -qi 'not a git repo' <<<"$out" \
  && ok "non-repo: passes with a reason" || bad "non-repo handling (rc=$rc): $out"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
