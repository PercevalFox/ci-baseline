# Threat model

What this pipeline is defending against, and what it is not. Written down
because a security control whose purpose is undocumented eventually gets
disabled by someone who could not tell what it was for.

## Assets

1. **The repository's source and history.** Write access allows backdooring.
2. **Secrets available to CI.** Registry credentials, cloud roles, signing
   keys. These are usually the most valuable thing in the pipeline, and often
   more valuable than the code.
3. **Build outputs.** An artifact or image consumers install without
   inspecting.
4. **The runner itself.** Compute, an OIDC identity, and network egress from
   inside a trusted network boundary.

## Adversaries

| Adversary | Capability |
|---|---|
| External contributor | Opens a pull request from a fork. Runs arbitrary code in CI. |
| Compromised dependency | Runs arbitrary code at install or build time. |
| Compromised third-party action | Runs arbitrary code with whatever the job's token allows. |
| Compromised maintainer account | Everything a maintainer can do. |

## What is addressed

**Fork pull requests reaching secrets.** No job that executes repository
content is granted secrets or write permissions. The reusable workflow declares
no `secrets:` at all, so there is nothing to leak even if a consumer wires it
up carelessly. Commenting is split into a separate `workflow_run` workflow;
`docs/fork-pull-requests.md` covers this in detail.

**A compromised action tag.** All third-party actions are pinned to commit
SHAs, checked in CI by `scripts/pin-actions.sh`. A tag is a mutable pointer
controlled by someone outside the organisation. When the `tj-actions`
repository's tags were repointed in March 2025, every consumer pinned to a tag
executed the attacker's code and every consumer pinned to a SHA did not.

**Script injection through workflow expressions.** Values reach shell scripts
through the environment, never through `${{ }}` interpolation inside a `run`
block. Interpolation is textual and happens before the shell parses the line,
so a branch name or pull request title containing shell metacharacters becomes
a command.

**Over-broad tokens.** `permissions: {}` at the top of every workflow, with
each job granting only what it needs. Without this, the effective permissions
depend on an organisation setting that is `write-all` on older accounts.

**Credentials left on disk.** `persist-credentials: false` on every checkout.
The default writes a token into `.git/config`, where every subsequent step —
including third-party actions — can read it.

**A scanner that silently stops working.** The most dangerous pipeline is one
that reports success while doing nothing. Scanner jobs are
`continue-on-error: true` so one failure does not mask the others, and the gate
uses `require_tools` to fail when an expected report is absent. A missing
report is treated as a failure, never as zero findings.

**Findings accumulating unreviewed.** Suppressions live in the gate policy,
require an expiry date, an owner and a reason, and cannot be dated more than
`max_waiver_days` ahead.

## What is not addressed

**A compromised maintainer account.** Someone who can push to the default
branch can change these workflows. Branch protection, required reviews and
hardware-backed 2FA are the controls for that, and they are repository settings
rather than files. This pipeline assumes the default branch is trusted.

**A malicious dependency at build time.** Scanners find *known* vulnerable
versions. They do not find a package that is behaving maliciously and has no
CVE. Runner egress filtering is the usual mitigation and is deliberately not
included here, because it needs a third-party action with elevated access and
that is a trade-off each organisation should make explicitly rather than
inherit from a template.

**Malicious code written by a contributor with commit rights.** SAST catches
patterns, not intent. Code review is the control.

**The scanners themselves being wrong.** Every tool here has false negatives.
Running four overlapping tools and merging their output raises the floor; it
does not make the floor a ceiling. The gate reports when two scanners agree on
a finding precisely because agreement is evidence and a single report is not.

**Compromise of the runner image.** GitHub-hosted runners are trusted. An
organisation that does not want to trust them needs self-hosted runners, which
bring their own and larger threat model — a self-hosted runner accepting fork
pull requests is one of the worst configurations available in Actions.

## Residual risk accepted deliberately

- Third-party actions are pinned but not vendored. A pinned SHA cannot change
  under us, but it also does not receive security fixes until someone bumps it.
  Dependabot handles the bumping; a review of the diff is the control.
- Scanners are installed from upstream releases at job time rather than from a
  pre-built image. This keeps the workflow readable and avoids maintaining an
  image, at the cost of trusting the download. Versions are pinned; checksums
  are not verified, which is a gap worth closing if this is used anywhere that
  matters.
