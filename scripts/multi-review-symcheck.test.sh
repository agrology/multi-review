#!/usr/bin/env bash
# multi-review-symcheck.test.sh — worklist derivation and coverage checking for the symbol-check
# pass (issue #89).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-symcheck.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkdoc <name> <line...> -> path
mkdoc() { local p="${WORK}/$1"; shift; printf '%s\n' "$@" > "$p"; echo "$p"; }

# --- not applicable: a doc with no ready-to-paste code ---
# Announced, never silent. A pass that quietly does not run is indistinguishable at the gate from
# one that ran clean — the failure this whole family of passes exists to close.
D="$(mkdoc prose.md '# A design' '' 'Some prose.' '' '## Review' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"; rc=$?
[[ $rc == 3 && -z "$out" ]] \
  && ok "rows: a doc with no code blocks exits 3 with no rows" \
  || bad "rows: prose doc rc=$rc out='$out' (want rc=3, empty)"
err="$(bash "$SUT" rows "$D" 2>&1 >/dev/null)"
grep -qF 'not applicable' <<<"$err" \
  && ok "rows: the not-applicable reason is stated on stderr" \
  || bad "rows: exits 3 without saying why: '$err'"

# --- a fenced block OUTSIDE a file-declaring section does not qualify ---
# A design doc quoting a snippet to make an argument is illustrating, not shipping. Checking it
# against the repo would manufacture findings about symbols nobody claimed exist.
D="$(mkdoc illustrative.md \
  '# A design' '' \
  'Consider:' '' '```python' 'foo(bar)' '```' '' \
  '### Task 1: no files block' '' '**Interfaces:**' '- Produces: `alpha`' '' \
  '```python' 'baz(qux)' '```' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"; rc=$?
[[ $rc == 3 ]] \
  && ok "rows: blocks outside a **Files:** section do not qualify" \
  || bad "rows: rc=$rc — an illustrative block qualified (out='$out')"

# --- one row per fenced block inside a **Files:** section ---
D="$(mkdoc twoblocks.md \
  '# Plan' '' \
  '### Task 1: ships code' '' '**Files:**' '- Modify: `src/a.py`' '' \
  'First:' '' '```python' 'insert_client(conn, client_id=1)' '```' '' \
  'Second:' '' '```sql' 'SELECT 1;' '```' '' \
  '### Task 2: also ships' '' '**Files:**' '- Modify: `src/b.py`' '' \
  '```python' '_view(db, at_hour=23)' '```' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && ok "rows: a doc with shipping code is applicable" || bad "rows: rc=$rc"
n="$(printf '%s\n' "$out" | grep -c . || true)"
[[ "$n" == 3 ]] && ok "rows: one row per fenced block (got $n)" \
  || bad "rows: expected 3 rows, got $n"
awk -F'\t' '$1=="B1" && $2=="Task 1"' <<<"$out" | grep -q . \
  && ok "rows: a row names its section" || bad "rows: B1 does not name Task 1"
awk -F'\t' '$3 ~ /^python:/' <<<"$out" | grep -q . \
  && ok "rows: a row carries its language tag" || bad "rows: no row carries a python tag"
awk -F'\t' '$3 ~ /^sql:/' <<<"$out" | grep -q . \
  && ok "rows: the sql block is not dropped" || bad "rows: the sql block is missing"
# Line ranges must be absolute document lines, not offsets within the section.
awk -F'\t' '$1=="B3"{split($3,a,":"); split(a[2],b,"-"); exit !(b[1] > 18)}' <<<"$out" \
  && ok "rows: line ranges are absolute document lines" \
  || bad "rows: B3's range looks section-relative — a reviewer would be pointed at the wrong lines"

# --- an untagged block still gets a row ---
# `rows` never decides a verdict. Pre-filtering by language would silently drop the rows most likely
# to be defects, which is the rule the crossref pass applies to unmatched Consumes entries.
D="$(mkdoc untagged.md \
  '# Plan' '' \
  '### Task 1: ships' '' '**Files:**' '- Modify: `src/a.py`' '' \
  '```' 'some output' '```' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
awk -F'\t' '$3 ~ /^-:/' <<<"$out" | grep -q . \
  && ok "rows: an untagged block still gets a row" \
  || bad "rows: the untagged block was filtered out — rows is a worklist, not a filter"
echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
