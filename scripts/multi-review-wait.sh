#!/usr/bin/env bash
# multi-review-wait.sh <doc> <state> [max-seconds] [--seed <copy-as-dispatched>] — lock-free
# bounded wait until the multi-review marker reaches <state>. Used by the star primary during
# fan-out to bound the wait on each secondary's working copy; it takes no lock and writes nothing.
#
# Exit: 0 state reached · 8 bound hit and the copy CHANGED since dispatch (still writing) ·
#       9 bound hit, state not reached (re-run to keep waiting) ·
#       10 a terminal state (converged/exhausted) preempted the wait — stop, human gate ·
#       2 usage / doc missing.
#
# Bounded on purpose: agent harnesses time out long commands, and an unbounded poll dies
# with them silently. A 9 tells the caller "nothing happened yet, run me again".
#
# WHY 8 EXISTS (issues #71, #47). The bound hit is the input to the quarantine decision, and a
# bare 9 cannot tell a reviewer that never opened the document from one that is mid-write. Those
# are opposite facts: the first is the only state that PROVES a reviewer did nothing, the second
# proves it is alive. Measured on a real run, `fable` latencies spanned 60-622s and a copy that
# was byte-identical at the bound completed 82s later with 11 findings including a `high` —
# quarantining on the first non-zero discarded a turn that had done real work. With `--seed` the
# caller gets the distinction for free, because the copy-as-dispatched is already snapshotted for
# `channel-check`.
#
# Callers that pass no `--seed` see the old behaviour exactly: a bound hit is a plain 9.
set -uo pipefail

die() { echo "multi-review-wait: $1" >&2; exit 2; }

# The default bound must cover the FLOOR reviewer's latency, not a typical one. `fable` is present
# in every default run, so if the default quarantines it, the default run has no secondary left
# and trips the all-quarantined anomaly stop — the whole review dies on latency alone. Measured
# range for fable is 60-622s (#71), and the previous 240s default sat inside it: a substantial
# fraction of rounds were quarantining a reviewer that simply had not finished. Raised to cover
# the observed maximum with margin. A caller that knows better still passes its own bound.
DEFAULT_MAX_SECONDS=600

doc="${1:?usage: multi-review-wait.sh <doc> <state> [max-seconds] [--seed <copy-as-dispatched>]}"
state="${2:?usage: multi-review-wait.sh <doc> <state> [max-seconds] [--seed <copy-as-dispatched>]}"
shift 2

max=""
seed=""
while (( $# )); do
  case "$1" in
    --seed)
      # Explicit arity check: `shift 2` with one arg left does not shift in bash, it just returns
      # non-zero, so an unguarded loop here spins forever on a bare trailing flag.
      (( $# >= 2 )) || die "--seed requires a value"
      seed="$2"; shift 2 ;;
    *)
      [[ -n "$max" ]] && die "unexpected argument: $1"
      max="$1"; shift ;;
  esac
done
max="${max:-$DEFAULT_MAX_SECONDS}"

[[ -e "$doc" ]] || die "doc not found: $doc"
case "$state" in
  awaiting-reviewer|awaiting-author|converged|exhausted) ;;
  *) die "unknown state '$state' (a typo would wait forever)" ;;
esac
[[ "$max" =~ ^[0-9]+$ ]] || die "max-seconds must be a non-negative integer, got '$max'"
# A missing seed is a usage error, never a silent downgrade to the undifferentiated 9. A caller
# that passes --seed is asking for the distinction, and quietly not making it is precisely how a
# quarantine reason becomes wrong again — the failure this flag exists to prevent.
[[ -z "$seed" || -f "$seed" ]] || die "seed snapshot not found: $seed"

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval="${MULTI_REVIEW_WAIT_INTERVAL:-5}"

# Classify a bound hit. Without a seed there is nothing to compare, so the verdict is the historic
# 9. With one, a copy that still equals what was dispatched is the ONLY state that proves no turn
# was taken; anything else means the reviewer wrote something and has not yet flipped the marker.
bound_hit() {
  if [[ -z "$seed" ]]; then
    exit 9
  fi
  if cmp -s "$doc" "$seed"; then
    echo "multi-review-wait: no turn taken — the copy is byte-identical to its seed after ${max}s" >&2
    exit 9
  fi
  echo "multi-review-wait: in progress — the copy changed since dispatch but the marker is not flipped after ${max}s; the reviewer is still writing, re-run the wait" >&2
  exit 8
}

while :; do
  # An unreadable/malformed marker is tolerated: the peer hand-edits the doc, so brief
  # inconsistent reads are expected mid-edit. The bound keeps a permanently broken doc
  # from hanging us.
  cur="$(bash "${dir}/multi-review-core.sh" marker "$doc" 2>/dev/null | awk '{print $1}')"
  [[ "$cur" == "$state" ]] && exit 0
  case "$cur" in
    converged|exhausted) exit 10 ;;   # review is over; waiting further is pointless
  esac
  (( SECONDS >= max )) && bound_hit
  sleep "$interval"
done
