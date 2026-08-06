#!/usr/bin/env bash
# multi-review-reviewer.sh — reviewer provider registry: which model reviews, whether it can be
# driven automatically, what prompt it gets, and whether the model that actually ran was the
# one selected. Single source of provider truth; the commands own only the dispatch itself.
#
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Exit: 0 ok, 1 check/verify/provisioning failure, 2 usage.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
PROTOCOL="${ROOT}/.agents/skills/multi-review/protocol/multi-review.md"

die() { echo "multi-review-reviewer: $1" >&2; exit "$2"; }

# --- registry -------------------------------------------------------------
# A case statement rather than an associative array: bash 3.2 has no `declare -A`.
# Model defaults prefer a provider-PUBLISHED alias over a version we pin ourselves, so a new
# release is picked up without a code change:
#   gemini  — `gemini-pro-latest` is Google's own alias for the current top Pro tier. Without a
#             `-m`, the CLI defaults to the cheaper flash tier, which is a weaker reviewer.
#   fable   — already an alias the harness resolves; there is no version here to go stale.
#   codex   — OpenAI publishes no "latest" alias, so a named default is unavoidable. It must be
#             non-empty: an unset model lets the `codex:codex-rescue` wrapper answer as Claude.
#             `verify-vendor` catches that after the fact; this keeps it from happening.
#             `gpt-5.6-terra` is the current top codex tier (successor to gpt-5.4/5.5); bump this
#             when OpenAI ships the next one. NB: codex self-reports its family id `gpt-5-codex`
#             regardless of the pinned variant, so the disclosed `> — via` model may differ
#             (https://github.com/agrology/multi-review/issues/20).
# MULTI_REVIEW_REVIEWER_MODEL overrides the default for whichever provider is selected — nothing
# here is unoverridable.
provider_row() { # <id> -> "id|vendor|dispatch-kind|model|has-skill"
  case "$1" in
    codex)  echo "codex|openai|subagent|${MULTI_REVIEW_REVIEWER_MODEL:-gpt-5.6-terra}|yes" ;;
    fable)  echo "fable|anthropic|subagent|fable|no" ;;
    gemini) echo "gemini|google|shell|${MULTI_REVIEW_REVIEWER_MODEL:-gemini-pro-latest}|no" ;;
    *)      return 1 ;;
  esac
}

# Map an arbitrary disclosed model id to a vendor. Used by `verify-vendor` (reviewer side).
# Returns 1 when unmappable — callers must treat that as a loud failure, never as a silent pass.
#
# Each family accepts the BARE id as well as the versioned one. A CLI that reports a family
# name with no version suffix is common in practice — Gemini discloses `gemini`, and Codex's
# own help documents `model="o3"` — and a suffix-only pattern leaves those unmappable, which
# `verify-vendor` escalates to a hard failure and takes the whole route down.
#
# Matching is CASE-INSENSITIVE (issue #24). Observed live: `codex` disclosed `gpt-5` in one round
# and `GPT-5` in the next from identical dispatches; the lowercase-only patterns made the second
# unmappable, quarantining a correct reviewer and discarding its whole round over the casing of
# its own name. Model self-report is already the least stable field in the protocol (#20), so
# depending on its exact casing compounds an unreliable signal.
#
# This does NOT weaken the guard: an id that maps to the WRONG vendor still fails, and an
# unmappable id still fails. Only the casing dimension is removed, and no impostor is constrained
# by casing — a model claiming to be something it is not would not be stopped by it.
# `printf`, not `echo`: an id beginning with a dash must not be eaten as a flag. `LC_ALL=C` on the
# fold: `[:upper:]`/`[:lower:]` are locale-dependent classes by POSIX, and model ids are ASCII by
# construction, so the mapping must not vary with whatever locale the caller happens to export.
# (The canonical Turkish dotless-i case does not reproduce on BSD tr, but pinning costs nothing
# and removes the whole locale dimension from an identity guard.)
vendor_of_model() { # <model-id> -> vendor
  local id; id="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$id" in
    claude-*|*opus*|*sonnet*|*haiku*|*fable*)     echo "anthropic" ;;
    gpt|gpt-*|o1|o1-*|o3|o3-*|*codex*)            echo "openai" ;;
    gemini|gemini-*)                              echo "google" ;;
    *)                                            return 1 ;;
  esac
}

field() { # <row> <n>
  echo "$1" | cut -d'|' -f"$2"
}

resolve_id() { # --reviewer <id> -> the selected provider id (required; no default)
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reviewer)
        # Explicit arity check: `shift 2` with only one arg left does NOT shift in bash, it
        # just returns non-zero — so `shift 2 || true` would spin this loop forever. A flag
        # with no value is a usage error, per the exit-code contract.
        [[ $# -ge 2 ]] || die "--reviewer requires a value" 2
        id="$2"; shift 2 ;;
      *)  shift ;;
    esac
  done
  [[ -n "$id" ]] || die "--reviewer <id> is required" 2
  echo "$id"
}

resolve_row() { # --reviewer <id> -> the full row, or die 2
  local id rc row
  id="$(resolve_id "$@")"; rc=$?
  # resolve_id runs inside this command substitution's own subshell, so a `die` inside it
  # (e.g. "--reviewer requires a value") exits only that subshell — it does NOT stop this
  # function. Left unchecked, execution falls through with id="" and provider_row emits a
  # second, contradictory "unknown reviewer provider: " (empty) on top of the real reason.
  # Propagate the real failure instead of layering a misleading one over it.
  [[ $rc -eq 0 ]] || exit "$rc"
  row="$(provider_row "$id")" \
    || die "unknown reviewer provider: ${id} (known: codex fable gemini)" 2
  echo "$row"
}

