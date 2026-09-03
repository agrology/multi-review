# Plan: loud undispatchable reviewer (round-2 shape, reduced)

### Task 1: the emitter

**Files:**
- Modify: `scripts/multi-review-star.sh`

```bash
_undispatchable() { # <id> <raw-reason>
  echo "multi-review-star: UNDISPATCHABLE ${1}: $(_norm_reason "${2:-}")" >&2
}
```

```bash
# test 7
bad "a pref-sourced drop emits UNDISPATCHABLE"
```

### Task 4: the table

**Files:**
- Modify: `scripts/multi-review-mutation-check.sh`

```bash
  mutate 'star/undispatchable-emitted' 'scripts/multi-review-star.sh' replace \
    'a pref-sourced drop emits UNDISPATCHABLE' 'multi-review-star.test.sh' \
    '  echo "multi-review-star: UNDISPATCHABLE ${1}: ${r:-unavailable}" >&2' \
    '  :'
```

## Review
