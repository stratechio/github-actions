@AGENTS.md

## Claude Code

The repository standards are in [AGENTS.md](AGENTS.md), imported above; every coding agent reads
them. This section is the Claude-Code-only wiring.

- **No repo-local skills.** This repository is a `brief-only` member of the workspace bootstrap
  manifest: the brief above is the whole instruction surface, and the workspace scripts on `PATH`
  (`stratech-lint` from the repository root before finishing) are the toolchain.
- **Memory.** The workspace and this repository's own files are the system of record, not Claude's
  memory system. Do not restate the global collaboration or git conventions here.
