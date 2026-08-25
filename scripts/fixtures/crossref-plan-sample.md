# Sample sectioned plan (fixture)

Reproduces the shape the union rule exists for: Task 1 names a file only in its steps, and Task 4
declares that same file in its Files block. A pair set built from declarations alone misses it. See
`docs/superpowers/specs/2026-08-24-crossref-pass-design.md` §2.

### Task 1: rewrite the availability check

**Files:**
- Modify: `scripts/multi-review-star.sh`

**Interfaces:**
- Produces: `resolve-set --allow-missing`

Step 7 rewrites the availability-check line, which is also the line targeted by the existing
entry in `scripts/multi-review-mutation-check.sh`.

### Task 4: mutation entries and the version bump

**Files:**
- Modify: `scripts/multi-review-mutation-check.sh`

**Interfaces:**
- Consumes: `resolve-set --allow-missing`

Add one entry per new guard.
