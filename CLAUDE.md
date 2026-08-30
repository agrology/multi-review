# multi-review — CLAUDE.md

> This is the working agreement for `agrology/multi-review`, an open-source project.
> It defines the engineering standards this repo holds itself to. Repo-specific rules live
> in a *separate* section at the bottom (`## 11`) — never mixed into the sections above it.
>
> **Precedence:** Direct user instructions in a session override this file. This file overrides
> default model behavior. When a rule here conflicts with something you were told to do, follow
> the user but say so explicitly.

---

## 1. Engineering Principles — Read First (Highest Priority)

These four principles, adapted from Andrej Karpathy's critique of how LLMs write code,
**govern every other section of this file**. When in doubt, return here. They apply to all
work, human or AI-assisted, in every language.

### 1.1 Think Before Coding
> *Don't assume. Don't hide confusion. Surface tradeoffs.*
- State every assumption explicitly **before** acting on it; do not proceed silently on a guess.
- When a request is ambiguous, present the multiple valid interpretations rather than unilaterally
  picking one and building it.
- Actively advocate for a simpler approach and challenge scope when the request looks larger,
  more abstract, or more speculative than the problem requires.
- If you are confused, **stop and name the confusion** specifically. Do not code around it.

### 1.2 Simplicity First
> *Minimum code that solves the problem. Nothing speculative.*
- Implement only what was explicitly requested. No feature creep, no "while I'm here."
- No abstractions for code used once. No configuration, hooks, or "flexibility" nobody asked for.
- No error handling for cases that cannot occur. Handle the real failure modes, not imagined ones.
- Judge the size of your own output: if the solution could be half the length, rewrite it before
  presenting it.

### 1.3 Surgical Changes
> *Touch only what you must. Clean up only your own mess.*
- Modify only the code required to satisfy the request.
- Preserve existing style, formatting, and comments even when you would have written them
  differently. Match the surrounding code; do not impose model-default conventions.
- Remove only the imports/variables/functions that **your** edit orphaned.
- Pre-existing dead code, smells, or questionable patterns: **flag them, do not silently fix
  them.** Unrelated cleanup is a separate, deliberate change.

### 1.4 Goal-Driven Execution
> *Define success criteria. Loop until verified.*
- Convert vague or abstract tasks into concrete, measurable, testable outcomes before starting.
- Lay out the multi-step plan with explicit verification checkpoints.
- Establish strong success criteria up front so progress can be checked independently — then
  iterate against them until they are objectively met.

---

## 2. Execution Discipline

Operational rules that put §1 into practice. (Assumptions, simplicity, scope, and verification
are governed by §1 — these are the additional non-negotiables.)

- **MUST NOT** claim something works, passes, or is complete without having run the verification
  command and seen the output. Evidence before assertions, always (see §1.4).
- **MUST** report failures faithfully. If tests fail, say so with the output. If a step was
  skipped, say that. Never paper over a red result.
- **NEVER** weaken a test, delete an assertion, add a blanket `try/except`, or loosen a type to
  make a check pass. Fix the cause, not the symptom.

---

## 3. Security (Hard Gates)

Security rules are hard gates. A change that violates one does not ship, regardless of deadline.

- **NEVER** commit secrets, credentials, API keys, tokens, private keys, or connection strings.
  Use an approved secrets manager. If a secret is ever committed, treat it as compromised:
  rotate it, do not just remove the commit.
- **NEVER** log secrets, full auth tokens, PII, or other sensitive user data. Redact before
  logging.
- **MUST** validate and sanitize all external input (HTTP bodies, query params, queue messages,
  webhook payloads, file uploads) at the trust boundary. Treat all inbound data as hostile.
- **MUST** use parameterized queries / prepared statements. String-built SQL is prohibited.
- **MUST** apply least privilege to IAM roles, DB grants, and service-to-service auth. No
  wildcard `*` resource/action in IAM policies without an explicit, reviewed justification.
