#!/usr/bin/env bash
# multi-review-reviewer-bundle.test.sh — the reviewer skill dir must be self-contained
# and byte-identical to the canonical sources (no drift).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
SKILL="${ROOT}/.agents/skills/multi-review"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- protocol doc bundled and identical ---
if cmp -s "${ROOT}/docs/multi-review.md" "${SKILL}/protocol/multi-review.md"; then
  ok "protocol doc bundled and in sync"
else
  bad "protocol doc missing or drifted at ${SKILL}/protocol/multi-review.md"
fi

# --- reviewer scripts bundled and identical ---
# The star-only bundle vendors just core.sh today; kept as a loop so adding a vendored script
# later is a one-line change. (single element by design)
# shellcheck disable=SC2043
for s in multi-review-core.sh; do
  if cmp -s "${ROOT}/scripts/${s}" "${SKILL}/scripts/${s}"; then
    ok "bundled script in sync: ${s}"
  else
    bad "bundled script missing/drifted: ${s}"
  fi
done

# --- retired scripts must NOT be vendored (dropped from the star-only bundle) ---
for s in multi-review-peer.sh multi-review-wait.sh multi-review-watch.sh; do
  if [[ -e "${SKILL}/scripts/${s}" ]]; then
    bad "retired script still vendored: ${s}"
  else
    ok "retired script not vendored: ${s}"
  fi
done

# --- SKILL.md must reference the BUNDLED install paths (resolvable), not just lack old refs ---
if grep -q '\.agents/skills/multi-review/protocol/multi-review\.md' "${SKILL}/SKILL.md" \
   && grep -q '\.agents/skills/multi-review/scripts/multi-review-' "${SKILL}/SKILL.md"; then
  ok "SKILL.md references bundled protocol doc + scripts by fixed install path"
else
  bad "SKILL.md missing bundled .agents/skills/multi-review/{protocol,scripts} refs (unresolvable)"
fi
# old repo-root refs (bare scripts/… or docs/multi-review.md NOT under .agents/) must be gone
oldrefs="$(grep -nE '(^|[^./\w])(scripts/multi-review-[a-z-]+\.sh|docs/multi-review\.md)' "${SKILL}/SKILL.md")"
if [[ -n "$oldrefs" ]] && grep -vq '\.agents/skills/multi-review/' <<<"$oldrefs"; then
  bad "SKILL.md still has old repo-root-relative refs"
else
  ok "no old repo-root refs remain in SKILL.md"
fi

echo "reviewer-bundle: $fails failure(s)"; [[ $fails -eq 0 ]]
