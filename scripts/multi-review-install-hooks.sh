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
    if [[ "$current" != "$OURS" ]]; then
      echo "install-hooks: core.hooksPath points at '${current}', which this installer did not set — leaving it alone" >&2
      exit 1
    fi
    git config --unset core.hooksPath
    echo "install-hooks: core.hooksPath unset — hooks disabled for this clone"
    exit 0
    ;;
  --force) force=1 ;;
  "")      : ;;
  *)       echo "install-hooks: unknown argument: $1 (expected --force or --uninstall)" >&2; exit 2 ;;
esac

[[ -d "$OURS" ]] || { echo "install-hooks: no ${OURS}/ directory here" >&2; exit 1; }

if [[ -n "$current" && "$current" != "$OURS" && "$force" != "1" ]]; then
  echo "install-hooks: core.hooksPath already points at '${current}'." >&2
  echo "install-hooks: refusing to overwrite it — that would disable the hooks it provides." >&2
  echo "install-hooks: re-run with --force if you really want ${OURS} instead." >&2
  exit 1
fi

git config core.hooksPath "$OURS" || { echo "install-hooks: could not set core.hooksPath" >&2; exit 1; }
echo "install-hooks: core.hooksPath -> ${OURS}"
echo "install-hooks: active hooks: $(ls "$OURS" | tr '\n' ' ')"