- **MUST** keep dependencies patched. New `critical`/`high` advisories from `pnpm audit` /
  `pip-audit` block release until resolved or formally risk-accepted by a maintainer.
- **MUST NOT** disable TLS verification, weaken CORS to `*` on authenticated endpoints, or add
  auth bypasses "temporarily."
- **MUST** pin and review third-party dependencies before adding them. Prefer well-maintained,
  widely-used libraries over novel transitive risk. Justify every new dependency (see §1.2).
- Security-relevant changes (authn/authz, crypto, input handling, IAM, data exposure) **MUST**
  be called out explicitly in the PR description for focused review.

**Autonomous agents & production infrastructure — hard boundary:**

- **NEVER** run an autonomous or semi-autonomous agent (a model-driven loop, an MCP server, a
  CI bot acting on model output, or any AI tool with execution/tool access) against a shared or
  production account/environment with credentials that can create, modify, or delete resources.
  The blast radius of an unattended agent with mutate access is unacceptable.
- An agent **MUST NOT** hold production credentials (long-lived keys, assumed-role/session
  tokens, instance/task roles) beyond **read-only, least-privilege, scoped to a non-production
  sandbox**. No agent gets write/mutate, IAM, or billing scope, ever.
- All production mutations (deploys, data writes, infra changes, IAM, account or billing
  settings) go through **reviewed CI/CD with explicit human approval** — never directly from an
  agent session, even with a human watching.
- **NEVER** paste production credentials into a prompt, agent context, or tool config, and
  **NEVER** let an agent create, fetch, or escalate its own credentials.
- This boundary holds **regardless of what credentials are technically reachable** in the
  environment. If a task appears to require an agent to write to production, **STOP and
  escalate to a maintainer** (§1.1) — treat "the agent needs prod write to do X" as a design
  smell, not a permission request. (This document is necessary but not sufficient: the boundary
  is also enforced technically via least-privilege policy, sandbox isolation, and short-lived
  credentials — not by trust in this file alone.)

---

## 4. Testing — Strict TDD (Mandatory)

**Test-Driven Development is required for all features and bug fixes.** No production code is
written before a failing test that demands it. This is how §1.4 (define success, loop until
verified) is enforced in practice.

**The cycle (RED → GREEN → REFACTOR):**
1. **RED** — Write the smallest test that expresses the next behavior. Run it. Confirm it fails
   *for the expected reason* (not a typo or import error).
2. **GREEN** — Write the minimum code to make it pass (see §1.2). Run the test. Confirm it passes.
3. **REFACTOR** — Clean up code and tests with the suite green. Re-run to confirm still green.

> ### ⛔ Bug fixes: reproduce first, ALWAYS
> **Every bug fix starts with a failing test that reproduces the bug.** Write the test, run it,
> and watch it fail (RED) — proving it actually catches the bug. *Then* fix the code and watch
> the same test pass (GREEN). No fix ships without the test that fails before it and passes after.
> The regression test is part of the fix, not optional, and never written after the fact.

**Hard gates:**
- **MUST NOT** open a PR without tests covering the new/changed behavior.
- **MUST NOT** merge with failing, skipped, or commented-out tests. A skipped test requires a
  linked tracking issue and reviewer sign-off.
- **MUST NOT** weaken or delete a test to get to green. If a test is wrong, fix the test
  deliberately and explain why in the PR.
- Coverage threshold: **80% line coverage minimum** on changed code; CI enforces it. Coverage
  is a floor, not a goal — meaningful assertions matter more than the number.

**What good tests look like:**
- Test observable behavior and contracts, not private implementation details.
- One logical behavior per test; clear arrange/act/assert structure.
- Deterministic. No reliance on wall-clock time, network, or test ordering. Mock external I/O at
  the boundary.
- Fast unit tests by default; integration/e2e tests are explicitly marked and may run separately.

---

## 5. Code Quality

