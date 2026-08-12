---
description: Multi-review — a star review (you as primary + N independent secondaries) over a spec/plan doc or a PR, converging to a human gate.
argument-hint: "[doc-path | PR-URL] [--reviewers <csv>]"
---

You are the **primary** in a multi-review star review: you dispatch N independent secondaries,
adjudicate their findings, and drive convergence — always stopping at a **human gate**. `fable`
is one of the secondaries by default (your guaranteed in-harness review voice) and any
`--reviewers` you name are added to it — unless the operator set `MULTI_REVIEW_FABLE=off`, which
suppresses that floor; see §2. Drive the review with the repo's shell helpers; you own prose edits
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
| revoke while `MULTI_REVIEW_FABLE=off` | revoke | *(empty)* → refusal | `remember-set --clear`, then STOP on exit 3 |
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
- **Exit 0** → it printed `owner|repo|number` (owner/repo empty for the bare-number forms:
  `#123`, `123`, `PR 123`, `pr#123`). This
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
- Else, run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh resolve-doc`. It lists `.md`
  files **directly under** each dir in `MULTI_REVIEW_DOC_DIRS` (default `docs/specs docs/plans
  docs/superpowers/specs docs/superpowers/plans`) whose names match `YYYY-MM-DD-…` and prints
  the greatest by **date prefix, then filename** (NOT mtime).
  - **Exit 0** → that path is the doc. **Relay any `WARNING —`/`note —` it printed on stderr.**
    A `WARNING` means a NEWER dated doc sits in a directory that was not searched: the pick is
    legitimate but probably not what the engineer meant, and the egress guard cannot catch it
    because the chosen doc IS inside the configured dirs. Say so before arming, and offer the
    named alternative.
  - **Non-zero** → zero candidates, or the top two share a date prefix (a tie). Show the
    message — it names the dirs searched and any sibling holding dated docs — and ask for an
    explicit path. Do NOT guess.

## 2. Resolve the reviewer set (`fable` included unless `MULTI_REVIEW_FABLE=off`)

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
   prose). Precedence is flag/prose → `MULTI_REVIEW_REVIEWERS` → the pref → the fable floor
   (suppressed when `MULTI_REVIEW_FABLE=off`, in which case an otherwise-empty set is a refusal,
   not a fallback); the pref is consulted **only** when neither a named set nor the env supplied
   one.
   - **One-off exception (§1, fable-rd1-r1):** when the §1 intent is a **one-off override**, OMIT
     `--pref-file` from this call, so the remembered combo does not leak into a run the user scoped
     to just this once (this is required for "just fable this once" to actually resolve fable-only —
     an empty `--reviewers` alone would fall through to the pref).
   - **Exit 0** → the resolved set, one `id|vendor|kind|model|has-skill` row per line. These are
     the secondaries for the whole run. `fable` is present via the `--fable-floor` union unless
     the operator set `MULTI_REVIEW_FABLE=off`, in which case it appears only when a source
     NAMED it.
   - **Exit 3** → no secondaries are available at all (the switch is off and nothing else is
     usable). `resolve-set` has already printed a per-provider diagnosis naming both the
     providers that are unusable and any that are ready but simply were not selected. **Relay it
     and STOP — arm nothing.** A star review with no independent secondary is not a cheaper
     review; do not proceed as a primary-only self-review.
   - **Exit 2 naming `MULTI_REVIEW_FABLE`** → the operator's env value is not a recognised
     on/off spelling. Relay it and STOP.
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

- **Capture the session root FIRST — before the egress guard below, and before anything else in
  this command changes directory.** In your original invocation directory run
  `git rev-parse --show-toplevel` once and keep the result as `<session-root>`. If it is empty
  (your cwd is not a git repo), say so and STOP rather than passing an empty value.

  This bullet is first because the ORDER is the whole point. The egress guard resolves
  `MULTI_REVIEW_DOC_DIRS` relative to the current directory, so on a cross-repo doc it refuses
  until you move into the repo that owns the doc — and once you have moved, the original
  directory is gone and `git rev-parse` returns the doc's repo instead. Capturing afterwards
  yields exactly the wrong value, silently, which is the bug `--session-root` exists to fix
  (issue #66). Everything downstream that says `<session-root>` means the value captured HERE.

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
    `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh check --reviewer <id> --doc "<doc>"
    --session-root "<session-root>"` and surface any
    `hint (<id>): …` line it prints on stderr in the armed message (e.g. "gemini: workspace may be
    untrusted — export GEMINI_CLI_TRUST_WORKSPACE=true"). This is **advisory** — `check` exits 0 and
    the secondary is still dispatched; the hint just puts the likely fix in front of the engineer
    *before* a misconfigured reviewer would otherwise fail mid-review and quarantine. Never a gate,
    never blocks dispatch. (Run `/multi-review --check-reviewers` for the full doctor report.)
    One of these fires when the working copy is outside the reviewer's sandbox root (issue #60) —
    the case that otherwise surfaces only as a wait-bound timeout ~20 minutes later, with a
    quarantine reason that describes the symptom. It is still advisory: dispatch proceeds, and you
    decide whether to move the review. `--doc` is what enables it, which is why the standalone
    `--check-reviewers` doctor (no doc in hand) does not report it.

    **`<session-root>` is the value you captured above — the same one you pass to `ensure-skill
    --repo`. Substitute the captured value; do NOT inline `$(git rev-parse --show-toplevel)` into
    the `check` line.** A command substitution there re-resolves in whatever directory you are
    standing in at that moment, and the egress guard pushes you into the repo that owns the doc —
    which is exactly where it returns that repo, the basis collapses onto the doc's own root, and
    the hint goes silent. That is the bug this flag exists to fix, reintroduced by the way the
    command is written.

    Why it must be the session root at all: it is the cwd a dispatched subagent inherits, and
    therefore the root the reviewer is actually bound to. Without the flag the check falls back to
    asking the codex companion, whose answer follows the shell in the same way (issue #66). Passing
    the captured session root is what makes a silent check mean "the reviewer can reach this copy"
    rather than "you happen to be standing next to it".

    An **empty** value is rejected with exit 2 rather than ignored — an ignored empty value would
    silently restore the wrong basis, and a failed capture is the one place an empty value comes
    from. That is why the capture step above tells you to stop instead of passing it on.

    **Both external arms consume `--session-root`.** codex is bound to one root per session;
    gemini's workspace is the cwd of the process at LAUNCH, and the shell branch below pins that
    to the same `<session-root>`. So for either provider a silent `check` now means "the reviewer
    can reach this copy", not merely "you happen to be standing next to it".

    That was not always true of gemini: the check judged against its own cwd repo, on the
    reasoning that gemini "runs as a shell command in the CURRENT cwd". The premise holds only if
    check and dispatch stand in the same place, and nothing enforced that — so the arm was wrong
    in BOTH directions, missing a copy outside the dispatch root and falsely hinting on one
    inside it (fable-rd2-r2, under #66). `fable` needs no basis: it runs in-harness with no
    workspace of its own.
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
   everything after the doc's LAST `## Review` heading **that is not inside a fenced code block**
   — keep the heading line, drop everything after it (any prior round's merged
   findings/responses). A doc whose merged findings quote a fenced `## Review` would otherwise
   move the truncation point and carry a previous round's findings into the baseline. `<doc>`
   itself is untouched.

   Then copy `<doc>.baseline` to `<doc>.baseline.rd<N>` for this round and **retain it** — round
   N+1 diffs against it. `<doc>.baseline` keeps its current meaning (the snapshot `verify-vendor`
   diffs against for the CURRENT round), so that guard is unaffected.
