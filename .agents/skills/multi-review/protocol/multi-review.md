# Multi-Review Protocol (file-coordination, opt-in)

> Opt-in. One **primary** (Claude) plus N independent **secondary** reviewers coordinate over
> ONE doc via an in-file status marker + id'd finding threads. Always ends at a **human
> approval gate**.

## Roles

- **Primary** (Claude, via `/multi-review`): drafts/revises the doc, dispatches secondaries,
  adjudicates every finding, and decides convergence.
- **Secondaries** (independent reviewers — `fable` by default unless `MULTI_REVIEW_FABLE=off`, plus any of `codex`,
  `gemini` you add): each reviews its OWN isolated copy of the doc. A secondary never sees
  another secondary's findings or the primary's responses — that independence is the point.
- **Autonomous by default:** `/multi-review` fans out, waits, merges, and adjudicates
  unattended, ending at the same human gate (see the README).

## Status markers (two scopes)

**Doc marker** — one line near the top of `<doc>`, the primary's own coordination state:

    <!-- multi-review: <state> · round <n>/<max> -->
    <!-- multi-review-mode: star · reviewers: <ids> -->

| State | Meaning | Whose turn |
|---|---|---|
| `awaiting-secondaries` | primary needs a fresh round of findings | primary fans out |
| `awaiting-primary` | a round's findings are merged in | primary adjudicates |
| `converged` | every merged finding has exactly one response; no coverage gap (terminal) | human gate |
| `exhausted` | round bound reached with findings still unaddressed (terminal) | human gate |

**Copy marker** — one line near the top of each secondary's working copy `<doc>.<id>`, reusing
the reviewer/author vocabulary for that copy's single one-shot turn:

    <!-- multi-review: <state> · round <n>/<max> -->
    <!-- multi-review-mode: star -->

| State | Meaning |
|---|---|
| `awaiting-reviewer` | the secondary's turn — leave findings |
| `awaiting-author`   | the secondary is done; the copy is ready to merge |

A secondary acts ONLY when its copy's marker is `awaiting-reviewer`, does exactly one review
pass, and flips the copy's marker to `awaiting-author` as its FINAL edit (the flip is the
handoff) — it never sets any other state and never edits `<doc>` itself.

## Findings (the channel)

Under the copy's `## Review` heading, a secondary raises each concern as:

- `> [finding:<id>|<sev>] <concern>` — a fresh id scoped to this copy (`r1`, `r2`, …; the
  primary namespaces it `<provider>-rd<N>-<id>` on merge, so you never need to coordinate ids
  with anyone else). `<sev>` is `high`, `med`, or `low` — the parser rejects any other token.
  Keep the concern to one short line.