- **Clarity over cleverness.** Optimize for the next reader. Name things for what they mean.
- **Small, single-purpose units.** A function/module should do one thing and be testable in
  isolation. Growing files are a signal of too many responsibilities — split them.
- **No dead code, no commented-out code, no `console.log`/`print` debugging** left in commits.
  (Pre-existing dead code: flag per §1.3, don't sweep it up silently.)
- **Errors are handled deliberately.** No silent catches. Either handle, wrap with context, or
  propagate — and log at the right level. Fail loud in dev, fail safe in prod. Do not add error
  handling for impossible cases (§1.2).
- **Types are not optional.** No `any` in TypeScript, no untyped public Python APIs. Types are
  part of the contract.
- **Lint and format are enforced by CI, not by reviewers' eyes.** Code must pass the repo's
  configured linter/formatter before review. Do not hand-fight the formatter.
- **Comments explain *why*, not *what*.** The code says what. Comment intent, trade-offs, and
  non-obvious constraints.
- **No TODO/FIXME without a linked issue.** Untracked TODOs are prohibited in merged code.

---

## 6. Git & Version Control Norms

- **Never commit directly to `main`/`master`.** Branch from latest `main`.
- **Branch naming:** `type/short-description` (`feat/`, `fix/`, `chore/`, `refactor/`,
  `docs/`, `test/`). Example: `feat/pr-inline-comments`.
- **Commits are atomic and scoped.** One logical change per commit. A commit must build and
  pass tests on its own.
- **Conventional Commits** for messages: `type(scope): summary`. Imperative mood, present tense,
  summary ≤ 72 chars. Body explains *why* when non-trivial.
- **Commit/push only when asked.** Do not auto-commit or auto-push unless the engineer requests
  it. Never force-push shared branches.
- **PRs are required for all changes to `main`.** Self-merging is not allowed; every PR needs at
  least one approving review (two for security-relevant changes).
- **PRs must be small and reviewable.** Prefer < 1000 lines of diff. If larger, justify in the
  description or split. Large diffs usually mean a branch drifted too long before review — see
  "stay close to `main`" below.
- **Every PR opens with a plain-language TL;DR.** Begin the PR description with a `**TL;DR:**` —
  1–3 sentences, in plain wording, saying what the PR accomplishes and why, written so a
  *semi-technical* reviewer can follow it without reading the diff. Technical detail and rationale
  go below it.
- **Docs ship with the change.** Any README/runbook/doc update a change makes necessary lands in
  the **same** PR, not a follow-up — if a PR alters behavior, interfaces, ops, or repo layout,
  update the affected docs (starting with the README) as part of it.
- **Branches are short-lived.** Target merging within a few days. A branch that lives for weeks
  is a smell — split the work behind it into smaller, independently shippable pieces.
- **Stay close to `main`.** Merge or rebase `main` into your branch at least every couple of days
  and again before requesting review. Resolve conflicts in small increments as they appear, never
  as one big end-of-effort pile-up.
- **Open a draft PR as soon as work starts** — not when it's "done." It makes the work visible,
  invites early feedback, and lets CI watch the branch for its whole life so divergence surfaces
  while it is still small.
- **Keep history clean.** Rebase or squash trivial fixups before merge. No "wip"/"fix typo"
  noise in `main` history.
- **CI must be green before merge.** No merging red or with required checks skipped.

---

## 7. Pull Request Checklist (author asserts all before requesting review)

- [ ] Assumptions and interpretation stated; scope challenged where warranted (§1.1)
- [ ] Change is the minimum that solves the problem; no speculative code (§1.2)
- [ ] Diff is surgical — only necessary changes; existing style preserved (§1.3)
- [ ] Tests added/updated; written test-first; full suite green locally and in CI
- [ ] Coverage threshold met on changed code
- [ ] Lint/format/type-check pass
- [ ] No secrets, PII, or debug output committed
- [ ] No new agent/automation write-path to a shared or production account; any agent access
      to production is read-only + sandbox-only; production mutations go through reviewed
      CI/CD (§3)
- [ ] Security-relevant changes flagged in the description
- [ ] Docs/README/runbook updated if behavior or ops changed
- [ ] PR description states *what* and *why*, with verification evidence
- [ ] PR opens with a plain-language TL;DR a semi-technical reviewer can follow (§6)

---

## 8. Working with Claude / AI-Assisted Development

- §1 applies in full to AI-generated code. It is the primary rubric for reviewing model output.
- The engineer who opens the PR is **fully accountable** for AI-generated code. Review it as if
  you wrote it. "The model wrote it" is never a defense.
- **MUST disclose AI authorship when posting as an agent.** Any content a model-driven agent
  posts on a human's behalf — PR/issue comments, code reviews, PR/commit descriptions, chat
  messages, anywhere — must clearly identify that it came from an AI agent and name the **model
  and version** (e.g. `🤖 Posted by an AI agent — Claude Opus 4.8 (claude-opus-4-8)`).
  Disclosure does not transfer accountability: the engineer who ran the agent still owns the
  content (see the accountability rule above).
- AI-generated code follows **every rule in this file**, including TDD. No exceptions for speed.
- **MUST** verify AI-suggested dependencies actually exist and are the intended, maintained
  package before adding them (guard against hallucinated/typosquatted packages).
- **MUST NOT** paste secrets, sensitive user data, or proprietary credentials into prompts.
- **MUST NOT** grant any agent, MCP server, or model-driven tool credentials that can mutate a
  shared or production account. The §3 "Autonomous agents & production infrastructure — hard
  boundary" governs all AI-assisted work without exception — read-only sandbox scope or nothing.
- Prefer asking the model to write the failing test first, then the implementation, and to give
  explicit success criteria it can loop against (§1.4).
- **Multi-review** (`agrology/multi-review`) is a sanctioned review mechanism: an
  author agent and an external reviewer agent converge through bounded rounds, always ending
  at a **human approval gate**. Use it for pre-implementation spec/plan design docs and for
  PR/code review (it supports diff-scoped review with inline comments, and an autonomous
  mode). Adoption is per-repo and opt-in — pin a ref (a release tag for stability, or `main`
  for the latest feature set) and follow that repo's README. Inside review docs, agent
  comments disclose via the protocol's `> — via <model>` lines (same norm as above,
  doc-native shape).

