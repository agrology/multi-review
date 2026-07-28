#!/usr/bin/env bash
# multi-review-install-hooks.sh — point this clone's git hooks at the versioned .githooks/ dir.
#
# Hooks live in .git/hooks/, which is NOT tracked, so a hook committed to the repo does nothing
# until a clone opts in. `core.hooksPath` is repo-local config: run this once per clone.
#
# Usage: multi-review-install-hooks.sh [--force | --uninstall]
#   --force      overwrite a core.hooksPath that points somewhere else
#   --uninstall  unset core.hooksPath, but ONLY if we are the ones who set it
#
# It never silently takes over, and never removes what it did not create. `core.hooksPath` is a
# SINGLE-valued setting, so overwriting one that already points at another framework (husky, a
# hand-rolled dir) would silently disable every hook that clone relies on — a bad trade for a
# convenience installer. An unconditional `--unset` has the mirror problem: it destroys config we
# never owned.
set -uo pipefail

OURS=".githooks"
OWNED="multi-review.hooksinstalled"     # our marker: proves WE set core.hooksPath, not just that
                                        # the value happens to match. Another tool could point at
                                        # .githooks itself, and unsetting that would disable hooks
                                        # this installer never wired up.

root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "install-hooks: not a git repo" >&2; exit 2; }
cd "$root" || exit 2

current="$(git config --get core.hooksPath 2>/dev/null)"
force=0

case "${1:-}" in
  --uninstall)
    if [[ -z "$current" ]]; then
      echo "install-hooks: core.hooksPath is not set — nothing to remove"; exit 0
    fi
    if [[ "$current" != "$OURS" || "$(git config --get "$OWNED" 2>/dev/null)" != "true" ]]; then
      echo "install-hooks: core.hooksPath points at '${current}', which this installer did not set — leaving it alone" >&2
      exit 1
    fi
    git config --unset core.hooksPath
    git config --unset "$OWNED" 2>/dev/null
    echo "install-hooks: core.hooksPath unset — hooks disabled for this clone"
    exit 0
    ;;
  --force) force=1 ;;
  "")      : ;;
  *)       echo "install-hooks: unknown argument: $1 (expected --force or --uninstall)" >&2; exit 2 ;;
esac

[[ -d "$OURS" ]] || { echo "install-hooks: no ${OURS}/ directory here" >&2; exit 1; }

# Ownership requires BOTH the marker and a matching value — the same test --uninstall applies.
#
# Neither alone is sufficient, and each failed differently. Value equality is not ownership:
# another tool can legitimately point core.hooksPath at .githooks, and adopting it would let a
# later --uninstall remove config we never created. But the marker alone is not ownership either:
# a foreign installer that takes over core.hooksPath does not clear OUR marker, so a stale
# `true` would authorise a plain re-run to silently overwrite the replacement framework — the
# exact clobber this guard exists to prevent.
owned=0
[[ "$current" == "$OURS" && "$(git config --get "$OWNED" 2>/dev/null)" == "true" ]] && owned=1
if [[ -n "$current" && "$owned" != "1" && "$force" != "1" ]]; then
  echo "install-hooks: core.hooksPath already points at '${current}', set by something other than this installer." >&2
  echo "install-hooks: refusing to adopt it — a later --uninstall would then remove config it did not create." >&2
  echo "install-hooks: re-run with --force to take ownership of it." >&2
  exit 1
fi

git config core.hooksPath "$OURS" || { echo "install-hooks: could not set core.hooksPath" >&2; exit 1; }
git config "$OWNED" true
echo "install-hooks: core.hooksPath -> ${OURS}"
echo "install-hooks: active hooks: $(ls "$OURS" | tr '\n' ' ')"
