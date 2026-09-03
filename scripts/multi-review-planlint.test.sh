#!/usr/bin/env bash
# multi-review-planlint.test.sh — the no-eval lint over a document's mutate entries (spec Part B).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-planlint.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkdoc <name> <line...> -> path
mkdoc() { local p="${WORK}/$1"; shift; printf '%s\n' "$@" > "$p"; echo "$p"; }
# verdict <rows> <id> -> the verdict column for <id>
verdict() { awk -F'\t' -v i="$2" '$1 == i { print $2 }' <<<"$1"; }
# detail <rows> <id> -> the detail column for <id>
detail() { awk -F'\t' -v i="$2" '$1 == i { print $3 }' <<<"$1"; }

# A fake repo the --repo half of the union resolves against. Hermetic: never this checkout.
REPO="${WORK}/repo"; mkdir -p "${REPO}/scripts"
printf '%s\n' '#!/usr/bin/env bash' '  existing_guard || die "nope"' > "${REPO}/scripts/foo.sh"
printf '%s\n' 'bad "the repo suite label"' > "${REPO}/scripts/foo.test.sh"

# --- not applicable: no mutate invocation anywhere in fenced code ---
D="$(mkdoc plain.md '# Plan' '' 'prose' '```bash' 'echo hi' '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>"${WORK}/na.err")"; rc=$?
[[ $rc -eq 3 && -z "$out" ]] && ok "check: no mutate entries exits 3 with no rows" || bad "check: plain doc rc=$rc out='$out'"
grep -qF 'not applicable' "${WORK}/na.err" && ok "check: the not-applicable reason is on stderr" || bad "check: exit 3 said nothing: $(cat "${WORK}/na.err")"

# a mutate that appears only in PROSE (outside a fence) is not an entry
D="$(mkdoc prose.md '# Plan' '' "Add mutate 'x/y' later." '' '## Review' '')"
bash "$SUT" check "$D" --repo "$REPO" >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "check: a mutate word in prose is not an entry" || bad "check: prose mutate counted (rc=$?)"

# a mutate inside the ## Review section is not an entry either (a quoted finding, not shipped code)
D="$(mkdoc inreview.md '# Plan' '' '## Review' '' '```bash' "mutate 'x/y' 'scripts/foo.sh' delete 'l' 'foo.test.sh' 'line'" '```')"
bash "$SUT" check "$D" --repo "$REPO" >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "check: fenced code under ## Review is not shipped code" || bad "check: review-section code counted (rc=$?)"

# --- the union: a target present only in the DOC is ok; one present only in the REPO is ok ---
D="$(mkdoc union.md '# Plan' '' \
  '```bash' 'new_guard() {' '  [[ -n "$x" ]] || die "x"' '}' 'bad "the doc suite label"' '```' '' \
  '```bash' \
  "  mutate 'a/doc-target' 'scripts/new.sh' replace \\" \
  "    'the doc suite label' 'new.test.sh' \\" \
  "    '  [[ -n \"\$x\" ]] || die \"x\"' \\" \
  "    '  :'" \
  "  mutate 'a/repo-target' 'scripts/foo.sh' delete 'the repo suite label' 'foo.test.sh' '  existing_guard || die \"nope\"'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>"${WORK}/u.err")"; rc=$?
[[ $rc -eq 0 ]] && ok "check: a consistent table exits 0" || bad "check: consistent table rc=$rc: $out / $(cat "${WORK}/u.err")"
[[ "$(verdict "$out" a/doc-target)" == ok ]] && ok "check: a target that exists only in the document's code is ok" || bad "check: doc-only target: $(verdict "$out" a/doc-target)"
[[ "$(verdict "$out" a/repo-target)" == ok ]] && ok "check: a target that exists only in the repo file is ok" || bad "check: repo-only target: $(verdict "$out" a/repo-target)"
grep -qF '2 entries checked, 0 defect(s)' "${WORK}/u.err" && ok "check: the summary counts entries and defects" || bad "check: summary: $(cat "${WORK}/u.err")"