- `> — via <model>` — required disclosure line, immediately after. Must be your real model id.
- `> — risk: <short risk>` — required, immediately after that. One clause, no paragraphs.
- `> — evidence: <how you know>` — **required on `high` and `med`**: the mechanism that produces
  the failure, or the reproduction that was run. `low` does not need one. Severity is a claim
  about consequence, and `high`/`med` assert a defect exists — a concern that cannot be grounded
  that way is still worth raising, as a `low`. Measured across four reviews (issue #29), a stated
  mechanism was what separated findings worth acting on from speculative ones; it predicted value
  better than either the vendor or the severity tag.

  A missing evidence line is **never** a parse error. Rejecting the finding would fail the whole
  reviewer turn and discard its good findings along with the weak one. Instead
  `multi-review-star.sh evidence-gaps <doc>` lists undocumented `high`/`med` findings for the
  primary at adjudication, and `gate-summary` reports the count to the human.
- Optionally, `> — at <path>:<line>` (or `> — at <path>:<start>-<end>`) immediately after the
  risk line, using RIGHT-side new-file line numbers. This only matters when the reviewed doc
  is a PR diff scratch — omit it for a design doc. An anchor that doesn't land on a changed
  hunk degrades to the summary rather than posting inline.

A secondary raises findings only — it never responds to a finding (its own or anyone else's)
and never converges the review. Only top-level `> [..]` lines are control markers; nested
`> > ...` is ignored. Ids must be unique within the copy; a duplicate id is a hard error.

### Nothing to raise

A secondary that read the document in full and has **nothing to raise** must say so explicitly:

    > [no-findings] reviewed in full; nothing to raise
    > — via <model>

- This is a **MUST**, not a courtesy. A turn that flips the marker and writes nothing is
  byte-identical to one from a reviewer that never opened the document — the signal is the only
  thing that distinguishes a careful empty review from a no-op.
- The `> — via <model>` disclosure is **required**, exactly as on a finding. `verify-vendor`
  checks new protocol content only when the turn added no new `> — via` id anywhere in the doc,
  so a signal that is the turn's *only* new content fails there if it lacks its own disclosure —
  otherwise an empty turn would satisfy the identity guard vacuously.
- Trailing text after the tag is optional and free-form.
- It is **not a finding**: it never merges as one, never needs an `agree`/`dispute`, and never
  affects convergence.
- It is **mutually exclusive with findings**. A copy that emits the signal *and* raises findings
  in the same turn is self-contradictory and fails `channel-check`.

## Primary adjudication

On the merged doc (marker `awaiting-primary`), the primary responds to **every** merged
finding with exactly one of:

- `> [agree:<ns-id>]` + `> — via <primary-model-id>` — accept the finding and address it in the
  doc body, or
- `> [dispute:<ns-id>] <one-line reason>` + `> — via <primary-model-id>` — reject it, tersely.
  A dispute never forces another round.

The primary may also leave a human-gate-only note that is NOT a finding and never affects
convergence: `> [observation] <text>` + `> — via <primary-model-id>`.

Convergence is **coverage, not consensus**: every merged finding needs exactly one
`agree`/`dispute`; disputes are expected and do not block. The human gate settles disputes.

The primary **adjudicates rather than rubber-stamps**. It disputes a finding with no demonstrated
failure mode, one about the PR description or code the change does not touch, one hardening a case
that cannot occur, or one already answered — stating the reason in a line so the gate can overrule
it. It does **not** dispute to save a round: a finding it cannot refute on the merits is one it
agrees with, however inconvenient. Leniency is not neutral — every `agree` obliges an edit, and
those edits are what later rounds spend their time reviewing.

**Model-id distinctness:** every secondary and the primary discloses its own *real* model id
on `> — via <model>`. The primary's disclosed id must differ from every secondary's — the
self-response guard fails a response whose model equals the finding's raiser model, so a
Claude-family secondary (e.g. `fable`) colliding with a Claude primary id would make
convergence impossible.

## Fable floor & independence

- `fable` is included in the secondary set by default — it runs in-harness (no CLI, no extra
  auth), so a round normally has at least one admissible secondary even if every external
  provider is unavailable or gets quarantined.
- That floor is an operator switch, not a law: `MULTI_REVIEW_FABLE=off` suppresses it, so a run
  costs no Claude tokens for review. `fable` still appears when a source NAMES it. With the floor
  off and no other secondary usable the run **refuses to arm** rather than degrading to a
  primary-only self-review — a review with no independent voice is not a cheaper review.
- **A seeded copy is checked for blindness** before dispatch (`multi-review-star.sh blind-check`):
  it must carry no previous round's findings and none of the primary's responses. Seeding is done
  by hand, and a botched truncation is silent in the direction that matters — the secondary would
  read what everyone else already said while every downstream check still passes.
- A secondary is **quarantined** — excluded from the merge, with its reason recorded durably
  in the doc — when it can't be dispatched, times out, or fails vendor verification (its
  disclosed model doesn't match the vendor it was dispatched as). All secondaries quarantined
  in the same round, including `fable`, is an anomaly: the primary stops rather than merging a
  round with zero trustworthy findings.
- A later round re-dispatches the FULL resolved secondary set, not just previously-admitted
  ones — a provider quarantined in round 1 gets a fresh independent copy again in round 2.
  The set never shrinks on its own: a secondary that went dry can still catch something in text
  written since, so saturation is not grounds for dropping it automatically. `round-stats`
  reports each provider's dry streak so the primary can drop one **knowingly** instead.
- The gate summary warns when the round's admitted secondaries are all same-vendor as the
  primary: `⚠ Independence: ... no independent cross-vendor perspective this run.` Add
  `--reviewers codex` (or `gemini`) for architectural independence.

## Bounds & terminal state

Round = one secondary fan-out pass + one primary adjudication pass. **One round is the default**:
the primary converges after round 1 unless it agreed to a `high`-severity finding whose fix was
non-trivial, its between-round edits introduced new logic no reviewer has seen, or the engineer
asked for depth. Measured over four self-reviews (issue #29), round 1 produced 38% of findings and
every serious one, while rounds 2+ produced the rest almost entirely about the primary's own
mid-review patches — at the cost of re-reading the whole doc each time.

When the primary does re-fan, the bound still applies: it re-enters `awaiting-secondaries` only
while the round is under `max`, the previous round produced at least one new admitted finding,
**and the finding rate is still decaying**. It converges as soon as a round goes dry *or the rate
stops falling*. At
`round > max` the doc marker becomes `exhausted`. Convergence or exhaustion both stop the loop
and present the annotated doc; a **human approves** before any implementation or PR.

Why stopping needs a rule at all: the primary must address each agreed finding in the doc body
between rounds, so round N+1 reviews prose written during round N. Every round supplies fresh,
never-reviewed text, and the per-round count can flatten rather than fall to zero — a rule keyed
only on "did this round find anything" keeps firing for as long as the primary keeps editing,
which the protocol obliges it to do. Coverage convergence (every finding has a response) is
reachable by construction; quality convergence (no new findings) is not.

**Whatever the terminal state, the primary's last round of fixes is unreviewed**, and it says so
at the gate. That is inherent to a loop where the author patches between rounds; the human gate,
not another round, is what covers it.

`multi-review-star.sh round-stats <doc>` reports per-round × per-provider counts, the trend, each
provider's dry streak, and a converge/re-fan verdict, all read from the doc itself. It is
**advisory** — the primary decides. Reaching `max` on a doc the primary rewrites substantially
each round is a normal terminal outcome, not a failure state.

## Egress

- **Mechanical (primary side):** `/multi-review` refuses to arm on any path outside
  `MULTI_REVIEW_DOC_DIRS` (default `docs/specs docs/plans docs/superpowers/specs
  docs/superpowers/plans`), or on a symlink/`../` escape.
- **Protocol requirement (secondary side, trusted):** a conforming secondary reads only the
  copy it is pointed at, captures no env/secrets, and uploads nothing beyond that copy's
  content without explicit authorization. This is a trust contract, not a mechanical
  guarantee.
- **PR mode (primary side):** when the reviewed artifact is a GitHub PR, coordination is still
  a local scratch file under `.multi-review/reviews/`. Only the **primary** touches GitHub — it
  reads the PR (`gh pr view`/`gh pr diff`) on ingest and posts **exactly one** neutral review
  (`gh pr review --comment`) on publish, and the publish is **human-gated**. Agreed findings
  carrying a valid `> — at <path>:<line>` anchor post as inline comments inside that single
  review; everything else stays in the top-level summary. Secondaries touch no GitHub: they
  read only their local working copy.

## Supersedes

The asymmetric single-reviewer grammar (`> [reviewer:]` / `> [author: resolved:]`) and the
two-agent peer-review grammar (`> [finding:]` answered by `> [concur:]` / `> [dispute:]`) are
both superseded by star: every review — local doc or PR — now runs primary + N independent
secondaries.