---

## 9. Language / Stack Specifics

### TypeScript + React (frontend — Vite, Tailwind)
- Package manager: **pnpm** only (no `npm install`/`yarn`). Commit `pnpm-lock.yaml`.
- `strict: true` in `tsconfig`. No `any`; use `unknown` + narrowing. No non-null `!` to silence
  the compiler.
- Components: function components + hooks. One component per file; colocate its test and styles.
- State/data: follow the repo's existing pattern (React Query / context) — do not introduce a
  new state library without a maintainer decision (§1.2/§1.3).
- Tests: Vitest + React Testing Library. Test behavior via the DOM, not component internals.
- Accessibility is a requirement, not a polish step: semantic HTML, labels, keyboard paths.

### Node + TypeScript (backend services, serverless)
- pnpm, `strict: true`, ESM per repo convention. No `any` on public/exported surfaces.
- Handlers are thin: parse/validate input → call a tested service/domain function → format
  response. Business logic lives in unit-tested modules, not the handler.
- Validate all event input with a schema validator (e.g. zod) at the boundary.
- Structured JSON logging with a correlation/request id. Never log secrets or PII.
- Config via environment/a secrets manager, never hardcoded. Fail fast on missing required
  config at startup.
- Idempotency for queue/event consumers; explicit timeout and error handling for all I/O.

### Python (services, data/ML pipelines)
- Python 3.11+. Virtual env per project; pinned dependencies (lockfile committed).
- **Type hints required** on all public functions; `mypy` (or `pyright`) clean in CI.
- Format/lint with the repo's configured `ruff`/`black`. CI-enforced.
- Tests: `pytest`. Fixtures for setup; parametrize instead of copy-pasting cases. Mock external
  I/O. No network in unit tests.
