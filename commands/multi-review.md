---
description: Multi-review — a star review (you as primary + N independent secondaries) over a spec/plan doc or a PR, converging to a human gate.
argument-hint: "[doc-path | PR-URL] [--reviewers <csv>]"
---

You are the **primary** in a multi-review star review: you dispatch N independent secondaries,
adjudicate their findings, and drive convergence — always stopping at a **human gate**. `fable`
is always one of the secondaries (your guaranteed in-harness review voice); any `--reviewers`
you name are added to it. Drive the review with the repo's shell helpers; you own prose edits
and marker flips, the helpers own grammar/merge/convergence. There is one review model — star —
for every doc; never advance past the human gate.

## 1. Resolve the argument

**Diagnostic shortcut (no review).** If `$ARGUMENTS` contains `--check-reviewers`, run
`${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh doctor`, show its per-provider readiness
checklist to the engineer, and STOP — do not resolve a doc or arm anything (a no-arm path, like the
standalone revoke). Use it to answer "why isn't `<reviewer>` working" before a real run.

**Split first.** `$ARGUMENTS` may carry `--reviewers <csv>` (a comma-separated provider set,
e.g. `codex,gemini`) in addition to the doc path or PR ref, in any order. Extract `--reviewers`
(consumed in §2). Everything else is `<positional>` (empty if flags-only, or absent).
Classification and doc resolution below use `<positional>` only — never the raw `$ARGUMENTS` —
so a trailing flag can never corrupt PR-ref matching or a doc path.

### Reviewers named in prose (natural language)

Reviewers may be named in **prose** — "with codex and gemini", "just codex" — not only as
`--reviewers`. Normalize either form into the reviewer set (comma-joined provider ids) before §2;
a prose mention and `--reviewers codex,gemini` are equivalent inputs.

