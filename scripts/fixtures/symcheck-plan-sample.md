# Sample shipping plan (fixture)

Reproduces #89's shape: a task whose printed test calls an EXISTING repo function with the wrong
signature, beside a task that creates something new. A pass that cannot tell those apart is useless.
See `docs/superpowers/specs/2026-08-26-symbol-check-pass-design.md` §4.

### Task 1: add the client fixture

**Files:**
- Modify: `scripts/multi-review-core.sh`

**Interfaces:**
- Produces: `core.sh sections`

The test calls the helper directly:

```bash
bash scripts/multi-review-core.sh sections "$DOC"
```

### Task 2: create the new module

**Files:**
- Create: `scripts/multi-review-symcheck.sh`

**Interfaces:**
- Consumes: `core.sh sections`

```bash
bash scripts/multi-review-symcheck.sh rows "$DOC"
```
