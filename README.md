[ci](https://github.com/PercevalFox/ci-baseline/actions/workflows/ci.yml/badge.svg)

# ci-baseline

A reusable GitHub Actions security workflow that detects what a repository
contains, runs the scanners that apply, and gates the build on a policy.

Takes no secrets. Safe to call from a pull request opened by a fork.

## Usage

```yaml
# .github/workflows/security.yml
name: security

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: '17 4 * * 1'

permissions: {}

jobs:
  security:
    uses: PercevalFox/ci-baseline/.github/workflows/security.yml@<commit-sha>
    permissions:
      contents: read
      security-events: write
```

That is the whole integration. There is no list of languages to declare and no
list of scanners to enable, because both go stale: they get written once,
correctly, and are then wrong from the day someone adds a Dockerfile and
nobody remembers to update the caller.

## What it does

```
detect ──> scan (matrix, parallel) ──> gate
             gitleaks                    merge all SARIF
             trivy (fs, image)           normalise severity
             semgrep                     apply policy
             checkov                     comment / upload / decide
             actionlint
```

**detect** walks the repository for stack markers and builds the scanner
matrix. It excludes `vendor/`, `node_modules/`, `testdata/` and friends —
scanning vendored code produces findings the repository cannot fix, and a wall
of unfixable findings trains everyone to ignore the job.

**scan** runs the applicable scanners in parallel, each with
`continue-on-error: true`. No scanner is allowed to fail the build, and none is
configured with a severity threshold. Both decisions belong to the gate; a
scanner that exits non-zero on findings means the policy lives in two places
and the copy in the workflow file is the one nobody reviews.

**gate** merges every report with [sarif-gate](https://github.com/PercevalFox/sarif-gate),
which deduplicates across tools, normalises severity, applies the policy in
`.sarif-gate.yml`, and produces one comment and one merged SARIF upload.

The `continue-on-error` and the gate's `require_tools` work together: a scanner
that crashes produces no report, and a missing report is caught as a missing
tool rather than read as a clean result. That is the failure this whole design
is built around — a pipeline reporting success while doing nothing is worse
than no pipeline, because the green check mark is now evidence.

## Design decisions worth knowing about

### It takes no secrets

The reusable workflow declares no `secrets:` block at all. That is the most
useful property in the file: a workflow with nothing worth stealing can be
called from a fork pull request without any of the usual danger.

Posting the pull request comment does need write access, so it lives in a
separate `workflow_run` workflow that never touches the pull request's code.
The naive alternative — `pull_request_target` with a checkout of the head —
is a remote code execution vulnerability, and a common one.
`docs/fork-pull-requests.md` explains it in full.

### Everything is pinned to a commit SHA

Including reusable workflows and container images. `scripts/pin-actions.sh`
enforces it in CI. A tag is a mutable pointer held by a third party;
`docs/pinning.md` covers the March 2025 `tj-actions` incident and what it cost
the repositories that had not pinned.

**This repository ships unpinned and pins itself on first setup.** Resolving
tags needs network access and credentials belonging to whoever runs it. Run
`make bootstrap` once after forking; the CI check fails until you do, which is
the point.

### Values never reach a shell through `${{ }}`

Interpolation is textual and happens before the shell parses the line, so
`${{ github.event.pull_request.title }}` inside a `run:` block is remote code
execution against anyone who opens a pull request with a backtick in the
title. Every value passes through `env:` instead. The workflows here have no
attacker-controlled values in them, but the habit is what matters — this is one
of the two most common findings in real Actions audits.

### Every checkout sets `persist-credentials: false`

The default writes a token into `.git/config`, where every subsequent step —
including third-party actions — can read it.

## Scripts

Zero dependencies beyond coreutils and git, so they run on a minimal container
image as well as on `ubuntu-latest`. Not jq, deliberately.

| Script | Purpose |
|---|---|
| `detect-stack.sh` | Decide which scanners apply. `key=true\|false` on stdout and to `$GITHUB_OUTPUT`. |
| `pin-actions.sh` | Verify or fix action pinning. `--fix` resolves tags via `gh`. |
| `actionlint-to-sarif.py` | actionlint has no SARIF writer; without this, workflow problems land in a job nobody opens. |

```bash
make test     # bats, 34 cases
make lint     # shellcheck and actionlint
make check    # both
```

## Configuration

| Input | Default | |
|---|---|---|
| `policy` | `.sarif-gate.yml` | Gate policy in the calling repository. |
| `sarif-gate-version` | `v0.1.0` | |
| `image` | — | Also scan a built container image. |
| `detect-depth` | `6` | Raise for deep monorepos. |
| `upload-sarif` | `true` | Publish to code scanning. |
| `runs-on` | `ubuntu-latest` | |

## Known limitations

- Kubernetes manifests are detected by looking for `apiVersion:` under `k8s/`,
  `kubernetes/`, `manifests/` or `deploy/`. Manifests elsewhere are missed.
  Detecting them by content across a whole repository is slow enough to be
  worse than the miss.
- `pin-actions.sh` parses `uses:` lines with a regular expression rather than a
  YAML parser, to stay dependency-free. A literal `uses:` inside a `run:` block
  would be flagged. A false positive here costs a glance at a diff; the
  dependency costs the ability to run anywhere.
- Scanner versions are pinned but their downloads are not checksum-verified.
  That is a real gap, called out in `docs/threat-model.md` rather than hidden.
- Detection has no per-directory scoping, so a monorepo with a Go service and
  a Node service runs both scanners over the whole tree rather than over the
  relevant subtree.

## Documentation

- `docs/threat-model.md` — what this defends against, what it does not, and
  which residual risks are accepted on purpose.
- `docs/fork-pull-requests.md` — the pwn request pattern and the split-workflow
  structure that avoids it.
- `docs/pinning.md` — why SHAs, and how to keep them current.

## Licence

Apache-2.0.