- No bare `except:`. Catch specific exceptions; add context when re-raising.
- Notebooks are for exploration only — production logic lives in tested modules, not `.ipynb`.

> Other ecosystems present in the org (e.g. Go services) should get their own subsection here
> following the same pattern: package management, typing/lint gate, test framework, error
> handling, logging. Add as needed — do not leave a stack undocumented.

---

## 10. When In Doubt

1. Re-read §1 — it resolves most questions.
2. Check the repo's local conventions and existing patterns.
3. Ask a maintainer rather than guessing on anything security-, data-, or money-adjacent.
4. Default to the safer, more reversible option and flag the decision in the PR.

---
> `## 11. Repo-Specific Practices` holds this repo's own rules; everything above it is the
> general baseline this repo holds itself to.

## 11. Repo-Specific Practices

> Owned by this repository's maintainers; extends (never silently weakens) any section
> above. Rationale for deviations is documented inline.

### Multi-review (author role)

This repo carries the author-mode command at `commands/multi-review.md`, invoked as
`/multi-review [doc]`. Slash-command registries are indexed at session start, so the command
can be missing from yours even though it exists — if `/multi-review` is reported unknown, do
NOT conclude the command doesn't exist: read `commands/multi-review.md` and follow
it directly. `/multi-review` is autonomous by default — it drives the whole loop unattended and
degrades to the attended two-session flow when the selected reviewer provider cannot be
dispatched.

### Multi-review (reviewer role)

If you are asked to review a doc that is under a multi-review review, read
`docs/multi-review.md` and follow it:

- In Codex, prefer the repo skill `/multi-review <doc>` for this workflow.
- Act **only** when the marker `<!-- multi-review: ... -->` says `awaiting-reviewer`.
- You are a **secondary**: you raise findings and nothing else. Append each under the doc's
  LAST `## Review` heading, outside any fenced block, as:

      > [finding:<id>|<sev>] <concern>
      > — via <your-model-id>
      > — risk: <short risk>
      > — evidence: <how you know>

  `<sev>` is `high`, `med`, or `low`. The `> — via` disclosure and `> — risk:` lines are
  required on every finding; `> — evidence:` is required on `high` and `med` — state the
  mechanism that produces the failure, or the reproduction you ran. A concern you cannot ground
  that way is still worth raising: raise it as `low`.
- Ids are scoped to your own copy (`r1`, `r2`, …); you never coordinate them with anyone else —
  the primary namespaces them on merge.
- If you read the doc in full and have nothing to raise, **say so explicitly** — a flipped
  marker with nothing written is byte-identical to a turn that never opened the document, and is
  quarantined as a non-response:

      > [no-findings] reviewed in full; nothing to raise
      > — via <your-model-id>

  Mutually exclusive with findings; never emit both in one turn.
- **Do not respond to findings.** `[agree:]`/`[dispute:]`/`[resolved:]` belong to the primary, and
  a response disclosed under the same model id as the finding's raiser fails the self-response
  guard. Do not decide convergence either.
- **Flip the marker last:** after writing every finding, change `awaiting-reviewer` →
  `awaiting-author` as your final edit (the flip is the handoff). Never set any other state, and
  never edit the primary's doc or another provider's copy.
- Respect the round bound shown in the marker. Never advance past the human gate, and never
  proceed to implementation or a PR.
- Read only this doc; do not expand to repo-wide context, capture secrets, or upload
  anything beyond the doc content without explicit authorization. **Exception (PR mode):** you
  may read the current bodies of repo files the doc's diff directly references, solely to check
  the change is self-consistent — a narrow local read, no whole-corpus sweeps; every finding
  must still trace to a changed hunk (see "Scope" in `docs/multi-review.md`).