# --- target-missing: the retained round-2 shape ---
F="${DIR}/fixtures/planlint-stale-target.md"
out="$(bash "$SUT" check "$F" --repo "$REPO" 2>/dev/null)"; rc=$?
[[ $rc -eq 1 ]] && ok "check: the stale round-2 entry exits 1" || bad "check: stale fixture rc=$rc"
[[ "$(verdict "$out" star/undispatchable-emitted)" == target-missing ]] \
  && ok "check: star/undispatchable-emitted is target-missing (the round-2 triple)" \
  || bad "check: stale target verdict '$(verdict "$out" star/undispatchable-emitted)'"

# --- label-missing, and SURVIVES-BY-DESIGN is exempt ---
D="$(mkdoc label.md '# Plan' '' '```bash' 'guard_a || die "a"' 'guard_b || die "b"' '```' '' '```bash' \
  "  mutate 'l/missing' 'scripts/x.sh' delete 'no such assertion anywhere' 'x.test.sh' 'guard_a || die \"a\"'" \
  "  mutate 'l/sbd' 'scripts/x.sh' delete 'SURVIVES-BY-DESIGN' 'x.test.sh' 'guard_b || die \"b\"'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"; rc=$?
[[ "$(verdict "$out" l/missing)" == label-missing ]] && ok "check: an expect label found nowhere is label-missing" || bad "check: label verdict '$(verdict "$out" l/missing)'"
[[ "$(verdict "$out" l/sbd)" == ok ]] && ok "check: SURVIVES-BY-DESIGN needs no label" || bad "check: SBD verdict '$(verdict "$out" l/sbd)'"
[[ $rc -eq 1 ]] && ok "check: one defect makes the exit 1" || bad "check: rc=$rc with a label-missing row"

# --- duplicate-id ---
D="$(mkdoc dup.md '# Plan' '' '```bash' 'g1 || die' 'g2 || die' 'bad "lbl"' '```' '' '```bash' \
  "  mutate 'd/same' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'g1 || die'" \
  "  mutate 'd/same' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'g2 || die'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"
[[ "$(printf '%s\n' "$out" | awk -F'\t' '$1=="d/same" && $2=="duplicate-id"' | grep -c . || true)" == 2 ]] \
  && ok "check: both occurrences of a duplicated id are duplicate-id" || bad "check: duplicate rows: $out"

# --- unparsed: a bare substitution inside double quotes, wrong arity, unknown mode ---
MARK="${WORK}/evaluated.mark"
D="$(mkdoc unparsed.md '# Plan' '' '```bash' 'x || die' 'bad "lbl"' '```' '' '```bash' \
  "  mutate 'u/subst' 'scripts/x.sh' replace 'lbl' 'x.test.sh' \"\$(touch ${MARK})\" 'x'" \
  "  mutate 'u/arity' 'scripts/x.sh' replace 'lbl' 'x.test.sh' 'x || die'" \
  "  mutate 'u/mode' 'scripts/x.sh' rewrite 'lbl' 'x.test.sh' 'x || die' 'y'" \
  "  mutate 'u/fine' 'scripts/x.sh' replace:2 'lbl' 'x.test.sh' 'x || die' 'y'" \
  "  mutate 'u/unterm' 'scripts/x.sh' replace 'lbl' 'x.test.sh' 'x || die' \"y" \
  "  mutate 'u/bare' 'scripts/x.sh' delete \$LBL 'x.test.sh' 'x || die'" \
  "  mutate 'u/dqbt' 'scripts/x.sh' delete \"a \`b\` c\" 'x.test.sh' 'x || die'" \
  "  mutate 'u/sqterm' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'x || die" \
  "  mutate 'u/darity' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'x || die' 'extra'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"; rc=$?