**Criterion for "explicitly named":** because the prose set also drives the pref write-back (§2),
the bar is deliberately narrow — treat prose as a reviewer choice **only when the user's request
for *this* review names the reviewers as its reviewer set** (an imperative like "multi-review the
spec with codex and gemini"). A reviewer mentioned in passing, in a question, or about a *past* run
("like last time with codex?") is **not** a choice: do not normalize it, and do not write the
pref. When it is genuinely ambiguous whether a name is this run's choice, **ask rather than guess**.

**Three intents** — do not conflate them (they drive different §2 write-back actions):

| user phrasing (this run) | intent | this run's set | §2 write-back |
|---|---|---|---|
| "multi-review the spec with codex and gemini" | named extras | codex,gemini (+fable) | `remember-set --reviewers codex,gemini` |
| "multi-review with just codex this time" | one-off | codex (+fable) | none |
| "just fable this once" | one-off | fable only | none |
| "forget the reviewers" / "fable-only from now on" | revoke | fable only | `remember-set --clear` |
| "like last time with codex?" (a question about a past run) | not a choice | (per pref/env) | none |
| ambiguous whether it's this run's choice | ask (default to one-off) | (per ask) | none until clarified |

The phrase "this time" / "just this once" is the signal that scopes a naming to a **one-off**
(resolve for this run, leave the pref alone) rather than a persistent choice or a revoke.

**A one-off ignores the pref for this run (fable-rd1-r1).** A one-off explicitly scopes to *this*
run, so it must NOT inherit the remembered combo — resolve it in §2 **without** `--pref-file`
(passing `--reviewers <ids>` for a named one-off, or nothing at all for "just fable this once",
which then floors to fable only). Omitting `--pref-file` is the ONLY way to force fable-only against
a stored pref: `resolve-set` treats an empty `--reviewers` as absent and would otherwise fall
through to the pref.

**Standalone revoke — no review (codex-rd1-r1).** If the request is *purely* to forget the
remembered combo ("forget the reviewers", "reset to fable-only from now on") with **no doc or PR to
review**, do NOT resolve a doc or arm anything: run
`${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh remember-set --pref-file
.multi-review/reviewers.pref --clear`, confirm "remembered reviewers cleared — bare runs will use
fable only," and STOP. Only when the same turn *also* asks for a review does the revoke fold into
the §2 write-back instead.

### Classify (doc path vs. PR)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh parse "<positional>"`.

- **Exit non-zero** (not a PR ref) → this is a local doc. Continue at "Resolve the doc" below.
- **Exit 0** → it printed `owner|repo|number` (owner/repo empty for the bare `#n` form). This
  is **PR flavor**:
  1. If owner/repo are empty, fill them: `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh resolve-repo` →
     `owner|repo`. If it fails, report and STOP.
  2. Compute the scratch path:
     `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh scratch-path "<owner>" "<repo>" "<number>"`.
  3. **Resume vs. fresh — re-ingest ONLY when the scratch file is absent.** Re-ingesting
     rewrites the file and would erase accumulated findings/responses, so:
       - **Scratch file does not exist** → `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh ingest "<owner>"
         "<repo>" "<number>"` (fetches via `gh`, writes the file, prints its path). On `gh`
         failure (unauthenticated, PR not found), report and STOP.
       - **Exists with a non-terminal marker** (`awaiting-secondaries`/`awaiting-primary`, via
         `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<scratch>"`) → **resume**: do NOT ingest.
         (`ingest` also refuses to clobber without `--fresh`, as a backstop.)
       - **Exists with a terminal marker** (`converged`/`exhausted`) → surface it and ask the
         engineer: resume reading it (skip ingest), or start fresh. Only if they choose fresh,
         run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh ingest --fresh "<owner>" "<repo>" "<number>"`.
  4. Set `<doc>` to the scratch path. The ingested scratch carries `## PR description` / `## Diff`
     / `## Review` and the PR url in its header; it is armed as a star review in §3 exactly like a
     local doc (the egress guard already allows `.multi-review/reviews`). The **only** difference
     is the terminal gate offers a human-gated publish back to the PR (§3, "Terminal gate").

### Resolve the doc (local, deterministic)

- If `<positional>` is non-empty, that path is the doc.
- Else: list `.md` files **directly under** each dir in `MULTI_REVIEW_DOC_DIRS`
  (default `docs/specs docs/plans`) whose names match `YYYY-MM-DD-…`. Pick the greatest by
  **date prefix, then filename** (NOT mtime). If there are zero candidates, or the top two
  share a date prefix (a tie), STOP and ask the engineer to pass an explicit path.

## 2. Resolve the reviewer set (`fable` always included)

Determine the secondaries once, here, and carry the rows through the whole run — never
re-resolve later (a mutable env var could otherwise swap providers mid-review unnoticed).

1. **Resume check (the doc's own header, checked first):** run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh mode "<doc>"`.
   - Prints `star` (exit 0) → `<doc>` is **already** a star review in flight. Read the
     `reviewers: <ids>` suffix off that header line and feed it back into
     `multi-review-star.sh resolve-set --fable-floor --reviewers <ids,comma,joined>` to rebuild
     the `id|vendor|kind|model|has-skill` rows. Go to §3.
   - Exits 1 (no star hint yet — a fresh local doc, or a just-ingested PR scratch) → fall
     through to step 2.
2. **Fresh-request check:** run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh resolve-set --fable-floor --pref-file
   .multi-review/reviewers.pref`, appending `--reviewers <csv>` when §1 extracted a set (flag or
   prose). Precedence is flag/prose → `MULTI_REVIEW_REVIEWERS` → the pref → fable-only; the pref is
   consulted **only** when neither a named set nor the env supplied one.
   - **One-off exception (§1, fable-rd1-r1):** when the §1 intent is a **one-off override**, OMIT
     `--pref-file` from this call, so the remembered combo does not leak into a run the user scoped
     to just this once (this is required for "just fable this once" to actually resolve fable-only —
     an empty `--reviewers` alone would fall through to the pref).
   - **Exit 0** → the resolved set, one `id|vendor|kind|model|has-skill` row per line. `fable` is
     always present (the `--fable-floor` union), so the set is never empty. These are the
     secondaries for the whole run.
   - **Capture `resolve-set`'s stderr.** When it prints a `pref reviewer '<id>' … dropping` line
     (a stale/unavailable remembered reviewer self-healed away), **relay it at arm time** (§3) so a
     silently narrowed combo is visible.
   - **Any non-zero exit** (an unknown provider id in a *named* set / env, or a typo'd flag) →
     report the message and STOP. (A stale id in the pref never reaches here — it is dropped with
     a notice, not an error.)

3. **Write-back (persist the choice) — do this once, right after arming a fresh review (§3):**
   act on the §1 intent, with the pref at `.multi-review/reviewers.pref`:
   - **named extras** → `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh remember-set
     --pref-file .multi-review/reviewers.pref --reviewers <csv>`;
   - **explicit revoke** → same with `--clear` instead of `--reviewers`;
   - **one-off override, a bare run, or a set resolved from env/pref** → no write, no clear.

   Write-back is best-effort and **non-fatal** — the run has already armed and proceeds regardless
   — but it is **not silent**: relay `remember-set`'s stderr to the engineer. In particular the
   env-shadow notice (`MULTI_REVIEW_REVIEWERS is set … not writing pref`), so the engineer never
   believes a combo was saved when env will shadow it. Resume runs (step 1) never write.

## 3. Star review — arm, fan-out, primary turn, terminal gate

### Arm (idempotent)

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-egress-guard.sh "<doc>"`. Non-zero → report the
  message and STOP — do not arm.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<doc>"`.
  - **Succeeds** (a marker already exists) → RESUMING an armed review. Do not re-arm. Go to
    "Branch on the marker" with the CURRENT state.
  - **Fails** (no marker yet) → fresh. Insert the star two-line header right after the H1:

        <!-- multi-review: awaiting-secondaries · round 1/<MAX> -->
        <!-- multi-review-mode: star · reviewers: <ids> -->

    `<MAX>` is `${MULTI_REVIEW_MAX_ROUNDS:-5}` — a **cost ceiling, not a target** (each round
    fans out to N secondaries). `<ids>` is the resolved set's ids from §2, **space**-joined in
    resolved order (e.g. `codex fable`). This one insertion covers local and PR docs alike —
    `pr.sh` ingest deliberately writes no mode hint, so there is never a duplicate.
  - **If `<doc>` has no `## Review` heading yet** (a fresh local spec/plan doc; PR scratch files
    already have one), append one now, with nothing under it — `merge` appends findings after the
    LAST `## Review` heading, so a doc with none would silently lose every merged finding.
  - **Perform the §2 step 3 write-back now** (persist named extras, `--clear` a revoke, or nothing
    for a one-off/bare run), relaying any `remember-set` stderr (esp. the env-shadow notice).
  - **Relay pref drops.** If §2's `resolve-set` emitted any `pref reviewer '<id>' … dropping` line
    on stderr, surface it in the armed message — a remembered reviewer dropped for two reasons,
    each a stable `pref reviewer … dropping` line: `unknown — dropping` (stale, registry-removed)
    and `unavailable in this repo — dropping` (registered but not set up). So a self-healed, quietly
    narrowed combo is visible, mirroring a dispatch quarantine.
  - **Relay preflight hints.** For each resolved secondary, run
    `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh check --reviewer <id>` and surface any
    `hint (<id>): …` line it prints on stderr in the armed message (e.g. "gemini: workspace may be
    untrusted — export GEMINI_CLI_TRUST_WORKSPACE=true"). This is **advisory** — `check` exits 0 and
    the secondary is still dispatched; the hint just puts the likely fix in front of the engineer
    *before* a misconfigured reviewer would otherwise fail mid-review and quarantine. Never a gate,
    never blocks dispatch. (Run `/multi-review --check-reviewers` for the full doctor report.)
  - Tell the engineer: "multi-review armed on `<doc>` — secondaries: `<ids>` (round bound `<MAX>`)"
    — and append any dropped-reviewer relay, e.g. "`gemini` dropped: unavailable in this repo".

### Branch on the marker

- **`awaiting-secondaries`** → run "Fan-out", then re-read the marker (now `awaiting-primary`)
  and continue directly into "Primary turn" in the same invocation — the primary IS this command,
  so there is no cross-session handoff between these states.
- **`awaiting-primary`** → run "Primary turn".
- **`converged`** → go to "Terminal gate".
- **`exhausted`** → present the still-open findings
  (`${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh open-findings "<doc>"`) and tell the
  engineer: "round bound reached with findings still unaddressed — escalate to a human." STOP.
  (Rare: convergence is coverage-based, so the primary can always converge once it has responded
  to every finding — but the state is honored defensively for a hand-edited doc.)

#### Fan-out (on `awaiting-secondaries`)

1. **Snapshot the baseline.** Copy `<doc>` to `<doc>.baseline`. In that COPY ONLY, truncate
   everything after the doc's LAST `## Review` heading — keep the heading line, drop everything
   after it (any prior round's merged findings/responses). `<doc>` itself is untouched.
2. **Seed one copy per provider**, using the SAME resolved set from §2 — a later round does not
   shrink the set, even for a provider quarantined earlier; it gets a fresh independent copy
   again. For each id: `cp "<doc>.baseline" "<doc>.<id>"`, then rewrite that copy's header to:

        <!-- multi-review: awaiting-reviewer · round <N>/<MAX> -->
        <!-- multi-review-mode: star -->

   (`<N>` is the round this fan-out is running; no `reviewers:` suffix on a working copy.) The
   copy carries the empty `## Review` heading from step 1; the secondary appends findings beneath.
3. **Provision each secondary's skill, right before dispatch.** The working root is the git
   toplevel of the repo under review — your own invocation directory (`git rev-parse
   --show-toplevel`) — **never** `<doc>`'s own location: for a PR-flavor doc, `<doc>` is a
   scratch file under `.multi-review/reviews/` and is not the repo it describes. For each id, run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh ensure-skill --reviewer <id> --repo
   <that working root>` — a no-op for skill-less reviewers. Non-zero
   exit → do NOT dispatch that reviewer this round; quarantine it now, using the command's stderr
   as the reason, via the same quarantine path a dispatch failure uses (record `--quarantined
   <id>:<reason>` for the merge below). If every selected reviewer quarantines here, apply the
   existing all-failed anomaly stop (below) before dispatching anyone.
4. **Dispatch every secondary in the same turn**, so the harness runs them concurrently — never
   one after another. Branch on `kind`, pointed at `<doc>.<id>`:
   - **`subagent`** → dispatch the Agent tool with the resolved `model`, passing the output of
     `multi-review-reviewer.sh prompt "<doc>.<id>" --reviewer <id>` as the task text. For `codex`
     use the `codex:codex-rescue` agent with `--model <model> --write`; for `fable` use
     `general-purpose` with `model: fable`. `--model`/`--write` are runtime controls, stripped
     from the task text. Run it in the same working root the reviewer was just provisioned into
     (step 3) — the two must never diverge.
   - **`shell`** → read NUL-delimited argv and execute it without a shell round-trip (macOS bash
     3.2 has no `mapfile`), launched as a background task so it does not block the batch:

            argv=()
            while IFS= read -r -d '' a; do argv+=("$a"); done \
              < <("${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh" command "<doc>.<id>" --reviewer <id>)
            # Guard the empty case BEFORE expanding: on macOS bash 3.2 under `set -u`,
            # "${argv[@]}" on a zero-element array is a fatal unbound-variable error. An empty
            # argv means the command could not be built — treat it as a dispatch failure for
            # this provider (quarantine it) rather than expanding.
            (( ${#argv[@]} )) || { : quarantine <id> "could not build reviewer command"; }
            (( ${#argv[@]} )) && "${argv[@]}"

   All same-turn subagent dispatches go in the SAME response block as each other.
5. **Bound the wait, per copy.**
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-wait.sh "<doc>.<id>" awaiting-author [seconds]`
   (240s default is reasonable; raise it for a known-slow provider). Exit 0 → verify below.
   Non-zero (bound hit, or the copy went sideways) → quarantine this provider (next step) with
   that reason. A hung secondary must never stall the others or the round.
6. **Verify identity, per copy that reached `awaiting-author`.**
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh verify-vendor --baseline
   "<doc>.baseline" "<doc>.<id>" --reviewer <id>`. Pass → admit the copy into the merge. Fail →
   quarantine: exclude it and record `--quarantined <id>:<reason>` (the reason is
   `verify-vendor`'s message, or "no response within the wait bound" from step 5).
   - **All secondaries quarantined** (including `fable`) → an **anomaly stop**: do not advance the
     marker; surface every quarantine reason and STOP. A round with zero trustworthy findings
     cannot merge. (In practice `fable` runs in-harness and should always be admissible, so this
     should not occur.)
7. **Merge.** `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh merge --round <N> [--quarantined
   <id>:<reason> ...] "<doc>" <admitted copies...>`.
8. **Flip the marker.** Edit `<doc>`'s marker from `awaiting-secondaries` to `awaiting-primary`,
   same round number — your final edit of this step. Retain `<doc>.<id>` for every provider,
   `<doc>.manifest`, and `<doc>.baseline` — the terminal gate releases them.

#### Primary turn (on `awaiting-primary`)

1. List the merged findings awaiting a response:
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh open-findings "<doc>"`, and the ones
   asserting a defect without saying how it is known:
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh evidence-gaps "<doc>"`.

   An `evidence-gaps` entry is **not** an automatic dispute — the mechanism may be obvious from
   the concern itself. It marks where to apply the "no demonstrated failure mode" test below
   rather than deciding it for you.
2. For each, append **exactly one** of:
   - `> [agree:<ns-id>]` + `> — via <primary-model-id>` — accept it, and address it in the doc
     body (or, for a PR, note it — the diff is read-only), or
   - `> [dispute:<ns-id>] <one-line reason>` + `> — via <primary-model-id>` — reject it, tersely.

   **Adjudicate, do not rubber-stamp.** Every `agree` obliges an edit, every edit is fresh
   unreviewed text, and that is the engine that drives extra rounds — so a lenient primary is
   expensive as well as uncritical. **Dispute** a finding when any of these holds:
   - **No demonstrated failure mode.** It says something *could* break without a mechanism or a
     case that reaches it. (A stated mechanism is enough; a pasted reproduction is not required.)
   - **Out of scope.** It is about the PR description, the commit message, or code the change
     does not touch, rather than the diff.
   - **Speculative hardening.** It guards a case that cannot occur — the same bar §1.2 of this
     repo's working agreement sets for the code itself.
   - **Already answered.** It restates a finding this review has responded to.

   Disputing is cheap and correct: convergence is **coverage, not consensus**, so a dispute never
   blocks and the human gate settles it. State the reason in one line so the gate can overrule you.

   Equally, do not dispute to save a round. A finding you cannot refute on the merits is one you
   `agree` with, even when it is inconvenient — the point of the review is the findings you did
   not expect. If you are unsure, agree and fix; being wrong in that direction is cheaper.

   Caution: `<primary-model-id>` must differ from every secondary's disclosed `> — via` model id
   — the self-response guard fails a response whose model equals the finding's raiser model, so
   colliding with a Claude-family secondary like `fable` would make convergence impossible.
3. **Optionally** record a primary observation the secondaries all missed:
   `> [observation] <text>` + `> — via <primary-model-id>`. It is human-gate-only — never a
   finding, never counted toward convergence — so a missing `> — via` line is a contract error.
4. Decide: **converge**, or re-enter `awaiting-secondaries` for another round.

   First run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh round-stats "<doc>"`. It prints
   the per-round × per-provider counts, the trend, any dry streaks, and a `verdict:` line.

   **ONE ROUND IS THE DEFAULT. Converge after round 1 unless a listed trigger fires.**

   Measured over four self-reviews (issue #29): round 1 produced 38% of all findings and every
   serious one; rounds 2+ produced the other 62%, almost entirely about patches the primary wrote
   *during* the review — obtained by re-reading the whole diff each time. Re-fanning is therefore
   opt-in, not the standing behaviour.

   **Re-fan only if at least one of these is true:**
   - you agreed to a **`high`**-severity finding and your fix was non-trivial — the fix is now the
     least-reviewed code in the change, and highs are where the real defects were;
   - your between-round edits introduced **new logic** (not wording, not a comment, not a test
     name) that no reviewer has seen;
   - the engineer asked for depth on this review.

   Otherwise converge, even when the round found plenty. "It found things" is not a reason to go
   again — round 1 finding a lot is the system working, not evidence that round 2 will.

   When you do re-fan, `round-stats`' `verdict:` line still bounds it: stop as soon as a round
   goes dry, the rate stops falling, or the ceiling is hit. Run it **after the merge**, in this
   turn — it refuses to render a verdict while a round is in flight, because an unmerged round has
   no findings in the doc yet and would read as dry.

   A `↑ rising` round stops the loop for a different reason than a plateau: the new findings are
   most likely about the edits you just made, not the original doc. Say so at the gate rather than
   presenting it as saturation.

   Whatever the reason for stopping, **say plainly at the gate that your last round of fixes is
   unreviewed.** That is true of every terminal state and is exactly what the human gate is for.

   A `dry-streak:` line is **advisory only**. Never drop a secondary from the set on your own:
   a saturated reviewer can still catch something in newly written text. Surface the streak at
   the gate and let the engineer decide.

   Edit the marker directly:
   - **Converge** → state word only: `awaiting-primary` → `converged` (same round number).
   - **Another round** → `awaiting-primary · round <N>/<MAX>` → `awaiting-secondaries · round
     <N+1>/<MAX>`, then return to "Fan-out".

### Terminal gate

Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh check-converged "<doc>"`.

- **Fail** → the marker says `converged` but the contract doesn't hold (a hand-edit broke
  coverage, or tampered with a quarantine record) — pause, surface the inconsistency, and STOP.
  Do not clean up the working files; they are what a human needs to diagnose the mismatch.
- **Pass** → present
  `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh gate-summary "<doc>" "<primary-model-id>" --flag-independence`
  to the engineer (the `--flag-independence` line warns when no admitted secondary was
  cross-vendor with you — silence means a cross-vendor perspective was present). Then:
  - **Local doc** → tell the engineer "converged — please review and approve before
    implementation or PR." STOP.
  - **PR flavor** → tell the engineer it converged and ask whether to post. Only on explicit
    approval, run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh publish "<doc>" "<primary-model-id>"`
    (one neutral `gh pr review --comment`; agreed findings with a `> — at <path>:<line>` anchor
    post inline, the rest in the summary; it reads the PR url from the scratch header). STOP.

  This is the **human gate**: never implement, commit, or open/merge a PR from this command. Only
  once the engineer confirms the review is done, remove the retained working files
  (`<doc>.<id>` for every provider, `<doc>.manifest`, `<doc>.baseline`) — never before the gate,
  since the gate is presented FROM them (`check-converged`/`gate-summary` read the manifest).

## Guardrails

- Turn-taking is the marker only — never act on "new text appeared" while a working copy says
  `awaiting-reviewer`.
- Star is **synchronous**: the primary IS this command, so there is no watcher and no second
  review session — the fan-out uses its own bounded wait (`multi-review-wait.sh`) per copy, and a
  secondary that can't be dispatched or times out is quarantined so the round proceeds on the
  rest (`fable` guarantees at least one admissible secondary).
- If the marker is missing/corrupt, or a working copy changed while it said `awaiting-reviewer`
  in a way the wait/verify flow can't reconcile, pause and surface — do not race-edit.
- **Doc↔manifest consistency is self-checked.** `merge` verifies the doc against its `.manifest`
  both before merging (it refuses to build on an already-inconsistent doc) and after writing —
  so a dropped/duplicated round, a finding split from its `> —` lines, or a mangled footer fails
  loud at the handoff instead of accumulating silently to the gate. If a `merge` aborts with a
  consistency error, **stop and diagnose** with `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh
  verify "<doc>"` — do not re-merge until it passes. After appending your primary
  `[agree]`/`[dispute]` responses each round, you may run `verify` yourself to catch an
  append that split a finding block before the next fan-out.
- Disclosure warnings on stderr are non-blocking; surface them at the gate but keep going.
- The human gate is inviolable and terminal for this command.
