#!/usr/bin/env bash
# multi-review-docs-check.sh — assert every DOCUMENTED default matches the constant it describes.
#
# Issue #44. #35 widened DOC_DIRS_DEFAULT and updated the README and the scripts, but two protocol
# docs kept the old value — and one of them is the copy SECONDARY REVIEWERS read, so agents were
# told a narrower default than the guard actually enforces. Nothing caught it: the code was right,
# the suite was green, and only the description was wrong. The same shape recurred across six more
# sites while shipping the fable switch. Prose does not check itself.
#
# Usage: multi-review-docs-check.sh [<root>]     (default: the repo this script lives in)
# Exit 0 = every documented default agrees with the code. 1 = drift (each site named). 2 = cannot run.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${DIR}/.." && pwd)}"

[[ -d "$ROOT" ]] || { echo "multi-review-docs-check: no such root: $ROOT" >&2; exit 2; }
# python3 absence is a FAILURE, not a skip: silently passing is how the described-but-unchecked
# state arose in the first place.
command -v python3 >/dev/null 2>&1 \
  || { echo "multi-review-docs-check: python3 required" >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]

core_path = os.path.join(root, "scripts", "multi-review-core.sh")
try:
    core = open(core_path, encoding="utf-8").read()
except OSError as e:
    print(f"multi-review-docs-check: cannot read {core_path}: {e}", file=sys.stderr); sys.exit(2)

m = re.search(r"^DOC_DIRS_DEFAULT='([^']*)'", core, re.M)
if not m:
    print("multi-review-docs-check: DOC_DIRS_DEFAULT not found in multi-review-core.sh", file=sys.stderr)
    sys.exit(2)
want = " ".join(m.group(1).split())

# Explicit, not a glob: a new doc stating the default must be listed here consciously, and the
# floor below proves the list is still live rather than quietly matching nothing.
DOCS = [
    "README.md",
    "docs/multi-review.md",
    ".agents/skills/multi-review/protocol/multi-review.md",
    "commands/multi-review.md",
]
# TWO shapes, because the default is stated two ways and a single pattern silently covered only
# one. Prose form wraps across lines in commands/multi-review.md, so match whitespace-collapsed
# text; a line-oriented check would skip the wrapped site while looking thorough.
PATS = (
    # prose:  ...`MULTI_REVIEW_DOC_DIRS` (default `a b c`)...
    re.compile(r"MULTI_REVIEW_DOC_DIRS`?\s*\(default\s*`([^`]*)`"),
    # env table row:  | `MULTI_REVIEW_DOC_DIRS` | `a b c` | meaning |
    re.compile(r"\|\s*`MULTI_REVIEW_DOC_DIRS`\s*\|\s*`([^`]*)`\s*\|"),
)

problems, per_file = [], {}
for rel in DOCS:
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        problems.append(f"{rel}: MISSING FILE"); per_file[rel] = 0; continue
    text = " ".join(open(p, encoding="utf-8").read().split())
    hits = [m for pat in PATS for m in pat.finditer(text)]
    per_file[rel] = len(hits)
    for hit in hits:
        got = " ".join(hit.group(1).split())
        if got != want:
            problems.append(f"{rel}: documents '{got}' but DOC_DIRS_DEFAULT is '{want}'")

# ANTI-VACUITY, PER FILE. An aggregate floor is not enough: with four listed docs and a global
# minimum, any ONE of them — including the .agents protocol copy this issue was specifically
# about — can be rephrased out of every pattern while the total still clears the bar and the check
# stays green. Requiring each listed doc to match at least once makes going blind impossible to
# hide behind its neighbours. A per-file MINIMUM, not an equality, so adding a statement is fine.
for rel, n in per_file.items():
    if n == 0 and f"{rel}: MISSING FILE" not in problems:
        problems.append(f"{rel}: 0 documented default(s) matched — this site has gone BLIND, not clean")

if problems:
    print("multi-review-docs-check: doc/code drift:", file=sys.stderr)
    for b in problems:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
print("multi-review-docs-check: " + str(sum(per_file.values())) + " documented default(s) across " + str(len(DOCS)) + " file(s) agree with DOC_DIRS_DEFAULT")
PY