[[ "$(verdict "$out" u/subst)" == unparsed ]] && ok "check: a bare \$( inside double quotes is unparsed" || bad "check: subst verdict '$(verdict "$out" u/subst)'"
[[ ! -e "$MARK" ]] && ok "check: document content was never evaluated (spec B3)" || bad "check: the document's \$(touch) RAN — the lint evaluated the doc"
[[ "$(verdict "$out" u/arity)" == unparsed ]] && ok "check: a replace with no new-line is unparsed" || bad "check: arity verdict '$(verdict "$out" u/arity)'"
[[ "$(verdict "$out" u/mode)" == unparsed ]] && ok "check: an unknown mode is unparsed" || bad "check: mode verdict '$(verdict "$out" u/mode)'"
[[ "$(verdict "$out" u/fine)" == ok ]] && ok "check: replace:N (a named occurrence) parses" || bad "check: replace:2 verdict '$(verdict "$out" u/fine)'"
[[ "$(verdict "$out" u/unterm)" == unparsed ]] && ok "check: an unterminated double quote is unparsed even at the right arity" || bad "check: unterminated-quote verdict '$(verdict "$out" u/unterm)'"
[[ "$(verdict "$out" u/bare)" == unparsed ]] && ok "check: a bare \$ outside any quotes is unparsed" || bad "check: bare-word substitution verdict '$(verdict "$out" u/bare)'"
[[ "$(verdict "$out" u/dqbt)" == unparsed ]] && ok "check: a backtick inside double quotes is unparsed" || bad "check: double-quoted backtick verdict '$(verdict "$out" u/dqbt)'"
[[ "$(verdict "$out" u/sqterm)" == unparsed ]] && ok "check: an unterminated single quote is unparsed" || bad "check: unterminated single-quote verdict '$(verdict "$out" u/sqterm)'"
[[ "$(verdict "$out" u/darity)" == unparsed ]] && ok "check: a delete with seven arguments is unparsed" || bad "check: a delete with seven arguments parsed anyway (verdict '$(verdict "$out" u/darity)')"
[[ $rc -eq 1 ]] && ok "check: unparsed is a defect, not a skip" || bad "check: rc=$rc with unparsed rows"

# --- a file-rel or suite that escapes the repo is a defect: both are joined onto ${repo} and read,
# so an absolute path or a `..` segment makes the lint read a file the reviewed document chose ---
D="$(mkdoc traverse.md '# Plan' '' '```bash' 'g || die' 'bad "lbl"' '```' '' '```bash' \
  "  mutate 't/dotdot' '../../etc/hosts' delete 'lbl' 'x.test.sh' 'g || die'" \
  "  mutate 't/abs' '/etc/hosts' delete 'lbl' 'x.test.sh' 'g || die'" \
  "  mutate 't/abs-suite' 'scripts/x.sh' delete 'lbl' '/etc/hosts' 'g || die'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"
[[ "$(verdict "$out" t/dotdot)" == unparsed ]] && ok "check: a .. segment in file-rel is unparsed" \
  || bad "check: a .. segment in file-rel was not refused (verdict '$(verdict "$out" t/dotdot)')"
[[ "$(verdict "$out" t/abs)" == unparsed ]] && ok "check: an absolute file-rel is unparsed" \
  || bad "check: an absolute file-rel was not refused (verdict '$(verdict "$out" t/abs)')"
[[ "$(verdict "$out" t/abs-suite)" == unparsed ]] && ok "check: an absolute suite is unparsed" \
  || bad "check: an absolute suite was not refused (verdict '$(verdict "$out" t/abs-suite)')"
[[ "$(detail "$out" t/dotdot)" == *"must be a relative path inside the repo"* ]] \
  && ok "check: the escaping-path row says why" \
  || bad "check: the escaping-path row does not name the reason ('$(detail "$out" t/dotdot)')"

