#!/usr/bin/env bash
# multi-review-core.test.sh — deterministic marker read/init logic.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-core.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }

mkdoc() { # mkdoc <name> <marker-state-line-or-empty>; prints path
  local p="${WORK}/$1"
  { echo "# Title"; echo; [[ -n "${2:-}" ]] && echo "$2"; } > "$p"
  echo "$p"
}

# --- marker: parse a valid marker ---
D="$(mkdoc good.md '<!-- multi-review: awaiting-author · round 3/10 -->')"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "awaiting-author 3 10" ]] && ok "marker parses state/round/max" || bad "marker parse (got '$out' code $code)"

# --- marker: reject a doc with no marker ---
D="$(mkdoc none.md '')"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail when absent" || ok "marker fails when absent"

# --- marker: reject a malformed marker ---
D="$(mkdoc bad.md '<!-- multi-review: not-a-state round X -->')"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail when malformed" || ok "marker fails when malformed"

# --- marker: reject a doc with TWO markers (split-brain) ---
D="${WORK}/two.md"
{ echo "# Title"; echo
  echo '<!-- multi-review: awaiting-reviewer · round 1/10 -->'
  echo '<!-- multi-review: awaiting-author · round 2/10 -->'; } > "$D"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail with two markers" || ok "marker fails with duplicate markers"

# --- marker: a prose mention of "multi-review:" is NOT counted as a marker ---
D="${WORK}/prose.md"
{ echo "# Title"; echo
  echo '<!-- multi-review: awaiting-author · round 1/10 -->'; echo
  echo 'We use the multi-review: protocol described above.'; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-author 1 10" ]] && ok "prose mention ignored; single marker parses" || bad "prose mention miscounted (got '$out')"

# --- marker: a marker-shaped line in a body section (e.g. an embedded PR diff) is NOT counted ---
# Marker detection is header-scoped (before the first "## " heading); the real marker sits at the
# top. A PR-mode scratch embeds the PR diff under "## Diff", which can contain quoted markers.
D="${WORK}/embedded.md"
{ echo "# PR review"; echo
  echo '<!-- multi-review: awaiting-author · round 1/10 -->'; echo
  echo "## Diff"; echo
  echo '```'
  echo '+<!-- multi-review: converged · round 3/10 -->'
  echo '```'; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "awaiting-author 1 10" ]] && ok "marker is header-scoped (ignores body/diff markers)" || bad "marker miscounts an embedded-diff marker (got '$out' code $code)"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && ok "init arms despite an embedded-diff marker" || bad "init treats an embedded-diff marker as corrupt"

# --- init: inserts a marker when absent, idempotent when present ---
D="$(mkdoc init.md '')"
bash "$SUT" init "$D" 10 >/dev/null 2>&1
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-reviewer 1 10" ]] && ok "init inserts round 1/10 marker" || bad "init insert (got '$out')"
bash "$SUT" init "$D" 10 >/dev/null 2>&1
n="$(grep -c 'multi-review:' "$D")"
[[ "$n" == "1" ]] && ok "init is idempotent (one marker)" || bad "init duplicated marker (count $n)"

# --- init: reject invalid max (would otherwise write an unparseable marker) ---
D="$(mkdoc initbad.md '')"
bash "$SUT" init "$D" 0 >/dev/null 2>&1 && bad "init should reject max=0" || ok "init rejects max=0"
bash "$SUT" init "$D" abc >/dev/null 2>&1 && bad "init should reject non-integer max" || ok "init rejects non-integer max"
[[ "$(grep -c 'multi-review:' "$D")" == "0" ]] && ok "init wrote no marker on invalid max" || bad "init wrote a marker despite invalid max"

# --- init: a malformed single marker is rejected, not treated as armed ---
D="${WORK}/initmalformed.md"
{ echo "# Title"; echo; echo '<!-- multi-review: not-a-state round X -->'; } > "$D"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should reject a malformed marker" || ok "init rejects a malformed single marker"
[[ "$(grep -cE '<!--[[:space:]]*multi-review:' "$D")" == "1" ]] && ok "init left the malformed doc untouched (no second marker)" || bad "init altered a malformed-marker doc"

