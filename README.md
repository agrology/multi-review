# multi-review

<p align="center">
  <img src="docs/multi-review-meme.png" alt="Three Spider-Men pointing: primary, secondaries, and the human gate all checking each other" width="480">
  <br>
  <em>Primary, secondaries, human gate — everyone checks everyone.</em>
</p>

An **opt-in, human-gated** code/design review where Claude (the **primary**) fans a doc or PR out
to **N independent secondaries**, adjudicates their findings, and converges — always stopping at a
**human approval gate**. `fable` is always one secondary (Claude's guaranteed review voice); add
cross-vendor reviewers (`codex`, `gemini`) for independent perspective.

One command, one model — **star** — for both local design docs and GitHub PRs.

```mermaid
flowchart TB
  A["/multi-review &lt;doc | PR&gt; --reviewers codex,gemini"] --> P
  subgraph R["each round · up to MULTI_REVIEW_MAX_ROUNDS (default 5)"]
    direction TB
    P["Claude · primary<br/>(neutral — adjudicates,<br/>never authors findings)"]
    P -- blind copy --> F["fable · always"]
    P -- blind copy --> C["codex"]
    P -- blind copy --> G["gemini"]
    F & C & G -- findings --> M["merge + verify-vendor<br/>(impostor → quarantine, not fail)"]
    M --> J["primary agrees /<br/>disputes each"]
    J -- "new findings →<br/>re-fan-out" --> P
  end
  J -- "round went dry → converge" --> H["HUMAN GATE<br/>+ warn if no cross-vendor reviewer"]
  H -- "PR only, on approval" --> Pub["one neutral gh pr review"]
```

## Install

    /plugin install agrology/multi-review

Installs the `/multi-review` command + its scripts. Reviewer setup depends on which reviewers you
add (below) — `fable` needs none.

## Use it

```bash
/multi-review docs/specs/2026-01-01-my-design.md        # local doc, fable only
/multi-review docs/specs/2026-01-01-my-design.md --reviewers codex   # + codex (cross-vendor)
/multi-review https://github.com/owner/repo/pull/42 --reviewers codex,gemini
```

- **You don't have to type the path.** Just say "multi-review the spec / the plan / this PR" —
  it resolves to the doc in context, or the newest dated doc under `MULTI_REVIEW_DOC_DIRS`.
- **Name reviewers in plain language.** "multi-review the spec with codex and gemini" is
  equivalent to `--reviewers codex,gemini`.
- **The combo is remembered per repo.** The last explicitly-named set is saved to
  `.multi-review/reviewers.pref`; a later bare run reuses it (self-healing — a reviewer that
  isn't set up is dropped for that run with a notice, not an error). Say "forget the reviewers"
  to reset to fable-only.
- PR refs also accept `owner/repo#n` and, in the current repo, `#n`.
- The set is always **`(--reviewers) ∪ {fable}`** — `fable` can't be removed.
- Local docs are found under `MULTI_REVIEW_DOC_DIRS` (default `docs/specs docs/plans`); pass an
  explicit path otherwise.
- On a PR, `gh` ingests the diff into a gitignored scratch file; on approval the primary posts
  **one** neutral `gh pr review` (anchored findings inline, the rest in the summary). Needs `gh` +
  `jq`.

## Reviewers

| reviewer | vendor | setup |
|---|---|---|
| `fable` *(always on)* | anthropic | **none** — runs in-harness |
| `codex` | openai | `codex` CLI authed **+** copy `.agents/skills/multi-review/` into your repo root |
| `gemini` | google | `gemini` CLI authed + 3 settings (below) |

**codex skill:** copy this repo's `.agents/skills/multi-review/` to `<your-repo>/.agents/skills/multi-review/`
(exact path — the bundled paths resolve against it) and run Codex from the repo root.

**gemini prereqs** (in order — the first is *the* blocker):
1. **`export GEMINI_CLI_TRUST_WORKSPACE=true`** (or trust the folder once). An untrusted workspace
   makes the CLI skip `.env` (so it can't authenticate — the error misleadingly says "set an Auth
   method") *and* disables file edits, so the reviewer can't write the doc.
2. An API key — `export GEMINI_API_KEY=…`, or drop `GEMINI_API_KEY=…` in `~/.gemini/.env` (or your
   repo's `.env`). **It auto-loads once the workspace is trusted.**
3. `.gemini/settings.json` → `{"context":{"fileFiltering":{"respectGitIgnore":false}}}` (review docs
   are gitignored). The free tier's daily cap will exhaust a multi-round review.

Run **`/multi-review --check-reviewers`** to verify every reviewer's setup at a glance.

## Config

| env | default | meaning |
|---|---|---|
| `MULTI_REVIEW_REVIEWERS` | *(empty)* | comma set of extra secondaries, e.g. `codex,gemini` (per-run: `--reviewers`) |
| `MULTI_REVIEW_MAX_ROUNDS` | `5` | round **ceiling** (each round costs N dispatches; convergence is adaptive) |
| `MULTI_REVIEW_REVIEWER_MODEL` | *(provider default)* | pin a provider's model (`codex`→`gpt-5.5`, `fable`→`fable`, `gemini`→`gemini-pro-latest`) |
| `MULTI_REVIEW_DOC_DIRS` | `docs/specs docs/plans` | where bare-name local docs are resolved |
| `MULTI_REVIEW_GEMINI_AUTOTRUST` | *(off)* | `=1` scopes `GEMINI_CLI_TRUST_WORKSPACE=true` to the gemini dispatch (no profile edit needed). **Security:** trusting a workspace lets gemini honor its `.env`/settings and auto-edit — enable only for repos you trust, never a freshly-cloned one. |

The last explicitly-named reviewer combo is remembered per repo in **`.multi-review/reviewers.pref`**
(gitignored). It is written when reviewers are named (flag or prose) — **except** when
`MULTI_REVIEW_REVIEWERS` is set, which would shadow the pref anyway, so the write is skipped with a
notice. It sits **below** `MULTI_REVIEW_REVIEWERS` in precedence, and self-heals — a remembered
reviewer that isn't available in the repo is dropped on read (with a notice), never poisoning the
run. Reset it with a "forget the reviewers" request.

## How it works

- **Neutral primary.** Claude only agrees/disputes secondaries' findings — it never authors its
  own. That's the anti-rubber-stamp property. `fable` is the always-present secondary so Claude's
  *review* voice is still heard, but adjudicated like any other.
- **Blind, independent copies.** Each secondary reviews its own copy and never sees the others —
  uncorrelated perspective, not consensus.
- **Identity-checked.** After each turn, `verify-vendor` confirms the finding's `> — via`
  disclosure maps to the selected provider's **vendor**. A mismatch or a no-show → that secondary
  is **quarantined** (set aside, surfaced), and the round proceeds on the rest.
- **Adaptive rounds.** The primary re-fans-out while a round still surfaces new findings, up to
  `MAX`; it converges the moment a round goes dry. Convergence is **coverage** — every finding has
  an agree/dispute — not agreement.
- **Independence, honestly.** The gate warns when no *cross-vendor* secondary was admitted (a
  `fable`-only run shares Claude's lineage — real value, weaker claim). Silence = a cross-vendor
  perspective was present.
- **Human gate.** Nothing auto-merges or auto-posts; the run stops for you to decide.

> **`> — via` lines are self-claims, and models misreport their own identity** (a
> `gemini-3.1-pro` turn has disclosed itself as `gemini-2.5-pro`). That's why `verify-vendor`
> checks the **vendor**, not the exact id — treat the line as *who answered*, not a version.

## Layout

- `commands/multi-review.md` — the `/multi-review` command
- `docs/multi-review.md` — the star protocol contract (also vendored into the reviewer skill)
- `.agents/skills/multi-review/` — the self-contained reviewer skill (needed only for `codex`)
- `.claude-plugin/plugin.json` — plugin manifest
- `scripts/multi-review-star.sh` — star grammar: mode / resolve-set / merge / open-findings / check-converged / gate-summary / compose
- `scripts/multi-review-reviewer.sh` — provider registry: resolve / check / prompt / command / verify-vendor / vendor-of-model
- `scripts/multi-review-pr.sh` — PR ingest (via `gh`) + the one-neutral-review publish
- `scripts/multi-review-core.sh` — marker state; `-wait.sh` — bounded per-copy wait;
  `-egress-guard.sh` — path validation; `-build-reviewer-bundle.sh` — regenerate the skill bundle;
  `-history-check.sh` — pre-publish sensitive-term gate (see `PUBLISHING.md`)
- `scripts/*.test.sh` — one suite per script (the gate below)
- `CLAUDE.md` / `AGENTS.md` — this repo's engineering agreement (§11 = multi-review specifics)

## Tests

    for t in scripts/*.test.sh; do bash "$t" || exit 1; done

Runs on macOS `/bin/bash` 3.2 and modern bash; keep `shellcheck --severity=warning scripts/multi-review-*.sh` clean.
