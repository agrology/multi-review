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

# --- the hook judges the PUSHED commits, not the checkout (PR#28 codex-rd1-r1 / fable-rd1-r1) ---
# It parsed stdin only to detect a deletion, then discarded the shas — so version-check ran
# against the current worktree. Pushing a branch you are not standing on (or with an uncommitted
# manifest edit) got a verdict about the wrong content, including a FALSE PASS: an unbumped branch
# pushed from a bumped checkout. That is the hook's one job.
r="$(newrepo 1.0.0)"
( cd "$r" && git checkout -q main \
    && git checkout -q -b unbumped && echo change > file.txt \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm unbumped \
    && git checkout -q main && git checkout -q -b bumped )
setver "$r" 2.0.0; commit "$r"
# standing on `bumped`, push `unbumped`
out="$( cd "$r" && printf 'refs/heads/unbumped %s refs/heads/unbumped %s\n' "$(git rev-parse unbumped)" "$ZERO" \
        | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 1 ]] && ok "pre-push: refuses an unbumped branch pushed from a bumped checkout" \
  || bad "FALSE PASS: unbumped branch allowed from a bumped checkout (rc=$rc): $out"
# and the bumped branch itself is still allowed
out="$( cd "$r" && printf 'refs/heads/bumped %s refs/heads/bumped %s\n' "$(git rev-parse bumped)" "$ZERO" \
        | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "pre-push: allows the bumped branch" || bad "bumped branch refused (rc=$rc): $out"

# A MULTI-REF push must be judged per ref: one good ref must not carry a bad one through.
out="$( cd "$r" && { printf 'refs/heads/bumped %s refs/heads/bumped %s\n' "$(git rev-parse bumped)" "$ZERO"
                     printf 'refs/heads/unbumped %s refs/heads/unbumped %s\n' "$(git rev-parse unbumped)" "$ZERO"; } \
        | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 1 ]] && ok "pre-push: a multi-ref push is refused if ANY ref lacks a bump" \
  || bad "multi-ref push let an unbumped ref through (rc=$rc): $out"

# An uncommitted worktree bump must not excuse an unbumped commit.
r="$(newrepo 1.0.0)"; echo change > "$r/file.txt"; commit "$r"
setver "$r" 9.9.9                                    # edited but NOT committed
out="$( cd "$r" && printf 'refs/heads/feature %s refs/heads/feature %s\n' "$(git rev-parse HEAD)" "$ZERO" \
        | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 1 ]] && ok "pre-push: an uncommitted bump does not excuse the pushed commit" \
  || bad "uncommitted worktree bump produced a false pass (rc=$rc): $out"

# --- a TAG push is not a content push to main (PR#28 fable-rd2-r1) ---------------------------
# The per-ref loop judged EVERY non-deletion ref against origin/main, tags included. Pushing a
# release tag for anything but the exact main tip — retro-tagging an already-released commit, the
# normal case — was refused with a bogus "bump the version" demand. This repo's own adoption docs
# tell users to pin release tags, so that path matters.
r="$(newrepo 1.0.0)"
( cd "$r" && git checkout -q main && echo more > file.txt \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm second \
    && git tag v0.9.0 HEAD~1 && git tag v1.0.0 HEAD )
for t in v0.9.0 v1.0.0; do
  tsha="$(cd "$r" && git rev-parse "${t}^{commit}")"
  out="$( cd "$r" && printf 'refs/tags/%s %s refs/tags/%s %s\n' "$t" "$tsha" "$t" "$ZERO" \
          | .githooks/pre-push 2>&1 )"; rc=$?
  [[ $rc -eq 0 ]] && ok "pre-push: tag push ($t) is not blocked" \
    || bad "tag push $t wrongly refused (rc=$rc): $out"
done
# a branch in the same push is still judged
( cd "$r" && git checkout -q -b unbumped2 && echo x > file.txt \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm nb )
tagsha="$(cd "$r" && git rev-parse "v1.0.0^{commit}")"
brsha="$(cd "$r" && git rev-parse unbumped2)"
out="$( cd "$r" && { printf 'refs/tags/v1.0.0 %s refs/tags/v1.0.0 %s\n' "$tagsha" "$ZERO"
                     printf 'refs/heads/unbumped2 %s refs/heads/unbumped2 %s\n' "$brsha" "$ZERO"; } \
        | .githooks/pre-push 2>&1 )"; rc=$?