cmd_resolve() { resolve_row "$@"; }

# repo root for workspace-relative advisory checks: the git top-level, else the plugin ROOT.
repo_root() { git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT"; }

# advisory hint -> stderr, distinct prefix so callers (doctor, the command) can grep/relay it.
hint() { echo "multi-review-reviewer: hint ($1): $2" >&2; }

# What a settings file SAYS about respectGitIgnore: "false", "true", or "" when it is silent.
# Whitespace/case-tolerant text match, no jq — advisory/best-effort, may over/under-detect on
# pathological JSON. The tri-state matters because the two scopes are ranked, not OR-ed: see
# gitignore_respected. (Supersedes an earlier boolean gitignore_disabled, which could not
# express "explicitly true" and so could not rank the scopes.)
gitignore_setting() { # <settings-file> -> false | true | (empty)
  [[ -f "$1" ]] || return 0
  local norm; norm="$(tr -d '[:space:]' < "$1" | tr '[:upper:]' '[:lower:]')"
  case "$norm" in
    *'"respectgitignore":false'*) echo false ;;
    *'"respectgitignore":true'*)  echo true ;;
    *)                            : ;;
  esac
}

# Does gemini-cli honor gitignore here? WORKSPACE settings take precedence over user settings, so
# the scopes are ranked rather than OR-ed: a workspace file that explicitly sets
# respectGitIgnore:true overrides a user-scope false. OR-ing them cleared the blocker in exactly
# that case and reported "ready" for a reviewer that would still refuse the docs.
gitignore_respected() { # <repo-root> -> 0 if gitignore IS honored (i.e. a real blocker)
  local v
  v="$(gitignore_setting "$1/.gemini/settings.json")"
  [[ -z "$v" ]] && v="$(gitignore_setting "${HOME:-}/.gemini/settings.json")"
  [[ "$v" != "false" ]]        # default (silent) is honor-gitignore
}

# Newline-separated path list -> one space-separated line. `printf %s`, never `echo`: a path that
# begins with a dash (a doc dir literally named `-n`/`-e`) is eaten by echo as a flag, and the
# hint would then name nothing while still claiming something is unreadable (PR#23 gemini-rd1-r3).
fmt_paths() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }

# Which arming roots gemini-cli would REFUSE to open, given this repo's ignore rules.
#
# Readability is a constraint independent of auth: gemini-cli honors gitignore by default, so a
# review doc under an ignored dir is unreadable no matter how well the CLI is authenticated. The
# candidates are exactly the roots a review can be armed on — the configured doc dirs, plus
# `.multi-review/`, where PR-mode ingests its scratch file (and which the plugin itself
# gitignores, so PR mode is affected even when the doc dirs are clean).
#
# Naming the offending path is the point. The previous hint fired unconditionally and named only
# the setting; a real run read it, checked whether the review copies were ignored (they were
# not), and reasonably concluded it did not apply (issue #22). A hint that names what is
# unreadable cannot be misread that way — and one that stays silent when nothing is ignored is
# believed when it does fire.
gemini_unreadable_paths() { # <repo-root> -> ignored candidate paths, one per line
  local rr="$1" d
  git -C "$rr" rev-parse --git-dir >/dev/null 2>&1 || return 0   # not a repo: gitignore is moot
  # Both scopes, RANKED (workspace wins) — see gitignore_respected. A user-level opt-out makes
  # the docs readable everywhere unless the workspace overrides it, so checking only the
  # workspace file would fire on a correctly-configured machine, and OR-ing the two would stay
  # silent when the workspace explicitly re-enables gitignore.
  gitignore_respected "$rr" || return 0
  # MULTI_REVIEW_DOC_DIRS is space-separated by design (word-split here) — same contract as
  # multi-review-egress-guard.sh; individual dirs cannot contain spaces.
  #
  # Probe the TRAILING-SLASH form. A directory-only pattern (`.multi-review/`, the shape the
  # plugin's own .gitignore uses) does not match a slash-less path that does not exist on disk
  # yet — and these dirs routinely do not, since the check runs before the review is armed. The
  # slash form matches both pattern shapes, so it is the only one correct in all cases.
  # shellcheck disable=SC2086
  for d in ${MULTI_REVIEW_DOC_DIRS:-docs/specs docs/plans docs/superpowers/specs docs/superpowers/plans} .multi-review; do
    # Probe the DIRECTORY *and* a representative markdown file inside it. A rule can ignore the
    # review docs without ignoring their directory (`docs/specs/*.md` is the common shape), and a
    # directory-only probe reports "readable" while gemini still refuses the actual doc.
    # `printf`, not `echo` — same dash-eating hazard fmt_paths documents, one level down: a dir
    # named `-n`/`-e` would be consumed as a flag and silently vanish from the list.
    if git -C "$rr" check-ignore -q -- "${d%/}/" 2>/dev/null \
       || git -C "$rr" check-ignore -q -- "${d%/}/probe.md" 2>/dev/null; then
      printf '%s\n' "$d"
    fi
  done
  return 0
}

