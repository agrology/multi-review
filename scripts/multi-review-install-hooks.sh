#!/usr/bin/env bash
# multi-review-install-hooks.sh — point this clone's git hooks at the versioned .githooks/ dir.
#
# Hooks live in .git/hooks/, which is NOT tracked, so a hook committed to the repo does nothing
# until a clone opts in. `core.hooksPath` is repo-local config: run this once per clone.
# Usage: scripts/multi-review-install-hooks.sh [--uninstall]
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "install-hooks: not a git repo" >&2; exit 2; }
cd "$root" || exit 2

if [[ "${1:-}" == "--uninstall" ]]; then
  git config --unset core.hooksPath 2>/dev/null
  echo "install-hooks: core.hooksPath unset — hooks disabled for this clone"
  exit 0
fi
[[ -d .githooks ]] || { echo "install-hooks: no .githooks/ directory here" >&2; exit 1; }

git config core.hooksPath .githooks || { echo "install-hooks: could not set core.hooksPath" >&2; exit 1; }
echo "install-hooks: core.hooksPath -> .githooks"
echo "install-hooks: active hooks: $(ls .githooks | tr '\n' ' ')"