[[ $rc -eq 1 ]] && ok "pre-push: skipping tags does not excuse a branch in the same push" \
  || bad "branch alongside a tag escaped the check (rc=$rc): $out"

# --- installer must not clobber someone else's hooks setup (PR#28 codex-rd1-r2 / fable-rd1-r2) ---
r="$(newrepo 1.1.0)"
( cd "$r" && git config core.hooksPath .husky )
( cd "$r" && bash scripts/multi-review-install-hooks.sh >/dev/null 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && ok "install-hooks: refuses to overwrite an existing core.hooksPath" \
  || bad "install-hooks silently clobbered an existing hooksPath"
[[ "$(cd "$r" && git config core.hooksPath)" == ".husky" ]] \
  && ok "install-hooks: leaves the existing value intact on refusal" \
  || bad "install-hooks destroyed the pre-existing hooksPath"
# ...and --uninstall must not remove config it did not create
( cd "$r" && bash scripts/multi-review-install-hooks.sh --uninstall >/dev/null 2>&1 )
[[ "$(cd "$r" && git config core.hooksPath)" == ".husky" ]] \
  && ok "install-hooks: --uninstall leaves a foreign hooksPath alone" \
  || bad "--uninstall destroyed a hooksPath it did not set"
# Ownership is tracked explicitly, not inferred from the VALUE (PR#28 codex-rd2-r1): another tool
# could legitimately point core.hooksPath at .githooks itself, and unsetting that would disable
# hooks this installer never wired up.
r2="$(newrepo 1.1.0)"
( cd "$r2" && git config core.hooksPath .githooks )      # set by someone else, same value
( cd "$r2" && bash scripts/multi-review-install-hooks.sh --uninstall >/dev/null 2>&1 )
[[ "$(cd "$r2" && git config core.hooksPath)" == ".githooks" ]] \
  && ok "install-hooks: --uninstall spares a .githooks value it did not set" \
  || bad "--uninstall removed a matching value it never owned"
# ...but its OWN install is removable
( cd "$r2" && git config --unset core.hooksPath; bash scripts/multi-review-install-hooks.sh >/dev/null 2>&1 \
    && bash scripts/multi-review-install-hooks.sh --uninstall >/dev/null 2>&1 )
[[ -z "$(cd "$r2" && git config core.hooksPath 2>/dev/null)" ]] \
  && ok "install-hooks: --uninstall removes its own install" || bad "--uninstall could not remove its own install"
# an explicit --force is the way through
( cd "$r" && bash scripts/multi-review-install-hooks.sh --force >/dev/null 2>&1 )
[[ "$(cd "$r" && git config core.hooksPath)" == ".githooks" ]] \
  && ok "install-hooks: --force overrides deliberately" || bad "--force did not take effect"

# --- installer wires core.hooksPath, and can undo it ---
r="$(newrepo 1.1.0)"
( cd "$r" && bash scripts/multi-review-install-hooks.sh >/dev/null 2>&1 )
[[ "$(cd "$r" && git config core.hooksPath)" == ".githooks" ]] \
  && ok "install-hooks: sets core.hooksPath" || bad "install-hooks did not set core.hooksPath"
( cd "$r" && bash scripts/multi-review-install-hooks.sh --uninstall >/dev/null 2>&1 )
[[ -z "$(cd "$r" && git config core.hooksPath 2>/dev/null)" ]] \
  && ok "install-hooks: --uninstall unsets it" || bad "install-hooks --uninstall left config behind"
# VACUOUS BEFORE: this called ok() on BOTH branches, so the exit-2 contract could never fail.
# Run somewhere that is definitely not inside a repo — $WORK may sit under one.
nonrepo="$(mktemp -d)"
( cd "$nonrepo" && bash "$INSTALL" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 2 ]] && ok "install-hooks: exits 2 outside a git repo" \
  || bad "install-hooks outside a repo exited $rc (want 2)"
rm -rf "$nonrepo"

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
