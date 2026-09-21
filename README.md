# github-actions

Policy-free composite GitHub Actions for pull-request hygiene, called by SHA-pinned callers in the
consuming repositories. Two actions ship today:

| Action | Does | Caller job permissions |
|---|---|---|
| [`pr-attribution`](pr-attribution/action.yml) | Fails a pull request whose title, body, or own commit messages match any caller-supplied extended regular expression | `contents: read` |
| [`pr-issue-labels`](pr-issue-labels/action.yml) | Copies the labels of the same-repository issues a pull request closes onto the pull request, additively, skipping caller-supplied label-name prefixes | `issues: read`, `pull-requests: write` |

Every policy value is a required input with no default. The actions carry no organisation-specific
rule; the caller says what, the action knows how.

## Usage

Pin by commit SHA, with the release tag in a trailing comment so Dependabot can bump both:

```yaml
name: pr-attribution
on:
  pull_request:
    branches: [main]
    types: [opened, edited, reopened, synchronize]
concurrency:
  group: pr-attribution-${{ github.ref }}
  cancel-in-progress: true
jobs:
  attribution:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: stratechio/github-actions/pr-attribution@<40-hex commit sha> # v1.0.0
        with:
          patterns: |
            [
              {"label": "work-in-progress marker", "pattern": "^wip:"},
              {"label": "bot co-author trailer", "pattern": "co-authored-by:.*@bots\\.example\\.invalid"}
            ]
          remediation-hint: Remove the marker or trailer; see CONTRIBUTING.md.
```

```yaml
name: pr-issue-labels
on:
  pull_request:
    types: [opened, edited, reopened]
concurrency:
  group: pr-issue-labels-${{ github.ref }}
  cancel-in-progress: true
jobs:
  inherit:
    runs-on: ubuntu-24.04
    permissions:
      issues: read
      pull-requests: write
    steps:
      - uses: stratechio/github-actions/pr-issue-labels@<40-hex commit sha> # v1.0.0
        with:
          exclude-label-prefixes: "release:, wip-"
```

A composite action cannot add triggers or permissions: the caller lists every activity type its
policy relies on (`edited` re-scans after a title or body change; `synchronize` re-scans new commits)
and declares the permissions above. `pr-issue-labels` reads the closing links present at the
triggering event; a link added later in the sidebar takes effect on the next `edited` run.

### Inputs

`pr-attribution`

| Input | Required | Meaning |
|---|---|---|
| `patterns` | yes | JSON array of `{"label", "pattern"}` objects. Each pattern is a POSIX extended regular expression matched case-insensitively (`grep -niE`, `LC_ALL=C`, so case folding is ASCII) against the title, the body, and the messages of the pull request's own commits (`base..head`). Backslashes are JSON-escaped: `\\.` for a literal dot. |
| `remediation-hint` | no | Text printed under the failure message. Empty means no hint. |

`pr-issue-labels`

| Input | Required | Meaning |
|---|---|---|
| `exclude-label-prefixes` | yes | Comma-separated label-name prefixes never copied; whitespace around entries is ignored. |

Both actions fail closed: an empty or malformed policy, an unresolvable commit range, an invalid
regular expression, a label or closing-issue list longer than one API page (100 entries), or any API
error fails the run instead of passing it unscanned or half-labelled. The runner does not enforce a
composite action's `required:` inputs, so the shell validates them itself.

## Versioning

- Consumers pin a 40-hex commit SHA and keep the tag in the comment; Dependabot's `github-actions`
  ecosystem rewrites both when a newer tag exists.
- Releases are annotated `vX.Y.Z` tags on `main`. A tag is never moved or deleted; there is no
  floating major tag.
- Compatibility surfaces (a break is a major version): the action directory names; the input names,
  their required/default status, and their semantics; the caller permissions each action needs; the
  trigger types a caller must list; the exit semantics (0 pass, 1 fail). A new optional input with a
  behaviour-preserving default is a minor version; internal fixes, dependency bumps, and message
  wording are patches.

## Security

Anyone with write access to this repository changes what runs under every consumer's `GITHUB_TOKEN`,
including `pull-requests: write` for `pr-issue-labels`. Consumers are protected by the SHA pin plus a
reviewed bump pull request; `main` is protected, releases are tags on reviewed merges, and the
actions read untrusted event fields only through environment variables, never interpolated into the
shell. Renaming this repository, moving an action directory, or making the repository private breaks
every caller at resolution, which surfaces as a failed required check rather than a silent pass.

## Development

- `bash test/run.sh` runs the behaviour and wiring suites. Preconditions: `python3` with PyYAML
  (`python3 -m pip install pyyaml==6.0.3`), `jq`, `git`; `PYTHON=/path/to/python bash test/run.sh`
  selects another interpreter.
- CI runs the suites and `actionlint` on every pull request; `self-check` additionally executes the
  pull request's own `pr-attribution` bytes through a local `uses: ./pr-attribution`.
- Release: merge, then tag the merge commit (`git tag -a vX.Y.Z -m "..." origin/main`, push the tag,
  optionally `gh release create vX.Y.Z --verify-tag`). Consumers resolve the commit with
  `git rev-parse vX.Y.Z^{}`.

## License

Apache-2.0; see [LICENSE](LICENSE).
