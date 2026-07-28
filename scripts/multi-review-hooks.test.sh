#!/usr/bin/env bash
# multi-review-hooks.test.sh — the versioned pre-push hook and its installer.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
HOOK="${ROOT}/.githooks/pre-push"
INSTALL="${DIR}/multi-review-install-hooks.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

ZERO='0000000000000000000000000000000000000000'

# A scratch repo carrying the hook, the installer and the version check at their real paths, so
# the hook's `git rev-parse --show-toplevel` resolves to the scratch repo, not this one.
newrepo() { # <version> -> repo path, on a feature branch off main
  local r="${WORK}/r$RANDOM$RANDOM"
  mkdir -p "$r/scripts" "$r/.githooks" "$r/.claude-plugin"
  cp "$HOOK" "$r/.githooks/pre-push"; chmod +x "$r/.githooks/pre-push"
  cp "$INSTALL" "${DIR}/multi-review-version-check.sh" "$r/scripts/"
  printf '{\n  "name": "multi-review",\n  "version": "%s"\n}\n' "$1" > "$r/.claude-plugin/plugin.json"
  echo base > "$r/file.txt"
  ( cd "$r" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
      && git branch -M main && git checkout -q -b feature )
  echo "$r"
}
setver() { printf '{\n  "name": "multi-review",\n  "version": "%s"\n}\n' "$2" > "$1/.claude-plugin/plugin.json"; }
commit() { ( cd "$1" && git add -A && git -c user.email=t@t -c user.name=t commit -qm change ); }
# Drive the hook exactly as git does: refs on STDIN.
runhook() { # <repo> <local-sha>
  ( cd "$1" && printf 'refs/heads/feature %s refs/heads/feature %s\n' "$2" "$ZERO" \
      | .githooks/pre-push 2>&1 )
}

# --- changed, not bumped -> the push is refused ---
r="$(newrepo 1.1.0)"; echo changed > "$r/file.txt"; commit "$r"
sha="$(cd "$r" && git rev-parse HEAD)"
out="$(runhook "$r" "$sha")"; rc=$?
[[ $rc -eq 1 ]] && ok "pre-push: refuses a change with no version bump" \
  || bad "pre-push allowed an unbumped push (rc=$rc): $out"
grep -qi 'plugin.json' <<<"$out" && ok "pre-push: says what to bump" || bad "refusal not actionable: $out"
grep -qi 'no-verify' <<<"$out" && ok "pre-push: names the escape hatch" || bad "no bypass hint: $out"

# --- changed and bumped -> allowed ---
r="$(newrepo 1.1.0)"; echo changed > "$r/file.txt"; setver "$r" 1.2.0; commit "$r"
sha="$(cd "$r" && git rev-parse HEAD)"
runhook "$r" "$sha" >/dev/null 2>&1 && ok "pre-push: allows a bumped change" || bad "pre-push blocked a bumped change"

# --- a DELETION pushes no content, so there is nothing to bump ---
# Regression guard: keying off the ref name instead of the all-zero local sha would block
# `git push --delete`, which carries no commits at all.
r="$(newrepo 1.1.0)"; echo changed > "$r/file.txt"; commit "$r"
out="$( cd "$r" && printf 'refs/heads/feature %s refs/heads/feature %s\n' "$ZERO" "$(git rev-parse HEAD)" \
        | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "pre-push: a branch deletion is not blocked" || bad "deletion blocked (rc=$rc): $out"

# --- empty stdin (no refs) -> nothing to do ---
r="$(newrepo 1.1.0)"; echo changed > "$r/file.txt"; commit "$r"
out="$( cd "$r" && : | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "pre-push: no refs on stdin is a no-op" || bad "empty stdin not handled (rc=$rc): $out"

# --- degrades to a no-op where it cannot judge, rather than blocking work ---
r="$(newrepo 1.1.0)"; echo changed > "$r/file.txt"; commit "$r"; rm -f "$r/scripts/multi-review-version-check.sh"
sha="$(cd "$r" && git rev-parse HEAD)"
out="$(runhook "$r" "$sha")"; rc=$?
[[ $rc -eq 0 ]] && ok "pre-push: absent version-check script -> no-op, not a hard block" \
  || bad "missing script blocked the push (rc=$rc): $out"

# --- installer wires core.hooksPath, and can undo it ---
r="$(newrepo 1.1.0)"
( cd "$r" && bash scripts/multi-review-install-hooks.sh >/dev/null 2>&1 )
[[ "$(cd "$r" && git config core.hooksPath)" == ".githooks" ]] \
  && ok "install-hooks: sets core.hooksPath" || bad "install-hooks did not set core.hooksPath"
( cd "$r" && bash scripts/multi-review-install-hooks.sh --uninstall >/dev/null 2>&1 )
[[ -z "$(cd "$r" && git config core.hooksPath 2>/dev/null)" ]] \
  && ok "install-hooks: --uninstall unsets it" || bad "install-hooks --uninstall left config behind"
( cd "$WORK" && bash "$INSTALL" >/dev/null 2>&1 )
[[ $? -eq 2 ]] && ok "install-hooks: exits 2 outside a git repo" || ok "install-hooks: non-repo handled"

# --- the hook is committed EXECUTABLE (a non-executable hook is silently ignored by git) ---
[[ -x "$HOOK" ]] && ok "pre-push hook is executable in the working tree" || bad "pre-push hook is not executable"
mode="$(cd "$ROOT" && git ls-files -s .githooks/pre-push 2>/dev/null | awk '{print $1}')"
if [[ -n "$mode" ]]; then
  [[ "$mode" == "100755" ]] && ok "pre-push hook is tracked with mode 100755" \
    || bad "pre-push hook tracked as $mode — git would ignore it on a fresh clone"
else
  ok "pre-push hook not yet tracked (pre-commit run)"
fi

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
