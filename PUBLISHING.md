# Publishing to a public repo

Removing files from the working tree does **not** remove them from git history. Before this
repo is made public, all history must be clean of internal references.

## Gate (must pass)

    bash scripts/multi-review-history-check.sh .

Exit 0 = safe. Non-zero prints the offending commits/blobs — do not publish until clean.

## Two safe routes

1. **Fresh-history export (preferred).** Publish the cleaned tree to a NEW public repo with no
   inherited history:

       git checkout --orphan public-main
       git commit -m "Initial public release"
       # push public-main to the new public remote as its main branch

2. **History scrub.** Use `git filter-repo` to purge the excluded paths and the sensitivity
   terms from ALL refs, then re-run the gate:

       git filter-repo --path docs/specs --path docs/plans --path docs/superpowers \
         --path .superpowers --path .multi-review --invert-paths
       bash scripts/multi-review-history-check.sh .

Only flip the GitHub repo to public after the gate passes.

## Distributing via a plugin marketplace

This repo is **both** the plugin and its catalog: `.claude-plugin/marketplace.json` lists a single
entry (`multi-review`) whose `source` is the `github` object for `agrology/multi-review`. Users add
and install with:

    /plugin marketplace add agrology/multi-review
    /plugin install multi-review@agrology

**Why a `github` source (not a relative `"./"`).** The docs recommend `github`/`url` over a relative
path for robustness — a relative source fails when the marketplace is added by direct URL. A `github`
source resolves the repo's **default branch** regardless of add-method, so installs/updates deliver
`main` HEAD (this repo treats `main` as always-shippable).

**Release dependency — the update-prompt trigger.** Marketplace installers only receive an update
prompt when `.claude-plugin/plugin.json`'s `version` is bumped on `main` at release time. Name the
version bump explicitly in the release steps, or a release silently never surfaces an update.

**Reserved names.** The marketplace `name` must not collide with Anthropic's reserved names or
impersonation patterns; `scripts/multi-review-packaging.test.sh` enforces this against a dated
snapshot list (Claude Code's server-side check on load is the authoritative gate). `agrology` is
clear.

**Anthropic's directories (separate, human, not automated here).** Anthropic runs
`claude-plugins-official` (curated, no submission process) and `anthropics/claude-plugins-community`
(reviewed submissions via Anthropic's form). Submitting there is a deliberate outward-facing
decision made by a human — verify the live submission URL/criteria at submission time rather than
trusting a pasted link.