# any GEMINI_API_KEY source? env, ~/.gemini/.env, or a workspace .env / .gemini/.env under repo root.
gemini_has_key() { # <repo-root> -> 0 if a key source exists (never reads the value)
  [[ -n "${GEMINI_API_KEY:-}" ]] && return 0
  local f
  # ${HOME:-} guards against a legitimately-unset HOME under `set -u`.
  for f in "${HOME:-}/.gemini/.env" "$1/.env" "$1/.gemini/.env"; do
    [[ -f "$f" ]] && grep -q '^GEMINI_API_KEY=' "$f" && return 0
  done
  return 1
}

cmd_check() { # --reviewer <id> -> 0 dispatchable, 1 with reason
  local row id
  row="$(resolve_row "$@")" || exit 2
  id="$(field "$row" 1)"
  case "$id" in
    fable)
      return 0 ;;                       # in-harness; nothing external to probe
    codex)
      command -v codex >/dev/null 2>&1 \
        || die "codex CLI not on PATH — the plugin route drives the local Codex CLI" 1
      # readiness = CLI present; auth is NOT probed here. The skill is provisioned
      # automatically at dispatch (ensure-skill), so its prior presence is not required.
      local rr; rr="$(repo_root)"
      # Both hints below assume repo_root() resolved a real external repo. When it falls back to
      # the plugin's own ROOT (non-git cwd, or literally inside the plugin repo), the bundle
      # there is the plugin's OWN legitimately-tracked source — neither hint applies, and the
      # untracked-copy hint's "remove it" advice would otherwise target the plugin's own bundle.
      if [[ "$(canon "$rr")" != "$(canon "$ROOT")" ]]; then
        local skill_dir="${rr}/.agents/skills/multi-review"
        if [[ -n "$(git -C "$rr" ls-files -- ".agents/skills/multi-review" 2>/dev/null)" ]]; then
          hint codex "using a git-tracked .agents/skills/multi-review/ — it may drift from the installed plugin; delete it to use auto-provisioning"
        elif [[ -e "$skill_dir" && ! -f "${skill_dir}/.multi-review-materialized" ]]; then
          # Exactly the state ensure-skill refuses forever ("untracked files at … — remove it
          # and re-run") — check/doctor must not say "ready" while codex is quarantined there.
          hint codex "untracked files at ${skill_dir} (pre-plugin manual copy or unrelated work) — remove it and re-run to enable auto-provisioning"
        fi
      fi
      ;;
    gemini)
      command -v gemini >/dev/null 2>&1 || die "gemini CLI not on PATH" 1
      local rr; rr="$(repo_root)"
      [[ "${GEMINI_CLI_TRUST_WORKSPACE:-}" == "true" ]] \
        || hint gemini "if gemini can't authenticate or edit, this workspace may be untrusted — export GEMINI_CLI_TRUST_WORKSPACE=true (or trust the folder once)"
      gemini_has_key "$rr" \
        || hint gemini "no API key source — put GEMINI_API_KEY in ~/.gemini/.env (or your repo's .env)"
      local unreadable; unreadable="$(gemini_unreadable_paths "$rr")"
      [[ -z "$unreadable" ]] \
        || hint gemini "gemini will refuse to read a review doc under $(fmt_paths "$unreadable") — git-ignored in this repo, and gemini-cli honors gitignore. Set context.fileFiltering.respectGitIgnore:false in .gemini/settings.json"
      ;;
    *)
      die "no availability check defined for reviewer provider '${id}'" 2 ;;
  esac
  return 0
}

abs_path() { # <path> -> canonical absolute path, or die 2
  local d b
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || die "cannot resolve doc path: $1" 2
  b="$(basename "$1")"
  echo "${d}/${b}"
}

# The operative contract, for inlining into a skill-less reviewer's prompt.
#
# Everything up to (not including) `## Supersedes`. That section documents the two RETIRED
# grammars (`[reviewer:]`/`[author: resolved:]` and `[concur:]`) for the benefit of someone
# reading the repo's history; handing it to a reviewer would offer it grammar it must not use.
# The awk cut is deliberately a no-op if the heading is ever renamed or dropped — the
# retired-grammar assertions in the test suite are what would then fail, loudly.
protocol_body() {
  [[ -f "$PROTOCOL" ]] || return 1
  awk '/^## Supersedes[[:space:]]*$/{exit} {print}' "$PROTOCOL"
}

# The opening paragraph is the ONLY provider-dependent part of the prompt. Skill-bearing
# reviewers are pointed at their skill; skill-less ones get the contract INLINE. There is one
# review model (star) and one finding grammar — it is stated unconditionally in emit_prompt
# below, never gated on a mode the reviewer has to detect.
#
# Inline rather than by path (issue #22): $PROTOCOL is rooted at the PLUGIN root, which under a
# normal install is ~/.claude/plugins/cache/<owner>/multi-review/<version>/... — always outside
# the repo being reviewed. gemini-cli refuses any read outside its workspace root
# ("Path not in workspace"), and no user setting relaxes that, so the one provider dispatched as
# an external CLI could never open the file. The in-repo copy is no fallback either: it is
# git-ignored twice over by ensure-skill (`.git/info/exclude` + an in-dir `.gitignore`), and
# gemini-cli honors gitignore by default. Inlining removes the filesystem from the path entirely,
# so the contract reaches every reviewer regardless of workspace root, ignore rules, or trust
# settings. Cost is ~7KB of prompt per dispatch.
prompt_head() { # <has-skill>
  if [[ "$1" == "yes" ]]; then
    cat <<'HEAD'
You are a secondary reviewer in this repo's multi-review star review. Use your multi-review skill
(it reads docs/multi-review.md and follows the star protocol).
HEAD
  else
    local body
    body="$(protocol_body)" || die "protocol contract not found at ${PROTOCOL}" 1
    [[ -n "$body" ]] || die "protocol contract at ${PROTOCOL} is empty" 1
    cat <<HEAD
You are a secondary reviewer in this repo's multi-review star review.

Before editing anything, read the protocol contract in full. It is inlined below between the
BEGIN/END markers — do NOT go looking for it on disk. It defines the star finding grammar and
the copy-marker handoff. Follow it for the rest of this turn.

----- BEGIN MULTI-REVIEW PROTOCOL -----
${body}
----- END MULTI-REVIEW PROTOCOL -----
HEAD
  fi
}