# --- continuation lines and escaped double-quoted content (the real table's shape) ---
D="$(mkdoc cont.md '# Plan' '' '```bash' \
  '  r="$(printf '"'"'%s'"'"' "${1:-}" | LC_ALL=C tr -d x)"' 'bad "collapsed"' '```' '' '```bash' \
  "  mutate 'c/esc' 'scripts/x.sh' replace \\" \
  "    'collapsed' 'x.test.sh' \\" \
  "    \"  r=\\\"\\\$(printf '%s' \\\"\\\${1:-}\\\" | LC_ALL=C tr -d x)\\\"\" \\" \
  "    '  r=\"\${1:-}\"'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>"${WORK}/c.err")"; rc=$?
[[ "$(verdict "$out" c/esc)" == ok ]] && ok "check: a backslash-continued entry with \\\" \\\$ \\\\ escapes parses and matches" \
  || bad "check: escaped entry verdict '$(verdict "$out" c/esc)' rc=$rc: $out / $(cat "${WORK}/c.err")"

# --- bash's real double-quote escape rule: \$ \` \" \\ collapse to that one character, but a
# backslash before any OTHER character (e.g. \* or \n, as in a table's own `grep -qE
# '^\*\*Files:\*\*'` old-lines) is a literal backslash plus that character, not a rejection ---
D="$(mkdoc esc.md '# Plan' '' \
  '```bash' \
  '  x=a\*b\n' \
  '  echo `hi`' \
  'bad "the escape label"' \
  '```' '' \
  '```bash' \
  "  mutate 'e/star-nl' 'scripts/x.sh' replace \\" \
  "    'the escape label' 'x.test.sh' \\" \
  '    "  x=a\*b\n" \' \
  "    'x=a-star-nl-new'" \
  "  mutate 'e/backtick' 'scripts/x.sh' replace \\" \
  "    'the escape label' 'x.test.sh' \\" \
  '    "  echo \`hi\`" \' \
  "    'echo hi-new'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>"${WORK}/esc.err")"; rc=$?
[[ "$(verdict "$out" e/star-nl)" == ok ]] && ok "check: a double-quoted \\* and \\n (backslash + a non-special char) is a literal backslash plus that char" \
  || bad "check: star-nl verdict '$(verdict "$out" e/star-nl)' rc=$rc: $out / $(cat "${WORK}/esc.err")"
[[ "$(verdict "$out" e/backtick)" == ok ]] && ok "check: a double-quoted backslash-backtick is a literal backtick" \
  || bad "check: backtick verdict '$(verdict "$out" e/backtick)' rc=$rc: $out / $(cat "${WORK}/esc.err")"

# --- a fenced "## Review" must not truncate the lint's view (found by linting this feature's own
# plan: the fixture it quotes carries one, the plan has no real ## Review heading, and a raw scan
# took the fenced one as the body's end — every entry after it went unlinted). No trailing real
# heading here on purpose: with one, the raw scan lands on it anyway and the guard is invisible.
D="$(mkdoc fencedreview.md '# Plan' '' '```markdown' '## Review' '```' '' '```bash' 'late_guard || die' 'bad "late label"' '```' '' '```bash' \
  "  mutate 'f/late' 'scripts/x.sh' delete 'late label' 'x.test.sh' 'late_guard || die'" \
  '```' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$(verdict "$out" f/late)" == ok ]] && ok "check: entries after a fenced ## Review are still linted" \
  || bad "check: a fenced ## Review truncated the body (rc=$rc out='$out')"

# --- a PR scratch is not applicable: its diff carries `+`/`-`/` ` prefixes, so a context-line
# `mutate` would parse and an edited entry would come back `unparsed` — an exit 1 the primary is
# forbidden to fix, since the diff is read-only (fable-rd1-r1) ---
D="$(mkdoc prscratch.md '# PR 1' '' '- **PR:** https://github.com/o/r/pull/1' '' '## Description' 'text' '' '## Diff' '```diff' '--- a/scripts/multi-review-mutation-check.sh' '+++ b/scripts/multi-review-mutation-check.sh' \
  "   mutate 'x/y' 'scripts/x.sh' replace \\" "-    'old label' 'x.test.sh' \\" "+    'new label' 'x.test.sh' \\" "     'line' \\" "     ':'" '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>"${WORK}/pr.err")"; rc=$?
