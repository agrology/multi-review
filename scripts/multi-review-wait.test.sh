#!/usr/bin/env bash
# multi-review-wait.test.sh — lock-free bounded wait for a marker state (reviewer side).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-wait.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export MULTI_REVIEW_WAIT_INTERVAL=1
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

mkdoc() { # mkdoc <name> <state>; prints path
  local p="${WORK}/$1"
  printf '# T\n\n<!-- multi-review: %s · round 2/10 -->\n' "$2" > "$p"
  echo "$p"
}

# --- already in the target state -> exit 0 immediately ---
D="$(mkdoc now.md awaiting-reviewer)"
bash "$SUT" "$D" awaiting-reviewer 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "exit 0 when already in target state" || bad "already-in-state rc=$rc (want 0)"

# --- state reached during the wait -> exit 0 ---
D="$(mkdoc flip.md awaiting-author)"
( sleep 2; printf '# T\n\n<!-- multi-review: awaiting-reviewer · round 2/10 -->\n' > "$D" ) &
bash "$SUT" "$D" awaiting-reviewer 10 >/dev/null 2>&1; rc=$?
wait
[[ "$rc" == 0 ]] && ok "exit 0 when state reached mid-wait" || bad "mid-wait flip rc=$rc (want 0)"

# --- bound reached -> exit 9 (re-run to keep waiting) ---
D="$(mkdoc slow.md awaiting-author)"
bash "$SUT" "$D" awaiting-reviewer 2 >/dev/null 2>&1; rc=$?
[[ "$rc" == 9 ]] && ok "exit 9 on timeout" || bad "timeout rc=$rc (want 9)"

# --- terminal state that is not the target -> exit 10 (stop, human gate) ---
D="$(mkdoc done.md exhausted)"
bash "$SUT" "$D" awaiting-reviewer 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 10 ]] && ok "exit 10 when a terminal state preempts the wait" || bad "terminal rc=$rc (want 10)"
D="$(mkdoc conv.md converged)"
bash "$SUT" "$D" awaiting-author 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 10 ]] && ok "exit 10 on converged too" || bad "converged rc=$rc (want 10)"

# --- waiting FOR a terminal state is allowed ---
D="$(mkdoc want-conv.md converged)"
bash "$SUT" "$D" converged 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "waiting for a terminal state itself works" || bad "wait-for-terminal rc=$rc (want 0)"

# --- usage errors -> exit 2 ---
bash "$SUT" "${WORK}/nope.md" awaiting-reviewer 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "missing doc exits 2" || bad "missing doc rc=$rc (want 2)"
D="$(mkdoc args.md awaiting-author)"
bash "$SUT" "$D" not-a-state 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "invalid state exits 2" || bad "invalid state rc=$rc (want 2)"
bash "$SUT" "$D" awaiting-reviewer abc >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "non-integer bound exits 2" || bad "non-integer bound rc=$rc (want 2)"

# --- lock-free: never creates or touches the watcher's lockdir ---
D="$(mkdoc nolock.md awaiting-author)"
bash "$SUT" "$D" awaiting-reviewer 2 >/dev/null 2>&1
[[ ! -e "${D}.multi-review-watch.lock" ]] && ok "takes no lock (author watcher undisturbed)" || bad "wait created a lockdir"

# --- --seed: distinguish "never took a turn" from "still writing" on a bound hit (#71, #47) ---
#
# The bound hit is the input to the quarantine decision, and exit 9 alone cannot tell a reviewer
# that never opened the doc from one mid-write. Measured on a real run: `fable` latencies spanned
# 60-622s, and a bound-hit copy that was byte-identical at the bound completed 82s later with 11
# findings including a high. Quarantining on the first non-zero discards that turn.
SEEDW="${WORK}/seedcase"; mkdir -p "$SEEDW"
mkseed() { # mkseed <name> <state> ; makes <p> and <p>.seed identical, prints <p>
  local p="${SEEDW}/$1"
  printf '# T\n\n<!-- multi-review: %s · round 2/10 -->\n\n## Review\n' "$2" > "$p"
  cp "$p" "${p}.seed"
  echo "$p"
}

# byte-identical to its seed at the bound: the reviewer provably contributed nothing yet.
D="$(mkseed untouched.md awaiting-reviewer)"
err="$(bash "$SUT" "$D" awaiting-author 2 --seed "${D}.seed" 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 9 ]] && ok "exit 9 when the copy is byte-identical to its seed at the bound" \
  || bad "byte-identical bound hit rc=$rc (want 9)"
