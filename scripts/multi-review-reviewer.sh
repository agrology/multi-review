#!/usr/bin/env bash
# multi-review-reviewer.sh — reviewer provider registry: which model reviews, whether it can be
# driven automatically, what prompt it gets, and whether the model that actually ran was the
# one selected. Single source of provider truth; the commands own only the dispatch itself.
#
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Exit: 0 ok, 1 check/verify failure, 2 usage.
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
# MULTI_REVIEW_REVIEWER_MODEL overrides the default for whichever provider is selected — nothing
# here is unoverridable.
provider_row() { # <id> -> "id|vendor|dispatch-kind|model|has-skill"
  case "$1" in
    codex)  echo "codex|openai|subagent|${MULTI_REVIEW_REVIEWER_MODEL:-gpt-5.5}|yes" ;;
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
vendor_of_model() { # <model-id> -> vendor
  case "$1" in
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

# respectGitIgnore disabled in a settings.json? whitespace/case-tolerant text match, no jq.
# Advisory/best-effort in both directions: may over/under-detect on pathological JSON.
gitignore_disabled() { # <settings-file> -> 0 if "respectGitIgnore":false is present
  [[ -f "$1" ]] || return 1
  tr -d '[:space:]' < "$1" | tr '[:upper:]' '[:lower:]' | grep -q '"respectgitignore":false'
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
      [[ -d "$(repo_root)/.agents/skills/multi-review" ]] \
        || hint codex "reviewer skill not found — copy .agents/skills/multi-review/ into your repo root"
      ;;
    gemini)
      command -v gemini >/dev/null 2>&1 || die "gemini CLI not on PATH" 1
      local rr; rr="$(repo_root)"
      [[ "${GEMINI_CLI_TRUST_WORKSPACE:-}" == "true" ]] \
        || hint gemini "if gemini can't authenticate or edit, this workspace may be untrusted — export GEMINI_CLI_TRUST_WORKSPACE=true (or trust the folder once)"
      gemini_has_key "$rr" \
        || hint gemini "no API key source — put GEMINI_API_KEY in ~/.gemini/.env (or your repo's .env)"
      gitignore_disabled "${rr}/.gemini/settings.json" \
        || hint gemini "gitignored docs won't be read — set context.fileFiltering.respectGitIgnore:false in .gemini/settings.json"
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

# The opening paragraph is the ONLY provider-dependent part of the prompt. Skill-bearing
# reviewers are pointed at their skill; skill-less ones get an actionable read-then-act
# instruction, because a bare path leaves them nothing to act on. There is one review model
# (star) and one finding grammar — it is stated unconditionally in emit_prompt below, never
# gated on a mode the reviewer has to detect.
prompt_head() { # <has-skill>
  if [[ "$1" == "yes" ]]; then
    cat <<'HEAD'
You are a secondary reviewer in this repo's multi-review star review. Use your multi-review skill
(it reads docs/multi-review.md and follows the star protocol).
HEAD
  else
    cat <<HEAD
You are a secondary reviewer in this repo's multi-review star review.

Before editing anything, read the protocol contract in full:
  ${PROTOCOL}
It defines the star finding grammar and the copy-marker handoff. Follow it for the rest of
this turn.
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
and optionally, right after the risk line, \`> — at <path>:<line>\` (or \`<path>:<start>-<end>\`,
RIGHT-side new-file line numbers). The severity tag and risk line are required on every
finding — local doc or PR diff scratch, there is no mode to detect. Flip the status marker
from \`awaiting-reviewer\` to \`awaiting-author\` as your FINAL edit (the flip is the handoff).

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
  prompt="$(emit_prompt "$(abs_path "$doc")" "$has_skill")"
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
      printf '%s\0' "gemini" "-m" "$model" "--approval-mode" "auto_edit" "-p" "$prompt" ;;
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
    | grep -E '^> \[(reviewer|author: resolved|finding|concur|dispute|withdraw):' 2>/dev/null \
    | sed -E 's/^> \[(reviewer|author: resolved|finding|concur|dispute|withdraw):([^]|]*).*/\1:\2/' \
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

# --- dispatch -------------------------------------------------------------
sub="${1:-}"; [[ -n "$sub" ]] || die "usage: multi-review-reviewer.sh <resolve|check|prompt|command|verify-vendor|vendor-of-model> [args]" 2
shift
case "$sub" in
  resolve) cmd_resolve "$@" ;;
  check)   cmd_check "$@" ;;
  prompt)  cmd_prompt "$@" ;;
  command) cmd_command "$@" ;;
  verify-vendor) cmd_verify_vendor "$@" ;;
  vendor-of-model) cmd_vendor_of_model "$@" ;;
  *)       die "unknown subcommand: $sub" 2 ;;
esac