emit_prompt() { # <abs-doc-path> <has-skill>
  local abs="$1" has_skill="$2" authority
  # Who defines the finding grammar for this reviewer. Saying "your skill" to a skill-less
  # reviewer contradicts the head block, which just told it to read the protocol file.
  # The codex wording is byte-frozen; only the skill-less variant differs.
  if [[ "$has_skill" == "yes" ]]; then
    authority="the protocol your skill defines"
  else
    authority="the protocol contract you just read"
  fi
  prompt_head "$has_skill"
  cat <<PROMPT

Review EXACTLY this document — its canonical absolute path:
  ${abs}

Do ONE reviewer turn, following ${authority}.
You are a secondary: read the document, then append your findings under its \`## Review\`
heading as:
  \`> [finding:<id>|<sev>] <concern>\` (\`<sev>\` is \`high\`, \`med\`, or \`low\` — required on
  every finding)
  \`> — via <your-model-id>\` — required disclosure line, immediately after
  \`> — risk: <short risk>\` — required, immediately after that, one clause, no paragraphs
  \`> — evidence: <how you know>\` — REQUIRED on \`high\` and \`med\`: the mechanism that produces
  the failure, or the reproduction you ran. If you cannot state one, raise it as \`low\`.
and optionally, after those, \`> — at <path>:<line>\` (or \`<path>:<start>-<end>\`,
RIGHT-side new-file line numbers). The severity tag and risk line are required on every
finding — local doc or PR diff scratch, there is no mode to detect.

Severity is a claim about consequence: \`high\`/\`med\` assert a defect exists, so say how you
know — "empty batch → index 0 raises IndexError", or "ran X, got rc=1". A concern you cannot
ground that way is still worth raising; raise it as \`low\`. Padding a round with speculative
\`med\`s costs the author real edits and the review real rounds.

If you read the document in full and have NOTHING to raise, say so explicitly under the same
\`## Review\` heading — do not simply flip the marker:
  \`> [no-findings] reviewed in full; nothing to raise\`
  \`> — via <your-model-id>\` — required, immediately after
A silent turn is indistinguishable from a reviewer that never opened the document, so an
unsignalled empty turn cannot be credited as a review.

Flip the status marker from \`awaiting-reviewer\` to \`awaiting-author\` as your FINAL edit (the
flip is the handoff).

Read only that document. Do not implement, commit, or open a PR — stop at the human gate.
Then stop and report which ids you added and that the marker was flipped.
PROMPT
}

cmd_prompt() { # <doc> --reviewer <id>
  local doc="${1:-}"
  [[ -n "$doc" ]] || die "usage: multi-review-reviewer.sh prompt <doc-path> --reviewer <id>" 2
  shift
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  local row has_skill
  row="$(resolve_row "$@")" || exit 2
  has_skill="$(field "$row" 5)"
  emit_prompt "$(abs_path "$doc")" "$has_skill"
}

cmd_command() { # <doc> --reviewer <id> -> NUL-delimited argv
  local doc="${1:-}"
  [[ -n "$doc" ]] || die "usage: multi-review-reviewer.sh command <doc-path> --reviewer <id>" 2
  shift
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  local row id kind model has_skill prompt
  row="$(resolve_row "$@")" || exit 2
  id="$(field "$row" 1)"; kind="$(field "$row" 3)"
  model="$(field "$row" 4)"; has_skill="$(field "$row" 5)"
  [[ "$kind" == "shell" ]] \
    || die "provider '${id}' is dispatch-kind '${kind}'; 'command' is shell-kind only (dispatch it via the Agent tool)" 2
  # emit_prompt runs in this substitution's own subshell, so a `die` inside it (missing/empty
  # protocol contract) exits only that subshell. Unchecked, we would emit a perfectly
  # well-formed argv carrying a truncated prompt — the reviewer would run with no contract at
  # all. Propagate instead. (Same subshell-die hazard resolve_row documents above.)
  prompt="$(emit_prompt "$(abs_path "$doc")" "$has_skill")" || exit $?
  # NUL-delimited: the prompt is multi-line and doc paths contain spaces, so the caller must
  # never re-parse this through a shell. Consumer idiom (bash 3.2 safe, no mapfile):
  #   argv=(); while IFS= read -r -d '' a; do argv+=("$a"); done < <(… command "$doc")
  case "$id" in
    gemini)
      # `model` always carries a value (registry default or the env override), so the model is
      # always explicit — we never fall through to the CLI's own default tier.
      #
      # `--approval-mode auto_edit` is the analogue of the codex route's `--write`. Without it
      # `gemini -p` runs at approval mode `default` ("prompt for approval") with nobody there
      # to prompt, so file-modification tools are disabled: observed live, the reviewer emitted
      # its findings as prose and never touched the doc, leaving the marker unflipped. Chosen
      # over `yolo` deliberately — `auto_edit` approves edit tools only, never shell.
      # Opt-in auto-trust (MULTI_REVIEW_GEMINI_AUTOTRUST=1) scopes GEMINI_CLI_TRUST_WORKSPACE=true to
      # THIS dispatch via an `env` prefix, so users needn't set it in their profile. Default
      # (unset/≠1) is byte-identical to before. SECURITY: trusting a workspace lets the CLI honor its
      # .env / settings and auto-edit — opt-in only, never a cloned/untrusted repo (see README).
      if [[ "${MULTI_REVIEW_GEMINI_AUTOTRUST:-}" == "1" ]]; then
        printf '%s\0' "env" "GEMINI_CLI_TRUST_WORKSPACE=true" "gemini" "-m" "$model" "--approval-mode" "auto_edit" "-p" "$prompt"
      else
        printf '%s\0' "gemini" "-m" "$model" "--approval-mode" "auto_edit" "-p" "$prompt"
      fi ;;
    *)
      die "no shell command defined for reviewer provider '${id}'" 2 ;;
  esac
}

cmd_vendor_of_model() { # <model-id> -> vendor, or exit 1 if unmappable
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: multi-review-reviewer.sh vendor-of-model <model-id>" 2
  vendor_of_model "$id" || die "cannot determine vendor from '${id}'" 1
}

# Disclosure-shaped lines inside fenced code blocks are documentation, not protocol. This is a
# deliberate small duplication of multi-review-core.sh's strip_fences (it is a CLI, not a
# sourceable library, so it cannot be imported here) — kept semantically IDENTICAL to it:
# CommonMark fence rules, no awk interval exprs (macOS awk lacks them). An opening fence is a
# line of >=3 backticks with AT MOST 3 leading spaces (4+ leading spaces is an indented code
# block, not a fence, and must stay visible); the closing fence must be >= the opener's length.
# A naive "any-leading-space, parity-toggle" version disagrees with the core engine on indented
# fences — it hides a disclosure the core engine would treat as a live, unresolved thread.
strip_fences() { # <file>
  awk '
    {
      s = $0
      sub(/^ ? ? ?/, "", s)                 # CommonMark allows up to 3 leading spaces
      ticks = 0
      if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) {
          rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { infence = 0; fence_len = 0; next }   # closing fence
        }
        next                                  # inside fence — drop
      }
      if (ticks >= 3) { infence = 1; fence_len = ticks; next }    # opening fence — drop
      print
    }
  ' "$1"
}

# The line where a fence opened but never closed, else empty — mirrors
# multi-review-core.sh's unterminated_fence_line. An unterminated fence makes strip_fences
# silently drop every line after it, including a disclosure that would have failed the
# identity check, so callers MUST refuse rather than report a pass on an unparseable doc.
unterminated_fence_line() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence = 0; fence_len = 0 } }
      } else if (ticks >= 3) { infence = 1; fence_len = ticks; open_ln = NR }
    }
    END { if (infence) print open_ln }
  ' "$1"
}

assert_balanced_fences() { # <file> — hard error (exit 1) on an unterminated code fence
  local file="$1" ln
  ln="$(unterminated_fence_line "$file")"
  [[ -z "$ln" ]] \
    || die "unterminated code fence in ${file} opened at line ${ln}: protocol lines after it are invisible — refusing to verify" 1
}

# Top-level protocol-comment lines of ANY grammar this parser still recognizes (star's current
# finding grammar plus the two single-reviewer/two-agent grammars it superseded), reduced to
# each line's IDENTITY KEY (role:id) — used only to detect "the turn added comments but contributed
# no usable disclosure" below. A key-based diff, not a full-line diff: rewording an existing
# finding's prose (or adding a stray trailing space) must not read as a newly added comment,
# only a genuinely new role:id pair should. `finding:f1|high` reduces to `finding:f1` — the id
# stops at the `|` severity separator. Never used to attribute an identity, so duplicate keys
# are deliberately kept (sorted, not uniqued) to match via_ids' multiset semantics.
protocol_lines() { # <file>
  strip_fences "$1" \
    | grep -E '^> \[((reviewer|author: resolved|finding|concur|dispute|withdraw):|no-findings[]:])' 2>/dev/null \
    | sed -E -e 's/^> \[(reviewer|author: resolved|finding|concur|dispute|withdraw):([^]|]*).*/\1:\2/' \
             -e 's/^> \[(no-findings)[]:].*/\1:/' \
    | sort
}

via_ids() { # <file> -> disclosed model ids, one per line, sorted — DUPLICATES PRESERVED
  # Sorted but NOT unique, deliberately. `comm` over sorted duplicates yields a MULTISET
  # difference, so an extra occurrence of an id already present in the baseline still shows
  # up as new. With `sort -u` it would not: a stale reviewer adding a second
  # `> — via gpt-5-codex` to a doc that already had one would produce an empty diff and
  # pass the identity check silently.
  strip_fences "$1" \
    | grep -oE '^> — via .+' 2>/dev/null \
    | sed -E 's/^> — via[[:space:]]*//' \
    | sed -E 's/[[:space:]]+$//' \
    | sort
}

cmd_verify_vendor() { # --baseline <snap> <doc> --reviewer <id>
  local base="" doc=""
  local -a rest
  rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline)
        [[ $# -ge 2 ]] || die "--baseline requires a value" 2
        base="$2"; shift 2 ;;
      --reviewer)
        # Same arity guard as resolve_id: `shift 2` on a lone flag does not shift, so an
        # unguarded `shift 2 || true` here would loop forever.
        [[ $# -ge 2 ]] || die "--reviewer requires a value" 2
        rest+=("$1" "$2"); shift 2 ;;
      *)  [[ -n "$doc" ]] || doc="$1"; shift ;;
    esac
  done
  [[ -n "$base" ]] \
    || die "verify-vendor requires --baseline <snapshot> (refusing to scan the whole doc)" 2
  [[ -f "$base" ]] || die "baseline snapshot not found: $base" 2
  [[ -n "$doc"  ]] || die "usage: multi-review-reviewer.sh verify-vendor --baseline <snap> <doc> --reviewer <id>" 2
  [[ -f "$doc"  ]] || die "doc not found: $doc" 2

  # An identity check that cannot parse a doc must not report "pass" — refuse both files.
  assert_balanced_fences "$base"
  assert_balanced_fences "$doc"

  local row rid rvendor
  row="$(resolve_row "${rest[@]+"${rest[@]}"}")" || exit 2
  rid="$(field "$row" 1)"; rvendor="$(field "$row" 2)"

  # Only ids NEW in <doc> relative to <baseline>. There is deliberately no author-id
  # exemption: the baseline is taken immediately before dispatch, so every new disclosure
  # belongs to the reviewer turn by construction.
  local new_ids id v new_protocol
  new_ids="$(comm -13 <(via_ids "$base") <(via_ids "$doc"))"
  if [[ -z "$new_ids" ]]; then
    # The turn may still have added protocol comments (marker/finding lines) that contributed
    # zero MAPPABLE disclosures — a missing "> — via" line, an ASCII hyphen / en dash instead
    # of the required em dash, or an empty id all fall through via_ids' regex. Omitting or
    # mangling a disclosure must not be an easier bypass than fabricating a wrong one.
    new_protocol="$(comm -13 <(protocol_lines "$base") <(protocol_lines "$doc"))"
    if [[ -n "$new_protocol" ]]; then
      die "reviewer turn added protocol comment(s) but no usable '> — via <model-id>' disclosure (missing, or not the required em dash '—')" 1
    fi
    return 0
  fi

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! v="$(vendor_of_model "$id")"; then
      die "reviewer identity unverifiable: new disclosure '${id}' maps to no known vendor (expected ${rvendor} for provider '${rid}')" 1
    fi
    if [[ "$v" != "$rvendor" ]]; then
      die "reviewer identity mismatch: new disclosure '${id}' is ${v}, but provider '${rid}' is ${rvendor}" 1
    fi
  done <<< "$new_ids"
  return 0
}

# doctor — per-provider readiness report (never a gate: exit 0 if the report ran). For gemini it
# also runs a bounded LIVE probe; the probe's raw output is discarded (may contain paths/auth).
cmd_doctor() {
  local id rr; rr="$(repo_root)"
  for id in codex fable gemini; do
    local hints rc
    hints="$(cmd_check --reviewer "$id" 2>&1 >/dev/null)"; rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "✗ ${id}: ${hints}"            # hard gate (CLI absent)
      continue
    fi
    if [[ "$id" == "gemini" ]]; then
      # The live probe is AUTHORITATIVE for gemini's AUTH: it proves auth+trust end-to-end, so a
      # green probe means ready even if a static hint (e.g. the env-var-only trust check) fired
      # falsely on an interactively-trusted workspace — auth hints never contradict a passing probe.
      #
      # READABILITY is a separate axis and the probe says nothing about it (issue #22). Letting a
      # green probe suppress it printed "✓ gemini: ready" in exactly the repo state where the
      # reviewer could not open the doc it was sent to review. Report the two independently.
      # The probe is a live network call — run it exactly once, then branch on the result.
      local unread probe_ok=0
      unread="$(gemini_unreadable_paths "$rr")"
      gemini_live_probe && probe_ok=1
      if (( probe_ok )) && [[ -n "$unread" ]]; then
        echo "△ gemini: ${GEMINI_PROBE_MSG}, but it cannot read a review doc under $(fmt_paths "$unread")"
        echo "    git-ignored in this repo, and gemini-cli honors gitignore."
        echo "    fix: set context.fileFiltering.respectGitIgnore:false in .gemini/settings.json"
      elif (( probe_ok )); then
        echo "✓ gemini: ready (${GEMINI_PROBE_MSG})"
      else
        echo "✗ gemini: ${GEMINI_PROBE_MSG}"
        [[ -n "$hints" ]] && printf '%s\n' "$hints" | sed 's/^/    likely cause: /'
      fi
    elif [[ "$id" == "codex" ]]; then
      # A passing check (rc==0) is authoritative for codex too: an advisory hint is never a
      # "needs setup" downgrade — same rule gemini gets above.
      echo "✓ codex: ready"
      [[ -n "$hints" ]] && printf '%s\n' "$hints" | sed 's/^/    advisory: /'
    elif [[ -n "$hints" ]]; then
      echo "△ ${id}: needs setup"
      printf '%s\n' "$hints" | sed 's/^/    /'
    else
      echo "✓ ${id}: ready"
    fi
  done
  return 0
}

# Bounded live probe. Returns 0 on auth OK / non-zero otherwise, and sets GEMINI_PROBE_MSG. Never
# prints the CLI's own output (captured to a temp file, discarded — redaction). Bash 3.2: no
# timeout(1), so poll a background job then escalate TERM→KILL (KILL can't be caught, so the wait
# can't hang) and reap direct children.
GEMINI_PROBE_MSG=""
gemini_live_probe() {
  local model out pid waited bound
  model="$(provider_row gemini | cut -d'|' -f4)"
  bound="${MULTI_REVIEW_PROBE_TIMEOUT:-30}"
  out="$(mktemp)"
  ( gemini -m "$model" -p "reply with OK" >"$out" 2>&1 ) & pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < bound )); do sleep 1; waited=$((waited+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null; sleep 1
    kill -KILL "$pid" 2>/dev/null              # KILL is uncatchable → the wait below returns
    pkill -KILL -P "$pid" 2>/dev/null || true  # reap direct children the CLI may have spawned
    wait "$pid" 2>/dev/null
    rm -f "$out"; GEMINI_PROBE_MSG="live probe timed out after ${bound}s"; return 1
  fi
  if wait "$pid"; then
    rm -f "$out"; GEMINI_PROBE_MSG="live probe: auth OK"; return 0
  fi
  rm -f "$out"; GEMINI_PROBE_MSG="live probe failed (auth/trust?) — run 'gemini -p test' to see the CLI's own error"; return 1
}

# --- provisioning: materialize a has-skill reviewer's bundle into the repo ----------
SKILL_REL=".agents/skills/multi-review"
SKILL_MARKER=".multi-review-materialized"
canon() { cd "$1" 2>/dev/null && pwd -P; }   # canonical physical path, or empty (no die)

# Canonical prefix containment: is <child> inside <parent> (or the same directory)?
#
# BOTH sides are canonicalized (issue #60, codex-rd1-r1). Canonicalizing only the child compares a
# physical path against a logical one, so a symlinked PARENT reports an inside path as outside —
# a FALSE hint on an ordinary same-root review, which is the failure direction that actually costs
# the engineer something. It is also the common case, not an exotic one: /tmp -> /private/tmp on
# macOS makes it the default for anything under a temp dir.
#
# Exit 1 when either side cannot be canonicalized, so an unresolvable path is never reported as
# contained. Callers that must stay silent on an unknown root check that root separately — see
# cmd_check, where "unresolvable" and "outside" have to be distinguished.
#
# The trailing-slash comparison is ensure_skill's existing idiom, and is what stops /root matching
# /rootstuff: containment is by path COMPONENT, not string prefix.
path_contains() { # <parent> <child> -> 0 contained, 1 outside or unresolvable
  local p c
  p="$(canon "${1:?parent}")"
  c="$(canon "${2:?child}")"
  [[ -n "$p" && -n "$c" ]] || return 1
  case "${c}/" in "${p%/}/"*) return 0 ;; *) return 1 ;; esac
}

# The codex sandbox root for THIS session, or empty. codex is bound to one root per session and
# does not follow a shell `cd`, so this — not `git rev-parse --show-toplevel` — is the pair to
# compare a working copy against (issue #60).
#
# Empty on EVERY failure path: no companion installed, no node, no jq, a non-zero run, or an
# absent field. Empty means "unknown", and cmd_check stays silent on unknown rather than hinting
# on every doc. Never dies, never writes, no side effects.
#
# Any single glob match will do. Deliberately NOT "the newest": a lexical sort of version dirs is
# wrong across a component rollover (1.9.0 sorts above 1.10.0), and the choice does not matter —
# workspaceRoot is a property of the session, not of the companion build.
codex_workspace_root() { # -> path, or empty
  local comp="" g
  for g in "${HOME:-}"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs; do
    if [[ -f "$g" ]]; then comp="$g"; break; fi
  done
  [[ -n "$comp" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  command -v jq   >/dev/null 2>&1 || return 0
  node "$comp" status --json 2>/dev/null | jq -r '.workspaceRoot // empty' 2>/dev/null || true
  return 0
}

cmd_ensure_skill() { # --reviewer <id> [--repo <dir>]
  local row id has_skill repo_override="" i args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[i]}" == "--repo" ]]; then
      [[ $((i+1)) -lt ${#args[@]} ]] || die "--repo requires a value" 2
      repo_override="${args[i+1]}"
    fi
  done
  row="$(resolve_row "$@")" || exit 2
  id="$(field "$row" 1)"; has_skill="$(field "$row" 5)"
  [[ "$has_skill" == "yes" ]] || return 0   # skill-less reviewers: nothing to provision

  local src repo repo_c
  src="$(canon "${ROOT}/${SKILL_REL}")"
  [[ -n "$src" && -f "${src}/SKILL.md" ]] || die "plugin skill bundle missing at ${ROOT}/${SKILL_REL}" 1
  repo="${repo_override:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")}"
  repo_c="$(canon "$repo")"; [[ -n "$repo_c" ]] || die "cannot resolve repo root: $repo" 1

  # a symlinked .agents that escapes the repo would let mkdir/cp write out of tree — refuse first
  if [[ -L "${repo_c}/.agents" ]]; then
    local ag; ag="$(canon "${repo_c}/.agents")"
    case "${ag}/" in "${repo_c%/}/"*) : ;; *) die "refusing: ${repo_c}/.agents is a symlink outside the repo" 1 ;; esac
  fi
  mkdir -p "${repo_c}/.agents/skills" || die "cannot create ${repo_c}/.agents/skills" 1
  local skills_c; skills_c="$(canon "${repo_c}/.agents/skills")"
  [[ -n "$skills_c" ]] || die "cannot resolve ${repo_c}/.agents/skills" 1
  case "${skills_c}/" in "${repo_c%/}/"*) : ;; *) die "refusing: .agents/skills resolves outside ${repo_c}" 1 ;; esac
  local dst="${skills_c}/multi-review"

  # src == dst -> no-op (plugin repo itself / non-git fallback to ROOT)
  local dst_c; dst_c="$(canon "$dst")"
  [[ -n "$dst_c" && "$dst_c" == "$src" ]] && return 0
  # an existing dst must be a real dir directly under skills_c (reject a symlinked leaf)
  if [[ -n "$dst_c" ]]; then
    case "${dst_c}/" in "${skills_c%/}/multi-review/") : ;; *) die "refusing: ${dst} resolves outside ${skills_c}" 1 ;; esac
  fi

  # a git-tracked copy -> no-op (capture then test; avoids grep -q SIGPIPE under pipefail)
  local tracked; tracked="$(git -C "$repo_c" ls-files -- "$SKILL_REL" 2>/dev/null)"
  [[ -n "$tracked" ]] && return 0

  # untracked, non-marker dir -> refuse (never destroy the user's files)
  [[ -e "$dst" && ! -f "${dst}/${SKILL_MARKER}" ]] \
    && die "untracked files at ${dst} (pre-plugin manual copy or unrelated work) — remove it and re-run to enable auto-provisioning" 1

  # rollback-safe materialize into a mktemp sibling, then swap
  local version tmp
  version="$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "${ROOT}/.claude-plugin/plugin.json" 2>/dev/null)"
  [[ -n "$version" ]] || die "cannot determine plugin version from plugin.json" 1
  tmp="$(mktemp -d "${skills_c}/.multi-review.materialize.XXXXXX")" || die "cannot create materialization dir" 1
  cp -R "${src}/." "${tmp}/" 2>/dev/null || { rm -rf "$tmp"; die "copy failed while materializing skill bundle" 1; }
  printf '%s\n' "$version" > "${tmp}/${SKILL_MARKER}" || { rm -rf "$tmp"; die "cannot write marker" 1; }
  printf '*\n' > "${tmp}/.gitignore" || { rm -rf "$tmp"; die "cannot write in-dir .gitignore" 1; }
  [[ -f "${tmp}/SKILL.md" && -f "${tmp}/${SKILL_MARKER}" && -f "${tmp}/.gitignore" ]] \
    || { rm -rf "$tmp"; die "materialized bundle incomplete" 1; }
  rm -rf "$dst" || { rm -rf "$tmp"; die "cannot remove old bundle at ${dst}" 1; }
  mv "$tmp" "$dst" || die "failed to install skill bundle at ${dst} — prior bundle was removed; fresh copy left at ${tmp}" 1

  # git hygiene: local exclude (worktree-safe path, anchored, idempotent, newline-safe) + in-dir .gitignore
  local excl ignored=0 pat="/${SKILL_REL}/"
  excl="$(git -C "$repo_c" rev-parse --git-path info/exclude 2>/dev/null)"
  [[ -n "$excl" && "$excl" != /* ]] && excl="${repo_c}/${excl}"
  if [[ -n "$excl" ]] && mkdir -p "$(dirname "$excl")" 2>/dev/null && { [[ -e "$excl" ]] || : > "$excl"; } 2>/dev/null; then
    [[ -s "$excl" && -n "$(tail -c1 "$excl")" ]] && printf '\n' >> "$excl" 2>/dev/null || true
    grep -Fqx -- "$pat" "$excl" 2>/dev/null || printf '%s\n' "$pat" >> "$excl" 2>/dev/null
    grep -Fqx -- "$pat" "$excl" 2>/dev/null && ignored=1
  fi
  grep -Fqx -- '*' "${dst}/.gitignore" 2>/dev/null && ignored=1   # verify the exact rule, not mere existence
  [[ "$ignored" == 1 ]] || die "could not make ${dst} git-ignored (no writable exclude, no in-dir .gitignore)" 1
  return 0
}

# --- dispatch -------------------------------------------------------------
sub="${1:-}"; [[ -n "$sub" ]] || die "usage: multi-review-reviewer.sh <resolve|check|prompt|command|doctor|verify-vendor|vendor-of-model|ensure-skill> [args]" 2
shift
case "$sub" in
  resolve) cmd_resolve "$@" ;;
  check)   cmd_check "$@" ;;
  prompt)  cmd_prompt "$@" ;;
  command) cmd_command "$@" ;;
  ensure-skill) cmd_ensure_skill "$@" ;;
  doctor)  cmd_doctor "$@" ;;
  verify-vendor) cmd_verify_vendor "$@" ;;
  vendor-of-model) cmd_vendor_of_model "$@" ;;
  # Test-only accessor. protocol_lines has no CLI surface, but its normalised KEY is a contract
  # (codex-rd2-r1): two copies whose free text differs must produce the same key, or a reworded
  # line reads as new protocol content. Underscore-prefixed and undocumented on purpose.
  _protocol_lines_for_test)
    [[ $# -ge 1 ]] || die "_protocol_lines_for_test requires a file argument" 2
    protocol_lines "$@" ;;
  # Test-only accessors. Neither helper has a CLI surface, but path_contains' both-sides
  # canonicalization (issue #60, codex-rd1-r1) and codex_workspace_root's empty-on-failure
  # contract are what cmd_check relies on, and check's output cannot distinguish an
  # unresolvable root from an ignored one. Underscore-prefixed and undocumented on purpose.
  _path_contains_for_test) path_contains "$@" ;;
  _codex_workspace_root_for_test) codex_workspace_root "$@" ;;
  *)       die "unknown subcommand: $sub" 2 ;;
esac