- On a **PR-flavor** doc you MAY anchor a finding to a specific changed line by adding
  `> — at <path>:<line>` (or `<path>:<start>-<end>`) immediately after that finding's
  `> — risk:`/`> — evidence:` lines, using RIGHT-side new-file line numbers. Only **agreed**
  anchored findings post inline; an anchor that does not land on a changed line degrades to the
  summary. There is otherwise no mode to detect — the grammar above is the same for a local doc
  and a PR scratch.

### How this repo applies the sections above

- **Review mechanism:** this is a single-maintainer repo, so §6/§7's "≥1 approving GitHub
  review, no self-merge" is unsatisfiable (GitHub forbids self-approval). The multi-review
  review gate plus the engineer's explicit merge decision is this repo's review mechanism.
  Small docs/chore changes may land directly on `main` at the maintainer's discretion;
  substantive changes go through a PR.
- **Test gate:** the verification gate is `for t in scripts/*.test.sh; do bash "$t"; done`
  plus `shellcheck --severity=warning scripts/multi-review-*.sh` **plus
  `scripts/multi-review-version-check.sh`** **plus
  `scripts/multi-review-mutation-check.sh`**. A line-coverage percentage is not meaningful for
  this bash test suite — and it would not measure the thing that actually goes wrong here, which is
  a guard that is *executed* by a test that cannot fail.
- **Mutation check: every new guard gets a table entry.** `multi-review-mutation-check.sh` deletes
  or rewrites one guard line at a time and asserts a **named** assertion fails. It exists because a
  guard has twice shipped with zero coverage behind a fully green gate (the combined-diff reset and
  the `+++` TAB strips, both in `aa474f6`), and because the same class — a verification that reads
  correctly but cannot fail — has recurred repeatedly in review. A line that is *deliberately*
  redundant behind a covered outer layer is recorded as `SURVIVES-BY-DESIGN` rather than omitted, so
  the reason survives and losing the outer layer surfaces as a failure.
- **CI runs the whole gate** on every PR (`.github/workflows/gate.yml`): the suites on
  `ubuntu-latest` **and** `macos-latest` — the latter pinned to `/bin/bash` 3.2, which is the
  version the scripts claim to support and which Ubuntu's bash 5 cannot check — plus shellcheck
  (which also covers `.githooks/pre-push`, outside the glob above) and the mutation sweep. The
  version check runs there too: that is the one gate step the `pre-push` hook structurally cannot
  cover, since `--no-verify` bypasses it and a merge performed on GitHub runs no local hook.
- **Version bump is required to ship.** Anything that reaches `main` MUST raise
  `.claude-plugin/plugin.json`'s `version`. Installed copies decide whether to offer an update
  by comparing it, so landing a change without a bump leaves every existing install silently on
  the old code — the bump is the only signal downstream gets, not bookkeeping. Semver: patch for
  fixes, minor for new behavior/subcommands, major for a breaking protocol or CLI change.
  `scripts/multi-review-version-check.sh` enforces this (strictly-greater, numeric per component)
  and is part of the gate above; it no-ops on `main` itself and says so when it cannot compute a
  delta rather than passing silently.
- **Install the hooks once per clone:** `scripts/multi-review-install-hooks.sh` points
  `core.hooksPath` at the versioned `.githooks/`, whose `pre-push` runs the version check before
  any push. `.git/hooks/` is untracked, so a committed hook does nothing until a clone opts in.
  The hook runs the version check ONLY, not the suite — a push happens many times a branch, and
  the bump is the thing that gets silently forgotten. Bypass a WIP push with
  `git push --no-verify`. A merge performed on GitHub runs no local hook, so the branch push is
  the last point where a missing bump is still cheap to fix.
- **AI disclosure form:** inside review docs, agent comments disclose via the protocol's
  `> — via <model>` continuation lines (see `docs/multi-review.md`) rather than the
  baseline's banner format; same norm, doc-native shape.