grep -qi 'no turn taken' <<<"$err" \
  && ok "the byte-identical case is reported as 'no turn taken'" \
  || bad "byte-identical bound hit does not say 'no turn taken': '$err'"

# changed but not yet flipped: the reviewer is demonstrably alive and mid-write. Quarantining
# here throws away a turn that is actively being written.
D="$(mkseed inflight.md awaiting-reviewer)"
printf '> [finding:r1|high] partial\n' >> "$D"
err="$(bash "$SUT" "$D" awaiting-author 2 --seed "${D}.seed" 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 8 ]] && ok "exit 8 when the copy changed but the marker is not flipped" \
  || bad "in-flight bound hit rc=$rc (want 8, distinct from 9)"
grep -qi 'in progress\|still writing' <<<"$err" \
  && ok "the in-flight case says the reviewer is still working" \
  || bad "in-flight bound hit message does not say so: '$err'"

# --seed never changes the SUCCESS path: reaching the state still exits 0.
D="$(mkseed reached.md awaiting-author)"
bash "$SUT" "$D" awaiting-author 5 --seed "${D}.seed" >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "--seed does not disturb the exit-0 path" || bad "--seed broke success rc=$rc"

# ...nor the terminal-state path.
D="$(mkseed term.md converged)"
bash "$SUT" "$D" awaiting-author 5 --seed "${D}.seed" >/dev/null 2>&1; rc=$?
[[ "$rc" == 10 ]] && ok "--seed does not disturb the exit-10 path" || bad "--seed broke terminal rc=$rc"

# a missing seed is a usage error, not a silent downgrade to the old behaviour: a caller that
# passes --seed is asking for the distinction, and quietly not making it is how a quarantine
# reason becomes wrong again.
D="$(mkseed noseed.md awaiting-reviewer)"
bash "$SUT" "$D" awaiting-author 2 --seed "${SEEDW}/absent.seed" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "--seed with a missing file is a usage error" || bad "missing seed rc=$rc (want 2)"
bash "$SUT" "$D" awaiting-author 2 --seed >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "--seed with no value is a usage error" || bad "bare --seed rc=$rc (want 2)"

# WITHOUT --seed the bound hit stays exactly as it was — 9, no new behaviour for old callers.
D="$(mkseed nolegacy.md awaiting-reviewer)"
printf '> [finding:r1|high] partial\n' >> "$D"
bash "$SUT" "$D" awaiting-author 2 >/dev/null 2>&1; rc=$?
[[ "$rc" == 9 ]] && ok "without --seed a bound hit is still a plain 9 (back-compatible)" \
  || bad "bound hit without --seed changed to rc=$rc"

# --- the default bound must cover the floor reviewer's measured latency (#71) ---
# `fable` is the guaranteed secondary, so its latency sets the floor for every default run. A
# default below it quarantines the ONLY secondary a default run has, which trips the
# all-quarantined anomaly stop and kills the whole review on latency alone.
# Read the default from its named constant. The extraction is guarded against VACUITY first:
# a sloppier reader (`awk -F'"' '/^max=/'` piped through `tr -dc 0-9`) turns `${3:-240}` into
# "3240" and the >= comparison then passes for any value at all — an assertion that reads
# correctly and cannot fail, which is the one thing this repo's gate exists to catch.
defmax="$(sed -n 's/^DEFAULT_MAX_SECONDS=\([0-9][0-9]*\)$/\1/p' "$SUT")"
[[ "$defmax" =~ ^[0-9]+$ ]] \
  || bad "could not read DEFAULT_MAX_SECONDS from $(basename "$SUT") — the bound assertion below is vacuous"
[[ "$defmax" =~ ^[0-9]+$ ]] && { (( defmax >= 600 )); } \
  && ok "default bound (${defmax}s) covers the measured fable range (60-622s)" \
  || bad "default bound is ${defmax}s — below fable's measured 60-622s, so the floor reviewer is quarantined on latency"

# --- a malformed marker mid-wait is tolerated (transient hand-edit), bounded anyway ---
D="$(mkdoc mangle.md awaiting-author)"
( sleep 1; echo garbage > "$D"; sleep 1; printf '# T\n\n<!-- multi-review: awaiting-reviewer · round 2/10 -->\n' > "$D" ) &
bash "$SUT" "$D" awaiting-reviewer 10 >/dev/null 2>&1; rc=$?
wait
[[ "$rc" == 0 ]] && ok "transient malformed marker tolerated" || bad "transient mangle rc=$rc (want 0)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
