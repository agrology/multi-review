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
# --- rows carry what the DOCUMENT ITSELF introduces ---
# This is the design's central correctness problem. Every #89 exemplar is a call to an EXISTING repo
# symbol with the wrong shape — but the same blocks also define new functions and call things an
# earlier section creates. Without this set the agent flags every not-yet-written symbol and the
# real defects drown.
D="$(mkdoc introduces.md \
  '# Plan' '' \
  '### Task 1: creates' '' '**Files:**' '- Create: `src/new_mod.py`' '- Modify: `src/a.py`' '' \
  '**Interfaces:**' '- Produces: `alpha --flag`' '' \
  '```python' 'alpha(1)' '```' '' \
  '### Task 2: consumes' '' '**Files:**' '- Modify: `src/b.py`' '' \
  '```python' 'alpha(2)' '```' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
awk -F'\t' '$1=="B1"' <<<"$out" | grep -qF 'src/new_mod.py' \
  && ok "rows: a created file appears in the introduces set" \
  || bad "rows: src/new_mod.py is not in B1's introduces set — every not-yet-written symbol would read as missing"
awk -F'\t' '$1=="B1"' <<<"$out" | grep -qF 'alpha --flag' \
  && ok "rows: a Produces entry appears in the introduces set" \
  || bad "rows: the Produces entry is not in the introduces set"
awk -F'\t' '$1=="B1"' <<<"$out" | grep -qF 'src/a.py' \
  && bad "rows: a MODIFIED file leaked into the introduces set — it already exists, so its symbols are exactly what must be checked" \
  || ok "rows: a modified file is not treated as introduced"
# The set is document-wide, not section-local: Task 2's block calls something Task 1 creates.
awk -F'\t' '$1=="B2"' <<<"$out" | grep -qF 'alpha --flag' \
  && ok "rows: the introduces set is document-wide" \
  || bad "rows: B2 does not carry Task 1's Produces — a later section's use of an earlier creation would read as a defect"
# --- the introduces set spans EVERY section, not just **Files:** ones (round 1's high) ---
# A contract-only section still PRODUCES things later sections legitimately call. Scoping the set to
# _file_sections drops those, and every valid call to them then reads as a missing repo symbol.
D="$(mkdoc introduces-iface-only.md \
  '# Plan' '' \
  '### Task 1: contract only' '' '**Interfaces:**' '- Produces: `alpha --flag`' '' \
  '### Task 2: ships code' '' '**Files:**' '- Modify: `src/b.py`' '' \
  '```python' 'alpha(2)' '```' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
grep -qF 'alpha --flag' <<<"$out" \
  && ok "rows: an Interfaces-only section's Produces reaches the introduces set" \
  || bad "rows: a contract-only section's Produces was dropped — every valid call to it would read as a missing symbol"

# --- fenced example content must not reach the introduces set, nor qualify a section ---
# A plan that QUOTES a fixture carries bare **Files:** and `- Create:` lines inside a fence. Read
# raw, they inflate the introduces set, so a genuinely missing symbol verdicts `new` and the defect
# this pass exists to catch is suppressed.
D="$(mkdoc introduces-fenced.md \
  '# Plan' '' \
  '### Task 1: quotes a fixture' '' '**Files:**' '- Modify: `src/real.py`' '' \
  '````markdown' '**Files:**' '- Create: `src/illustrative.py`' '' '```bash' 'echo hi' '```' '````' '' \
  '```python' 'real(1)' '```' '' \
  '### Task 2: second' '' '**Files:**' '- Modify: `src/c.py`' '' \
  '```python' 'c(2)' '```' '')"
out="$(bash "$SUT" rows "$D" 2>/dev/null)"
grep -qF 'src/illustrative.py' <<<"$out" \
  && bad "rows: a fenced '- Create:' reached the introduces set — a missing symbol would verdict 'new' and the defect would be suppressed" \
  || ok "rows: fenced example content stays out of the introduces set"

# --- a core.sh failure is loud, never a false not-applicable (fable-rd2-r1) ---
D="$(mkdoc corefail.md '# Plan' '' '### Task 1: one' '' '**Files:**' '- Modify: `src/a.py`' '' \
  '```python' 'foo(1)' '```' '')"
err="$(MULTI_REVIEW_CORE_SH=/nonexistent/core.sh bash "$SUT" rows "$D" 2>&1 >/dev/null)"; rc=$?
[[ $rc != 0 && $rc != 3 ]] && grep -qF 'core.sh sections failed' <<<"$err" \
  && ok "rows: a core.sh failure fails loudly instead of reporting not-applicable" \
  || bad "rows: a broken core.sh reported rc=$rc — the pass silently self-disables and records a clean not-applicable at the gate"

# --- the fixture yields rows, and distinguishes created from modified ---
F="${DIR}/fixtures/symcheck-plan-sample.md"
if [[ ! -f "$F" ]]; then
  bad "fixture missing: $F"
else
  out="$(bash "$SUT" rows "$F" 2>/dev/null)"; rc=$?
  [[ $rc == 0 ]] && ok "rows: the fixture is applicable" || bad "rows: fixture rc=$rc"
  n="$(printf '%s\n' "$out" | grep -c . || true)"
  [[ "$n" == 2 ]] && ok "rows: the fixture yields one row per block (got $n)" \
    || bad "rows: expected 2 fixture rows, got $n"
  grep -qF 'scripts/multi-review-symcheck.sh' <<<"$out" \
    && ok "rows: the fixture's CREATED module is in the introduces set" \
    || bad "rows: the created module is absent from the introduces set"
  grep -qF 'core.sh sections' <<<"$out" \
    && ok "rows: the fixture's Produces entry is in the introduces set" \
    || bad "rows: the Produces entry is absent"
fi
echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
