# Project conventions for Claude Code

## Commits & PRs

- **Do not mention Claude, AI assistance, or co-authoring** in any commit message, commit body, PR title, or PR description.
- No `Co-Authored-By: Claude …` trailer.
- No "Generated with Claude Code" footer.
- No 🤖 emoji or other AI-attribution markers.

Write commits and PRs as the user would write them: focused on the *why* of the change, in their voice.

## Design & planning artifacts

- Specs live in `docs/superpowers/specs/`.
- Plans live in `docs/superpowers/plans/`.
- Ops runbooks live in `docs/ops/`.
- Always reference the current spec when dispatching sub-agents so they work from the agreed contract.