# --- init: an empty doc is rejected, not a silent no-op "success" ---
D="${WORK}/empty.md"; : > "$D"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should fail on an empty doc" || ok "init fails loudly on an empty doc"

# --- init: a write failure is surfaced (non-zero), not a silent "success" ---
if [[ "$(id -u)" != "0" ]]; then
  RODIR="${WORK}/roi"; mkdir -p "$RODIR"
  D="${RODIR}/i.md"; printf '# Title\n' > "$D"
  chmod 555 "$RODIR"
  bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should fail on an unwritable dir" || ok "init surfaces a write failure (non-zero)"
  chmod 755 "$RODIR"   # restore so the EXIT trap can clean WORK up
else
  ok "init write-failure test skipped (running as root)"
fi

# star states are recognized additively
D="${WORK}/star-sec.md"; { echo "# Doc"; echo '<!-- multi-review: awaiting-secondaries · round 1/2 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-secondaries 1 2" ]] && ok "marker: awaiting-secondaries recognized" || bad "star-sec (got '$out')"
D="${WORK}/star-pri.md"; { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/2 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-primary 2 2" ]] && ok "marker: awaiting-primary recognized" || bad "star-pri (got '$out')"
# existing state still works
D="${WORK}/still-rev.md"; { echo "# Doc"; echo '<!-- multi-review: awaiting-reviewer · round 1/10 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-reviewer 1 10" ]] && ok "marker: existing state intact" || bad "still-rev (got '$out')"

# ============================ resolve-doc (issue #35) ============================
RD="${WORK}/rd"; mkdir -p "$RD"
( cd "$RD" && mkdir -p docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans )

# --- the superpowers layout is reachable with NO configuration ---
: > "${RD}/docs/superpowers/specs/2026-01-02-alpha.md"
out="$(cd "$RD" && bash "$SUT" resolve-doc 2>/dev/null)"
[[ "$out" == "docs/superpowers/specs/2026-01-02-alpha.md" ]] \
  && ok "resolve-doc: superpowers layout found by default" || bad "superpowers layout missed (got '$out')"

# --- newest by DATE PREFIX then filename, across all default dirs ---
: > "${RD}/docs/specs/2026-01-01-older.md"
: > "${RD}/docs/superpowers/plans/2026-03-09-newest.md"
out="$(cd "$RD" && bash "$SUT" resolve-doc 2>/dev/null)"
[[ "$out" == "docs/superpowers/plans/2026-03-09-newest.md" ]] \
  && ok "resolve-doc: newest across all default dirs" || bad "wrong doc chosen (got '$out')"

# --- a same-date TIE stops rather than guessing ---
: > "${RD}/docs/specs/2026-03-09-tie.md"
(cd "$RD" && bash "$SUT" resolve-doc >/dev/null 2>&1)
[[ $? -ne 0 ]] && ok "resolve-doc: same-date tie stops" || bad "tie resolved silently"
rm -f "${RD}/docs/specs/2026-03-09-tie.md"

# --- THE SILENT WRONG-DOC CASE (#35 failure mode 2): configured dirs hold a doc, but a
#     sibling dir holds a NEWER one — the chosen doc is legitimate, so nothing else catches it
RD2="${WORK}/rd2"; mkdir -p "$RD2/docs/specs" "$RD2/docs/superpowers/specs"
: > "${RD2}/docs/specs/2026-01-01-stale.md"
: > "${RD2}/docs/superpowers/specs/2026-06-01-real-work.md"
msg="$(cd "$RD2" && MULTI_REVIEW_DOC_DIRS="docs/specs" bash "$SUT" resolve-doc 2>&1 >/dev/null)"
# Assert the WARNING BRANCH specifically: both branches mention the sibling path, so matching
# the path alone stays green if the newer-than logic breaks (fable-rd1-r3).
[[ "$msg" == *"WARNING"* && "$msg" == *"NEWER dated doc"* && "$msg" == *"2026-06-01-real-work.md"* ]] \
  && ok "resolve-doc: WARNS that an unsearched sibling holds a NEWER doc" \
  || bad "silent wrong-doc: warning branch did not fire ('$msg')"
# ...and the note branch (sibling exists but is OLDER) must NOT claim a newer doc
: > "${RD2}/docs/specs/2026-12-01-newest-here.md"
msg="$(cd "$RD2" && MULTI_REVIEW_DOC_DIRS="docs/specs" bash "$SUT" resolve-doc 2>&1 >/dev/null)"
[[ "$msg" != *"WARNING"* && "$msg" == *"not searched"* ]] \
  && ok "resolve-doc: older sibling notes without warning" || bad "wrong branch for an older sibling ('$msg')"
rm -f "${RD2}/docs/specs/2026-12-01-newest-here.md"

# --- zero candidates names what was searched, not just "none found" ---
RD3="${WORK}/rd3"; mkdir -p "$RD3/docs/specs"
msg="$(cd "$RD3" && bash "$SUT" resolve-doc 2>&1 >/dev/null)"
[[ "$msg" == *"docs/specs"* && "$msg" == *"docs/plans"* ]] \
  && ok "resolve-doc: zero candidates names the dirs searched" || bad "unhelpful empty message ('$msg')"

# --- an explicit MULTI_REVIEW_DOC_DIRS is honored verbatim ---
RD4="${WORK}/rd4"; mkdir -p "$RD4/design"
: > "${RD4}/design/2026-02-02-custom.md"
out="$(cd "$RD4" && MULTI_REVIEW_DOC_DIRS="design" bash "$SUT" resolve-doc 2>/dev/null)"
[[ "$out" == "design/2026-02-02-custom.md" ]] \
  && ok "resolve-doc: explicit DOC_DIRS honored" || bad "explicit DOC_DIRS ignored (got '$out')"

# --- only files DIRECTLY under a dir, and only dated ones ---
RD5="${WORK}/rd5"; mkdir -p "$RD5/docs/specs/nested"
: > "${RD5}/docs/specs/nested/2026-09-09-deep.md"
: > "${RD5}/docs/specs/undated.md"
: > "${RD5}/docs/specs/2026-01-01-ok.md"
out="$(cd "$RD5" && bash "$SUT" resolve-doc 2>/dev/null)"
[[ "$out" == "docs/specs/2026-01-01-ok.md" ]] \
  && ok "resolve-doc: ignores nested and undated files" || bad "picked a nested/undated file (got '$out')"

# --- codex-rd1-r1 (HIGH): a symlinked doc DIRECTORY must not arm an out-of-tree file ---
EG="${DIR}/multi-review-egress-guard.sh"
SL="${WORK}/sl"; OUTSIDE="${WORK}/outside"
mkdir -p "$SL/docs/superpowers" "$OUTSIDE"
: > "${OUTSIDE}/2026-01-01-external.md"
ln -s "$OUTSIDE" "$SL/docs/superpowers/specs"
(cd "$SL" && bash "$EG" docs/superpowers/specs/2026-01-01-external.md >/dev/null 2>&1)
[[ $? -eq 3 ]] && ok "egress-guard: symlinked doc dir cannot arm an out-of-tree file" \
  || bad "SYMLINK ESCAPE: out-of-tree file armed via a symlinked doc dir (codex-rd1-r1)"

# --- a real (non-symlinked) doc dir still arms ---
RL="${WORK}/rl"; mkdir -p "$RL/docs/superpowers/specs"
: > "${RL}/docs/superpowers/specs/2026-01-01-ok.md"
(cd "$RL" && bash "$EG" docs/superpowers/specs/2026-01-01-ok.md >/dev/null 2>&1) \
  && ok "egress-guard: a real doc dir still arms" || bad "false positive on a real doc dir"

# --- fable-rd1-r1: a non-canonical spelling of a searched dir is NOT reported as unsearched ---
RD6="${WORK}/rd6"; mkdir -p "$RD6/docs/specs"
: > "${RD6}/docs/specs/2026-01-01-a.md"
for spelling in "docs/specs/" "./docs/specs"; do
  msg="$(cd "$RD6" && MULTI_REVIEW_DOC_DIRS="$spelling" bash "$SUT" resolve-doc 2>&1 >/dev/null)"
  [[ -z "$msg" ]] && ok "resolve-doc: '$spelling' not falsely reported unsearched" \
    || bad "false alarm for spelling '$spelling' ('$msg')"
done

# --- fable-rd1-r6: a nested subdir UNDER a searched dir is not a "sibling" ---
RD7="${WORK}/rd7"; mkdir -p "$RD7/docs/specs/archive"
: > "${RD7}/docs/specs/2026-01-01-current.md"
: > "${RD7}/docs/specs/archive/2026-09-09-old.md"
msg="$(cd "$RD7" && MULTI_REVIEW_DOC_DIRS="docs/specs" bash "$SUT" resolve-doc 2>&1 >/dev/null)"
[[ -z "$msg" ]] && ok "resolve-doc: nested subdir of a searched dir is not flagged" \
  || bad "nested subdir triggered a false alarm ('$msg')"

# --- fable-rd1-r7: the sibling scan does not follow symlinked dirs ---
RD8="${WORK}/rd8"; mkdir -p "$RD8/docs/specs"
: > "${RD8}/docs/specs/2026-01-01-a.md"
ln -s "$OUTSIDE" "$RD8/docs/elsewhere"
msg="$(cd "$RD8" && bash "$SUT" resolve-doc 2>&1 >/dev/null)"
[[ "$msg" != *"docs/elsewhere"* ]] && ok "resolve-doc: sibling scan skips symlinked dirs" \
  || bad "symlinked dir pulled into the hint ('$msg')"

# --- fable-rd1-r5: the note message is not garbled ---
RD9="${WORK}/rd9"; mkdir -p "$RD9/docs/specs" "$RD9/docs/other"
: > "${RD9}/docs/specs/2026-12-01-newer.md"
: > "${RD9}/docs/other/2026-01-01-older.md"
msg="$(cd "$RD9" && MULTI_REVIEW_DOC_DIRS="docs/specs" bash "$SUT" resolve-doc 2>&1 >/dev/null)"
[[ "$msg" != *"DOC_DIRS NOT searched"* && "$msg" == *"docs/other"* ]] \
  && ok "resolve-doc: note message reads cleanly" || bad "garbled note ('$msg')"

# --- fable-rd1-r4: the three duplicated defaults must not drift ---
CORE_D="$(grep -E "^DOC_DIRS_DEFAULT=" "${DIR}/multi-review-core.sh" | sed -E "s/^[^']*'([^']*)'.*/\1/")"
EG_D="$(grep -oE 'MULTI_REVIEW_DOC_DIRS:-[^}]*' "${DIR}/multi-review-egress-guard.sh" | head -1 | sed 's/^MULTI_REVIEW_DOC_DIRS:-//')"
RV_D="$(grep -oE 'MULTI_REVIEW_DOC_DIRS:-[^}]*' "${DIR}/multi-review-reviewer.sh" | head -1 | sed 's/^MULTI_REVIEW_DOC_DIRS:-//')"
[[ -n "$CORE_D" && "$CORE_D" == "$EG_D" && "$CORE_D" == "$RV_D" ]] \
  && ok "doc-dir default identical across core/egress-guard/reviewer" \
  || bad "DOC_DIRS default drifted (core='$CORE_D' guard='$EG_D' reviewer='$RV_D')"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
