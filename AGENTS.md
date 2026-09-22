# github-actions

Public repository of policy-free composite GitHub Actions (`pr-attribution`, `pr-issue-labels`),
called by SHA-pinned callers in several independently owned repositories. Apache-2.0. The
[README](README.md) is the consumer-facing contract; this file is the standing brief for agents
changing the repository.

## Invariants

- **The reusable surface carries no consumer policy.** `*/action.yml`, `test/`, and `README.md`
  name no consumer organisation, repository, label, or path. Every policy value is a required input
  with no default; the shell validates it and fails closed, because the runner does not enforce a
  composite action's `required:` inputs. This repository's own workflow callers under
  `.github/workflows/` are consumer configuration, not part of the reusable surface.
- **Untrusted data never reaches the shell by interpolation.** Event fields and inputs pass through
  `env:`; no `run:` block contains `${{`. Third-party actions are pinned to a 40-hex commit SHA with
  the version in a trailing comment.
- **Fail closed.** An unresolvable commit range, an empty or malformed policy, an invalid regular
  expression, an API list cut at its page size (`pageInfo.hasNextPage`), or any API error fails the
  run. A change that turns one of these into a pass is a defect.
- **Tests move with the shell.** An action change updates its behaviour suite in the same pull
  request; the wiring suite pins the step shape, the `env` maps, and the pins. `bash test/run.sh`
  must pass before a pull request is opened.
- **Compatibility surfaces** (a break is a major version): action directory names; input names,
  required/default status, and semantics; the caller permissions each action needs; the trigger
  types a caller must list; exit semantics. See the README's Versioning section.

## Layout

| Path | Holds |
|---|---|
| `pr-attribution/action.yml`, `pr-issue-labels/action.yml` | The composite actions; one `run:` step each |
| `test/*.test.sh`, `test/run.sh` | Bash wrappers around Python `unittest` suites (PyYAML `BaseLoader`, stub `gh`, real `jq` and `git`) |
| `.github/workflows/ci.yml` | Required checks `test` and `actionlint` |
| `.github/workflows/self-check.yml` | Runs the pull request's own `pr-attribution` bytes through a local `uses:` |
| `.github/workflows/pr-attribution.yml`, `pr-issue-labels.yml` | This repository's own consumer-form callers, pinned like every other consumer's |
| `.github/dependabot.yml` | Weekly `github-actions` updates for the workflows and each action directory |

## Working here

- Run the suites with `bash test/run.sh`. Preconditions: `python3` with PyYAML 6.0.3, `jq`, `git`;
  `PYTHON=` selects the interpreter. `actionlint` is optional locally and mandatory in CI.
- Release procedure: follow [README.md#release](README.md#release). Fetch `main`, verify the merged
  pull request's landing commit, and tag that exact commit as an annotated `vX.Y.Z`. GitHub rebase
  merges create no merge commit. Never move or delete a tag. Consumers pin the commit the tag points
  at, bumped by Dependabot.
- Report follow-ups as issues in this repository, labelled with the shared `kind:`, `stage:`, and
  `sev:` families.

## Session branches, push for review (remote-first main)

This repository is remote-first per the workspace decision record
[ADR-0098](https://github.com/stratechio/stratech-ops/blob/main/decisions/0098-github-actions-composite-callers.md):
create session branches from `origin/main` in a dedicated worktree, publish them for pull-request
review, and never merge locally. `main` is protected with required checks, required conversation
resolution, linear history, and administrator enforcement; the merge method is rebase only. Commits
follow Conventional Commits and carry no AI-authorship trailers.

## Workspace standards

The owning workspace is [stratechio/stratech-ops](https://github.com/stratechio/stratech-ops). Its
lint (`stratech-lint`, run from this repository's root before finishing) checks this file, the
`CLAUDE.md` importer, Markdown format, self-containment, branch protection, and the merge method.
