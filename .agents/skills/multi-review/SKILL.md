---
name: multi-review
description: >-
  Review a multi-review star review working copy as the Codex/GPT secondary. Use when asked
  to review a doc under the file-coordination multi-review protocol, especially docs with a
  `<!-- multi-review: ... -->` marker or requests like "multi-review <doc>".
---

# Multi Review

## Purpose

Act as a **secondary** in this repo's multi-review star review: one primary (Claude) plus N
independent secondaries, each reviewing its own isolated copy of a doc. The primary is
Claude's `/multi-review`; this skill is the Codex/GPT secondary's side. There is one review
model — star — no mode detection, no back-and-forth with other secondaries.

## Workflow

> Setup assumption: this skill lives at `.agents/skills/multi-review/` in the repo Codex is
> running in; all bundled protocol/script paths below are relative to the repo root.

1. Read the bundled protocol contract in full: `.agents/skills/multi-review/protocol/multi-review.md`.
   It defines the star grammar this workflow uses; nothing below restates it.
2. Resolve the target to ONE canonical absolute path before reviewing anything. You were most
   likely handed that path directly (the dispatch prompt names your exact working copy). If
   instead you were handed the bare doc path with no copy suffix:
   - Look for `<path>.codex` next to it — that is your working copy.
   - If neither the given path nor `<path>.codex` exists, or exists but carries no marker, the
     live copy may be in another checkout: run `git worktree list` and check each checkout for
     the same repo-relative doc.
   - Proceed only when EXACTLY ONE candidate copy exists with a non-terminal marker
     (`awaiting-reviewer`). Zero candidates: stop and report the doc is not armed for you. Two
     or more: stop and ask which copy is live. Never guess.
3. Read only that working copy unless the user explicitly authorizes broader repo context.
   Star review is **not** diff-scoped — review the whole document body on its merits, end to
   end (see "Scope" in the protocol doc for the narrow PR-diff exception).
4. Check the copy's marker:
   `bash .agents/skills/multi-review/scripts/multi-review-core.sh marker "<copy>"`
   — prints `<state> <round> <max>`.
   - Act only when the state is `awaiting-reviewer`.
   - `awaiting-author` means you already took your turn on this copy — nothing more to do.
   - `converged` or `exhausted` means the review is over — stop at the human gate.
   - Missing or malformed marker: stop and report the doc is not armed.
5. Review the document for unresolved design, safety, correctness, implementation-plan, or
   protocol concerns. Prefer a small number of high-signal findings over exhaustive commentary.
6. For each concern, append to the `## Review` section, using a fresh id scoped to this copy
   (`r1`, `r2`, … — you never coordinate ids with anyone else; the primary namespaces them on
   merge):

       > [finding:<id>|<sev>] <concern>
       > — via <your-model-id>
       > — risk: <short risk>

   `<sev>` is `high`, `med`, or `low`. Keep the concern to one short line and the risk to one
   clause. Optionally, immediately after the risk line, anchor the finding to a changed line
   (only meaningful when the doc is a PR diff scratch — omit otherwise):

       > — at <path>:<line>

   using RIGHT-side new-file line numbers.
7. If you read the document in full and have **nothing to raise**, say so explicitly instead of
   leaving the `## Review` section untouched — a flipped marker with nothing written is
   byte-identical to a turn that never opened the document:

       > [no-findings] reviewed in full; nothing to raise
       > — via <your-model-id>

   This is mutually exclusive with findings — never emit it alongside a `[finding:]` in the
   same turn.
8. You raise findings only. Do not respond to a finding (yours or anyone else's — that verb set
   is `[agree:]`/`[dispute:]`, and it belongs to the primary), and do not decide convergence.
9. Flip the marker **last**, as your FINAL edit of this turn: change this copy's
   `awaiting-reviewer` to `awaiting-author` (the flip is the handoff). Never set any other
   state, and never edit the primary's doc or any other provider's copy.
10. Stop. Do not implement, commit, or open a PR — stop at the human gate. Do one turn per
    invocation; you are not re-invoked within this session for a later round — a fresh round
    dispatches a fresh copy.

## Review Standard

A good finding is actionable, tied to the doc's stated goal, and explains the failure mode or
ambiguity the primary should resolve.

Use ids like `r1`, `r2`, or `missing-timeout`. Do not reuse an id already present in this copy.

## Scope discipline

Read only the document you were pointed at (plus, for a PR-diff scratch, the current bodies of
repo files the diff directly references, solely to check the change is self-consistent — see
"Scope" in the protocol doc). Capture no env/secrets, and upload nothing beyond the doc's
content without explicit authorization.

## Output

After your turn, report:

- Whether findings were added, and their ids — or that you emitted `[no-findings]` because
  there was nothing to raise.
- That the marker was flipped to `awaiting-author` as the final edit.
- That you are done — the primary picks the review back up; you do not wait for it.