[[ $rc -eq 3 && -z "$out" ]] && grep -qF 'PR scratch' "${WORK}/pr.err" && ok "check: a PR scratch is not applicable, and says so" \
  || bad "check: a PR scratch was linted (rc=$rc out='$out' err='$(cat "${WORK}/pr.err")')"
# a local doc with a REAL ## Diff section is still linted: the discriminator is pr.sh's identity
# line in the header, not a heading name (fable-rd2-r3)
D="$(mkdoc realdiff.md '# Plan' '' '## Diff' 'a section that happens to be called Diff' '' '```bash' 'g || die' 'bad "lbl"' '```' '' '```bash' "  mutate 'q/ok' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'g || die'" '```' '')"
bash "$SUT" check "$D" --repo "$REPO" >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "check: a local doc with a real ## Diff section is still linted" || bad "check: a ## Diff heading made a local doc not-applicable (rc=$?)"

# --- a block tagged `fixture` is quoted material and is skipped (fable-rd1-r2) ---
D="$(mkdoc fixture.md '# Plan' '' '````markdown fixture' '```bash' "  mutate 'f/stale' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'this line exists nowhere'" '```' '````' '' \
  '```bash' 'g || die' 'bad "lbl"' '```' '' '```bash' "  mutate 'f/live' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'g || die'" '```' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$(verdict "$out" f/live)" == ok ]] && ! grep -q 'f/stale' <<<"$out" \
  && ok "check: a fixture-tagged block's entries are not linted" || bad "check: the fixture block was linted (rc=$rc out='$out')"

# --- an unterminated LAST fenced block whose final line is itself the mutate entry: the closing
# fence is missing entirely, so the entry's own line must still be read as code ---
D="$(mkdoc unterm2.md '# Plan' '' '```bash' 'g || die' 'bad "lbl"' '```' '' '```bash' \
  "  mutate 'f/unterm' 'scripts/x.sh' delete 'lbl' 'x.test.sh' 'g || die'")"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$(verdict "$out" f/unterm)" == ok ]] \
  && ok "check: an entry on the last line of an unterminated final block is still linted" \
  || bad "check: unterminated final block: rc=$rc out='$out'"

# --- an EMPTY fenced block must contribute nothing: `sed -n "N,N-1p"` prints line N on both BSD and
# GNU sed, so a span check that lets a zero-line block through leaks its closing fence into the
# corpus, and an entry whose old-line is a bare fence would then verify against it ---
D="$(mkdoc emptyblock.md '# Plan' '' '```bash' '```' '' '```bash' 'g || die' 'bad "lbl"' '```' '' '```bash' \
  "  mutate 'e/fence' 'scripts/x.sh' delete 'lbl' 'x.test.sh' '\`\`\`'" \
  '```' '' '## Review' '')"
out="$(bash "$SUT" check "$D" --repo "$REPO" 2>/dev/null)"
[[ "$(verdict "$out" e/fence)" == target-missing ]] \
  && ok "check: an empty fenced block leaks no closing fence into the corpus" \
  || bad "check: empty-block fence verdict '$(verdict "$out" e/fence)' — a fence line reached the corpus"

# --- usage ---
bash "$SUT" check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "check: no doc is a usage error" || bad "check: no-doc rc=$?"
bash "$SUT" check "${WORK}/nope.md" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "check: a missing doc exits 2" || bad "check: missing doc rc=$?"
bash "$SUT" check "$F" --repo "${WORK}/norepo" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "check: a missing --repo exits 2" || bad "check: bad repo rc=$?"
bash "$SUT" check "$F" --repo >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "check: a bare --repo with no value exits 2, not through \${2:?}" || bad "check: a bare --repo rc=$? (codex-rd1-r2)"
bash "$SUT" frobnicate >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "unknown subcommand exits 2" || bad "unknown subcommand rc=$?"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
