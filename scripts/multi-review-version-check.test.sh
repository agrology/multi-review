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

# --- the WHOLE string must be MAJOR.MINOR.PATCH (PR#27 codex-rd1-r1) -------------------------
# semver_gt read only the first three dot-separated fields, so `1.2.4.0` compared as 1.2.4 and
# shipped through the gate as a valid bump. A release gate that accepts an invalid version is
# worse than none: the plugin UI is the thing that has to parse it downstream.
for badv in 1.2.4.0 1.2 1 "1.2.x" "v1.2.3" "1.2.3 " ""; do
  r="$(newrepo 1.1.0)"
  echo changed > "$r/file.txt"; setver "$r" "$badv"
  ( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
  out="$(run "$r")"; rc=$?
  [[ $rc -eq 2 ]] && ok "malformed version '${badv:-<empty>}' exits 2" \
    || bad "malformed version '${badv:-<empty>}' rc=$rc (want 2): $out"
done

# A pre-release suffix is valid semver but deliberately unsupported by this gate — the message
# must SAY that rather than calling it malformed, so the diagnosis is actionable.
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"; setver "$r" "1.2.0-rc1"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 2 ]] && grep -qi 'pre-release' <<<"$out" \
  && ok "pre-release version: rejected with a diagnosis that names why" \
  || bad "pre-release diagnosis unclear (rc=$rc): $out"

# ...but hyphenated GARBAGE must not be mis-diagnosed as a pre-release (PR#27 fable-rd3-r2): the
# suffix arm ran before any shape check, sending the operator to look for a suffix that is not
# there. Exit code was right; the message was not.
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"; setver "$r" "not-a-version"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -eq 2 ]] && ! grep -qi 'pre-release' <<<"$out" \
  && ok "hyphenated garbage is not mis-diagnosed as a pre-release" \
  || bad "mis-diagnosis persists (rc=$rc): $out"
grep -qi 'MAJOR.MINOR.PATCH' <<<"$out" \
  && ok "hyphenated garbage gets the shape diagnosis instead" || bad "no actionable diagnosis: $out"

# --- the base ref is IDENTIFIED, so a stale one is visible (PR#27 fable-rd1-r3) ---------------
# The check compares against a local origin/main it never fetches. It cannot know it is stale, so
# it must at least name what it compared against — a gate documented as "fails loud" must not
# hide the one input that decides its verdict.
r="$(newrepo 1.1.0)"
echo changed > "$r/file.txt"; setver "$r" 1.2.0
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"
base_sha="$(cd "$r" && git rev-parse --short main)"
grep -qF "$base_sha" <<<"$out" \
  && ok "pass output identifies the base commit it compared against" \
  || bad "base commit not identified, so staleness is invisible: $out"

# --- no base ref -> loud skip, not a silent pass (an unverifiable state must say so) ---
r="${WORK}/nobase"; mkdir -p "$r/scripts" "$r/.claude-plugin"; cp "$SUT" "$r/scripts/"
printf '{"name":"multi-review","version":"1.0.0"}\n' > "$r/.claude-plugin/plugin.json"
( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && git branch -M other )
out="$(cd "$r" && bash scripts/multi-review-version-check.sh 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -qi 'skipping' <<<"$out" \
  && ok "no base ref: passes but says why" || bad "no-base handling (rc=$rc): $out"

# --- a NEW manifest must still be validated (PR#27 codex-rd2-r1 / gemini-rd2-r2) -------------
# The "no version at base" path exited 0 BEFORE validation ran, so the first version a manifest
# ever carries could be anything. Two vendors found this independently.
r="${WORK}/newman"; mkdir -p "$r/scripts" "$r/.claude-plugin"; cp "$SUT" "$r/scripts/"
echo base > "$r/file.txt"
( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
    && git branch -M main && git checkout -q -b feature )
printf '{"name":"m","version":"v1.0"}\n' > "$r/.claude-plugin/plugin.json"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm add )
out="$(run "$r")"; rc=$?
[[ $rc -eq 2 ]] && ok "new manifest: an invalid first version is still rejected" \
  || bad "new manifest bypassed validation (rc=$rc): $out"
# ...and a VALID first version is accepted
printf '{"name":"m","version":"0.1.0"}\n' > "$r/.claude-plugin/plugin.json"
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm fix )
[[ "$(run "$r" >/dev/null 2>&1; echo $?)" == "0" ]] \
  && ok "new manifest: a valid first version is accepted" || bad "new manifest rejected a valid first version"

# --- leading zeros (PR#27 gemini-rd2-r1 / fable-rd2-r1) --------------------------------------
# Semver forbids leading zeros, and bash arithmetic makes them actively dangerous: `08`/`09` raise
# "value too great for base" (both compares then read false, failing a legitimate bump), and
# octal-valid strings are silently reinterpreted — 1.017.0 → 1.16.0 compares 16 > 15 and PASSES
# while the plugin UI's decimal compare sees a DECREASE. A real false pass, found by two vendors.
for v in 1.08.0 1.017.0 01.2.3 1.2.03; do
  r="$(newrepo 1.1.0)"; echo changed > "$r/file.txt"; setver "$r" "$v"
  ( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
  out="$(run "$r")"; rc=$?
  [[ $rc -eq 2 ]] && ok "leading-zero version '$v' rejected" || bad "leading-zero '$v' rc=$rc: $out"
done
# the specific false pass: base 1.017.0 (octal 15) vs current 1.16.0 — decimal says DECREASE
r="$(newrepo 1.017.0)"; echo changed > "$r/file.txt"; setver "$r" 1.16.0
( cd "$r" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change )
out="$(run "$r")"; rc=$?
[[ $rc -ne 0 ]] && ok "octal-valid leading zeros cannot produce a false pass" \
  || bad "FALSE PASS: 1.017.0 -> 1.16.0 accepted as a bump: $out"
# no stray arithmetic error text leaks either
! grep -qi 'value too great' <<<"$out" && ok "no bash octal error leaks to the operator" \
  || bad "octal arithmetic error surfaced: $out"

# --- not a git repo -> pass with a reason (a tarball install must not fail the gate) ---
r="${WORK}/nogit"; mkdir -p "$r/scripts" "$r/.claude-plugin"; cp "$SUT" "$r/scripts/"
printf '{"name":"multi-review","version":"1.0.0"}\n' > "$r/.claude-plugin/plugin.json"
out="$(cd "$r" && bash scripts/multi-review-version-check.sh 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -qi 'not a git repo' <<<"$out" \
  && ok "non-repo: passes with a reason" || bad "non-repo handling (rc=$rc): $out"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