2. **Seed one copy per provider**, using the SAME resolved set from §2 — a later round does not
   shrink the set, even for a provider quarantined earlier; it gets a fresh independent copy
   again.

   - **Round 1** — `cp "<doc>.baseline" "<doc>.<id>"`, then rewrite that copy's header as below.
   - **Round N ≥ 2, local doc** — build a **diff-scoped** copy instead, so the round costs what
     you changed rather than the size of the document:

         "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-scope.sh" local-copy \
           --round <N> --max <MAX> \
           --prev "<doc>.baseline.rd<N-1>" --curr "<doc>.baseline.rd<N>" > "<doc>.<id>"

   - **Round N ≥ 2, PR flavor** — the primary never edits a PR diff, so the reviewable delta is
     what the *author* pushed since the last round. **Before** seeding the copies, refresh the
     scratch once for this round:

         "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh" refresh "<doc>" <N>

     `refresh` re-fetches the diff at the current head, records this round's head/merge-base,
     captures existing anchors' line text, and replaces `## Diff` while preserving `## Review`
     and the manifest.

     **If `refresh` fails with a diff-window message** (`no '## Diff' section … matches a recorded
     digest`, or `… ambiguous diff window`), it wrote NOTHING — that is deliberate. The diff window
     is verified against a digest the writer recorded in the sidecar, so an unverifiable window
     means the scratch or its `.records` sidecar was edited or lost. Do **not** hand-splice the
     diff to work around it: report the message and STOP, because writing blind is what silently
     destroyed the description and the previous round's diff before this check existed. The
     recoverable path is a fresh `ingest --fresh` (losing accumulated findings) at the engineer's
     choice.

     **Choosing `--fresh` also means clearing the PREVIOUS review's protocol artifacts** —
     `<scratch>.manifest`, `<scratch>.baseline`, and every `<scratch>.<id>` copy. `ingest` resets
     its own sidecar (`<scratch>.records`), but the manifest belongs to this protocol layer, and a
     manifest left behind from an earlier review **blocks every future merge on that path**:
     `merge` refuses to build on a doc inconsistent with its manifest, so the new review cannot
     proceed until the stale file is removed by hand. Observed live while reviewing PR #40, whose
     earlier review had been abandoned without releasing its files at the gate. This applies to
     **completed** reviews too, not just abandoned ones — the terminal gate deliberately keeps the
     manifest (issue #57), so `--fresh` is the step that clears it.

     Then read both rounds' records and build each copy:

         "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh" head-record "<doc>" <N-1>   # -> head|merge-base
         "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh" head-record "<doc>" <N>
         "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-scope.sh" pr-copy \
           --round <N> --max <MAX> \
           --since <head-rd(N-1)>  --merge-base-prev <mb-rd(N-1)> \
           --head  <head-rdN>      --merge-base      <mb-rdN> \
           "$(git rev-parse --show-toplevel)" > "<doc>.<id>"

     Exit 3 here is common and expected — a rebase, a force-push, a forward merge of the base
     branch, or an unchanged head all trip it. Fall back exactly as below and relay the reason.

     The copy carries the delta with **function context** (`git diff -W -U10`) and **no whole-file
     text**: hunks extend to their enclosing function, which is where the invariant a fix depends
     on actually lives. Emitting each touched file in full was the original rule and cost 48–412%
     of the round it replaced, because that scales with the size of the files touched rather than
     with the size of the change.

     Either way, `local-copy`/`pr-copy` writes the whole copy, header and marker included — do
     NOT also rewrite the header on this path.

     **Exit 3 is not a failure**: the round cannot be scoped — no retained prior baseline, an
     empty delta, a PR whose history moved (rebase, force-push, forward merge, unresolvable head),
     or **the scoped copy came out no smaller than the full artifact it would replace**, in which
     case the notice names both byte counts. Fall back to `cp "<doc>.baseline" "<doc>.<id>"` plus
     the header rewrite, and **relay the reason it printed** in the round's message — a degraded
     round is never silent. Any other non-zero exit is a real error: stop and surface it.

     An **empty delta** also means nothing changed since the last round, which is a converge
     signal — prefer converging over re-fanning. The decision stays yours; #30's triggers govern
     *whether* to re-fan, and this step governs only what a re-fan costs.

   For the round-1 path (and the exit-3 fallback), rewrite that copy's header to:

        <!-- multi-review: awaiting-reviewer · round <N>/<MAX> -->
        <!-- multi-review-mode: star -->

   (`<N>` is the round this fan-out is running; no `reviewers:` suffix on a working copy.) The
   copy carries the empty `## Review` heading from step 1; the secondary appends findings beneath.

   **Now — with the header final on every path, scoped or not — snapshot each copy as
   dispatched:** `cp "<doc>.<id>" "<doc>.<id>.seed"`. Step 6's `channel-check` diffs against this.
   It is the only faithful record of what the reviewer was handed; for a scoped round
   `<doc>.baseline` is NOT it, and `channel-check` refuses `--baseline` for that reason. Do this
   AFTER the header rewrite — a pre-rewrite snapshot differs from the dispatched copy. Retain it
   with the other working files; the terminal gate releases it.

   **And clear the previous round's dispatch log, here, in the same synchronous step:**
   `rm -f "<doc>.<id>.multi-review.log"`. This is the only place it can be done safely. The
   `shell` dispatch runs as a background task, so a removal written inside it races your own
   pre-wait read of the same file — and a lost race means round N-1's status line quarantines a
   reviewer that launched seconds ago. Removing it before you dispatch anything cannot race.

   **Then prove the copy is BLIND, before dispatching it** (issue #39):
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh blind-check "<doc>.<id>"`.
   **Exit 1** — the copy still carries a previous round's findings, your responses, or a
   carried-over `[no-findings]` signal. Do NOT dispatch it: the secondary would read what
   everyone else already said, and independence is the whole point of the star. Re-seed from
   the baseline (truncating after the LAST `## Review` outside any fence) and re-run the check.
   **Exit 2** — a usage error on your side; fix the path.
   Seeding is the one step you perform by hand, so it is the one step with no other check on it:
   get the truncation wrong and nothing downstream notices — `merge` accepts the copy, `verify`
   passes, `check-converged` passes, and the gate reports N *independent* secondaries.
3. **Provision each secondary's skill, right before dispatch.** The working root is
   **`<session-root>` — the value you captured in Arm**, and **never** `<doc>`'s own location: for
   a PR-flavor doc, `<doc>` is a scratch file under `.multi-review/reviews/` and is not the repo
   it describes. For each id, run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh ensure-skill --reviewer <id>
   --repo "<session-root>"` — a no-op for skill-less reviewers.

   **Substitute the captured value; do NOT inline `$(git rev-parse --show-toplevel)` here** — the
   same rule Arm states for `check --session-root`, and for the same reason. By this point the
   egress guard has pushed you into the repo that owns the doc, so a substitution resolves to
   THAT repo while the dispatched subagent inherits the SESSION cwd. In the cross-repo case the
   two differ, the bundle materializes into a repo the reviewer never sees, and the round dies as
   a wait-bound timeout with a reason that describes the symptom (issue #66). Provisioning and
   dispatch must resolve to one root, and `<session-root>` is the one dispatch actually uses.

   Non-zero
   exit → do NOT dispatch that reviewer this round; quarantine it now, using the command's stderr
   as the reason, via the same quarantine path a dispatch failure uses (record `--quarantined
   <id>:<reason>` for the merge below). If every selected reviewer quarantines here, apply the
   existing all-failed anomaly stop (below) before dispatching anyone.
4. **Dispatch every secondary in the same turn**, so the harness runs them concurrently — never
   one after another. Branch on `kind`, pointed at `<doc>.<id>`:
   - **`subagent`** → dispatch the Agent tool, passing the output of
     `multi-review-reviewer.sh prompt "<doc>.<id>" --reviewer <id>` as the task text. The two
     providers are dispatched **differently**, and the difference is not cosmetic:

     - **`fable`** → agent `general-purpose`, with the Agent tool's own `model` parameter set to
       `fable`.
     - **`codex`** → agent `codex:codex-rescue`, with the Agent tool's `model` parameter **left
       unset**, and `--model <model> --write --background` appended to the END of the task text.
       The rescue wrapper parses those three out of the text as runtime controls; they are not
       instructions to the reviewer.

     **Do not put the resolved `model` in the Agent tool's `model` parameter for codex.** That
     parameter takes a fixed set of harness aliases (`sonnet`/`opus`/`haiku`/`fable`), so a codex
     model id like `gpt-5.6-terra` is rejected outright and the dispatch never happens. It works
     for `fable` only because `fable` happens to be one of those aliases.

     Run it in the same working root the reviewer was just provisioned into (step 3) — the two
     must never diverge.

     **If the Agent tool itself errors** — unknown agent type, rejected model — that is an
     ENVIRONMENT failure, not a reviewer outcome. Do not fold it into the quarantine path: it is
     deterministic, so re-dispatching next round fails identically, and quarantining it spends a
     round to discover something already known. Surface it immediately with the remedy (for
     `codex:codex-rescue`, the codex plugin is not installed — see the README's reviewer table)
     and ask the engineer whether to proceed on the remaining set or stop. `check` gates this
     before arming, so reaching it here means the environment changed mid-run.

     **`--background` is not optional for `codex`.** The rescue wrapper forwards to
     `codex-companion.mjs task`, which runs in the FOREGROUND by default; a real review outlives
     the harness's 10-minute foreground window, so the subagent's turn ends and the detached codex
     process is torn down *before it writes any findings*. The failure is silent and expensive:
     the working copy stays byte-identical to its seed, step 5's wait times out, and step 6
     quarantines the provider with no error anywhere — a round that cost a reviewer slot and
     produced nothing, indistinguishable from a reviewer that genuinely found nothing. With
     `--background` the companion returns a managed job id immediately and the job survives the
     caller; step 5's per-copy marker wait is already the correct completion signal, so nothing
     else changes. (Observed live on a PR review: the companion's own job output file was 0 bytes.)
   - **`shell`** → read NUL-delimited argv and execute it without a shell round-trip (macOS bash
     3.2 has no `mapfile`), launched as a background task so it does not block the batch:

            argv=()
            while IFS= read -r -d '' a; do argv+=("$a"); done \
              < <("${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh" command "<doc>.<id>" --reviewer <id>)
            # Guard the empty case BEFORE expanding: on macOS bash 3.2 under `set -u`,
            # "${argv[@]}" on a zero-element array is a fatal unbound-variable error. An empty
            # argv means the command could not be built — treat it as a dispatch failure for
            # this provider (quarantine it) rather than expanding.
            (( ${#argv[@]} )) || echo "DISPATCH-FAILED <id>: could not build reviewer command" >&2
            # PIN THE LAUNCH CWD. gemini-cli's workspace is the cwd of the process at LAUNCH, and
            # it refuses to read or write outside it — so without this `cd` the workspace is
            # whatever directory this Bash call happens to inherit, which is not necessarily the
            # root holding `<doc>.<id>`. Same drift `--session-root` fixes for codex (#66); the
            # subshell keeps it scoped to the dispatch and leaves your own cwd alone.
            # CAPTURE OUTPUT AND STATUS. Nothing else in the round ever hears from this process:
            # a reviewer that dies on launch leaves a copy byte-identical to its seed, which is
            # exactly what a reviewer still thinking leaves. The log is the only thing that can
            # tell those apart. `.multi-review.log` is already a gitignored shape (G3).
            # The previous round's log is already gone — step 2 removed it synchronously, which is
            # the only place that can. Removing it HERE would be inside this background task and
            # could lose the race against your own pre-wait read.
            if (( ${#argv[@]} )); then
              ( cd "<session-root>" && "${argv[@]}" ) >"<doc>.<id>.multi-review.log" 2>&1
              # printf with a LEADING newline, never a bare `echo`: a process that dies mid-write
              # leaves no trailing newline, and `echo` would glue the status onto it
              # (`quota exceededmulti-review: dispatch exited 1`) — unfindable as a line, in
              # exactly the crash this exists to catch. The blank line a clean exit gains is free.
              printf '\nmulti-review: dispatch exited %s\n' "$?" >>"<doc>.<id>.multi-review.log"
            fi

     **`DISPATCH-FAILED <id>` on stderr is yours to act on.** The block only reports it; nothing
     downstream reads it for you. Do not dispatch that reviewer this round and record
     `--quarantined <id>:could not build reviewer command` for the merge — the same path a step-3
     non-zero exit uses. Left unrecorded, the provider is simply absent: step 5 then waits on a
     copy nobody launched and returns exit 9, which you would report as `no turn taken` — the
     reason for a reviewer that declined, not one that was never started.

   All same-turn subagent dispatches go in the SAME response block as each other.
5. **Bound the wait, per copy — and never quarantine on the first bound hit.**

       "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-wait.sh" "<doc>.<id>" awaiting-author \
         [seconds] --seed "<doc>.<id>.seed"

   Pass `--seed` (the snapshot step 2 already took). It is what lets the wait tell a reviewer that
   never took a turn from one that is mid-write — opposite facts that a bare bound hit reports
   identically, and the difference between quarantining a no-op and discarding real findings.

   **For a `shell` reviewer, read `<doc>.<id>.multi-review.log` — before the first wait, and again
   at every bound hit.** Step 2 removed the previous round's log synchronously, so what you read is
   this round's. The dispatch appends `multi-review: dispatch exited <rc>` on a line of its own once
   the process is gone. **It counts only when it is the log's FINAL non-empty line.** A match
   anywhere earlier is echoed text, not a status: the log is verbatim CLI output, and in this
   repo's self-reviews the reviewed material contains the sentinel string verbatim. Taking merely
   the last match is not enough — while the reviewer is still alive the real status does not exist
   yet, so an echoed one would be the last match and a live reviewer would read as exited. The
   dispatch writes the real status after the process ends, so being last is exactly what makes it
   real.

   The status answers exactly one question — *has the process exited?* What to DO is decided by the
   copy, in this order:

   - **Marker says `awaiting-author`** → the turn completed. Verify it normally (step 6) whatever
     the status says, and never quarantine. A CLI can write its turn, flip the marker, and only then
     die — on teardown, or on a post-edit call that exhausts a quota. Quarantining on the status
     would discard a completed turn and every finding in it, which is a strictly worse failure than
     the one this log was added to fix. The marker is the handoff; the status is evidence about the
     process, not about the turn.
   - **No status line yet** → the process is still running. The bound-hit rules below apply exactly
     as written. Note the residual honestly: the status appears asynchronously, so a process that
     dies just after you looked is not noticed until the next bound hit. That costs **one** bound,
     against the four this mechanism removes — the accepted price of reading the log rather than
     watching it. Closing it means teaching the wait itself to watch, which is a change to
     `multi-review-wait.sh`, not to this instruction.
   - **Status present, marker not flipped, copy CHANGED since its seed** → it wrote something and
     died before the handoff. Do **not** re-wait. The exit-8 retry path exists for a reviewer that
     is "demonstrably alive and still writing", and the status has just disproven that premise, so
     re-waiting spends up to three more bounds on a process that can never flip anything. Run step
     6's `channel-check` against the seed on what it *did* write: admit the turn if the findings are
     readable, and only otherwise quarantine, with `died mid-turn after writing; see
     <doc>.<id>.multi-review.log`. Partial findings are worth more than a discarded round. Note
     that neither `channel-check` nor `merge` requires the copy's marker to have been flipped —
     both accept an unflipped copy — so this recovery is runnable exactly when it is needed.
   - **Status present, marker not flipped, copy byte-identical to its seed** → nothing was written.
     Quarantine with `dispatch exited <rc>; see <doc>.<id>.multi-review.log`.

     **Name the file; do not paste its text into the reason.** Quarantine reasons are recorded
     durably in the doc and rendered at the gate, while the log is gitignored and local — and the
     failure most likely to be sitting on that last line is an authentication error, which is the
     line most likely to carry a credential. Copying it out would move the one thing the log's
     containment argument rests on into the one place the protocol publishes. Read the log
     yourself and say what happened in your own words if the gate needs it.

   - **Exit 0** → verify below.
   - **Exit 8** — the copy CHANGED since dispatch but the marker is not flipped. The reviewer is
     demonstrably alive and still writing, so do NOT quarantine on the first 8: that throws away a
     turn that is actively being written. **Re-run the same wait, at most 3 more times.** If the
     4th wait still returns 8, quarantine with the reason **`still writing at the retry cap`** —
     distinct from `no turn taken`, because the two describe opposite states and the gate renders
     reasons as free text.

     The cap is a number rather than your judgement because this command is **autonomous by
     default**: a primary running with nobody watching has no patience to run out, and a copy that changes on every
     poll would otherwise return 8 forever, so the round would never reach verification or a
     deliberate quarantine (codex-rd1-r1 on PR #78). Four waits at the 600s default is ~40 minutes
     for one provider, which is already generous for a reviewer that has not managed to flip a
     marker.
   - **Exit 9** — the copy is byte-identical to its seed: no turn taken *yet*. Re-run the wait
     **once** as grace before recording anything. A reviewer 82 seconds past the bound is not a
     reviewer that failed (issue #71: a bound-hit copy completed with 11 findings, one `high`).
     If the second wait also returns 9, quarantine with the reason **`no turn taken`** — the one
     state that proves the reviewer contributed nothing, as opposed to finishing late.
   - **Exit 10** — a terminal state preempted the wait. Stop and surface it; this is not a
     quarantine.
   - **Exit 2** — a usage error on your side (bad path, missing seed). Fix the invocation.
     **Never quarantine a reviewer for an exit 2.**

   The default bound is 600s, chosen to cover the floor reviewer's measured 60–622s range. Raise
   it for a known-slow provider; lowering it below that range quarantines `fable` on latency
   alone, and in a default (fable-only) run that empties the admitted set and trips the
   all-quarantined anomaly stop — the review dies without a single reviewer having failed.

   Use the two reasons **verbatim** when you do quarantine here — `no turn taken` for exit 9, and
   the wait's own message for anything else. `gate-summary` renders quarantine reasons as free
   text, so two different failures worded two different ways read alike to whoever reads the gate.

   A hung secondary must never stall the others or the round: these waits are per-copy and a
   provider that keeps returning 8 past your patience is still yours to quarantine, deliberately.
6. **Verify identity, per copy that reached `awaiting-author`.**
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh verify-vendor --baseline
   "<doc>.baseline" "<doc>.<id>" --reviewer <id>`. Pass → admit the copy into the merge. Fail →
   quarantine: exclude it and record `--quarantined <id>:<reason>` (the reason is
   `verify-vendor`'s message, or "no response within the wait bound" from step 5).

   **Then check the findings actually reached the channel** (issue #32):
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh channel-check --seed "<doc>.<id>.seed"
   "<doc>.<id>"`. **`--seed` is the copy AS DISPATCHED, not `<doc>.baseline`** — from round 2 a
   copy may be a scoped reduction, and differencing that against the full baseline lets absent
   lines absorb misplaced findings, which would miss the very incident #32 came from.
   **Exit 1** — NONE of that reviewer's findings reached what `merge` ingests → **quarantine that
   provider** with the message as the reason. This covers two shapes: findings captured by an
   earlier or fenced `## Review`, and (issue #42) a copy whose **heading structure changed** —
   a reviewer that reformats, e.g. indenting every appended line so `## Review` loses line-start,
   produces no recognisable findings at all and would otherwise score as a clean empty turn.
   **Exit 1, contradiction** — the copy claims `[no-findings]` while also adding findings. The
   turn is self-contradictory: `merge` would ingest the findings while the signal tells the gate
   the turn was clean. Quarantine that provider with the message as the reason.
   **Exit 1, non-response** — the copy adds no findings AND no `> [no-findings]` signal. The
   secondary flipped the marker without contributing anything the protocol can read, which is
   what a turn that never read the document looks like. Quarantine that provider. If a re-dispatch
   is cheap, prefer re-running that secondary once with explicit formatting guidance first — a copy
   that indented only its own appended lines reaches this same exit and is indistinguishable from
   one that never read the document. If this empties the admitted set, the existing
   all-quarantined anomaly stop applies: surface every reason and STOP.
   **Exit 0 with a `note —` line on stderr** — some findings landed and some did not (usually a
   quoted example inside a fence). The turn is admitted; relay the note at the gate.
   **Exit 2** — a usage/infra error on YOUR side (bad path, missing value). Fix the invocation.
   **Never quarantine a reviewer for an exit 2.** `merge` reads only the text after the LAST `## Review`, so a reviewer that
   appended under an earlier one — a `## Review` inside a fenced example, which any doc about
   this protocol legitimately contains — has its **entire turn silently discarded**: nothing else
   catches it, and `gate-summary` then shows that provider as admitted with zero findings,
   indistinguishable from one that genuinely found nothing. If a re-dispatch is cheap, prefer re-running that
   secondary with an explicit instruction to append under the LAST `## Review`, outside any
   fence — the findings are usually real and merely misplaced.
   - **All secondaries quarantined** (including `fable`) → an **anomaly stop**: do not advance the
     marker; surface every quarantine reason and STOP. A round with zero trustworthy findings
     cannot merge. (With the fable floor on, `fable` runs in-harness and should be admissible, so this
     should not occur.)
7. **Merge.** `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh merge --round <N> [--quarantined
   <id>:<reason> ...] "<doc>" <admitted copies...>`.
8. **Flip the marker.** Edit `<doc>`'s marker from `awaiting-secondaries` to `awaiting-primary`,
   same round number — your final edit of this step. Retain `<doc>.<id>` for every provider,
   `<doc>.<id>.seed` for every provider, `<doc>.baseline`, and every `<doc>.baseline.rd<N>` — the
   terminal gate releases them. `<doc>.manifest` is retained too, but the gate does **not** release
   it (see "Terminal gate").

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

   **Check your own model id BEFORE writing the first response** — this is a gate, not a caution:

       ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh check-primary-id "<doc>" "<primary-model-id>"

   - **Exit 0** → your id is distinct from every raiser's; proceed.
   - **Exit 3** → it collides. Do NOT write a response under it. Disclose a distinguishing id
     (the message suggests one) and use that for every response in this review.

   The self-response guard fails a response whose model equals the finding's raiser model, and it
   is **parse-fatal by design** — but it fires only once the colliding response is already in the
   doc. `_table` underlies `_structural_consistency`, so from that moment merge's pre-check,
   `verify`, `gate-summary`, `round-stats` and `compose-review` all fail too, and the review is
   stuck in both directions: you cannot respond without tripping the guard, and cannot converge
   without responding. Recovery means hand-editing the doc or disclosing a false id.

   This is not operator error waiting to happen — it is a supported configuration. `fable` is a
   selectable session model, so a fable-powered primary discloses exactly the string its floor
   secondary does. One command up front costs a line of output; the collision costs the review.
3. **Optionally** record a primary observation the secondaries all missed:
   `> [observation] <text>` + `> — via <primary-model-id>`. It is never a finding and never
   counted toward convergence — but in PR mode it IS published with the review (issue #63),
   naming the model that raised it, so a defect you found yourself reaches the author. A
   missing `> — via` line is a contract error, and now a publishing one: `compose-review`
   refuses to compose without it.
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
  (`<doc>.<id>` and `<doc>.<id>.seed` for every provider, `<doc>.baseline`, and every
  `<doc>.baseline.rd<N>`) — never before the gate,
  since the gate is presented FROM them (`check-converged`/`gate-summary` read the manifest).

  **Keep `<doc>.manifest`.** It is the one retained file that is not regenerable, and it is tiny
  next to the copies/seeds/baselines this step releases — so releasing them without it gets the
  cleanup benefit at no risk. Deleting it broke the most natural follow-up workflow (issue #57):
  when the author pushes a fix and you resume this same scratch for round N+1 — rather than
  `ingest --fresh`, which would discard round 1's findings and your responses, the very things you
  need in order to judge the follow-up — `merge` has nothing to verify the earlier rounds against.
  It now refuses that merge up front rather than corrupting the doc, so a deleted manifest costs
  the review, not just the file.

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
  loud at the handoff instead of accumulating silently to the gate. A **missing** manifest is
  checked too: if the doc carries `<!-- star-findings: -->` footers from an earlier round but the
  manifest is gone, `merge` refuses before touching the doc rather than rebuilding a manifest that
  covers only the current round (issue #57). If a `merge` aborts with a
  consistency error, **stop and diagnose** with `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh
  verify "<doc>"` — do not re-merge until it passes. After appending your primary
  `[agree]`/`[dispute]` responses each round, you may run `verify` yourself to catch an
  append that split a finding block before the next fan-out.
- Disclosure warnings on stderr are non-blocking; surface them at the gate but keep going.
- The human gate is inviolable and terminal for this command.
