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
e.g. `codex,gemini`) in addition to the doc path or PR ref, in any order.
Extract `--reviewers` and `--allow-missing` (consumed in §2). Everything else is `<positional>`
(empty if flags-only, or absent). Classification and doc resolution below use `<positional>` only
— never the raw `$ARGUMENTS` — so a trailing flag can never corrupt PR-ref matching or a doc path.

`--allow-missing` is **flag-only — never inferred from prose.** It *tolerates* a reviewer that
cannot run; it never *subtracts* one that can. "Without gemini" said of a healthy gemini would
still dispatch it, inverting the request, and exclusion phrasing already belongs to the one-off
override lane below.

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
     `multi-review-star.sh resolve-set --fable-floor --resume --reviewers <ids,comma,joined>` to rebuild
     the `id|vendor|kind|model|has-skill` rows. Capture every `multi-review-star: UNDISPATCHABLE
     <id>: <reason>` line this rebuild prints and carry it into every round's `merge` as
     `--quarantined <id>:<reason>`, exactly as step 2's bullet below requires. Go to §3.

     **If the header carries no `reviewers:` suffix, the rebuild exits 2** naming `--reviewers`.
     `--resume` declares the in-flight roster and cannot infer one, and an empty value used to
     drop through to env/pref as a fresh ask — the exit-4 refusal `--resume` exists to prevent
     (fable-rd1-r2, #91). A suffix-less header is legitimate (a doc armed before the suffix
     existed), so resume it by naming the set explicitly: ask the engineer which reviewers this
     review is running with rather than guessing, then pass them.

     `--resume` is required. Without it these header-derived ids look like a fresh ask, so a
     provider that became undispatchable between sessions exits 4 and the review becomes
     permanently unresumable — with a message blaming the engineer for ids they never typed.
   - Exits 1 (no star hint yet — a fresh local doc, or a just-ingested PR scratch) → fall
     through to step 2.
2. **Fresh-request check:** run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh resolve-set --fable-floor --pref-file
   .multi-review/reviewers.pref`, appending `--reviewers <csv>` when §1 extracted a set (flag or
   prose), **and appending `--allow-missing` when §1 extracted that flag.** Without forwarding it
   the documented opt-out does nothing: §1 parses it off the positional, nobody passes it on, and
   the run still exits 4 — the engineer's escape hatch silently absent (codex-rd1-r1). Precedence
   is flag/prose → `MULTI_REVIEW_REVIEWERS` → the pref → the fable floor
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
   - **Exit 4** → at least one reviewer named for THIS run is not dispatchable. The message names
     every one of them and each concrete reason. **Relay it verbatim and STOP — arm nothing.**
     Re-run with `--allow-missing` only if the engineer asks to proceed without them.
   - **Capture every `multi-review-star: UNDISPATCHABLE <id>: <reason>` line**, from any exit code.
     Each one becomes `--quarantined <id>:<reason>` at **every** round's `merge` — not just the
     round that armed. Nothing else records these reviewers, and a resumed session re-derives them
     from a fresh `resolve-set` run rather than from memory it does not have.
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
    fans out to N secondaries). `<ids>` is the resolved set's ids **union every id dropped with an
    `UNDISPATCHABLE` line**, space-joined in resolved order (e.g. `codex fable`). The roster is
    what was ASKED FOR, not what resolved: `gate-summary` computes `admitted = raisers ∪ (roster −
    quarantined)`, so a dropped provider must be in the roster to be subtracted by its quarantine
    record. Omit it and the provider is silently absent instead of visibly quarantined. The
    implicit `fable` floor is in the roster too — a reviewer that raises nothing and is never
    quarantined is counted ONLY by the roster term, so leaving it out re-opens issue #59's
    clean-reviewer undercount. This one insertion covers local and PR docs alike — `pr.sh` ingest
    deliberately writes no mode hint, so there is never a duplicate.
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

   **Lint the document's mutation entries — every round, before seeding any copy** (spec
   2026-09-01 Part B). Fixes add entries, so the entry set changes exactly on the re-fan path, and
   this fan-out is where a stale entry is cheapest to catch — before three reviewers spend a round
   on it (codex-rd2-r1, gemini-rd2-mutation-target-mismatch and fable-rd2-r2 were one such entry).

       ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-planlint.sh check "<doc>" --repo "<session-root>"

   - **Exit 3** → not applicable: the doc ships no `mutate` entries. State it out loud — a lint
     that silently does not run is indistinguishable at the gate from one that ran clean — and
     continue. Step 8 records `not applicable`.
   - **Exit 0** → every entry is consistent. Continue; step 8 records the count.
   - **Exit 1** → the rows name each defect (`target-missing`, `label-missing`, `duplicate-id`,
     `unparsed`). Fix them in the doc body and re-run;
     **do NOT seed or dispatch anyone until it exits 0 or 3.** This is the one blocking step in
     the fan-out, and it blocks only you, only on your own text. `unparsed` is a defect, not a
     skip: an entry the lint cannot read is one it cannot vouch for.
   - **Exit 2** → a usage/infra error on your side. Fix the invocation; stop if you cannot.

   The lint never evaluates the document, and never reads a PR scratch: the `- **PR:** <url>`
   identity line pr.sh writes into the header makes it exit 3 by construction, because the diff is
   the author's read-only change, not shipped code, and the real table is covered there by
   `--verify-table` in CI.

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
     and the manifest. It also re-fetches the PR body and replaces `## PR description`, so the
     description and the diff describe the same revision — from round 2 the two used to drift,
     and secondaries spent findings on the disagreement (issue #85). The description is written
     under the same digest guard as the diff, so one that was hand-edited since it was last
     written no longer matches and is LEFT AS-IS: `refresh` still exits 0 and prints
     `PR description not refreshed` on stderr. Relay that line, and reconcile the description
     against the PR by hand before seeding the copies — do not fan out a description that
     contradicts the diff.

     **That hand reconcile is one-way.** Your edited body matches no recorded digest, nothing
     re-arms the guard, and so
     every later round skips it too — the description is then only as current as your last manual
     pass, and keeping it aligned with the diff stays your job for the rest of the review. Say so
     at the gate. Only `ingest --fresh` re-seeds a recorded description, and it discards every
     accumulated finding and response, so it is rarely the right trade mid-review.

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

     The copy carries the delta with a **bounded context window** (`git diff -U10`) and **no
     whole-file text**. Two earlier rules both failed the same way and are retired: emitting each
     touched file in full cost 48–412% of the round it replaced, and extending each hunk to its
     enclosing function (`-W`) cost 6.32× on a doc-heavy round and 1.50× on a bash-heavy one. Both
     scale with the size of the unit *touched* rather than with the size of the *change*, which is
     the dependency scoping exists to remove. A fixed window does not.

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

   **Derive the crossref worklist here too, but ROUND 1 ONLY** (spec §7): the pass runs once per
   review, against the full document, never on a round N≥2 scoped copy — the pairs it needs to
   compare mostly live in unedited text, which a diff-scoped copy would not contain. This also
   means it costs one dispatch per review, not one per round. **On round N ≥ 2, skip this
   sub-step entirely** — do not run `rows`, do not seed or dispatch `<doc>.crossref`; steps 4, 5,
   7 and 8's crossref clauses below then have nothing to act on this round.

   In round 1:
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-crossref.sh rows "<doc>" > "<doc>.crossref.rows"`.
   It is a mechanical cross-reference sweep over the document's own internal consistency
   (declared `Files:` vs. paths named in its steps, matching pairs shared across sections,
   `Consumes:`/`Produces:` pairing) rather than an independent perspective on the document's
   argument, so **it is not a secondary**: it is excluded from the reviewer roster resolved in
   §2, the secondary count, and the independence warning at the terminal gate — two vendored
   secondaries plus this pass is still exactly two independent perspectives.

   **Exit 3** → not applicable — the doc has no sectioned structure to cross-reference (the
   message names why). **State that out loud** — a pass that silently does not run is
   indistinguishable at the gate from one that ran and found nothing — and do NOT seed or
   dispatch it this round: continue to step 3. **Do not record the durable coverage line here.**
   It is written once, in step 8, alongside this pass's other coverage outcomes — recording it
   here too would duplicate it if this round aborts before step 7 (an anomaly stop, say) and a
   later turn re-runs this fan-out for the same round: step 2 would run again and, if the record
   were written here, append a second identical line.
   **Exit 0** → seed it exactly as a round-1 secondary copy would be: `cp "<doc>.baseline"
   "<doc>.crossref"`, rewrite its header the way above, then snapshot it as `<doc>.crossref.seed`
   the same way. It is now ready to dispatch alongside the secondaries, in step 4.

   **Derive the symcheck worklist here too, ROUND 1 ONLY**, the same way and for the same reason
   the crossref pass is round 1 only: it costs one dispatch per review, not one per round, and a
   round N ≥ 2 scoped copy carries only the edited hunks, not the document's shipped blocks. **On
   round N ≥ 2, skip this sub-step entirely** — steps 4, 5, 7 and 8's symcheck clauses then have
   nothing to act on.

   In round 1:
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-symcheck.sh rows "<doc>" > "<doc>.symcheck.rows"`.
   It checks the document's ready-to-paste code against the repository it targets — the defect
   class reviewer scope structurally cannot see (#89) — rather than offering a perspective on the
   argument, so **the symcheck pass is not a secondary**: like the crossref pass it is excluded
   from the reviewer roster resolved in §2, the secondary count, and the independence warning at
   the terminal gate.

   It runs in-harness as a subagent of YOU, the primary, whose harness already has the repository.
   The sandboxed secondaries are asked for nothing new and their scope discipline is unchanged.

   **Exit 3** → not applicable — the doc ships no ready-to-paste code blocks (the message names
   why). **State that out loud** — a pass that silently does not run is indistinguishable at the
   gate from one that ran and found nothing — and do NOT seed or dispatch it this round. **Do not
   record the durable coverage line here**, for the same duplication reason as above: it is
   written once, in step 8.
   **Exit 0** → seed it exactly as a round-1 secondary copy would be: `cp "<doc>.baseline"
   "<doc>.symcheck"`, rewrite its header the way above, then snapshot it as `<doc>.symcheck.seed`
   the same way. It is now ready to dispatch alongside the secondaries, in step 4.
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
       unset**, and `--model <model> --effort high --write --background` appended to the END of
       the task text. The rescue wrapper parses those four out of the text as runtime controls;
       they are not instructions to the reviewer.

     **`--effort high` is not optional either.** codex defaults to `reasoning effort: none` for
     `gpt-5.6-terra`, and at that effort the turn does not read the document it was pointed at:
     observed across four dispatches, three referenced the review doc in zero commands and the
     fourth ran only `wc -l` on it, each burning a 32-second turn on the skill, the protocol and
     repo source before reporting `[no-findings]`. Three consecutive worthless clean verdicts came
     from that, and a clean verdict from a turn that read nothing looks exactly like a real one at
     the gate. The prompt now demands the read (`READ THAT DOCUMENT IN FULL, FIRST`); the effort
     is what buys the turn enough room to obey it.

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

     **A TRANSIENT harness error is the other case** — the Agent tool dies on an API error whose
     class itself says retry: a 5xx (`529 Overloaded`), a `429` rate limit, a dropped connection.
     Any other 4xx (`401` auth, `400` malformed) is deterministic and belongs to the paragraph
     above — stop and ask. A subagent's turn is many API calls,
     so the death can land before the reviewer opens its copy or halfway through its findings, and
     the tool reports both the same way. **Compare the copy to its seed before doing anything**
     (`cmp "<doc>.<id>" "<doc>.<id>.seed"`):
     - **Pristine** → the copy is still blind. For `codex`, first check whether the tool had
       reported a job id before it died: the companion job survives the rescue subagent (see
       below), so a reported id means the reviewer IS running and the copy is pristine only
       because it has not written yet — do not retry; go to step 5's wait as normal. Otherwise
       nothing about the reviewer is known, so re-dispatch it **once**, on the same copy, in the
       same round. If the retry's tool call dies too, **compare again**: a changed copy takes the
       mid-turn path below; a copy still pristine means the retry ALSO died before
       the reviewer runs — on any harness error, not only the same one — quarantine with the reason
       **`dispatch failed: <error class>`**, naming the retry's error class — e.g. `dispatch
       failed: API 529 Overloaded` — never pasting its text (a request id or a quota message is not
       a reason).
     - **Changed** → the reviewer ran and the harness died mid-turn. Do NOT re-dispatch: a second
       reviewer restarts its ids on a copy that already carries them (a duplicate id is a parse
       error) or writes `[no-findings]` beside real findings (a channel-check contradiction). Take
       step 5's "wrote something and died" path instead: `channel-check` what it wrote, admit the
       turn if the findings are readable, and only otherwise quarantine with `died mid-turn after
       writing`.
     This is NOT `no turn taken`: that reason is reserved for
     a reviewer that ran and wrote nothing, and the two mean opposite things to the author reading
     the published review (issue #124: three 529 deaths in one round were recorded as a reviewer
     that declined). For the two-consecutive-rounds stop rule below, a harness error that recurs
     next round is the same reason — stop paying for it the same way.

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

   **If step 2 derived a crossref worklist (exit 0), dispatch it here too — in this SAME response
   block as the secondary dispatches above, not a later turn.** A `general-purpose` Agent,
   pointed at `<doc>.crossref`, with the task text
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh prompt "<doc>.crossref" --crossref
   "<doc>.crossref.rows"`. Batching it with the secondaries here — not after they are already
   merged — is what makes the pass concurrent rather than an afterthought.

   **If step 2 derived a symcheck worklist (exit 0), dispatch it here too — in this SAME response
   block.** A `general-purpose` Agent, pointed at `<doc>.symcheck`, with the task text
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh prompt "<doc>.symcheck" --symcheck
   "<doc>.symcheck.rows"`. Unlike every other copy dispatched here, this agent MAY read repository
   files — only what resolving a symbol the document's code names requires; the prompt states that
   bound and forbids writes, the network, and environment or secret files.
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
     state that proves the reviewer contributed nothing, as opposed to finishing late. **Only when
     the dispatch itself succeeded:** a copy that is pristine because the Agent tool died before
     the reviewer ran is step 4's transient case, reason `dispatch failed: <error class>`, and this
     wait's exit 9 is merely the expected shape of that — never its reason.
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

   **Wait on the crossref pass here too, if step 4 dispatched it — with the secondaries, not
   after them.** Bound `<doc>.crossref` against `<doc>.crossref.seed` with the same bound and
   retry timing above (up to 3 more waits on exit 8, one grace wait on exit 9). Exit 10 and
   exit 2 mean exactly what they mean above. **Unlike a secondary, this pass has no roster slot
   and is never quarantined** — there is no `--quarantined <id>:<reason>` to feed step 7's merge
   for it. Once its wait budget is exhausted, whatever the final exit code or marker state, move
   on: step 8's `crossref check` judges `<doc>.crossref` on what it actually contains, not on
   whether it finished.

   **Wait on the symcheck pass here too, if step 4 dispatched it — with the secondaries.** Bound
   `<doc>.symcheck` against `<doc>.symcheck.seed` with the same bound and retry timing. It has no
   roster slot and is never quarantined either; once its wait budget is exhausted, move on —
   step 8's `symcheck check` judges the copy on what it contains, not on whether it finished.
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

   **The crossref pass's copy is not verified here.** `<doc>.crossref` is not run through
   `verify-vendor` — it has no vendor, and it is not an independent perspective to authenticate.
   `crossref check`, in step 8, is its verification. Say this explicitly so a later editor does
   not "fix" the omission. It is also not run through `channel-check` above — genuinely
   uncovered, but fail-safe: `channel-check`'s `namespace_blocks` is `review_section`-scoped, so
   an out-of-channel crossref verdict or finding is DROPPED rather than injected, and the
   resulting missing table then trips `crossref check`'s own disclosure guard in step 8, reported
   as `0/M` rather than silently passed.

   **The symcheck pass's copy is not verified here either**, for the same reasons and with the
   same fail-safe: `<doc>.symcheck` has no vendor to authenticate, `symcheck check` in step 8 is
   its verification, and an out-of-channel verdict is dropped rather than injected, which then
   trips `symcheck check`'s own disclosure guard.
7. **Merge.** `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh merge --round <N> [--quarantined
   <id>:<reason> ...] [--pass "<doc>.crossref"] "<doc>" <admitted copies...>`. Pass `--pass
   "<doc>.crossref"` only in round 1, and only when step 2 derived a worklist (exit 0) — omit it
   on the exit-3 not-applicable round and on every round N ≥ 2, when step 2 did not run and there
   is no `<doc>.crossref` from this round to merge. Findings the pass already merged in round 1
   persist in `<doc>` like any other finding; no later round re-merges them.

   Pass `--pass "<doc>.symcheck"` on the same terms and in the same invocation — round 1 only, and
   only when step 2's symcheck derivation exited 0. Both passes may be merged in one round; each
   `--pass` is independent of the other.
8. **Crossref coverage.** The worklist, seed, dispatch and wait for this pass all already
   happened above (steps 2, 4 and 5) — concurrently with the secondaries, so its copy exists in
   time for step 7's merge. This step only checks and records the outcome — in ONE place, after
   merge, so every branch (not-applicable, complete, incomplete) shares one recording point and a
   round that aborts before reaching here (and later re-runs step 2) cannot duplicate it.

   **On round N ≥ 2, skip this step entirely** — step 2 did not run this round, there is nothing
   to check, and the round-1 coverage line already recorded stands.

   **If step 2 exited 3 (not applicable) this round**, under `<doc>`'s `## Review` heading,
   alongside this round's quarantine records (written by step 7's merge, so they exist by now),
   append: `> [crossref-coverage: not applicable]`. Otherwise, run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-crossref.sh check "<doc>" "<doc>.crossref" --rows
   "<doc>.crossref.rows"`.

   **`--rows` is not optional.** It pins the check to the worklist the pass was DISPATCHED with.
   Without it `check` re-derives the rows from the document *as it is now* — and between dispatch
   and here the primary has been agreeing with findings and editing the doc, which is its job. An
   edit that adds a section changes the derived row set, so rows the pass was never given surface
   as missing verdicts and a complete turn reports INCOMPLETE (issue #95). A missing rows file is
   a usage error rather than a silent re-derivation, so a typo here fails loudly instead of
   quietly reintroducing the defect.
      - **Exit 0** → every row was verdicted. Let `<M>` be the worklist's row count (the number
        of lines in `<doc>.crossref.rows` from step 2). Under `<doc>`'s `## Review` heading,
        alongside this round's quarantine records, append:
        `> [crossref-coverage: <M>/<M> rows verdicted]`.
      - **Exit 1** → the turn is not fully trustworthy: a missing verdict, a missing `> [crossref]
        — via <model>` disclosure, a verdict naming a row that was never emitted, or a defect
        naming a finding that is not in the copy — `check`'s own message says which.

        **Do NOT quarantine anything for it.** This pass has no roster slot to quarantine, and
        the rows it DID verdict correctly still count; discarding them to punish the gap would
        destroy real work for a reason unrelated to those rows.

        When the message is `incomplete turn: no verdict for row(s): …`, let `<N>` be `<M>` minus
        the count of row ids it names. For any OTHER exit-1 reason, the verdict table cannot be
        trusted at all, so `<N>` is `0`. Either way, append:
        `> [crossref-coverage: <N>/<M> rows verdicted]`. This branch is never optional: an
        unrecorded exit-1 turn is byte-identical at the gate to a round where this pass was never
        wired up, which is the exact failure this feature exists to close.
      - **Exit 2** → a genuine usage/infra error on YOUR side (a bad path). Fix the invocation;
        this is not a pass outcome and nothing is recorded for it.

   **Symcheck coverage, in this same step and on the same terms.** Round 1 only; skipped entirely
   on round N ≥ 2. If step 2's symcheck derivation exited 3, append
   `> [symcheck-coverage: not applicable]` under `<doc>`'s `## Review` heading, alongside this
   round's quarantine records. Otherwise run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-symcheck.sh check "<doc>" "<doc>.symcheck"`, with
   `<M>` the line count of `<doc>.symcheck.rows`:
      - **Exit 0** → every row was verdicted; append
        `> [symcheck-coverage: <M>/<M> rows verdicted]`.
      - **Exit 1** → the turn is not fully trustworthy — `check`'s own message says which clause
        failed. **Do NOT quarantine anything for it**: this pass has no roster slot, and the rows
        it DID verdict still count. When the message is `incomplete turn: no verdict for row(s):
        …`, let `<N>` be `<M>` minus the count of row ids it names; for any OTHER exit-1 reason
        the table cannot be trusted at all, so `<N>` is `0`. Either way append
        `> [symcheck-coverage: <N>/<M> rows verdicted]`. Never optional: an unrecorded exit-1 turn
        is byte-identical at the gate to a review where this pass was never wired up.
      - **Exit 2** → a usage/infra error on YOUR side. Fix the invocation; nothing is recorded.
   **Plan-lint coverage, in this same step — EVERY round, not round 1 only.** The fan-out's lint ran
   this round (it blocks the fan-out until it exits 0 or 3), so record which. If it exited 3,
   append `> [planlint-coverage: not applicable]` under `<doc>`'s `## Review` heading, alongside
   this round's quarantine records;
   otherwise append `> [planlint-coverage: <M> entries checked]`, with `<M>` the number of rows it
   printed. The line records that the lint RAN — passing is what the blocking step guarantees —
   and `gate-summary` renders it beside the two pass lines, deriving `NO RECORD` from the lint's
   exit code when a round forgot to write it.
9. **Flip the marker.** Edit `<doc>`'s marker from `awaiting-secondaries` to `awaiting-primary`,
   same round number — your final edit of this step. Retain every regenerable working file this
   round's fan-out wrote beside `<doc>` — every `<doc>.<id>` and `<doc>.<id>.seed` (provider or
   pass), `<doc>.baseline`, every `<doc>.baseline.rd<N>`, and every pass's derived worklist
   (`<doc>.<pass>.rows` — `<doc>.crossref.rows`, `<doc>.symcheck.rows`) — the terminal
   gate releases them. `<doc>.manifest` is retained too, but the gate does **not** release it (see
   "Terminal gate").

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

   **A fix about whether a CHECK CAN FAIL must demonstrate the failure, not assert it**
   (issue #47 §1). When the finding concerns a test, a guard, an assertion or a coverage claim,
   "I added a test" is not a fix — "I broke it on purpose and watched that test go red" is. Say
   which, in the response or the doc body.

   A check that cannot fail is *indistinguishable from a passing check by inspection*, which is
   precisely why re-reading keeps missing it. In the session that filed #47 one property test was
   written wrong three times and failed by passing every time; re-reading never caught any of
   them, and a two-minute deliberate break would have caught all three. It is not hypothetical
   here either: reviewing PR #105 the mutation sweep found two of this repo's own assertions
   staying green with the guard removed, and a third that was fully covered while checking the
   wrong property — none of which reading the diff had surfaced.

   The demonstration is cheap and mechanical, and it converts the most expensive recurring failure
   class in a review into a step you either did or did not perform. **Coverage is not the claim
   being made; falsifiability is.** A guard can be provably load-bearing for the cases someone
   wrote and still be checking the wrong thing — so when the finding is about a check, name the
   break you performed and what went red.

   **Every `agree` carries a witness** (spec 2026-09-01 Part A). Immediately after the response's
   `> — via` line, add:

       > — witness: <what goes red if this fix is wrong — name it in backticks>

   Name, in backticks, the thing that does the catching: an entry id, an assertion label, a test
   name, a step's stated RED. Every backticked token must RESOLVE — for a local doc, in the doc
   body outside `## Review` (the entry you added, the label the plan prints); for a PR scratch, in
   an ADDED line of the current `## Diff`, because the author's push is the fix and a witness that
   is not in the push is not a witness for it. A fix with nothing to witness says so:
   `> — witness: none — <why>` — a recorded decision, like `SURVIVES-BY-DESIGN`, counted
   separately at the gate so a review whose agrees are mostly `none` is visible as such. A witness
   is never valid on a `dispute` (nothing changed) and is never parse-fatal when missing:
   `witness-gaps <doc>` lists the gaps, and step 5's `refan-check` refuses to re-fan on one.

   **In PR flavor the witness belongs on the `[resolved:]` record (step 4), not on the `agree`.**
   You never edit the diff, so at agree time the fix is the author's future push and no token can
   sit in the current `## Diff`; an `agree` without a witness is not a gap there, and one that
   carries a witness is still checked.

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
4. **Round N ≥ 2 only — record what the author already fixed.** You have just re-read a
   refreshed diff at a new head. For every finding you agreed with in an EARLIER round that this
   push has fixed, append:

       > [resolved:<ns-id>] <what changed, at which head>
       > — via <primary-model-id>

   Leave the finding's `[agree:]` in place — this is an annotation, not a response, and
   convergence is unaffected. `compose-review` then lists it under **Fixed during review** rather
   than in the open worklist, and `compose-inline` posts no comment on the line.

   **Skipping this is not neutral.** Everything you agreed to in round 1 is still in the doc, and
   without a record the composed review republishes all of it as currently-open — in the run that
   filed issue #88, 10 of 12 round-1 findings had been fixed and the comment still opened with a
   🔴 the author had resolved. To the author that reads as "you fixed nothing", and it costs them
   a pass through items already closed. Nothing else catches it: `verify` passes,
   `check-converged` passes, and the composed body looks well-formed.

   Record only what you **checked in the refreshed diff**. It is a claim a human approves at the
   gate and nothing can verify it mechanically, so `gate-summary` prints it as a primary claim.
   The helpers refuse a record that names an unknown finding, one you disputed or never answered,
   a second record for the same finding, or one disclosed under the raiser's own model id.

   **A resolved record carries a witness too**, on the same `> — witness:` line and terms as an
   `agree` (step 2), resolved by the document's flavor: on a PR scratch the backticked token must
   occur in an ADDED line of this round's `## Diff` — the assertion or entry the push added that
   now covers the fix, present because fan-out step 2's `refresh` re-fetched the diff at the
   author's current head before this round's copies were seeded; on a local doc, in the body
   outside `## Review`. `refan-check` refuses a re-fan
   while any resolved record lacks one, in every round: a record names an earlier-round finding by
   rule, so its own round cannot be read from the id, and it is your claim regardless.

5. Decide: **converge**, or re-enter `awaiting-secondaries` for another round.

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
     name) that no reviewer has seen — **and this trigger has not already been used in this
     review** (see the bound below);
   - the engineer asked for depth on this review.

   Otherwise converge, even when the round found plenty. "It found things" is not a reason to go
   again — round 1 finding a lot is the system working, not evidence that round 2 will.

   **The new-logic trigger fires AT MOST ONCE per review** (issue #106). Read it literally and it
   can never be false: every `agree` obliges an edit, and any edit that is not purely cosmetic is
   new logic no reviewer has seen — so the trigger is satisfied by construction after every
   productive round. It is not a condition, it is a tautology, and the loop it guards has no fixed
   point.

   The bound is *once* rather than *never* because the first round of fixes genuinely is the
   least-reviewed code in the change — that is issue #29's original observation and it still
   holds. The fifth round of fixes to the same predicate is not: by then the review is reviewing
   itself. Measured on a nine-round review of a downstream PR — 32 findings, **zero `high`**,
   and a per-round new-finding rate of 6, 5, 2, 2, 3, 3, 5, 3, 3 — it fell to 2 by round 4 and
   then climbed back to 5, so it never settled and no `verdict:` line ever stopped it. Its own
   round-8 turn records the mechanism: the round-8 delta fixed `fable-rd7-r2` and created
   `codex-rd9-r1` in the same predicate, which had then been wrong in three consecutive rounds.

   **From round 3, re-fan only for a `med` or higher.** A round that agreed to nothing above `low`
   has not found the kind of defect that justifies another fan-out, and `low`-severity churn is
   what a self-reviewing loop produces once it runs out of real material. Replayed against that
   review, this floor first fires at **round 4** — which agreed to nothing at all, both its
   findings refuted — so rounds 5-9 never run: **17 of the 32 findings, and not one `high` lost,
   because there were none.** Five rounds saved, not days: rounds 4 and 9 landed four hours apart.
   What this bound buys back is rounds, not calendar time.

   The `high` trigger is deliberately NOT bounded. A non-trivial fix to a `high` is the one case
   where re-review reliably earns its cost, and a review that keeps surfacing `high`s is not the
   failure mode this bound addresses.

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

   **A BROKEN provider is not a dry one** (issue #47 §4). That rule protects a reviewer that
   *reviewed and found nothing* — silence is a real result and may not repeat next round. It was
   never meant to cover a provider that cannot run at all: a dispatch failure is a different
   signal from silence, and re-dispatching it buys a guaranteed no-op at the price of a wait bound.

   So: **after a provider is quarantined in TWO consecutive rounds for the same reason, stop
   dispatching it for the rest of the review.** Keep it in the roster and keep recording its
   quarantine every round, so `gate-summary` still subtracts it and the gate still shows it was
   asked for and could not answer — the point is to stop paying for it, not to hide it. Say at the
   gate that you stopped, and why.

   Judge "the same reason" by the failure, not the wording: an auth refusal that recurs verbatim
   is the same reason; a timeout followed by a malformed turn is not.

   Measured live: `gemini` quarantined with an identical `dispatch exited 41` — an unreadable
   auth configuration — in **all four rounds across PRs #102 and #105**, and its preflight `check`
   hint had predicted exactly that before the first dispatch. Each round re-dispatched a provider
   already watched failing deterministically, because this instruction only had a rule for dry
   reviewers. The deterministic-failure rule the Agent-tool branch already states — "it is
   deterministic, so re-dispatching next round fails identically, and quarantining it spends a
   round to discover something already known" — is the same reasoning; it simply never covered the
   shell path.

   **Run `verify` BEFORE you touch the marker** — not optional on the re-fan branch:

       ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh verify "<doc>"

   `cmd_resolved`'s earlier-round check reads the round from the marker **at call time**, so a
   `[resolved:]` record written against a CURRENT-round finding is only visible while the marker
   still names the round it was written in. Bump to `<N+1>` first and that same record reads as
   an earlier-round one and passes every later consumer — merge's pre-check, `check-converged`,
   `compose-review`, `gate-summary` — so a premature "fixed" claim publishes as a valid primary
   claim (fable-rd2-r1). Converging catches it (the terminal check runs at the same round
   number); re-fanning is the path that does not, which is why the check belongs here rather
   than after the edit.

   **And `refan-check`, on the re-fan branch, before the same bump:**

       ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh refan-check "<doc>"

   **Exit 1** → a current-round `agree` or a resolved record has no resolving witness; the gaps
   are listed. Add the witness (or `none — <why>`) and re-run;
   **do NOT bump the marker until it exits 0.** It reads the round from the marker at call time
   for the same reason `verify` does: after the bump, every current-round gap reads as an
   earlier-round one and the check passes vacuously. Converging is not blocked by a gap — the gate
   shows the count and the human decides — but the chain this check exists to break runs through
   re-fan.

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
  once the engineer confirms the review is done, release the regenerable working files this
  review created beside `<doc>` — never before the gate, since the gate is presented FROM them
  (`check-converged`/`gate-summary` read the manifest):

      ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh release "<doc>"

  It deletes by an ALLOWLIST derived from the doc's own roster — every `<doc>.<id>`,
  `<doc>.<id>.seed` and `<doc>.<id>.multi-review.log` per provider AND per pass
  (`<doc>.crossref`/`<doc>.crossref.seed` and `<doc>.symcheck`/`<doc>.symcheck.seed` included),
  every pass's derived worklist (`<doc>.<pass>.rows`), `<doc>.baseline` and every
  `<doc>.baseline.rd<N>` — and KEEPS everything else: `<doc>.manifest` and `<doc>.records` by
  name, and any file it does not recognise by default. **Do not hand-roll the deletion.** The
  prose rule this replaced ("every regenerable file") was stated by intent so it would keep
  covering working-file kinds added later; that protected against under-listing and had no
  defence against over-deleting, and `<doc>.records` — the PR sidecar holding the diff digest and
  per-round heads, which nothing can regenerate — was swept with the rest, so the next round's
  `refresh` refused and the only recovery was `ingest --fresh` (issue #112). The helper refuses
  (exit 3) while the marker is not terminal, and exits 2 on a header with no `reviewers:` suffix
  (a doc armed before the suffix existed) — release those by hand, keeping the two files named.
  The one file the allowlist protects that this paragraph has not yet explained is next, by name.

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
  both before merging (it refuses to build on an already-inconsistent doc) and before committing
  the round it has staged — so a dropped/duplicated round, a finding split from its `> —` lines,
  or a mangled footer fails loud at the handoff instead of accumulating silently to the gate. A
  **missing** manifest is checked too: if the doc carries `<!-- star-findings: -->` footers from an
  earlier round but the manifest is gone, `merge` refuses before touching the doc rather than
  rebuilding a manifest that covers only the current round (issue #57).
  **A `merge` that aborts with a consistency error has written nothing** — the second check runs
  against a staged copy, so the doc and its manifest are byte-unchanged (issue #107). Read the
  diagnosis, fix the turn it names, and re-run the SAME round: there is no rollback step, and
  nothing to repair by hand. After appending your primary `[agree]`/`[dispute]` responses each
  round, you may run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh verify "<doc>"` yourself
  to catch an append that split a finding block before the next fan-out.
- Disclosure warnings on stderr are non-blocking; surface them at the gate but keep going.
- The human gate is inviolable and terminal for this command.
